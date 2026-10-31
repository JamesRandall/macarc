// File choosers (GtkFileDialog, which uses the desktop's portal, so they
// work in a Flatpak), alerts and the clipboard.

import CGtk
import Foundation

@MainActor
enum FileDialogs {
    struct Filter {
        var name: String
        /// File name suffixes, without the dot.
        var suffixes: [String]
    }

    private typealias Finish = @MainActor (OpaquePointer, OpaquePointer) -> URL?

    private static func make(title: String, filters: [Filter], allFiles: Bool) -> OpaquePointer {
        let dialog = gtk_file_dialog_new()!
        gtk_file_dialog_set_title(dialog, title)
        gtk_file_dialog_set_modal(dialog, 1)
        var all = filters
        if allFiles {
            all.append(Filter(name: "All Files", suffixes: []))
        }
        if !all.isEmpty {
            let store = g_list_store_new(gtk_file_filter_get_type())!
            for filter in all {
                let gtkFilter = gtk_file_filter_new()!
                gtk_file_filter_set_name(gtkFilter, filter.name)
                if filter.suffixes.isEmpty {
                    gtk_file_filter_add_pattern(gtkFilter, "*")
                }
                for suffix in filter.suffixes {
                    gtk_file_filter_add_suffix(gtkFilter, suffix)
                }
                g_list_store_append(store, gtkFilter.raw)
                g_object_unref(gtkFilter.raw)
            }
            gtk_file_dialog_set_filters(dialog, store.opaque)
            g_object_unref(store.raw)
        }
        return dialog
    }

    private static func run(_ dialog: OpaquePointer, finish: @escaping Finish, completion: @escaping @MainActor (URL) -> Void,
                            cancelled: @escaping Handler = {}, start: (OpaquePointer, GAsyncReadyCallback, gpointer) -> Void) {
        let callback: GAsyncReadyCallback = { source, result, data in
            let box = Unmanaged<Box<(Finish, @MainActor (URL) -> Void, Handler)>>.fromOpaque(data!).takeRetainedValue()
            let (finish, completion, cancelled) = box.value
            MainActor.assumeIsolated {
                if let source, let result, let url = finish(source.opaque, result.opaque) {
                    completion(url)
                } else {
                    cancelled()
                }
            }
        }
        start(dialog, callback, Box((finish, completion, cancelled)).retained)
        g_object_unref(dialog.raw)
    }

    private static func url(_ file: OpaquePointer?) -> URL? {
        guard let file else { return nil }
        defer { g_object_unref(file.raw) }
        return String(gOwned: g_file_get_path(file)).map { URL(fileURLWithPath: $0) }
    }

    /// Asks for a file to open.
    static func open(parent: Widget?, title: String, filters: [Filter] = [], allFiles: Bool = true,
                     _ completion: @escaping @MainActor (URL) -> Void) {
        let dialog = make(title: title, filters: filters, allFiles: allFiles)
        run(dialog, finish: { dialog, result in
            url(gtk_file_dialog_open_finish(dialog, result, nil))
        }, completion: completion) { dialog, callback, data in
            gtk_file_dialog_open(dialog, parent?.cast(), nil, callback, data)
        }
    }

