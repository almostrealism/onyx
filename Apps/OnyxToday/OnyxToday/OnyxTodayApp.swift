//
// OnyxTodayApp.swift
//
// The iOS app: Onyx Today on an iPhone, and Onyx — Today plus terminals on
// every shared host — on an iPad. All of it lives in the package
// (OnyxToday, OnyxPad, OnyxUI, OnyxCore, OnyxSSH); this is only the entry
// point and the few things only an app can do — know the device, hear the
// pairing link, and see the scenes come and go.
//

import SwiftUI
import UIKit
import OnyxCore
import OnyxToday
import OnyxPad

@main
struct OnyxTodayApp: App {
    @StateObject private var model: TodayModel
    @StateObject private var pad: PadModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // "Last written by Michael's iPhone" in the Macs' status line.
        SharedStateSync.deviceName = UIDevice.current.name
        let today = TodayModel()
        _model = StateObject(wrappedValue: today)
        _pad = StateObject(wrappedValue: PadModel(phone: today))
    }

    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    var body: some Scene {
        // One WindowGroup: on an iPad each window is a scene of its own,
        // with its own tabs; the hosts and sessions are shared.
        WindowGroup {
            Group {
                if isPad {
                    PadRoot(model: pad)
                } else {
                    TodayRoot(model: model)
                }
            }
            .onOpenURL { model.open($0) }
        }
        .onChange(of: scenePhase) { _, phase in
            if isPad { pad.setFrontmost(phase == .active) } else { model.setFrontmost(phase == .active) }
        }
    }
}
