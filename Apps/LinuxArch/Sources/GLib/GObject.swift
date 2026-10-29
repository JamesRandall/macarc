// Calling GTK from Swift: GObject pointers, and signals connected to Swift
// closures.
//
// GTK's objects come to Swift as typed pointers (`UnsafeMutablePointer<
// GtkWidget>`) or, for final types, `OpaquePointer`. `cast()` is C's cast
// between them, and `opaque` the opaque form. Signal handlers run on the main
// thread, which is the main actor's.

import CGtk
import Foundation

typealias Widget = UnsafeMutablePointer<GtkWidget>

protocol GPointer {
    var raw: UnsafeMutableRawPointer { get }
}

extension UnsafeMutablePointer: GPointer {
    var raw: UnsafeMutableRawPointer { UnsafeMutableRawPointer(self) }
}

extension OpaquePointer: GPointer {
    var raw: UnsafeMutableRawPointer { UnsafeMutableRawPointer(self) }
}

extension UnsafeMutableRawPointer: GPointer {
    var raw: UnsafeMutableRawPointer { self }
}

extension GPointer {
    /// The object as another of its GObject types.
    func cast<T>() -> UnsafeMutablePointer<T> { raw.assumingMemoryBound(to: T.self) }
    /// The object as one of its final types, which Swift sees as opaque.
    func cast() -> OpaquePointer { OpaquePointer(raw) }
    var opaque: OpaquePointer { OpaquePointer(raw) }
    var widget: Widget { cast() }
    var object: UnsafeMutablePointer<GObject> { cast() }
}

/// Holds a Swift value for C (as a signal's or source's user data).
final class Box<T> {
    let value: T
    init(_ value: T) { self.value = value }

    var retained: gpointer { Unmanaged.passRetained(self).toOpaque() }

    static func from(_ data: gpointer?) -> T {
        Unmanaged<Box<T>>.fromOpaque(data!).takeUnretainedValue().value
    }
}

/// Releases a `Box` when its signal is disconnected or its object goes.
let releaseBox: GClosureNotify = { data, _ in
    if let data { Unmanaged<AnyObject>.fromOpaque(data).release() }
}

/// For sources and tick callbacks.
let releaseBoxNotify: GDestroyNotify = { data in
    if let data { Unmanaged<AnyObject>.fromOpaque(data).release() }
}

@discardableResult
private func connect<T>(_ object: some GPointer, _ name: String, after: Bool, _ value: T, _ callback: GCallback) -> gulong {
    la_signal_connect(object.raw, name, callback, Box(value).retained, releaseBox, after ? 1 : 0)
}

private func c<F>(_ function: F) -> GCallback {
    unsafeBitCast(function, to: GCallback.self)
}

// MARK: Signals, by their handlers' shapes

typealias Handler = @MainActor () -> Void

/// A signal with no arguments, e.g. "clicked" or "activate".
@MainActor @discardableResult
func onSignal(_ object: some GPointer, _ name: String, after: Bool = false, _ handler: @escaping Handler) -> gulong {
    let callback: @convention(c) (gpointer?, gpointer?) -> Void = { _, data in
        let handler = Box<Handler>.from(data)
        MainActor.assumeIsolated { handler() }
    }
    return connect(object, name, after: after, handler, c(callback))
}

/// A signal with no arguments whose handler says whether it handled it
/// (e.g. "close-request": true stops the window closing).
@MainActor @discardableResult
func onSignalReturning(_ object: some GPointer, _ name: String, _ handler: @escaping @MainActor () -> Bool) -> gulong {
    let callback: @convention(c) (gpointer?, gpointer?) -> gboolean = { _, data in
        let handler = Box<@MainActor () -> Bool>.from(data)
        return MainActor.assumeIsolated { handler() } ? 1 : 0
    }
    return connect(object, name, after: false, handler, c(callback))
}

