//
// OnyxVersion.swift
//
// Responsibility: The version number. All of it. For everything.
// Scope: Its own target, because the two things that must agree — the app
//        and the OnyxMCP bridge — cannot import each other. OnyxMCP builds
//        on Linux and depends on nothing else; this stays that way (no
//        Foundation, no platform code) so that remains true.
//
// Why a whole target for one string: the bridge used to carry its own
// number and drifted to 0.17 while the app shipped as 0.16, so "which
// bridge goes with which app" had no answer. Anything a human has to
// remember to update in two places is a thing that will be right until the
// day it matters.
//
// Bumping it: change this, and the app bundle, the bridge's --version, the
// per-host "update available" check and the release tag all follow.
// package.sh, install.sh and release.sh READ this file rather than
// carrying their own copy; release.sh refuses to tag a version that
// disagrees with it.
//

public enum OnyxVersion {
    /// The version this source tree builds. Matches the git tag at a
    /// release, and is the version a build from an untagged tree claims to
    /// be working toward.
    public static let current = "0.17"

    /// What the bridge and the app have agreed between themselves, bumped
    /// whenever that agreement changes.
    ///
    /// Separate from `current` because the release number can't answer the
    /// question the installer actually has. The drifting bridge already
    /// shipped calling itself 0.17 — including builds that answered
    /// notifications and broke the connection — so "is this bridge the one
    /// that goes with this app" cannot be settled by comparing release
    /// numbers, whatever we number the next release.
    ///
    /// A bridge states it in `--version`; one that states nothing predates
    /// the idea and is by definition too old. That makes the check work
    /// without burning a version number to route around our own mistake.
    ///
    /// 1 — the original: answered notifications, waited for replies to them.
    /// 2 — notifications are one-way in both directions.
    public static let bridgeProtocol = 2
}
