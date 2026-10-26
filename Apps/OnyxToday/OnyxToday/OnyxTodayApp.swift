//
// OnyxTodayApp.swift
//
// The iOS app: Onyx Today on an iPhone (and, for now, an iPad). All of it
// lives in the package (OnyxToday, OnyxUI, OnyxCore, OnyxSSH); this is
// only the entry point and the few things only an app can do — know the
// device's name, hear the pairing link, and see the scene come and go.
//

import SwiftUI
import UIKit
import OnyxCore
import OnyxToday

@main
struct OnyxTodayApp: App {
    @StateObject private var model: TodayModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // "Last written by Michael's iPhone" in the Macs' status line.
        SharedStateSync.deviceName = UIDevice.current.name
        _model = StateObject(wrappedValue: TodayModel())
    }

    var body: some Scene {
        WindowGroup {
            TodayRoot(model: model)
                .onOpenURL { model.open($0) }
        }
        .onChange(of: scenePhase) { _, phase in
            model.setFrontmost(phase == .active)
        }
    }
}
