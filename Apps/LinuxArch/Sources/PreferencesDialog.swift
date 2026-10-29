import ArchimedesCore
import CGtk
import Foundation

/// Preferences: the mouse, the keyboard and its custom keys, and the ROM
/// list. (The Mac app's Settings and ROMs windows.)
@MainActor
enum PreferencesDialog {
    enum Page: String {
        case general, roms, debugging, networking
    }

    static func present(parent: Widget?, page: Page = .general) {
        let dialog = adw_preferences_dialog_new()!
        adw_dialog_set_content_width(dialog.cast(), 620)
        adw_dialog_set_content_height(dialog.cast(), 640)
        let general = generalPage(dialog: dialog.widget)
        let roms = romsPage(dialog: dialog.widget)
        let debugging = debuggingPage()
        let networking = networkingPage()
        for added in [general, roms, debugging, networking] {
            adw_preferences_dialog_add(dialog.cast(), added.cast())
        }
        let shown = switch page {
        case .general: general
        case .roms: roms
        case .debugging: debugging
        case .networking: networking
        }
        adw_preferences_dialog_set_visible_page(dialog.cast(), shown.cast())
        adw_dialog_present(dialog.cast(), parent)
    }

    // MARK: General

    private static func generalPage(dialog: Widget) -> Widget {
        let page = adw_preferences_page_new()!
        adw_preferences_page_set_title(page.cast(), "General")
        adw_preferences_page_set_icon_name(page.cast(), "preferences-system-symbolic")
        let settings = AppSettings.shared

        let modes = AppSettings.MouseMode.allCases
        let mouseMode = UI.comboRow("Mouse", modes.map(\.name), selected: modes.firstIndex(of: settings.mouseMode) ?? 0) { index in
            settings.mouseMode = modes[index]
        }
        let clicks = AppSettings.SecondaryClick.allCases
        let rightButton = UI.comboRow("Right Button", clicks.map(\.name), selected: clicks.firstIndex(of: settings.secondaryClick) ?? 0) { index in
            settings.secondaryClick = clicks[index]
        }
        let mouse = UI.preferencesGroup("Mouse",
            description: "Capture the mouse with a click (Ctrl+Shift+M lets it go), or leave it free, with RISC OS’s pointer following the desktop’s. The Archimedes mouse’s buttons are Select, Menu and Adjust: left is Select, and the middle button is whichever of the other two the right isn’t.",
            [mouseMode, rightButton])

        let keyboard = KeyboardSettings.shared
        let keyModes = KeyboardSettings.Mode.allCases
        let keyMode = UI.comboRow("Keys", keyModes.map(\.shortName), selected: keyModes.firstIndex(of: keyboard.mode) ?? 0) { index in
            keyboard.mode = keyModes[index]
        }
        let keys = UI.preferencesGroup("Keyboard",
            description: "By position, each key is the Archimedes key in its place (End is Copy, Pause is Break, the key left of Z is £); by character, keys type what your keyboard’s layout says.",
            [keyMode])

        let mappings = UI.preferencesGroup("Custom Keys", description: "PC keys that press another Archimedes key, before the rest of the keyboard.")
        let add = UI.button("_Add…", classes: ["flat"]) { recordMapping(parent: dialog) }
        adw_preferences_group_set_header_suffix(mappings.cast(), add)
        var rows: [Widget] = []
        observe(widget: mappings) {
            for row in rows { adw_preferences_group_remove(mappings.cast(), row) }
            rows = KeyboardSettings.shared.mappings.map { mapping in
                let name = KeyboardSettings.catalogue.first { $0.code == mapping.arcKey }?.name ?? "Key \(mapping.arcKey)"
                let remove = UI.iconButton("user-trash-symbolic", tooltip: "Remove", classes: ["flat"]) {
                    KeyboardSettings.shared.removeMapping(keyCode: mapping.keyCode)
                }
                return UI.actionRow(mapping.keyName, subtitle: "Presses \(name)", suffixes: [remove])
            }
            if rows.isEmpty {
                rows = [UI.actionRow("None", subtitle: "Every key is where the Archimedes has it")]
            }
            for row in rows { adw_preferences_group_add(mappings.cast(), row) }
        }

        for group in [opening(), mouse, keys, mappings, gameLibrary(dialog: dialog)] {
            adw_preferences_page_add(page.cast(), group.cast())
        }
        return page
    }