/// "notify::PROPERTY".
@MainActor @discardableResult
func onNotify(_ object: some GPointer, _ property: String, _ handler: @escaping Handler) -> gulong {
    let callback: @convention(c) (gpointer?, gpointer?, gpointer?) -> Void = { _, _, data in
        let handler = Box<Handler>.from(data)
        MainActor.assumeIsolated { handler() }
    }
    return connect(object, "notify::" + property, after: false, handler, c(callback))
}

/// GtkEventControllerKey's "key-pressed" and "key-released": keyval,
/// hardware keycode, modifiers. Pressed handlers say whether they used it.
typealias KeyHandler = @MainActor (_ keyval: UInt32, _ keycode: UInt32, _ state: GdkModifierType) -> Bool

@MainActor @discardableResult
func onKey(_ controller: some GPointer, _ name: String, _ handler: @escaping KeyHandler) -> gulong {
    let callback: @convention(c) (gpointer?, guint, guint, GdkModifierType, gpointer?) -> gboolean = { _, keyval, keycode, state, data in
        let handler = Box<KeyHandler>.from(data)
        return MainActor.assumeIsolated { handler(keyval, keycode, state) } ? 1 : 0
    }
    return connect(controller, name, after: false, handler, c(callback))
}

/// Pointer motion and "enter": x, y.
typealias PointHandler = @MainActor (_ x: Double, _ y: Double) -> Void

@MainActor @discardableResult
func onPoint(_ controller: some GPointer, _ name: String, _ handler: @escaping PointHandler) -> gulong {
    let callback: @convention(c) (gpointer?, Double, Double, gpointer?) -> Void = { _, x, y, data in
        let handler = Box<PointHandler>.from(data)
        MainActor.assumeIsolated { handler(x, y) }
    }
    return connect(controller, name, after: false, handler, c(callback))
}

/// GtkGestureClick's "pressed" and "released": number of presses, x, y.
typealias ClickHandler = @MainActor (_ presses: Int32, _ x: Double, _ y: Double) -> Void

@MainActor @discardableResult
func onClick(_ gesture: some GPointer, _ name: String, _ handler: @escaping ClickHandler) -> gulong {
    let callback: @convention(c) (gpointer?, gint, Double, Double, gpointer?) -> Void = { _, presses, x, y, data in
        let handler = Box<ClickHandler>.from(data)
        MainActor.assumeIsolated { handler(presses, x, y) }
    }
    return connect(gesture, name, after: false, handler, c(callback))
}

/// GtkGLArea's "render".
@MainActor @discardableResult
func onRender(_ area: some GPointer, _ handler: @escaping @MainActor () -> Bool) -> gulong {
    let callback: @convention(c) (gpointer?, gpointer?, gpointer?) -> gboolean = { _, _, data in
        let handler = Box<@MainActor () -> Bool>.from(data)
        return MainActor.assumeIsolated { handler() } ? 1 : 0
    }
    return connect(area, "render", after: false, handler, c(callback))
}

/// GtkGLArea's "resize": width and height in pixels.
@MainActor @discardableResult
func onResize(_ area: some GPointer, _ handler: @escaping @MainActor (Int32, Int32) -> Void) -> gulong {
    let callback: @convention(c) (gpointer?, gint, gint, gpointer?) -> Void = { _, width, height, data in
        let handler = Box<@MainActor (Int32, Int32) -> Void>.from(data)
        MainActor.assumeIsolated { handler(width, height) }
    }
    return connect(area, "resize", after: false, handler, c(callback))
}

/// GtkDropTarget's "drop": the dropped file's path. The handler says
/// whether it took it.
@MainActor @discardableResult
func onDropFile(_ target: some GPointer, _ handler: @escaping @MainActor (String) -> Bool) -> gulong {
    let callback: @convention(c) (gpointer?, UnsafePointer<GValue>?, Double, Double, gpointer?) -> gboolean = { _, value, _, _, data in
        let handler = Box<@MainActor (String) -> Bool>.from(data)
        guard let value, let path = la_dropped_path(value) else { return 0 }
        defer { g_free(path) }
        let string = String(cString: path)
        return MainActor.assumeIsolated { handler(string) } ? 1 : 0
    }
    return connect(target, "drop", after: false, handler, c(callback))
}

