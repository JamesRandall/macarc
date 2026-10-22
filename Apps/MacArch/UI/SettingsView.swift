import AppKit
import ArchimedesCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            MachineSettingsView()
                .tabItem { Label("Machine", systemImage: "desktopcomputer") }
            MouseSettingsView()
                .tabItem { Label("Mouse", systemImage: "computermouse") }
            KeyboardSettingsView()
                .tabItem { Label("Keyboard", systemImage: "keyboard") }
            DebuggingSettingsView()
                .tabItem { Label("Debugging", systemImage: "ant") }
        }
        .frame(width: 520, height: 460)
    }
}

/// The ROM library and the machine new windows start as. A window's own
/// machine changes from its Machine menu.
struct MachineSettingsView: View {
    @State private var settings = AppSettings.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Form {
            Section {
                ForEach(settings.romLibrary) { rom in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(rom.version)
                            Text(rom.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        if rom.path == settings.romPath {
                            Text("Default").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Button("Make Default") { settings.romPath = rom.path }.buttonStyle(.borderless)
                        }
                        Button { settings.removeROM(rom.path) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .disabled(rom.path == settings.romPath)
                            .help("Remove from the list")
                    }
                }
            } header: {
                Text("ROMs")
            } footer: {
                HStack {
                    Text("MacArch never includes ROMs: use images you own.").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Add ROMs…") { openWindow(id: "roms") }
                }
            }
            Section {
                Picker("Model", selection: $settings.model) {
                    ForEach(MachineModel.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Picker("Processor", selection: Binding(get: { settings.cpu(for: settings.model) },
                                                       set: { settings.setCPU($0, for: settings.model); settings.model = settings.model })) {
                    ForEach(settings.model.cpuChoices, id: \.self) { Text($0.displayName).tag($0) }
                }
                Picker("Memory", selection: Binding(get: { settings.ramKB(for: settings.model) },
                                                    set: { settings.setRAMKB($0, for: settings.model); settings.model = settings.model })) {
                    ForEach(settings.model.ramChoices, id: \.self) { Text(AppSettings.ramLabel($0)).tag($0) }
                }
                if settings.model.monitorChoices.count > 1 {
                    Picker("Monitor", selection: Binding(get: { settings.monitor(for: settings.model) },
                                                         set: { settings.setMonitor($0, for: settings.model); settings.model = settings.model })) {
                        ForEach(settings.model.monitorChoices, id: \.self) { Text($0.displayName).tag($0) }
                    }
                }
                Text("CMOS settings are kept per model and ROM in ~/Library/Application Support/MacArch. Hold Delete while powering on (Machine > Power Cycle) to reset them to RISC OS defaults.")
                    .font(.callout).foregroundStyle(.secondary)
            } header: {
                Text("New Windows")
            }
        }
        .formStyle(.grouped)
    }
}

struct KeyboardSettingsView: View {
    @State private var settings = KeyboardSettings.shared
    @State private var recorder: KeyRecorder?

    var body: some View {
        Form {
            Section {
                Picker("Keys", selection: $settings.mode) {
                    ForEach(KeyboardSettings.Mode.allCases) { Text($0.name).tag($0) }
                }
                .pickerStyle(.radioGroup)
                Text(settings.mode == .physical
                     ? "Each Mac key is the Archimedes key in the same place, so Shift-2 types what an Archimedes types (@). Best for games. The Option keys are Alt, Forward Delete is Delete, End is Copy and Help is Insert."
                     : "Keys type what your Mac's layout says, with the Archimedes' Shift adjusted to match. Best for typing. Arrows, function keys, Return, Delete, the keypad and Control combinations still go by position; Option types characters rather than being Alt.")
                    .font(.callout).foregroundStyle(.secondary)
                Text("Command shortcuts always stay with the Mac.").font(.callout).foregroundStyle(.secondary)
            }
            Section {
                if settings.mappings.isEmpty {
                    Text("No custom keys. Add one to put any Archimedes key on any Mac key.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(settings.mappings) { mapping in
                    HStack {
                        Text(mapping.macKeyName).frame(minWidth: 120, alignment: .leading)
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        Picker("Archimedes key", selection: Binding(
                            get: { mapping.arcKey },
                            set: { settings.setMapping(keyCode: mapping.keyCode, macKeyName: mapping.macKeyName, to: $0) }
                        )) {
                            ForEach(KeyboardSettings.catalogue, id: \.code) { Text($0.name).tag($0.code) }
                        }
                        .labelsHidden()
                        Button { settings.removeMapping(keyCode: mapping.keyCode) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .help("Remove")
                    }
                }
            } header: {
                Text("Custom keys")
            } footer: {
                HStack {
                    if recorder != nil {
                        Text("Press the Mac key to map…").foregroundStyle(.secondary)
                        Button("Cancel") { stopRecording() }
                    } else {
                        Button("Add Mapping…") { startRecording() }
                    }
                    Spacer()
                    Button("Remove All") { settings.removeAllMappings() }
                        .disabled(settings.mappings.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        recorder = KeyRecorder { event in
            settings.setMapping(keyCode: event.keyCode, macKeyName: KeyboardSettings.name(of: event),
                                to: settings.currentKey(for: event.keyCode))
            stopRecording()
        }
    }

    private func stopRecording() {
        recorder?.stop()
        recorder = nil
    }
}

/// The Archimedes mouse's three buttons on a Mac mouse or trackpad.
struct MouseSettingsView: View {
    @State private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                Picker("Secondary click", selection: $settings.secondaryClick) {
                    ForEach(AppSettings.SecondaryClick.allCases) { Text($0.name).tag($0) }
                }
                .pickerStyle(.radioGroup)
                Text("The secondary click is a right click on a mouse, or a two-finger click (or the corner you have set) on a trackpad. RISC OS uses Menu constantly, so on a laptop you may prefer Menu here.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Buttons") {
                LabeledContent("Select (left)", value: "Click")
                LabeledContent("Menu (middle)", value: settings.secondaryClick == .menu
                               ? "Secondary click, ⌘-click, ⌃-click or the middle button"
                               : "⌘-click, ⌃-click, ⌥-click or the middle button")
                LabeledContent("Adjust (right)", value: settings.secondaryClick == .adjust ? "Secondary click" : "⌥-click")
                Text("⌘-click is the cleanest Menu on a trackpad: Command is never passed to the Archimedes, whereas Control and Option are also its Ctrl and Alt keys.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section {
                Text("Click the display to capture the mouse; ⌃⌘M or switching away releases it.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// The debug adapter VS Code connects to.
struct DebuggingSettingsView: View {
    @State private var settings = AppSettings.shared
    @State private var log = AgentLog.shared

    var body: some View {
        Form {
            Section {
                Toggle("Let editors debug the Archimedes (Debug Adapter Protocol)", isOn: $settings.debugAdapterEnabled)
                TextField("Port", value: $settings.debugAdapterPort, format: .number.grouping(.never))
                    .disabled(!settings.debugAdapterEnabled)
                LabeledContent("Status", value: log.debugAdapterState)
                Text("VS Code and other editors that speak DAP connect to localhost on this port to assemble and run ARM code, set breakpoints in the source, step (and step back), and inspect registers and memory. The MacArch extension for VS Code is in Tools/vscode-macarch. Changes take effect next launch.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
