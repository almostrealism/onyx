import SwiftUI

// MARK: - Syntax Highlighting

enum SyntaxHighlighter {
    // Theme colors (dark background friendly)
    private static let keyword = Color(hex: "C06BFF")     // purple
    private static let type = Color(hex: "66CCFF")         // blue
    private static let string = Color(hex: "6BFF8E")       // green
    private static let comment = Color(hex: "6B7280")      // gray
    private static let number = Color(hex: "FFD06B")       // yellow
    private static let annotation = Color(hex: "FFD06B")   // yellow
    private static let plain = Color.white.opacity(0.85)

    /// Supported file extensions → language
    private static let languages: [String: Language] = [
        "java": .java, "kt": .kotlin,
        "swift": .swift,
        "js": .javascript, "ts": .typescript, "jsx": .javascript, "tsx": .typescript,
        "py": .python,
        "go": .go,
        "rs": .rust,
        "c": .c, "cpp": .c, "h": .c, "hpp": .c, "cc": .c,
        "rb": .ruby,
        "sh": .shell, "bash": .shell, "zsh": .shell,
        "json": .json,
        "yaml": .yaml, "yml": .yaml,
        "toml": .toml,
        "xml": .xml, "html": .xml, "htm": .xml, "plist": .xml, "svg": .xml,
    ]

    enum Language {
        case java, kotlin, swift, javascript, typescript, python, go, rust, c, ruby, shell, json, yaml, toml, xml
    }

    static func highlight(_ content: String, fileName: String) -> AttributedString {
        let ext = (fileName as NSString).pathExtension.lowercased()
        guard let language = languages[ext] else {
            var attr = AttributedString(content)
            attr.foregroundColor = plain
            return attr
        }
        return highlightCode(content, language: language)
    }

    private static func highlightCode(_ code: String, language: Language) -> AttributedString {
        var result = AttributedString(code)
        result.foregroundColor = plain

        let rules = syntaxRules(for: language)
        for rule in rules {
            guard let regex = try? NSRegularExpression(pattern: rule.pattern, options: rule.options) else { continue }
            let nsRange = NSRange(code.startIndex..., in: code)
            for match in regex.matches(in: code, range: nsRange) {
                let groupIndex = rule.captureGroup
                let matchRange = groupIndex < match.numberOfRanges ? match.range(at: groupIndex) : match.range
                guard matchRange.location != NSNotFound,
                      let range = Range(matchRange, in: code) else { continue }
                let offset = code.distance(from: code.startIndex, to: range.lowerBound)
                let length = code.distance(from: range.lowerBound, to: range.upperBound)
                let start = result.index(result.startIndex, offsetByCharacters: offset)
                let end = result.index(start, offsetByCharacters: length)
                result[start..<end].foregroundColor = rule.color
            }
        }
        return result
    }

    private struct Rule {
        let pattern: String
        let color: Color
        let options: NSRegularExpression.Options
        let captureGroup: Int

        init(_ pattern: String, _ color: Color, options: NSRegularExpression.Options = [], group: Int = 0) {
            self.pattern = pattern
            self.color = color
            self.options = options
            self.captureGroup = group
        }
    }

    private static func syntaxRules(for language: Language) -> [Rule] {
        // Order matters: numbers → keywords → types → annotations → strings → comments
        // Later rules override earlier ones at the same position
        switch language {
        case .java:
            return javaRules()
        case .kotlin:
            return kotlinRules()
        case .swift:
            return swiftRules()
        case .javascript, .typescript:
            return jsRules()
        case .python:
            return pythonRules()
        case .go:
            return goRules()
        case .rust:
            return rustRules()
        case .c:
            return cRules()
        case .ruby:
            return rubyRules()
        case .shell:
            return shellRules()
        case .json:
            return jsonRules()
        case .yaml:
            return yamlRules()
        case .toml:
            return tomlRules()
        case .xml:
            return xmlRules()
        }
    }

    // MARK: - Language Rules

