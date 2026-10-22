import AppKit
import ArchimedesCore
import SwiftUI

// The welcome screen (no ROM yet), the ROMs window, and the pieces they
// share: a drop zone that finds ROMs in whatever lands on it, what was
// found, and the list of ROMs MacArch has.

/// Drop ROM files, chip sets, folders or ZIPs here (or choose them).
struct ROMDropZone: View {
    var compact = false
    @State private var library = ROMLibrary.shared
    @State private var targeted = false

    var body: some View {
        // Static drawing: a continuous animation here (marching ants) kept
        // the window server recompositing the whole window every frame.
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(targeted ? AnyShapeStyle(.tint.opacity(0.16)) : AnyShapeStyle(Color.primary.opacity(0.04)))
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: targeted ? 2.5 : 1.5, dash: [9, 7]))
                .foregroundStyle(targeted ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.secondary.opacity(0.55)))
            content
        }
        .frame(height: compact ? 112 : 230)
        .animation(.easeOut(duration: 0.15), value: targeted)
        .dropDestination(for: URL.self) { urls, _ in
            Task { await library.add(urls) }
            return true
        } isTargeted: { targeted = $0 }
        .onAppear { if ProcessInfo.processInfo.environment["MACARCH_SELFTEST_HOVER"] != nil { targeted = true } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Drop RISC OS ROMs here")
    }

    @ViewBuilder private var content: some View {
        let layout = compact ? AnyLayout(HStackLayout(spacing: 16)) : AnyLayout(VStackLayout(spacing: 10))
        layout {
            Image(systemName: library.scanning ? "magnifyingglass" : "memorychip")
                .font(.system(size: compact ? 34 : 56, weight: .thin))
                .foregroundStyle(targeted ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .symbolEffect(.bounce, value: library.scans)
                .symbolEffect(.pulse, isActive: library.scanning)
                .frame(width: compact ? 44 : nil)
            VStack(alignment: compact ? .leading : .center, spacing: 4) {
                Text(library.scanning ? "Looking for ROMs…" : targeted ? "Drop to add" : "Drop RISC OS ROMs here")
                    .font(compact ? .headline : .title2.weight(.semibold))
                Text("A ROM image, its chip files (such as IC24–IC27), a folder of them, or a ZIP archive")
                    .font(compact ? .caption : .callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(compact ? .leading : .center)
                if !compact {
                    Button("Choose Files…") { Task { await library.chooseAndAdd() } }
                        .controlSize(.large)
                        .padding(.top, 8)
                }
            }
            if compact {
                Spacer(minLength: 0)
                Button("Choose…") { Task { await library.chooseAndAdd() } }
            }
        }
        .padding(compact ? 20 : 28)
    }
}

/// What the last drop turned up: ROMs added (and how sure we are of them)
/// and anything that wasn't a ROM, with the reason.
struct ROMResultsView: View {
    @State private var library = ROMLibrary.shared

    var body: some View {
        if !library.outcomes.isEmpty || !library.rejected.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(summary).font(.subheadline.weight(.semibold))
                    Spacer()
                    Button { withAnimation { library.clearResults() } } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary).help("Dismiss")
                }
                ForEach(library.outcomes) { o in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        TrustBadge(known: o.found.known)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(o.found.rom.versionString).font(.callout.weight(.medium))
                            Text((o.alreadyHad ? "Already in your ROMs · " : "Added · ") + "from " + o.found.origin)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                    }
                }
                ForEach(library.rejected) { r in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(r.name).font(.callout).lineLimit(1).truncationMode(.middle)
                            Text(r.reason).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(14)
            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    var summary: String {
        let added = library.outcomes.filter { !$0.alreadyHad }.count
        if library.outcomes.isEmpty { return "No ROMs found" }
        if added == 0 { return library.outcomes.count == 1 ? "You already have this ROM" : "You already have these ROMs" }
        return added == 1 ? "Added 1 ROM" : "Added \(added) ROMs"
    }
}

/// Known-good dump (its checksum is one MacArch knows) or recognised.
struct TrustBadge: View {
    var known: ROMImporter.Known?
    var body: some View {
        Image(systemName: known == nil ? "checkmark.circle.fill" : "checkmark.seal.fill")
            .foregroundStyle(known == nil ? Color.blue : Color.green)
            .help(known == nil
                  ? "Recognised: it starts like a RISC OS ROM and reads as \"RISC OS\" or \"Arthur\" throughout, but it isn't a dump MacArch has checked"
                  : "A known good dump: \(known!.title), \(known!.note)")
    }
}

