//
//  AppTerminalView+NSTextInputClient.swift
//  libghostty-spm
//
//  Created by Lakr233 on 2026/3/17.
//

#if canImport(AppKit) && !canImport(UIKit)
    import AppKit

    extension AppTerminalView: @preconcurrency NSTextInputClient {
        open func insertText(_ string: Any, replacementRange _: NSRange) {
            inputHandler?.inputMethodHandler?.insertText(string)
        }

        open func setMarkedText(
            _ string: Any,
            selectedRange: NSRange,
            replacementRange _: NSRange
        ) {
            inputHandler?.inputMethodHandler?.setMarkedText(
                string,
                selectedRange: selectedRange
            )
        }

        open func unmarkText() {
            inputHandler?.inputMethodHandler?.unmarkText()
        }

        open func selectedRange() -> NSRange {
            inputHandler?.inputMethodHandler?.currentSelectedRange()
                ?? NSRange(location: NSNotFound, length: 0)
        }

        open func markedRange() -> NSRange {
            inputHandler?.inputMethodHandler?.markedRange()
                ?? NSRange(location: NSNotFound, length: 0)
        }

        open func hasMarkedText() -> Bool {
            inputHandler?.inputMethodHandler?.hasMarkedText ?? false
        }

        open func attributedSubstring(
            forProposedRange range: NSRange,
            actualRange: NSRangePointer?
        ) -> NSAttributedString? {
            inputHandler?.inputMethodHandler?.attributedSubstring(
                forProposedRange: range,
                actualRange: actualRange
            )
        }

        open func validAttributesForMarkedText() -> [NSAttributedString.Key] {
            []
        }

        open func firstRect(
            forCharacterRange _: NSRange,
            actualRange _: NSRangePointer?
        ) -> NSRect {
            guard let surface else { return .zero }

            let point = surface.imePoint()
            // Ghostty reports the cursor cell's BOTTOM edge in top-left
            // coordinates, so flipping it alone already lands on the rect's
            // AppKit origin. Subtracting the cell height again drops the rect
            // onto the next line down, which pushes the candidate window a line
            // too low -- and onto the text being typed once it has to flip up
            // for lack of room below.
            let viewRect = NSRect(
                x: point.x,
                y: bounds.height - point.y,
                width: point.width,
                height: point.height
            )

            guard let window else { return viewRect }
            let windowRect = convert(viewRect, to: nil)
            return window.convertToScreen(windowRect)
        }

        open func characterIndex(for _: NSPoint) -> Int {
            NSNotFound
        }
    }
#endif
