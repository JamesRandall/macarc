import ArchimedesCore
import CGtk
import Foundation

/// The debugger for one machine (the Mac app's, after LinuxBeeb's):
/// disassembly with a breakpoint gutter and memory on the left, the CPU,
/// breakpoints, hardware, trace, profile and log on the right; or, debugging
/// BASIC, the program and its variables, with its calls, breakpoints and
/// watches.
@MainActor
final class DebuggerWindow {
    let model: DebuggerModel
    let window: Widget
    private let actions: Actions
    var onClose: Handler?

    init(model: DebuggerModel, machineName: String) {
        self.model = model
        window = adw_window_new()!
        gtk_window_set_application(window.cast(), LinuxArchApp.shared.app.cast())
        gtk_window_set_title(window.cast(), "Debugger — \(machineName)")
        gtk_window_set_default_size(window.cast(), 1100, 760)

        let group = g_simple_action_group_new()!
        actions = Actions(OpaquePointer(group))
        gtk_widget_insert_action_group(window, "dbg", OpaquePointer(group))
        g_object_unref(group.raw)
        addActions()

        let code = Self.split(left: Self.paned(disassemblyPanel(), memoryPanel(), position: 420), right: sidebar())
        let basic = Self.split(left: Self.paned(basicListingPanel(), basicVariablesPanel(), position: 440), right: basicSidebar())
        let stack = gtk_stack_new()!
        gtk_stack_add_named(stack.cast(), code, "code")
        gtk_stack_add_named(stack.cast(), basic, "basic")

        let toolbar = adw_toolbar_view_new()!
        adw_toolbar_view_add_top_bar(toolbar.cast(), headerBar())
        adw_toolbar_view_set_content(toolbar.cast(), stack)
        adw_window_set_content(window.cast(), toolbar)

        observe(self) { [weak self] in
            guard let self else { return }
            gtk_stack_set_visible_child_name(stack.cast(), self.model.view.basic ? "basic" : "code")
        }
        onSignalReturning(window, "close-request") { [weak self] in
            self?.model.stop()
            self?.onClose?()
            return false
        }
    }

    func present() {
        model.start()
        gtk_window_present(window.cast())
    }

    func close() {
        gtk_window_close(window.cast())
    }

    private static func paned(_ top: Widget, _ bottom: Widget, position: Int32) -> Widget {
        let paned = gtk_paned_new(GTK_ORIENTATION_VERTICAL)!
        gtk_paned_set_start_child(paned.cast(), top)
        gtk_paned_set_end_child(paned.cast(), bottom)
        gtk_paned_set_position(paned.cast(), position)
        return paned
    }

    private static func split(left: Widget, right: Widget) -> Widget {
        let split = gtk_paned_new(GTK_ORIENTATION_HORIZONTAL)!
        gtk_paned_set_start_child(split.cast(), left)
        gtk_paned_set_end_child(split.cast(), right)
        gtk_paned_set_position(split.cast(), 700)
        gtk_paned_set_shrink_end_child(split.cast(), 0)
        return split
    }

    // MARK: Running

    private func addActions() {
        let model = model
        // The same keys step machine code or BASIC, whichever is shown.
        actions.add("continue") { model.view.basic ? model.basicPauseOrContinue() : model.pauseOrContinue() }
        actions.add("step-over") { model.view.basic ? model.basicStep(.over) : model.run(.stepOver) }
        actions.add("step-into") { model.view.basic ? model.basicStep(.into) : model.run(.stepInstruction) }
        actions.add("step-out") { model.view.basic ? model.basicStep(.out) : model.run(.stepOut) }
        actions.add("step-back") { if !model.view.basic { model.stepBack() } }
        actions.add("reverse-continue") { if !model.view.basic { model.reverseContinue() } }
        actions.add("step-scanline") { model.run(.nextScanline) }
        actions.add("step-frame") { model.run(.nextFrame) }
        actions.add("step-interrupt") { model.run(.nextInterrupt) }

        // In this window the function keys are the debugger's.
        let shortcuts = gtk_shortcut_controller_new()!
        gtk_shortcut_controller_set_scope(shortcuts.opaque, GTK_SHORTCUT_SCOPE_LOCAL)
        for (trigger, action) in [("<Control><Shift>y", "dbg.continue"), ("F5", "dbg.continue"),
                                  ("F6", "dbg.step-over"), ("F7", "dbg.step-into"), ("F8", "dbg.step-out"),
                                  ("<Shift>F7", "dbg.step-back"), ("<Control><Shift><Alt>y", "dbg.reverse-continue")] {
            let shortcut = gtk_shortcut_new(gtk_shortcut_trigger_parse_string(trigger), gtk_named_action_new(action))
            gtk_shortcut_controller_add_shortcut(shortcuts.opaque, shortcut)
        }
        gtk_event_controller_set_propagation_phase(shortcuts, GTK_PHASE_CAPTURE)
        window.addController(shortcuts)

        observe(self) { [weak self] in
            guard let self else { return }
            let stopped = self.model.isStopped, basic = self.model.view.basic
            for name in ["step-over", "step-into", "step-out"] {
                self.actions[name]?.isEnabled = stopped
            }
            for name in ["step-back", "reverse-continue"] {
                self.actions[name]?.isEnabled = stopped && !basic
            }
        }
    }

    private func headerBar() -> Widget {
        let header = adw_header_bar_new()!
        let modes = adw_toggle_group_new()!
        for (name, label) in [("code", "Machine Code"), ("basic", "BASIC")] {
            let toggle = adw_toggle_new()!
            adw_toggle_set_name(toggle, name)
            adw_toggle_set_label(toggle, label)
            adw_toggle_group_add(modes.cast(), toggle)
        }
        modes.setTooltip("Debug machine code, or a BASIC program by its lines")
        onNotify(modes, "active-name") { [weak self] in
            guard let self, let name = String(gBorrowed: adw_toggle_group_get_active_name(modes.cast())) else { return }
            if self.model.view.basic != (name == "basic") { self.model.view.basic = name == "basic" }
        }
        adw_header_bar_pack_start(header.cast(), modes)

        let pause = UI.actionButton(icon: "media-playback-pause-symbolic", tooltip: "Pause (Ctrl+Shift+Y)", action: "dbg.continue")
        let over = UI.actionButton(icon: "go-next-symbolic", tooltip: "", action: "dbg.step-over")
        let into = UI.actionButton(icon: "go-down-symbolic", tooltip: "", action: "dbg.step-into")
        let out = UI.actionButton(icon: "go-up-symbolic", tooltip: "", action: "dbg.step-out")
        let back = UI.actionButton(icon: "edit-undo-symbolic", tooltip: "Step back (Shift+F7): to the previous instruction, from the rewind history",
                                   action: "dbg.step-back")
        let reverse = UI.actionButton(icon: "media-skip-backward-symbolic",
                                      tooltip: "Reverse continue (Ctrl+Shift+Alt+Y): back to the last breakpoint hit", action: "dbg.reverse-continue")
        let stepBy = gtk_menu_button_new()!
        gtk_menu_button_set_icon_name(stepBy.cast(), "media-skip-forward-symbolic")
        gtk_menu_button_set_menu_model(stepBy.cast(), Menu()
            .item("Next Scanline", "dbg.step-scanline").item("Next Frame", "dbg.step-frame")
            .item("Next Interrupt", "dbg.step-interrupt").model)
        stepBy.setTooltip("Step to the next scanline, frame or interrupt")
        for button in [pause, over, into, out, back, reverse, stepBy] {
            adw_header_bar_pack_start(header.cast(), button)
        }
        let status = UI.label("", classes: ["dim-label"])
        gtk_label_set_ellipsize(status.cast(), PANGO_ELLIPSIZE_END)
        adw_header_bar_pack_end(header.cast(), status)
        adw_header_bar_set_title_widget(header.cast(), UI.label(""))

        observe(self) { [weak self] in
            guard let self else { return }
            let model = self.model
            let stopped = model.isStopped, basic = model.view.basic
            gtk_button_set_icon_name(pause.cast(), stopped ? "media-playback-start-symbolic" : "media-playback-pause-symbolic")
            pause.setTooltip(stopped ? "Continue (Ctrl+Shift+Y)" : basic ? "Pause (Ctrl+Shift+Y): at the next BASIC statement" : "Pause (Ctrl+Shift+Y)")
            over.setTooltip(basic ? "Step over (F6): to the next statement, running PROCs, FNs and GOSUBs through"
                                  : "Step over (F6): a BL or SWI runs to the next instruction")
            into.setTooltip(basic ? "Step into (F7): to the next statement, into PROCs, FNs and GOSUBs" : "Step into (F7): one instruction")
            out.setTooltip(basic ? "Step out (F8): until this PROC, FN or subroutine returns"
                                 : "Step out (F8): until this routine returns to R14, or the interrupt handler ends")
            for widget in [back, reverse, stepBy] { widget.setVisible(!basic) }
            let name = basic ? "basic" : "code"
            if String(gBorrowed: adw_toggle_group_get_active_name(modes.cast())) != name {
                adw_toggle_group_set_active_name(modes.cast(), name)
            }
            var text = ""
            if let s = model.snapshot {
                if let reason = s.stopReason {
                    text = "Stopped: \(reason)"
                } else if s.isRunningCommand && s.view.basic {
                    text = "Running to a BASIC statement…"
                } else {
                    text = s.isRunningCommand ? "Stepping…" : "Running"
                }
            }
            UI.setText(status, text)
        }
        return header
    }

