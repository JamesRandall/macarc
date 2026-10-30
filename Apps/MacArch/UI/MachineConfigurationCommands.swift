import AppKit
import SwiftUI
import ArchimedesCore

/// Welcome imports prepare a new machine without booting the default ROM or
/// replacing another window's session. Failed imports leave Welcome in place.
@MainActor
enum MachineConfigurationCommands {
    static let windowID = "imported-machine"

    static func prepare(from url: URL, savedMachine: UUID? = nil) throws -> MachineController {
        let machine = MachineController(startAutomatically: false)
        do {
            try machine.importConfiguration(from: url, confirmRestart: false, savedMachine: savedMachine)
            guard machine.host != nil, machine.startError == nil else {
                throw MachineError.badConfiguration(machine.startError ?? "The imported machine did not start")
            }
            return machine
        } catch {
            machine.shutdown()
            MachineController.all[machine.id] = nil
            MachineController.live.remove(machine)
            throw error
        }
    }

    @discardableResult
    static func start(from url: URL, openWindow: OpenWindowAction) throws -> MachineController {
        let machine = try prepare(from: url)
        openWindow(id: windowID, value: machine.id)
        return machine
    }

    static func chooseAndStart(openWindow: OpenWindowAction) -> Bool {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.prompt = "Import and Start"
        panel.message = "Choose a machine configuration to start. Keep its ROM and CMOS files beside it when their paths are relative."
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        do {
            try start(from: url, openWindow: openWindow)
            return true
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not import machine configuration"
            alert.informativeText = "\(error)"
            alert.runModal()
            return false
        }
    }
}

struct ImportMachineConfigurationButton: View {
    let machine: MachineController?
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Button("Import Machine Configuration…") {
            if let machine {
                machine.chooseImportConfiguration()
            } else if MachineConfigurationCommands.chooseAndStart(openWindow: openWindow) {
                dismissWindow(id: WelcomeScreen.windowID)
            }
        }
        .disabled(machine?.isStation == true)
    }
}
