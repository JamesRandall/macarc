import CGtk
import Observation

/// Keeps GTK widgets in step with `@Observable` models, as SwiftUI does:
/// `update` runs now, and again each time something it read changes, for as
/// long as `owner` is around.
@MainActor
final class Observer {
    private weak var owner: AnyObject?
    private let update: @MainActor () -> Void

    @discardableResult
    init(_ owner: AnyObject, _ update: @escaping @MainActor () -> Void) {
        self.owner = owner
        self.update = update
        run()
    }

    private func run() {
        guard owner != nil else { return }
        withObservationTracking {
            update()
        } onChange: {
            // (Called before the change is made, possibly mid-update.)
            Task { @MainActor in self.run() }
        }
    }
}

/// Runs `update` now and whenever what it reads changes, while `owner` lives.
@MainActor
func observe(_ owner: AnyObject, _ update: @escaping @MainActor () -> Void) {
    Observer(owner, update)
}

/// What a widget's observers hang on to: it lives as long as the widget.
@MainActor
private final class WidgetLifetime {
    static var count = 0
}

/// Runs `update` now and whenever what it reads changes, while `widget` is
/// around (GTK's widgets aren't Swift objects to own an observer).
@MainActor
func observe(widget: some GPointer, _ update: @escaping @MainActor () -> Void) {
    let lifetime = WidgetLifetime()
    WidgetLifetime.count += 1
    g_object_set_data_full(widget.object, "linuxarch-observer-\(WidgetLifetime.count)",
                           Unmanaged.passRetained(lifetime).toOpaque(), releaseBoxNotify)
    observe(lifetime, update)
}
