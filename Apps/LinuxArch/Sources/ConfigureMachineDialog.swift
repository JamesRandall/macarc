import ArchimedesCore
import CGtk
import Foundation

/// Machine ▸ Configure Machine: the model, processor, memory, monitor, ROM
/// and hard discs in one place. (The Mac app's ConfigureMachineWindow.)
///
/// The hardware is chosen as a draft: fitting it restarts the machine (as
/// switching off and on would), so nothing changes until Restart Machine.
/// Hard disc actions restart it themselves, so they act straight away.
@MainActor
final class ConfigureMachineDialog {
    private let machine: MachineController
    private let dialog: Widget
    private let parent: Widget
    private let onClose: Handler
    private var draft: Draft
    private let processorRow: Widget
    private let memoryRow: Widget
    private let monitorRow: Widget
    private let romRow: Widget
    private let restart: Widget
    private let hardDiscGroup: Widget
    private var hardDiscRows: [Widget] = []

    struct Draft: Equatable {
        var model: MachineModel
        var cpu: CPUType
        var ramKB: Int
        var monitor: MonitorType
        var romPath: String
    }

    private static func current(_ m: MachineController) -> Draft {
        Draft(model: m.model, cpu: m.cpu, ramKB: m.ramKB, monitor: m.monitor, romPath: m.romPath ?? "")
    }

    init(machine: MachineController, parent: Widget, onClose: @escaping Handler) {
        self.machine = machine
        self.parent = parent
        self.onClose = onClose
        draft = Self.current(machine)
        dialog = adw_preferences_dialog_new()!.widget
        adw_dialog_set_title(dialog.cast(), "Configure Machine")
        adw_dialog_set_content_width(dialog.cast(), 620)

        let models = MachineModel.allCases
        let modelRow = UI.comboRow("Model", models.map(\.displayName), selected: models.firstIndex(of: draft.model) ?? 0) { _ in }
        processorRow = UI.comboRow("Processor", [], selected: 0) { _ in }
        memoryRow = UI.comboRow("Memory", [], selected: 0) { _ in }
        monitorRow = UI.comboRow("Monitor", [], selected: 0) { _ in }
        romRow = UI.comboRow("ROM", [], selected: 0) { _ in }
        let hardware = UI.preferencesGroup("Hardware", description: "Changes wait until Restart Machine, which switches it off and on again. The floppy stays in.",
                                           [modelRow, processorRow, memoryRow, monitorRow, romRow])

        hardDiscGroup = UI.preferencesGroup("Hard Discs", description: "Changing a drive restarts the machine straight away.")

        restart = UI.button("_Restart Machine", classes: ["suggested-action", "pill"]) {}
        restart.align(horizontal: GTK_ALIGN_CENTER)
        let footer = UI.preferencesGroup(nil, [restart])

        let page = adw_preferences_page_new()!
        for group in [hardware, hardDiscGroup, footer] {
            adw_preferences_page_add(page.cast(), group.cast())
        }
        adw_preferences_dialog_add(dialog.cast(), page.cast())

        onNotify(modelRow, "selected") { [weak self] in
            guard let self else { return }
            let index = Int(adw_combo_row_get_selected(modelRow.cast()))
            guard models.indices.contains(index), models[index] != self.draft.model else { return }
            // A model brings back the processor, memory and monitor it last had.
            // A ROM that can't drive it gives way to one that can.
            let m = models[index], s = AppSettings.shared
            let fits = s.romLibrary.first { $0.path == self.draft.romPath }?.suits(m) ?? true
            let rom = fits ? self.draft.romPath : s.preferredROM(for: m, like: self.draft.romPath) ?? self.draft.romPath
            self.draft = Draft(model: m, cpu: s.cpu(for: m), ramKB: s.ramKB(for: m), monitor: s.monitor(for: m), romPath: rom)
            self.showChoices()
        }
        onNotify(processorRow, "selected") { [weak self] in
            guard let self else { return }
            let choices = self.draft.model.cpuChoices, index = Int(adw_combo_row_get_selected(self.processorRow.cast()))
            if choices.indices.contains(index) { self.draft.cpu = choices[index] }
            self.updateRestart()
        }
        onNotify(memoryRow, "selected") { [weak self] in
            guard let self else { return }
            let choices = self.draft.model.ramChoices, index = Int(adw_combo_row_get_selected(self.memoryRow.cast()))
            if choices.indices.contains(index) { self.draft.ramKB = choices[index] }
            self.updateRestart()
        }
        onNotify(monitorRow, "selected") { [weak self] in
            guard let self else { return }
            let choices = self.draft.model.monitorChoices, index = Int(adw_combo_row_get_selected(self.monitorRow.cast()))
            if choices.indices.contains(index) { self.draft.monitor = choices[index] }
            self.updateRestart()
        }
        onNotify(romRow, "selected") { [weak self] in
            guard let self else { return }
            let roms = AppSettings.shared.romLibrary, index = Int(adw_combo_row_get_selected(self.romRow.cast()))
            if roms.indices.contains(index) { self.draft.romPath = roms[index].path }
            self.updateRestart()
        }
        onSignal(restart, "clicked") { [weak self] in
            guard let self else { return }
            let d = self.draft
            if d.model != machine.model {
                // Remember the draft's choices as that model's, then switch.
                let s = AppSettings.shared
                s.setCPU(d.cpu, for: d.model); s.setRAMKB(d.ramKB, for: d.model); s.setMonitor(d.monitor, for: d.model)
            }
            machine.setHardware(model: d.model, cpu: d.cpu, ramKB: d.ramKB, monitor: d.monitor, romPath: d.romPath.isEmpty ? nil : d.romPath)
            self.close()
        }
        onSignal(dialog, "closed") { [weak self] in self?.onClose() }

        showChoices()
        observe(self) { [weak self] in
            guard let self else { return }
            _ = (machine.hardDiscs, machine.model)
            self.showHardDiscs()
        }
    }

