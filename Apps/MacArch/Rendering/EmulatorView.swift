import AppKit
import ArchimedesCore
import MetalKit
import SwiftUI

/// The machine's screen. Takes keyboard focus and sends keys to the
/// machine; a click hands it the mouse, or (Settings ▸ Mouse) RISC OS's
/// pointer follows the Mac's.
final class EmulatorNSView: MTKView {
    weak var machine: MachineController?
    var renderer: Renderer?

    override var acceptsFirstResponder: Bool { true }

    // MARK: Zoom

    /// Posted (with the controller, and "zoom" in userInfo) by View > Zoom.
    static let setZoom = Notification.Name("MacArchSetZoom")
    /// Posted (with the controller) by Window > Make 16:9.
    static let makeWidescreen = Notification.Name("MacArchMakeWidescreen")
    /// Called with the picture's zoom (its height over the frame's actual
    /// height) when the view is resized.
    var onZoom: (Double) -> Void = { _ in }

    private var pictureSize: CGSize {
        let aspect = renderer?.aspect ?? 4.0 / 3.0
        let height = min(bounds.height, bounds.width / aspect)
        return CGSize(width: height * aspect, height: height)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let zoom = pictureSize.height / (renderer?.actualSize.height ?? 576)
        DispatchQueue.main.async { [weak self] in self?.onZoom(zoom) }
    }

    /// Resizes the window so the picture is `zoom` times the frame's actual
    /// size, keeping the window's top left in place and on screen.
    @objc private func applyZoom(_ n: Notification) {
        guard (n.object as AnyObject?) === machine, let zoom = n.userInfo?["zoom"] as? Double,
              let window, let renderer else { return }
        let content = window.contentLayoutRect.size
        var frame = window.frame
        var height = renderer.actualSize.height * zoom
        if let screen = window.screen?.visibleFrame {
            height = min(height, screen.height - (frame.height - content.height),
                         (screen.width - (frame.width - content.width)) / renderer.aspect)
        }
        let target = CGSize(width: (height * renderer.aspect).rounded(), height: height.rounded())
        let size = CGSize(width: frame.width + target.width - content.width, height: frame.height + target.height - content.height)
        frame.origin.y += frame.height - size.height
        frame.size = size
        if let screen = window.screen?.visibleFrame {
            frame.origin.x = max(screen.minX, min(frame.origin.x, screen.maxX - frame.width))
            frame.origin.y = max(screen.minY, min(frame.origin.y, screen.maxY - frame.height))
        }
        window.setFrame(frame, display: true, animate: true)
    }

    /// Makes the window 16:9 at its height (less, if that's wider than the
    /// screen), keeping its top left in place and on screen.
    @objc private func applyWidescreen(_ n: Notification) {
        guard (n.object as AnyObject?) === machine, let window else { return }
        var frame = window.frame
        var height = frame.height
        if let screen = window.screen?.visibleFrame {
            height = min(height, screen.width * 9 / 16)
        }
        let size = CGSize(width: (height * 16 / 9).rounded(), height: height.rounded())
        frame.origin.y += frame.height - size.height
        frame.size = size
        if let screen = window.screen?.visibleFrame {
            frame.origin.x = max(screen.minX, min(frame.origin.x, screen.maxX - frame.width))
            frame.origin.y = max(screen.minY, min(frame.origin.y, screen.maxY - frame.height))
        }
        window.setFrame(frame, display: true, animate: true)
    }

    // MARK: Mouse (captured and relative, or following the Mac's)

    /// Posted (with the controller) by Machine > Capture or Release Mouse.
    static let toggleMouseCapture = Notification.Name("MacArchToggleMouseCapture")
    /// Posted (with the controller, and "captured" in userInfo) whenever
    /// the mouse is captured or released, for windows with their own subtitle.
    static let mouseCaptureChanged = Notification.Name("MacArchMouseCaptureChanged")
    static let captureHint = "Mouse captured: ⌃⌘M releases it · ⌘-click is Menu (middle button)"

    private(set) var mouseCaptured = false
    private var remainder = CGPoint.zero

