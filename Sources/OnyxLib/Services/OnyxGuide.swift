//
// OnyxGuide.swift
//
// Responsibility: What Onyx tells an agent about how to use Onyx.
// Scope: Service. Static text and the index over it — no state, no I/O.
//
// Why this exists: tool descriptions answer "what does this one do", and
// nothing answered "what can I build with these together". An agent
// asked to produce a report and then tell the user about it has to
// discover that publishing and alerting are two calls that pair, that
// slots persist, and that a remote agent can't hand over a file path.
// None of that fits in a parameter description.
//
// The topics are written for an agent mid-task, not for a person
// browsing docs: short, concrete, and each ending in the shape of a
// call. A guide nobody finishes reading is a guide that didn't work.
//

import Foundation

public enum OnyxGuide {

    public struct Topic {
        public let id: String
        public let summary: String
        public let body: String
    }

    public static let topics: [Topic] = [
        Topic(
            id: "overview",
            summary: "What Onyx is and which tool does what",
            body: """
            Onyx is the terminal the user is working in. It keeps their SSH sessions \
            alive, and it has a panel beside the terminal and an overlay above it where \
            things can be SHOWN to them. You are probably running inside one of its \
            sessions right now.

            Two things it gives you that a terminal does not:

            1. A place to put something the user should look at, which survives after \
            your output has scrolled away — `show_html`, `show_text`, `show_diagram`, \
            `show_model`, in one of eight numbered slots.
            2. A way to get their attention when they are not watching — `notify`.

            They pair. Publish first, then notify, so the thing you are pointing at is \
            already there when they look.

            Topics: artifacts, alerts, sessions, recipes, skills.

            Before writing to a slot, `list_slots` shows what is already there.
            """
        ),

        Topic(
            id: "artifacts",
            summary: "Showing the user something: slots, HTML, text, diagrams",
            body: """
            Eight slots, 0-7, each holding one artifact. Writing to a slot replaces what \
            was there; the user can switch between slots and the content stays until \
            replaced. Pick a slot and keep using it for the same kind of thing, so a \
            second report does not destroy the first.

            `show_html` — a rendered page. The right choice for anything with structure: \
            a status summary, a table of results, a report linking to what it describes. \
            Links open in the user's browser, so link to each item you mention. A full \
            document is shown exactly as you wrote it; a fragment is wrapped in the app's \
            dark styling. The panel is dark — if you write a full document assuming a \
            white background, set one.

            `show_text` — code or prose, with syntax highlighting. Use it for a file or a \
            diff, not for a report you have formatted yourself.

            `show_diagram` — mermaid or plantuml. Prefer top-down: the panel is a tall \
            column, not a wide one.

            `show_model` — a 3D model, when that is what you have.

            `analyze_deps` — points at a Java source tree and draws its dependency graph \
            into a slot, instead of you listing the edges as text.

            `list_slots` — what is already on screen. Worth a call before you pick a \
            slot, so you replace your own last report rather than something the user is \
            still reading. `clear_slot` empties one when its contents have gone stale.

            IF YOU ARE ON A REMOTE HOST, which you usually are: Onyx reads files on the \
            machine IT runs on, not the machine you are on. Pass `content`, not `file`. A \
            path that works for you either fails or, worse, finds a different file with \
            the same name.
            """
        ),

        Topic(
            id: "alerts",
            summary: "Getting the user's attention with notify",
            body: """
            `notify` puts a message in front of the user. Send one when you are blocked, \
            when you have finished something they are waiting on, or when you need a \
            decision. Do not send one for progress they did not ask for.

            Two flags escalate, and they mean different things:

            - Neither: a quiet indicator next to the session. They will see it when they \
            look.
            - `external`: delivered outside Onyx as well, so it arrives when the app is \
            not in front. On macOS, Notification Center.
            - `urgent`: interrupts. On macOS, the dock icon bounces until they come back. \
            Reserve it for "I cannot continue without you".

            Say WHERE you are, so the alert lands against your session rather than in a \
            general list: `user`, `host`, `session`. See the sessions topic for how to \
            find those. You do not need all three — one unambiguous detail is enough. \
            The reply tells you whether it matched; if it says nothing matched, ask the \
            user which session they see your work in rather than guessing again.

            Write the title for someone glancing at it. "Migration finished, 3 conflicts \
            need a decision" is useful; "done" is not.
            """
        ),

        Topic(
            id: "sessions",
            summary: "Telling Onyx which session you are in",
            body: """
            Onyx keys work by remote user, host and tmux session name. To find yours:

                whoami                            -> user
                hostname                          -> host
                tmux display-message -p '#S'      -> session

            Pass those to `notify`. The host should be how the USER refers to the \
            machine; a short name and a fully-qualified one both match.

            If you cannot work them out — no tmux, an unusual setup — ask the user. \
            "Which Onyx session am I running in?" is a reasonable question, and they can \
            tell you the session name from the list in the app.

            Alerts that name a session appear next to that session's note in the \
            monitoring overlay, which is where the user looks to see which of their \
            terminals needs them.
            """
        ),

        Topic(
            id: "recipes",
            summary: "Worked shapes: report-and-tell, long job, decision needed",
            body: """
            REPORT, THEN POINT AT IT. The common one. Do the work, publish the result, \
            then say it is ready:

                show_html(slot: 1, title: "Review: 12 open MRs", content: "<full page>")
                notify(title: "Review ready — 4 need you, 8 waiting on authors",
                       session: "<your tmux session>", external: true)

            Publish BEFORE notifying, so the page is there when they look.

            A LONG JOB. Do not narrate. One notify at the end, `external` so it reaches \
            them wherever they are:

                notify(title: "Training finished — 94.1% on the holdout set",
                       session: "trainer", external: true)

            A DECISION. This is what `urgent` is for, because you are stopped:

                notify(title: "Migration needs a decision: 3 conflicting rows",
                       body: "Keep the newer row, keep both, or stop?",
                       session: "migrate", urgent: true, external: true)

            Pair it with a page when the decision needs detail — publish the conflicts \
            with `show_html`, then notify pointing at the slot.
            """
        ),

        Topic(
            id: "skills",
            summary: "Writing a reusable skill that uses Onyx",
            body: """
            When the user asks for a skill or command that "shows me" something, the \
            Onyx part is the last two steps: build the artifact, publish it, notify.

            Make the skill do this:

            1. Gather whatever it reports on, using the normal CLI for that system \
            (`glab`, `gh`, `kubectl` — whatever they already have authenticated).
            2. Build one self-contained HTML document. Group it by what the USER has to \
            do: things waiting on them first, things waiting on someone else after. \
            Link every item to its source so a row is one click from the real thing.
            3. `show_html` it into a fixed slot, so re-running replaces the last run \
            rather than scattering results.
            4. `notify` with a title that carries the headline number, and the session \
            name so it lands in the right place.

            Two things to bake in, because they are easy to get wrong once and then wrong \
            forever: pass the page as `content` (the skill will usually run on a remote \
            host), and style the document for a dark panel.

            Write the slot number and the session name into the skill as parameters with \
            sensible defaults, so the user can run two of them at once without one \
            overwriting the other.
            """
        ),
    ]

    public static var index: [String] { topics.map(\.id) }

    public static func topic(_ id: String?) -> Topic {
        guard let id = id?.trimmingCharacters(in: .whitespaces).lowercased(), !id.isEmpty,
              let found = topics.first(where: { $0.id == id }) else {
            return topics[0]
        }
        return found
    }

    /// What a request for an unknown topic gets: the overview plus the
    /// list, rather than an error. An agent guessing a topic name should
    /// land somewhere useful.
    public static func response(for id: String?) -> String {
        let topic = topic(id)
        let known = topics.map { "  \($0.id) — \($0.summary)" }.joined(separator: "\n")
        return """
        # \(topic.id)

        \(topic.body)

        ---
        Other topics:
        \(known)
        """
    }
}
