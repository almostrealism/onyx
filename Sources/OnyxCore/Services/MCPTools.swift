//
// MCPTools.swift
//
// Responsibility: What each Onyx MCP tool is called, says it does and
//                 takes — the definitions an agent reads to decide whether
//                 to call one. Every Onyx that answers the bridge (the Mac,
//                 the iPad) lists from here, so the words can't drift.
// Scope: Service. Data.
//

import Foundation

public enum MCPTools {

    /// Listed by the desktop so the tool list is identical whether an agent
    /// sees it through the bridge or not. The bridge answers this one
    /// ITSELF, from the host's own records, and never forwards it — which
    /// is the point: it must work when the desktop can't be reached. A
    /// call that does arrive here came over a direct connection, and the
    /// only honest answer is that the desktop is, evidently, reachable.
    public static var statusTool: AnyCodableValue {
        .object([
            "name": .string("onyx_status"),
            "description": .string("""
                Is Onyx reachable from this host, and if not, why not and since when. Call \
                this FIRST when any other Onyx tool fails or when the Onyx tools seem to be \
                missing: it answers from this host's own records — which desktops have ever \
                answered from here, when each was last heard from, what the last attempt \
                saw, and whether alerts are queued — and never needs the desktop to be running.
                """),
            "inputSchema": .object([
                "type": .string("object"),
                "properties": .object([:])
            ])
        ])
    }

    /// Ask for the user's attention.
    ///
    /// The description has to earn its place: an agent decides whether to
    /// call this from these words alone. It states what the two flags
    /// MEAN, mentions what a Mac does with them without making the tool
    /// Apple-shaped, and explains that naming the session is what puts
    /// the indicator next to the right piece of work.
    public static var notifyTool: AnyCodableValue {
        .object([
            "name": .string("notify"),
            "description": .string("""
                Tell the user you need them — you are blocked, you finished something they \
                are waiting on, or something needs a decision. The message appears in Onyx \
                against the session it came from.

                Alerts are URGENT BY DEFAULT, and you should leave it that way. Urgent is \
                what actually reaches a person: the dock bounces, and depending on how the \
                user has set up this Mac and their phone, it goes to Notification Center and \
                to their wrist. A non-urgent alert is a quiet indicator next to the session \
                and nothing more — if the user is not looking at Onyx at that moment, they \
                will not know it exists. Set `urgent: false` ONLY when the user has told you \
                to keep quiet and just keep a record of what is going on.

                Where the alert is delivered — Notification Center, phone, watch — is the \
                user's choice in Onyx's settings, per machine. It is not something you \
                decide per call, and there is no flag for it.

                Say which session you are in: host and tmux session name are enough, and \
                are what is trusted. If you do not know, the user can tell you.

                If the reply says the alert was QUEUED, read it: a desktop that answered a \
                minute ago is between contacts, not gone, and the alert lands on its next \
                contact — treat that as delivered and do not tell the user it failed. Never \
                resend a queued alert.
                """),
            "inputSchema": .object([
                "type": .string("object"),
                "properties": .object([
                    "title": .object(["type": .string("string"),
                                      "description": .string("One line, written for someone glancing at it. \"Migration finished, needs review\" rather than \"done\".")]),
                    "body": .object(["type": .string("string"),
                                     "description": .string("Optional detail shown when they open the alert.")]),
                    "urgent": .object(["type": .string("boolean"),
                                       "description": .string("Default TRUE, and leave it true. False is a quiet indicator the user will only see if they happen to look — use it only when they have asked you not to be noisy and just to keep a record.")]),
                    "user": .object(["type": .string("string"),
                                     "description": .string("Optional. The account Onyx CONNECTED to this host as — usually the ssh login, which is NOT `whoami` if you were started with su or sudo -u. Host and session alone are enough and are what is trusted; a user that doesn't match is ignored, not fatal.")]),
                    "host": .object(["type": .string("string"),
                                     "description": .string("Host of the session this is about, as the user refers to it, e.g. from `hostname`.")]),
                    "session": .object(["type": .string("string"),
                                        "description": .string("tmux session name, e.g. from `tmux display-message -p \"#S\"`.")])
                ]),
                "required": .array([.string("title")])
            ])
        ])
    }