    private static func javaRules() -> [Rule] {
        let keywords = "abstract|assert|boolean|break|byte|case|catch|char|class|const|continue|default|do|double|else|enum|extends|final|finally|float|for|goto|if|implements|import|instanceof|int|interface|long|native|new|package|private|protected|public|return|short|static|strictfp|super|switch|synchronized|this|throw|throws|transient|try|var|void|volatile|while|yield|record|sealed|permits|non-sealed"
        let types = "String|Integer|Long|Double|Float|Boolean|Byte|Short|Character|Object|List|Map|Set|ArrayList|HashMap|HashSet|Optional|Stream|Collection|Iterator|Iterable|Comparable|Runnable|Callable|Future|Thread|Exception|Error|Override|Deprecated|SuppressWarnings|FunctionalInterface"
        return [
            Rule(#"\b(\d+\.?\d*[fFdDlL]?)\b"#, number),
            Rule(#"\b(0x[0-9a-fA-F]+[lL]?)\b"#, number),
            Rule("\\b(\(keywords))\\b", keyword),
            Rule("\\b(\(types))\\b", type),
            Rule(#"\b(true|false|null)\b"#, keyword),
            Rule(#"@\w+"#, annotation),
            Rule(#""(?:[^"\\]|\\.)*""#, string),
            Rule(#"'(?:[^'\\]|\\.)*'"#, string),
            Rule(#"//.*$"#, comment, options: .anchorsMatchLines),
            Rule(#"/\*[\s\S]*?\*/"#, comment, options: .dotMatchesLineSeparators),
        ]
    }

    private static func kotlinRules() -> [Rule] {
        let keywords = "abstract|actual|annotation|as|break|by|catch|class|companion|const|constructor|continue|crossinline|data|delegate|do|dynamic|else|enum|expect|external|final|finally|for|fun|get|if|import|in|infix|init|inline|inner|interface|internal|is|it|lateinit|noinline|object|open|operator|out|override|package|private|protected|public|reified|return|sealed|set|super|suspend|tailrec|this|throw|try|typealias|val|var|vararg|when|where|while"
        return [
            Rule(#"\b(\d+\.?\d*[fFdDlL]?)\b"#, number),
            Rule("\\b(\(keywords))\\b", keyword),
            Rule(#"\b(true|false|null)\b"#, keyword),
            Rule(#"@\w+"#, annotation),
            Rule(#""(?:[^"\\]|\\.)*""#, string),
            Rule(#"//.*$"#, comment, options: .anchorsMatchLines),
            Rule(#"/\*[\s\S]*?\*/"#, comment, options: .dotMatchesLineSeparators),
        ]
    }

    private static func swiftRules() -> [Rule] {
        let keywords = "actor|any|as|associatedtype|async|await|break|case|catch|class|continue|convenience|default|defer|deinit|do|dynamic|else|enum|extension|fallthrough|fileprivate|final|for|func|get|guard|if|import|in|indirect|infix|init|inout|internal|is|isolated|lazy|let|mutating|nonisolated|nonmutating|open|operator|optional|override|package|postfix|precedencegroup|prefix|private|protocol|public|repeat|required|rethrows|return|set|some|static|struct|subscript|super|switch|throw|throws|try|typealias|unowned|var|weak|where|while|willSet|didSet"
        return [
            Rule(#"\b(\d+\.?\d*)\b"#, number),
            Rule("\\b(\(keywords))\\b", keyword),
            Rule(#"\b(true|false|nil|self|Self)\b"#, keyword),
            Rule(#"@\w+"#, annotation),
            Rule(#""(?:[^"\\]|\\.)*""#, string),
            Rule(#"//.*$"#, comment, options: .anchorsMatchLines),
            Rule(#"/\*[\s\S]*?\*/"#, comment, options: .dotMatchesLineSeparators),
        ]
    }

    private static func jsRules() -> [Rule] {
        let keywords = "abstract|arguments|async|await|break|case|catch|class|const|continue|debugger|default|delete|do|else|enum|export|extends|finally|for|from|function|get|if|implements|import|in|instanceof|interface|let|new|of|package|private|protected|public|return|set|static|super|switch|this|throw|try|typeof|var|void|while|with|yield"
        return [
            Rule(#"\b(\d+\.?\d*)\b"#, number),
            Rule("\\b(\(keywords))\\b", keyword),
            Rule(#"\b(true|false|null|undefined|NaN|Infinity)\b"#, keyword),
            Rule(#""(?:[^"\\]|\\.)*""#, string),
            Rule(#"'(?:[^'\\]|\\.)*'"#, string),
            Rule(#"`(?:[^`\\]|\\.)*`"#, string),
            Rule(#"//.*$"#, comment, options: .anchorsMatchLines),
            Rule(#"/\*[\s\S]*?\*/"#, comment, options: .dotMatchesLineSeparators),
        ]
    }

    private static func pythonRules() -> [Rule] {
        let keywords = "and|as|assert|async|await|break|class|continue|def|del|elif|else|except|finally|for|from|global|if|import|in|is|lambda|nonlocal|not|or|pass|raise|return|try|while|with|yield"
        return [
            Rule(#"\b(\d+\.?\d*[jJ]?)\b"#, number),
            Rule("\\b(\(keywords))\\b", keyword),
            Rule(#"\b(True|False|None|self|cls)\b"#, keyword),
            Rule(#"@\w+"#, annotation),
            Rule(#"f?"(?:[^"\\]|\\.)*""#, string),
            Rule(#"f?'(?:[^'\\]|\\.)*'"#, string),
            Rule(#"#.*$"#, comment, options: .anchorsMatchLines),
        ]
    }

    private static func goRules() -> [Rule] {
        let keywords = "break|case|chan|const|continue|default|defer|else|fallthrough|for|func|go|goto|if|import|interface|map|package|range|return|select|struct|switch|type|var"
        let types = "bool|byte|complex64|complex128|error|float32|float64|int|int8|int16|int32|int64|rune|string|uint|uint8|uint16|uint32|uint64|uintptr"
        return [
            Rule(#"\b(\d+\.?\d*)\b"#, number),
            Rule("\\b(\(keywords))\\b", keyword),
            Rule("\\b(\(types))\\b", type),
            Rule(#"\b(true|false|nil|iota)\b"#, keyword),
            Rule(#""(?:[^"\\]|\\.)*""#, string),
            Rule(#"`[^`]*`"#, string),
            Rule(#"//.*$"#, comment, options: .anchorsMatchLines),
            Rule(#"/\*[\s\S]*?\*/"#, comment, options: .dotMatchesLineSeparators),
        ]
    }

    private static func rustRules() -> [Rule] {
        let keywords = "as|async|await|break|const|continue|crate|dyn|else|enum|extern|fn|for|if|impl|in|let|loop|match|mod|move|mut|pub|ref|return|self|Self|static|struct|super|trait|type|union|unsafe|use|where|while"
        let types = "bool|char|f32|f64|i8|i16|i32|i64|i128|isize|str|u8|u16|u32|u64|u128|usize|String|Vec|Option|Result|Box|Rc|Arc"
        return [
            Rule(#"\b(\d+\.?\d*[_]?[fiu]?\d*)\b"#, number),
            Rule("\\b(\(keywords))\\b", keyword),
            Rule("\\b(\(types))\\b", type),
            Rule(#"\b(true|false|None|Some|Ok|Err)\b"#, keyword),
            Rule(#"#\[[\w(,= ]*\]"#, annotation),
            Rule(#""(?:[^"\\]|\\.)*""#, string),
            Rule(#"//.*$"#, comment, options: .anchorsMatchLines),
            Rule(#"/\*[\s\S]*?\*/"#, comment, options: .dotMatchesLineSeparators),
        ]
    }

    private static func cRules() -> [Rule] {
        let keywords = "auto|break|case|char|const|continue|default|do|double|else|enum|extern|float|for|goto|if|inline|int|long|register|restrict|return|short|signed|sizeof|static|struct|switch|typedef|union|unsigned|void|volatile|while|class|namespace|template|typename|using|public|private|protected|virtual|override|new|delete|try|catch|throw|nullptr"
        return [
            Rule(#"\b(\d+\.?\d*[fFlLuU]*)\b"#, number),
            Rule(#"\b(0x[0-9a-fA-F]+[uUlL]*)\b"#, number),
            Rule("\\b(\(keywords))\\b", keyword),
            Rule(#"\b(true|false|NULL|nullptr)\b"#, keyword),
            Rule(#"#\w+"#, annotation),
            Rule(#""(?:[^"\\]|\\.)*""#, string),
            Rule(#"'(?:[^'\\]|\\.)*'"#, string),
            Rule(#"//.*$"#, comment, options: .anchorsMatchLines),
            Rule(#"/\*[\s\S]*?\*/"#, comment, options: .dotMatchesLineSeparators),
        ]
    }

    private static func rubyRules() -> [Rule] {
        let keywords = "alias|and|begin|break|case|class|def|defined|do|else|elsif|end|ensure|for|if|in|module|next|not|or|redo|rescue|retry|return|self|super|then|undef|unless|until|when|while|yield"
        return [
            Rule(#"\b(\d+\.?\d*)\b"#, number),
            Rule("\\b(\(keywords))\\b", keyword),
            Rule(#"\b(true|false|nil)\b"#, keyword),
            Rule(#":\w+"#, annotation),
            Rule(#""(?:[^"\\]|\\.)*""#, string),
            Rule(#"'(?:[^'\\]|\\.)*'"#, string),
            Rule(#"#.*$"#, comment, options: .anchorsMatchLines),
        ]
    }

    private static func shellRules() -> [Rule] {
        let keywords = "if|then|else|elif|fi|for|while|do|done|case|esac|in|function|return|local|export|readonly|declare|typeset|unset|shift|break|continue|eval|exec|exit|trap|source"
        return [
            Rule(#"\b(\d+\.?\d*)\b"#, number),
            Rule("\\b(\(keywords))\\b", keyword),
            Rule(#"\$\w+"#, type),
            Rule(#"\$\{[^}]+\}"#, type),
            Rule(#""(?:[^"\\]|\\.)*""#, string),
            Rule(#"'[^']*'"#, string),
            Rule(#"#.*$"#, comment, options: .anchorsMatchLines),
        ]
    }

    private static func jsonRules() -> [Rule] {
        return [
            Rule(#""(?:[^"\\]|\\.)*"\s*:"#, type),  // keys
            Rule(#":\s*"(?:[^"\\]|\\.)*""#, string), // string values
            Rule(#"\b(\d+\.?\d*)\b"#, number),
            Rule(#"\b(true|false|null)\b"#, keyword),
        ]
    }

    private static func yamlRules() -> [Rule] {
        return [
            Rule(#"^[\w.-]+(?=\s*:)"#, type, options: .anchorsMatchLines), // keys
            Rule(#"\b(\d+\.?\d*)\b"#, number),
            Rule(#"\b(true|false|null|yes|no|on|off)\b"#, keyword),
            Rule(#""(?:[^"\\]|\\.)*""#, string),
            Rule(#"'[^']*'"#, string),
            Rule(#"#.*$"#, comment, options: .anchorsMatchLines),
        ]
    }

    private static func tomlRules() -> [Rule] {
        return [
            Rule(#"\[[\w.-]+\]"#, type),             // section headers
            Rule(#"^[\w.-]+(?=\s*=)"#, type, options: .anchorsMatchLines), // keys
            Rule(#"\b(\d+\.?\d*)\b"#, number),
            Rule(#"\b(true|false)\b"#, keyword),
            Rule(#""(?:[^"\\]|\\.)*""#, string),
            Rule(#"'[^']*'"#, string),
            Rule(#"#.*$"#, comment, options: .anchorsMatchLines),
        ]
    }

    private static func xmlRules() -> [Rule] {
        return [
            Rule(#"</?[\w:-]+"#, keyword),            // tag names
            Rule(#"/?\s*>"#, keyword),                 // closing >
            Rule(#"\b[\w:-]+(?=\s*=)"#, type),        // attribute names
            Rule(#""[^"]*""#, string),                 // attribute values
            Rule(#"'[^']*'"#, string),
            Rule(#"<!--[\s\S]*?-->"#, comment, options: .dotMatchesLineSeparators),
        ]
    }
}
