import ArchimedesCore
import CGtk
import Foundation

/// The network laid out freely: machines as cards with their screens live,
/// the clock, and the bus they share drawn behind them. Pan by dragging the
/// background or scrolling, zoom with Ctrl-scrolling or a pinch. (The Mac
/// app's NetworkCanvas: the cards are widgets, placed and scaled on a
/// GtkFixed; a drawing area behind them draws the grid and the bus, and
/// takes the pointer, finding the card under it by the layout.)
@MainActor
final class NetworkCanvasView {
    let widget: Widget
    private let session: NetworkSession
    private weak var studio: NetworkStudioWindow?
    private let area: Widget
    private let board: Widget
    private let problemsBox: Widget
    private let zoomLabel: Widget
    private var cards: [UUID: CanvasCard] = [:]
    private var remoteCards: [Int: RemoteCard] = [:]
    private let actions: Actions

    private var zoom = 1.0
    private var centre = (x: 0.0, y: 0.0)
    /// Nodes being dragged, and how far (in view pixels).
    private var dragging: (ids: Set<UUID>, dx: Double, dy: Double)?
    private var panStart: (x: Double, y: Double)?
    private var zoomStart: Double?
    private var pressedNode: UUID?

    static let grid = 20.0
    static let zoomRange = 0.25...2.5
    /// A monitor's 4:3 picture.
    static let screenAspect = 4.0 / 3.0

    init(session: NetworkSession, studio: NetworkStudioWindow) {
        self.session = session
        self.studio = studio
        area = gtk_drawing_area_new()!
        board = gtk_fixed_new()!
        problemsBox = UI.vbox(spacing: 4, classes: ["canvas-float"])
        zoomLabel = UI.label("100%", classes: ["caption", "numeric"], xalign: 0.5)
        widget = gtk_overlay_new()!
        let group = g_simple_action_group_new()!
        actions = Actions(OpaquePointer(group))
        gtk_widget_insert_action_group(widget, "canvas", OpaquePointer(group))
        g_object_unref(group.raw)

        zoom = session.project.canvas.zoom
        centre = (session.project.canvas.centre.x, session.project.canvas.centre.y)
        build()
        addActions()
        observeSession()
        // A new network (zoom 0) starts with everything in view.
        if zoom <= 0 {
            zoom = 1
            after(0.1) { [weak self] in self?.fit() }
        }
    }

    /// The view's going: its cards stop asking for pictures.
    func close() {
        for card in cards.values { card.hideScreen() }
    }

    // MARK: Building

    private func build() {
        area.expand(horizontally: true, vertically: true)
        gtk_widget_set_focusable(area, 1)
        area.addClass("canvas")
        let draw: GtkDrawingAreaDrawFunc = { _, cairo, width, height, data in
            let view = Unmanaged<NetworkCanvasView>.fromOpaque(data!).takeUnretainedValue()
            MainActor.assumeIsolated { view.draw(cairo!, Double(width), Double(height)) }
        }
        gtk_drawing_area_set_draw_func(area.cast(), draw, Unmanaged.passUnretained(self).toOpaque(), nil)
        onResize(area) { [weak self] _, _ in self?.layout() }
        gtk_overlay_set_child(widget.cast(), area)
        gtk_widget_set_can_target(board, 0)
        gtk_overlay_add_overlay(widget.cast(), board)
        gtk_widget_set_overflow(widget, GTK_OVERFLOW_HIDDEN)

        let palette = self.palette()
        palette.align(horizontal: GTK_ALIGN_START, vertical: GTK_ALIGN_START)
        palette.setMargins(12)
        gtk_overlay_add_overlay(widget.cast(), palette)
        problemsBox.align(horizontal: GTK_ALIGN_CENTER, vertical: GTK_ALIGN_START)
        problemsBox.setMargins(top: 12)
        gtk_overlay_add_overlay(widget.cast(), problemsBox)
        let zoomControls = self.zoomControls()
        zoomControls.align(horizontal: GTK_ALIGN_END, vertical: GTK_ALIGN_END)
        zoomControls.setMargins(12)
        gtk_overlay_add_overlay(widget.cast(), zoomControls)

        addGestures()
    }

    private func palette() -> Widget {
        let box = UI.vbox(spacing: 2, [UI.label("Add", classes: ["caption-heading", "dim-label"])], classes: ["canvas-float", "palette"])
        for item in PaletteItem.allCases {
            let content = adw_button_content_new()!
            adw_button_content_set_icon_name(content.cast(), item.icon)
            adw_button_content_set_label(content.cast(), item.title)
            gtk_widget_set_halign(content, GTK_ALIGN_START)
            let button = gtk_button_new()!
            gtk_button_set_child(button.cast(), content)
            button.addClass("flat")
            button.setTooltip("Drag onto the network, or click to add")
            onSignal(button, "clicked") { [weak self] in
                guard let self else { return }
                // At the end of its row, along the trunk.
                self.add(item, at: self.session.project.nextPosition(for: item.kind))
            }
            // Dragged onto the canvas: added where it's dropped.
            let source = gtk_drag_source_new()!
            gtk_drag_source_set_actions(source, GDK_ACTION_COPY)
            let prepare: @convention(c) (OpaquePointer?, Double, Double, gpointer?) -> OpaquePointer? = { _, _, _, data in
                let name = Box<String>.from(data)
                var value = GValue()
                g_value_init(&value, la_type_string())
                g_value_set_string(&value, name)
                let provider = gdk_content_provider_new_for_value(&value)
                g_value_unset(&value)
                return provider.map { OpaquePointer($0) }
            }
            la_signal_connect(source.raw, "prepare", unsafeBitCast(prepare, to: GCallback.self), Box(item.rawValue).retained, releaseBox, 0)
            button.addController(source)
            if item == .clock {
                observe(widget: button) { [weak self] in
                    guard let self else { return }
                    button.setSensitive(!self.session.project.hasClock)
                    button.setTooltip(self.session.project.hasClock ? "The network has its clock" : "Drag onto the network, or click to add")
                }
            }
            UI.append(box, button)
        }
        gtk_widget_set_size_request(box, 168, -1)
        return box
    }

