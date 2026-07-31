import SwiftUI

extension Binding {
    /// A `Bool` binding for presenting something off optional state: true while a
    /// value is set, and clearing it when SwiftUI sets false.
    ///
    /// `alert(_:isPresented:)` needs to *write* to its binding on dismissal.
    /// `.constant(error != nil)` can't be written, so it only appeared to work
    /// because each alert's button cleared the state by hand — anything that
    /// dismissed without pressing a button left the state set, and the alert could
    /// then never be presented again.
    func presented<Wrapped>() -> Binding<Bool> where Value == Wrapped? {
        Binding<Bool>(
            get: { wrappedValue != nil },
            set: { isPresented in
                if !isPresented { wrappedValue = nil }
            }
        )
    }
}
