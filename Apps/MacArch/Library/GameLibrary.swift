import AppKit
import ArchimedesCore
import Observation

/// The Game Library's state: the user's own games (My Games), and any
/// being added or edited. (After MacBeeb's ClassicsLibrary, without the
/// archive's shelves: there's no Archimedes archive to link to.)
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
        let groups = MyGames.group(urls)
        guard !groups.isEmpty else { return }
        Task {
            for group in groups {
                var disc: DiscFile?
                if let url = group.disc {
                    do {
                        disc = try await Task.detached { try MyGames.readDisc(at: url) }.value
                    } catch {
                        NSAlert(error: error).runModal()
                        continue
                    }
                }
                if let cover = group.cover {
                    do {
                        _ = try await Task.detached { try MyGames.checkCover(at: cover) }.value
                    } catch {
                        NSAlert(error: error).runModal()
                        if disc == nil { continue }
                        drafts.append(GameDraft(disc: disc, cover: nil))
                        continue
                    }
                }
                drafts.append(GameDraft(disc: disc, cover: group.cover))
            }
        }
    }

    /// Add Games…: disc images and pictures.
    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = MachineController.discTypes + [.image]
        panel.allowsOtherFileTypes = true
        panel.allowsMultipleSelection = true
        panel.message = "Choose floppy disc images and cover pictures. A disc and a picture with the same name make one game."
        guard panel.runModal() == .OK else { return }
        addFiles(panel.urls)
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
            NSAlert(error: error).runModal()
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
                    if game.discFile != nil, !confirmReplacingDisc(of: game) { return }
                    try await myGames.setDisc(file, for: game.id)
                }
                if let cover { try await myGames.setCover(cover, for: game.id) }
            } catch {
                NSAlert(error: error).runModal()
            }
            await refresh()
        }
        return true
    }

    func chooseDisc(for game: PersonalGame) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = MachineController.discTypes
        panel.allowsOtherFileTypes = true
        panel.message = "Choose the disc image for \(game.title)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        _ = attach([url], to: game)
    }

    func chooseCover(for game: PersonalGame) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.message = "Choose a cover picture for \(game.title)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        _ = attach([url], to: game)
    }

    private func confirmReplacingDisc(of game: PersonalGame) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Replace \(game.title)’s disc?"
        alert.informativeText = "MacArch’s copy of the old disc is deleted, with anything saved to it."
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Deletes one of My Games, after asking.
    func remove(_ game: PersonalGame) {
        let alert = NSAlert()
        alert.messageText = "Remove \(game.title) from My Games?"
        alert.informativeText = "MacArch’s copies of its disc and cover are deleted, with anything saved to the disc. The files you added it from aren’t touched."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            do { try await myGames.remove(id: game.id) } catch { NSAlert(error: error).runModal() }
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