    private func zoomControls() -> Widget {
        let out = UI.iconButton("zoom-out-symbolic", tooltip: "Zoom out", classes: ["flat"]) { [weak self] in
            guard let self else { return }
            self.setZoom(self.zoom / 1.25)
        }
        let inButton = UI.iconButton("zoom-in-symbolic", tooltip: "Zoom in", classes: ["flat"]) { [weak self] in
            guard let self else { return }
            self.setZoom(self.zoom * 1.25)
        }
        gtk_widget_set_size_request(zoomLabel, 44, -1)
        let fit = UI.iconButton("zoom-fit-best-symbolic", tooltip: "Show the whole network", classes: ["flat"]) { [weak self] in self?.fit() }
        return UI.hbox(spacing: 0, [out, zoomLabel, inButton, UI.separator(GTK_ORIENTATION_VERTICAL), fit], classes: ["canvas-float", "zoom-pill"])
    }

    // MARK: The palette

    enum PaletteItem: String, CaseIterable {
        case a310, a3000, a440, a5000, fileServer, clock

        var title: String {
            switch self {
            case .a310: "A310"
            case .a3000: "A3000"
            case .a440: "A440/1"
            case .a5000: "A5000"
            case .fileServer: "File Server"
            case .clock: "Clock"
            }
        }

        var kind: NetworkNode.Kind {
            switch self {
            case .a310, .a3000, .a440, .a5000: .station
            case .fileServer: .fileServer
            case .clock: .clock
            }
        }

        var model: MachineModel {
            switch self {
            case .a310: .a310
            case .a440, .fileServer: .a440
            case .a5000: .a5000
            case .a3000, .clock: .a3000
            }
        }

        var icon: String {
            switch self {
            case .a3000: "input-keyboard-symbolic"
            case .a310, .a440, .a5000: "computer-symbolic"
            case .fileServer: "network-server-symbolic"
            case .clock: "preferences-system-time-symbolic"
            }
        }
    }

    private func add(_ item: PaletteItem, at point: CanvasPoint) {
        guard let id = session.add(item.kind, model: item.model, at: point) else { return }
        session.selection = [id]
        reveal(point)
    }

    /// Pans to show `point` (a new card) if it's off the canvas.
    private func reveal(_ point: CanvasPoint) {
        let view = viewPoint(point.x, point.y)
        let (width, height) = size
        let margin = 140 * zoom
        guard view.x < margin + 180 || view.x > width - margin || view.y < margin || view.y > height - margin else { return }
        centre = (point.x, (centre.y + point.y) / 2)
        rememberView()
        layout()
    }

    // MARK: Geometry

    private var size: (Double, Double) { (Double(gtk_widget_get_width(area)), Double(gtk_widget_get_height(area))) }

    private func viewPoint(_ x: Double, _ y: Double) -> (x: Double, y: Double) {
        let (width, height) = size
        return ((x - centre.x) * zoom + width / 2, (y - centre.y) * zoom + height / 2)
    }

    private func canvasPoint(_ x: Double, _ y: Double) -> CanvasPoint {
        let (width, height) = size
        return CanvasPoint(x: (x - width / 2) / zoom + centre.x, y: (y - height / 2) / zoom + centre.y)
    }

    private func snapped(_ point: CanvasPoint) -> CanvasPoint {
        guard session.project.canvas.snapToGrid else { return point }
        return CanvasPoint(x: (point.x / Self.grid).rounded() * Self.grid, y: (point.y / Self.grid).rounded() * Self.grid)
    }

    /// Where a node is drawn, in canvas points, allowing for a drag.
    private func position(of node: NetworkNode) -> (x: Double, y: Double) {
        var point = (x: node.position.x, y: node.position.y)
        if let dragging, dragging.ids.contains(node.id) {
            point.x += dragging.dx / zoom
            point.y += dragging.dy / zoom
        }
        return point
    }

    /// Where the room's other machines go: along the end of the stations'
    /// row, after everything of this network's.
    private var remoteLayout: [(station: StationView, x: Double, y: Double)] {
        let remote = session.remoteStations
        guard !remote.isEmpty else { return [] }
        let stations = session.project.nodes.filter { $0.kind == .station }
        let y = stations.isEmpty ? 0 : stations.map(\.position.y).sorted()[stations.count / 2]
        let x = (session.project.nodes.map(\.position.x).max() ?? -NetworkProject.columnSpacing) + NetworkProject.columnSpacing
        return remote.enumerated().map { index, station in (station, x + Double(index) * NetworkProject.columnSpacing, y) }
    }

