import ArchimedesCore
import CGtk
import Foundation

/// The rewind history as a scrubber: pick a moment and go back to it.
@MainActor
final class RewindDialog {
    private let machine: MachineController
    private let dialog: Widget
    private let picture: Widget
    private let scale: Widget
    private let label: Widget
    private let rewindButton: Widget
    private var points: [UInt64] = []
    private var now: UInt64 = 0
    private var wasPaused = false
    private let onClose: Handler
    /// The latest thumbnail asked for, so slow ones don't overwrite it.
    private var thumbnailRequest = 0

    init(machine: MachineController, parent: Widget, onClose: @escaping Handler) {
        self.machine = machine
        self.onClose = onClose
        dialog = adw_dialog_new()!.widget
        adw_dialog_set_title(dialog.cast(), "Rewind")
        adw_dialog_set_content_width(dialog.cast(), 420)

        picture = gtk_picture_new()!
        gtk_picture_set_content_fit(picture.cast(), GTK_CONTENT_FIT_FILL)
        // The thumbnail is the monitor's shape.
        let aspect = Double(Rewinder.thumbnailWidth) / Double(Rewinder.thumbnailHeight)
        gtk_widget_set_size_request(picture, Int32((288 * aspect).rounded()), 288)
        picture.addClass("thumbnail")
        gtk_widget_set_overflow(picture, GTK_OVERFLOW_HIDDEN)
        picture.align(horizontal: GTK_ALIGN_CENTER)

        scale = gtk_scale_new_with_range(GTK_ORIENTATION_HORIZONTAL, 0, 1, 1)!
        gtk_scale_set_draw_value(scale.cast(), 0)
        label = UI.label("No history yet: rewind keeps the last minute as the machine runs.",
                         classes: ["dim-label", "numeric"], wrap: true, xalign: 0.5)

        let cancel = UI.button("Cancel") {}
        rewindButton = UI.button("Rewind to Here", classes: ["suggested-action"]) {}
        let buttons = UI.hbox(spacing: 8, [cancel, UI.spacer(), rewindButton])
        let content = UI.vbox(spacing: 16, [picture, scale, label, buttons])
        content.setMargins(top: 8, bottom: 20, start: 20, end: 20)
        let toolbar = adw_toolbar_view_new()!
        adw_toolbar_view_add_top_bar(toolbar.cast(), adw_header_bar_new())
        adw_toolbar_view_set_content(toolbar.cast(), content)
        adw_dialog_set_child(dialog.cast(), toolbar)
        adw_dialog_set_default_widget(dialog.cast(), rewindButton)
        rewindButton.setSensitive(false)
        scale.setVisible(false)

        onSignal(cancel, "clicked") { [weak self] in self?.close() }
        onSignal(rewindButton, "clicked") { [weak self] in
            guard let self else { return }
            let index = self.index
            if self.points.indices.contains(index) {
                machine.seek(to: self.points[index])
            }
            self.close()
        }
        onSignal(scale, "value-changed") { [weak self] in self?.indexChanged() }
        onSignal(dialog, "closed") { [weak self] in self?.closed() }

        wasPaused = machine.paused
        machine.setPaused(true)
        adw_dialog_present(dialog.cast(), parent)
        Task { [weak self] in
            let (points, now) = await machine.rewindPoints()
            guard let self else { return }
            self.points = points
            self.now = now
            if points.count > 1 {
                gtk_range_set_range(self.scale.cast(), 0, Double(points.count - 1))
                gtk_range_set_value(self.scale.cast(), Double(points.count - 1))
                self.scale.setVisible(true)
                self.rewindButton.setSensitive(true)
            }
            self.indexChanged()
        }
    }

    private var index: Int { Int(gtk_range_get_value(scale.cast()).rounded()) }

    private func indexChanged() {
        let index = index
        if points.indices.contains(index), points.count > 1 {
            let back = Double(now - min(now, points[index])) / Double(MasterClock.ticksPerSecond)
            UI.setText(label, back < 0.05 ? "Now" : String(format: "%.1f seconds ago", back))
        }
        thumbnailRequest += 1
        let request = thumbnailRequest
        Task { [weak self] in
            guard let pixels = await self?.machine.rewindThumbnail(index), let self, request == self.thumbnailRequest else { return }
            self.show(pixels)
        }
    }

    private func show(_ pixels: [UInt32]) {
        let width = Rewinder.thumbnailWidth, height = Rewinder.thumbnailHeight
        let bytes = pixels.withUnsafeBytes { g_bytes_new($0.baseAddress, gsize($0.count)) }
        defer { g_bytes_unref(bytes) }
        // 0xAARRGGBB, little-endian: B, G, R, A (opaque).
        guard let texture = gdk_memory_texture_new(Int32(width), Int32(height), GDK_MEMORY_B8G8R8X8, bytes, gsize(width * 4))
        else { return }
        gtk_picture_set_paintable(picture.cast(), texture.opaque)
        g_object_unref(texture.raw)
    }

    func close() {
        adw_dialog_close(dialog.cast())
    }

    private func closed() {
        machine.setPaused(wasPaused)
        onClose()
    }
}
