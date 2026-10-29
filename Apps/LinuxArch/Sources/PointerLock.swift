import CGtk
import CWaylandPointer

/// Holds the pointer still over a widget and reports its movements, while
/// the mouse is captured: on Wayland, with the pointer-constraints protocol
/// (GTK has no pointer lock). Where the desktop can't, `isLocked` is false
/// and the view works from the pointer's positions instead.
@MainActor
final class PointerLock {
    private var lock: OpaquePointer?
    private var timer: GLibTimer?
    private let onMove: @MainActor (Double, Double) -> Void

    var isLocked: Bool { lock.map { la_pointer_lock_is_locked($0) } ?? false }

    init(widget: Widget, onMove: @escaping @MainActor (Double, Double) -> Void) {
        self.onMove = onMove
        let motion: la_relative_motion = { data, dx, dy in
            let lock = Unmanaged<PointerLock>.fromOpaque(data!).takeUnretainedValue()
            MainActor.assumeIsolated { lock.onMove(dx, dy) }
        }
        lock = la_pointer_lock_new(la_wayland_display(widget), la_wayland_surface(widget), la_wayland_pointer(widget),
                                   motion, Unmanaged.passUnretained(self).toOpaque())
        if lock != nil {
            // Its events, as they come (GDK reads them off the connection).
            timer = GLibTimer(interval: 0.004) { [weak self] in
                guard let self, let lock = self.lock else { return false }
                la_pointer_lock_dispatch(lock)
                return true
            }
        }
    }

    isolated deinit {
        timer?.invalidate()
        if let lock {
            la_pointer_lock_free(lock)
        }
    }
}