    func present() {
        adw_dialog_present(dialog.cast(), parent)
    }

    func close() {
        adw_dialog_close(dialog.cast())
    }

    /// The draft model's choices, with the draft's selected.
    private func showChoices() {
        let d = draft
        UI.setItems(comboRow: processorRow, d.model.cpuChoices.map(\.displayName), selected: d.model.cpuChoices.firstIndex(of: d.cpu) ?? 0)
        UI.setItems(comboRow: memoryRow, d.model.ramChoices.map(AppSettings.ramLabel), selected: d.model.ramChoices.firstIndex(of: d.ramKB) ?? 0)
        UI.setItems(comboRow: monitorRow, d.model.monitorChoices.map(\.displayName),
                    selected: d.model.monitorChoices.firstIndex(of: d.monitor) ?? 0)
        let roms = AppSettings.shared.romLibrary
        UI.setItems(comboRow: romRow, roms.map(AppSettings.shared.label), selected: roms.firstIndex { $0.path == d.romPath } ?? 0)
        processorRow.setSensitive(d.model.cpuChoices.count > 1)
        monitorRow.setSensitive(d.model.monitorChoices.count > 1)
        draft = d
        updateRestart()
    }

    private func updateRestart() {
        restart.setSensitive(draft != Self.current(machine))
    }

    /// Each drive's image, with Open, New and Remove.
    private func showHardDiscs() {
        for row in hardDiscRows { adw_preferences_group_remove(hardDiscGroup.cast(), row) }
        hardDiscRows = []
        let model = machine.model
        hardDiscGroup.setVisible(model.hardDiscSlots > 0)
        let kind = model.hasIDE ? "IDE" : "ST506"
        for drive in 0..<model.hardDiscSlots {
            let name = machine.hardDiscName(drive)
            var suffixes: [Widget] = []
            let machine = machine
            let newButton = UI.button("New…", classes: ["flat"]) { Task { @MainActor in await machine.newHardDisc(drive: drive) } }
            let openButton = UI.button("Open…", classes: ["flat"]) { machine.openHardDisc(drive: drive) }
            suffixes = [newButton, openButton]
            if name != nil {
                suffixes.append(UI.iconButton("user-trash-symbolic", tooltip: "Remove the hard disc (the image file keeps its contents)",
                                              classes: ["flat"]) { machine.ejectHardDisc(drive: drive) })
            }
            let row = UI.actionRow("Drive :\(drive + 4)", subtitle: name ?? "No \(kind) drive fitted", suffixes: suffixes)
            adw_preferences_group_add(hardDiscGroup.cast(), row)
            hardDiscRows.append(row)
        }
    }
}
