#if canImport(AppKit) && !canImport(UIKit)
    import AppKit
    @testable import GhosttyTerminal
    import XCTest

    /// What a paste puts into the terminal.
    ///
    /// The failure this guards is silent and total: a copied file whose
    /// location is dropped arrives as a bare basename, and an agent asked to
    /// open it has nothing to open.
    final class NSPasteboardTerminalPasteTests: XCTestCase {
        private var pasteboard: NSPasteboard!

        override func setUp() {
            super.setUp()
            pasteboard = NSPasteboard(name: .init("libghostty-paste-\(UUID().uuidString)"))
            pasteboard.clearContents()
        }

        override func tearDown() {
            pasteboard.releaseGlobally()
            pasteboard = nil
            super.tearDown()
        }

        /// Writes a file the way Finder does: the URL *and* the basename as
        /// text, which is the pair that used to resolve to the basename.
        private func writeFinderCopy(_ paths: [String]) {
            pasteboard.clearContents()
            let items: [NSPasteboardItem] = paths.map { path in
                let item = NSPasteboardItem()
                // The `.fileURL` flavor is the absolute string, the same shape
                // `writeObjects([NSURL])` and Finder itself produce.
                // `setPropertyList` would binary-plist-encode it instead, and
                // the read would see a corrupted URL.
                item.setString(URL(fileURLWithPath: path).absoluteString, forType: .fileURL)
                item.setString((path as NSString).lastPathComponent, forType: .string)
                return item
            }
            XCTAssertTrue(pasteboard.writeObjects(items))
        }

        func testACopiedFileYieldsItsPathNotItsName() {
            writeFinderCopy(["/Users/example/Desktop/example image.png"])
            XCTAssertEqual(
                pasteboard.terminalPasteText(),
                "'/Users/example/Desktop/example image.png' "
            )
        }

        /// Finder concatenates basenames with no separator on a multi-select,
        /// so the old read produced one unusable token.
        func testEachCopiedFileIsItsOwnQuotedArgument() {
            writeFinderCopy([
                "/Users/example/Desktop/example image.png",
                "/Users/example/Desktop/it's fine.txt",
            ])
            XCTAssertEqual(
                pasteboard.terminalPasteText(),
                "'/Users/example/Desktop/example image.png' '/Users/example/Desktop/it'\\''s fine.txt' "
            )
        }

        func testOrdinaryTextIsHandedOverUntouched() {
            pasteboard.clearContents()
            pasteboard.setString("echo hello", forType: .string)
            XCTAssertEqual(pasteboard.terminalPasteText(), "echo hello")
        }

        /// A trailing space after a path lets typing continue; adding one to an
        /// ordinary paste would corrupt it.
        func testOnlyAFilePasteGainsATrailingSpace() {
            pasteboard.clearContents()
            pasteboard.setString("/Users/example/Desktop/example image.png", forType: .string)
            let text = pasteboard.terminalPasteText()
            XCTAssertEqual(text, "/Users/example/Desktop/example image.png")
            XCTAssertFalse(text?.hasSuffix(" ") == true, "text that looks like a path is still text")
        }

        func testAnEmptyPasteboardHasNothingToPaste() {
            XCTAssertNil(pasteboard.terminalPasteText())
        }

        func testQuotingSurvivesShellMetacharacters() {
            for path in [
                "/tmp/cost$file.txt", "/tmp/weird`name.txt", "/tmp/run;me.txt",
                "/tmp/a b(c).txt", "/Users/example/桌面/图片.png",
            ] {
                writeFinderCopy([path])
                XCTAssertEqual(pasteboard.terminalPasteText(), "'\(path)' ", path)
            }
        }
    }
#endif
