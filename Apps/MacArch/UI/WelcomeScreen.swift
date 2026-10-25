import AppKit
import ArchimedesCore
import SwiftUI

/// The first thing MacArch shows (unless Settings says otherwise): its
/// three parts, an Archimedes, the Game Library and the Network Studio,
/// and things worth trying, so there's a way into all of it. (After
/// MacBeeb's welcome screen.)
struct WelcomeScreen: View {
    static let windowID = "welcome"
    static let title = "Welcome to MacArch"
    /// Posted to have the welcome screen opened, by whichever window can.
    static let openRequest = Notification.Name("MacArchOpenWelcome")
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @AppStorage(LaunchScreen.defaultsKey, store: AppSettings.store) private var launchScreen = LaunchScreen.preference
    @State private var error: String?
    @MainActor private static var launched = false
    /// What's New has notes the user hasn't seen (until they look).
    @MainActor private static var unseenNotes = false
    @State private var hasUnseenNotes = WelcomeScreen.unseenNotes
    @State private var library = GameLibrary.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            hero
            HStack(alignment: .top, spacing: 18) {
                machineCard
                gamesCard
                networkCard
            }
            .fixedSize(horizontal: false, vertical: true)
            explore
            footer
        }
        .padding(.horizontal, 36)
        .padding(.top, 30)
        .padding(.bottom, 22)
        .frame(width: 1060)
        .background(HomeBackground())
        .preferredColorScheme(.dark)
        .onAppear(perform: arrived)
        .onOpenURL { url in
            if JoinRequests.isJoinLink(url) {
                JoinRequests.shared.handle(url)
                go { openWindow(id: JoinRoomView.windowID) }
            }
        }
        .alert("Can’t make the network", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") {}
        } message: {
            Text(error ?? "")
        }
    }

    private func arrived() {
        guard !Self.launched else { return }
        Self.launched = true
        if LaunchScreen.atLaunch == .network {
            NetworkStudioCommands.showStudio(openWindow: openWindow)
            dismissWindow(id: Self.windowID)
        } else {
            // Its tile says so, rather than opening the notes.
            Self.unseenNotes = WhatsNew.shouldShowOnLaunch()
            hasUnseenNotes = Self.unseenNotes
        }
    }

    /// Opens a window and puts this one away.
    private func go(_ action: () -> Void) {
        action()
        dismissWindow(id: Self.windowID)
    }

    // MARK: Hero

    private var hero: some View {
        HStack(alignment: .center, spacing: 32) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Welcome to")
                    .font(.title2.weight(.medium))
                    .foregroundStyle(.secondary)
                Text("MacArch")
                    .font(.system(size: 64, weight: .heavy, design: .rounded))
                    .foregroundStyle(LinearGradient(colors: [.white, Color(white: 0.78)], startPoint: .top, endPoint: .bottom))
                Text("The Acorn Archimedes, on your Mac. Switch one on and use RISC OS, play your games, or wire up a classroom of them on Econet and watch them work together.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 470, alignment: .leading)
                AcornStripe()
                    .padding(.top, 4)
            }
            Spacer(minLength: 0)
            CommandLineScreen()
                .frame(width: 400, height: 250)
        }
    }

    // MARK: The three parts

    private var machineCard: some View {
        WelcomeCard(colour: .green, symbol: "desktopcomputer", title: "Archimedes",
                    blurb: "An A310, A3000, A440/1 or A5000, with RISC OS 2 or 3 from your own ROMs. Fit hard discs, and step through its ARM in the debugger.") {
            ModelChips()
        } actions: {
            Button { go { openWindow(id: MachineWindow.windowID) } } label: {
                Label("Switch On", systemImage: "power")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .controlSize(.large)
            .help("Open an Archimedes, set up as the last one was")
        }
    }

    private var gamesCard: some View {
        WelcomeCard(colour: .orange, symbol: "books.vertical", title: "Game Library",
                    blurb: "Your own Archimedes games on a shelf, with their box art: each with its disc, the machine it plays on and how it starts, ready to play with a double-click.") {
            CoverFan()
        } actions: {
            Button { go { openWindow(id: GameLibraryView.windowID) } } label: {
                Label(library.personalGames.isEmpty ? "Add Your Games" : "Browse Games", systemImage: "gamecontroller")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .controlSize(.large)
        }
    }

    private var networkCard: some View {
        let recent = RecentNetworks.shared.existing
        return WelcomeCard(colour: .cyan, symbol: "point.3.connected.trianglepath.dotted", title: "Network Studio",
                           blurb: "A classroom of Archimedes on Econet, each one running for real: a Level 4 file server, network boot, and BBC Micros from MacBeeb over the Internet.") {
            EconetAnimation()
        } actions: {
            Button { go { openWindow(id: JoinRoomView.windowID) } } label: {
                Label("Join with a Code…", systemImage: "globe")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .help("Join someone's network over the Internet (from MacArch or MacBeeb), with the code or link they gave you")
            if !recent.isEmpty {
                WideMenu(title: "Open Recent", items: recent.prefix(8).map { url in
                    (url.deletingPathExtension().lastPathComponent, { go { NetworkStudioCommands.open(url, openWindow: openWindow) } })
                })
            }
            Button { go { openWindow(id: NetworkStartView.windowID) } } label: {
                Label("New Network", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.teal)
            .controlSize(.large)
        }
    }

    // MARK: Explore

    private var explore: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Things to Try")
                .font(.headline)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                ExploreTile(symbol: "sparkles", colour: .purple, title: "Distributed Mandelbrot",
                            detail: "Four A3000s, over Econet") {
                    go { make(.distributedMandelbrot) }
                }
                ExploreTile(symbol: "building.columns", colour: .green, title: "A school classroom",
                            detail: "With a Level 4 file server") {
                    go { make(.schoolClassroom) }
                }
                ExploreTile(symbol: "brain", colour: .pink, title: "Let an AI drive",
                            detail: "Connect an agent with MCP") {
                    go { openWindow(id: "mcp-setup") }
                }
                ExploreTile(symbol: "gift", colour: .blue, title: "What’s new in \(WhatsNew.releases.first?.version ?? WhatsNew.currentVersion)",
                            detail: "Everything in this version", badge: hasUnseenNotes ? "New" : nil) {
                    Self.unseenNotes = false
                    hasUnseenNotes = false
                    openWindow(id: "whats-new")
                }
            }
        }
    }

    /// A new network from a template, opened.
    private func make(_ template: NetworkTemplate) {
        let url = RecentNetworks.newURL(named: template.title)
        do {
            try NetworkPackage.create(template, at: url)
            NetworkStudioCommands.open(url, openWindow: openWindow)
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Text("When MacArch opens, show")
                .foregroundStyle(.secondary)
            Picker("When MacArch opens, show", selection: $launchScreen) {
                ForEach(LaunchScreen.allCases) { screen in
                    Text(screen.title).tag(screen)
                }
            }
            .labelsHidden()
            .fixedSize()
            Spacer()
            Text("Window ▸ Welcome to MacArch brings this back.")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Pieces

/// One of the three parts: a picture, what it is, and how in.
private struct WelcomeCard<Art: View, Actions: View>: View {
    let colour: Color
    let symbol: String
    let title: String
    let blurb: String
    @ViewBuilder var art: Art
    @ViewBuilder var actions: Actions
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            art
                .frame(height: 132)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .foregroundStyle(colour)
                Text(title)
                    .font(.title2.weight(.bold))
            }
            Text(blurb)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            VStack(spacing: 8) {
                actions
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 18)
                .fill(.white.opacity(hovering ? 0.085 : 0.055))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(LinearGradient(colors: [colour.opacity(hovering ? 0.9 : 0.45), .white.opacity(0.06)],
                                             startPoint: .top, endPoint: .bottom), lineWidth: 1.5)
        }
        .shadow(color: colour.opacity(hovering ? 0.35 : 0.0), radius: 22)
        .scaleEffect(hovering ? 1.012 : 1)
        .animation(.snappy(duration: 0.2), value: hovering)
        .onHover { hovering = $0 }
    }
}

