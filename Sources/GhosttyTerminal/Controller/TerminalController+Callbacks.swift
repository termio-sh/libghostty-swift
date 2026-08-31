//
//  TerminalController+Callbacks.swift
//  libghostty-spm
//

import Foundation
import GhosttyKit

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

private enum TerminalCallbacks {
    static func wakeup(userdata: UnsafeMutableRawPointer?) {
        guard let userdata else { return }
        let controller = Unmanaged<TerminalController>.fromOpaque(userdata)
            .takeUnretainedValue()
        // One hop in flight at a time: a burst of wakeups from a streaming
        // process coalesces into the hop already queued (see
        // `beginWakeupDispatch`), which drains everything the burst raised.
        guard controller.beginWakeupDispatch() else { return }
        terminalRunOnMain {
            controller.handleWakeup()
        }
    }

    static func action(
        appPtr: ghostty_app_t?,
        target: ghostty_target_s,
        action: ghostty_action_s
    ) -> Bool {
        guard let appPtr else { return false }
        guard ghostty_app_userdata(appPtr) != nil else { return false }
        guard target.tag == GHOSTTY_TARGET_SURFACE else { return false }
        guard let surfacePtr = target.target.surface else { return false }
        guard let bridgePtr = ghostty_surface_userdata(surfacePtr) else { return false }

        let bridge = Unmanaged<TerminalCallbackBridge>
            .fromOpaque(bridgePtr)
            .takeUnretainedValue()
        terminalRunOnMain {
            bridge.handleAction(action)
        }

        return false
    }

    static func closeSurface(
        userdata: UnsafeMutableRawPointer?,
        processAlive: Bool
    ) {
        guard let userdata else { return }
        let bridge = Unmanaged<TerminalCallbackBridge>
            .fromOpaque(userdata)
            .takeUnretainedValue()
        terminalRunOnMain {
            bridge.handleClose(processAlive: processAlive)
        }
    }

    /// The system pasteboards this wrapper talks to are text-only, so any
    /// other MIME type is reported as unavailable rather than guessed at.
    private static func isTextMime(_ mime: String) -> Bool {
        mime == "text/plain" || mime.hasPrefix("text/plain;")
    }

    private static func pasteboardText() -> String? {
        #if canImport(UIKit)
            return UIPasteboard.general.string
        #elseif canImport(AppKit)
            return NSPasteboard.general.string(forType: .string)
        #else
            return nil
        #endif
    }

    private static func setPasteboardText(_ text: String) {
        #if canImport(UIKit)
            UIPasteboard.general.string = text
        #elseif canImport(AppKit)
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        #endif
    }

    static func writeClipboard(
        userdata _: UnsafeMutableRawPointer?,
        clipboard _: ghostty_clipboard_e,
        contents: UnsafePointer<ghostty_clipboard_content_s>?,
        contentsLen: Int,
        confirm _: Bool
    ) {
        guard let contents, contentsLen > 0 else { return }

        // Representations are binary-safe and carry an explicit length, so the
        // text one is decoded by length. Reading it as a C string would stop at
        // the first embedded NUL and run past the end when there is none.
        var text: String?
        for index in 0 ..< contentsLen {
            let content = contents[index]
            guard let mime = content.mime, isTextMime(String(cString: mime)) else { continue }
            guard let data = content.data else { continue }
            text = String(
                decoding: UnsafeRawBufferPointer(start: data, count: content.len),
                as: UTF8.self
            )
            break
        }

        guard let text else { return }
        setPasteboardText(text)
    }

    static func readClipboard(
        userdata: UnsafeMutableRawPointer?,
        clipboard _: ghostty_clipboard_e,
        opaquePtr: UnsafeMutableRawPointer?,
        mimes: UnsafePointer<UnsafePointer<CChar>?>?,
        mimesLen: Int,
        list: Bool
    ) -> ghostty_clipboard_read_result_e {
        guard let userdata, let opaquePtr else { return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED }

        let bridge = Unmanaged<TerminalCallbackBridge>
            .fromOpaque(userdata)
            .takeUnretainedValue()
        guard let surface = bridge.rawSurface else { return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED }

        guard let text = pasteboardText() else {
            TerminalDebugLog.log(.input, "clipboard paste read empty")
            return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE
        }

        // Serve only what was asked for, so an unrelated large representation
        // sitting on the pasteboard is never loaded.
        var served: [ClipboardRepresentation] = []
        var seen = Set<String>()
        if let mimes {
            for index in 0 ..< mimesLen {
                guard let pointer = mimes[index] else { continue }
                let mime = String(cString: pointer)
                guard !seen.contains(mime), isTextMime(mime) else { continue }
                seen.insert(mime)
                served.append(.init(mime: mime, bytes: Array(text.utf8)))
            }
        }

        let available = list ? ["text/plain"] : []
        guard !served.isEmpty || list else { return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE }

        TerminalDebugLog.log(
            .input,
            "clipboard paste read bytes=\(text.utf8.count) lines=\(TerminalInputText.lineCount(in: text))"
        )
        completeClipboardRequest(
            surface,
            contents: served,
            available: available,
            state: opaquePtr
        )
        TerminalDebugLog.log(.input, "clipboard paste complete")
        return GHOSTTY_CLIPBOARD_READ_STARTED
    }

