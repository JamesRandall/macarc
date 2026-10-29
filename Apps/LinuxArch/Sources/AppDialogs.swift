import CGtk
import Foundation

/// Help's dialogs: the keyboard shortcuts, About, and What's New.
@MainActor
enum ShortcutsDialog {
    static func present(parent: Widget?) {
        let dialog = adw_shortcuts_dialog_new()!
        for section in LinuxArchApp.shortcuts {
            let gtkSection = adw_shortcuts_section_new(section.section)!
            for item in section.items {
                let gtkItem = adw_shortcuts_item_new(item.title, item.accels.joined(separator: " "))!
                adw_shortcuts_section_add(gtkSection, gtkItem)
            }
            adw_shortcuts_dialog_add(dialog.cast(), gtkSection)
        }
        // Where the Archimedes' keys a PC hasn't are.
        let arc = adw_shortcuts_section_new("The Archimedes’ Keys")!
        // (£ is the key left of Z, whatever your layout calls it.)
        for (title, accelerator) in [("Copy", "End"), ("Break", "Pause"), ("Print", "Print"), ("Insert", "Insert"),
                                     ("Alt", "Alt_L"), ("Caps Lock", "Caps_Lock")] {
            adw_shortcuts_section_add(arc, adw_shortcuts_item_new(title, accelerator))
        }
        adw_shortcuts_dialog_add(dialog.cast(), arc)
        adw_dialog_present(dialog.cast(), parent)
    }
}

@MainActor
enum AboutDialog {
    static func present(parent: Widget?) {
        let dialog = adw_about_dialog_new()!
        let about: OpaquePointer = dialog.cast()
        adw_about_dialog_set_application_name(about, "LinuxArch")
        adw_about_dialog_set_application_icon(about, AppInfo.id)
        adw_about_dialog_set_developer_name(about, "James Randall")
        adw_about_dialog_set_version(about, AppInfo.version)
        adw_about_dialog_set_comments(about, "An Acorn Archimedes emulator: MacArch, for Linux.")
        adw_about_dialog_set_website(about, AppInfo.website)
        adw_about_dialog_add_link(about, "MacArch on GitHub", AppInfo.repository)
        adw_about_dialog_set_license_type(about, GTK_LICENSE_GPL_3_0)
        adw_about_dialog_set_copyright(about, "© 2026 James Randall")
        adw_about_dialog_add_legal_section(about, "RISC OS",
            "Acorn’s RISC OS ROMs are copyright; they’re not included, and not covered by the GPL.",
            GTK_LICENSE_CUSTOM, nil)
        if AppPaths.resource("ArcLibre/ArcLibre.rom") != nil {
            adw_about_dialog_add_legal_section(about, "ArcLibre",
                "ArcLibre, a free ROM restored from Acorn’s publicly released RISC OS sources, is included. Its floating point emulator carries ARM Limited’s BSD notice, and its Squash compressor a BSD notice.",
                GTK_LICENSE_APACHE_2_0, nil)
        }
        if let release = WhatsNew.releases.first {
            adw_about_dialog_set_release_notes_version(about, release.version)
            adw_about_dialog_set_release_notes(about, WhatsNewDialog.appStreamMarkup(release))
        }
        adw_dialog_present(dialog.cast(), parent)
    }
}

