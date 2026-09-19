//
//  NSPasteboard+TerminalPaste.swift
//  libghostty-swift
//

#if canImport(AppKit) && !canImport(UIKit)
    import AppKit

    public extension NSPasteboard {
        /// What a paste should put into the terminal.
        ///
        /// A pasteboard item that carries a file reference becomes the path to
        /// that file; anything else contributes its text. Finder writes *both*
        /// — the URL and the basename as a string — and the string is what a
        /// naive read picks up, which is how a copied file used to arrive as a
        /// bare `example image.png` with its location gone. On a multi-select
        /// it is worse than lossy: Finder concatenates the basenames with no
        /// separator, so two files became one unusable token.
        ///
        /// Ghostty's own app resolves this the same way, per pasteboard item,
        /// joined by spaces. The quoting differs on purpose — see
        /// `shellQuoted` — and file references gain a trailing space so typing
        /// can continue after the path. Plain text is handed over untouched:
        /// adding anything to it would corrupt an ordinary paste.
        func terminalPasteText() -> String? {
            var pieces: [String] = []
            var sawFileReference = false
            for item in pasteboardItems ?? [] {
                if let url = item.fileURL {
                    sawFileReference = true
                    pieces.append(Self.shellQuoted(url.path))
                } else if let text = item.string(forType: .string) {
                    pieces.append(text)
                }
            }
            guard !pieces.isEmpty else { return nil }
            let joined = pieces.joined(separator: " ")
            return sawFileReference ? joined + " " : joined
        }

        /// POSIX single-quoting, which is what a dropped file already inserts
        /// (the host app's own drop path uses these tokens). Ghostty instead
        /// backslash-escapes a fixed character set; single quotes are chosen
        /// here because the two ways of putting a path into a terminal —
        /// dropping it and pasting it — have to agree, and because quoting
        /// covers every metacharacter rather than an enumerated list.
        static func shellQuoted(_ value: String) -> String {
            "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
    }

    private extension NSPasteboardItem {
        /// The item's file reference, or nil. Read through the property list
        /// rather than the string flavor: a string that merely looks like a
        /// `file://` URL is text somebody copied, not a file somebody copied.
        var fileURL: URL? {
            guard let plist = propertyList(forType: .fileURL),
                  let url = NSURL(pasteboardPropertyList: plist, ofType: .fileURL) as URL?,
                  url.isFileURL
            else { return nil }
            return url.standardizedFileURL
        }
    }
#endif
