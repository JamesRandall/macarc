// GActions (what menus, buttons and shortcuts invoke) and GMenus.

import CGtk

/// A GSimpleAction.
@MainActor
final class Action {
    let pointer: OpaquePointer

    init(_ pointer: OpaquePointer) {
        self.pointer = pointer
    }

    var isEnabled: Bool {
        get { g_action_get_enabled(pointer) != 0 }
        set {
            if newValue != isEnabled { g_simple_action_set_enabled(pointer, newValue ? 1 : 0) }
        }
    }

    func setState(_ on: Bool) {
        let current = g_action_get_state(pointer)
        defer { if let current { g_variant_unref(current) } }
        if let current, (g_variant_get_boolean(current) != 0) == on { return }
        g_simple_action_set_state(pointer, g_variant_new_boolean(on ? 1 : 0))
    }

    func setState(_ value: String) {
        let current = g_action_get_state(pointer)
        defer { if let current { g_variant_unref(current) } }
        if let current, String(gBorrowed: g_variant_get_string(current, nil)) == value { return }
        g_simple_action_set_state(pointer, g_variant_new_string(value))
    }
}

/// Actions added to a window or the app (anything that's a GActionMap).
@MainActor
final class Actions {
    let map: OpaquePointer
    private(set) var all: [String: Action] = [:]

    init(_ map: some GPointer) {
        self.map = map.opaque
    }

    subscript(name: String) -> Action? { all[name] }

    private func add(_ pointer: OpaquePointer, _ name: String) -> Action {
        g_action_map_add_action(map, pointer)
        let action = Action(pointer)
        all[name] = action
        g_object_unref(pointer.raw)
        return action
    }

    @discardableResult
    func add(_ name: String, _ handler: @escaping Handler) -> Action {
        let pointer: OpaquePointer = g_simple_action_new(name, nil)
        onVariant(pointer, "activate") { _ in handler() }
        return add(pointer, name)
    }

    /// An action with a string parameter (`win.insert-bundled::0:cpm`).
    @discardableResult
    func add(_ name: String, string handler: @escaping @MainActor (String) -> Void) -> Action {
        let pointer: OpaquePointer = g_simple_action_new(name, la_variant_type_string())
        onVariant(pointer, "activate") { variant in
            guard let variant else { return }
            handler(String(gBorrowed: g_variant_get_string(variant, nil)) ?? "")
        }
        return add(pointer, name)
    }

    /// A check box in menus.
    @discardableResult
    func addToggle(_ name: String, state: Bool, _ handler: @escaping @MainActor (Bool) -> Void) -> Action {
        let pointer: OpaquePointer = g_simple_action_new_stateful(name, nil, g_variant_new_boolean(state ? 1 : 0))
        onVariant(pointer, "activate") { _ in
            let current = g_action_get_state(pointer)
            let on = current.map { g_variant_get_boolean($0) != 0 } ?? false
            if let current { g_variant_unref(current) }
            handler(!on)
        }
        return add(pointer, name)
    }

    /// Radio items in menus: each item's target is a value.
    @discardableResult
    func addRadio(_ name: String, state: String, _ handler: @escaping @MainActor (String) -> Void) -> Action {
        let pointer: OpaquePointer = g_simple_action_new_stateful(name, la_variant_type_string(), g_variant_new_string(state))
        onVariant(pointer, "activate") { variant in
            guard let variant else { return }
            handler(String(gBorrowed: g_variant_get_string(variant, nil)) ?? "")
        }
        return add(pointer, name)
    }
}

/// A GMenu, built in code.
@MainActor
final class Menu {
    let pointer: OpaquePointer

    init() {
        pointer = g_menu_new()
    }

    var model: UnsafeMutablePointer<GMenuModel> { pointer.cast() }

    @discardableResult
    func item(_ label: String, _ action: String, string target: String? = nil) -> Menu {
        let item = g_menu_item_new(label, nil)!
        if let target {
            g_menu_item_set_action_and_target_value(item, action, g_variant_new_string(target))
        } else {
            g_menu_item_set_action_and_target_value(item, action, nil)
        }
        g_menu_append_item(pointer, item)
        g_object_unref(item.raw)
        return self
    }

    @discardableResult
    func section(_ label: String? = nil, _ build: (Menu) -> Void) -> Menu {
        let section = Menu()
        build(section)
        g_menu_append_section(pointer, label, section.model)
        return self
    }

    @discardableResult
    func submenu(_ label: String, _ build: (Menu) -> Void) -> Menu {
        let submenu = Menu()
        build(submenu)
        g_menu_append_submenu(pointer, label, submenu.model)
        return self
    }

    /// Replaces everything (for menus whose items change: recent discs).
    func removeAll() {
        g_menu_remove_all(pointer)
    }
}
