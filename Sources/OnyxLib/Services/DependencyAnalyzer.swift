import Foundation
import OnyxCore

/// Analyzes dependency relationships between changed files in a git repo.
/// Runs a Python script on the remote host (via SSH) that:
/// 1. Gets changed files from git status
/// 2. Parses imports from all Java files in the repo
/// 3. Builds a dependency graph
/// 4. Finds the subgraph connecting changed files (including intermediaries)
/// 5. Outputs a Mermaid diagram
public class DependencyAnalyzer {
    private let appState: AppState

    /// Create a new instance.
    public init(appState: AppState) {
        self.appState = appState
    }

    /// Analyze dependencies for the given repo path and return Mermaid diagram text.
    /// Runs on a background thread. Calls completion on main thread.
    public func analyze(repoPath: String, host: HostConfig? = nil, completion: @escaping (String?) -> Void) {
        let h = host ?? appState.activeHost ?? .localhost
        let transport = appState.transport

        DispatchQueue.global(qos: .userInitiated).async {
            // Step 1: Write the analysis script to a temp file
            let tmpDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("onyx-deps-\(ProcessInfo.processInfo.processIdentifier)")
            try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmpDir) }

            let scriptFile = tmpDir.appendingPathComponent("analyze_deps.py")
            try? Self.analysisScript.write(to: scriptFile, atomically: true, encoding: .utf8)

            if h.isLocal {
                // Local: run directly
                print("DependencyAnalyzer: running locally for \(repoPath)")
                let result = Self.runLocally(scriptFile.path, repoPath: repoPath)
                DispatchQueue.main.async { completion(result) }
                return
            }

            // Remote: copy the script up, run it, clean up. The upload path
            // is relative to the remote home — a file-transfer path, not a
            // shell path (CLAUDE.md, "scp paths are NOT shell paths").
            print("DependencyAnalyzer: uploading script to \(h.label)...")
            let mkdir = transport.runCommand("mkdir -p ~/.onyx", on: h, label: "deps:mkdir")
            if mkdir.exit != 0 {
                print("DependencyAnalyzer: failed to create ~/.onyx on remote")
            }
            let upload = transport.upload(scriptFile.path, to: ".onyx/analyze_deps.py", on: h,
                                          recursive: false, timeout: 30, label: "deps:upload")
            guard upload.exit == 0 else {
                print("DependencyAnalyzer: upload failed (\(upload.exit)): \(upload.stderr)")
                DispatchQueue.main.async { completion(nil) }
                return
            }