    /// A card's size, in canvas units (its natural size).
    private func cardSize(_ card: Widget) -> (width: Double, height: Double) {
        var width: Int32 = 0, height: Int32 = 0, ignored: Int32 = 0
        gtk_widget_measure(card, GTK_ORIENTATION_HORIZONTAL, -1, &ignored, &width, nil, nil)
        gtk_widget_measure(card, GTK_ORIENTATION_VERTICAL, width, &ignored, &height, nil, nil)
        return (Double(width), Double(height))
    }

    /// The node under a view point, topmost first.
    private func node(at x: Double, _ y: Double) -> NetworkNode? {
        let p = canvasPoint(x, y)
        for node in session.project.nodes.reversed() {
            guard let card = cards[node.id] else { continue }
            let (width, height) = cardSize(card.widget)
            let centre = position(of: node)
            if abs(p.x - centre.x) <= width / 2 && abs(p.y - centre.y) <= height / 2 { return node }
        }
        return nil
    }

    // MARK: Layout

    /// Places every card (and redraws the bus) for the zoom and centre.
    private func layout() {
        for node in session.project.nodes {
            guard let card = cards[node.id] else { continue }
            place(card.widget, at: position(of: node))
        }
        for item in remoteLayout {
            if let card = remoteCards[item.station.station] { place(card.widget, at: (item.x, item.y)) }
        }
        UI.setText(zoomLabel, "\(Int((zoom * 100).rounded()))%")
        gtk_widget_queue_draw(area)
    }

    private func place(_ card: Widget, at point: (x: Double, y: Double)) {
        let (width, height) = cardSize(card)
        let view = viewPoint(point.x, point.y)
        var origin = graphene_point_t(x: Float(view.x - width * zoom / 2), y: Float(view.y - height * zoom / 2))
        let transform = gsk_transform_scale(gsk_transform_translate(nil, &origin), Float(zoom), Float(zoom))
        gtk_fixed_set_child_transform(board.cast(), card, transform)
        gsk_transform_unref(transform)
    }

    private func observeSession() {
        let session = session
        // The cards: one for each node, and each of the room's other machines.
        observe(self) { [weak self] in
            guard let self else { return }
            let nodes = session.project.nodes
            for id in self.cards.keys where !nodes.contains(where: { $0.id == id }) {
                if let card = self.cards.removeValue(forKey: id) {
                    card.hideScreen()
                    gtk_fixed_remove(self.board.cast(), card.widget)
                }
            }
            for node in nodes {
                if let card = self.cards[node.id], card.kind == (node.kind == .clock ? .clock : .machine) { continue }
                if let old = self.cards.removeValue(forKey: node.id) {
                    old.hideScreen()
                    gtk_fixed_remove(self.board.cast(), old.widget)
                }
                let card = CanvasCard(node: node, session: session)
                self.cards[node.id] = card
                gtk_fixed_put(self.board.cast(), card.widget, 0, 0)
            }
            let remote = self.remoteLayout.map(\.station)
            for (station, card) in self.remoteCards where !remote.contains(where: { $0.station == station }) {
                gtk_fixed_remove(self.board.cast(), card.widget)
                self.remoteCards[station] = nil
            }
            for station in remote {
                let card = self.remoteCards[station.station] ?? {
                    let card = RemoteCard()
                    self.remoteCards[station.station] = card
                    gtk_fixed_put(self.board.cast(), card.widget, 0, 0)
                    return card
                }()
                card.show(station, participant: session.participant(station.participantId),
                          screen: station.online ? session.remoteScreens[station.station] : nil)
            }
            // Selection, state and screens.
            let showsScreens = self.zoom >= 0.35
            for node in nodes {
                self.cards[node.id]?.update(node, selected: session.selection.contains(node.id),
                                            problem: session.project.problems.first { $0.nodes.contains(node.id) }?.message,
                                            showsScreen: showsScreens)
            }
            // Problems, at the top.
            UI.removeAll(self.problemsBox)
            for problem in session.project.problems {
                let icon = UI.image(icon: "dialog-warning-symbolic")
                icon.addClass("warning")
                UI.append(self.problemsBox, UI.hbox(spacing: 6, [icon, UI.label(problem.message)]))
            }
            self.problemsBox.setVisible(!session.project.problems.isEmpty)
            after(0) { [weak self] in self?.layout() }
        }
        // The bus's lights.
        observe(self) { [weak self] in
            guard let self else { return }
            _ = (session.transmitting, session.controllers.count)
            gtk_widget_queue_draw(self.area)
        }
    }

    // MARK: Drawing