    func setMouseCaptured(_ captured: Bool) {
        guard captured != mouseCaptured else { return }
        if captured && window?.isKeyWindow != true { return }
        mouseCaptured = captured
        remainder = .zero
        if captured {
            NSCursor.hide()
            CGAssociateMouseAndMouseCursorPosition(0)
            window?.subtitle = Self.captureHint
        } else {
            CGAssociateMouseAndMouseCursorPosition(1)
            NSCursor.unhide()
            window?.subtitle = ""
            for b in pressed.keys { release(b) }
        }
        NotificationCenter.default.post(name: Self.mouseCaptureChanged, object: machine, userInfo: ["captured": captured])
    }

    @objc private func toggleMouseCapture(_ n: Notification) {
        guard (n.object as AnyObject?) === machine, !following else { return }
        setMouseCaptured(!mouseCaptured)
    }

    /// Whether RISC OS's pointer follows the Mac's, which stays free.
    private var following: Bool { AppSettings.shared.mouseMode == .follow }
    /// Whether the Mac's pointer is hidden over the picture, where RISC
    /// OS's takes its place.
    private var macPointerHidden = false
    private static let noPointer = NSCursor(image: NSImage(size: NSSize(width: 1, height: 1)), hotSpot: .zero)

    /// Following: sends RISC OS's pointer to the Mac's, and while RISC OS's
    /// is off, the movement as counts.
    private func follow(_ e: NSEvent) {
        if mouseCaptured { setMouseCaptured(false) }
        // Mouse-moved events come to the key window wherever the pointer is,
        // so over another window on top of the picture (Configure Machine,
        // say) the pointer is that window's.
        guard NSWindow.windowNumber(at: NSEvent.mouseLocation, belowWindowWithWindowNumber: 0) == window?.windowNumber else {
            stopFollowing()
            return
        }
        // RISC OS's pointer can't go into VIDC's border: there it waits at
        // the display area's edge, and the Mac's pointer shows.
        var spot = framePoint(e, clamped: true)
        var inDisplay = spot != nil
        if let s = spot, let d = machine?.host?.frame.displayArea {
            let x = min(max(s.x, d.x), d.x + d.width - 1), y = min(max(s.y, d.y), d.y + d.height - 1)
            inDisplay = x == s.x && y == s.y && framePoint(e) != nil
            spot = (x, y)
        }
        machine?.followPointer(to: spot, dx: Int(e.deltaX.rounded()), dy: Int(-e.deltaY.rounded()))
        let hide = inDisplay && machine?.host?.pointerShown == true
        if hide != macPointerHidden {
            macPointerHidden = hide
            (hide ? Self.noPointer : NSCursor.arrow).set()
        } else if hide {
            Self.noPointer.set()
        }
    }

    private func stopFollowing() {
        machine?.followPointer(to: nil)
        if macPointerHidden { macPointerHidden = false; NSCursor.arrow.set() }
    }

    private func move(_ e: NSEvent) {
        guard mouseCaptured else { return }
        // One mouse count per Mac point; RISC OS applies its own scaling.
        let x = remainder.x + e.deltaX, y = remainder.y - e.deltaY
        let dx = Int(x.rounded(.towardZero)), dy = Int(y.rounded(.towardZero))
        remainder = CGPoint(x: x - CGFloat(dx), y: y - CGFloat(dy))
        if dx != 0 || dy != 0 { machine?.mouseMove(dx: dx, dy: dy) }
    }

    static let select: UInt8 = 0x70, menu: UInt8 = 0x71, adjust: UInt8 = 0x72

    /// Archimedes buttons for a Mac primary click: Select, or with a modifier
    /// the other two buttons for trackpads and one-button mice. Command never
    /// reaches the guest, so ⌘-click is the clean way to press Menu.
    private func primaryButton(_ e: NSEvent) -> UInt8 {
        let f = e.modifierFlags
        if f.contains(.command) || f.contains(.control) {
            return Self.menu
        }
        if f.contains(.option) {
            return AppSettings.shared.secondaryClick == .adjust ? Self.menu : Self.adjust
        }
        return Self.select
    }

    private var secondaryButton: UInt8 { AppSettings.shared.secondaryClick == .adjust ? Self.adjust : Self.menu }

    /// The guest button each Mac button pressed, so release matches press.
    private var pressed: [Int: UInt8] = [:]

    private func press(_ macButton: Int, _ code: UInt8) {
        if let old = pressed[macButton] { machine?.keyUp(old) }
        pressed[macButton] = code
        machine?.keyDown(code)
    }

