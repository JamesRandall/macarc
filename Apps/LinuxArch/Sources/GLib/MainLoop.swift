// GLib's main loop, running libdispatch's main queue (and so the main
// actor's jobs), and timers on it.

import CGtk
import Dispatch

@MainActor
enum MainLoop {
    /// Call once, on the main thread, before the loop runs. Foundation's run
    /// loop does the same on Linux: libdispatch pokes an eventfd when the
    /// main queue has work, and draining it runs the work.
    static func runDispatchMainQueue() {
        let fd = _dispatch_get_main_queue_handle_4CF()
        let callback: GUnixFDSourceFunc = { fd, _, _ in
            _ = la_drain_eventfd(fd)
            _dispatch_main_queue_callback_4CF(nil)
            return 1
        }
        g_unix_fd_add(fd, G_IO_IN, callback, nil)
    }
}

/// A repeating timer on the main loop. Stops when invalidated, or when the
/// handler returns false.
@MainActor
final class GLibTimer {
    private var source: guint = 0

    /// Calls `handler` every `interval` seconds.
    init(interval: Double, _ handler: @escaping @MainActor () -> Bool) {
        let callback: GSourceFunc = { data in
            let handler = Box<@MainActor () -> Bool>.from(data)
            return MainActor.assumeIsolated { handler() } ? 1 : 0
        }
        source = g_timeout_add_full(G_PRIORITY_DEFAULT, guint(max(1, interval * 1000)), callback,
                                    Box(handler).retained, releaseBoxNotify)
    }

    func invalidate() {
        if source != 0 {
            g_source_remove(source)
            source = 0
        }
    }

    isolated deinit {
        invalidate()
    }
}

/// Runs `handler` on the main loop after `delay` seconds.
@MainActor
func after(_ delay: Double, _ handler: @escaping Handler) {
    let callback: GSourceFunc = { data in
        let handler = Box<Handler>.from(data)
        MainActor.assumeIsolated { handler() }
        return 0
    }
    g_timeout_add_full(G_PRIORITY_DEFAULT, guint(max(0, delay * 1000)), callback, Box(handler).retained, releaseBoxNotify)
}