/// A smaller suggestion.
private struct ExploreTile: View {
    let symbol: String
    let colour: Color
    let title: String
    let detail: String
    var badge: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(colour)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if let badge {
                    Text(badge)
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(colour, in: Capsule())
                        .foregroundStyle(.white)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(.white.opacity(hovering ? 0.09 : 0.05), in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(colour.opacity(hovering ? 0.7 : 0), lineWidth: 1.5)
            }
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.snappy(duration: 0.15), value: hovering)
    }
}

/// The page behind it all: dark, with a glow of RISC OS's colours.
private struct HomeBackground: View {
    var body: some View {
        ZStack {
            Color(red: 0.05, green: 0.06, blue: 0.075)
            RadialGradient(colors: [Color.green.opacity(0.2), .clear], center: UnitPoint(x: 0.05, y: 0.0), startRadius: 0, endRadius: 520)
            RadialGradient(colors: [Color.cyan.opacity(0.16), .clear], center: UnitPoint(x: 1, y: 0.15), startRadius: 0, endRadius: 560)
            RadialGradient(colors: [Color.orange.opacity(0.08), .clear], center: UnitPoint(x: 0.5, y: 1.1), startRadius: 0, endRadius: 600)
        }
        .ignoresSafeArea()
    }
}

/// The Acorn logo's colours, as a rule under the title.
private struct AcornStripe: View {
    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array([Color.green, .mint, .cyan, .blue, .indigo, .orange, .yellow].enumerated()), id: \.offset) { _, colour in
                Capsule()
                    .fill(colour.gradient)
                    .frame(width: 34, height: 6)
            }
        }
        .accessibilityHidden(true)
    }
}

