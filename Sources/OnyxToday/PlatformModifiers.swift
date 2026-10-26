//
// PlatformModifiers.swift
//
// Responsibility: The few iOS-only touches the Today views use, as
//                 modifiers that are no-ops on a Mac — OnyxToday builds for
//                 both, so `swift build` checks it on every commit.
//

import SwiftUI

extension View {
    /// A field for a code or a token: no capitals, no autocorrect.
    func codeEntry() -> some View {
        #if os(iOS)
        return self.textInputAutocapitalization(.never).autocorrectionDisabled()
        #else
        return self.autocorrectionDisabled()
        #endif
    }

    /// A sheet's title, small.
    func inlineNavigationTitle() -> some View {
        #if os(iOS)
        return self.navigationBarTitleDisplayMode(.inline)
        #else
        return self
        #endif
    }
}
