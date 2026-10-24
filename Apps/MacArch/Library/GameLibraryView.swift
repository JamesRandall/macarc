import AppKit
import ArchimedesCore
import SwiftUI
import UniformTypeIdentifiers

/// The Game Library: the user's own games (My Games), as covers on a shelf,
/// with a game's details beside them. (MacBeeb's bookshelf, with only its
/// My Games shelf: there's no Archimedes archive like BBCMicro.co.uk to
/// link to.) Drop disc images and cover pictures on it to add games.
struct GameLibraryView: View {
    static let windowID = "game-library"
    static let title = "Game Library"

    @State private var library = GameLibrary.shared
    @State private var selection: UUID?
    @State private var showingDetail = false
    @State private var columns = 4
    @FocusState private var gridFocused: Bool
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let tileWidth: CGFloat = 168
    private static let detailWidth: CGFloat = 320
    static let spacing: CGFloat = 28

    var body: some View {
        ScrollViewReader { scroller in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    ShelfLayout(tileWidth: Self.tileWidth, spacing: Self.spacing) {
                        ForEach(library.personalGames) { game in
                            PersonalTile(game: game, selected: selection == game.id)
                                .id(game.id)
                                .onTapGesture {
                                    select(game.id)
                                    gridFocused = true
                                }
                                .simultaneousGesture(TapGesture(count: 2).onEnded {
                                    if game.discFile != nil { Player.play(game) { openMachine() } }
                                })
                                .accessibilityAction { select(game.id) }
                                .contextMenu {
                                    Button("Play") { Player.play(game) { openMachine() } }
                                        .disabled(game.discFile == nil)
                                    Divider()
                                    Button("Edit…") { library.edit(game) }
                                    Button(game.discFile == nil ? "Choose Disc…" : "Replace Disc…") { library.chooseDisc(for: game) }
                                    Button(game.coverFile == nil ? "Add Cover…" : "Change Cover…") { library.chooseCover(for: game) }
                                    Divider()
                                    Button("Remove…") { library.remove(game) }
                                }
                        }
                        AddGameTile()
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                        columns = ShelfLayout.columns(in: width, tileWidth: Self.tileWidth, spacing: Self.spacing)
                    }
                    .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: columns)
                    .focusable()
                    .focusEffectDisabled()
                    .focused($gridFocused)
                    .onMoveCommand { direction in
                        move(direction)
                        if let selection { withAnimation(reduceMotion ? nil : .default) { scroller.scrollTo(selection) } }
                    }
                    .onKeyPress(.return) {
                        guard let game = selectedGame, game.discFile != nil else { return .ignored }
                        Player.play(game) { openMachine() }
                        return .handled
                    }
                    .onKeyPress(.escape) {
                        guard showingDetail else { return .ignored }
                        showingDetail = false
                        return .handled
                    }
                    if library.personalGames.isEmpty {
                        emptyHelp
                    }
                }
                .padding(24)
            }
        }
        .background(.background)
        .inspector(isPresented: $showingDetail) {
            Group {
                if let game = selectedGame {
                    PersonalGameDetail(game: game) { openMachine() }
                } else {
                    ContentUnavailableView("No Game Selected", systemImage: "square.stack", description: Text("Choose a game to see its details."))
                }
            }
            .inspectorColumnWidth(Self.detailWidth)
        }
        .dropDestination(for: URL.self) { urls, _ in
            let wanted = urls.filter { MyGames.isDiscName($0) || MyGames.isCoverName($0) }
            library.addFiles(wanted)
            return !wanted.isEmpty
        }
        .sheet(item: Binding(get: { library.drafts.first },
                             set: { if $0 == nil, let draft = library.drafts.first { library.cancel(draft) } })) { draft in
            GameDetailsSheet(draft: draft)
        }
        .navigationTitle(Self.title)
        .navigationSubtitle("My Games")
        .onAppear { gridFocused = true }
        .toolbar {
            ToolbarItem {
                Button { openMachine() } label: { Label("Archimedes", systemImage: "desktopcomputer") }
                    .help("Open an Archimedes window, to use without a game from the shelf")
            }
            ToolbarItem {
                Button { library.chooseFiles() } label: { Label("Add Games…", systemImage: "plus") }
                    .help("Add floppy disc images and cover pictures as your own games")
            }
            ToolbarItem {
                Button { showingDetail.toggle() } label: { Label("Details", systemImage: "sidebar.right") }
                    .help("Show or hide the details of the selected game")
            }
        }
    }

    private var selectedGame: PersonalGame? { selection.flatMap { library.game(id: $0) } }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("My Games")
                    .font(.largeTitle.weight(.semibold))
                Text("Your Archimedes games, ready to play. Drag in floppy disc images and cover pictures, in either order or together.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            Spacer()
            Button("Add Games…") { library.chooseFiles() }
        }
    }

    private var emptyHelp: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            Text("Each game keeps its own copy of its disc, the machine it plays on (an A3000 with RISC OS 3, say, or RISC OS 2 for older games) and how it starts: from the disc’s !Boot, with a command at the command line, or with the disc just put in for you to open. Double-click a game to play it.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 8)
    }

    private func select(_ id: UUID) {
        selection = id
        showingDetail = true
    }

    private func move(_ direction: MoveCommandDirection) {
        let ids = library.personalGames.map(\.id)
        guard !ids.isEmpty else { return }
        let current = selection.flatMap(ids.firstIndex(of:))
        let step = switch direction {
        case .left: -1
        case .right: 1
        case .up: -columns
        case .down: columns
        @unknown default: 0
        }
        selection = ids[current.map { min(max($0 + step, 0), ids.count - 1) } ?? 0]
    }

    private func openMachine() {
        openWindow(id: MachineWindow.windowID)
    }
}

