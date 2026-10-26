import SwiftUI
import OnyxCore
import OnyxUI

// MARK: - Pointing at features where they're used
//
// See FeatureCatalog for why. A tip is one line, at the spot where the
// feature lives, until it's used or closed.

// MARK: - What's New

/// Once after an update: what arrived since this person last looked, with
/// "Show me" for the ones that can be put on screen. Closing it by any
/// route counts as seen.
struct WhatsNewOverlay: View {
    @ObservedObject var appState: AppState

    private var accent: Color { appState.accentColor }

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .onTapGesture { appState.closeWhatsNew() }

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("WHAT'S NEW IN ONYX")
                        .font(.system(size: appState.uiSize(11), weight: .medium, design: .monospaced))
                        .foregroundColor(accent)
                        .tracking(3)
                    Spacer()
                    if let since = appState.whatsNewFeatures.first?.since {
                        Text(since)
                            .font(.system(size: appState.uiSize(10), design: .monospaced))
                            .foregroundColor(.gray.opacity(0.4))
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 14)

                Divider().background(Color.white.opacity(0.06))

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(appState.whatsNewFeatures) { row($0) }
                    }
                    .padding(24)
                }
                .frame(maxHeight: 520)

                Divider().background(Color.white.opacity(0.06))

                HStack {
                    Text("Tips marked NEW point at these where they're used. ⌘/ lists every key.")
                        .font(.system(size: appState.uiSize(10), design: .monospaced))
                        .foregroundColor(.gray.opacity(0.45))
                    Spacer()
                    Button(action: { appState.closeWhatsNew() }) {
                        Text("Got it")
                            .font(.system(size: appState.uiSize(11), weight: .medium, design: .monospaced))
                            .foregroundColor(.black.opacity(0.85))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(accent)
                            .cornerRadius(5)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
            }
            .frame(width: 600)
            .background(Color.black.opacity(0.92))
            .cornerRadius(12)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.08), lineWidth: 1))
            .shadow(color: .black.opacity(0.5), radius: 30)
        }
    }

    private func row(_ feature: Feature) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(feature.title)
                    .font(.system(size: appState.uiSize(14), weight: .semibold))
                    .foregroundColor(.white.opacity(0.92))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if AppState.demonstrableFeatures.contains(feature.id) {
                    Button(action: { appState.demonstrateFeature(feature.id) }) {
                        Text("Show me →")
                            .font(.system(size: appState.uiSize(10), weight: .medium, design: .monospaced))
                            .foregroundColor(accent)
                    }
                    .buttonStyle(.plain)
                }
            }
            Text(feature.detail)
                .font(.system(size: appState.uiSize(12)))
                .foregroundColor(.white.opacity(0.6))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            if !feature.keys.isEmpty {
                HStack(spacing: 6) {
                    ForEach(feature.keys, id: \.self) { key in
                        Text(key)
                            .font(.system(size: appState.uiSize(10), weight: .medium, design: .monospaced))
                            .foregroundColor(accent)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(accent.opacity(0.10))
                            .cornerRadius(4)
                    }
                }
            }
        }
    }
}