    // MARK: Disassembly

    private final class LineRow {
        let widget: Widget
        let labels: Widget
        let line: Widget
        let dot: Widget
        let marker: Widget
        let heat: Widget
        let address: Widget
        let word: Widget
        let text: Widget
        let source: Widget
        var lineAddress: UInt32 = 0
        var shownLabels: [String] = []

        @MainActor
        init(toggle: @escaping @MainActor (UInt32) -> Void) {
            labels = UI.vbox()
            dot = gtk_button_new()!
            dot.addClass("breakpoint-dot")
            dot.align(vertical: GTK_ALIGN_CENTER)
            marker = UI.label("", classes: ["code"])
            gtk_widget_set_size_request(marker, 14, -1)
            heat = gtk_level_bar_new()!
            gtk_widget_set_size_request(heat, 36, 4)
            heat.align(vertical: GTK_ALIGN_CENTER)
            address = UI.label("", classes: ["code", "dim-label"])
            word = UI.label("", classes: ["code", "dim-label"])
            gtk_widget_set_size_request(word, 80, -1)
            text = UI.label("", classes: ["code"])
            text.expand(horizontally: true)
            source = UI.label("", classes: ["code-small", "dim-label"])
            line = UI.hbox(spacing: 8, [dot, marker, heat, address, word, text, source], classes: ["disassembly-row"])
            widget = UI.vbox(spacing: 0, [labels, line])
            onSignal(dot, "clicked") { [unowned self] in toggle(self.lineAddress) }
        }
    }

    private func disassemblyPanel() -> Widget {
        let goTo = UI.entry(placeholder: "Go to address", width: 14)
        onSignal(goTo, "activate") { [weak self] in
            guard let self else { return }
            let text = UI.text(of: goTo)
            if let a = self.model.address(text) { self.model.view.disassemblyStart = a & ~3 } else { self.model.message = "Bad address: \(text)" }
        }
        let pc = UI.button("PC") { [weak self] in self?.model.view.disassemblyStart = nil }
        pc.setTooltip("Follow the program counter")
        let symbols = UI.iconButton("bookmark-new-symbolic", tooltip: "Load symbols: a label file (name = &8000, nm output…)") { [weak self] in
            guard let self else { return }
            FileDialogs.open(parent: self.window, title: "Load Symbols (name = &8000, name EQU &8000, or nm output)") { url in
                self.model.loadSymbols(url)
            }
        }
        let up = UI.iconButton("go-up-symbolic", tooltip: "Earlier") { [weak self] in self?.scroll(by: -48) }
        let down = UI.iconButton("go-down-symbolic", tooltip: "Later") { [weak self] in self?.scroll(by: 24) }
        let toolbar = UI.hbox(spacing: 6, [UI.label("Disassembly", classes: ["heading"]), UI.spacer(), goTo, pc, symbols, up, down])
        toolbar.setMargins(8)

        let box = UI.vbox()
        box.setMargins(top: 4, bottom: 4)
        let model = model
        let rows = RowList<DebugSnapshot.Line, LineRow>(box: box, make: {
            LineRow { address in model.toggleBreakpoint(at: address) }
        }, widget: { $0.widget }) { row, line, _ in
            row.lineAddress = line.address
            if row.shownLabels != line.labels {
                row.shownLabels = line.labels
                UI.removeAll(row.labels)
                for label in line.labels {
                    let widget = UI.label(label + ":", classes: ["code", "accent"])
                    widget.setMargins(start: 52)
                    UI.append(row.labels, widget)
                }
            }
            row.dot.setClass("set", !line.breakpoints.isEmpty)
            row.dot.setTooltip(line.breakpoints.isEmpty ? "Set a breakpoint" : "Remove the breakpoint")
            UI.setText(row.marker, line.isPC ? "▶" : "")
            gtk_level_bar_set_value(row.heat.cast(), line.heat)
            row.heat.setVisible(line.heat > 0)
            UI.setText(row.address, String(format: "%08X", line.address))
            UI.setText(row.word, line.word.map { String(format: "%08X", $0) } ?? "--------")
            UI.setText(row.text, line.text)
            UI.setText(row.source, line.source ?? "")
            row.line.setClass("pc", line.isPC)
            row.line.setClass("stopped", line.isPC && model.isStopped)
        }
        let message = UI.label("", classes: ["error-text"], wrap: true)
        message.setMargins(6)
        observe(self) { [weak self] in
            guard let self else { return }
            rows.show(self.model.snapshot?.disassembly ?? [])
            UI.setText(message, self.model.message ?? "")
            message.setVisible(self.model.message != nil)
        }
        let scrolled = UI.scrolled(box, horizontal: GTK_POLICY_AUTOMATIC)
        scrolled.expand(vertically: true)
        return UI.vbox(spacing: 0, [toolbar, UI.separator(), scrolled, message])
    }

    private func scroll(by lines: Int) {
        let start = model.snapshot?.disassembly.first?.address ?? 0
        model.view.disassemblyStart = start &+ UInt32(bitPattern: Int32(lines * 4))
    }

    // MARK: Memory

    private final class MemoryRow {
        let widget: Widget
        let address: Widget
        let bytes: [Widget]
        let text: Widget
        var offset = 0

        @MainActor
        init(edit: @escaping @MainActor (MemoryRow, Int) -> Void) {
            address = UI.label("", classes: ["code-small", "dim-label"])
            address.setMargins(end: 6)
            var bytes: [Widget] = []
            let box = UI.hbox(spacing: 4, [address])
            for column in 0..<16 {
                let label = UI.label("", classes: ["code-small"])
                bytes.append(label)
                UI.append(box, label)
                if column == 7 { UI.append(box, UI.label(" ", classes: ["code-small"])) }
            }
            text = UI.label("", classes: ["code-small", "dim-label"])
            text.setMargins(start: 8)
            UI.append(box, text)
            box.setMargins(start: 8, end: 8)
            widget = box
            self.bytes = bytes
            for (column, label) in bytes.enumerated() {
                let click = gtk_gesture_click_new()!
                onClick(click, "pressed") { [unowned self] presses, _, _ in
                    if presses == 2 { edit(self, column) }
                }
                label.addController(click)
                label.setTooltip("Double-click to change")
            }
        }
    }

