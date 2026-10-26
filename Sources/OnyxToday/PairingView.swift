//
// PairingView.swift
//
// Responsibility: The first thing a new phone shows: how it gets the key
//                 to the home host — from iCloud Keychain on its own, or
//                 from the Mac's pairing code.
// Scope: Shown until the phone has a home host.
//

import SwiftUI
import OnyxCore
import OnyxUI

struct PairingView: View {
    @ObservedObject var model: TodayModel
    @State private var code = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("ONYX TODAY")
                    .monitorFont(size: 14, weight: .medium)
                    .foregroundColor(Color.onyxBlue)
                    .tracking(3)

                Text("Your reminders, calendar, open PRs, pipelines and hours — the side panel of Onyx's simple mode, on your phone.")
                    .monitorFont(size: 12)
                    .foregroundColor(.white.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)

                step(1, "On your Mac, open Onyx → Settings → Shared state, choose a home host, and turn on Sync to iPhone and iPad.")
                step(2, "This phone picks it up from iCloud Keychain within a minute or so. Nothing else to do.")
                step(3, "If it doesn't — or your Mac's Onyx says it can't use iCloud Keychain — click Show pairing code there and point this phone's camera at it, or copy it and paste it here.")

                TextField("onyx1:…", text: $code, axis: .vertical)
                    .monitorFont(size: 11)
                    .codeEntry()
                    .lineLimit(3...6)
                    .padding(10)
                    .background(Color.white.opacity(0.06))
                    .cornerRadius(6)

                HStack(spacing: 14) {
                    PasteButton(payloadType: String.self) { strings in
                        guard let first = strings.first else { return }
                        DispatchQueue.main.async {
                            code = first
                            model.pair(with: first)
                        }
                    }
                    .labelStyle(.titleAndIcon)
                    Button("Pair") { model.pair(with: code) }
                        .disabled(code.isEmpty)
                    Spacer()
                    Button("Check iCloud") { model.adoptHomeFromKeychain() }
                }
                .monitorFont(size: 12)

                if let problem = model.pairingProblem {
                    Text(problem)
                        .monitorFont(size: 10)
                        .foregroundColor(Color.onyxRed.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("The code holds the key to your home host. It's stored in this phone's keychain and nowhere else.")
                    .monitorFont(size: 9)
                    .foregroundColor(.gray.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(22)
        }
        .background(Color.black.ignoresSafeArea())
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(n)")
                .monitorFont(size: 12, weight: .medium)
                .foregroundColor(Color.onyxBlue)
            Text(text)
                .monitorFont(size: 11)
                .foregroundColor(.white.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
