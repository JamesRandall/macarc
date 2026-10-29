import ArchimedesCore
import CGtk
import Foundation

/// The machine's screen: a GL area that takes keyboard focus and sends keys
/// to the machine. A click hands it the mouse, or (Preferences ▸ Mouse)
/// RISC OS's pointer follows the desktop's. (The Mac app's EmulatorNSView.)
@MainActor
final class EmulatorView {
    let area: Widget
    weak var machine: MachineController?
    private(set) var renderer: Renderer?
    /// Why there's no picture, if OpenGL failed.
    private(set) var rendererError: String?
    var style = DisplayStyle.saved {
        didSet {
            renderer?.style = style
            gtk_gl_area_queue_render(area.cast())
        }
    }
    var border = DisplayBorder.saved {
        didSet {
            renderer?.border = border
            gtk_gl_area_queue_render(area.cast())
        }
    }
    /// Called with the picture's zoom (its height over the frame's actual
    /// height) when the view is resized.
    var onZoom: (Double) -> Void = { _ in }
    /// Called when the mouse is captured or released.
    var onMouseCapture: (Bool) -> Void = { _ in }
    /// Called when it gets the keyboard (a network's tile: it's heard).
    var onFocus: Handler?

    init() {
        area = gtk_gl_area_new()!
        gtk_gl_area_set_auto_render(area.cast(), 0)
        gtk_gl_area_set_allowed_apis(area.cast(), GdkGLAPI(rawValue: GDK_GL_API_GL.rawValue | GDK_GL_API_GLES.rawValue))
        gtk_widget_set_focusable(area, 1)
        gtk_widget_set_focus_on_click(area, 1)
        area.expand(horizontally: true, vertically: true)
        area.addClass("emulator")
        gtk_widget_set_size_request(area, 320, 256)

        onSignal(area, "realize") { [unowned self] in self.realize() }
        onSignal(area, "unrealize") { [unowned self] in self.unrealize() }
        onRender(area) { [unowned self] in self.render() }
        onResize(area) { [unowned self] _, _ in
            let zoom = self.pictureSize.height / (self.renderer?.actualSize.height ?? 576)
            // (Not in the middle of GTK's layout.)
            after(0) { [weak self] in self?.onZoom(zoom) }
        }
        let tick: GtkTickCallback = { _, _, data in
            let view = Unmanaged<EmulatorView>.fromOpaque(data!).takeUnretainedValue()
            MainActor.assumeIsolated { view.tick() }
            return 1
        }
        gtk_widget_add_tick_callback(area, tick, Unmanaged.passUnretained(self).toOpaque(), nil)

        setUpKeyboard()
        setUpMouse()
        // It lives as long as its widget (its tick callback uses it), which a
        // network's tiles make and drop as machines come and go.
        g_object_set_data_full(area.object, "linuxarch-emulator-view", Unmanaged.passRetained(self).toOpaque()) { data in
            if let data { Unmanaged<EmulatorView>.fromOpaque(data).release() }
        }
    }

    /// The smallest it can be (a tile's smaller than a window's).
    func setMinimumSize(width: Int32, height: Int32) {
        gtk_widget_set_size_request(area, width, height)
    }

    // MARK: Drawing

    private func realize() {
        gtk_gl_area_make_current(area.cast())
        if let error = gtk_gl_area_get_error(area.cast()) {
            rendererError = String(cString: error.pointee.message)
            return
        }
        guard let host = machine?.host else { return }
        attachRenderer(host)
    }

    /// Makes the renderer for `host` (the machine's switched on after the
    /// window opened, say).
    func attachRenderer(_ host: EmulatorHost) {
        guard gtk_widget_get_realized(area) != 0 else { return }
        gtk_gl_area_make_current(area.cast())
        renderer?.destroy()
        var error: String?
        renderer = Renderer(host: host, error: &error)
        renderer?.style = style
        renderer?.border = border
        rendererError = error
        if let error {
            NSLog("LinuxArch: no picture: \(error)")
        }
        gtk_gl_area_queue_render(area.cast())
    }

    private func unrealize() {
        gtk_gl_area_make_current(area.cast())
        renderer?.destroy()
        renderer = nil
    }