    private func memoryPanel() -> Widget {
        let spaces = DebugMemorySpace.allCases
        let space = UI.dropDown(spaces.map(\.name)) { [weak self] index in
            guard let self, self.model.view.memorySpace != spaces[index] else { return }
            self.model.view.memorySpace = spaces[index]
        }
        let addressEntry = UI.entry(placeholder: "Address", width: 12)
        onSignal(addressEntry, "activate") { [weak self] in
            guard let self else { return }
            let text = UI.text(of: addressEntry)
            if let a = self.model.address(text) { self.model.view.memoryAddress = a & ~15 } else { self.model.message = "Bad address: \(text)" }
        }
        let up = UI.iconButton("go-up-symbolic", tooltip: "Earlier") { [weak self] in self?.model.view.memoryAddress &-= 256 }
        let down = UI.iconButton("go-down-symbolic", tooltip: "Later") { [weak self] in self?.model.view.memoryAddress &+= 256 }
        let toolbar = UI.hbox(spacing: 6, [UI.label("Memory", classes: ["heading"]), space, UI.spacer(), addressEntry, up, down])
        toolbar.setMargins(8)

        let box = UI.vbox()
        box.setMargins(top: 4, bottom: 4)
        let model = model
        let rows = RowList<Int, MemoryRow>(box: box, make: { [weak self] in
            MemoryRow { [weak self] row, column in self?.edit(row: row, column: column) }
        }, widget: { $0.widget }) { row, rowIndex, _ in
            let memory = model.snapshot?.memory ?? []
            let base = model.snapshot?.view.memoryAddress ?? 0
            row.offset = rowIndex * 16
            UI.setText(row.address, String(format: "%08X", base &+ UInt32(rowIndex * 16)))
            let previous = model.previousMemory
            for column in 0..<16 {
                let index = rowIndex * 16 + column
                let value = index < memory.count ? memory[index] : nil
                let changed = index < previous.count && previous[index] != value
                UI.setText(row.bytes[column], value.map { String(format: "%02X", $0) } ?? "--")
                row.bytes[column].setClass("changed", changed)
                row.bytes[column].setClass("dim-label", value == nil)
            }
            let slice = memory[min(memory.count, rowIndex * 16)..<min(memory.count, rowIndex * 16 + 16)]
            UI.setText(row.text, String(slice.map { b -> Character in
                guard let b, b >= 32 && b < 127 else { return "." }
                return Character(UnicodeScalar(b))
            }))
        }
        observe(self) { [weak self] in
            guard let self else { return }
            if let index = spaces.firstIndex(of: self.model.view.memorySpace) { UI.select(space, index) }
            rows.show(Array(0..<((self.model.snapshot?.memory.count ?? 0) / 16)))
        }
        let scrolled = UI.scrolled(box, horizontal: GTK_POLICY_AUTOMATIC)
        scrolled.expand(vertically: true)
        return UI.vbox(spacing: 0, [toolbar, UI.separator(), scrolled])
    }