/// The shelf: as many columns of same-sized tiles as fit, from the left,
/// each row's tiles sitting on its bottom. (MacBeeb's.)
struct ShelfLayout: Layout {
    let tileWidth: CGFloat
    let spacing: CGFloat

    static func columns(in width: CGFloat, tileWidth: CGFloat, spacing: CGFloat) -> Int {
        guard width.isFinite, width > 0 else { return 1 }
        return max(1, Int((width + spacing) / (tileWidth + spacing)))
    }

    private func rows(_ width: CGFloat, _ subviews: Subviews) -> [(range: Range<Int>, height: CGFloat)] {
        let columns = Self.columns(in: width, tileWidth: tileWidth, spacing: spacing)
        return stride(from: 0, to: subviews.count, by: columns).map { start in
            let range = start..<min(start + columns, subviews.count)
            let height = range.map { subviews[$0].sizeThatFits(.init(width: tileWidth, height: nil)).height }.max() ?? 0
            return (range, height)
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? (tileWidth + spacing) * 4
        let rows = rows(width, subviews)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(bounds.width, subviews) {
            for (column, index) in row.range.enumerated() {
                let size = subviews[index].sizeThatFits(.init(width: tileWidth, height: nil))
                subviews[index].place(at: CGPoint(x: bounds.minX + CGFloat(column) * (tileWidth + spacing), y: y + row.height - size.height),
                                      proposal: .init(width: tileWidth, height: size.height))
            }
            y += row.height + spacing
        }
    }
}

extension View {
    /// Old box scans are faded and flat: a little more colour and contrast
    /// makes them stand out on the shelf.
    func coverPop() -> some View {
        saturation(1.2).contrast(1.1)
    }
}

/// One of My Games on the shelf. Dropping a disc or picture on it gives it
/// that disc or cover.
struct PersonalTile: View {
    let game: PersonalGame
    let selected: Bool
    @State private var library = GameLibrary.shared
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 8) {
            PersonalCover(game: game)
                .frame(height: 210, alignment: .bottom)
                .frame(maxWidth: .infinity)
                .shadow(color: .black.opacity(0.35), radius: 6, y: 4)
            VStack(spacing: 2) {
                Text(game.title)
                    .font(.headline)
                    .lineLimit(1)
                Group {
                    if game.discFile == nil {
                        Label("No disc yet: drop one here", systemImage: "opticaldisc")
                            .foregroundStyle(.secondary)
                    } else {
                        Label("Ready to play", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
                .font(.caption)
                .lineLimit(1)
            }
        }
        .padding(8)
        .background(background, in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .dropDestination(for: URL.self) { urls, _ in
            library.attach(urls, to: game)
        } isTargeted: { targeted = $0 }
        .help(game.discFile == nil ? "\(game.title): drop its disc image here" : "\(game.title): double-click to play; drop a picture here for its cover")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(game.title), my game. \(game.discFile == nil ? "No disc yet." : "Ready to play.")")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private var background: AnyShapeStyle {
        if targeted { return AnyShapeStyle(Color.accentColor.opacity(0.3)) }
        return selected ? AnyShapeStyle(.selection.opacity(0.35)) : AnyShapeStyle(.clear)
    }
}

/// A game's own cover, or its title on a plain cover until it has one.
struct PersonalCover: View {
    let game: PersonalGame
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .coverPop()
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(LinearGradient(colors: [Color(red: 0.14, green: 0.12, blue: 0.22), Color(red: 0.06, green: 0.05, blue: 0.11)],
                                             startPoint: .top, endPoint: .bottom))
                    // The Archimedes' function keys, as a band.
                    VStack(spacing: 3) {
                        ForEach(0..<3) { _ in
                            Rectangle().fill(Color(red: 0.86, green: 0.36, blue: 0.16)).frame(height: 3)
                        }
                    }
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, 18)
                    VStack(spacing: 8) {
                        Text(game.title.uppercased())
                            .font(.system(.title3, design: .rounded).weight(.bold))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(Color(red: 1, green: 0.85, blue: 0.45))
                        if let publisher = game.publisher {
                            Text(publisher).font(.caption).foregroundStyle(.white.opacity(0.7))
                        }
                        Text("Drop a cover here")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    .padding(10)
                }
                .aspectRatio(0.7, contentMode: .fit)
            }
        }
        .accessibilityHidden(true)
        .task(id: game.coverFile) {
            guard let url = GameLibrary.shared.myGames.coverURL(game) else {
                image = nil
                return
            }
            image = await Task.detached { NSImage(contentsOf: url) }.value
        }
    }
}

