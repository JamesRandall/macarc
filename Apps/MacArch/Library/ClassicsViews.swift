import AppKit
import ArchimedesCore
import SwiftUI

// The Archimedes Classics shelf's pieces: a game's tile and details, the
// archive's book, and notices. (After MacBeeb's bookshelf.)

/// One of the Classics on the shelf: its cover, rank, and what's next.
struct ClassicTile: View {
    let game: ClassicGame
    let selected: Bool
    @State private var classics = ClassicsLibrary.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 8) {
            // Nothing drawn over the artwork: the rank and state go below.
            ClassicCover(game: game)
                // Not in the library yet: a touch darker, still in full colour.
                .brightness(classics.state(of: game) == .installed ? 0 : -0.06)
                .shadow(color: .black.opacity(0.35), radius: 6, y: 4)
                .scaleEffect(classics.justInstalled == game.id && !reduceMotion ? 1.04 : 1)
                .frame(height: 210, alignment: .bottom)
                .frame(maxWidth: .infinity)
            VStack(spacing: 3) {
                HStack(spacing: 6) {
                    Text("\(game.rank)")
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(game.title)
                        .font(.headline)
                }
                .lineLimit(1)
                status
                    .font(.caption)
                    .lineLimit(1)
            }
        }
        .padding(8)
        .background(selected ? AnyShapeStyle(.selection.opacity(0.35)) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .help("#\(game.rank) \(game.title) — \(statusText)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Number \(game.rank), \(game.title). \(statusText).")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityActions {
            if classics.state(of: game) == .notInstalled {
                Button("Get from the Archimedes Archive") { classics.get(game) }
            }
        }
        .animation(reduceMotion ? nil : .spring(duration: 0.4), value: statusText)
    }

    @ViewBuilder private var status: some View {
        if classics.justInstalled == game.id {
            Label("Added to your library", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else {
            switch classics.state(of: game) {
            case .notInstalled:
                Button {
                    classics.get(game)
                } label: {
                    Label("Get", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.link)
                .help("Get \(game.title) from the Archimedes Archive")
            case .waiting:
                Label(classics.haveDiscs(game) > 0 ? "\(classics.haveDiscs(game)) of \(game.discs.count) discs…" : "Waiting for download…",
                      systemImage: "clock")
                    .foregroundStyle(.orange)
            case .importing:
                Label("Adding…", systemImage: "arrow.down.doc")
                    .foregroundStyle(.orange)
            case .partial(let have, let of):
                Label("\(have) of \(of) discs", systemImage: "circle.lefthalf.filled")
                    .foregroundStyle(.orange)
            case .installed:
                Label("Ready to play", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
    }

    private var statusText: String {
        if classics.justInstalled == game.id { return "Added to your library" }
        return switch classics.state(of: game) {
        case .notInstalled: "Get from the Archimedes Archive"
        case .waiting: "Waiting for download"
        case .importing: "Adding"
        case .partial(let have, let of): "\(have) of \(of) discs"
        case .installed: "Ready to play"
        }
    }
}

/// A Classic's bundled cover at its own proportions, or a typographic one.
struct ClassicCover: View {
    let game: ClassicGame

    var body: some View {
        if let image = ClassicCovers.image(for: game) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .coverPop()
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .accessibilityHidden(true)
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
                }
                .padding(10)
            }
            .aspectRatio(0.7, contentMode: .fit)
            .accessibilityHidden(true)
        }
    }
}

/// The archive's book at the end of the shelf: typographic, in the
/// Archimedes' colours, with no third-party logo.
struct ArchiveCover: View {
    let archive: ClassicsArchive

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 3)
                .fill(LinearGradient(colors: [Color(red: 0.12, green: 0.14, blue: 0.13), Color(red: 0.05, green: 0.07, blue: 0.06)],
                                     startPoint: .top, endPoint: .bottom))
            HStack(spacing: 3) {
                ForEach(Array([Color.green, .cyan, .blue, .orange, .yellow].enumerated()), id: \.offset) { _, colour in
                    Rectangle().fill(colour).frame(height: 4)
                }
            }
            .padding(.top, 22)
            VStack(alignment: .leading, spacing: 6) {
                Spacer()
                Image(systemName: "books.vertical.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(Color(red: 0.45, green: 0.85, blue: 0.55))
                Text(archive.title)
                    .font(.system(.title3, design: .serif).weight(.bold))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                Text("arcarc.top")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Color(red: 0.45, green: 0.85, blue: 0.55))
                Text("Thousands more titles")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.7))
            }
            .padding(12)
        }
        .accessibilityHidden(true)
    }
}

struct ArchiveTile: View {
    let archive: ClassicsArchive
    let selected: Bool