    /// Paths from a NULL-terminated C array, which is freed.
    static func urls(_ paths: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> [URL] {
        guard let paths else { return [] }
        defer { g_strfreev(paths) }
        var urls: [URL] = []
        var index = 0
        while let path = paths[index] {
            urls.append(URL(fileURLWithPath: String(cString: path)))
            index += 1
        }
        return urls
    }

    /// Asks for files to open (several at once).
    static func openMultiple(parent: Widget?, title: String, filters: [Filter] = [], allFiles: Bool = true,
                             _ completion: @escaping @MainActor ([URL]) -> Void, cancelled: @escaping Handler = {}) {
        let dialog = make(title: title, filters: filters, allFiles: allFiles)
        let callback: GAsyncReadyCallback = { source, result, data in
            let (completion, cancelled) = Unmanaged<Box<(@MainActor ([URL]) -> Void, Handler)>>.fromOpaque(data!).takeRetainedValue().value
            var urls: [URL] = []
            if let source, let result {
                let files = gtk_file_dialog_open_multiple_finish(source.opaque, result.opaque, nil)
                urls = FileDialogs.urls(la_file_list_paths(files))
                if let files { g_object_unref(files.raw) }
            }
            MainActor.assumeIsolated {
                if urls.isEmpty { cancelled() } else { completion(urls) }
            }
        }
        gtk_file_dialog_open_multiple(dialog, parent?.cast(), nil, callback, Box((completion, cancelled)).retained)
        g_object_unref(dialog.raw)
    }

    /// Asks for a folder.
    static func chooseFolder(parent: Widget?, title: String, initial: URL? = nil,
                             _ completion: @escaping @MainActor (URL) -> Void) {
        let dialog = make(title: title, filters: [], allFiles: false)
        if let initial, let file = g_file_new_for_path(initial.path) {
            gtk_file_dialog_set_initial_folder(dialog, file)
            g_object_unref(file.raw)
        }
        run(dialog, finish: { dialog, result in
            url(gtk_file_dialog_select_folder_finish(dialog, result, nil))
        }, completion: completion) { dialog, callback, data in
            gtk_file_dialog_select_folder(dialog, parent?.cast(), nil, callback, data)
        }
    }

    /// Asks where to save, suggesting `name` (in `folder`, if given).
    static func save(parent: Widget?, title: String, name: String, filters: [Filter] = [], folder: URL? = nil,
                     _ completion: @escaping @MainActor (URL) -> Void, cancelled: @escaping Handler = {}) {
        let dialog = make(title: title, filters: filters, allFiles: false)
        gtk_file_dialog_set_initial_name(dialog, name)
        if let folder, let file = g_file_new_for_path(folder.path) {
            gtk_file_dialog_set_initial_folder(dialog, file)
            g_object_unref(file.raw)
        }
        run(dialog, finish: { dialog, result in
            url(gtk_file_dialog_save_finish(dialog, result, nil))
        }, completion: completion, cancelled: cancelled) { dialog, callback, data in
            gtk_file_dialog_save(dialog, parent?.cast(), nil, callback, data)
        }
    }

    /// "Archimedes 2026-10-22 at 19.30.12.png", as MacArch names files.
    static func timestampedName(_ fileExtension: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Archimedes \(formatter.string(from: Date())).\(fileExtension)"
    }
}

@MainActor
enum Alerts {
    /// A message with an OK button.
    static func show(_ heading: String, _ body: String? = nil, parent: Widget?) {
        let dialog = adw_alert_dialog_new(heading, body)!
        adw_alert_dialog_add_response(dialog.cast(), "ok", "OK")
        adw_alert_dialog_set_default_response(dialog.cast(), "ok")
        adw_dialog_present(dialog.cast(), parent)
    }

    static func show(_ error: Error, parent: Widget?) {
        show("That didn’t work", describe(error), parent: parent)
    }

    /// Foundation's errors in words; the rest as they describe themselves.
    static func describe(_ error: Error) -> String {
        if let error = error as? LocalizedError, let description = error.errorDescription {
            return branded(description)
        }
        if error is CocoaError {
            return error.localizedDescription
        }
        return branded(String(describing: error))
    }

    /// Asks to go ahead with something: true if `button` was chosen.
    static func confirm(_ heading: String, _ body: String?, button: String, destructive: Bool = false,
                        parent: Widget?) async -> Bool {
        await withCheckedContinuation { continuation in
            ask(heading, body, responses: [("cancel", "Cancel"), ("ok", button)], destructive: destructive ? "ok" : nil,
                parent: parent) { continuation.resume(returning: $0 == "ok") }
        }
    }

    /// Asks a question: `responses` are (id, label) pairs, the last the
    /// default; `destructive` marks one red.
    static func ask(_ heading: String, _ body: String?, responses: [(String, String)], destructive: String? = nil,
                    parent: Widget?, _ completion: @escaping @MainActor (String) -> Void) {
        let dialog = adw_alert_dialog_new(heading, body)!
        for (id, label) in responses {
            adw_alert_dialog_add_response(dialog.cast(), id, label)
        }
        if let last = responses.last?.0 {
            adw_alert_dialog_set_default_response(dialog.cast(), last)
        }
        if let first = responses.first?.0 {
            adw_alert_dialog_set_close_response(dialog.cast(), first)
        }
        if let destructive {
            adw_alert_dialog_set_response_appearance(dialog.cast(), destructive, ADW_RESPONSE_DESTRUCTIVE)
        }
        let callback: GAsyncReadyCallback = { source, result, data in
            let completion = Unmanaged<Box<@MainActor (String) -> Void>>.fromOpaque(data!).takeRetainedValue().value
            guard let source, let result else { return }
            let response = String(gBorrowed: adw_alert_dialog_choose_finish(source.cast(), result.opaque)) ?? ""
            MainActor.assumeIsolated { completion(response) }
        }
        adw_alert_dialog_choose(dialog.cast(), parent, nil, callback, Box(completion).retained)
    }
}

extension Alerts {
    /// Asks a question with several answers: `responses` are (id, label)
    /// pairs, the first what closing it means and the last the default.
    /// Returns the id chosen.
    static func choice(_ heading: String, _ body: String?, responses: [(String, String)], destructive: String? = nil,
                       parent: Widget?) async -> String {
        await withCheckedContinuation { continuation in
            ask(heading, body, responses: responses, destructive: destructive, parent: parent) { continuation.resume(returning: $0) }
        }
    }

