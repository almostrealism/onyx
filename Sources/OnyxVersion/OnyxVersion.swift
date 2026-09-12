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
// 0.17 is skipped deliberately. The bridge already claimed it, including
// the builds with the notification bug, so a host reporting "0.17" is
// ambiguous — it could be either. 0.18 is the first version where the
// number means one thing.
//

public enum OnyxVersion {
    /// The version this source tree builds. Matches the git tag at a
    /// release, and is the version a build from an untagged tree claims to
    /// be working toward.
    public static let current = "0.18"
}
