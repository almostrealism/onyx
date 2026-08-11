import SwiftUI

/// Favorites as a treemap of nested block buttons.
///
/// Every box is clickable, including the containers: a box is a folder,
/// and the ones the user didn't explicitly save (implicit containers,
/// drawn dimmer) still navigate there. Children are drawn after their
/// parent so they sit on top and take the clicks inside their own area.
struct FavoritesTreemap: View {
    let nodes: [FavoriteTreeNode]
    let selectedPath: String?
    let accent: Color
    let onOpen: (String) -> Void
    let onRemove: (String) -> Void

    var body: some View {
        GeometryReader { geo in
            let boxes = FavoriteTreemapLayout.place(
                nodes, in: CGRect(origin: .zero, size: geo.size))
            ZStack(alignment: .topLeading) {
                ForEach(boxes) { box in
                    cell(box)
                        .frame(width: max(0, box.rect.width),
                               height: max(0, box.rect.height))
                        .offset(x: box.rect.minX, y: box.rect.minY)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private func cell(_ box: PlacedFavorite) -> some View {
        let selected = box.path == selectedPath
        // Containers get a header-only hit area (their children own the
        // rest); leaves are clickable edge to edge.
        VStack(spacing: 0) {
            Button(action: { onOpen(box.path) }) {
                HStack(spacing: 4) {
                    Image(systemName: box.hasChildren ? "folder" : "folder.fill")
                        .font(.system(size: box.hasChildren ? 9 : 10))
                        .foregroundColor(iconColor(box, selected: selected))
                    Text(box.label)
                        .font(.system(size: box.hasChildren ? 10 : 11,
                                      weight: box.isFavorite ? .regular : .light,
                                      design: .monospaced))
                        .foregroundColor(textColor(box, selected: selected))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 6)
                .frame(height: box.hasChildren ? FavoriteTreemapLayout.headerHeight : nil)
                .frame(maxWidth: .infinity,
                       maxHeight: box.hasChildren ? nil : .infinity,
                       alignment: box.hasChildren ? .leading : .topLeading)
                .padding(.top, box.hasChildren ? 0 : 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if box.hasChildren { Spacer(minLength: 0) }
        }
        .background(background(box, selected: selected))
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(borderColor(box, selected: selected), lineWidth: selected ? 1 : 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .help(box.isFavorite ? box.path : "\(box.path) — shown to tell apart same-named favorites")
        .contextMenu {
            Button("Open") { onOpen(box.path) }
            if box.isFavorite {
                Button("Remove from favorites", role: .destructive) { onRemove(box.path) }
            }
        }
    }

    @ViewBuilder
    private func background(_ box: PlacedFavorite, selected: Bool) -> some View {
        if selected {
            RoundedRectangle(cornerRadius: 5).fill(accent.opacity(0.18))
        } else if box.hasChildren {
            // Containers sit *behind* their children — keep them dark so
            // nested boxes read as being inside them.
            RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(box.isFavorite ? 0.05 : 0.03))
        } else {
            RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(box.isFavorite ? 0.08 : 0.04))
        }
    }

    private func borderColor(_ box: PlacedFavorite, selected: Bool) -> Color {
        if selected { return accent.opacity(0.6) }
        if box.hasChildren { return Color.white.opacity(0.08) }
        return Color.white.opacity(0.05)
    }

    private func iconColor(_ box: PlacedFavorite, selected: Bool) -> Color {
        if selected { return accent }
        return box.isFavorite ? .gray.opacity(0.55) : .gray.opacity(0.35)
    }

    private func textColor(_ box: PlacedFavorite, selected: Bool) -> Color {
        if selected { return accent }
        return box.isFavorite ? .white.opacity(0.85) : .white.opacity(0.5)
    }
}
