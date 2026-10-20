import SwiftUI
import AppKit

/// The draggable edge between the terminal and the side panel.
///
/// It used to be a 1pt line at 15% opacity — draggable, but nothing said
/// so, and users asked for a way to resize the panel. So it shows a grip
/// in the middle, lights up under the pointer, and says what it does when
/// hovered. Double-click puts the panel back to its default width.
struct PanelDivider: View {
    let accent: Color
    /// The window's width and where it sits on screen, to turn the
    /// pointer's position into the panel's share.
    let containerWidth: CGFloat
    let containerMinX: CGFloat
    @Binding var fraction: CGFloat
    /// Called once a drag or a reset is over, to remember the width.
    let onCommit: () -> Void

    @State private var hovering = false
    @State private var dragging = false

    private var lit: Bool { hovering || dragging }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(accent.opacity(lit ? 0.6 : 0.22))
                .frame(width: lit ? 2 : 1)

            // The grip: a pill with three dots, so the edge reads as
            // something you can take hold of.
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.black.opacity(0.85))
                .overlay(RoundedRectangle(cornerRadius: 3)
                    .stroke(accent.opacity(lit ? 0.8 : 0.35), lineWidth: 1))
                .overlay(
                    VStack(spacing: 3) {
                        ForEach(0..<3, id: \.self) { _ in
                            Circle().fill(accent.opacity(lit ? 0.9 : 0.5))
                                .frame(width: 2.5, height: 2.5)
                        }
                    }
                )
                .frame(width: 7, height: 30)
        }
        .frame(width: 10)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.12), value: lit)
        .onHover { inside in
            hovering = inside
            if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
        }
        .help("Drag to resize the panel · double-click for the default width · ⌘\\ steps through widths")
        .onTapGesture(count: 2) {
            withAnimation(.easeInOut(duration: 0.2)) {
                fraction = CGFloat(PanelSplit.defaultFraction)
            }
            onCommit()
        }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    dragging = true
                    let x = Double(value.location.x - containerMinX)
                    fraction = CGFloat(PanelSplit.fraction(dividerAt: x, width: Double(containerWidth)))
                }
                .onEnded { _ in
                    dragging = false
                    onCommit()
                }
        )
    }
}
