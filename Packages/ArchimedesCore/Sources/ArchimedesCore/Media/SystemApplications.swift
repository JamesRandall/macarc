import Foundation

/// The two applications a RISC OS 3.1 hard disc needs in its root directory,
/// set up as Acorn's own were (their 0.56 !System and 0.58 !Scrap, from
/// January 1992), but written for MacArch: the files, help text and icons
/// here are new, not copied from Acorn's discs.
///
/// - !System holds modules that applications share, in !System.Modules.
///   Applications find them through System:Modules (System$Path), and
///   installers such as Acorn C/C++'s add theirs to <System$Dir>.Modules.
/// - !Scrap is where applications put a document while passing it to
///   another (Wimp$Scrap) and keep other temporary files (Wimp$ScrapDir).
///
/// Neither ROM sets these variables; the Filer runs each application's
/// !Boot the first time it shows the directory holding it. As with Acorn's,
/// !Boot only sets a variable that isn't already set, so the first !System
/// or !Scrap seen is the one used; double-clicking one (its !Run) makes it
/// the one used.
public enum SystemApplications {
    /// The files and (empty) directories, under !System and !Scrap.
    public static func items(date: Date = Date()) -> (items: [ADFSHardDiscBuilder.Item], directories: [[String]]) {
        func obey(_ app: String, _ name: String, _ lines: [String]) -> ADFSHardDiscBuilder.Item {
            .init(path: [app, name], data: Array((lines.joined(separator: "\n") + "\n").utf8), type: 0xFEB, date: date)
        }
        func text(_ app: String, _ name: String, _ s: String) -> ADFSHardDiscBuilder.Item {
            .init(path: [app, name], data: Array(s.utf8), type: 0xFFF, date: date)
        }
        func sprites(_ app: String, _ name: String, _ mode: UInt32, _ rows: [String]) -> ADFSHardDiscBuilder.Item {
            .init(path: [app, name], data: spriteFile(name: app.lowercased(), mode: mode, rows: rows), type: 0xFF9, date: date)
        }
        let items: [ADFSHardDiscBuilder.Item] = [
            obey("!System", "!Boot", [
                "| !System: modules shared by applications, in System:Modules.",
                "| The first !System the Filer sees is used; double-click another to use it.",
                "IconSprites <Obey$Dir>.!Sprites",
                "If \"<System$Dir>\" = \"\" Then Set System$Dir <Obey$Dir>",
                "If \"<System$Path>\" = \"\" Then Set System$Path <System$Dir>.",
            ]),
            obey("!System", "!Run", [
                "| !System: use this one for System:Modules.",
                "IconSprites <Obey$Dir>.!Sprites",
                "Set System$Dir <Obey$Dir>",
                "Set System$Path <System$Dir>.",
            ]),
            text("!System", "!Help", systemHelp),
            sprites("!System", "!Sprites", 12, halfHeight(systemIcon)),
            sprites("!System", "!Sprites22", 20, systemIcon),
            obey("!Scrap", "!Boot", [
                "| !Scrap: where applications put files they pass to each other.",
                "| The first !Scrap the Filer sees is used; double-click another to use it.",
                "IconSprites <Obey$Dir>.!Sprites",
                "If \"<Wimp$ScrapDir>\" = \"\" Then Set Wimp$ScrapDir <Obey$Dir>.ScrapDir",
                "If \"<Wimp$Scrap>\" = \"\" Then Set Wimp$Scrap <Wimp$ScrapDir>.ScrapFile",
            ]),
            obey("!Scrap", "!Run", [
                "| !Scrap: use this one for files passed between applications.",
                "IconSprites <Obey$Dir>.!Sprites",
                "Set Wimp$ScrapDir <Obey$Dir>.ScrapDir",
                "Set Wimp$Scrap <Wimp$ScrapDir>.ScrapFile",
            ]),
            text("!Scrap", "!Help", scrapHelp),
            sprites("!Scrap", "!Sprites", 12, halfHeight(scrapIcon)),
            sprites("!Scrap", "!Sprites22", 20, scrapIcon),
        ]
        return (items, [["!System", "Modules"], ["!Scrap", "ScrapDir"]])
    }

    static let systemHelp = """
        !System
        =======

        !System holds the relocatable modules that applications share, in
        its Modules directory. Applications load them from there when they
        need them: you don't need to do anything, except let the Filer see
        !System once after you switch on, by opening the directory that
        holds it.

        If an application says "Filing system or path System: not present",
        open the directory holding !System and try again.

        If an application says it needs a later version of a module, that
        module isn't in !System.Modules, or is older than it needs. Installers
        (Acorn C/C++'s, for example) copy their modules in for you.

        If there is more than one !System, the first one the Filer sees is
        used. Double-click a !System to use that one instead.

        """