/// The empty box at the end of the shelf: drop discs and pictures on it, or
/// click it to choose them.
struct AddGameTile: View {
    @State private var library = GameLibrary.shared
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .foregroundStyle(targeted ? Color.accentColor : .secondary.opacity(0.6))
                VStack(spacing: 8) {
                    Image(systemName: "plus").font(.largeTitle)
                    Text("Drop disc images or cover pictures here")
                        .font(.caption)
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.secondary)
                .padding(12)
            }
            .aspectRatio(0.7, contentMode: .fit)
            .frame(height: 210)
            Text("Add a Game").font(.headline)
            Text(" ").font(.caption)
        }
        .padding(8)
        .contentShape(Rectangle())
        .onTapGesture { library.chooseFiles() }
        .dropDestination(for: URL.self) { urls, _ in
            let wanted = urls.filter { MyGames.isDiscName($0) || MyGames.isCoverName($0) }
            library.addFiles(wanted)
            return !wanted.isEmpty
        } isTargeted: { targeted = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Add a game: choose disc images and cover pictures")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { library.chooseFiles() }
    }
}

/// One of My Games in the details panel.
struct PersonalGameDetail: View {
    let game: PersonalGame
    let openMachine: () -> Void
    @State private var library = GameLibrary.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                PersonalCover(game: game)
                    .frame(maxHeight: 260)
                    .frame(maxWidth: .infinity)
                    .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
                    .dropDestination(for: URL.self) { urls, _ in library.attach(urls, to: game) }
                VStack(alignment: .leading, spacing: 4) {
                    Text(game.title).font(.title2.weight(.semibold))
                    let byline = [game.publisher, game.year.map(String.init)].compactMap { $0 }.joined(separator: ", ")
                    if !byline.isEmpty { Text(byline).foregroundStyle(.secondary) }
                    Text("My game").font(.callout).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                if game.discFile != nil {
                    Button {
                        Player.play(game, openMachine: openMachine)
                    } label: {
                        Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                } else {
                    Text("Add the game’s disc image to play it: drop it on the game, or choose it.")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        library.chooseDisc(for: game)
                    } label: {
                        Text("Choose Disc…").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                HStack {
                    Button("Edit…") { library.edit(game) }
                    if game.discFile != nil { Button("Replace Disc…") { library.chooseDisc(for: game) } }
                    Button(game.coverFile == nil ? "Add Cover…" : "Change Cover…") { library.chooseCover(for: game) }
                }
                .buttonStyle(.link)
                HStack {
                    if let url = library.myGames.discURL(game) {
                        Button("Reveal Disc") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    }
                    Button("Remove…") { library.remove(game) }
                }
                .buttonStyle(.link)
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                    GridRow {
                        Text("Plays on").foregroundStyle(.secondary)
                        Text(game.machineSummary)
                    }
                    GridRow {
                        Text("Starts by").foregroundStyle(.secondary)
                        switch game.start {
                        case .boot: Text("Running the disc’s !Boot")
                        case .application(let name): Text("Starting \(name)")
                        case .insertOnly: Text("Putting the disc in")
                        case .type(let command):
                            Text(command.isEmpty ? "Putting the disc in" : command)
                                .font(.system(.callout, design: .monospaced))
                        }
                    }
                }
                .font(.callout)
                if let notes = game.notes {
                    Text(notes).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
        }
    }
}

/// The details of a game being added or edited: what it's called, its disc
/// and cover, the machine it plays on, and how it starts.
struct GameDetailsSheet: View {
    @State var draft: GameDraft
    @State private var library = GameLibrary.shared
    @State private var saving = false
    @State private var yearText = ""
    @State private var command = ""
    @State private var startChoice = StartChoice.insertOnly
    @Environment(\.dismiss) private var dismiss