/// The models, as chips.
private struct ModelChips: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color.green.opacity(0.32), Color.green.opacity(0.06)], startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(spacing: 10) {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 46, weight: .light))
                    .foregroundStyle(.white.opacity(0.9))
                HStack(spacing: 6) {
                    ForEach(["A310", "A3000", "A440/1", "A5000"], id: \.self) { model in
                        Text(model)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.black.opacity(0.35), in: Capsule())
                    }
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// Some classic covers, fanned out.
private struct CoverFan: View {
    static let names = ["lemmings", "elite", "gods", "thechaosengine", "syndicate"]
    static let images: [NSImage] = names.compactMap { name in
        Bundle.main.url(forResource: name, withExtension: "jpg", subdirectory: "Covers").flatMap(NSImage.init(contentsOf:))
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color.orange.opacity(0.28), Color.yellow.opacity(0.05)], startPoint: .topLeading, endPoint: .bottomTrailing)
            ZStack {
                ForEach(Array(Self.images.enumerated()), id: \.offset) { index, image in
                    let middle = Double(Self.images.count - 1) / 2
                    let place = Double(index) - middle
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 70, height: 96)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                        .shadow(color: .black.opacity(0.5), radius: 6, y: 3)
                        .rotationEffect(.degrees(place * 9), anchor: .bottom)
                        .offset(x: place * 40, y: abs(place) * 7 + 10)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// Archimedes on a cable, with frames running along it.
private struct EconetAnimation: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            Canvas { g, size in
                let line = size.height * 0.7
                let stations = 4
                let xs = (0..<stations).map { size.width * (0.14 + 0.24 * Double($0)) }
                var cable = Path()
                cable.move(to: CGPoint(x: size.width * 0.05, y: line))
                cable.addLine(to: CGPoint(x: size.width * 0.95, y: line))
                g.stroke(cable, with: .color(.cyan.opacity(0.55)), lineWidth: 2)
                for x in xs {
                    var drop = Path()
                    drop.move(to: CGPoint(x: x, y: line))
                    drop.addLine(to: CGPoint(x: x, y: line - 26))
                    g.stroke(drop, with: .color(.cyan.opacity(0.55)), lineWidth: 2)
                    // A RISC OS desktop: grey, with its icon bar.
                    let screen = CGRect(x: x - 22, y: line - 66, width: 44, height: 40)
                    g.fill(Path(roundedRect: screen, cornerRadius: 5), with: .color(.white.opacity(0.85)))
                    let inner = screen.insetBy(dx: 4, dy: 4)
                    g.fill(Path(roundedRect: inner, cornerRadius: 2), with: .color(Color(white: 0.55)))
                    g.fill(Path(CGRect(x: inner.minX, y: inner.maxY - 7, width: inner.width, height: 7)), with: .color(Color(white: 0.85)))
                    let window = CGRect(x: inner.minX + 4, y: inner.minY + 4, width: 18 + Double(Int(x) % 7), height: 13)
                    g.fill(Path(window), with: .color(.white))
                    g.fill(Path(CGRect(x: window.minX, y: window.minY, width: window.width, height: 3)), with: .color(Color(red: 0.6, green: 0.7, blue: 0.95)))
                }
                for packet in 0..<3 {
                    let phase = (time * 0.35 + Double(packet) / 3).truncatingRemainder(dividingBy: 1)
                    let from = xs[packet % stations], to = xs[(packet + 2) % stations]
                    let x = from + (to - from) * (0.5 - 0.5 * cos(phase * .pi * 2))
                    let dot = CGRect(x: x - 5, y: line - 5, width: 10, height: 10)
                    g.fill(Path(ellipseIn: dot.insetBy(dx: -5, dy: -5)), with: .color(.cyan.opacity(0.18)))
                    g.fill(Path(ellipseIn: dot), with: .color([Color.yellow, .green, .pink][packet]))
                }
            }
            .background(LinearGradient(colors: [Color.cyan.opacity(0.22), Color.blue.opacity(0.05)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        .accessibilityHidden(true)
    }
}

/// RISC OS's command line (F12), typing things to try, the cursor flashing.
struct CommandLineScreen: View {
    static let commands = ["Desktop", "Mandel", "BASIC", "I AM SYST", "Cat", "Configure Mode 12", "Modules", "Run !Draw"]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(lines(at: time).enumerated()), id: \.offset) { _, line in
                    Text(line.isEmpty ? " " : line)
                }
            }
            .font(.system(size: 15, weight: .semibold, design: .monospaced))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(18)
            .background(Color.black)
            .overlay {
                Canvas { g, size in
                    var y = 0.0
                    while y < size.height {
                        g.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)), with: .color(.black.opacity(0.22)))
                        y += 3
                    }
                }
                .allowsHitTesting(false)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(.white.opacity(0.14), lineWidth: 1)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 20).fill(Color(white: 0.84)).shadow(color: .black.opacity(0.6), radius: 18, y: 8))
        .shadow(color: .green.opacity(0.15), radius: 30)
        .accessibilityElement()
        .accessibilityLabel("An Archimedes' command line, RISC OS's star prompt")
    }

    private func lines(at time: Double) -> [String] {
        let period = 4.0
        let index = Int(time / period) % Self.commands.count
        let into = time.truncatingRemainder(dividingBy: period)
        let command = Self.commands[index]
        let typed = String(command.prefix(max(0, Int((into - 0.6) * 9))))
        let cursor = Int(time * 2.5) % 2 == 0 ? "_" : " "
        return ["Acorn A3000 2048K", "", "RISC OS 3.11", "", "Press SPACE or click", "mouse to continue", "", "*" + typed + cursor]
    }
}