    private func draw(_ cr: OpaquePointer, _ width: Double, _ height: Double) {
        var fg = GdkRGBA()
        gtk_widget_get_color(area, &fg)
        let accent = adw_style_manager_get_accent_color_rgba(adw_style_manager_get_default()).map { pointer in
            defer { gdk_rgba_free(pointer) }
            return pointer.pointee
        } ?? GdkRGBA(red: 0.21, green: 0.52, blue: 0.89, alpha: 1)
        func colour(_ c: GdkRGBA, _ alpha: Double) { cairo_set_source_rgba(cr, Double(c.red), Double(c.green), Double(c.blue), alpha * Double(c.alpha)) }

        // A faint dot grid that moves and scales with the canvas.
        let step = Self.grid * 2 * zoom
        if step >= 6 {
            let origin = viewPoint(0, 0)
            let startX = origin.x.truncatingRemainder(dividingBy: step) - step
            let startY = origin.y.truncatingRemainder(dividingBy: step) - step
            let dot = max(1, 1.4 * zoom)
            colour(fg, 0.18)
            var y = startY
            while y < height + step {
                var x = startX
                while x < width + step {
                    cairo_new_sub_path(cr)
                    cairo_arc(cr, x, y, dot / 2, 0, 2 * .pi)
                    x += step
                }
                y += step
            }
            cairo_fill(cr)
        }

        // The shared bus: a backbone between the rows of machines, and a
        // drop from each to it. It's a picture of a shared medium, not of
        // the cabling.
        let nodes = session.project.nodes
        let remote = remoteLayout
        guard nodes.count + remote.count > 1 else { return }
        let points = nodes.map { node in (node: node, point: viewPoint(position(of: node).x, position(of: node).y)) }
        let remotePoints = remote.map { (point: viewPoint($0.x, $0.y), online: $0.station.online) }
        let ys = points.map(\.point.y)
        let busY = ys.isEmpty ? remotePoints[0].point.y : (ys.min()! + ys.max()!) / 2
        let xs = points.map(\.point.x) + remotePoints.map(\.point.x)
        let lineWidth = max(1.5, 3 * zoom)
        cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND)
        cairo_set_line_width(cr, lineWidth)
        colour(fg, 0.4)
        cairo_move_to(cr, xs.min()!, busY)
        cairo_line_to(cr, xs.max()!, busY)
        cairo_stroke(cr)
        let green = GdkRGBA(red: 0.18, green: 0.76, blue: 0.49, alpha: 1)
        let teal = GdkRGBA(red: 0.13, green: 0.63, blue: 0.62, alpha: 1)
        for (node, point) in points {
            let on = session.isOn(node.id) || node.kind == .clock
            let sending = session.transmitting.contains(node.id)
            if sending {
                colour(green, 0.35)
                cairo_set_line_width(cr, lineWidth * 3)
                cairo_move_to(cr, point.x, point.y)
                cairo_line_to(cr, point.x, busY)
                cairo_stroke(cr)
            }
            if sending { colour(green, 1) } else if on { colour(accent, 0.55) } else { colour(fg, 0.3) }
            cairo_set_line_width(cr, lineWidth * 0.8)
            if !on {
                var dash = [4 * zoom, 4 * zoom]
                cairo_set_dash(cr, &dash, 2, 0)
            }
            cairo_move_to(cr, point.x, point.y)
            cairo_line_to(cr, point.x, busY)
            cairo_stroke(cr)
            cairo_set_dash(cr, nil, 0, 0)
            if on { colour(accent, 1) } else { colour(fg, 0.45) }
            cairo_arc(cr, point.x, busY, lineWidth * 1.5, 0, 2 * .pi)
            cairo_fill(cr)
        }
        // Remote machines: through the Internet gateway, drawn apart.
        for (point, online) in remotePoints {
            if online { colour(teal, 0.7) } else { colour(fg, 0.3) }
            cairo_set_line_width(cr, lineWidth * 0.8)
            var dash = [6 * zoom, 3 * zoom]
            cairo_set_dash(cr, &dash, 2, 0)
            cairo_move_to(cr, point.x, point.y)
            cairo_line_to(cr, point.x, busY)
            cairo_stroke(cr)
            cairo_set_dash(cr, nil, 0, 0)
            if online { colour(teal, 1) } else { colour(fg, 0.45) }
            cairo_arc(cr, point.x, busY, lineWidth * 1.5, 0, 2 * .pi)
            cairo_fill(cr)
        }
    }

    // MARK: The pointer

    private var modifiers: GdkModifierType = GdkModifierType(0)

    private func addGestures() {
        // A press selects (Shift or Ctrl adds to the selection); a double
        // click opens a machine's window.
        let click = gtk_gesture_click_new()!
        onClick(click, "pressed") { [weak self] presses, x, y in
            guard let self else { return }
            gtk_widget_grab_focus(self.area)
            let state = gtk_event_controller_get_current_event_state(click.opaque)
            let toggling = state.rawValue & (GDK_SHIFT_MASK.rawValue | GDK_CONTROL_MASK.rawValue) != 0
            guard let node = self.node(at: x, y) else {
                if !toggling { self.session.selection = [] }
                return
            }
            if presses == 2, node.isMachine {
                if !self.session.isOn(node.id) { self.session.powerOn(node.id) }
                self.studio?.openStation(node.id)
                return
            }
            if toggling {
                if self.session.selection.contains(node.id) { self.session.selection.remove(node.id) } else { self.session.selection.insert(node.id) }
            } else if !self.session.selection.contains(node.id) || presses == 1 && self.session.selection.count == 1 {
                self.session.selection = [node.id]
            }
            if node.isMachine, self.session.isOn(node.id) { self.session.focus(node.id) }
        }
        area.addController(click)

        // Dragging a card moves it (and the others selected with it);
        // dragging the background pans.
        let drag = gtk_gesture_drag_new()!
        onPoint(drag, "drag-begin") { [weak self] x, y in
            guard let self else { return }
            if let node = self.node(at: x, y) {
                self.pressedNode = node.id
                if !self.session.selection.contains(node.id) { self.session.selection = [node.id] }
            } else {
                self.pressedNode = nil
                self.panStart = self.centre
            }
        }
        onPoint(drag, "drag-update") { [weak self] dx, dy in
            guard let self else { return }
            if self.pressedNode != nil {
                guard self.dragging != nil || abs(dx) + abs(dy) > 3 else { return }
                self.dragging = (self.session.selection, dx, dy)
            } else if let start = self.panStart {
                self.centre = (start.x - dx / self.zoom, start.y - dy / self.zoom)
            }
            self.layout()
        }
        onPoint(drag, "drag-end") { [weak self] _, _ in
            guard let self else { return }
            if let dragging = self.dragging {
                for id in dragging.ids {
                    if let node = self.session.node(id) {
                        let moved = self.position(of: node)
                        self.session.move(id, to: self.snapped(CanvasPoint(x: moved.x, y: moved.y)))
                    }
                }
                self.dragging = nil
            } else if self.panStart != nil {
                self.rememberView()
            }
            self.panStart = nil
            self.pressedNode = nil
            self.layout()
        }
        area.addController(drag)

        // A right click: the node's menu.
        let secondary = gtk_gesture_click_new()!
        gtk_gesture_single_set_button(secondary.cast(), 3)
        onClick(secondary, "pressed") { [weak self] _, x, y in
            guard let self, let node = self.node(at: x, y) else { return }
            if !self.session.selection.contains(node.id) { self.session.selection = [node.id] }
            self.showMenu(node, x: x, y: y)
        }
        area.addController(secondary)

        // Scrolling pans; with Ctrl it zooms, about the pointer.
        let scroll = gtk_event_controller_scroll_new(GtkEventControllerScrollFlags(rawValue: GTK_EVENT_CONTROLLER_SCROLL_BOTH_AXES.rawValue))!
        let motion = gtk_event_controller_motion_new()!
        var pointer = (x: 0.0, y: 0.0)
        onPoint(motion, "motion") { x, y in pointer = (x, y) }
        area.addController(motion)
        let scrolled: @convention(c) (gpointer?, Double, Double, gpointer?) -> gboolean = { controller, dx, dy, data in
            let view = Unmanaged<NetworkCanvasView>.fromOpaque(data!).takeUnretainedValue()
            let state = gtk_event_controller_get_current_event_state(OpaquePointer(controller))
            MainActor.assumeIsolated { view.scrolled(dx, dy, zooming: state.rawValue & GDK_CONTROL_MASK.rawValue != 0) }
            return 1
        }
        la_signal_connect(scroll.raw, "scroll", unsafeBitCast(scrolled, to: GCallback.self), Unmanaged.passUnretained(self).toOpaque(), nil, 0)
        area.addController(scroll)
        scrollPointer = { pointer }

        // A pinch zooms.
        let pinch = gtk_gesture_zoom_new()!
        let changed: @convention(c) (gpointer?, Double, gpointer?) -> Void = { _, scale, data in
            let view = Unmanaged<NetworkCanvasView>.fromOpaque(data!).takeUnretainedValue()
            MainActor.assumeIsolated {
                if view.zoomStart == nil { view.zoomStart = view.zoom }
                view.zoom = (view.zoomStart! * scale).clamped(to: NetworkCanvasView.zoomRange)
                view.layout()
            }
        }
        la_signal_connect(pinch.raw, "scale-changed", unsafeBitCast(changed, to: GCallback.self), Unmanaged.passUnretained(self).toOpaque(), nil, 0)
        onSignal(pinch, "end") { [weak self] in
            self?.zoomStart = nil
            self?.rememberView()
        }
        area.addController(pinch)

        // Delete removes what's selected.
        let keys = gtk_event_controller_key_new()!
        onKey(keys, "key-pressed") { [weak self] keyval, _, _ in
            guard let self, keyval == UInt32(GDK_KEY_Delete) || keyval == UInt32(GDK_KEY_BackSpace), !self.session.selection.isEmpty else { return false }
            self.confirmRemove(self.session.selection)
            return true
        }
        area.addController(keys)

        // A palette item dropped on the canvas: added there, unless that's
        // on another card.
        let drop = gtk_drop_target_new(la_type_string(), GDK_ACTION_COPY)!
        let dropped: @convention(c) (gpointer?, UnsafePointer<GValue>?, Double, Double, gpointer?) -> gboolean = { _, value, x, y, data in
            let view = Unmanaged<NetworkCanvasView>.fromOpaque(data!).takeUnretainedValue()
            guard let value, let text = String(gBorrowed: g_value_get_string(value)), let item = PaletteItem(rawValue: text) else { return 0 }
            MainActor.assumeIsolated {
                view.add(item, at: view.session.project.freePosition(near: view.snapped(view.canvasPoint(x, y))))
            }
            return 1
        }
        la_signal_connect(drop.raw, "drop", unsafeBitCast(dropped, to: GCallback.self), Unmanaged.passUnretained(self).toOpaque(), nil, 0)
        area.addController(drop)
    }

    private var scrollPointer: () -> (x: Double, y: Double) = { (0, 0) }

    private func scrolled(_ dx: Double, _ dy: Double, zooming: Bool) {
        if zooming {
            // Keep the point under the pointer where it is.
            let pointer = scrollPointer()
            let before = canvasPoint(pointer.x, pointer.y)
            zoom = (zoom * (1 - dy / 10)).clamped(to: Self.zoomRange)
            let after = canvasPoint(pointer.x, pointer.y)
            centre.x += before.x - after.x
            centre.y += before.y - after.y
        } else {
            centre.x += dx * 20 / zoom
            centre.y += dy * 20 / zoom
        }
        rememberView()
        layout()
    }

    private func setZoom(_ value: Double) {
        zoom = value.clamped(to: Self.zoomRange)
        rememberView()
        layout()
    }

    /// Zooms and centres to show every node, and the room's other machines.
    func fit() {
        let points = session.project.nodes.map { ($0.position.x, $0.position.y) } + remoteLayout.map { ($0.x, $0.y) }
        guard !points.isEmpty else { return }
        let xs = points.map(\.0), ys = points.map(\.1)
        let width = (xs.max()! - xs.min()!) + NetworkProject.cardSize.x + 80
        let height = (ys.max()! - ys.min()!) + NetworkProject.cardSize.y + 80
        // Clear of the palette, on the left.
        let palette = 200.0
        let (viewWidth, viewHeight) = size
        guard viewWidth > 0, viewHeight > 0 else {
            after(0.1) { [weak self] in self?.fit() }
            return
        }
        let fitted = min((viewWidth - palette) / width, viewHeight / height, 1.5).clamped(to: Self.zoomRange)
        zoom = fitted
        centre = ((xs.max()! + xs.min()!) / 2 - palette / 2 / fitted, (ys.max()! + ys.min()!) / 2)
        rememberView()
        layout()
    }

    private func rememberView() {
        let zoom = zoom, centre = centre
        session.update {
            $0.canvas.zoom = zoom
            $0.canvas.centre = CanvasPoint(x: centre.x, y: centre.y)
        }
    }

    // MARK: The node's menu

    private func addActions() {
        let session = session
        func node(_ id: String) -> UUID? { UUID(uuidString: id) }
        actions.add("power", string: { id in node(id).map { session.togglePower($0) } })
        actions.add("power-cycle", string: { id in node(id).map { session.coldBoot($0) } })
        actions.add("reset", string: { id in node(id).map { session.reset($0) } })
        actions.add("suspend", string: { id in node(id).map { session.setSuspended($0, !session.isSuspended($0)) } })
        actions.add("open", string: { [weak self] id in
            guard let id = node(id) else { return }
            if !session.isOn(id) { session.powerOn(id) }
            self?.studio?.openStation(id)
        })
        actions.add("debugger", string: { [weak self] id in node(id).map { self?.studio?.openDebugger($0) } })
        actions.add("configure", string: { [weak self] id in node(id).map { self?.studio?.openConfigure($0) } })
        actions.add("insert-disc", string: { [weak self] id in node(id).map { session.chooseDisc(for: $0, parent: self?.studio?.window) } })
        actions.add("eject", string: { id in node(id).map { session.eject($0) } })
        actions.add("level4", string: { [weak self] id in node(id).map { session.setUpLevel4($0, parent: self?.studio?.window) } })
        actions.add("duplicate", string: { id in node(id).map { session.duplicate($0) } })
        actions.add("remove", string: { [weak self] id in
            guard let self, let id = node(id) else { return }
            self.confirmRemove(session.selection.contains(id) ? session.selection : [id])
        })
    }

    private func showMenu(_ node: NetworkNode, x: Double, y: Double) {
        let id = node.id.uuidString
        let menu = Menu()
        if node.isMachine {
            let on = session.isOn(node.id)
            menu.section { section in
                section.item(on ? "Power Off" : "Power On", "canvas.power", string: id)
                section.item("Power Cycle", "canvas.power-cycle", string: id)
                if on {
                    section.item("Reset", "canvas.reset", string: id)
                    section.item(session.isSuspended(node.id) ? "Resume Station" : "Suspend Station", "canvas.suspend", string: id)
                }
            }
            menu.section { section in
                section.item("Open Window", "canvas.open", string: id)
                if on {
                    section.item("Show Debugger", "canvas.debugger", string: id)
                    section.item("Configure Machine…", "canvas.configure", string: id)
                }
                section.item("Insert Disc…", "canvas.insert-disc", string: id)
                if node.discs[0] != nil { section.item("Eject Disc", "canvas.eject", string: id) }
                if node.kind == .fileServer {
                    section.item(node.runsLevel4 == true ? "Set Up Level 4 Again" : "Set Up Level 4 File Server", "canvas.level4", string: id)
                }
            }
            menu.section { $0.item("Duplicate", "canvas.duplicate", string: id) }
        }
        menu.section { $0.item("Remove…", "canvas.remove", string: id) }
        let popover = gtk_popover_menu_new_from_model(menu.model)!
        gtk_widget_set_parent(popover, area)
        var point = GdkRectangle(x: Int32(x), y: Int32(y), width: 1, height: 1)
        gtk_popover_set_pointing_to(popover.cast(), &point)
        gtk_popover_set_has_arrow(popover.cast(), 0)
        gtk_widget_set_halign(popover, GTK_ALIGN_START)
        onSignal(popover, "closed") { after(0) { gtk_widget_unparent(popover) } }
        gtk_popover_popup(popover.cast())
    }

    private func confirmRemove(_ ids: Set<UUID>) {
        let title = ids.count == 1 ? "Remove “\(session.node(ids.first!)?.name ?? "")” from the network?" : "Remove \(ids.count) items from the network?"
        Task {
            guard await Alerts.confirm(title, "Machines that are on are switched off, and their discs’ copies in the network are deleted.",
                                       button: "Remove", destructive: true, parent: studio?.window) else { return }
            session.remove(ids)
        }
    }
}

