import Foundation

/// A selectable file-type group for the file-browser search filter
/// (e.g. "Java" → .java/.kt). The user picks one or more presets; searches
/// are then restricted to those extensions and non-matching files are dimmed
/// in the listing. Stored in AppearanceConfig as a list of preset ids.
///
/// Kept as a flat extension list so the same filter can later drive a
/// content (grep) search via `--include=*.ext` without reshaping anything.
public struct SearchFileType: Identifiable, Equatable {
    public let id: String          // stable id persisted in config
    public let label: String       // chip label in settings
    public let extensions: [String] // lowercased, no leading dot

    public init(id: String, label: String, extensions: [String]) {
        self.id = id; self.label = label; self.extensions = extensions
    }

    public static let presets: [SearchFileType] = [
        .init(id: "java",   label: "Java",    extensions: ["java", "kt"]),
        .init(id: "python", label: "Python",  extensions: ["py", "pyi"]),
        .init(id: "js",     label: "JS/TS",   extensions: ["js", "jsx", "ts", "tsx", "mjs", "cjs"]),
        .init(id: "swift",  label: "Swift",   extensions: ["swift"]),
        .init(id: "go",     label: "Go",      extensions: ["go"]),
        .init(id: "rust",   label: "Rust",    extensions: ["rs"]),
        .init(id: "c",      label: "C/C++",   extensions: ["c", "h", "cc", "cpp", "hpp", "cxx", "hh"]),
        .init(id: "csharp", label: "C#",      extensions: ["cs"]),
        .init(id: "ruby",   label: "Ruby",    extensions: ["rb"]),
        .init(id: "php",    label: "PHP",     extensions: ["php"]),
        .init(id: "web",    label: "Web",     extensions: ["html", "css", "scss", "vue", "svelte"]),
        .init(id: "shell",  label: "Shell",   extensions: ["sh", "bash", "zsh"]),
        .init(id: "config", label: "Config",  extensions: ["json", "yaml", "yml", "toml", "xml"]),
        .init(id: "docs",   label: "Docs",    extensions: ["md", "txt", "rst"]),
    ]

    private static let byID = Dictionary(uniqueKeysWithValues: presets.map { ($0.id, $0) })

    /// Union of extensions for the selected preset ids (deduped, order-stable).
    public static func extensions(forSelectedIDs ids: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for id in ids {
            for ext in byID[id]?.extensions ?? [] where seen.insert(ext).inserted {
                result.append(ext)
            }
        }
        return result
    }
}
