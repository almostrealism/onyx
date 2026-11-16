//
// PRLabels.swift
//
// Responsibility: A PR's labels, drawn two ways — as named chips in the
//                 detailed overlay, and as bare colored dots where a line
//                 has no room for a word (simple mode, the Today page).
//                 Which labels appear is LabelFilterStore's.
//
import SwiftUI
import OnyxCore

/// Labels in their own colors, each a dot and its name, in one row. The
/// overlay wraps them instead (`PRLabelChip` in a flow layout).
public struct PRLabelChips: View {
    let labels: [PRLabel]

    public init(labels: [PRLabel]) {
        self.labels = labels
    }

    public var body: some View {
        HStack(spacing: 4) {
            ForEach(labels, id: \.name) { PRLabelChip(label: $0) }
        }
    }
}

/// One label: its dot — the same dot simple mode shows alone, so the two
/// layouts read as one — and its name, never truncated.
public struct PRLabelChip: View {
    let label: PRLabel

    public init(label: PRLabel) {
        self.label = label
    }

    public var body: some View {
        HStack(spacing: 3) {
            PRLabelDot(label: label)
            Text(label.name)
                .monitorFont(size: 9)
                .foregroundColor(.white.opacity(0.8))
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        // The label's own color, faint enough that white text on any of
        // them stays legible — forges allow black and yellow alike.
        .background(Color(hex: label.colorHex).opacity(0.18))
        .overlay(RoundedRectangle(cornerRadius: 3)
            .stroke(Color(hex: label.colorHex).opacity(0.55), lineWidth: 0.5))
        .cornerRadius(3)
    }
}

/// Labels as color alone: a row of tiny dots. Whatever holds them names
/// them on hover.
public struct PRLabelDots: View {
    let labels: [PRLabel]

    public init(labels: [PRLabel]) {
        self.labels = labels
    }

    public var body: some View {
        HStack(spacing: 3) {
            ForEach(labels, id: \.name) { PRLabelDot(label: $0) }
        }
    }
}

/// One label's color, at the size of the session list's Claude mark.
public struct PRLabelDot: View {
    let label: PRLabel
    var size: CGFloat = 6

    public init(label: PRLabel, size: CGFloat = 6) {
        self.label = label
        self.size = size
    }

    public var body: some View {
        Circle()
            .fill(Color(hex: label.colorHex))
            // A hairline ring, so a black or navy label still shows up on
            // the overlay's black.
            .overlay(Circle().stroke(Color.white.opacity(0.25), lineWidth: 0.5))
            .frame(width: size, height: size)
    }
}