    /// What LinuxArch shows when it opens.
    private static func opening() -> Widget {
        let group = UI.preferencesGroup("When LinuxArch Opens",
            description: "Opening with only the Game Library suits playing games: choose one and its Archimedes opens, set up to play it. The Network Studio opens the network you used last. Takes effect the next time LinuxArch opens.")
        var first: Widget?
        for screen in LaunchScreen.allCases {
            let check = gtk_check_button_new()!
            if let first { gtk_check_button_set_group(check.cast(), first.cast()) } else { first = check }
            gtk_check_button_set_active(check.cast(), LaunchScreen.preference == screen ? 1 : 0)
            check.align(vertical: GTK_ALIGN_CENTER)
            let row = adw_action_row_new()!
            adw_preferences_row_set_title(row.cast(), "Show " + screen.title.prefix(1).lowercased() + screen.title.dropFirst())
            adw_action_row_add_prefix(row.cast(), check)
            adw_action_row_set_activatable_widget(row.cast(), check)
            onSignal(check, "toggled") {
                if gtk_check_button_get_active(check.cast()) != 0 { LaunchScreen.preference = screen }
            }
            adw_preferences_group_add(group.cast(), row)
        }
        return group
    }

    /// Whether, and where, to look for the Classics' downloaded discs.
    private static func gameLibrary(dialog: Widget) -> Widget {
        let classics = ClassicsLibrary.shared
        let auto = adw_switch_row_new()!
        adw_preferences_row_set_title(auto.cast(), "Add downloaded Classics’ discs automatically")
        adw_switch_row_set_active(auto.cast(), classics.autoDetect == true ? 1 : 0)
        let folder = UI.label("", classes: ["dim-label"])
        let choose = UI.button("Choose…", classes: ["flat"]) {
            FileDialogs.chooseFolder(parent: dialog, title: "Look for Downloaded Discs In", initial: classics.downloadFolder) { url in
                classics.downloadFolder = url
            }
        }
        let folderRow = UI.actionRow("Look in", suffixes: [folder, choose])
        onNotify(auto, "active") {
            classics.autoDetect = adw_switch_row_get_active(auto.cast()) != 0
        }
        observe(widget: folder) {
            UI.setText(folder, classics.downloadFolder.lastPathComponent)
            folderRow.setSensitive(classics.autoDetect == true)
        }
        return UI.preferencesGroup("Game Library",
            description: "The Archimedes Classics’ discs come from the Archimedes Archive, downloaded in your browser. LinuxArch recognises them in this folder and adds them to the Game Library. It only reads them, and only while it’s open.",
            [auto, folderRow])
    }

    /// Asks for a PC key, then the Archimedes key it presses.
    private static func recordMapping(parent: Widget) {
        let prompt = UI.label("Press the PC key to assign…", classes: ["title-4"], xalign: 0.5)
        var pressed: (code: UInt16, name: String)?
        let catalogue = KeyboardSettings.catalogue
        var chosen = 0
        let picker = UI.searchableDropDown(catalogue.map(\.name), selected: 0) { chosen = $0 }
        picker.setSensitive(false)
        let box = UI.vbox(spacing: 12, [prompt, picker])
        let dialog = adw_alert_dialog_new("Custom Key", "The key goes down and up with the PC key, whatever else is held.")!
        adw_alert_dialog_set_extra_child(dialog.cast(), box)
        adw_alert_dialog_add_response(dialog.cast(), "cancel", "Cancel")
        adw_alert_dialog_add_response(dialog.cast(), "ok", "Assign")
        adw_alert_dialog_set_response_appearance(dialog.cast(), "ok", ADW_RESPONSE_SUGGESTED)
        adw_alert_dialog_set_response_enabled(dialog.cast(), "ok", 0)
        adw_alert_dialog_set_close_response(dialog.cast(), "cancel")

        let keys = gtk_event_controller_key_new()!
        gtk_event_controller_set_propagation_phase(keys, GTK_PHASE_CAPTURE)
        onKey(keys, "key-pressed") { keyval, keycode, _ in
            // Until a key's chosen, every key is the one to assign.
            guard pressed == nil, let code = LinuxKeyMap.evdev(gdkKeycode: keycode) else { return false }
            let unicode = gdk_keyval_to_unicode(keyval)
            let character = unicode > 0 ? Unicode.Scalar(unicode).map { String(Character($0)) } : nil
            let name = KeyboardSettings.name(keyCode: code, character: character)
            pressed = (code, name)
            UI.setText(prompt, name)
            let current = KeyboardSettings.shared.currentKey(for: code)
            chosen = catalogue.firstIndex { $0.code == current } ?? 0
            UI.select(picker, chosen)
            picker.setSensitive(true)
            adw_alert_dialog_set_response_enabled(dialog.cast(), "ok", 1)
            gtk_widget_grab_focus(picker)
            return true
        }
        dialog.addController(keys)

        let callback: GAsyncReadyCallback = { source, result, data in
            let completion = Unmanaged<Box<@MainActor (String) -> Void>>.fromOpaque(data!).takeRetainedValue().value
            let response = source.flatMap { source in
                result.flatMap { String(gBorrowed: adw_alert_dialog_choose_finish(source.cast(), $0.opaque)) }
            } ?? ""
            MainActor.assumeIsolated { completion(response) }
        }
        let completion: @MainActor (String) -> Void = { response in
            guard response == "ok", let pressed, catalogue.indices.contains(chosen) else { return }
            KeyboardSettings.shared.setMapping(keyCode: pressed.code, keyName: pressed.name, to: catalogue[chosen].code)
        }
        adw_alert_dialog_choose(dialog.cast(), parent, nil, callback, Box(completion).retained)
    }