    /// Asks for one of `items` from a drop-down under the question: its
    /// index, or nil if it's cancelled.
    static func chooseItem(_ heading: String, _ body: String?, items: [String], selected: Int, button: String,
                           parent: Widget?) async -> Int? {
        var chosen = selected
        let dropDown = UI.dropDown(items, selected: selected) { chosen = $0 }
        return await withCheckedContinuation { continuation in
            let dialog = adw_alert_dialog_new(heading, body)!
            adw_alert_dialog_set_extra_child(dialog.cast(), dropDown)
            adw_alert_dialog_add_response(dialog.cast(), "cancel", "Cancel")
            adw_alert_dialog_add_response(dialog.cast(), "ok", button)
            adw_alert_dialog_set_response_appearance(dialog.cast(), "ok", ADW_RESPONSE_SUGGESTED)
            adw_alert_dialog_set_default_response(dialog.cast(), "ok")
            adw_alert_dialog_set_close_response(dialog.cast(), "cancel")
            let completion: @MainActor (String) -> Void = { continuation.resume(returning: $0 == "ok" ? chosen : nil) }
            let callback: GAsyncReadyCallback = { source, result, data in
                let completion = Unmanaged<Box<@MainActor (String) -> Void>>.fromOpaque(data!).takeRetainedValue().value
                let response = source.flatMap { source in
                    result.flatMap { String(gBorrowed: adw_alert_dialog_choose_finish(source.cast(), $0.opaque)) }
                } ?? ""
                MainActor.assumeIsolated { completion(response) }
            }
            adw_alert_dialog_choose(dialog.cast(), parent, nil, callback, Box(completion).retained)
        }
    }

    /// Asks for one of `items`, as above, with a check box under the
    /// drop-down (on to begin with): the index and whether it's ticked, or
    /// nil if it's cancelled. `body` is the question, given the box's state.
    static func chooseItem(_ heading: String, _ body: @escaping (Bool) -> String, items: [String], selected: Int,
                           option: String, optionTooltip: String? = nil, button: String,
                           parent: Widget?) async -> (Int, Bool)? {
        let dialog = adw_alert_dialog_new(heading, body(true))!
        var chosen = selected
        var ticked = true
        let dropDown = UI.dropDown(items, selected: selected) { chosen = $0 }
        let check = UI.check(option, active: true) { on in
            ticked = on
            adw_alert_dialog_set_body(dialog.cast(), body(on))
        }
        check.setTooltip(optionTooltip)
        let index = await withCheckedContinuation { continuation in
            adw_alert_dialog_set_extra_child(dialog.cast(), UI.vbox(spacing: 12, [dropDown, check]))
            adw_alert_dialog_add_response(dialog.cast(), "cancel", "Cancel")
            adw_alert_dialog_add_response(dialog.cast(), "ok", button)
            adw_alert_dialog_set_response_appearance(dialog.cast(), "ok", ADW_RESPONSE_SUGGESTED)
            adw_alert_dialog_set_default_response(dialog.cast(), "ok")
            adw_alert_dialog_set_close_response(dialog.cast(), "cancel")
            let completion: @MainActor (String) -> Void = { continuation.resume(returning: $0 == "ok" ? chosen : nil) }
            let callback: GAsyncReadyCallback = { source, result, data in
                let completion = Unmanaged<Box<@MainActor (String) -> Void>>.fromOpaque(data!).takeRetainedValue().value
                let response = source.flatMap { source in
                    result.flatMap { String(gBorrowed: adw_alert_dialog_choose_finish(source.cast(), $0.opaque)) }
                } ?? ""
                MainActor.assumeIsolated { completion(response) }
            }
            adw_alert_dialog_choose(dialog.cast(), parent, nil, callback, Box(completion).retained)
        }
        return index.map { ($0, ticked) }
    }

