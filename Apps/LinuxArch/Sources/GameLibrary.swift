import ArchimedesCore
import CGtk
import Foundation
import Observation

/// My Games' state: the user's own games, and any being added or edited.
/// (The Archimedes Classics are ClassicsLibrary's.) The Mac app's, with
/// GTK's dialogs.
@MainActor
@Observable
final class GameLibrary {
    static let shared = GameLibrary()

    @ObservationIgnored let myGames: MyGames
    private(set) var personalGames: [PersonalGame] = []
    /// Games being added or edited, a sheet each, in turn.
    var drafts: [GameDraft] = []

    init(root: URL = MyGames.defaultRoot) {
        myGames = MyGames(root: root)
        Task { await refresh() }
    }

    func refresh() async {
        personalGames = await myGames.games
    }

    func game(id: UUID) -> PersonalGame? { personalGames.first { $0.id == id } }

    // MARK: Adding

    /// Adds dropped or chosen files: discs and pictures become games, whose
    /// details the user fills in.
    func addFiles(_ urls: [URL]) {
        Task {
            // The Classics' discs go to them; anything else is My Games'.
            let groups = MyGames.group(await ClassicsLibrary.shared.add(urls))
            for group in groups {
                var disc: DiscFile?
                if let url = group.disc {
                    do {
                        disc = try await Task.detached { try MyGames.readDisc(at: url) }.value
                    } catch {
                        Alerts.show(error, parent: frontWindow)
                        continue
                    }
                }
                if let cover = group.cover {
                    do {
                        _ = try await Task.detached { try MyGames.checkCover(at: cover) }.value
                    } catch {
                        Alerts.show(error, parent: frontWindow)
                        if disc == nil { continue }
                        drafts.append(GameDraft(disc: disc, cover: nil))
                        continue
                    }
                }
                drafts.append(GameDraft(disc: disc, cover: group.cover))
            }
        }
    }

    static let coverFilter = FileDialogs.Filter(name: "Pictures", suffixes: Array(MyGames.coverExtensions).sorted())

    /// Add Games…: disc images and pictures (a disc and a picture with the
    /// same name make one game).
    func chooseFiles(parent: Widget?) {
        let filter = FileDialogs.Filter(name: "Disc images and pictures",
                                        suffixes: MachineController.discFilter.suffixes + Self.coverFilter.suffixes + ["zip"])
        FileDialogs.openMultiple(parent: parent, title: "Add Games (the Classics’ discs, or your own discs and cover pictures)",
                                 filters: [filter, MachineController.discFilter, Self.coverFilter]) { urls in
            self.addFiles(urls)
        }
    }

    func edit(_ game: PersonalGame) {
        drafts.append(GameDraft(editing: game, discName: game.discFile.map { _ in game.title }, cover: myGames.coverURL(game)))
    }

    /// Saves a draft: a new game, or changes to one.
    func save(_ draft: GameDraft) async -> Bool {
        do {
            if draft.isNew {
                try await myGames.add(draft.game, disc: draft.disc, cover: draft.newCover)
            } else {
                try await myGames.update(draft.game)
                if let disc = draft.disc { try await myGames.setDisc(disc, for: draft.game.id) }
                if let cover = draft.newCover { try await myGames.setCover(cover, for: draft.game.id) }
            }
        } catch {
            Alerts.show(error, parent: frontWindow)
            return false
        }
        drafts.removeAll { $0.id == draft.id }
        await refresh()
        return true
    }

    func cancel(_ draft: GameDraft) {
        drafts.removeAll { $0.id == draft.id }
    }

    /// Files dropped on a game: a disc image gives it its disc, a picture
    /// its cover.
    func attach(_ urls: [URL], to game: PersonalGame) -> Bool {
        let disc = urls.first(where: MyGames.isDiscName)
        let cover = urls.first(where: MyGames.isCoverName)
        guard disc != nil || cover != nil else { return false }
        Task {
            do {
                if let disc {
                    let file = try await Task.detached { try MyGames.readDisc(at: disc) }.value
                    if game.discFile != nil, !(await confirmReplacingDisc(of: game)) { return }
                    try await myGames.setDisc(file, for: game.id)
                }
                if let cover { try await myGames.setCover(cover, for: game.id) }
            } catch {
                Alerts.show(error, parent: frontWindow)
            }
            await refresh()
        }
        return true
    }

    func chooseDisc(for game: PersonalGame, parent: Widget?) {
        FileDialogs.open(parent: parent, title: "The Disc Image for \(game.title)", filters: [MachineController.discFilter]) { url in
            _ = self.attach([url], to: game)
        }
    }

    func chooseCover(for game: PersonalGame, parent: Widget?) {
        FileDialogs.open(parent: parent, title: "A Cover Picture for \(game.title)", filters: [Self.coverFilter]) { url in
            _ = self.attach([url], to: game)
        }
    }

    private func confirmReplacingDisc(of game: PersonalGame) async -> Bool {
        await Alerts.confirm("Replace \(game.title)’s disc?", "LinuxArch’s copy of the old disc is deleted, with anything saved to it.",
                             button: "Replace", parent: frontWindow)
    }

    /// Deletes one of My Games, after asking.
    func remove(_ game: PersonalGame) {
        Task {
            guard await Alerts.confirm("Remove \(game.title) from My Games?",
                                       "LinuxArch’s copies of its disc and cover are deleted, with anything saved to the disc. The files you added it from aren’t touched.",
                                       button: "Remove", destructive: true, parent: frontWindow) else { return }
            do { try await myGames.remove(id: game.id) } catch { Alerts.show(error, parent: frontWindow) }
            await refresh()
        }
    }
}

/// One of My Games being added or edited: its details, and any disc or
/// cover to copy in when it's saved.
struct GameDraft: Identifiable {
    var game: PersonalGame
    var isNew: Bool
    /// A disc to copy in.
    var disc: DiscFile?
    /// A picture to copy in.
    var newCover: URL?
    /// What the game has already (when editing).
    var existingDiscName: String?
    var existingCover: URL?

    var id: UUID { game.id }

    /// A new game, with its details guessed from its disc's name.
    init(disc: DiscFile?, cover: URL?) {
        var game = PersonalGame(title: disc?.suggestedTitle ?? cover.map { $0.deletingPathExtension().lastPathComponent } ?? "")
        game.year = disc?.suggestedYear
        if let disc { game.start = disc.suggestedStart }
        self.game = game
        isNew = true
        self.disc = disc
        newCover = cover
    }

    init(editing game: PersonalGame, discName: String?, cover: URL?) {
        self.game = game
        isNew = false
        existingDiscName = discName
        existingCover = cover
    }

    var hasDisc: Bool { disc != nil || existingDiscName != nil }
    /// The cover to show: the new one, or the one it has.
    var shownCover: URL? { newCover ?? existingCover }
}