// MARK: Cards

/// A machine (or the clock) on the canvas: its screen, live, and who it is.
@MainActor
final class CanvasCard {
    enum Kind { case machine, clock }

    let kind: Kind
    let widget: Widget
    private let id: UUID
    private let session: NetworkSession
    private let picture: Widget
    private let offBox: Widget
    private let offIcon: Widget
    private let offLabel: Widget
    private let serverBadge: Widget
    private let badge: Widget
    private let name: Widget
    private let subtitle: Widget
    private let sending: Widget
    private let state: Widget
    private let console: Widget
    private var showingHost: EmulatorHost?

    static let width: Int32 = 236

    init(node: NetworkNode, session: NetworkSession) {
        id = node.id
        self.session = session
        kind = node.kind == .clock ? .clock : .machine
        picture = gtk_picture_new()!
        offIcon = UI.image(icon: "system-shutdown-symbolic", size: 24)
        offLabel = UI.label("Off", classes: ["caption"], wrap: true, xalign: 0.5)
        offBox = UI.vbox(spacing: 4, [offIcon, offLabel], classes: ["card-off"])
        serverBadge = UI.label("FILE SERVER", classes: ["server-badge"])
        badge = UI.label("–", classes: ["station-badge"], xalign: 0.5)
        name = UI.label("", classes: ["heading"])
        subtitle = UI.label("", classes: ["caption", "dim-label"])
        sending = UI.image(icon: "network-transmit-symbolic")
        state = UI.label("●", classes: ["state-dot"])
        console = UI.label("", classes: ["code-small", "dim-label"])
        if kind == .clock {
            let icon = UI.image(icon: "preferences-system-time-symbolic", size: 26)
            icon.addClass("clock-icon")
            icon.align(horizontal: GTK_ALIGN_CENTER)
            widget = UI.vbox(spacing: 6, [icon, UI.label("Clock", classes: ["heading"], xalign: 0.5), subtitle], classes: ["canvas-card", "clock-card"])
            gtk_widget_set_size_request(widget, 130, -1)
            subtitle.align(horizontal: GTK_ALIGN_CENTER)
            return
        }
        gtk_picture_set_content_fit(picture.cast(), GTK_CONTENT_FIT_FILL)
        gtk_picture_set_can_shrink(picture.cast(), 1)
        let screen = gtk_overlay_new()!
        let black = UI.box(GTK_ORIENTATION_VERTICAL, classes: ["card-screen"])
        gtk_widget_set_size_request(black, Self.width - 20, Int32(Double(Self.width - 20) / NetworkCanvasView.screenAspect))
        gtk_overlay_set_child(screen.cast(), black)
        gtk_overlay_add_overlay(screen.cast(), picture)
        offBox.align(horizontal: GTK_ALIGN_CENTER, vertical: GTK_ALIGN_CENTER)
        gtk_overlay_add_overlay(screen.cast(), offBox)
        serverBadge.align(horizontal: GTK_ALIGN_END, vertical: GTK_ALIGN_END)
        serverBadge.setMargins(6)
        gtk_overlay_add_overlay(screen.cast(), serverBadge)
        gtk_widget_set_overflow(screen, GTK_OVERFLOW_HIDDEN)
        screen.addClass("card-screen-frame")
        gtk_label_set_ellipsize(name.cast(), PANGO_ELLIPSIZE_END)
        gtk_label_set_ellipsize(subtitle.cast(), PANGO_ELLIPSIZE_END)
        gtk_label_set_ellipsize(console.cast(), PANGO_ELLIPSIZE_END)
        gtk_label_set_max_width_chars(name.cast(), 1)
        gtk_label_set_max_width_chars(subtitle.cast(), 1)
        gtk_label_set_max_width_chars(console.cast(), 1)
        let text = UI.vbox(spacing: 1, [name, subtitle])
        text.expand(horizontally: true)
        badge.align(vertical: GTK_ALIGN_CENTER)
        sending.addClass("sending")
        let row = UI.hbox(spacing: 8, [badge, text, sending, state])
        widget = UI.vbox(spacing: 8, [screen, row, console], classes: ["canvas-card"])
        gtk_widget_set_size_request(widget, Self.width, -1)
        observe(widget: picture) { [weak self] in
            guard let self, let texture = session.thumbnails.images[self.id] else { return }
            gtk_picture_set_paintable(self.picture.cast(), texture)
        }
    }