/// A menu that looks like the card's other buttons, as wide as they are:
/// a button that opens its menu where it was clicked. (MacBeeb's.)
private struct WideMenu: View {
    let title: String
    let items: [(String, () -> Void)]

    var body: some View {
        Button(action: show) {
            Text(title)
                .frame(maxWidth: .infinity)
                .overlay(alignment: .trailing) {
                    Image(systemName: "chevron.down").font(.caption.weight(.semibold))
                }
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .accessibilityHint("Shows a menu")
    }

    @MainActor
    private func show() {
        let menu = NSMenu()
        let target = MenuTarget(items.map(\.1))
        for (index, item) in items.enumerated() {
            let entry = NSMenuItem(title: item.0, action: #selector(MenuTarget.choose(_:)), keyEquivalent: "")
            entry.target = target
            entry.tag = index
            menu.addItem(entry)
        }
        withExtendedLifetime(target) {
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }

    @MainActor
    private final class MenuTarget: NSObject {
        let actions: [() -> Void]
        init(_ actions: [() -> Void]) { self.actions = actions }
        @objc func choose(_ item: NSMenuItem) {
            if actions.indices.contains(item.tag) { actions[item.tag]() }
        }
    }
}

/// Window ▸ Welcome to MacArch.
struct WelcomeMenuItem: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // (Menus are made at launch: the way to open the welcome screen
        // when no window's left to do it.)
        let _ = WelcomeReturn.remember(openWindow)
        Button("Welcome to MacArch") { openWindow(id: WelcomeScreen.windowID) }
            .keyboardShortcut("1", modifiers: [.command, .shift])
    }
}

/// What MacArch shows when it opens: the welcome screen, or straight into
/// one of its three parts. Chosen on the welcome screen and in Settings.
enum LaunchScreen: String, CaseIterable, Identifiable {
    case welcome, machine, games, network