/// GtkDropTarget's "drop": every dropped file's path. The handler says
/// whether it took them.
@MainActor @discardableResult
func onDropFiles(_ target: some GPointer, _ handler: @escaping @MainActor ([URL]) -> Bool) -> gulong {
    let callback: @convention(c) (gpointer?, UnsafePointer<GValue>?, Double, Double, gpointer?) -> gboolean = { _, value, _, _, data in
        let handler = Box<@MainActor ([URL]) -> Bool>.from(data)
        guard let value else { return 0 }
        let urls = MainActor.assumeIsolated { FileDialogs.urls(la_dropped_paths(value)) }
        guard !urls.isEmpty else { return 0 }
        return MainActor.assumeIsolated { handler(urls) } ? 1 : 0
    }
    return la_signal_connect(target.raw, "drop", unsafeBitCast(callback, to: GCallback.self), Box(handler).retained,
                             releaseBox, 0)
}

/// A drop target for files on `widget`, calling `handler` with them.
@MainActor
func acceptFileDrops(on widget: Widget, _ handler: @escaping @MainActor ([URL]) -> Bool) {
    let target = gtk_drop_target_new(la_type_file_list(), GDK_ACTION_COPY)!
    onDropFiles(target, handler)
    widget.addController(target)
}

/// GSimpleAction's "activate" and "change-state": the parameter or new state.
typealias VariantHandler = @MainActor (OpaquePointer?) -> Void

@MainActor @discardableResult
func onVariant(_ action: some GPointer, _ name: String, _ handler: @escaping VariantHandler) -> gulong {
    let callback: @convention(c) (gpointer?, OpaquePointer?, gpointer?) -> Void = { _, variant, data in
        let handler = Box<VariantHandler>.from(data)
        MainActor.assumeIsolated { handler(variant) }
    }
    return connect(action, name, after: false, handler, c(callback))
}

// MARK: Strings

extension String {
    /// A C string GLib allocated, freed after copying.
    init?(gOwned pointer: UnsafeMutablePointer<CChar>?) {
        guard let pointer else { return nil }
        self.init(cString: pointer)
        g_free(pointer)
    }

    init?(gBorrowed pointer: UnsafePointer<CChar>?) {
        guard let pointer else { return nil }
        self.init(cString: pointer)
    }
}

// MARK: Widgets

@MainActor
extension GPointer {
    func addClass(_ name: String) {
        gtk_widget_add_css_class(widget, name)
    }

    func removeClass(_ name: String) {
        gtk_widget_remove_css_class(widget, name)
    }

    func setClass(_ name: String, _ on: Bool) {
        if on { addClass(name) } else { removeClass(name) }
    }

    func setTooltip(_ text: String?) {
        gtk_widget_set_tooltip_text(widget, text)
    }

    func setSensitive(_ on: Bool) {
        gtk_widget_set_sensitive(widget, on ? 1 : 0)
    }

    func setVisible(_ on: Bool) {
        gtk_widget_set_visible(widget, on ? 1 : 0)
    }

    func setMargins(_ all: Int32) {
        setMargins(top: all, bottom: all, start: all, end: all)
    }

    func setMargins(top: Int32 = 0, bottom: Int32 = 0, start: Int32 = 0, end: Int32 = 0) {
        gtk_widget_set_margin_top(widget, top)
        gtk_widget_set_margin_bottom(widget, bottom)
        gtk_widget_set_margin_start(widget, start)
        gtk_widget_set_margin_end(widget, end)
    }

    func expand(horizontally: Bool = false, vertically: Bool = false) {
        gtk_widget_set_hexpand(widget, horizontally ? 1 : 0)
        gtk_widget_set_vexpand(widget, vertically ? 1 : 0)
    }

    func align(horizontal: GtkAlign? = nil, vertical: GtkAlign? = nil) {
        if let horizontal { gtk_widget_set_halign(widget, horizontal) }
        if let vertical { gtk_widget_set_valign(widget, vertical) }
    }

    func addController(_ controller: some GPointer) {
        gtk_widget_add_controller(widget, controller.opaque)
    }
}