    static let scrapHelp = """
        !Scrap
        ======

        !Scrap is where applications keep a document while passing it to
        another application, and where some keep other temporary files.
        Let the Filer see it once after you switch on, by opening the
        directory that holds it.

        If an application says it can't transfer a file and suggests setting
        Wimp$Scrap, open the directory holding !Scrap and try again.

        !Scrap must be somewhere applications can write: not on a
        write-protected floppy disc. If there is more than one !Scrap, the
        first one the Filer sees is used. Double-click a !Scrap to use that
        one instead.

        """

    // The icons, 34 by 34 square pixels in the Wimp's 16 colours (0 white,
    // 1-6 greys, 7 black, 8 dark blue, 9 yellow, 10 green, 11 red, 12 cream,
    // 13 dark green, 14 orange, 15 light blue); "." is transparent.
    // !Sprites (mode 12, for standard monitors) keeps every other row.

    /// A chip: a black package with grey legs above and below, a notch at
    /// one corner and a white mark.
    static let systemIcon: [String] = (0..<34).map { y in
        String((0..<34).map { x -> Character in
            let body = (5...28).contains(x) && (9...24).contains(y)
            if body {
                if x == 5 || x == 28 || y == 9 || y == 24 { return "6" }   // edge
                if x - 5 + y - 9 < 4 { return "4" }                          // the notch
                if (12...16).contains(y) && (14...19).contains(x) { return (y == 12 || y == 16 || x == 14 || x == 19) ? "0" : "7" }
                return "7"
            }
            let leg = (7...26).contains(x) && (x - 7) % 4 < 2
            if leg && ((4...8).contains(y) || (25...29).contains(y)) { return "2" }
            return "."
        })
    }

    /// A sheet of paper, its top right corner turned down, with lines of writing.
    static let scrapIcon: [String] = (0..<34).map { y in
        String((0..<34).map { x -> Character in
            let left = 6, right = 27, top = 2, bottom = 31, fold = 8
            guard (left...right).contains(x), (top...bottom).contains(y) else { return "." }
            let cut = right - fold + (y - top)          // the fold's diagonal, at this row
            if y - top < fold && x > cut { return "." }     // above the fold: no paper
            if y - top < fold && x == cut { return "7" }
            if y - top == fold && x >= right - fold { return "7" }            // the flap's lower edge
            if y - top < fold && x > right - fold && x < cut { return "2" }   // the turned-down flap
            if x == left || x == right || y == top || y == bottom || (y - top < fold && x == right - fold) { return "7" }
            if y > top + fold + 1 && y < bottom - 2 && (y - top) % 3 == 0 && x > left + 2 && x < right - 2 - (y % 2 == 0 ? 5 : 0) { return "4" }
            return "0"
        })
    }

    /// Every other row, for rectangular-pixel modes such as mode 12.
    static func halfHeight(_ rows: [String]) -> [String] { stride(from: 0, to: rows.count, by: 2).map { rows[$0] } }

    /// A sprite file (a sprite area without its first word) holding one
    /// 16-colour sprite with a mask, in `mode`. Each row of `rows` is a pixel
    /// row; characters are hex Wimp colours, "." is transparent.
    static func spriteFile(name: String, mode: UInt32, rows: [String]) -> [UInt8] {
        let width = rows.map(\.count).max() ?? 0, height = rows.count
        let words = (width * 4 + 31) / 32
        var image = [UInt8](), mask = [UInt8]()
        for row in rows {
            var pixels = Array(row)
            pixels += Array(repeating: ".", count: width - pixels.count)
            var i = [UInt8](repeating: 0, count: words * 4), m = i
            for (x, c) in pixels.enumerated() where c != "." {
                let v = UInt8(String(c), radix: 16) ?? 7
                i[x / 2] |= x % 2 == 0 ? v : v << 4
                m[x / 2] |= x % 2 == 0 ? 0x0F : 0xF0
            }
            image += i; mask += m
        }
        func word(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)] }
        let header = 44
        var sprite = word(UInt32(header + image.count + mask.count))
        sprite += Array(name.utf8.prefix(12)) + [UInt8](repeating: 0, count: 12 - min(12, name.utf8.count))
        sprite += word(UInt32(words - 1)) + word(UInt32(height - 1)) + word(0) + word(UInt32((width * 4 - 1) % 32))
        sprite += word(UInt32(header)) + word(UInt32(header + image.count)) + word(mode)
        sprite += image + mask
        return word(1) + word(16) + word(UInt32(16 + sprite.count)) + sprite
    }
}