    /// Shows what the node is now.
    func update(_ node: NetworkNode, selected: Bool, problem: String?, showsScreen: Bool) {
        widget.setClass("selected", selected)
        widget.setClass("problem", problem != nil && !selected)
        if kind == .clock {
            UI.setText(subtitle, ClockText.rate(node.clockRate ?? EconetTime.defaultClockRate))
            widget.setTooltip("The network’s clock: every Econet needs one")
            return
        }
        let controller = session.controllers[node.id]
        UI.setText(badge, node.stationNumber.map(String.init) ?? "–")
        badge.setClass("problem", problem != nil)
        UI.setText(name, node.name)
        let model = node.setup?.summary ?? ""
        UI.setText(subtitle, node.kind == .station ? model : "\(node.kind.displayName) · \(model)")
        sending.setVisible(session.transmitting.contains(node.id))
        sending.setTooltip("Sending on the network")
        let (text, colour) = Self.state(controller, session: session)
        UI.setText(state, controller == nil ? "○" : "●")
        for name in ["on", "off", "suspended", "paused", "debugger"] { state.setClass(name, name == colour) }
        state.setTooltip(text)
        serverBadge.setVisible(node.kind == .fileServer)
        console.setVisible(node.kind == .fileServer && controller != nil)
        UI.setText(console, controller?.consoleLine ?? "Starting…")
        console.setTooltip("The server’s console: its last line")
        // The screen, live, while it's on (and big enough to see).
        if let host = controller?.host, showsScreen {
            if showingHost !== host {
                hideScreen()
                session.thumbnails.show(node.id, host: host)
                showingHost = host
            }
            picture.setVisible(true)
            offBox.setVisible(false)
        } else {
            hideScreen()
            picture.setVisible(false)
            let waiting = session.waitingForServer.contains(node.id)
            offBox.setVisible(controller == nil)
            gtk_image_set_from_icon_name(offIcon.cast(), waiting ? "content-loading-symbolic" : "system-shutdown-symbolic")
            UI.setText(offLabel, waiting ? "Waiting for the file server" : "Off")
        }
        widget.setTooltip(problem ?? "\(node.name): double-click to open its window")
    }

