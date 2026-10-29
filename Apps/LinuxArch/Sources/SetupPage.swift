import ArchimedesCore
import CGtk
import Foundation

/// What a window shows before its machine is switched on: no ROM yet (the
/// build came without ArcLibre, or it was taken off the list), or the last
/// try failed. Add ROMs (or drop them on the window), pick a model, and
/// Switch On. (The Mac app's welcome card for an Archimedes.)
@MainActor
final class SetupPage {
    let widget: Widget
    private let machine: MachineController
    private var model: MachineModel
    private var romPath: String?
    private let status: Widget
    private let romRow: Widget
    private let switchOn: Widget
    private let errorLabel: Widget

    init(machine: MachineController) {
        self.machine = machine
        model = machine.model
        romPath = AppSettings.shared.romPath
        status = adw_status_page_new()!
        adw_status_page_set_icon_name(status.cast(), AppInfo.id)

        let models = MachineModel.allCases
        let modelRow = UI.comboRow("Model", models.map(\.displayName), selected: models.firstIndex(of: model) ?? 0) { _ in }
        let romRow = UI.comboRow("RISC OS", [], selected: 0) { _ in }
        self.romRow = romRow
        errorLabel = UI.label("", classes: ["error-text"], wrap: true, xalign: 0.5)
        errorLabel.setVisible(false)
        let group = UI.preferencesGroup(nil, [modelRow, romRow])

        switchOn = UI.button("_Switch On", classes: ["suggested-action", "pill"]) {}
        let addROMs = UI.button("_Add ROMs…", classes: ["pill"]) {}
        let importButton = UI.button("_Import Machine…", classes: ["pill"]) {}
        let buttons = UI.hbox(spacing: 12, [addROMs, importButton, switchOn])
        buttons.align(horizontal: GTK_ALIGN_CENTER)
        let content = UI.vbox(spacing: 24, [group, errorLabel, buttons])
        let clamp = adw_clamp_new()!
        adw_clamp_set_maximum_size(clamp.cast(), 480)
        adw_clamp_set_child(clamp.cast(), content)
        adw_status_page_set_child(status.cast(), clamp)
        widget = status

        onNotify(modelRow, "selected") { [weak self] in
            let index = Int(adw_combo_row_get_selected(modelRow.cast()))
            if models.indices.contains(index) { self?.model = models[index] }
        }
        onNotify(romRow, "selected") { [weak self] in
            let roms = AppSettings.shared.romLibrary
            let index = Int(adw_combo_row_get_selected(romRow.cast()))
            if roms.indices.contains(index) { self?.romPath = roms[index].path }
        }
        onSignal(switchOn, "clicked") { [weak self] in
            guard let self, let rom = self.romPath else { return }
            machine.setHardware(model: self.model, romPath: rom)
        }
        onSignal(addROMs, "clicked") { [weak self] in ROMLibrary.shared.chooseAndAdd(parent: self?.widget) }
        onSignal(importButton, "clicked") { machine.chooseImportConfiguration() }

        observe(self) { [weak self] in
            guard let self else { return }
            let roms = AppSettings.shared.romLibrary
            if self.romPath == nil || !roms.contains(where: { $0.path == self.romPath }) {
                self.romPath = AppSettings.shared.romPath ?? roms.last?.path
            }
            UI.setItems(comboRow: self.romRow, roms.map(\.version), selected: roms.firstIndex { $0.path == self.romPath } ?? 0)
            self.romRow.setVisible(!roms.isEmpty)
            self.switchOn.setSensitive(!roms.isEmpty)
            if let error = machine.startError {
                adw_status_page_set_title(self.status.cast(), "The Archimedes Couldn’t Switch On")
                adw_status_page_set_description(self.status.cast(), "Choose another ROM or model, and try again.")
                UI.setText(self.errorLabel, error)
                self.errorLabel.setVisible(true)
            } else if roms.isEmpty {
                adw_status_page_set_title(self.status.cast(), "Add RISC OS")
                adw_status_page_set_description(self.status.cast(),
                    "The Archimedes needs a RISC OS ROM to switch on. Drop a ROM image, the chip files of a set (such as IC24–IC27), a folder of them or a ZIP archive on this window, or choose them.")
                self.errorLabel.setVisible(false)
            } else {
                adw_status_page_set_title(self.status.cast(), "Switch On an Archimedes")
                adw_status_page_set_description(self.status.cast(), "Choose a model and the RISC OS it starts with.")
                self.errorLabel.setVisible(false)
            }
        }
    }
}