    /// A question with a widget of its own (an entry, say) under it: calls
    /// `completion` if `button` is chosen.
    static func askWithChild(_ heading: String, _ body: String?, child: Widget, button: String, parent: Widget?,
                             _ completion: @escaping @MainActor () -> Void, cancelled: @escaping @MainActor () -> Void = {}) {
        let dialog = adw_alert_dialog_new(heading, body)!
        adw_alert_dialog_set_extra_child(dialog.cast(), child)
        adw_alert_dialog_add_response(dialog.cast(), "cancel", "Cancel")
        adw_alert_dialog_add_response(dialog.cast(), "ok", button)
        adw_alert_dialog_set_response_appearance(dialog.cast(), "ok", ADW_RESPONSE_SUGGESTED)
        adw_alert_dialog_set_default_response(dialog.cast(), "ok")
        adw_alert_dialog_set_close_response(dialog.cast(), "cancel")
        let callback: GAsyncReadyCallback = { source, result, data in
            let (completion, cancelled) = Unmanaged<Box<(@MainActor () -> Void, @MainActor () -> Void)>>.fromOpaque(data!).takeRetainedValue().value
            let response = source.flatMap { source in
                result.flatMap { String(gBorrowed: adw_alert_dialog_choose_finish(source.cast(), $0.opaque)) }
            } ?? ""
            MainActor.assumeIsolated { if response == "ok" { completion() } else { cancelled() } }
        }
        adw_alert_dialog_choose(dialog.cast(), parent, nil, callback, Box((completion, cancelled)).retained)
    }
}

@MainActor
enum Clipboard {
    private static var clipboard: OpaquePointer {
        gdk_display_get_clipboard(gdk_display_get_default())
    }

    static func setText(_ text: String) {
        gdk_clipboard_set_text(clipboard, text)
    }

    /// Puts an image (PNG data) on the clipboard.
    static func setPNG(_ png: Data) {
        let bytes = png.withUnsafeBytes { g_bytes_new($0.baseAddress, gsize($0.count)) }
        defer { g_bytes_unref(bytes) }
        guard let texture = gdk_texture_new_from_bytes(bytes, nil) else { return }
        gdk_clipboard_set_texture(clipboard, texture)
        g_object_unref(texture.raw)
    }

    /// The clipboard's text, if it has some.
    static func readText(_ completion: @escaping @MainActor (String?) -> Void) {
        let callback: GAsyncReadyCallback = { source, result, data in
            let completion = Unmanaged<Box<@MainActor (String?) -> Void>>.fromOpaque(data!).takeRetainedValue().value
            guard let source, let result else { return }
            let text = String(gOwned: gdk_clipboard_read_text_finish(source.opaque, result.opaque, nil))
            MainActor.assumeIsolated { completion(text) }
        }
        gdk_clipboard_read_text_async(clipboard, nil, callback, Box(completion).retained)
    }
}

/// Text from the shared code (which is MacArch's) as LinuxArch shows it:
/// "isn’t a disc image MacArch can read" names this app.
func branded(_ text: String) -> String {
    text.replacingOccurrences(of: "MacArch", with: "LinuxArch")
}

/// The app's window in front, for dialogs that don't belong to one.
@MainActor
var frontWindow: Widget? {
    gtk_application_get_active_window(LinuxArchApp.shared.app.cast()).map { $0.widget }
}

/// Shows a file in the file manager, selected.
@MainActor
func revealInFileManager(_ url: URL, parent: Widget?) {
    let file = g_file_new_for_path(url.path)!
    let launcher = gtk_file_launcher_new(file)!
    gtk_file_launcher_open_containing_folder(launcher, parent?.cast(), nil, nil, nil)
    g_object_unref(launcher.raw)
    g_object_unref(file.raw)
}

/// Opens a web page in the user's browser.
@MainActor
func openURI(_ uri: String, parent: Widget?) {
    let launcher = gtk_uri_launcher_new(uri)!
    gtk_uri_launcher_launch(launcher, parent?.cast(), nil, nil, nil)
    g_object_unref(launcher.raw)
}

/// Notes a file in GTK's recent files (the desktop's, which file choosers
/// and the file manager show).
@MainActor
func noteRecentFile(_ url: URL) {
    guard let uri = String(gOwned: g_filename_to_uri(url.path, nil, nil)) else { return }
    _ = gtk_recent_manager_add_item(gtk_recent_manager_get_default(), uri)
}