    var body: some View {
        VStack(spacing: 8) {
            ArchiveCover(archive: archive)
                .aspectRatio(0.7, contentMode: .fit)
                .shadow(color: .black.opacity(0.35), radius: 6, y: 4)
                .frame(height: 210, alignment: .bottom)
                .frame(maxWidth: .infinity)
            VStack(spacing: 3) {
                Text("Archimedes Archive").font(.headline).lineLimit(1)
                Text("Explore the archive ↗").font(.caption).foregroundStyle(Color.accentColor)
            }
        }
        .padding(8)
        .background(selected ? AnyShapeStyle(.selection.opacity(0.35)) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .help(archive.pitch)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(archive.title). \(archive.subtitle).")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// A notice across the top of the shelf, with actions.
struct ShelfBanner<Message: View, Actions: View>: View {
    let systemImage: String
    @ViewBuilder let message: Message
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.secondary)
            message
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            actions
        }
        .padding(12)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// One of the Classics in the details panel: what it is, how to get it,
/// and Play.
struct ClassicDetail: View {
    let game: ClassicGame
    let openMachine: () -> Void
    @State private var classics = ClassicsLibrary.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ClassicCover(game: game)
                    .frame(maxHeight: 260)
                    .frame(maxWidth: .infinity)
                    .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
                VStack(alignment: .leading, spacing: 4) {
                    Text(game.title)
                        .font(.title2.weight(.semibold))
                    if let edition = game.editionLabel {
                        Text(edition).foregroundStyle(.secondary)
                    }
                    Text("#\(game.rank) of the Archimedes Top 25")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)

                actions

                Text(game.description)
                    .fixedSize(horizontal: false, vertical: true)

                if let hint = game.hint {
                    Label {
                        Text(hint).fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "lightbulb")
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }

                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                    if let publisher = game.publisher {
                        GridRow {
                            Text("Publisher").foregroundStyle(.secondary)
                            Text(publisher + (game.year.map { ", \($0)" } ?? ""))
                        }
                    }
                    if let authors = game.authors {
                        GridRow {
                            Text("By").foregroundStyle(.secondary)
                            Text(authors)
                        }
                    }
                    GridRow {
                        Text("Plays on").foregroundStyle(.secondary)
                        Text(game.machine.summary)
                    }
                }
                .font(.callout)

                discList

                Link("View in the Archimedes Archive ↗", destination: game.archivePageURL)
                    .font(.callout)
                Text("Disc images preserved by the Archimedes Archive and its contributors.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
        }
    }

    @ViewBuilder private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch classics.state(of: game) {
            case .notInstalled, .partial:
                Button {
                    classics.get(game)
                } label: {
                    Text("Get from the Archimedes Archive ↗").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                Button("Add Discs…") { classics.chooseAndImport(for: game) }
                    .buttonStyle(.link)
            case .waiting:
                Text(game.discs.count > 1
                     ? "Download the \(game.discs.count) files below from the Archimedes Archive. MacArch adds each as it finishes."
                     : "Download \(game.discs[0].fileName) from the Archimedes Archive. MacArch adds it when it finishes.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                if classics.autoDetect != true {
                    Text("Looking for downloads is off, so add the discs once they’re downloaded.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button {
                    NSWorkspace.shared.open(game.archivePageURL)
                } label: {
                    Text("Open the Archive Again ↗").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Waiting for download…").font(.callout).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Add Discs…") { classics.chooseAndImport(for: game) }
                    Button("Cancel Waiting") { classics.cancelWaiting(game) }
                }
                .buttonStyle(.link)
            case .importing:
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Adding…").foregroundStyle(.secondary)
                }
            case .installed:
                if classics.justInstalled == game.id {
                    Label("Added to your library", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                Button {
                    Player.play(game, openMachine: openMachine)
                } label: {
                    Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                HStack {
                    Button("Reveal Discs") { classics.reveal(game) }
                    Button("Remove…") { classics.remove(game) }
                }
                .buttonStyle(.link)
            }
        }
    }

    /// Its discs: which are in, each with a link to download it.
    private var discList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(game.discs.count == 1 ? "Disc" : "Discs").font(.headline)
            ForEach(game.discs, id: \.sha256) { disc in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: classics.has(disc, of: game) ? "checkmark.circle.fill" : "circle.dashed")
                        .foregroundStyle(classics.has(disc, of: game) ? .green : .secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(disc.label).font(.callout)
                        if classics.has(disc, of: game) {
                            Text(disc.fileName).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        } else {
                            Button(disc.fileName + " ↗") { classics.get(disc, of: game) }
                                .buttonStyle(.link)
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help("Download \(disc.fileName) from the Archimedes Archive")
                        }
                    }
                }
            }
        }
    }
}

/// The archive's book in the details panel.
struct ArchiveDetail: View {
    let archive: ClassicsArchive

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ArchiveCover(archive: archive)
                    .aspectRatio(0.7, contentMode: .fit)
                    .frame(maxHeight: 260)
                    .frame(maxWidth: .infinity)
                Text(archive.title)
                    .font(.title2.weight(.semibold))
                Text(archive.pitch)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    NSWorkspace.shared.open(archive.url)
                } label: {
                    Text("Visit the Archimedes Archive ↗").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                Text(archive.about)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Disc images are downloaded from the Archimedes Archive in your browser. MacArch is an independent emulator and is not affiliated with the archive.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
        }
    }
}

extension Player {
    /// Starts a Classic in the Archimedes in front (or a new window's),
    /// asking before taking over a machine that has a disc in.
    static func play(_ game: ClassicGame, openMachine: @escaping () -> Void) {
        let classics = ClassicsLibrary.shared
        let floppies = classics.floppyURLs(game)
        let hardDisc = game.discs.contains { $0.kind == .hardDiscArchive } ? classics.store.hardDiscURL(game) : nil
        let cmos = classics.store.folder(game.id).appendingPathComponent("cmos.bin").path
        let launch: (MachineController) -> Void = { $0.play(game, floppies: floppies, hardDisc: hardDisc, cmosPath: cmos) }
        guard let machine = MachineController.frontmost, machine.host != nil else {
            MachineController.pendingLaunch = launch
            openMachine()
            return
        }
        if let current = machine.discName, machine.session?.gameID != game.id {
            let alert = NSAlert()
            alert.messageText = "Play \(game.title)?"
            alert.informativeText = "The Archimedes restarts as \(game.title) wants it, replacing “\(current)”. Anything unsaved there is lost (Quick Save, ⌥⌘S, keeps it)."
            alert.addButton(withTitle: "Play")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        launch(machine)
        NSApp.windows.first { $0.identifier?.rawValue.hasPrefix(MachineWindow.windowID) == true && $0.isVisible }?.makeKeyAndOrderFront(nil)
    }
}