/// What's New in LinuxArch, also opened on the first launch after an
/// update: the release notes, newest first, with those since the last
/// version the user ran marked New.
@MainActor
enum WhatsNewDialog {
    static func present(parent: Widget?) {
        let dialog = adw_dialog_new()!
        adw_dialog_set_title(dialog.cast(), "What’s New")
        adw_dialog_set_content_width(dialog.cast(), 520)
        adw_dialog_set_content_height(dialog.cast(), 560)

        let icon = gtk_image_new_from_icon_name(AppInfo.id)!
        gtk_image_set_pixel_size(icon.cast(), 56)
        let heading = UI.vbox(spacing: 2, [
            UI.label("What’s New in LinuxArch", classes: ["title-2"]),
            UI.label("Version \(WhatsNew.currentVersion)", classes: ["dim-label"]),
        ])
        heading.align(vertical: GTK_ALIGN_CENTER)
        let top = UI.hbox(spacing: 14, [icon, heading])
        top.setMargins(20)

        let releases = UI.vbox(spacing: 22)
        releases.setMargins(20)
        if WhatsNew.releases.isEmpty {
            UI.append(releases, UI.label("There are no release notes in this build.", classes: ["dim-label"]))
        }
        for release in WhatsNew.releases {
            UI.append(releases, section(release))
        }

        let done = UI.button("Continue", classes: ["suggested-action", "pill"]) {
            adw_dialog_close(dialog.cast())
        }
        done.align(horizontal: GTK_ALIGN_END)
        let bottom = UI.hbox(spacing: 8, [UI.spacer(), done])
        bottom.setMargins(top: 12, bottom: 12, start: 20, end: 20)

        let content = UI.vbox(spacing: 0, [top, UI.separator(), UI.scrolled(releases), UI.separator(), bottom])
        let toolbar = adw_toolbar_view_new()!
        let header = adw_header_bar_new()!
        adw_header_bar_set_show_title(header.cast(), 0)
        adw_toolbar_view_add_top_bar(toolbar.cast(), header)
        adw_toolbar_view_set_content(toolbar.cast(), content)
        adw_dialog_set_child(dialog.cast(), toolbar)
        adw_dialog_set_default_widget(dialog.cast(), done)
        adw_dialog_present(dialog.cast(), parent)
        // (Not the first selectable note, which would show it selected.)
        adw_dialog_set_focus(dialog.cast(), done)
    }

    private static func section(_ release: WhatsNew.Release) -> Widget {
        var heading: [Widget] = [UI.label(release.version, classes: ["heading"])]
        if let date = release.date {
            heading.append(UI.label(date, classes: ["dim-label"]))
        }
        if WhatsNew.isNew(release, since: WhatsNew.previousVersion) {
            let badge = UI.label("NEW", classes: ["new-badge"])
            badge.align(vertical: GTK_ALIGN_CENTER)
            heading.append(badge)
        }
        let box = UI.vbox(spacing: 8, [UI.hbox(spacing: 8, heading)])
        for line in release.intro {
            let label = UI.markup(pango(line))
            gtk_label_set_selectable(label.cast(), 1)
            UI.append(box, label)
        }
        for item in release.items {
            let bullet = UI.label("•", classes: ["dim-label"])
            bullet.align(vertical: GTK_ALIGN_START)
            let text = UI.markup(pango(item))
            gtk_label_set_selectable(text.cast(), 1)
            text.expand(horizontally: true)
            UI.append(box, UI.hbox(spacing: 8, [bullet, text]))
        }
        return box
    }

    /// Inline Markdown (**bold**, *italic*, `code`, [links](url)) as Pango
    /// markup.
    static func pango(_ markdown: String) -> String {
        var text = UI.escape(markdown)
        let rules: [(String, String)] = [
            (#"\[([^\]]+)\]\(([^)\s]+)\)"#, #"<a href="$2">$1</a>"#),
            (#"\*\*([^*]+)\*\*"#, "<b>$1</b>"),
            (#"\*([^*]+)\*"#, "<i>$1</i>"),
            (#"`([^`]+)`"#, "<tt>$1</tt>"),
        ]
        for (pattern, template) in rules {
            text = text.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return text
    }

    /// A release as AppStream's description markup (for About's release
    /// notes): paragraphs and a list, inline Markdown dropped.
    static func appStreamMarkup(_ release: WhatsNew.Release) -> String {
        func plain(_ markdown: String) -> String {
            var text = markdown
            for (pattern, template) in [(#"\[([^\]]+)\]\(([^)\s]+)\)"#, "$1"), (#"\*\*([^*]+)\*\*"#, "$1"),
                                        (#"\*([^*]+)\*"#, "$1"), (#"`([^`]+)`"#, "$1")] {
                text = text.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
            }
            return UI.escape(text)
        }
        let intro = release.intro.map { "<p>\(plain($0))</p>" }.joined()
        let items = release.items.isEmpty ? "" : "<ul>" + release.items.map { "<li>\(plain($0))</li>" }.joined() + "</ul>"
        return intro + items
    }
}