    // MARK: Debugging

    /// The debug adapter VS Code connects to.
    private static func debuggingPage() -> Widget {
        let page = adw_preferences_page_new()!
        adw_preferences_page_set_title(page.cast(), "Debugging")
        adw_preferences_page_set_icon_name(page.cast(), "system-run-symbolic")
        let settings = AppSettings.shared
        let enabled = adw_switch_row_new()!
        adw_preferences_row_set_title(enabled.cast(), "Let editors debug the Archimedes (Debug Adapter Protocol)")
        adw_switch_row_set_active(enabled.cast(), settings.debugAdapterEnabled ? 1 : 0)
        let port = adw_spin_row_new_with_range(1, 65535, 1)!
        adw_preferences_row_set_title(port.cast(), "Port")
        adw_spin_row_set_value(port.cast(), Double(settings.debugAdapterPort))
        port.setSensitive(settings.debugAdapterEnabled)
        onNotify(enabled, "active") {
            let on = adw_switch_row_get_active(enabled.cast()) != 0
            settings.debugAdapterEnabled = on
            port.setSensitive(on)
        }
        onNotify(port, "value") {
            settings.debugAdapterPort = Int(adw_spin_row_get_value(port.cast()))
        }
        let status = UI.label("", classes: ["dim-label"])
        let statusRow = UI.actionRow("Status", suffixes: [status])
        observe(widget: status) { UI.setText(status, AgentLog.shared.debugAdapterState) }
        let group = UI.preferencesGroup(nil,
            description: "VS Code and other editors that speak DAP connect to localhost on this port to assemble and run ARM code, set breakpoints in the source, step (and step back), and inspect registers and memory. The MacArch extension for VS Code is at github.com/acorn-playground/vscode-macarch. Changes take effect next launch.",
            [enabled, port, statusRow])
        adw_preferences_page_add(page.cast(), group.cast())
        return page
    }

    // MARK: Networking