/// The ROMs MacArch has, as cards; one can be selected.
struct ROMListView: View {
    @Binding var selection: String?
    /// When set, ROMs that can't drive this model say so.
    var model: MachineModel?
    var showsRemove = false
    @State private var settings = AppSettings.shared
    @State private var library = ROMLibrary.shared

    var body: some View {
        VStack(spacing: 8) {
            ForEach(settings.romLibrary) { entry in
                card(entry)
            }
        }
    }

    @ViewBuilder func card(_ entry: AppSettings.ROMEntry) -> some View {
        let d = library.detail(for: entry.path)
        let selected = selection == entry.path
        let unsuitable = model.map { m in d.map { !$0.models.contains(m) } ?? false } ?? false
        Button { selection = entry.path } label: {
            HStack(spacing: 12) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(d?.version ?? entry.version).font(.body.weight(.medium))
                        TrustBadge(known: d?.known).font(.caption)
                    }
                    Text(caption(d, unsuitable: unsuitable))
                        .font(.caption)
                        .foregroundStyle(unsuitable ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                }
                Spacer(minLength: 0)
                if showsRemove {
                    Button { library.remove(entry.path) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .help(d?.isCopy == true ? "Remove (MacArch's copy goes to the Trash)" : "Remove from the list (the file is left where it is)")
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .contentShape(Rectangle())
            .background(selected ? AnyShapeStyle(.tint.opacity(0.14)) : AnyShapeStyle(Color.primary.opacity(0.04)),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(selected ? AnyShapeStyle(.tint.opacity(0.7)) : AnyShapeStyle(Color.clear), lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)]) }
            Button("Remove") { library.remove(entry.path) }
        }
    }

    func caption(_ d: ROMLibrary.Detail?, unsuitable: Bool) -> String {
        guard let d else { return "Can't be read: the file has moved or changed" }
        var parts = [d.sizeKB >= 1024 ? "\(d.sizeKB / 1024) MB" : "\(d.sizeKB) KB"]
        parts.append(d.known != nil ? "Known good dump" : "Recognised")
        if unsuitable, let m = model { parts.append("Not for the \(m.displayName): it needs RISC OS 3") }
        else if d.models.count == MachineModel.allCases.count { parts.append("Every model") }
        else { parts.append("300 and 400 series, A540, A3000") }
        return parts.joined(separator: " · ")
    }
}

/// First run, or no usable ROM: pick a machine, add ROMs, switch on.
struct WelcomeView: View {
    let machine: MachineController
    @State private var settings = AppSettings.shared
    @State private var library = ROMLibrary.shared