    private func render() -> Bool {
        guard let renderer else { return false }
        let scale = gtk_widget_get_scale_factor(area)
        renderer.draw(width: gtk_widget_get_width(area) * scale, height: gtk_widget_get_height(area) * scale)
        return true
    }

    /// Each frame of the display: draws if the machine has a new picture.
    private func tick() {
        if renderer == nil, let host = machine?.host, rendererError == nil {
            attachRenderer(host)
        }
        if renderer?.hasNewFrame == true {
            gtk_gl_area_queue_render(area.cast())
        }
    }

    /// Renders the picture as shown at `width` x `height`.
    func renderImage(width: Int, height: Int) -> [UInt32]? {
        guard renderer != nil else { return nil }
        gtk_gl_area_make_current(area.cast())
        return renderer?.renderImage(width: width, height: height)
    }

    // MARK: Geometry

    private var size: (width: Double, height: Double) {
        (Double(gtk_widget_get_width(area)), Double(gtk_widget_get_height(area)))
    }

    var aspect: Double { renderer?.aspect ?? 4.0 / 3.0 }

    /// The picture's size in the view, allowing for the letterboxing.
    var pictureSize: (width: Double, height: Double) {
        let (width, height) = size
        let pictureHeight = min(height, width / aspect)
        return (pictureHeight * aspect, pictureHeight)
    }

    /// The frame pixel under a point in the view; off the picture, nil or
    /// (clamped) the nearest at its edge.
    private func framePoint(x: Double, y: Double, clamped: Bool = false) -> (x: Int, y: Int)? {
        guard let f = machine?.host?.frame, f.width > 1 else { return nil }
        let (viewWidth, viewHeight) = size
        let (width, height) = pictureSize
        var u = (x - (viewWidth - width) / 2) / width, v = (y - (viewHeight - height) / 2) / height
        if clamped { u = min(max(u, 0), 0.9999); v = min(max(v, 0), 0.9999) }
        guard (0..<1).contains(u), (0..<1).contains(v) else { return nil }
        let c = renderer?.crop ?? VideoFrame.Area(x: 0, y: 0, width: f.width, height: f.height)
        return (c.x + Int(u * Double(c.width)), c.y + Int(v * Double(c.height)))
    }

    // MARK: Keyboard

    /// Keys down, by Linux key code, so repeats can be told from presses
    /// (RISC OS does its own auto-repeat).
    private var down: Set<UInt16> = []
    /// In host-layout mode: the Archimedes key each held key went down as,
    /// and whether Shift was changed for it.
    private var typed: [UInt16: (code: UInt8, shiftChanged: Bool)] = [:]
    private var shiftHeld = false

    private func setUpKeyboard() {
        let keys = gtk_event_controller_key_new()!
        onKey(keys, "key-pressed") { [unowned self] keyval, keycode, state in
            self.keyPressed(keyval: keyval, keycode: keycode, state: state)
        }
        onKey(keys, "key-released") { [unowned self] keyval, keycode, state in
            self.keyReleased(keyval: keyval, keycode: keycode, state: state)
            return true
        }
        area.addController(keys)

        let focus = gtk_event_controller_focus_new()!
        onSignal(focus, "leave") { [unowned self] in self.focusLost() }
        onSignal(focus, "enter") { [unowned self] in self.onFocus?() }
        area.addController(focus)
    }

    private func setArcShift(_ down: Bool) {
        if down { machine?.keyDown(0x4C) } else { machine?.keyUp(0x4C); machine?.keyUp(0x58) }
    }

    private func arcKey(_ code: UInt16) -> UInt8? {
        KeyboardSettings.shared.customKeys[code] ?? LinuxKeyMap.table[code]
    }

