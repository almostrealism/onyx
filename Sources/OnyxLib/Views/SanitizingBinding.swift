import SwiftUI

extension Binding where Value == String {
    /// Wraps a string binding so any macOS smart-quote / smart-dash / ellipsis
    /// substitution is stripped on every write — stylized characters can never
    /// land in the bound value, even when pasted in. Pair with the app-wide
    /// substitution disable in AppDelegate (which prevents them while typing);
    /// this is the guaranteed catch for everything else.
    func sanitizingStylizedText() -> Binding<String> {
        Binding(
            get: { wrappedValue },
            set: { newValue in
                let clean = TextSanitizer.sanitize(newValue)
                if clean != wrappedValue { wrappedValue = clean }
            }
        )
    }
}
