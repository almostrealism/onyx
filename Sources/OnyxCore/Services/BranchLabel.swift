//
// BranchLabel.swift
//
// Responsibility: Fitting a git branch name into a few characters without
//                 losing the part that tells branches apart.
// Scope: Service. Pure string functions.
//
// Branch names are mostly a short, familiar prefix and a long, specific
// name: feature/, fix/, qa/, experiment/ come from a handful you know by
// heart, so three or four letters of one is as good as the whole word.
// The words after the last slash are what you can't reconstruct. So the
// prefixes give their characters up first, and if it still doesn't fit,
// the cut goes in the middle of the last segment — never through a
// prefix, which would spend scarce characters on the half you already
// know.
//
//   feature/delta-consolidation       → feat/delta-…dation
//   experiment/quant-welfare/phase-1  → expe/quan/phase-1
//

public enum BranchLabel {

    /// `branch` in at most `max` characters, or untouched when it fits.
    ///
    /// - Parameter prefixLength: what each segment before the last is cut
    ///   to, when cutting is needed.
    public static func compact(_ branch: String, max: Int = 18, prefixLength: Int = 4) -> String {
        guard branch.count > max else { return branch }

        var segments = branch.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let last = segments.removeLast()
        guard !segments.isEmpty else { return middleEllipsis(branch, max: max) }

        let lead = segments.map { String($0.prefix(prefixLength)) }.joined(separator: "/") + "/"
        if lead.count + last.count <= max { return lead + last }

        // The last segment gets what the prefixes leave — unless that's
        // too little to recognize anything by, in which case cut the
        // whole thing instead.
        let room = max - lead.count
        guard room >= minimumLastSegment else { return middleEllipsis(lead + last, max: max) }
        return lead + middleEllipsis(last, max: room)
    }

    /// Below this, a cut last segment is just noise ("a…b"), and spending
    /// the characters on the whole name says more.
    static let minimumLastSegment = 8

    /// `s` with its middle replaced by "…" to fit `max` characters — the
    /// start and the end being the parts that tell names apart. The start
    /// gets the odd character.
    public static func middleEllipsis(_ s: String, max: Int) -> String {
        guard s.count > max else { return s }
        guard max > 1 else { return String(s.prefix(max)) }
        let keep = max - 1
        return "\(s.prefix((keep + 1) / 2))…\(s.suffix(keep / 2))"
    }
}