    private func keyPressed(keyval: UInt32, keycode: UInt32, state: GdkModifierType) -> Bool {
        guard let code = LinuxKeyMap.evdev(gdkKeycode: keycode) else { return false }
        let settings = KeyboardSettings.shared
        // The Super keys, and combinations with them, belong to the desktop.
        if LinuxKeyMap.superKeys.contains(code) && settings.customKeys[code] == nil { return false }
        if state.rawValue & GDK_SUPER_MASK.rawValue != 0 { return false }
        if code == 42 || code == 54 { shiftHeld = true }
        guard down.insert(code).inserted else { return true }
        let hostLayout = settings.mode == .hostLayout && settings.customKeys[code] == nil
        // With the host's layout, it applies Caps Lock and AltGr to the
        // characters it reports, so they aren't passed on.
        if hostLayout && (code == 58 || code == 100) { return true }
        if hostLayout, state.rawValue & GDK_CONTROL_MASK.rawValue == 0, !LinuxKeyMap.positionalKeys.contains(code),
           let scalar = Unicode.Scalar(gdk_keyval_to_unicode(keyval)), scalar.value > 0,
           let (arc, shift) = ArcKey.forCharacter(Character(scalar)) {
            let change = shift != shiftHeld
            if change { setArcShift(shift) }
            typed[code] = (arc, change)
            machine?.keyDown(arc)
            return true
        }
        if let arc = arcKey(code) { machine?.keyDown(arc) }
        return true
    }

    private func keyReleased(keyval: UInt32, keycode: UInt32, state: GdkModifierType) {
        guard let code = LinuxKeyMap.evdev(gdkKeycode: keycode) else { return }
        if code == 42 || code == 54 { shiftHeld = false }
        guard down.remove(code) != nil else { return }
        if let t = typed.removeValue(forKey: code) {
            machine?.keyUp(t.code)
            if t.shiftChanged { setArcShift(shiftHeld) }
            return
        }
        let settings = KeyboardSettings.shared
        if settings.mode == .hostLayout && settings.customKeys[code] == nil && (code == 58 || code == 100) { return }
        if let arc = arcKey(code) { machine?.keyUp(arc) }
    }

    /// The window's gone to the background, or another widget has focus:
    /// let go of everything.
    func focusLost() {
        setMouseCaptured(false)
        for b in pressed.keys { release(b) }
        stopFollowing()
        down = []
        typed = [:]
        shiftHeld = false
        machine?.releaseAllKeys()
    }

    func grabFocus() {
        gtk_widget_grab_focus(area)
    }

    // MARK: Mouse (captured and relative, or following the desktop's)

    static let captureHint = "Mouse captured: Ctrl+Shift+M releases it"
    static let select: UInt8 = 0x70, menu: UInt8 = 0x71, adjust: UInt8 = 0x72

    private(set) var mouseCaptured = false
    /// Movement not yet a whole count.
    private var remainder = (x: 0.0, y: 0.0)
    /// Where the pointer was last, for movements.
    private var lastPointer: (x: Double, y: Double)?
    private var pointerLock: PointerLock?
    /// The guest button each PC button pressed, so release matches press.
    private var pressed: [UInt32: UInt8] = [:]
    /// Whether the desktop's pointer is hidden over the picture, where
    /// RISC OS's takes its place.
    private var pointerHidden = false

    /// Whether RISC OS's pointer follows the desktop's, which stays free.
    private var following: Bool { AppSettings.shared.mouseMode == .follow }

    func setMouseCaptured(_ captured: Bool) {
        guard captured != mouseCaptured else { return }
        mouseCaptured = captured
        remainder = (0, 0)
        lastPointer = nil
        if captured {
            gtk_widget_set_cursor_from_name(area, "none")
            // Where the desktop allows, the pointer's held still and only
            // its movements come (else they stop at the window's edge).
            pointerLock = PointerLock(widget: area) { [weak self] dx, dy in
                self?.move(dx: dx, dy: dy)
            }
        } else {
            pointerLock = nil
            gtk_widget_set_cursor(area, nil)
            for b in pressed.keys { release(b) }
        }
        onMouseCapture(captured)
    }

    func toggleMouseCapture() {
        guard !following else { return }
        if !mouseCaptured { grabFocus() }
        setMouseCaptured(!mouseCaptured)
    }

    var isPointerLocked: Bool { pointerLock?.isLocked ?? false }

    /// While the debugger is open: which frame pixel is under the mouse.
    private func inspect(x: Double, y: Double) {
        guard let machine, machine.inspecting else { return }
        let p = framePoint(x: x, y: y)
        machine.hover(x: p?.x ?? -1, y: p?.y ?? -1)
    }