    /// The Internet Econet service networks are shared on. (The Mac app's,
    /// after MacBeeb's.)
    private static func networkingPage() -> Widget {
        let page = adw_preferences_page_new()!
        adw_preferences_page_set_title(page.cast(), "Networking")
        adw_preferences_page_set_icon_name(page.cast(), "network-workgroup-symbolic")
        var custom = !InternetEconetService.isOfficial
        let official = gtk_check_button_new()!
        let other = gtk_check_button_new()!
        gtk_check_button_set_group(other.cast(), official.cast())
        gtk_check_button_set_active((custom ? other : official).cast(), 1)
        let officialRow = UI.actionRow("Official service (\(InternetEconetService.officialURL.host ?? ""))")
        let customRow = UI.actionRow("Custom service")
        for (row, check) in [(officialRow, official), (customRow, other)] {
            check.align(vertical: GTK_ALIGN_CENTER)
            adw_action_row_add_prefix(row.cast(), check)
            adw_action_row_set_activatable_widget(row.cast(), check)
        }
        let address = adw_entry_row_new()!
        adw_preferences_row_set_title(address.cast(), "Address, such as https://econet.example.org")
        UI.setText(editable: address, InternetEconetService.isOfficial ? "" : InternetEconetService.current.absoluteString)
        let problem = UI.label("", classes: ["error-text", "caption"], wrap: true)
        let developer = UI.label("Developer mode: an unencrypted service on this computer.", classes: ["warning", "caption"], wrap: true)
        let result = UI.label("", wrap: true)
        let spinner = adw_spinner_new()!
        gtk_widget_set_size_request(spinner, 16, 16)
        spinner.setVisible(false)
        func showCustom() {
            address.setVisible(custom)
            problem.setVisible(custom && !UI.text(of: problem).isEmpty)
            let url = try? InternetEconetService.validate(UI.text(of: address)).get()
            developer.setVisible(custom && url.map(InternetEconetService.isLocalDevelopment) == true)
        }
        /// Takes the typed address, if it's a good one.
        func apply() -> URL? {
            guard custom else { return InternetEconetService.officialURL }
            switch InternetEconetService.validate(UI.text(of: address)) {
            case .success(let url):
                UI.setText(problem, "")
                UI.setText(editable: address, url.absoluteString)
                InternetEconetService.current = url
                showCustom()
                return url
            case .failure(let error):
                UI.setText(problem, error.description)
                showCustom()
                return nil
            }
        }
        onSignal(other, "toggled") {
            custom = gtk_check_button_get_active(other.cast()) != 0
            UI.setText(result, "")
            if !custom { InternetEconetService.current = InternetEconetService.officialURL }
            showCustom()
        }
        onSignal(address, "apply") { _ = apply() }
        adw_entry_row_set_show_apply_button(address.cast(), 1)
        onSignal(address, "changed") { showCustom() }
        let test = UI.button("Test Connection") {}
        onSignal(test, "clicked") {
            guard let url = apply() else { return }
            test.setSensitive(false)
            spinner.setVisible(true)
            UI.setText(result, "")
            Task {
                var text: String
                var ok = false
                do {
                    let info = try await RoomAPI(service: url).serviceInfo()
                    if let incompatibility = info.incompatibility {
                        text = incompatibility
                    } else {
                        text = "\(info.name): compatible, protocol \(ServiceInfo.protocolVersion)"
                        ok = true
                    }
                } catch {
                    text = "No Internet Econet service answered at \(url.host ?? url.absoluteString)"
                }
                UI.setText(result, (ok ? "✓ " : "✕ ") + text)
                result.setClass("ready", ok)
                result.setClass("error-text", !ok)
                test.setSensitive(true)
                spinner.setVisible(false)
            }
        }
        let reset = UI.button("Reset to Default", classes: ["flat"]) {
            gtk_check_button_set_active(official.cast(), 1)
            UI.setText(editable: address, "")
            UI.setText(problem, "")
            InternetEconetService.current = InternetEconetService.officialURL
            showCustom()
        }
        showCustom()
        let link = gtk_link_button_new_with_label("https://github.com/JamesRandall/cloudflare-econet", "The service on GitHub")!
        link.align(horizontal: GTK_ALIGN_START)
        let group = UI.preferencesGroup("Internet Econet Service",
            description: "Sharing a network over the Internet makes its room here (MacArch and MacBeeb use the same service, so their Archimedes and BBC Micros can join), and join codes are looked up here. Anyone can run a compatible service of their own (acornplayground’s econet service, on Cloudflare); invitation links name theirs. Each service keeps its own rooms and credentials.",
            [officialRow, customRow, address])
        let actions = UI.vbox(spacing: 8, [problem, developer, UI.hbox(spacing: 8, [test, spinner, result, UI.spacer(), reset]), link])
        actions.setMargins(top: 8)
        adw_preferences_group_add(group.cast(), actions)
        adw_preferences_page_add(page.cast(), group.cast())
        return page
    }

    // MARK: ROMs

