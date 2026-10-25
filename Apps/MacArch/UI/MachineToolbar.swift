import ArchimedesCore
import SwiftUI

/// The window's toolbar: the common actions, and the machine's lights.
/// Customisable, and hidden with View > Hide Toolbar.
struct MachineToolbar: CustomizableToolbarContent {
    let machine: MachineController

    var body: some CustomizableToolbarContent {
        ToolbarItem(id: "model", placement: .navigation) {
            Menu {
                HardwarePickers(machine: machine)
            } label: {
                Label("Model", systemImage: "desktopcomputer")
            } primaryAction: {
                machine.configureRequested = true
            }
            .help("Configure the machine; hold for a quick menu")
        }

        ToolbarItem(id: "disc") {
            Menu {
                DiscItems(machine: machine)
            } label: {
                Label("Disc", systemImage: "opticaldiscdrive")
            } primaryAction: {
                // Playing a Classic on several discs: the next of them.
                if machine.sessionDiscsActive { machine.insertNextSessionDisc() } else { machine.openDisc() }
            }
            .help(machine.sessionDiscsActive ? "\(machine.nextSessionDiscTitle) (⌥⌘N); hold for the game’s other discs" : "Insert a disc in drive 0; hold for more")
        }

        ToolbarItem(id: "hardDisc") {
            Menu {
                HardDiscItems(machine: machine)
            } label: {
                Label("Hard Disc", systemImage: "internaldrive")
            }
            .disabled(machine.model.hardDiscSlots == 0)
            .help("Hard discs (400 series, A5000, A3020, A4000)")
        }

        ToolbarItem(id: "reset") {
            Button { machine.reset() } label: {
                Label("Reset", systemImage: "arrow.counterclockwise")
            }
            .help("Press the reset button")
        }

        ToolbarItem(id: "power") {
            Button { machine.powerCycle() } label: {
                Label("Power Cycle", systemImage: "power")
            }
            .help("Switch off and on again")
        }

        ToolbarItem(id: "rewind") {
            Menu {
                Button("Back 1 Second") { machine.rewind(seconds: 1) }
                Button("Back 5 Seconds") { machine.rewind(seconds: 5) }
                Button("Back 30 Seconds") { machine.rewind(seconds: 30) }
                Divider()
                Button("Timeline…") { machine.showingTimeline = true }
            } label: {
                Label("Rewind", systemImage: "backward.fill")
            } primaryAction: {
                machine.rewind(seconds: 5)
            }
            .help("Go back 5 seconds; hold for more")
        }

        ToolbarItem(id: "pause") {
            let still = machine.paused || machine.heldForAgent
            Button { machine.togglePause() } label: {
                Label(still ? "Resume" : "Pause", systemImage: still ? "play.fill" : "pause.fill")
            }
            .help(machine.heldForAgent && !machine.paused ? "Resume (an AI agent is holding the machine between its tool calls)" : (still ? "Resume" : "Pause"))
        }

        ToolbarItem(id: "speed") {
            Toggle(isOn: Binding(get: { !machine.speedLimited }, set: { _ in machine.toggleSpeedLimit() })) {
                Label("Full Speed", systemImage: "hare")
            }
            .help("Run as fast as possible")
        }

        ToolbarItem(id: "mute", showsByDefault: false) {
            Toggle(isOn: Binding(get: { machine.muted }, set: { machine.muted = $0 })) {
                Label("Mute", systemImage: machine.muted ? "speaker.slash" : "speaker.wave.2")
            }
            .help("Mute the sound")
        }

        ToolbarItem(id: "screenshot") {
            Button { machine.saveScreenshot() } label: {
                Label("Screenshot", systemImage: "camera")
            }
            .help("Save a screenshot")
        }

        ToolbarItem(id: "record") {
            Button { machine.toggleRecording() } label: {
                Label(machine.recordingURL == nil ? "Record" : "Stop Recording",
                      systemImage: machine.recordingURL == nil ? "record.circle" : "stop.circle.fill")
                    .foregroundStyle(machine.recordingURL == nil ? Color.primary : Color.red)
            }
            .help(machine.recordingURL == nil ? "Record a video" : "Stop recording")
        }

        ToolbarItem(id: "state") {
            Menu {
                Button("Save State…") { machine.saveState() }
                Button("Load State…") { machine.loadState() }
                Divider()
                Button("Quick Save") { machine.quickSave() }
                Button("Quick Load") { machine.quickLoad() }
            } label: {
                Label("Save State", systemImage: "square.and.arrow.down.on.square")
            } primaryAction: {
                machine.saveState()
            }
            .help("Save the machine's state; hold to load one")
        }

        ToolbarItem(id: "display", showsByDefault: false) {
            Menu {
                Picker("Display", selection: Binding(get: { machine.displayStyle }, set: { machine.displayStyle = $0 })) {
                    ForEach(DisplayStyle.allCases) { Text($0.name).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Label("Display", systemImage: "tv")
            }
            .help("Display style")
        }

        ToolbarItem(id: "keyboard", showsByDefault: false) {
            SettingsLink {
                Label("Keyboard", systemImage: "keyboard")
            }
            .help("Keyboard settings")
        }

        ToolbarItem(id: "lights", placement: .primaryAction) {
            HStack(spacing: 10) {
                if machine.servesAgents { AgentLight() }
                MachineLights(lights: machine.lights)
            }
        }
    }
}

/// The A3000's keyboard LEDs and floppy drive light.
struct MachineLights: View {
    let lights: Machine.Lights

    var body: some View {
        HStack(spacing: 10) {
            light("CAPS", lights.capsLock, .green)
            light("NUM", lights.numLock, .green)
            light("SCROLL", lights.scrollLock, .green)
            light("DISC", lights.drive, .orange)
        }
        .padding(.horizontal, 6)
        .help("Caps Lock, Num Lock, Scroll Lock and the floppy drive")
    }

    private func light(_ label: String, _ on: Bool, _ colour: Color) -> some View {
        VStack(spacing: 2) {
            Circle()
                .fill(on ? colour : Color.secondary.opacity(0.25))
                .shadow(color: on ? colour.opacity(0.8) : .clear, radius: 3)
                .frame(width: 7, height: 7)
            Text(label)
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement()
        .accessibilityLabel("\(label) light \(on ? "on" : "off")")
    }
}

/// The disc button's menu. A view of its own, like HardDiscItems, so it
/// follows the recent list and the disc's state.
private struct DiscItems: View {
    let machine: MachineController

    var body: some View {
        if machine.sessionDiscsActive, let session = machine.session {
            Section(session.title) {
                ForEach(Array(session.discLabels.enumerated()), id: \.offset) { index, label in
                    Toggle(label, isOn: Binding(get: { machine.sessionDisc == index }, set: { _ in machine.insertSessionDisc(index) }))
                }
            }
            Divider()
        }
        Button("Open Disc…") { machine.openDisc() }
        RecentDiscsMenu(machine: machine)
        Divider()
        Button("Save Disc Changes") { machine.saveDisc() }
            .disabled(!machine.disc.modified || !machine.disc.savable)
        Button("Save Disc As…") { machine.saveDiscAs() }
            .disabled(machine.discName == nil || !machine.disc.savable)
        Button("Eject Disc") { machine.ejectDisc() }
            .disabled(machine.discName == nil)
    }
}