    /// Edits a byte in a popover.
    private func edit(row: MemoryRow, column: Int) {
        let offset = row.offset + column
        Self.popoverEntry(on: row.bytes[column], text: String(cString: gtk_label_get_text(row.bytes[column].cast())), width: 6) { [weak self] text in
            let t = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "&", with: "")
            if let v = UInt8(t, radix: 16) { self?.model.write(v, at: offset) }
        }
    }

    /// A popover with an entry, under `anchor`; `done` gets what's typed
    /// when Return is pressed.
    private static func popoverEntry(on anchor: Widget, text: String, width: Int32, title: String? = nil, note: String? = nil,
                                     _ done: @escaping @MainActor (String) -> Void) {
        let popover = gtk_popover_new()!
        let entry = UI.entry(placeholder: "Value", width: width)
        UI.setText(editable: entry, text)
        var children: [Widget] = []
        if let title { children.append(UI.label(title, classes: ["code"])) }
        children.append(entry)
        if let note { children.append(UI.label(note, classes: ["caption", "dim-label"])) }
        let box = UI.vbox(spacing: 6, children)
        box.setMargins(6)
        gtk_popover_set_child(popover.cast(), box)
        gtk_widget_set_parent(popover, anchor)
        onSignal(entry, "activate") {
            done(UI.text(of: entry))
            gtk_popover_popdown(popover.cast())
        }
        onSignal(popover, "closed") {
            after(0) { gtk_widget_unparent(popover) }
        }
        gtk_popover_popup(popover.cast())
        gtk_widget_grab_focus(entry)
    }

    // MARK: Sidebars

    /// Tabs over a stack of pages; the tab shown is remembered under `key`.
    private static func tabs(_ pages: [(String, Widget)], key: String) -> Widget {
        let tabs = adw_toggle_group_new()!
        adw_toggle_group_set_can_shrink(tabs.cast(), 1)
        let stack = gtk_stack_new()!
        for (name, page) in pages {
            let toggle = adw_toggle_new()!
            adw_toggle_set_name(toggle, name)
            adw_toggle_set_label(toggle, name)
            adw_toggle_group_add(tabs.cast(), toggle)
            gtk_stack_add_named(stack.cast(), page, name)
        }
        let saved = Preferences.standard.string(forKey: key).flatMap { name in pages.first { $0.0 == name }?.0 } ?? pages[0].0
        adw_toggle_group_set_active_name(tabs.cast(), saved)
        gtk_stack_set_visible_child_name(stack.cast(), saved)
        onNotify(tabs, "active-name") {
            guard let name = String(gBorrowed: adw_toggle_group_get_active_name(tabs.cast())) else { return }
            gtk_stack_set_visible_child_name(stack.cast(), name)
            Preferences.standard.set(name, forKey: key)
        }
        tabs.setMargins(8)
        stack.expand(vertically: true)
        let sidebar = UI.vbox(spacing: 0, [tabs, UI.separator(), stack])
        gtk_widget_set_size_request(sidebar, 340, -1)
        return sidebar
    }

    private func sidebar() -> Widget {
        Self.tabs([("CPU", registersView()), ("Breakpoints", breakpointsView()), ("Hardware", hardwareView()),
                   ("Trace", traceView()), ("Profile", profileView()), ("Log", logView())], key: "debuggerTab")
    }

    private func basicSidebar() -> Widget {
        Self.tabs([("Calls", basicCallsView()), ("Breakpoints", basicBreakpointsView()), ("Watch", basicWatchView()),
                   ("Log", logView())], key: "basicDebuggerTab")
    }

    // MARK: CPU

    private final class RegisterRow {
        let widget: Widget
        let name: Widget
        let entry: Widget
        let decimal: Widget
        var register = ""
        var value: UInt32?

        @MainActor
        init(set: @escaping @MainActor (String, UInt32) -> Void) {
            name = UI.label("", classes: ["code", "dim-label"])
            gtk_widget_set_size_request(name, 56, -1)
            entry = UI.entry(width: 10)
            entry.addClass("code")
            decimal = UI.label("", classes: ["code-small", "dim-label"])
            widget = UI.hbox(spacing: 10, [name, entry, decimal])
            onSignal(entry, "activate") { [unowned self] in
                let text = UI.text(of: self.entry)
                if let v = DebuggerModel.parseNumber(text.hasPrefix("&") ? text : "&" + text) {
                    set(self.register, v)
                } else if let value = self.value {
                    UI.setText(editable: self.entry, String(format: "&%08X", value))
                }
            }
        }
    }

    private func registersView() -> Widget {
        let model = model
        let registers = UI.vbox(spacing: 4)
        let registerRows = RowList<(String, UInt32), RegisterRow>(box: registers, make: {
            RegisterRow { name, value in model.setRegister(name, value) }
        }, widget: { $0.widget }) { row, register, _ in
            let (name, value) = register
            row.register = name
            UI.setText(row.name, name == "R13" ? "R13 sp" : name == "R14" ? "R14 lr" : name)
            if row.value != value {
                row.value = value
                UI.setText(editable: row.entry, String(format: "&%08X", value))
            }
            UI.setText(row.decimal, "\(value)")
            row.entry.setSensitive(model.isStopped)
        }
        let flagNames = [("N", 31), ("Z", 30), ("C", 29), ("V", 28), ("I", 27), ("F", 26)]
        var flagButtons: [Widget] = []
        let flags = UI.hbox(spacing: 4)
        for (flag, bit) in flagNames {
            let button = UI.button(flag, classes: ["code"]) {
                guard let psr = model.snapshot?.psr else { return }
                model.setRegister(flag, psr & (1 << UInt32(bit)) != 0 ? 0 : 1)
            }
            flagButtons.append(button)
            UI.append(flags, button)
        }
        let modes = ["USR", "FIQ", "IRQ", "SVC"]
        var updatingMode = false
        let mode = UI.dropDown(modes) { index in
            guard !updatingMode, let psr = model.snapshot?.psr, psr & 3 != UInt32(index) else { return }
            model.setRegister("MODE", UInt32(index))
        }
        UI.append(flags, mode)
        let bankedText = UI.label("", classes: ["code-small", "dim-label"], wrap: true, selectable: true)
        let banked = gtk_expander_new("Banked registers")!
        gtk_expander_set_child(banked.cast(), bankedText)
        let counts = UI.label("", classes: ["dim-label"], wrap: true)
        let stack = UI.vbox(spacing: 1)
        let stackRows = RowList<(UInt32, UInt32?), Widget>(box: stack, make: {
            UI.label("", classes: ["code-small"])
        }) { row, entry, _ in
            UI.setText(row, String(format: "%08X  ", entry.0) + (entry.1.map { String(format: "%08X", $0) } ?? "--------"))
        }
        let content = UI.vbox(spacing: 10, [registers, flags, banked, counts, UI.separator(),
                                            UI.label("Stack (from R13)", classes: ["heading"]), stack])
        content.setMargins(12)
        observe(self) {
            guard let s = model.snapshot else {
                registerRows.show([])
                return
            }
            registerRows.show(s.registers)
            for (button, (flag, bit)) in zip(flagButtons, flagNames) {
                let set = s.psr & (1 << UInt32(bit)) != 0
                button.setClass("suggested-action", set)
                button.setTooltip(set ? "\(flag) is set" : "\(flag) is clear")
                button.setSensitive(model.isStopped)
            }
            updatingMode = true
            UI.select(mode, Int(s.psr & 3))
            updatingMode = false
            mode.setSensitive(model.isStopped)
            UI.setText(bankedText, s.banked.map { mode, regs in
                "\(mode): " + regs.enumerated().map { String(format: "R%d=%08X", $0.offset + 8, $0.element) }.joined(separator: " ")
            }.joined(separator: "\n"))
            UI.setText(counts, "Instruction \(s.instructions), cycle \(s.ticks)")
            stackRows.show(s.stack)
        }
        return UI.scrolled(content)
    }

    // MARK: Breakpoints

    private final class BreakpointRow {
        let widget: Widget
        let toggle: Widget
        let title: Widget
        let detail: Widget
        let hits: Widget
        var breakpoint: Debugger.Breakpoint?

        @MainActor
        init(model: DebuggerModel) {
            toggle = gtk_switch_new()!
            toggle.align(vertical: GTK_ALIGN_CENTER)
            title = UI.label("", classes: ["code-small"])
            detail = UI.label("", classes: ["caption", "dim-label"], wrap: true)
            let text = UI.vbox(spacing: 0, [title, detail])
            text.expand(horizontally: true)
            hits = UI.label("", classes: ["caption", "dim-label"])
            hits.setTooltip("Hits")
            let remove = UI.iconButton("list-remove-symbolic", tooltip: "Remove", classes: ["flat"]) {}
            widget = UI.hbox(spacing: 8, [toggle, text, hits, remove])
            onNotify(toggle, "active") { [unowned self] in
                guard var changed = self.breakpoint else { return }
                let on = gtk_switch_get_active(self.toggle.cast()) != 0
                guard on != changed.enabled else { return }
                changed.enabled = on
                model.updateBreakpoint(changed)
            }
            onSignal(remove, "clicked") { [unowned self] in
                if let id = self.breakpoint?.id { model.removeBreakpoint(id) }
            }
        }
    }

    /// A form's row: a label and its field.
    private static func field(_ label: String, _ widget: Widget) -> Widget {
        let title = UI.label(label, classes: ["dim-label"])
        gtk_widget_set_size_request(title, 76, -1)
        widget.expand(horizontally: true)
        return UI.hbox(spacing: 8, [title, widget])
    }

    private func breakpointsView() -> Widget {
        let model = model
        let list = UI.vbox(spacing: 2)
        list.setMargins(8)
        let rows = RowList<Debugger.Breakpoint, BreakpointRow>(box: list, make: { BreakpointRow(model: model) },
                                                                widget: { $0.widget }) { row, b, _ in
            row.breakpoint = b
            if (gtk_switch_get_active(row.toggle.cast()) != 0) != b.enabled {
                gtk_switch_set_active(row.toggle.cast(), b.enabled ? 1 : 0)
            }
            UI.setText(row.title, Self.title(b))
            let detail = Self.detail(b)
            UI.setText(row.detail, detail ?? "")
            row.detail.setVisible(detail != nil)
            UI.setText(row.hits, "\(b.hitCount)")
        }

        let address = UI.entry(placeholder: "&8000 or expression")
        let end = UI.entry(placeholder: "optional end of range")
        let kinds: [(String, Debugger.Breakpoint.Kind)] = [("Execute", .execute), ("Read", .read), ("Write", .write), ("Read or write", .access)]
        var kind = Debugger.Breakpoint.Kind.execute
        let kindPicker = UI.dropDown(kinds.map(\.0)) { kind = kinds[$0].1 }
        let condition = UI.entry(placeholder: "e.g. R0 == &41")
        let log = UI.entry(placeholder: "log instead of stopping: R0={R0}")
        let add = UI.button("Add Breakpoint", classes: ["suggested-action"]) {
            let text = UI.text(of: address), endText = UI.text(of: end)
            guard let a = model.address(text) else {
                model.message = "Bad address: \(text)"
                return
            }
            let e = endText.isEmpty ? nil : model.address(endText)
            let conditionText = UI.text(of: condition), logText = UI.text(of: log)
            model.addBreakpoint(.init(id: 0, kind: kind, start: kind == .execute ? a & ~3 : a, end: e,
                                      condition: conditionText.isEmpty ? nil : conditionText,
                                      logMessage: logText.isEmpty ? nil : logText))
            UI.setText(editable: address, "")
            UI.setText(editable: end, "")
        }
        let removeAll = UI.button("Remove All") { model.removeAllBreakpoints() }
        let form = UI.vbox(spacing: 6, [
            Self.field("Address", address), Self.field("To", end), Self.field("Stop on", kindPicker),
            Self.field("Condition", condition), Self.field("Log", log), UI.hbox(spacing: 8, [add, UI.spacer(), removeAll]),
        ])
        form.setMargins(8)
        observe(self) {
            let breakpoints = model.snapshot?.breakpoints ?? []
            rows.show(breakpoints)
            removeAll.setSensitive(!breakpoints.isEmpty)
        }
        let scrolled = UI.scrolled(list)
        scrolled.expand(vertically: true)
        return UI.vbox(spacing: 0, [scrolled, UI.separator(), form])
    }

    private static func title(_ b: Debugger.Breakpoint) -> String {
        let k = b.kind == .execute ? "exec" : b.kind == .read ? "read" : b.kind == .write ? "write" : "r/w"
        return "\(k) " + String(format: "&%X", b.start) + (b.end != b.start ? String(format: "-&%X", b.end) : "")
    }

    private static func detail(_ b: Debugger.Breakpoint) -> String? {
        let parts = [b.condition.map { "if \($0)" }, b.logMessage.map { "log \($0)" }, b.hitTarget.map { "from hit \($0)" },
                     b.mode.map { "in \($0)" }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "; ")
    }

    // MARK: Hardware

    private func hardwareView() -> Widget {
        let model = model
        let box = UI.vbox(spacing: 4)
        box.setMargins(12)
        var shape: [[String]] = []
        var values: [[Widget]] = []
        observe(self) {
            let sections = model.snapshot?.hardware ?? []
            let newShape = sections.map { [$0.name] + $0.rows.map(\.label) }
            if newShape != shape {
                shape = newShape
                values = []
                UI.removeAll(box)
                for section in sections {
                    let heading = UI.label(section.name, classes: ["heading"])
                    heading.setMargins(top: 8)
                    UI.append(box, heading)
                    var labels: [Widget] = []
                    for row in section.rows {
                        let label = UI.label(row.label, classes: ["dim-label"])
                        label.align(vertical: GTK_ALIGN_START)
                        let value = UI.label("", classes: ["code-small"], wrap: true, xalign: 1, selectable: true)
                        value.expand(horizontally: true)
                        gtk_label_set_justify(value.cast(), GTK_JUSTIFY_RIGHT)
                        labels.append(value)
                        UI.append(box, UI.hbox(spacing: 8, [label, value]))
                    }
                    values.append(labels)
                }
            }
            for (section, labels) in zip(sections, values) {
                for (row, label) in zip(section.rows, labels) {
                    UI.setText(label, row.value)
                }
            }
        }
        return UI.scrolled(box)
    }

    // MARK: Trace

    private func traceView() -> Widget {
        let model = model
        let toggle = UI.check("Record the last 100,000 instructions", active: false) { on in
            if on != (model.snapshot?.tracing ?? false) { model.setTracing(on) }
        }
        toggle.setMargins(8)
        let box = UI.vbox(spacing: 0)
        box.setMargins(8)
        let rows = RowList<DebugSnapshot.TraceLine, Widget>(box: box, make: {
            let text = UI.label("", classes: ["code-small"])
            gtk_widget_set_size_request(text, 200, -1)
            return UI.hbox(spacing: 8, [UI.label("", classes: ["code-small", "dim-label"]), text,
                                        UI.label("", classes: ["code-small", "dim-label"])])
        }) { row, line, _ in
            let pc = gtk_widget_get_first_child(row)!
            let text = gtk_widget_get_next_sibling(pc)!
            UI.setText(pc, String(format: "%08X", line.pc))
            UI.setText(text, line.text)
            UI.setText(gtk_widget_get_last_child(row)!, line.registers)
        }
        let scrolled = UI.scrolled(box, horizontal: GTK_POLICY_AUTOMATIC)
        scrolled.expand(vertically: true)
        var lastCount: Int?
        var lastText: String?
        observe(self) {
            UI.setActive(check: toggle, model.snapshot?.tracing ?? false)
            let trace = model.snapshot?.trace ?? []
            rows.show(trace)
            if trace.count != lastCount || trace.last?.text != lastText {
                lastCount = trace.count
                lastText = trace.last?.text
                // To the newest, once laid out.
                after(0.05) {
                    let adjustment = gtk_scrolled_window_get_vadjustment(scrolled.cast())
                    gtk_adjustment_set_value(adjustment, gtk_adjustment_get_upper(adjustment))
                }
            }
        }
        return UI.vbox(spacing: 0, [toggle, UI.separator(), scrolled])
    }

    // MARK: Profile

    private func profileView() -> Widget {
        let model = model
        let button = UI.button("Start Profiling") {
            model.setProfiling(!(model.snapshot?.isProfiling ?? false))
        }
        let summary = UI.label("", classes: ["caption", "dim-label"], wrap: true, xalign: 1)
        summary.expand(horizontally: true)
        let top = UI.hbox(spacing: 8, [button, summary])
        top.setMargins(8)
        let explanation = UI.label("Start profiling to count the time spent at every instruction. The disassembly shows where the time goes; routines are grouped by symbol (or by 4 KB).",
                                   classes: ["dim-label"], wrap: true)
        explanation.setMargins(12)
        func makeRow() -> Widget {
            let percent = UI.label("", classes: ["code-small"], xalign: 1)
            gtk_widget_set_size_request(percent, 56, -1)
            let bar = gtk_level_bar_new()!
            gtk_widget_set_size_request(bar, 60, 6)
            bar.align(vertical: GTK_ALIGN_CENTER)
            let name = UI.label("", classes: ["code-small"])
            gtk_label_set_ellipsize(name.cast(), PANGO_ELLIPSIZE_END)
            return UI.hbox(spacing: 8, [percent, bar, name])
        }
        typealias Share = (name: String, share: Double)
        func update(_ row: Widget, _ share: Share, _: Int) {
            let percent = gtk_widget_get_first_child(row)!
            let bar = gtk_widget_get_next_sibling(percent)!
            UI.setText(percent, String(format: "%5.1f%%", share.share * 100))
            gtk_level_bar_set_value(bar.cast(), share.share)
            UI.setText(gtk_widget_get_last_child(row)!, share.name)
        }
        let routines = UI.vbox(spacing: 2), hottest = UI.vbox(spacing: 2)
        let routineRows = RowList<Share, Widget>(box: routines, make: makeRow, update: update)
        let hottestRows = RowList<Share, Widget>(box: hottest, make: makeRow, update: update)
        let lists = UI.vbox(spacing: 8, [UI.label("Routines", classes: ["heading"]), routines,
                                         UI.label("Busiest instructions", classes: ["heading"]), hottest])
        lists.setMargins(12)
        let content = UI.vbox(spacing: 0, [explanation, lists])
        observe(self) {
            let profiling = model.snapshot?.isProfiling == true
            gtk_button_set_label(button.cast(), profiling ? "Stop Profiling" : "Start Profiling")
            if let p = model.snapshot?.profile {
                UI.setText(summary, String(format: "%d frames, %.0f cycles/frame, %.1f%% in interrupts", p.frames, p.ticksPerFrame, 100 * p.interruptShare))
            } else {
                UI.setText(summary, "")
            }
            if let p = model.snapshot?.profile, p.totalTicks > 0 {
                let total = Double(p.totalTicks)
                explanation.setVisible(false)
                lists.setVisible(true)
                routineRows.show(p.routines.prefix(30).map { ($0.name, Double($0.ticks) / total) })
                hottestRows.show(p.hottest.prefix(30).map { (String(format: "&%07X  ×%d", $0.address, $0.executions), Double($0.ticks) / total) })
            } else {
                explanation.setVisible(true)
                lists.setVisible(false)
            }
        }
        return UI.vbox(spacing: 0, [top, UI.separator(), UI.scrolled(content)])
    }

    // MARK: Log

    private func logView() -> Widget {
        let model = model
        let box = UI.vbox(spacing: 6)
        box.setMargins(12)
        let rows = RowList<Debugger.LogEntry, Widget>(box: box, make: {
            UI.vbox(spacing: 0, [UI.label("", classes: ["code-small"], wrap: true, selectable: true), UI.label("", classes: ["caption", "dim-label"])])
        }) { row, entry, _ in
            UI.setText(gtk_widget_get_first_child(row)!, entry.text)
            UI.setText(gtk_widget_get_last_child(row)!, "cycle \(entry.ticks)")
        }
        let empty = UI.label("Log points’ output appears here. Add a breakpoint with a log message to log instead of stopping.",
                             classes: ["dim-label"], wrap: true, xalign: 0.5)
        empty.setMargins(24)
        observe(self) {
            let log = model.snapshot?.log ?? []
            rows.show(log)
            empty.setVisible(log.isEmpty)
        }
        let scrolled = UI.scrolled(box)
        scrolled.expand(vertically: true)
        return UI.vbox(spacing: 0, [empty, scrolled])
    }

    // MARK: BASIC listing

    private final class BasicLineRow {
        let widget: Widget
        let dot: Widget
        let marker: Widget
        let number: Widget
        let text: Widget
        var line: BasicDebugSnapshot.Line?

        @MainActor
        init(toggle: @escaping @MainActor (BasicLineRow) -> Void, edit: @escaping @MainActor (BasicLineRow) -> Void) {
            dot = gtk_button_new()!
            dot.addClass("breakpoint-dot")
            dot.align(vertical: GTK_ALIGN_CENTER)
            marker = UI.label("", classes: ["code"])
            gtk_widget_set_size_request(marker, 14, -1)
            number = UI.label("", classes: ["code", "dim-label"], xalign: 1)
            text = UI.label("", classes: ["code"])
            text.expand(horizontally: true)
            widget = UI.hbox(spacing: 8, [dot, marker, number, text], classes: ["disassembly-row"])
            onSignal(dot, "clicked") { [unowned self] in toggle(self) }
            // A right click edits the line's breakpoint.
            let click = gtk_gesture_click_new()!
            gtk_gesture_single_set_button(click.cast(), 3)
            onClick(click, "pressed") { [unowned self] _, _, _ in edit(self) }
            widget.addController(click)
        }
    }

    private func basicListingPanel() -> Widget {
        let model = model
        let interpreter = UI.label("", classes: ["dim-label"])
        let goTo = UI.entry(placeholder: "Go to line", width: 10)
        onSignal(goTo, "activate") {
            if let line = Int(UI.text(of: goTo).trimmingCharacters(in: .whitespaces)) { model.showBasicLine(line) }
        }
        let current = UI.button("Current") { if let line = model.basic?.stop?.line { model.showBasicLine(line) } }
        current.setTooltip("Show the line it’s stopped at")
        let toolbar = UI.hbox(spacing: 6, [UI.label("BASIC", classes: ["heading"]), interpreter, UI.spacer(), goTo, current])
        toolbar.setMargins(8)
        let errorLabel = UI.label("", classes: ["error-text"], wrap: true)
        errorLabel.setMargins(8)
        let placeholder = UI.label("", classes: ["dim-label"], wrap: true, xalign: 0.5)
        placeholder.setMargins(24)
        placeholder.expand(vertically: true)

        let box = UI.vbox()
        box.setMargins(top: 4, bottom: 4)
        let rows = RowList<BasicDebugSnapshot.Line, BasicLineRow>(box: box, make: { [weak self] in
            BasicLineRow(toggle: { row in
                if let line = row.line { model.toggleBasicBreakpoint(line: line.number) }
            }, edit: { [weak self] row in
                self?.editBasicBreakpoint(row)
            })
        }, widget: { $0.widget }) { row, line, _ in
            row.line = line
            let basic = model.basic
            let isCurrent = basic?.stop?.line == line.number
            let hasBreakpoint = !line.breakpoints.isEmpty
            let enabled = line.breakpoints.contains { $0.enabled }
            let conditional = line.breakpoints.contains { $0.condition != nil || $0.hitTarget != nil || $0.logMessage != nil || $0.statement != nil }
            row.dot.setClass("set", hasBreakpoint && enabled)
            row.dot.setClass("disabled", hasBreakpoint && !enabled)
            row.dot.setClass("conditional", conditional)
            row.dot.setTooltip(hasBreakpoint ? "Remove the breakpoint (right-click to edit it)" : "Stop at this line (right-click for a condition)")
            UI.setText(row.marker, isCurrent ? "▶" : "")
            let width = String(basic?.lines.last?.number ?? 0).count
            UI.setText(row.number, String(repeating: " ", count: max(0, width - String(line.number).count)) + String(line.number))
            if isCurrent, let stop = basic?.stop, let range = Self.statement(stop.statement, in: line.text),
               range != line.text.startIndex..<line.text.endIndex {
                let markup = UI.escape(String(line.text[..<range.lowerBound])) + "<b><u>" + UI.escape(String(line.text[range]))
                    + "</u></b>" + UI.escape(String(line.text[range.upperBound...]))
                gtk_label_set_markup(row.text.cast(), markup)
            } else {
                UI.setText(row.text, line.text)
            }
            row.widget.setClass("pc", isCurrent)
            row.widget.setClass("stopped", isCurrent && model.isStopped)
            row.widget.setClass("error-line", isCurrent && basic?.error != nil)
        }
        let scrolled = UI.scrolled(box, horizontal: GTK_POLICY_AUTOMATIC)
        scrolled.expand(vertically: true)
        let message = UI.label("", classes: ["error-text"], wrap: true)
        message.setMargins(6)

        var lastStop: BasicLocation?
        var lastRequest: DebuggerModel.ScrollRequest?
        observe(self) { [weak self] in
            guard let self else { return }
            let basic = model.basic
            UI.setText(interpreter, basic?.interpreter ?? "")
            current.setSensitive(basic?.stop != nil)
            if let error = basic?.error {
                UI.setText(errorLabel, "Error \(error.number) at \(error.location): \(error.message)" + (error.trapped ? " (ON ERROR will handle it)" : ""))
                errorLabel.setVisible(true)
            } else {
                errorLabel.setVisible(false)
            }
            if let basic, basic.interpreter == nil {
                UI.setText(placeholder, "No BASIC found\n\nThis ROM’s BASIC isn’t one the debugger knows.")
            } else if let basic, basic.lines.isEmpty {
                UI.setText(placeholder, "No program in memory\n\nPress F12 and type BASIC, then type a program in, LOAD one or drop a .bas file on the machine. Breakpoints set in the Breakpoints tab wait for their lines.")
            }
            let empty = basic.map { $0.interpreter == nil || $0.lines.isEmpty } ?? false
            placeholder.setVisible(empty)
            scrolled.setVisible(!empty)
            rows.show(basic?.lines ?? [])
            UI.setText(message, model.message ?? "")
            message.setVisible(model.message != nil)
            // Follow the stop, or a line asked for.
            if basic?.stop != lastStop || model.basicScrollRequest != lastRequest {
                let target = model.basicScrollRequest != lastRequest ? model.basicScrollRequest?.line : basic?.stop?.line
                lastStop = basic?.stop
                lastRequest = model.basicScrollRequest
                if let target { after(0.05) { [weak self] in self?.scrollListing(scrolled, rows: rows, to: target) } }
            }
        }
        return UI.vbox(spacing: 0, [toolbar, UI.separator(), errorLabel, placeholder, scrolled, message])
    }

    /// Scrolls the listing so the line (or the nearest after it) is in the
    /// middle.
    private func scrollListing(_ scrolled: Widget, rows: RowList<BasicDebugSnapshot.Line, BasicLineRow>, to target: Int) {
        guard let row = rows.rows.first(where: { ($0.line?.number ?? -1) >= target }) ?? rows.rows.last else { return }
        var bounds = graphene_rect_t()
        guard gtk_widget_compute_bounds(row.widget, rows.box, &bounds) != 0 else { return }
        let adjustment = gtk_scrolled_window_get_vadjustment(scrolled.cast())
        let page = gtk_adjustment_get_page_size(adjustment)
        gtk_adjustment_set_value(adjustment, Double(bounds.origin.y) - page / 2)
    }

    /// Where statement `n` (from 1) is in a listed line: colons outside
    /// quotes separate them.
    static func statement(_ n: Int, in text: String) -> Range<String.Index>? {
        var starts = [text.startIndex]
        var quoted = false
        var index = text.startIndex
        while index < text.endIndex {
            let c = text[index]
            if c == "\"" { quoted.toggle() }
            if !quoted && c == ":" { starts.append(text.index(after: index)) }
            index = text.index(after: index)
        }
        guard n >= 1 && n <= starts.count else { return nil }
        let end = n < starts.count ? text.index(before: starts[n]) : text.endIndex
        return starts[n - 1]..<end
    }

    /// A line's breakpoint: its statement, condition, hit count or log, in
    /// a popover.
    private func editBasicBreakpoint(_ row: BasicLineRow) {
        guard let line = row.line else { return }
        let model = model
        let existing = line.breakpoints.first
        let popover = gtk_popover_new()!
        let statement = UI.entry(placeholder: "any (as the line is entered)")
        let condition = UI.entry(placeholder: "BASIC, e.g. I%>10")
        let hitCount = UI.entry(placeholder: "the first")
        let logMessage = UI.entry(placeholder: "log instead: I%={I%}")
        UI.setText(editable: statement, existing?.statement.map(String.init) ?? "")
        UI.setText(editable: condition, existing?.condition ?? "")
        UI.setText(editable: hitCount, existing?.hitTarget.map(String.init) ?? "")
        UI.setText(editable: logMessage, existing?.logMessage ?? "")
        let save = UI.button(existing == nil ? "Add" : "Save", classes: ["suggested-action"]) {
            var b = existing ?? BasicBreakpoint(line: line.number)
            b.statement = Int(UI.text(of: statement).trimmingCharacters(in: .whitespaces))
            let c = UI.text(of: condition)
            b.condition = c.trimmingCharacters(in: .whitespaces).isEmpty ? nil : c
            b.hitTarget = Int(UI.text(of: hitCount).trimmingCharacters(in: .whitespaces))
            let l = UI.text(of: logMessage)
            b.logMessage = l.isEmpty ? nil : l
            if existing == nil { model.addBasicBreakpoint(b) } else { model.updateBasicBreakpoint(b) }
            gtk_popover_popdown(popover.cast())
        }
        var buttons = [UI.spacer(), save]
        if let existing {
            buttons.insert(UI.button("Remove", classes: ["destructive-action"]) {
                model.removeBasicBreakpoint(id: existing.id)
                gtk_popover_popdown(popover.cast())
            }, at: 0)
        }
        let box = UI.vbox(spacing: 6, [
            UI.label("Breakpoint at line \(line.number)", classes: ["heading"]),
            Self.field("Statement", statement), Self.field("Condition", condition), Self.field("From hit", hitCount),
            Self.field("Log", logMessage), UI.hbox(spacing: 8, buttons),
        ])
        box.setMargins(8)
        gtk_widget_set_size_request(box, 340, -1)
        gtk_popover_set_child(popover.cast(), box)
        gtk_widget_set_parent(popover, row.dot)
        onSignal(popover, "closed") { after(0) { gtk_widget_unparent(popover) } }
        gtk_popover_popup(popover.cast())
    }

    // MARK: BASIC variables

    /// A row of the variables list: a heading, a variable, an array's
    /// element, or how many more elements there are.
    private enum VariableItem {
        case heading(String)
        case variable(BasicVariable)
        case element(array: String, indices: [Int], value: BasicValue)
        case more(Int)
    }

    private final class VariableRow {
        let widget: Widget
        let arrow: Widget
        let name: Widget
        let value: Widget
        var item: VariableItem?

        @MainActor
        init(activate: @escaping @MainActor (VariableRow) -> Void) {
            arrow = UI.label("", classes: ["dim-label"])
            gtk_widget_set_size_request(arrow, 12, -1)
            name = UI.label("", classes: ["code-small"])
            value = UI.label("", classes: ["code-small", "dim-label"], xalign: 1)
            value.expand(horizontally: true)
            gtk_label_set_ellipsize(value.cast(), PANGO_ELLIPSIZE_END)
            widget = UI.hbox(spacing: 6, [arrow, name, value])
            widget.setMargins(top: 1, bottom: 1, start: 8, end: 8)
            let click = gtk_gesture_click_new()!
            onClick(click, "pressed") { [unowned self] presses, _, _ in
                // Arrays open with a click; values change with a double-click.
                if case .variable(let v) = self.item, v.dimensions != nil { activate(self) } else if presses == 2 { activate(self) }
            }
            widget.addController(click)
        }
    }

    private func basicVariablesPanel() -> Widget {
        let model = model
        let showAllKey = "basicShowAllResident"
        var showAll = Preferences.standard.bool(forKey: showAllKey)
        var filter = ""
        let all = UI.check("All @%–Z%", active: showAll) { on in
            showAll = on
            Preferences.standard.set(on, forKey: showAllKey)
            model.refresh()
        }
        all.setTooltip("Show the resident integers even when they’re 0")
        let filterEntry = UI.entry(placeholder: "Filter", width: 12)
        let toolbar = UI.hbox(spacing: 6, [UI.label("Variables", classes: ["heading"]), UI.spacer(), all, filterEntry])
        toolbar.setMargins(8)
        let empty = UI.label("", classes: ["dim-label"], xalign: 0.5)
        empty.setMargins(24)

        let box = UI.vbox()
        box.setMargins(top: 4, bottom: 4)
        let rows = RowList<VariableItem, VariableRow>(box: box, make: { [weak self] in
            VariableRow { [weak self] row in self?.activate(row) }
        }, widget: { $0.widget }) { row, item, _ in
            row.item = item
            row.name.setClass("heading", false)
            switch item {
            case .heading(let title):
                UI.setText(row.arrow, "")
                UI.setText(row.name, title)
                row.name.setClass("heading", true)
                UI.setText(row.value, "")
                row.widget.setTooltip(nil)
            case .variable(let v):
                if let dimensions = v.dimensions {
                    UI.setText(row.arrow, model.view.basicExpanded.contains(v.name) ? "▾" : "▸")
                    UI.setText(row.name, v.name + dimensions.map(String.init).joined(separator: ",") + ")")
                    UI.setText(row.value, v.kind.rawValue)
                    row.widget.setTooltip("Click to show its elements")
                } else {
                    UI.setText(row.arrow, "")
                    UI.setText(row.name, v.name)
                    UI.setText(row.value, v.value?.description ?? "")
                    row.widget.setTooltip("Double-click to change it")
                }
            case .element(let array, let indices, let value):
                UI.setText(row.arrow, "")
                UI.setText(row.name, "  " + array + indices.map(String.init).joined(separator: ",") + ")")
                UI.setText(row.value, value.description)
                row.widget.setTooltip("Double-click to change it")
            case .more(let count):
                UI.setText(row.arrow, "")
                UI.setText(row.name, "  …and \(count) more")
                UI.setText(row.value, "")
                row.widget.setTooltip(nil)
            }
        }
        func update() {
            let variables = (model.basic?.variables ?? []).filter { v in
                v.name.hasPrefix(filter) && (showAll || !v.isResident || v.value != .integer(0))
            }
            var items: [VariableItem] = []
            func section(_ title: String, _ vs: [BasicVariable]) {
                guard !vs.isEmpty else { return }
                items.append(.heading(title))
                for v in vs {
                    items.append(.variable(v))
                    if let dimensions = v.dimensions, model.view.basicExpanded.contains(v.name) {
                        for element in model.basic?.elements[v.name] ?? [] {
                            items.append(.element(array: v.name, indices: element.indices, value: element.value))
                        }
                        let count = dimensions.reduce(1) { $0 * ($1 + 1) }
                        if count > BasicDebugSnapshot.elementLimit { items.append(.more(count - BasicDebugSnapshot.elementLimit)) }
                    }
                }
            }
            section("Local", variables.filter(\.isLocal))
            section("Variables", variables.filter { !$0.isLocal && !$0.isResident && $0.dimensions == nil })
            section("Arrays", variables.filter { !$0.isLocal && $0.dimensions != nil })
            section("Resident integers", variables.filter { !$0.isLocal && $0.isResident })
            rows.show(items)
            UI.setText(empty, filter.isEmpty ? "No variables yet: RUN the program." : "No variables starting \(filter)")
            empty.setVisible(variables.isEmpty)
        }
        onSignal(filterEntry, "changed") {
            filter = UI.text(of: filterEntry)
            update()
        }
        observe(self) { update() }
        let scrolled = UI.scrolled(box)
        scrolled.expand(vertically: true)
        return UI.vbox(spacing: 0, [toolbar, UI.separator(), empty, scrolled])
    }

    /// An array opens or closes; a value is changed in a popover.
    private func activate(_ row: VariableRow) {
        guard let item = row.item else { return }
        let model = model
        switch item {
        case .variable(let v) where v.dimensions != nil:
            model.toggleBasicArray(v.name)
        case .variable(let v):
            guard let value = v.value else { return }
            Self.popoverEntry(on: row.value, text: value.description, width: 24, title: "\(v.name) =",
                              note: "A BASIC expression: strings in quotes.") { text in
                model.setBasicVariable(v.name, to: text)
            }
        case .element(let array, let indices, let value):
            Self.popoverEntry(on: row.value, text: value.description, width: 24,
                              title: array + indices.map(String.init).joined(separator: ",") + ") =",
                              note: "A BASIC expression: strings in quotes.") { text in
                model.setBasicVariable(array, indices: indices, to: text)
            }
        default:
            break
        }
    }

    // MARK: BASIC calls, breakpoints and watches

    private func basicCallsView() -> Widget {
        let model = model
        let box = UI.vbox(spacing: 4)
        box.setMargins(8)
        let rows = RowList<(Int, BasicFrame), Widget>(box: box, make: {
            let name = UI.label("", classes: ["code-small"])
            let place = UI.label("", classes: ["caption", "dim-label"])
            let button = gtk_button_new()!
            button.addClass("flat")
            gtk_button_set_child(button.cast(), UI.vbox(spacing: 0, [name, place]))
            return button
        }) { button, entry, _ in
            let (index, frame) = entry
            let content = gtk_button_get_child(button.cast())!
            let name = gtk_widget_get_first_child(content)!
            UI.setText(name, frame.name.map { $0 == "?" ? "(not followed further)" : $0 } ?? "Main program")
            name.setClass("heading", index == 0)
            UI.setText(gtk_widget_get_last_child(content)!,
                       frame.location.map { (index == 0 ? "at " : "called at ") + "\($0)" } ?? "from a command typed in")
            g_object_set_data(button.object, "line", frame.location.map { UnsafeMutableRawPointer(bitPattern: $0.line + 1) } ?? nil)
        }
        let empty = UI.label("Stop in the program (a breakpoint, a step, or Pause in BASIC) to see its PROC and FN calls.",
                             classes: ["dim-label"], wrap: true, xalign: 0.5)
        empty.setMargins(24)
        var connected = 0
        observe(self) {
            let frames = model.basic?.frames ?? []
            rows.show(Array(frames.enumerated()))
            // Each row's click shows its line (connected once per row).
            while connected < rows.rows.count {
                let button = rows.rows[connected]
                onSignal(button, "clicked") {
                    if let data = g_object_get_data(button.object, "line") { model.showBasicLine(Int(bitPattern: data) - 1) }
                }
                connected += 1
            }
            empty.setVisible(frames.isEmpty)
        }
        return UI.vbox(spacing: 0, [empty, UI.scrolled(box)])
    }

    private final class BasicBreakpointRow {
        let widget: Widget
        let toggle: Widget
        let title: Widget
        let detail: Widget
        let hits: Widget
        var breakpoint: BasicBreakpoint?

        @MainActor
        init(model: DebuggerModel) {
            toggle = gtk_switch_new()!
            toggle.align(vertical: GTK_ALIGN_CENTER)
            title = UI.label("", classes: ["code-small"])
            detail = UI.label("", classes: ["caption", "dim-label"], wrap: true)
            let show = gtk_button_new()!
            show.addClass("flat")
            gtk_button_set_child(show.cast(), UI.vbox(spacing: 0, [title, detail]))
            show.expand(horizontally: true)
            hits = UI.label("", classes: ["caption", "dim-label"])
            hits.setTooltip("Hits")
            let remove = UI.iconButton("list-remove-symbolic", tooltip: "Remove", classes: ["flat"]) {}
            widget = UI.hbox(spacing: 8, [toggle, show, hits, remove])
            onNotify(toggle, "active") { [unowned self] in
                guard var changed = self.breakpoint else { return }
                let on = gtk_switch_get_active(self.toggle.cast()) != 0
                guard on != changed.enabled else { return }
                changed.enabled = on
                model.updateBasicBreakpoint(changed)
            }
            onSignal(show, "clicked") { [unowned self] in
                if let line = self.breakpoint?.line { model.showBasicLine(line) }
            }
            onSignal(remove, "clicked") { [unowned self] in
                if let id = self.breakpoint?.id { model.removeBasicBreakpoint(id: id) }
            }
        }
    }

    private func basicBreakpointsView() -> Widget {
        let model = model
        let errorStops: [(String, BasicDebugger.ErrorStop)] = [("Off", .off), ("Untrapped", .untrapped), ("All", .all)]
        let stops = adw_toggle_group_new()!
        for (label, _) in errorStops {
            let toggle = adw_toggle_new()!
            adw_toggle_set_name(toggle, label)
            adw_toggle_set_label(toggle, label)
            adw_toggle_group_add(stops.cast(), toggle)
        }
        stops.setTooltip("Stop where an error happens: those no ON ERROR handles (Escape and STOP too), or all of them")
        onNotify(stops, "active-name") {
            guard let name = String(gBorrowed: adw_toggle_group_get_active_name(stops.cast())),
                  let stop = errorStops.first(where: { $0.0 == name })?.1, stop != model.basic?.errorStop else { return }
            model.setBasicErrorStop(stop)
        }
        let stopRow = Self.field("Stop on errors", stops)
        stopRow.setMargins(8)

        let list = UI.vbox(spacing: 2)
        list.setMargins(8)
        let rows = RowList<BasicBreakpoint, BasicBreakpointRow>(box: list, make: { BasicBreakpointRow(model: model) },
                                                                 widget: { $0.widget }) { row, b, _ in
            row.breakpoint = b
            if (gtk_switch_get_active(row.toggle.cast()) != 0) != b.enabled {
                gtk_switch_set_active(row.toggle.cast(), b.enabled ? 1 : 0)
            }
            UI.setText(row.title, "Line \(b.line)" + (b.statement.map { " statement \($0)" } ?? ""))
            var parts: [String] = []
            if let c = b.condition { parts.append("if \(c)") }
            if let l = b.logMessage { parts.append("log \(l)") }
            if let h = b.hitTarget { parts.append("from hit \(h)") }
            if let lines = model.basic?.lines, !lines.isEmpty, !lines.contains(where: { $0.number == b.line }) { parts.append("no such line") }
            UI.setText(row.detail, parts.joined(separator: "; "))
            row.detail.setVisible(!parts.isEmpty)
            UI.setText(row.hits, "\(b.hitCount)")
        }

        let line = UI.entry(placeholder: "e.g. 120")
        let statement = UI.entry(placeholder: "optional: 1 is the first")
        let condition = UI.entry(placeholder: "BASIC, e.g. I%>10")
        let log = UI.entry(placeholder: "log instead of stopping: I%={I%}")
        let add = UI.button("Add Breakpoint", classes: ["suggested-action"]) {
            guard let number = Int(UI.text(of: line).trimmingCharacters(in: .whitespaces)) else { return }
            let c = UI.text(of: condition), l = UI.text(of: log)
            model.addBasicBreakpoint(BasicBreakpoint(line: number, statement: Int(UI.text(of: statement).trimmingCharacters(in: .whitespaces)),
                                                     condition: c.trimmingCharacters(in: .whitespaces).isEmpty ? nil : c,
                                                     logMessage: l.isEmpty ? nil : l))
            for entry in [line, statement, condition, log] { UI.setText(editable: entry, "") }
        }
        add.setSensitive(false)
        onSignal(line, "changed") { add.setSensitive(Int(UI.text(of: line).trimmingCharacters(in: .whitespaces)) != nil) }
        let removeAll = UI.button("Remove All") { model.removeAllBasicBreakpoints() }
        let form = UI.vbox(spacing: 6, [
            Self.field("Line", line), Self.field("Statement", statement), Self.field("Condition", condition),
            Self.field("Log", log), UI.hbox(spacing: 8, [add, UI.spacer(), removeAll]),
        ])
        form.setMargins(8)
        observe(self) {
            let basic = model.basic
            rows.show(basic?.breakpoints ?? [])
            removeAll.setSensitive(!(basic?.breakpoints.isEmpty ?? true))
            let name = errorStops.first { $0.1 == basic?.errorStop ?? .off }?.0 ?? "Off"
            if String(gBorrowed: adw_toggle_group_get_active_name(stops.cast())) != name {
                adw_toggle_group_set_active_name(stops.cast(), name)
            }
        }
        let scrolled = UI.scrolled(list)
        scrolled.expand(vertically: true)
        return UI.vbox(spacing: 0, [stopRow, UI.separator(), scrolled, UI.separator(), form])
    }

    private func basicWatchView() -> Widget {
        let model = model
        let expression = UI.entry(placeholder: "e.g. total/count%")
        expression.expand(horizontally: true)
        let addWatch: Handler = {
            model.addBasicWatch(UI.text(of: expression))
            UI.setText(editable: expression, "")
        }
        onSignal(expression, "activate", addWatch)
        let watch = UI.button("Watch", addWatch)
        let top = UI.hbox(spacing: 6, [expression, watch])
        top.setMargins(8)
        let box = UI.vbox(spacing: 4)
        box.setMargins(8)
        let rows = RowList<BasicDebugSnapshot.Watch, Widget>(box: box, make: {
            let name = UI.label("", classes: ["code-small"])
            let value = UI.label("", classes: ["code-small", "dim-label"], wrap: true, xalign: 1)
            value.expand(horizontally: true)
            let remove = gtk_button_new()!
            gtk_button_set_icon_name(remove.cast(), "list-remove-symbolic")
            remove.addClass("flat")
            remove.setTooltip("Stop watching")
            onSignal(remove, "clicked") {
                if let data = g_object_get_data(remove.object, "expression") {
                    model.removeBasicWatch(Unmanaged<NSString>.fromOpaque(data).takeUnretainedValue() as String)
                }
            }
            return UI.hbox(spacing: 8, [name, value, remove])
        }) { row, watch, _ in
            let name = gtk_widget_get_first_child(row)!
            let value = gtk_widget_get_next_sibling(name)!
            UI.setText(name, watch.expression)
            switch watch.result {
            case .success(let v):
                UI.setText(value, v.description)
                value.setClass("error-text", false)
            case .failure(let error):
                UI.setText(value, error.message)
                value.setClass("error-text", true)
            }
            let remove = gtk_widget_get_last_child(row)!
            g_object_set_data_full(remove.object, "expression", Unmanaged.passRetained(watch.expression as NSString).toOpaque()) { data in
                if let data { Unmanaged<NSString>.fromOpaque(data).release() }
            }
        }
        let empty = UI.label("Watch BASIC expressions: variables, array elements, arithmetic and comparisons. They update as the program runs.",
                             classes: ["dim-label"], wrap: true, xalign: 0.5)
        empty.setMargins(24)
        observe(self) {
            let watches = model.basic?.watches ?? []
            rows.show(watches)
            empty.setVisible(watches.isEmpty)
        }
        return UI.vbox(spacing: 0, [top, UI.separator(), empty, UI.scrolled(box)])
    }
}
