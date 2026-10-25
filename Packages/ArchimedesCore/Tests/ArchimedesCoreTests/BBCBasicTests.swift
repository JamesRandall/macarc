import XCTest
@testable import ArchimedesCore

final class BBCBasicTests: XCTestCase {
    static let sample = [
        "10 REM Hello: \"world\"",
        "20 A%=&FF:B=1.5E3:C$=\"PRINT\":DIM D%(3),E(2,2)",
        "30 FOR I%=1 TO 10 STEP 2:PRINT I%;:NEXT",
        "40 IF A%>3 THEN PRINT \"YES\" ELSE PRINT \"NO\"",
        "50 IF A% THEN 100 ELSE 200",
        "60 GOTO 30:GOSUB 1000:RESTORE 20",
        "70 PROCdraw(1,2):X=FNsum(3)",
        "80 CASE A% OF",
        "90 WHEN 1,2:PRINT \"one\"",
        "100 OTHERWISE PRINT \"other\"",
        "110 ENDCASE",
        "120 WHILE A%<10:A%+=1:ENDWHILE",
        "130 IF A%=1 THEN",
        "140 PRINT 1",
        "150 ELSE",
        "160 PRINT 2",
        "170 ENDIF",
        "180 SYS \"OS_Write0\",A%:SWAP A%,B%",
        "190 CIRCLE FILL 100,100,50:RECTANGLE 0,0,10,10:ELLIPSE 1,2,3,4:ORIGIN 0,0",
        "200 MOUSE X%,Y%,B%:WAIT:TINT 1,2:POINT 1,2:Z=POINT(1,2)",
        "210 TIME=0:PAGE=&9000:T=TIME:P=PAGE:LOMEM=LOMEM",
        "220 DATA 1,2,PRINT",
        "230 PRINT LEFT$(A$,2)+MID$(A$,1,2)+RIGHT$(A$,1)+STRING$(3,\"x\")+STR$(4)+CHR$(65)",
        "240 *CAT",
        "250 X=SUM(D%()):Y=SUMLEN(C$())",
        "260 ON ERROR PRINT REPORT$:END",
        "270 LOCAL ERROR:ON ERROR LOCAL PRINT ERR,ERL",
        "280 ENDPROC:QUIT:END",
        "290 TRUEX=1:ENDX=2:PI=3",
        "300 DEF PROCdraw(a,b):LOCAL c:c=a*b DIV 2 MOD 3:ENDPROC",
        "310 DEF FNsum(n)=n+1",
        "320 SOUND 1,-15,100,10:ENVELOPE 1,2,3,4,5,6,7,8,9,10,11,12,13,14:BEATS 4:TEMPO 100:VOICES 4:VOICE 1,\"WaveSynth\":STEREO 1,0",
        "330 INSTALL \"Lib\":LIBRARY \"Lib\":OVERLAY a$()",
        "340 OSCLI \"CAT\":CALL &8000:A=USR(&8000)",
        "350 REPEAT:UNTIL TRUE OR FALSE AND NOT EOF#1",
        "360 VDU 7:CLS:CLG:COLOUR 1:GCOL 0,1:MODE 12:MOVE 0,0:DRAW 1,1:PLOT 85,1,1",
    ]

    func testListingRoundTrips() throws {
        let program = try BBCBasic.tokenise(Self.sample.joined(separator: "\n"))
        XCTAssertTrue(BBCBasic.isProgram(program))
        let listed = BBCBasic.list(program).split(separator: "\n").map(String.init)
        XCTAssertEqual(listed, Self.sample)
    }

    /// The interpreter itself tokenises each line as BBCBasic does.
    func testTokenisingMatchesBASICV() throws {
        guard let dir = GameSmokeTests.romDir("riscos3_11") else { throw XCTSkip("RISC OS 3.11 ROM not present") }
        var c = MachineConfiguration()
        c.romPaths = [dir]
        c.powerOnKeys = [0x34]
        let m = try Machine(configuration: c)
        m.powerOn()
        m.run(seconds: 20)
        m.keyDown(0x0C); m.run(seconds: 0.1); m.keyUp(0x0C)
        m.run(seconds: 0.5)
        func type(_ t: String) { m.scheduleTyping(t, startingAt: m.nominalTicks, intervalMs: 25); m.run(seconds: Double(t.count) * 0.055 + 0.4) }
        type("BASIC\r")
        for line in Self.sample { type(line + "\r") }
        func b(_ a: Int) -> UInt8 { m.memc.debugRead(UInt32(a), space: .logical) ?? 0 }
        func w(_ a: Int) -> Int { Int(b(a)) | Int(b(a + 1)) << 8 | Int(b(a + 2)) << 16 | Int(b(a + 3)) << 24 }
        let page = w(0x8700 - 0x94), top = w(0x8700 - 0x90)
        let actual = (page..<top).map(b)
        let expected = try BBCBasic.tokenise(Self.sample.joined(separator: "\n"))
        // Line by line, for a readable failure.
        func lines(_ p: [UInt8]) -> [[UInt8]] {
            var out: [[UInt8]] = []
            var i = 0
            while i + 3 < p.count, p[i] == 0x0D, p[i + 1] != 0xFF { out.append(Array(p[i..<i + Int(p[i + 3])])); i += Int(p[i + 3]) }
            return out
        }
        let a = lines(actual), e = lines(expected)
        XCTAssertEqual(a.count, e.count)
        for (x, y) in zip(a, e) where x != y {
            XCTFail("line \(Int(x[1]) << 8 | Int(x[2])): BASIC \(x.map { String(format: "%02X", $0) }.joined(separator: " "))\n ours \(y.map { String(format: "%02X", $0) }.joined(separator: " "))")
        }
    }
}