    /// How to use Onyx, on request.
    ///
    /// Listed FIRST in the description's own words — "start here" — for
    /// the same reason the tool exists: an agent asked to "show me a
    /// report in Onyx" has no way to know that publishing and alerting
    /// are two calls that pair, or that a remote agent cannot hand over a
    /// file path. Parameter descriptions can't carry that.
    public static var guideTool: AnyCodableValue {
        .object([
            "name": .string("onyx_guide"),
            "description": .string("""
                How to use Onyx in a workflow. Start here if the user has asked you to show \
                them something in Onyx, alert them, or build a skill or command that does \
                either — the other tools describe themselves individually, this explains how \
                they fit together and what to avoid.

                Call with no topic for the overview. Topics: \
                \(OnyxGuide.index.joined(separator: ", ")).
                """),
            "inputSchema": .object([
                "type": .string("object"),
                "properties": .object([
                    "topic": .object([
                        "type": .string("string"),
                        "enum": .array(OnyxGuide.index.map { .string($0) }),
                        "description": .string("Which topic. Omit for the overview.")
                    ])
                ]),
                "required": .array([])
            ])
        ])
    }

    /// Publish a rendered HTML page into a slot.
    ///
    /// Separate from show_text rather than a format flag on it, because
    /// this is the one agents need to FIND: "build a status page and show
    /// it to me" is a different intention from "display this text", and a
    /// tool named for it is what makes that discoverable.
    ///
    /// The description is blunt about the file/content split. An agent
    /// running on a remote host is talking to Onyx through a pipe — the
    /// app reads files from ITS OWN filesystem, so a path that exists
    /// where the agent is would silently fail to be found, or worse, find
    /// a different file of the same name.
    public static var showHTMLTool: AnyCodableValue {
        .object([
            "name": .string("show_html"),
            "description": .string("""
                Render an HTML page in an artifact slot beside the user's terminal. Use it \
                for anything that is better looked at than read in a chat: a status summary, \
                a table of results, a report with links to the things it describes.

                Links are clickable and open in the user's browser, so linking to each item \
                you describe is usually worth doing.

                Pass the page in `content`. Only use `file` when you are running on the SAME \
                machine as Onyx — the app reads the path on its own filesystem, so a path \
                from a remote host either fails or finds the wrong file. If you are on a \
                remote host, read the file yourself and send the text.

                A complete document is shown exactly as you wrote it, so style it however \
                you like; a bare fragment is wrapped in the app's own dark styling. The \
                panel is dark, so a page that assumes a white background should set one.

                Pair it with `notify` when the user needs to know the page is ready.
                """),
            "inputSchema": .object([
                "type": .string("object"),
                "properties": .object([
                    "slot": .object(["type": .string("integer"), "description": .string("Slot number 0-7"), "minimum": .int(0), "maximum": .int(7)]),
                    "title": .object(["type": .string("string"), "description": .string("Title shown above the page")]),
                    "content": .object(["type": .string("string"), "description": .string("The HTML. A full document or a fragment.")]),
                    "file": .object(["type": .string("string"), "description": .string("Absolute path to an HTML file — only when you are on the same machine as Onyx.")])
                ]),
                "required": .array([.string("slot"), .string("title")])
            ])
        ])
    }