    var id: String { rawValue }

    static let defaultsKey = "MacArchLaunchScreen"

    var title: String {
        switch self {
        case .welcome: "The Welcome Screen"
        case .machine: "An Archimedes"
        case .games: "The Game Library"
        case .network: "The Network Studio"
        }
    }

    static var preference: LaunchScreen {
        get { AppSettings.store.string(forKey: defaultsKey).flatMap(LaunchScreen.init(rawValue:)) ?? .welcome }
        set { AppSettings.store.set(newValue.rawValue, forKey: defaultsKey) }
    }

    /// What this launch shows: the setting as it was when the app started.
    /// Self-tests need a machine.
    nonisolated static let atLaunch: LaunchScreen = AppSettings.isSelfTest ? .machine
        : AppSettings.store.string(forKey: defaultsKey).flatMap(LaunchScreen.init(rawValue:)) ?? .welcome
}

/// With the welcome screen as the opening screen, MacArch is a place to
/// come back to: closing the last other window brings the welcome screen
/// back, and closing that quits (as closing the last window does
/// otherwise). (MacBeeb's.)
@MainActor
enum WelcomeReturn {
    private static var openWindow: OpenWindowAction?

    static var applies: Bool { LaunchScreen.preference == .welcome && !AppSettings.isSelfTest }

    static func remember(_ action: OpenWindowAction) { openWindow = action }

    static func open() { openWindow?(id: WelcomeScreen.windowID) }

    static func open(id: String) { openWindow?(id: id) }

    static func start() {
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            let title = (note.object as? NSWindow)?.title
            MainActor.assumeIsolated { closed(title: title) }
        }
    }

    private static func closed(title: String?) {
        guard applies else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            let open = NSApp.windows.contains { $0.isVisible && !($0 is NSPanel) && $0.styleMask.contains(.titled) }
            guard !open else { return }
            if title == WelcomeScreen.title {
                NSApp.terminate(nil)
            } else {
                Self.open()
            }
        }
    }
}