    var body: some View {
        ZStack {
            WelcomeBackground()
            HStack(alignment: .top, spacing: 36) {
                hero.frame(width: 300)
                roms.frame(maxWidth: .infinity)
            }
            .padding(40)
        }
        .frame(minWidth: 900, minHeight: 600)
        .environment(\.colorScheme, .dark)
        .tint(Color(red: 0.25, green: 0.78, blue: 0.45))
        .animation(.spring(duration: 0.35), value: library.scans)
        .animation(.spring(duration: 0.35), value: settings.romLibrary.count)
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().interpolation(.high)
                .frame(width: 104, height: 104)
                .shadow(color: .black.opacity(0.4), radius: 12, y: 6)
            VStack(alignment: .leading, spacing: 6) {
                Text("MacArch").font(.system(size: 46, weight: .bold, design: .rounded))
                Text("The Acorn Archimedes, on your Mac").font(.title3).foregroundStyle(.secondary)
            }
            Text("MacArch needs a RISC OS ROM, which it can't include. Add ROM images you own: they're copied into MacArch's own folder, so the originals can go anywhere afterwards.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Model").gridColumnAlignment(.trailing)
                    Picker("Model", selection: Binding(get: { machine.model }, set: { m in
                        settings.model = m
                        machine.setHardware(model: m)
                    })) {
                        ForEach(MachineModel.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                }
                GridRow {
                    Text("Memory")
                    Picker("Memory", selection: Binding(get: { machine.ramKB }, set: { machine.setHardware(ramKB: $0) })) {
                        ForEach(machine.model.ramChoices, id: \.self) { Text(AppSettings.ramLabel($0)).tag($0) }
                    }
                }
                if machine.model.monitorChoices.count > 1 {
                    GridRow {
                        Text("Monitor")
                        Picker("Monitor", selection: Binding(get: { machine.monitor }, set: { machine.setHardware(monitor: $0) })) {
                            ForEach(machine.model.monitorChoices, id: \.self) { Text($0.displayName).tag($0) }
                        }
                    }
                }
            }
            .labelsHidden()
            .padding(16)
            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            Spacer(minLength: 0)
            if let e = machine.startError {
                Label(e, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(action: switchOn) {
                Label("Switch On", systemImage: "power")
                    .font(.title3.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(!canStart)
            Text(startHint)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var roms: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("ROMs").font(.title2.weight(.semibold))
                Spacer()
                if !settings.romLibrary.isEmpty {
                    Button("Show in Finder") {
                        try? FileManager.default.createDirectory(atPath: ROMLibrary.directory, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(URL(fileURLWithPath: ROMLibrary.directory))
                    }
                    .buttonStyle(.borderless).font(.callout)
                }
            }
            ROMDropZone(compact: !settings.romLibrary.isEmpty)
            ROMResultsView()
            if !settings.romLibrary.isEmpty {
                ScrollView {
                    ROMListView(selection: $settings.romPath, model: machine.model, showsRemove: true)
                        .padding(.bottom, 4)
                }
                .scrollIndicators(.automatic)
            } else {
                ROMGuide()
                Spacer(minLength: 0)
            }
        }
    }

    private var selectedDetail: ROMLibrary.Detail? { settings.romPath.flatMap { library.detail(for: $0) } }

    private var canStart: Bool {
        guard let d = selectedDetail else { return false }
        return d.models.contains(machine.model)
    }

    private var startHint: String {
        guard let d = selectedDetail else { return "Add a ROM to switch on." }
        if !d.models.contains(machine.model) { return "The \(machine.model.displayName) needs RISC OS 3: choose another ROM or model." }
        return "Starts the \(machine.model.displayName) with \(d.version). The first boot resets CMOS to RISC OS's defaults; after that your settings are kept."
    }

    private func switchOn() {
        guard let p = settings.romPath else { return }
        machine.start(romPath: p)
    }
}

/// Which ROM does what, shown until the first one is added.
struct ROMGuide: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            tile("RISC OS 3", "3.00 to 3.19, 2 MB. Runs every model, and the A5000, A3010, A3020 and A4000 need it.", "3.circle.fill")
            tile("RISC OS 2", "2.00 or 2.01, 512 KB. The 300 and 400 series, A540 and A3000; some early games want it.", "2.circle.fill")
            tile("Any shape", "One image, or the files of a chip set (IC24–IC27, say), loose, in a folder or zipped: MacArch works out how they fit.", "square.stack.3d.up.fill")
        }
    }

    func tile(_ title: String, _ text: String, _ symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: symbol).font(.title2).foregroundStyle(.tint).frame(height: 28)
            Text(title).font(.headline)
            Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// A dark backdrop with a faint pinstripe, after the RISC OS desktop.
struct WelcomeBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.07, green: 0.09, blue: 0.13), Color(red: 0.05, green: 0.14, blue: 0.13)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Canvas { ctx, size in
                var y: CGFloat = 0
                while y < size.height {
                    ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)), with: .color(.white.opacity(0.025)))
                    y += 4
                }
            }
            RadialGradient(colors: [Color(red: 0.2, green: 0.75, blue: 0.45).opacity(0.18), .clear],
                           center: .topLeading, startRadius: 0, endRadius: 520)
        }
        .ignoresSafeArea()
    }
}

/// Machine ▸ ROM ▸ Add ROMs…, Settings ▸ Machine ▸ Add ROMs…
struct ROMsWindowView: View {
    @State private var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ROMDropZone(compact: true)
            ROMResultsView()
            Text("Your ROMs").font(.headline)
            ScrollView {
                ROMListView(selection: $settings.romPath, showsRemove: true)
            }
            Text("The selected ROM is the one new windows start with; a window's own ROM is in its Machine menu. Added ROMs are copied into \(abbreviated(ROMLibrary.directory)).")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 480)
    }

    func abbreviated(_ p: String) -> String { (p as NSString).abbreviatingWithTildeInPath }
}