    private func setUpMouse() {
        let motion = gtk_event_controller_motion_new()!
        onPoint(motion, "motion") { [unowned self] x, y in
            defer { self.lastPointer = (x, y) }
            if self.mouseCaptured {
                if !self.isPointerLocked, let last = self.lastPointer {
                    self.move(dx: x - last.x, dy: y - last.y)
                }
                return
            }
            self.inspect(x: x, y: y)
            if self.following { self.follow(x: x, y: y) }
        }
        onSignal(motion, "leave") { [unowned self] in
            self.lastPointer = nil
            if self.machine?.inspecting == true { self.machine?.hover(x: -1, y: -1) }
            if self.following { self.stopFollowing() }
        }
        area.addController(motion)

        let click = gtk_gesture_click_new()!
        // Every button.
        gtk_gesture_single_set_button(click.cast(), 0)
        onClick(click, "pressed") { [unowned self] _, x, y in
            self.grabFocus()
            let button = gtk_gesture_single_get_current_button(click.cast())
            if self.following {
                self.follow(x: x, y: y)
                self.press(button, self.arcButton(button))
            } else if self.mouseCaptured {
                self.press(button, self.arcButton(button))
            } else if button == 1 {
                self.setMouseCaptured(true)
            }
        }
        onClick(click, "released") { [unowned self] _, _, _ in
            self.release(gtk_gesture_single_get_current_button(click.cast()))
        }
        area.addController(click)
    }

    /// Left is Select, middle Menu, and right Adjust (or Menu, with the
    /// middle button Adjust: Preferences ▸ Mouse).
    private func arcButton(_ button: guint) -> UInt8 {
        let rightIsAdjust = AppSettings.shared.secondaryClick == .adjust
        switch button {
        case 2: return rightIsAdjust ? Self.menu : Self.adjust
        case 3: return rightIsAdjust ? Self.adjust : Self.menu
        default: return Self.select
        }
    }

    private func press(_ button: UInt32, _ code: UInt8) {
        if let old = pressed[button] { machine?.keyUp(old) }
        pressed[button] = code
        machine?.keyDown(code)
    }

    private func release(_ button: UInt32) {
        if let code = pressed.removeValue(forKey: button) { machine?.keyUp(code) }
    }

    /// Captured: the PC's movement (in the widget's pixels, down positive)
    /// as counts, one a pixel; RISC OS applies its own scaling.
    private func move(dx: Double, dy: Double) {
        let x = remainder.x + dx, y = remainder.y - dy
        let cx = Int(x.rounded(.towardZero)), cy = Int(y.rounded(.towardZero))
        remainder = (x - Double(cx), y - Double(cy))
        if cx != 0 || cy != 0 { machine?.mouseMove(dx: cx, dy: cy) }
    }

    /// Following: sends RISC OS's pointer to the desktop's, and while
    /// RISC OS's is off, the movement as counts.
    private func follow(x: Double, y: Double) {
        if mouseCaptured { setMouseCaptured(false) }
        // RISC OS's pointer can't go into VIDC's border: there it waits at
        // the display area's edge, and the desktop's pointer shows.
        var spot = framePoint(x: x, y: y, clamped: true)
        var inDisplay = spot != nil
        if let s = spot, let d = machine?.host?.frame.displayArea {
            let fx = min(max(s.x, d.x), d.x + d.width - 1), fy = min(max(s.y, d.y), d.y + d.height - 1)
            inDisplay = fx == s.x && fy == s.y && framePoint(x: x, y: y) != nil
            spot = (fx, fy)
        }
        let delta = lastPointer.map { (x - $0.x, y - $0.y) } ?? (0, 0)
        machine?.followPointer(to: spot, dx: Int(delta.0.rounded()), dy: Int(-delta.1.rounded()))
        let hide = inDisplay && machine?.host?.pointerShown == true
        if hide != pointerHidden {
            pointerHidden = hide
            if hide { gtk_widget_set_cursor_from_name(area, "none") } else { gtk_widget_set_cursor(area, nil) }
        }
    }

    private func stopFollowing() {
        machine?.followPointer(to: nil)
        if pointerHidden {
            pointerHidden = false
            gtk_widget_set_cursor(area, nil)
        }
    }
}