    func hideScreen() {
        if showingHost != nil {
            session.thumbnails.hide(id)
            showingHost = nil
        }
    }

    /// On, off, suspended, paused, stopped.
    static func state(_ controller: MachineController?, session: NetworkSession) -> (String, String) {
        guard let controller else { return ("Off", "off") }
        if controller.debugStop != nil { return ("Stopped in the debugger", "debugger") }
        if session.paused { return ("Paused", "paused") }
        if controller.paused { return ("Suspended", "suspended") }
        return ("On", "on")
    }
}

/// A machine in the network's Internet room, on someone else's computer (an
/// Archimedes in MacArch or LinuxArch, or a BBC Micro in MacBeeb): who it is
/// and whose, whether it's online, and how far away.
@MainActor
final class RemoteCard {
    let widget: Widget
    private let picture: Widget
    private let icon: Widget
    private let rtt: Widget
    private let online: Widget
    private let badge: Widget
    private let name: Widget
    private let kind: Widget
    private let family: Widget

    init() {
        picture = gtk_picture_new()!
        gtk_picture_set_content_fit(picture.cast(), GTK_CONTENT_FIT_FILL)
        gtk_widget_set_size_request(picture, CanvasCard.width - 24, Int32(Double(CanvasCard.width - 24) / NetworkCanvasView.screenAspect))
        picture.addClass("card-screen")
        icon = UI.image(icon: "computer-symbolic", size: 24)
        rtt = UI.label("", classes: ["caption", "numeric", "dim-label"])
        online = UI.label("", classes: ["online-pill", "caption-heading"])
        let top = UI.hbox(spacing: 6, [icon, UI.image(icon: "network-wireless-symbolic"), UI.spacer(), rtt, online])
        badge = UI.label("", classes: ["station-badge"], xalign: 0.5)
        badge.align(vertical: GTK_ALIGN_CENTER)
        name = UI.label("", classes: ["heading"])
        kind = UI.label("", classes: ["caption", "dim-label"])
        family = UI.label("", classes: ["caption", "dim-label"])
        for label in [name, kind, family] {
            gtk_label_set_ellipsize(label.cast(), PANGO_ELLIPSIZE_END)
            gtk_label_set_max_width_chars(label.cast(), 1)
        }
        let text = UI.vbox(spacing: 1, [name, kind, family])
        text.expand(horizontally: true)
        widget = UI.vbox(spacing: 8, [picture, top, UI.hbox(spacing: 8, [badge, text])], classes: ["canvas-card", "remote-card"])
        gtk_widget_set_size_request(widget, CanvasCard.width, 160)
    }