    private static func romsPage(dialog: Widget) -> Widget {
        let page = adw_preferences_page_new()!
        adw_preferences_page_set_title(page.cast(), "ROMs")
        adw_preferences_page_set_icon_name(page.cast(), "media-flash-symbolic")
        let group = UI.preferencesGroup("RISC OS ROMs",
            description: "ROMs added are copied into LinuxArch’s folder as single images, so the originals can go. Drop ROM images, chip files (such as IC24–IC27), folders of them or ZIP archives on a window to add them too.")
        let add = UI.button("_Add ROMs…", classes: ["flat"]) { ROMLibrary.shared.chooseAndAdd(parent: dialog) }
        adw_preferences_group_set_header_suffix(group.cast(), add)
        adw_preferences_page_add(page.cast(), group.cast())

        var rows: [Widget] = []
        observe(widget: group) {
            for row in rows { adw_preferences_group_remove(group.cast(), row) }
            let settings = AppSettings.shared
            rows = settings.romLibrary.map { rom in
                let detail = ROMLibrary.shared.detail(for: rom.path)
                var notes: [String] = []
                if let known = detail?.known { notes.append(known.note) }
                if let models = detail?.models, !models.isEmpty, models.count < MachineModel.allCases.count {
                    notes.append("For the " + models.map(\.rawValue).joined(separator: ", "))
                }
                if detail?.isCopy != true { notes.append(rom.path) }
                let remove = UI.iconButton("user-trash-symbolic", tooltip: "Take off the list (LinuxArch’s copy goes to the Trash)",
                                           classes: ["flat"]) { ROMLibrary.shared.remove(rom.path) }
                var suffixes = [remove]
                if settings.romPath == rom.path {
                    suffixes.insert(UI.label("New windows", classes: ["dim-label", "caption"]), at: 0)
                }
                let row = UI.actionRow(rom.version, subtitle: notes.joined(separator: " · "), suffixes: suffixes)
                return row
            }
            if rows.isEmpty {
                rows = [UI.actionRow("No ROMs", subtitle: "Add RISC OS 2 or 3 (or ArcLibre) to switch on")]
            }
            for row in rows { adw_preferences_group_add(group.cast(), row) }
        }
        adw_preferences_page_add(page.cast(), newWindows().cast())
        return page
    }

    /// The machine new windows start as (a window's own changes from its
    /// main menu, and new windows start as it was last set).
    private static func newWindows() -> Widget {
        let settings = AppSettings.shared
        let models = MachineModel.allCases
        var updating = false
        let model = UI.comboRow("Model", models.map(\.displayName), selected: models.firstIndex(of: settings.model) ?? 0) { index in
            if !updating { settings.model = models[index] }
        }
        let cpu = UI.comboRow("Processor", []) { index in
            let choices = settings.model.cpuChoices
            if !updating, choices.indices.contains(index) { settings.setCPU(choices[index], for: settings.model) }
        }
        let memory = UI.comboRow("Memory", []) { index in
            let choices = settings.model.ramChoices
            if !updating, choices.indices.contains(index) { settings.setRAMKB(choices[index], for: settings.model) }
        }
        let monitor = UI.comboRow("Monitor", []) { index in
            let choices = settings.model.monitorChoices
            if !updating, choices.indices.contains(index) { settings.setMonitor(choices[index], for: settings.model) }
        }
        let group = UI.preferencesGroup("New Windows",
            description: "CMOS settings are kept per model and ROM in LinuxArch’s folder. Hold Delete while powering on (Power Cycle) to reset them to RISC OS defaults.",
            [model, cpu, memory, monitor])
        observe(widget: group) {
            let current = settings.model
            updating = true
            defer { updating = false }
            UI.setItems(comboRow: cpu, current.cpuChoices.map(\.displayName), selected: current.cpuChoices.firstIndex(of: settings.cpu(for: current)) ?? 0)
            UI.setItems(comboRow: memory, current.ramChoices.map(AppSettings.ramLabel),
                        selected: current.ramChoices.firstIndex(of: settings.ramKB(for: current)) ?? 0)
            UI.setItems(comboRow: monitor, current.monitorChoices.map(\.displayName),
                        selected: current.monitorChoices.firstIndex(of: settings.monitor(for: current)) ?? 0)
            monitor.setVisible(current.monitorChoices.count > 1)
        }
        return group
    }
}