            print("DependencyAnalyzer: running script on \(h.label)...")
            let escaped = repoPath.replacingOccurrences(of: "'", with: "'\\''")
            let remoteScript = "~/.onyx/analyze_deps.py"
            let result = transport.runCommand(
                "python3 \(remoteScript) '\(escaped)'; EXIT=$?; rm -f \(remoteScript); exit $EXIT",
                on: h, label: "deps:run")
            let output = result.combined.isEmpty ? nil : result.combined
            print("DependencyAnalyzer: remote exit=\(result.exit), output=\(output?.prefix(200) ?? "nil")")
            DispatchQueue.main.async { completion(output) }
        }
    }

    /// Run the analysis script locally and return its output.
    private static func runLocally(_ scriptPath: String, repoPath: String) -> String? {
        let result = RemoteExec.shared.run("/usr/bin/python3", args: [scriptPath, repoPath],
                                           softTimeout: 10, captureStdout: true, captureStderr: true,
                                           label: "deps:local")
        let merged = result.stdout + (result.stderr.isEmpty ? "" : "\n" + result.stderr)
        print("DependencyAnalyzer: local exit=\(result.exit), output=\(merged.prefix(200))")
        return merged.isEmpty ? nil : merged
    }

    // MARK: - Analysis Script

    /// Python script that analyzes Java dependency graphs.
    /// Self-contained, no external dependencies beyond Python 3 stdlib.
    static let analysisScript = """
    #!/usr/bin/env python3
    \"\"\"Analyze dependency graph between changed Java files in a git repo.\"\"\"
    import os, sys, re, subprocess
    from collections import defaultdict
    from pathlib import Path

    def get_changed_files(repo):
        \"\"\"Get list of changed files from git status.\"\"\"
        result = subprocess.run(
            ['git', '-C', repo, 'status', '--porcelain'],
            capture_output=True, text=True
        )
        files = []
        for line in result.stdout.strip().split('\\n'):
            if not line.strip():
                continue
            # Format: "XY filename" or "XY old -> new"
            parts = line[3:].strip().split(' -> ')
            path = parts[-1].strip()
            if path:
                files.append(path)
        return files

    def find_java_files(repo):
        \"\"\"Find all .java files in the repo.\"\"\"
        result = subprocess.run(
            ['find', repo, '-name', '*.java', '-not', '-path', '*/.*',
             '-not', '-path', '*/build/*', '-not', '-path', '*/target/*',
             '-not', '-path', '*/node_modules/*'],
            capture_output=True, text=True
        )
        return [f.strip() for f in result.stdout.strip().split('\\n') if f.strip()]

    def extract_imports(filepath):
        \"\"\"Extract import statements from a Java file.\"\"\"
        imports = []
        try:
            with open(filepath, 'r', errors='ignore') as f:
                for line in f:
                    line = line.strip()
                    if line.startswith('import '):
                        # import com.example.Foo; or import static com.example.Foo.bar;
                        match = re.match(r'import\\s+(?:static\\s+)?(\\S+?)\\s*;', line)
                        if match:
                            imports.append(match.group(1))
                    elif line.startswith('class ') or line.startswith('public class') or \\
                         line.startswith('interface ') or line.startswith('public interface') or \\
                         line.startswith('enum ') or line.startswith('public enum') or \\
                         line.startswith('@'):
                        break  # Past the import section
        except:
            pass
        return imports

    def package_to_path(pkg):
        \"\"\"Convert a Java package name to a relative path. e.g., com.foo.Bar -> com/foo/Bar.java\"\"\"
        # Remove method references for static imports
        parts = pkg.split('.')
        # The class name is typically the last capitalized part
        path_parts = []
        for i, p in enumerate(parts):
            path_parts.append(p)
            if i < len(parts) - 1 and parts[i+1][0].isupper() if parts[i+1] else False:
                path_parts.append(parts[i+1])
                break
            elif p[0].isupper():
                break
        return '/'.join(path_parts) + '.java'

    def build_graph(repo, java_files):
        \"\"\"Build import dependency graph. Returns {file_rel_path: [imported_file_rel_paths]}\"\"\"
        # Map: partial path suffix -> full relative path
        # e.g., "com/foo/Bar.java" -> "src/main/java/com/foo/Bar.java"
        suffix_map = {}
        for f in java_files:
            rel = os.path.relpath(f, repo)
            # Store progressively shorter suffixes
            parts = rel.split('/')
            for i in range(len(parts)):
                suffix = '/'.join(parts[i:])
                if suffix not in suffix_map:
                    suffix_map[suffix] = rel

        graph = defaultdict(set)
        for f in java_files:
            rel = os.path.relpath(f, repo)
            imports = extract_imports(f)
            for imp in imports:
                target_path = package_to_path(imp)
                # Try to find the target in our suffix map
                if target_path in suffix_map:
                    target_rel = suffix_map[target_path]
                    if target_rel != rel:
                        graph[rel].add(target_rel)
        return graph

    def find_connecting_subgraph(graph, changed_files):
        \"\"\"Find the subgraph that connects changed files, including intermediary nodes.\"\"\"
        # Build reverse graph too
        reverse = defaultdict(set)
        for src, targets in graph.items():
            for t in targets:
                reverse[t].add(src)

        changed_set = set(changed_files)
        if len(changed_set) < 2:
            # Just show direct dependencies of the single changed file
            relevant = set()
            for f in changed_set:
                relevant.add(f)
                relevant.update(graph.get(f, set()))
                relevant.update(reverse.get(f, set()))
            return relevant

        # BFS from each changed file to find paths to other changed files
        # Include any node that lies on a shortest path between two changed files
        relevant = set(changed_set)

        for start in changed_set:
            # BFS forward
            visited = {start: None}
            queue = [start]
            while queue:
                current = queue.pop(0)
                for neighbor in graph.get(current, set()) | reverse.get(current, set()):
                    if neighbor not in visited:
                        visited[neighbor] = current
                        queue.append(neighbor)
                        # If we reached another changed file, trace back the path
                        if neighbor in changed_set and neighbor != start:
                            node = neighbor
                            while node is not None:
                                relevant.add(node)
                                node = visited[node]

        return relevant

    def short_name(path):
        \"\"\"Extract a short display name from a file path.\"\"\"
        name = os.path.basename(path)
        if name.endswith('.java'):
            name = name[:-5]
        return name

    def generate_mermaid(graph, relevant_nodes, changed_files):
        \"\"\"Generate a Mermaid diagram for the relevant subgraph.\"\"\"
        changed_set = set(changed_files)
        lines = ['graph LR']

        # Define node styles
        node_ids = {}
        for i, node in enumerate(sorted(relevant_nodes)):
            nid = f'N{i}'
            node_ids[node] = nid
            name = short_name(node)
            if node in changed_set:
                lines.append(f'    {nid}["{name}"]')
            else:
                lines.append(f'    {nid}("{name}")')

        # Add edges (only between relevant nodes)
        edges_added = set()
        for src in relevant_nodes:
            for target in graph.get(src, set()):
                if target in relevant_nodes:
                    edge = (src, target)
                    if edge not in edges_added:
                        edges_added.add(edge)
                        lines.append(f'    {node_ids[src]} --> {node_ids[target]}')

        # Style changed nodes
        changed_ids = [node_ids[f] for f in changed_set if f in node_ids]
        if changed_ids:
            lines.append(f'    style {",".join(changed_ids)} fill:#4a3,stroke:#6b5,color:#fff')

        # Style intermediate nodes
        intermediate_ids = [node_ids[f] for f in relevant_nodes - changed_set if f in node_ids]
        if intermediate_ids:
            lines.append(f'    style {",".join(intermediate_ids)} fill:#335,stroke:#558,color:#aac')

        return '\\n'.join(lines)

    def main():
        repo = sys.argv[1] if len(sys.argv) > 1 else '.'
        repo = os.path.abspath(repo)

        changed = get_changed_files(repo)
        java_changed = [f for f in changed if f.endswith('.java')]

        if not java_changed:
            print('graph LR')
            print('    N0["No Java files changed"]')
            return

        java_files = find_java_files(repo)
        if not java_files:
            print('graph LR')
            print('    N0["No Java files found"]')
            return

        graph = build_graph(repo, java_files)
        relevant = find_connecting_subgraph(graph, java_changed)

        # Always include changed files even if they have no connections
        for f in java_changed:
            relevant.add(f)

        mermaid = generate_mermaid(graph, relevant, java_changed)
        print(mermaid)

    if __name__ == '__main__':
        main()
    """
}