    func show(_ station: StationView, participant: ParticipantView?, screen: OpaquePointer?) {
        let app: String = switch participant?.app {
        case "MacBeeb": "BBC Micro, in MacBeeb"
        case "MacArch": "Archimedes, in MacArch"
        case let app?: "in \(app)"
        case nil: "on another computer"
        }
        gtk_image_set_from_icon_name(icon.cast(), participant?.app == "MacBeeb" ? "input-keyboard-symbolic" : "computer-symbolic")
        picture.setVisible(screen != nil)
        if let screen { gtk_picture_set_paintable(picture.cast(), screen) }
        UI.setText(rtt, participant?.rttMs.map { station.online ? "\($0) ms" : "" } ?? "")
        UI.setText(online, station.online ? "Online" : "Offline")
        online.setClass("on", station.online)
        widget.setClass("offline", !station.online)
        UI.setText(badge, "\(station.station)")
        UI.setText(name, station.label)
        UI.setText(kind, "\(station.kind) · \(participant?.name ?? "someone else")")
        UI.setText(family, app)
        widget.setTooltip("Station \(station.station), \(station.label): a \(station.kind) on \(participant?.name ?? "another person")’s computer, in this network’s Internet room")
    }
}

enum ClockText {
    static func rate(_ rate: Int) -> String { "\(rate / 1000) kbit/s" }
}

extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
