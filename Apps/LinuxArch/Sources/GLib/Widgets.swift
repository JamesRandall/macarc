// Building GTK widgets from Swift.

import CGtk

@MainActor
enum UI {
    static func label(_ text: String, classes: [String] = [], wrap: Bool = false, xalign: Float = 0,
                      selectable: Bool = false) -> Widget {
        let label = gtk_label_new(text)!
        gtk_label_set_xalign(label.cast(), xalign)
        if wrap {
            gtk_label_set_wrap(label.cast(), 1)
            gtk_label_set_wrap_mode(label.cast(), PANGO_WRAP_WORD_CHAR)
        }
        if selectable {
            gtk_label_set_selectable(label.cast(), 1)
        }
        for name in classes { label.addClass(name) }
        return label
    }

    /// A label showing Pango markup.
    static func markup(_ markup: String, classes: [String] = [], wrap: Bool = true) -> Widget {
        let label = UI.label("", classes: classes, wrap: wrap)
        gtk_label_set_markup(label.cast(), markup)
        return label
    }

    static func setText(_ label: Widget, _ text: String) {
        // Setting the same text still relayouts; don't.
        if String(gBorrowed: gtk_label_get_text(label.cast())) != text {
            gtk_label_set_text(label.cast(), text)
        }
    }

    static func button(_ label: String, classes: [String] = [], _ action: @escaping Handler) -> Widget {
        let button = gtk_button_new_with_mnemonic(label)!
        for name in classes { button.addClass(name) }
        onSignal(button, "clicked", action)
        return button
    }

    static func iconButton(_ icon: String, tooltip: String, classes: [String] = [], _ action: @escaping Handler) -> Widget {
        let button = gtk_button_new_from_icon_name(icon)!
        button.setTooltip(tooltip)
        for name in classes { button.addClass(name) }
        onSignal(button, "clicked", action)
        return button
    }

    /// A button for an action (`win.pause`, say), so it follows the action's
    /// enabled state.
    static func actionButton(icon: String, tooltip: String, action: String) -> Widget {
        let button = gtk_button_new_from_icon_name(icon)!
        button.setTooltip(tooltip)
        gtk_actionable_set_action_name(button.cast(), action)
        return button
    }

    static func box(_ orientation: GtkOrientation, spacing: Int32 = 0, _ children: [Widget] = [],
                    classes: [String] = []) -> Widget {
        let box = gtk_box_new(orientation, spacing)!
        for child in children { gtk_box_append(box.cast(), child) }
        for name in classes { box.addClass(name) }
        return box
    }

    static func vbox(spacing: Int32 = 0, _ children: [Widget] = [], classes: [String] = []) -> Widget {
        box(GTK_ORIENTATION_VERTICAL, spacing: spacing, children, classes: classes)
    }

    static func hbox(spacing: Int32 = 0, _ children: [Widget] = [], classes: [String] = []) -> Widget {
        box(GTK_ORIENTATION_HORIZONTAL, spacing: spacing, children, classes: classes)
    }

    static func append(_ box: Widget, _ child: Widget) {
        gtk_box_append(box.cast(), child)
    }

    static func removeAll(_ box: Widget) {
        while let child = gtk_widget_get_first_child(box) {
            gtk_box_remove(box.cast(), child)
        }
    }