    static func confirmReadClipboard(
        userdata: UnsafeMutableRawPointer?,
        confirm: UnsafePointer<ghostty_clipboard_confirm_s>?,
        opaquePtr: UnsafeMutableRawPointer?,
        request: ghostty_clipboard_request_e
    ) {
        guard let userdata, let opaquePtr else { return }

        let bridge = Unmanaged<TerminalCallbackBridge>
            .fromOpaque(userdata)
            .takeUnretainedValue()
        guard let surface = bridge.rawSurface else { return }

        guard let confirm else {
            ghostty_surface_deny_clipboard_request(surface, opaquePtr)
            return
        }
        let payload = confirm.pointee

        // The embedding app owns clipboard policy — this wrapper has no prompt
        // to show — so the confirmation completes with what libghostty offered.
        // The representations are borrowed for the length of this call, so they
        // are copied before completing.
        var served: [ClipboardRepresentation] = []
        if let contents = payload.contents {
            for index in 0 ..< payload.contents_len {
                let content = contents[index]
                guard let mime = content.mime else { continue }
                var bytes: [UInt8] = []
                if content.len > 0, let data = content.data {
                    bytes = Array(UnsafeRawBufferPointer(start: data, count: content.len))
                }
                served.append(.init(mime: String(cString: mime), bytes: bytes))
            }
        }

        var available: [String] = []
        if let listing = payload.available {
            for index in 0 ..< payload.available_len {
                guard let pointer = listing[index] else { continue }
                available.append(String(cString: pointer))
            }
        }

        TerminalDebugLog.log(
            .input,
            "clipboard paste confirm request=\(request.rawValue) representations=\(served.count)"
        )
        completeClipboardRequest(
            surface,
            contents: served,
            available: available,
            state: opaquePtr,
            confirmed: true
        )
        TerminalDebugLog.log(.input, "clipboard paste confirmed")
    }

    private struct ClipboardRepresentation {
        let mime: String
        let bytes: [UInt8]
    }

    private static func completeClipboardRequest(
        _ surface: ghostty_surface_t,
        contents: [ClipboardRepresentation],
        available: [String],
        state: UnsafeMutableRawPointer?,
        confirmed: Bool = false,
        remember: Bool = false
    ) {
        // libghostty copies out of this payload during the call, so the C
        // memory only has to outlive the call itself.
        var strings: [UnsafeMutablePointer<CChar>] = []
        var buffers: [UnsafeMutableRawPointer] = []
        defer {
            strings.forEach { free($0) }
            buffers.forEach { $0.deallocate() }
        }

        var cContents: [ghostty_clipboard_content_s] = []
        for entry in contents {
            guard let mime = strdup(entry.mime) else { continue }
            strings.append(mime)
            let buffer = UnsafeMutableRawPointer.allocate(
                byteCount: max(entry.bytes.count, 1),
                alignment: 1
            )
            buffers.append(buffer)
            entry.bytes.withUnsafeBytes { source in
                if let base = source.baseAddress {
                    buffer.copyMemory(from: base, byteCount: source.count)
                }
            }
            cContents.append(ghostty_clipboard_content_s(
                mime: mime,
                data: buffer.assumingMemoryBound(to: CChar.self),
                len: entry.bytes.count
            ))
        }

        var cAvailable: [UnsafePointer<CChar>?] = []
        for mime in available {
            guard let copy = strdup(mime) else { continue }
            strings.append(copy)
            cAvailable.append(UnsafePointer(copy))
        }

        cContents.withUnsafeBufferPointer { contentsBuffer in
            cAvailable.withUnsafeBufferPointer { availableBuffer in
                var complete = ghostty_clipboard_complete_s(
                    contents: contentsBuffer.baseAddress,
                    contents_len: contentsBuffer.count,
                    available: availableBuffer.baseAddress,
                    available_len: availableBuffer.count,
                    confirmed: confirmed,
                    remember: remember
                )
                ghostty_surface_complete_clipboard_request(surface, &complete, state)
            }
        }
    }
}

func terminalControllerWakeupCallback(userdata: UnsafeMutableRawPointer?) {
    TerminalCallbacks.wakeup(userdata: userdata)
}

func terminalControllerActionCallback(
    appPtr: ghostty_app_t?,
    target: ghostty_target_s,
    action: ghostty_action_s
) -> Bool {
    TerminalCallbacks.action(appPtr: appPtr, target: target, action: action)
}

func terminalControllerCloseSurfaceCallback(
    userdata: UnsafeMutableRawPointer?,
    processAlive: Bool
) {
    TerminalCallbacks.closeSurface(userdata: userdata, processAlive: processAlive)
}

func terminalControllerWriteClipboardCallback(
    userdata: UnsafeMutableRawPointer?,
    clipboard: ghostty_clipboard_e,
    contents: UnsafePointer<ghostty_clipboard_content_s>?,
    contentsLen: Int,
    confirm: Bool
) {
    TerminalCallbacks.writeClipboard(
        userdata: userdata,
        clipboard: clipboard,
        contents: contents,
        contentsLen: contentsLen,
        confirm: confirm
    )
}

func terminalControllerReadClipboardCallback(
    userdata: UnsafeMutableRawPointer?,
    clipboard: ghostty_clipboard_e,
    opaquePtr: UnsafeMutableRawPointer?,
    mimes: UnsafePointer<UnsafePointer<CChar>?>?,
    mimesLen: Int,
    list: Bool
) -> ghostty_clipboard_read_result_e {
    TerminalCallbacks.readClipboard(
        userdata: userdata,
        clipboard: clipboard,
        opaquePtr: opaquePtr,
        mimes: mimes,
        mimesLen: mimesLen,
        list: list
    )
}

func terminalControllerConfirmReadClipboardCallback(
    userdata: UnsafeMutableRawPointer?,
    confirm: UnsafePointer<ghostty_clipboard_confirm_s>?,
    opaquePtr: UnsafeMutableRawPointer?,
    request: ghostty_clipboard_request_e
) {
    TerminalCallbacks.confirmReadClipboard(
        userdata: userdata,
        confirm: confirm,
        opaquePtr: opaquePtr,
        request: request
    )
}
