import AppKit
import ArchimedesCore
import SwiftUI

/// End-to-end welcome import: real menu state, invalid-file cleanup and a new
/// visible window attached to the imported controller (never the default ROM).
@MainActor
enum WelcomeImportSelfTest {
    private static var ran = false
    static func runIfRequested(openWindow: OpenWindowAction, dismissWindow: DismissWindowAction) async {
        let env = ProcessInfo.processInfo.environment
        guard AppSettings.isSelfTest, !ran, let source = env["MACARCH_SELFTEST_WELCOME_IMPORT"],
              let output = env["MACARCH_SELFTEST"] else { return }
        ran = true
        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw MachineError.badConfiguration(message) }
        }
        func capture(_ window: NSWindow, _ suffix: String) throws {
            guard let view = window.contentView?.superview, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                throw MachineError.badConfiguration("Cannot capture window")
            }
            view.cacheDisplay(in: view.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: output + suffix + ".png"))
        }
        func importItem(_ menu: NSMenu) -> NSMenuItem? {
            menu.delegate?.menuNeedsUpdate?(menu); menu.update()
            for item in menu.items {
                if item.title == "Import Machine Configuration…" { return item }
                if let submenu = item.submenu, let found = importItem(submenu) { return found }
            }
            return nil
        }
        do {
            try await Task.sleep(for: .seconds(1))
            guard let welcome = NSApp.windows.first(where: { $0.identifier?.rawValue == WelcomeScreen.windowID && $0.isVisible }) else {
                throw MachineError.badConfiguration("Welcome is not visible")
            }
            welcome.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .seconds(0.5))
            try require(NSApp.mainMenu.flatMap(importItem)?.isEnabled == true, "Import menu disabled on Welcome")
            try capture(welcome, "-welcome")
            let before = Set(MachineController.all.keys)
            let bad = URL(fileURLWithPath: output + ".invalid.json")
            try Data("{invalid}".utf8).write(to: bad)
            var rejected = false
            do { _ = try MachineConfigurationCommands.prepare(from: bad) } catch { rejected = true }
            try require(rejected && Set(MachineController.all.keys) == before && welcome.isVisible, "Failed import changed the welcome/session state")
            let input = URL(fileURLWithPath: source)
            let expected = try MachineConfigurationFile.load(from: input)
            let machine = try MachineConfigurationCommands.start(from: input, openWindow: openWindow)
            dismissWindow(id: WelcomeScreen.windowID)
            try await Task.sleep(for: .seconds(3))
            try require(machine.host != nil && machine.startError == nil && machine.model == expected.model && machine.cpu == expected.cpu && machine.ramKB == expected.ramKB, "Imported machine settings/start")
            try require(MachineController.frontmost === machine, "New window is not using the imported controller")
            try require(!welcome.isVisible, "Welcome did not close after import")
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.identifier?.rawValue.contains(MachineConfigurationCommands.windowID) == true }) else {
                throw MachineError.badConfiguration("Imported machine window not visible")
            }
            try capture(window, "-machine")
            let exported = URL(fileURLWithPath: output + ".machine.json")
            try await machine.exportConfiguration(to: exported)
            let actual = try MachineConfigurationFile.load(from: exported)
            try require(actual.cmosSettings == expected.cmosSettings, "CMOS overrides lost")
            try "PASS: enabled welcome menu, invalid-import cleanup, imported machine window, settings and CMOS\n".write(toFile: output + ".welcome-import.txt", atomically: true, encoding: .utf8)
        } catch {
            try? "FAIL: \(error)\n".write(toFile: output + ".welcome-import.txt", atomically: true, encoding: .utf8)
        }
        NSApp.terminate(nil)
    }
}