    public static var showTextTool: AnyCodableValue {
        .object([
            "name": .string("show_text"),
            "description": .string("Display text, code, or markdown in an artifact slot. For code files, prefer using the file parameter to load directly — the client renders with syntax highlighting. Line wrapping is auto-detected from file extension (off for code, on for prose) but can be overridden with the wrap parameter."),
            "inputSchema": .object([
                "type": .string("object"),
                "properties": .object([
                    "slot": .object(["type": .string("integer"), "description": .string("Slot number 0-7"), "minimum": .int(0), "maximum": .int(7)]),
                    "title": .object(["type": .string("string"), "description": .string("Title for the artifact")]),
                    "content": .object(["type": .string("string"), "description": .string("Text content to display (optional if file is provided)")]),
                    "file": .object(["type": .string("string"), "description": .string("Absolute path to a file to load and display. The file extension is used for syntax highlighting and wrap detection.")]),
                    "format": .object(["type": .string("string"), "enum": .array([.string("plain"), .string("markdown"), .string("html")]), "description": .string("Text format (default: plain for files, markdown for content)")]),
                    "language": .object(["type": .string("string"), "description": .string("Language hint for syntax highlighting (e.g. java, swift, python). Auto-detected from file extension if not specified.")]),
                    "wrap": .object(["type": .string("boolean"), "description": .string("Enable line wrapping. Auto-detected if omitted: off for code, on for markdown/plain prose.")])
                ]),
                "required": .array([.string("slot"), .string("title")])
            ])
        ])
    }

    public static var showDiagramTool: AnyCodableValue {
        .object([
            "name": .string("show_diagram"),
            "description": .string("Render a UML or flowchart diagram in an artifact slot visible to the user. Prefer top-down (TD) layouts over left-right (LR) as the display area is a vertical panel. Pinch to zoom is supported."),
            "inputSchema": .object([
                "type": .string("object"),
                "properties": .object([
                    "slot": .object(["type": .string("integer"), "description": .string("Slot number 0-7"), "minimum": .int(0), "maximum": .int(7)]),
                    "title": .object(["type": .string("string"), "description": .string("Title for the diagram")]),
                    "content": .object(["type": .string("string"), "description": .string("Diagram source (Mermaid or PlantUML syntax)")]),
                    "format": .object(["type": .string("string"), "enum": .array([.string("mermaid"), .string("plantuml")]), "description": .string("Diagram format (default: mermaid)")])
                ]),
                "required": .array([.string("slot"), .string("title"), .string("content")])
            ])
        ])
    }

    public static var showModelTool: AnyCodableValue {
        .object([
            "name": .string("show_model"),
            "description": .string("Display a 3D model in an artifact slot visible to the user"),
            "inputSchema": .object([
                "type": .string("object"),
                "properties": .object([
                    "slot": .object(["type": .string("integer"), "description": .string("Slot number 0-7"), "minimum": .int(0), "maximum": .int(7)]),
                    "title": .object(["type": .string("string"), "description": .string("Title for the model")]),
                    "data": .object(["type": .string("string"), "description": .string("Base64-encoded model data")]),
                    "format": .object(["type": .string("string"), "enum": .array([.string("obj"), .string("usdz"), .string("stl")]), "description": .string("3D model format")])
                ]),
                "required": .array([.string("slot"), .string("title"), .string("data"), .string("format")])
            ])
        ])
    }

    public static var clearSlotTool: AnyCodableValue {
        .object([
            "name": .string("clear_slot"),
            "description": .string("Clear an artifact slot"),
            "inputSchema": .object([
                "type": .string("object"),
                "properties": .object([
                    "slot": .object(["type": .string("integer"), "description": .string("Slot number 0-7"), "minimum": .int(0), "maximum": .int(7)])
                ]),
                "required": .array([.string("slot")])
            ])
        ])
    }

    public static var listSlotsTool: AnyCodableValue {
        .object([
            "name": .string("list_slots"),
            "description": .string("List all occupied artifact slots and their contents"),
            "inputSchema": .object([
                "type": .string("object"),
                "properties": .object([:])
            ])
        ])
    }

    public static var analyzeDepsTool: AnyCodableValue {
        .object([
            "name": .string("analyze_deps"),
            "description": .string("Analyze the dependency graph between changed Java files in a git repo. Parses imports to find relationships between modified files (including unchanged intermediary files that connect them). Displays result as a Mermaid diagram in artifact slot 0. Requires python3 on the remote host."),
            "inputSchema": .object([
                "type": .string("object"),
                "properties": .object([
                    "repo_path": .object([
                        "type": .string("string"),
                        "description": .string("Absolute path to the git repository root")
                    ])
                ]),
                "required": .array([.string("repo_path")])
            ])
        ])
    }

    // MARK: - Tool Call Dispatch
}
