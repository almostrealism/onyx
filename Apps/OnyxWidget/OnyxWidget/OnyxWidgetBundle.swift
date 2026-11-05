//
// OnyxWidgetBundle.swift
//
// The session widget extension's entry point. Everything else — the
// timeline, the views, the snapshot it reads — is OnyxWidgetKit, in the
// package, where the app and the tests can reach it too.
//

import SwiftUI
import WidgetKit
import OnyxWidgetKit

@main
struct OnyxWidgetBundle: WidgetBundle {
    var body: some Widget {
        OnyxSessionsWidget()
    }
}