    static func spacer() -> Widget {
        let spacer = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)!
        spacer.expand(horizontally: true)
        return spacer
    }

    static func separator(_ orientation: GtkOrientation = GTK_ORIENTATION_HORIZONTAL) -> Widget {
        gtk_separator_new(orientation)
    }

    static func scrolled(_ child: Widget, horizontal: GtkPolicyType = GTK_POLICY_NEVER,
                         vertical: GtkPolicyType = GTK_POLICY_AUTOMATIC) -> Widget {
        let scrolled = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_policy(scrolled.cast(), horizontal, vertical)
        gtk_scrolled_window_set_child(scrolled.cast(), child)
        scrolled.expand(horizontally: true, vertically: true)
        return scrolled
    }

    static func entry(placeholder: String = "", width: Int32? = nil, _ activate: Handler? = nil) -> Widget {
        let entry = gtk_entry_new()!
        gtk_entry_set_placeholder_text(entry.cast(), placeholder)
        if let width { gtk_editable_set_width_chars(entry.cast(), width) }
        if let activate { onSignal(entry, "activate", activate) }
        return entry
    }

    static func text(of editable: Widget) -> String {
        String(gBorrowed: gtk_editable_get_text(editable.cast())) ?? ""
    }

    static func setText(editable: Widget, _ text: String) {
        if UI.text(of: editable) != text {
            gtk_editable_set_text(editable.cast(), text)
        }
    }

    /// A drop-down of `items`, calling `changed` with the index chosen.
    static func dropDown(_ items: [String], selected: Int = 0, _ changed: @escaping @MainActor (Int) -> Void) -> Widget {
        let dropDown = gtk_drop_down_new(stringList(items), nil)!
        gtk_drop_down_set_selected(dropDown.cast(), guint(max(0, selected)))
        onNotify(dropDown, "selected") {
            let index = gtk_drop_down_get_selected(dropDown.cast())
            if index != GTK_INVALID_LIST_POSITION { changed(Int(index)) }
        }
        return dropDown
    }

    /// A drop-down of many items (Archimedes keys), with a search box.
    static func searchableDropDown(_ items: [String], selected: Int = 0,
                                   _ changed: @escaping @MainActor (Int) -> Void) -> Widget {
        let dropDown = dropDown(items, selected: selected, changed)
        let expression = gtk_property_expression_new(gtk_string_object_get_type(), nil, "string")
        gtk_drop_down_set_expression(dropDown.cast(), expression)
        gtk_expression_unref(expression)
        gtk_drop_down_set_enable_search(dropDown.cast(), 1)
        la_set_int(dropDown.raw, "search-match-mode", Int32(GTK_STRING_FILTER_MATCH_MODE_SUBSTRING.rawValue))
        return dropDown
    }

    /// Selects an item, if it isn't already (the drop-down's handler is
    /// called, so handlers ignore a selection the model already has).
    static func select(_ dropDown: Widget, _ index: Int) {
        if Int(gtk_drop_down_get_selected(dropDown.cast())) != index {
            gtk_drop_down_set_selected(dropDown.cast(), guint(max(0, index)))
        }
    }

    /// A libadwaita combo row of `items`, calling `changed` with the index
    /// chosen.
    static func comboRow(_ title: String, subtitle: String? = nil, _ items: [String], selected: Int = 0,
                         _ changed: @escaping @MainActor (Int) -> Void) -> Widget {
        let row = adw_combo_row_new()!
        adw_preferences_row_set_title(row.cast(), title)
        if let subtitle { adw_action_row_set_subtitle(row.cast(), subtitle) }
        adw_combo_row_set_model(row.cast(), stringList(items))
        adw_combo_row_set_selected(row.cast(), guint(max(0, selected)))
        onNotify(row, "selected") {
            let index = adw_combo_row_get_selected(row.cast())
            if index != GTK_INVALID_LIST_POSITION { changed(Int(index)) }
        }
        return row
    }

    /// Replaces a combo row's items (its handler sees the new selection).
    static func setItems(comboRow row: Widget, _ items: [String], selected: Int) {
        adw_combo_row_set_model(row.cast(), stringList(items))
        adw_combo_row_set_selected(row.cast(), guint(max(0, selected)))
    }

    /// A libadwaita action row: a title, a subtitle, and widgets at its end.
    static func actionRow(_ title: String, subtitle: String? = nil, suffixes: [Widget] = []) -> Widget {
        let row = adw_action_row_new()!
        adw_preferences_row_set_title(row.cast(), title)
        adw_preferences_row_set_use_markup(row.cast(), 0)
        if let subtitle { adw_action_row_set_subtitle(row.cast(), subtitle) }
        for suffix in suffixes {
            suffix.align(vertical: GTK_ALIGN_CENTER)
            adw_action_row_add_suffix(row.cast(), suffix)
        }
        return row
    }

    static func preferencesGroup(_ title: String? = nil, description: String? = nil, _ rows: [Widget] = []) -> Widget {
        let group = adw_preferences_group_new()!
        if let title { adw_preferences_group_set_title(group.cast(), title) }
        if let description { adw_preferences_group_set_description(group.cast(), description) }
        for row in rows { adw_preferences_group_add(group.cast(), row) }
        return group
    }

    static func stringList(_ items: [String]) -> OpaquePointer {
        let list = gtk_string_list_new(nil)!
        for item in items { gtk_string_list_append(list, item) }
        return list
    }

    static func check(_ label: String, active: Bool, _ toggled: @escaping @MainActor (Bool) -> Void) -> Widget {
        let check = gtk_check_button_new_with_label(label)!
        gtk_check_button_set_active(check.cast(), active ? 1 : 0)
        onSignal(check, "toggled") { toggled(gtk_check_button_get_active(check.cast()) != 0) }
        return check
    }

    static func setActive(check: Widget, _ on: Bool) {
        if (gtk_check_button_get_active(check.cast()) != 0) != on {
            gtk_check_button_set_active(check.cast(), on ? 1 : 0)
        }
    }

    static func image(icon: String, size: Int32 = 16) -> Widget {
        let image = gtk_image_new_from_icon_name(icon)!
        gtk_image_set_pixel_size(image.cast(), size)
        return image
    }

    /// Escapes text for Pango markup.
    static func escape(_ text: String) -> String {
        String(gOwned: g_markup_escape_text(text, -1)) ?? text
    }

    /// Applies CSS to the whole app.
    static func addCSS(_ css: String) {
        let provider = gtk_css_provider_new()!
        gtk_css_provider_load_from_string(provider, css)
        gtk_style_context_add_provider_for_display(gdk_display_get_default(), provider.opaque,
                                                   guint(GTK_STYLE_PROVIDER_PRIORITY_APPLICATION))
    }
}

/// Rows of a box kept in step with an array, reusing rows rather than
/// rebuilding them on every refresh (the debugger refreshes often). A row is
/// whatever holds its widgets (`Row`), its top widget given by `widget`.
@MainActor
final class RowList<Item, Row> {
    let box: Widget
    private(set) var rows: [Row] = []
    private let make: @MainActor () -> Row
    private let widget: @MainActor (Row) -> Widget
    private let update: @MainActor (Row, Item, Int) -> Void

    /// `make` builds an empty row; `update` shows an item in one.
    init(box: Widget, make: @escaping @MainActor () -> Row, widget: @escaping @MainActor (Row) -> Widget,
         update: @escaping @MainActor (Row, Item, Int) -> Void) {
        self.box = box
        self.make = make
        self.widget = widget
        self.update = update
    }

    func show(_ items: [Item]) {
        while rows.count < items.count {
            let row = make()
            rows.append(row)
            UI.append(box, widget(row))
        }
        while rows.count > items.count {
            gtk_box_remove(box.cast(), widget(rows.removeLast()))
        }
        for (index, item) in items.enumerated() {
            update(rows[index], item, index)
        }
    }
}

extension RowList where Row == Widget {
    convenience init(box: Widget, make: @escaping @MainActor () -> Widget,
                     update: @escaping @MainActor (Widget, Item, Int) -> Void) {
        self.init(box: box, make: make, widget: { $0 }, update: update)
    }
}