    private func release(_ macButton: Int) {
        if let code = pressed.removeValue(forKey: macButton) { machine?.keyUp(code) }
    }

    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        // A network tile without the keyboard: the first click gives it the
        // keyboard, rather than capturing the mouse.
        if !takesFocus, let onFocus { onFocus(); return }
        if following { follow(e); press(0, primaryButton(e)); return }
        if !mouseCaptured { setMouseCaptured(true); return }
        press(0, primaryButton(e))
    }
    /// Whether the buttons go to the machine.
    private var buttonsGo: Bool { mouseCaptured || (following && takesFocus) }
    override func mouseUp(with e: NSEvent) { release(0) }
    override func rightMouseDown(with e: NSEvent) { if buttonsGo { press(1, secondaryButton) } }
    override func rightMouseUp(with e: NSEvent) { release(1) }
    override func otherMouseDown(with e: NSEvent) { if buttonsGo { press(2, Self.menu) } }
    override func otherMouseUp(with e: NSEvent) { release(2) }
    override func mouseMoved(with e: NSEvent) {
        if mouseCaptured { move(e) } else { inspect(e) }
        if following && takesFocus { follow(e) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for a in trackingAreas { removeTrackingArea(a) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseExited(with e: NSEvent) {
        if machine?.inspecting == true { machine?.hover(x: -1, y: -1) }
        if following { stopFollowing() }
    }

    /// Where the picture is in the view.
    private var pictureRect: CGRect {
        let size = pictureSize
        return CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
    }

    /// The frame pixel under the mouse; off the picture, nil or (clamped)
    /// the nearest at its edge.
    private func framePoint(_ e: NSEvent, clamped: Bool = false) -> (x: Int, y: Int)? {
        guard let f = machine?.host?.frame, f.width > 1 else { return nil }
        let p = convert(e.locationInWindow, from: nil), r = pictureRect
        var u = (p.x - r.minX) / r.width, v = (p.y - r.minY) / r.height
        if clamped { u = min(max(u, 0), 0.9999); v = min(max(v, 0), 0.9999) }
        guard u >= 0, u < 1, v >= 0, v < 1 else { return nil }
        let c = renderer?.crop ?? VideoFrame.Area(x: 0, y: 0, width: f.width, height: f.height)
        return (c.x + Int(u * CGFloat(c.width)), c.y + Int((isFlipped ? v : 1 - v) * CGFloat(c.height)))
    }

    /// While the debugger is open: which frame pixel is under the mouse.
    private func inspect(_ e: NSEvent) {
        guard let machine, machine.inspecting else { return }
        let p = framePoint(e)
        machine.hover(x: p?.x ?? -1, y: p?.y ?? -1)
    }
    override func mouseDragged(with e: NSEvent) { drag(e) }
    override func rightMouseDragged(with e: NSEvent) { drag(e) }
    override func otherMouseDragged(with e: NSEvent) { drag(e) }
    private func drag(_ e: NSEvent) { if following && buttonsGo { follow(e) } else { move(e) } }

    // MARK: Keyboard

    private func arcKey(_ keyCode: UInt16) -> UInt8? {
        KeyboardSettings.shared.customKeys[keyCode] ?? KeyMap.table[keyCode]
    }

    /// Mac keys that stay positional in Mac-layout mode: arrows, function
    /// keys, editing keys, Return, Tab, Escape, Delete and the keypad.
    private static let positionalKeys: Set<UInt16> = [
        36, 48, 51, 53, 76, 117, 114, 115, 116, 119, 121, 123, 124, 125, 126,
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113,
        65, 67, 69, 71, 75, 78, 81, 82, 83, 84, 85, 86, 87, 88, 89, 91, 92,
    ]

    /// In Mac-layout mode: the Archimedes key each held Mac key went down as,
    /// and whether Shift was changed for it.
    private var typed: [UInt16: (code: UInt8, shiftChanged: Bool)] = [:]
    private var macShiftHeld = false

    private func setArcShift(_ down: Bool) {
        if down { machine?.keyDown(0x4C) } else { machine?.keyUp(0x4C); machine?.keyUp(0x58) }
    }

    override func keyDown(with e: NSEvent) {
        // Command combinations belong to the menus.
        if e.modifierFlags.contains(.command) { super.keyDown(with: e); return }
        if e.isARepeat { return } // RISC OS does its own auto-repeat
        if KeyboardSettings.shared.customKeys[e.keyCode] == nil,
           KeyboardSettings.shared.modeValue == .macLayout,
           !e.modifierFlags.contains(.control), !Self.positionalKeys.contains(e.keyCode),
           let ch = e.characters?.first, let (code, shift) = ArcKey.forCharacter(ch) {
            let change = shift != macShiftHeld
            if change { setArcShift(shift) }
            typed[e.keyCode] = (code, change)
            machine?.keyDown(code)
            return
        }
        if let code = arcKey(e.keyCode) { machine?.keyDown(code) }
    }

    override func keyUp(with e: NSEvent) {
        if let t = typed.removeValue(forKey: e.keyCode) {
            machine?.keyUp(t.code)
            if t.shiftChanged { setArcShift(macShiftHeld) }
            return
        }
        if let code = arcKey(e.keyCode) { machine?.keyUp(code) }
    }

    override func flagsChanged(with e: NSEvent) {
        if let custom = KeyboardSettings.shared.customKeys[e.keyCode] {
            if KeyRecorder.isPress(e) { machine?.keyDown(custom) } else { machine?.keyUp(custom) }
            return
        }
        guard let (code, flag) = KeyMap.modifiers[e.keyCode] else { return }
        let macLayout = KeyboardSettings.shared.modeValue == .macLayout
        if flag == .shift { macShiftHeld = e.modifierFlags.contains(.shift) }
        // In Mac-layout mode the Mac applies Caps Lock and Option to the
        // characters it reports, so they are not passed on.
        if macLayout && (flag == .capsLock || flag == .option) { return }
        if flag == .capsLock {
            // macOS reports Caps Lock as a toggle: tap the Arc's key.
            machine?.keyDown(code)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.machine?.keyUp(code) }
            return
        }
        if e.modifierFlags.contains(flag) { machine?.keyDown(code) } else { machine?.keyUp(code) }
    }

    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        e.modifierFlags.contains(.command) ? super.performKeyEquivalent(with: e) : false
    }

    // MARK: Window

    /// Whether it takes the keyboard (in a network's tiles, only the
    /// focused machine's does), and what a click on it does if it doesn't.
    var takesFocus = true
    var onFocus: (() -> Void)?

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        // Leaving the window (a network changing view) gives the mouse back.
        if newWindow == nil { setMouseCaptured(false) }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
        if takesFocus { window?.makeFirstResponder(self) }
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(windowDidResignKey), name: NSWindow.didResignKeyNotification, object: window)
        nc.addObserver(self, selector: #selector(toggleMouseCapture), name: Self.toggleMouseCapture, object: nil)
        nc.addObserver(self, selector: #selector(applyZoom), name: Self.setZoom, object: nil)
        nc.addObserver(self, selector: #selector(applyWidescreen), name: Self.makeWidescreen, object: nil)
    }

    @objc private func windowDidResignKey(_ n: Notification) {
        setMouseCaptured(false)
        for b in pressed.keys { release(b) }
        stopFollowing()
        typed.removeAll()
        macShiftHeld = false
        machine?.releaseAllKeys()
    }
}

struct EmulatorView: NSViewRepresentable {
    let machine: MachineController
    let host: EmulatorHost
    let style: DisplayStyle
    var border = DisplayBorder.saved
    var onRenderer: (Renderer) -> Void = { _ in }
    var onZoom: (Double) -> Void = { _ in }
    var takesFocus = true
    var onFocus: (() -> Void)?

    func makeNSView(context: Context) -> EmulatorNSView {
        let device = MTLCreateSystemDefaultDevice()
        let view = EmulatorNSView(frame: .zero, device: device)
        view.machine = machine
        view.onZoom = onZoom
        view.takesFocus = takesFocus
        view.onFocus = onFocus
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.preferredFramesPerSecond = 120
        if let device, let r = Renderer(device: device, pixelFormat: view.colorPixelFormat, host: host) {
            r.style = style
            r.border = border
            view.renderer = r
            view.delegate = r
            onRenderer(r)
        }
        return view
    }

    func updateNSView(_ view: EmulatorNSView, context: Context) {
        view.renderer?.style = style
        view.renderer?.border = border
        view.onFocus = onFocus
        if takesFocus != view.takesFocus {
            view.takesFocus = takesFocus
            if takesFocus { view.window?.makeFirstResponder(view) }
        }
    }
}