    enum StartChoice: Hashable { case application, boot, type, insertOnly }
    @State private var application = ""
    /// The disc's applications, to choose one to start.
    @State private var applications: [String] = []

    /// RISC OS versions a game can ask for: the families, matched against
    /// the ROMs the user has.
    static let romChoices = ["RISC OS 2", "RISC OS 3"]

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    HStack(alignment: .top, spacing: 16) {
                        coverWell
                        VStack(alignment: .leading, spacing: 8) {
                            TextField("Title", text: $draft.game.title, prompt: Text("Required"))
                            TextField("Publisher", text: optional(\.publisher), prompt: Text("Optional"))
                            TextField("Year", text: $yearText, prompt: Text("Optional"))
                        }
                    }
                }
                Section("Disc") { discRow }
                Section("Machine") {
                    Picker("Model", selection: $draft.game.model) {
                        ForEach(MachineModel.allCases, id: \.self) { model in
                            Text(model.displayName).tag(model)
                        }
                    }
                    Picker("Memory", selection: $draft.game.ramKB) {
                        Text("As the model usually has").tag(Int?.none)
                        ForEach(draft.game.model.ramChoices, id: \.self) { kb in
                            Text(AppSettings.ramLabel(kb)).tag(Int?.some(kb))
                        }
                    }
                    Picker("RISC OS", selection: $draft.game.rom) {
                        Text("As chosen in Settings").tag(String?.none)
                        ForEach(Self.romChoices, id: \.self) { family in
                            let have = AppSettings.shared.romLibrary.contains { $0.version.hasPrefix(family) }
                            Text(have ? family : "\(family) (not in your ROMs)").tag(String?.some(family))
                        }
                    }
                }
                Section("Starting") {
                    Picker("Start by", selection: $startChoice) {
                        Text("Starting an application on the disc").tag(StartChoice.application)
                        Text("Running the disc’s !Boot").tag(StartChoice.boot)
                        Text("Typing a command at the command line").tag(StartChoice.type)
                        Text("Just putting the disc in").tag(StartChoice.insertOnly)
                    }
                    .pickerStyle(.radioGroup)
                    if startChoice == .application {
                        if applications.isEmpty {
                            TextField("Application", text: $application, prompt: Text("!Game"))
                                .font(.system(.body, design: .monospaced))
                        } else {
                            Picker("Application", selection: $application) {
                                ForEach(applications, id: \.self) { Text($0).tag($0) }
                            }
                        }
                    }
                    if startChoice == .type {
                        TextField("Command", text: $command, prompt: Text("Run ADFS::0.$.!Game"))
                            .font(.system(.body, design: .monospaced))
                        Text("Typed after F12, at the desktop’s command line. Separate several with ;")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Notes") {
                    TextField("Notes", text: optional(\.notes), prompt: Text("Controls, tips, where it came from…"), axis: .vertical)
                        .lineLimit(2...5)
                        .labelsHidden()
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                if !draft.hasDisc {
                    Text("You can add the disc later: drop it on the game.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel) { library.cancel(draft) }
                    .keyboardShortcut(.cancelAction)
                Button(draft.isNew ? "Add Game" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.game.title.trimmingCharacters(in: .whitespaces).isEmpty || saving)
            }
            .padding(16)
        }
        .frame(width: 540, height: 700)
        .onAppear {
            yearText = draft.game.year.map(String.init) ?? ""
            applications = draft.disc?.applications ?? existingApplications
            switch draft.game.start {
            case .boot: startChoice = .boot
            case .application(let name):
                startChoice = .application
                application = name
            case .insertOnly: startChoice = .insertOnly
            case .type(let text):
                startChoice = .type
                command = text
            }
        }
        .onChange(of: draft.game.model) {
            if let kb = draft.game.ramKB, !draft.game.model.ramChoices.contains(kb) { draft.game.ramKB = nil }
        }
        .dropDestination(for: URL.self) { urls, _ in take(urls) }
    }

    private var coverWell: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5]))
                .foregroundStyle(.tertiary)
            if let url = draft.shownCover, let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).padding(4)
            } else {
                VStack(spacing: 4) {
                    Image(systemName: "photo").font(.title)
                    Text("Drop a cover").font(.caption)
                }
                .foregroundStyle(.secondary)
            }
        }
        .frame(width: 110, height: 150)
        .contentShape(Rectangle())
        .onTapGesture { chooseCover() }
        .help("Drop a picture here, or click to choose one")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(draft.shownCover == nil ? "No cover. Choose a cover picture." : "Cover. Choose another picture.")
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder private var discRow: some View {
        HStack {
            Image(systemName: draft.hasDisc ? "opticaldisc" : "opticaldisc.fill")
                .foregroundStyle(draft.hasDisc ? .primary : .tertiary)
            if let disc = draft.disc {
                Text(disc.fileName)
            } else if draft.existingDiscName != nil {
                Text("The game’s disc")
            } else {
                Text("No disc yet").foregroundStyle(.secondary)
            }
            Spacer()
            Button(draft.hasDisc ? "Replace…" : "Choose…") { chooseDisc() }
        }
    }

    private func chooseDisc() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = MachineController.discTypes
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        _ = take([url])
    }

    private func chooseCover() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        _ = take([url])
    }

    /// A disc image or picture dropped on (or chosen in) the sheet.
    private func take(_ urls: [URL]) -> Bool {
        let discURL = urls.first(where: MyGames.isDiscName)
        let coverURL = urls.first(where: MyGames.isCoverName)
        guard discURL != nil || coverURL != nil else { return false }
        if let coverURL {
            do {
                _ = try MyGames.checkCover(at: coverURL)
                draft.newCover = coverURL
            } catch {
                NSAlert(error: error).runModal()
            }
        }
        if let discURL {
            do {
                let disc = try MyGames.readDisc(at: discURL)
                let hadDisc = draft.hasDisc
                draft.disc = disc
                applications = disc.applications
                if draft.isNew && !hadDisc {
                    switch disc.suggestedStart {
                    case .application(let name):
                        startChoice = .application
                        application = name
                    case .boot: startChoice = .boot
                    default: break
                    }
                }
                // A cover-first game: its disc says more about it.
                if draft.isNew && !hadDisc && (draft.game.title.isEmpty || draft.game.title == draft.newCover?.deletingPathExtension().lastPathComponent) {
                    draft.game.title = disc.suggestedTitle
                    if draft.game.year == nil, let year = disc.suggestedYear { yearText = String(year) }
                }
            } catch {
                NSAlert(error: error).runModal()
            }
        }
        return true
    }

    /// The applications on the game's disc already (when editing).
    private var existingApplications: [String] {
        guard !draft.isNew, let url = library.myGames.discURL(draft.game),
              let data = FileManager.default.contents(atPath: url.path) else { return [] }
        return MyGames.applications(onDisc: [UInt8](data))
    }

    private func optional(_ keyPath: WritableKeyPath<PersonalGame, String?>) -> Binding<String> {
        Binding(get: { draft.game[keyPath: keyPath] ?? "" },
                set: { draft.game[keyPath: keyPath] = $0.isEmpty ? nil : $0 })
    }

    private func save() {
        draft.game.title = draft.game.title.trimmingCharacters(in: .whitespaces)
        draft.game.year = Int(yearText.trimmingCharacters(in: .whitespaces))
        draft.game.start = switch startChoice {
        case .application: application.isEmpty ? .insertOnly : .application(application)
        case .boot: .boot
        case .insertOnly: .insertOnly
        case .type: .type(command.trimmingCharacters(in: .whitespaces))
        }
        saving = true
        let draft = draft
        Task {
            _ = await library.save(draft)
            saving = false
        }
    }
}

