//
// ClaudeSessionManager+Mac.swift
//
// Responsibility: How the Mac gets noticed while an agent waits on a
//                 permission decision: the dock icon bounces.
//

import AppKit
import OnyxCore

extension ClaudeSessionManager {

    /// `.criticalRequest` keeps bouncing until the app is activated,
    /// which is right here: one bounce is easy to miss while you're in
    /// another window, and that's precisely when this happens. Nothing
    /// bounces when Onyx is already the active app — you can see the
    /// banner. Installed once, at launch.
    static let installDockBounce: Void = {
        var token: Int?
        shared.attention = (
            begin: {
                guard let app = NSApp, !app.isActive, token == nil else { return }
                token = app.requestUserAttention(.criticalRequest)
            },
            end: {
                guard let current = token else { return }
                NSApp?.cancelUserAttentionRequest(current)
                token = nil
            })
    }()
}