// MARK: Playing

/// Starts My Games in the Archimedes in front (or a new window's), asking
/// before taking over a machine that has a disc in.
@MainActor
enum Player {
    static func play(_ game: PersonalGame, openMachine: @escaping () -> Void) {
        guard let url = GameLibrary.shared.myGames.discURL(game) else { return }
        let launch: (MachineController) -> Void = { $0.play(game, disc: url) }
        guard let machine = MachineController.frontmost, machine.host != nil else {
            MachineController.pendingLaunch = launch
            openMachine()
            return
        }
        if let current = machine.discName, machine.playing != game.id {
            let alert = NSAlert()
            alert.messageText = "Play \(game.title)?"
            alert.informativeText = "The Archimedes starts \(game.title), replacing “\(current)”. Anything unsaved there is lost (Quick Save, ⌥⌘S, keeps it)."
            alert.addButton(withTitle: "Play")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        launch(machine)
        NSApp.windows.first { $0.identifier?.rawValue.hasPrefix(MachineWindow.windowID) == true && $0.isVisible }?.makeKeyAndOrderFront(nil)
    }
}

extension MachineController {
    /// Plays one of My Games: the machine it wants (power cycling if it's
    /// another), its disc in drive 0, then started as the game says.
    func play(_ game: PersonalGame, disc url: URL) {
        let rom = game.rom.flatMap { family in AppSettings.shared.romLibrary.first { $0.version.hasPrefix(family) }?.path }
        let changesMachine = game.model != model || (game.ramKB != nil && game.ramKB != ramKB) || (rom != nil && rom != romPath)
        if changesMachine {
            setHardware(model: game.model, ramKB: game.ramKB, romPath: rom)
        }
        guard let host else { return }
        do {
            let image = try FloppyImage.open(path: url.path)
            host.send { $0.machine.insertFloppy(image) }
            playing = game.id
        } catch {
            alert("Could not open \(game.title)’s disc", "\(error)")
            return
        }
        switch game.start {
        case .insertOnly:
            break
        case .boot:
            // The disc's !Boot, from the command line, as booting it would.
            atCommandLine("/ADFS::0.$.!Boot\n")
        case .application(let name):
            // Run, then an empty line back to the desktop, where it starts.
            atCommandLine("Run ADFS::0.$.\(name)\n\n")
        case .type(let command):
            guard !command.isEmpty else { break }
            atCommandLine(command.replacingOccurrences(of: ";", with: "\n") + "\n")
        }
    }

    /// Types at the desktop's command line (F12), once the machine's at its
    /// desktop (one that's just started takes a while).
    private func atCommandLine(_ text: String) {
        let f12: UInt8 = 0x0C
        Task { @MainActor [weak self] in
            for _ in 0..<60 {
                let up = self?.host?.sendAndWait { $0.machine.seconds } ?? 0
                if up > 25 { break }
                try? await Task.sleep(for: .seconds(1))
            }
            guard let self else { return }
            self.keyDown(f12)
            try? await Task.sleep(for: .milliseconds(150))
            self.keyUp(f12)
            try? await Task.sleep(for: .milliseconds(800))
            self.type(text)
        }
    }
}

/// Window ▸ Game Library.
struct GameLibraryMenuItem: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Game Library") { openWindow(id: GameLibraryView.windowID) }
            .keyboardShortcut("g", modifiers: [.command, .shift])
    }
}
