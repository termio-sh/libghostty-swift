//
//  InMemoryTerminalSession.swift
//  libghostty-spm
//
//  Created by Lakr233 on 2026/3/16.
//

import Foundation
import GhosttyKit

public final class InMemoryTerminalSession: @unchecked Sendable {
    /// Guards `surface`, `pendingPreSurface`, and `surfaceUses`. Never held
    /// across a call into libghostty: `ghostty_surface_write_buffer` parses
    /// on the calling thread and can block until the surface's io thread
    /// drains a reply mailbox, and that same io thread calls back into
    /// `dispatchResize` as it starts up. One lock on both sides of that
    /// exchange is a deadlock — the reader holds it waiting for the io
    /// thread, the io thread waits for the lock — and every main-thread
    /// caller of `readViewportText` or `dispatchResize` then hangs behind
    /// them. That was the termio beachball of 2026-08-29.
    private let state = NSCondition()
    private var surface: ghostty_surface_t?
    /// Calls into libghostty currently holding `surface`. `clearSurface`
    /// waits for this to reach zero so the caller can free the surface.
    private var surfaceUses = 0
    /// Host output received before a surface has attached. The read pump is
    /// armed the instant the child is spawned, but the ghostty surface is not
    /// built until the view mounts a turn later — so the shell's first prompt
    /// can arrive before `setSurface`. Buffer it here instead of dropping it,
    /// and flush it the moment a surface attaches (see `setSurface`).
    private var pendingPreSurface = Data()
    /// Safety cap on the pre-surface buffer so a surface that never attaches
    /// cannot grow it without bound. A cold-start prompt is a few hundred
    /// bytes; this only bites pathological cases. Oldest bytes drop first.
    private static let pendingPreSurfaceCap = 1 << 20 // 1 MB
    /// Serializes writers only, so the pre-surface flush lands strictly before
    /// any live byte that arrives after attach. It is held across
    /// `ghostty_surface_write_buffer`, which is safe: nothing libghostty
    /// calls back into takes it.
    private let writeLock = NSLock()
    /// Guards `lastResize` alone, so the io thread's resize callback never
    /// waits on a parse.
    private let resizeLock = NSLock()
    private var lastResize: InMemoryTerminalViewport?
    private let writeHandler: @Sendable (Data) -> Void
    private let resizeHandler: @Sendable (InMemoryTerminalViewport) -> Void

    public init(
        write: @escaping @Sendable (Data) -> Void,
        resize: @escaping @Sendable (InMemoryTerminalViewport) -> Void
    ) {
        writeHandler = write
        resizeHandler = resize
    }

    // MARK: - Surface Lifecycle

    func setSurface(_ surface: ghostty_surface_t?) {
        state.lock()
        self.surface = surface
        state.unlock()
        TerminalDebugLog.log(
            .lifecycle,
            "in-memory session surface=\(surface == nil ? "nil" : "set")"
        )
        // Flush anything the host sent before the surface existed — the shell's
        // first prompt at cold start. `write` drains the pre-surface buffer
        // ahead of its own bytes under `writeLock`, so the flush is written
        // strictly before any live byte that arrives after attach.
        if surface != nil {
            write(Data())
        }
    }

    func clearSurface(ifMatches expectedSurface: ghostty_surface_t?) {
        state.lock()
        defer { state.unlock() }

        guard surface == expectedSurface else {
            TerminalDebugLog.log(
                .lifecycle,
                "in-memory session clear skipped expected=\(expectedSurface == nil ? "nil" : "set") current=\(surface == nil ? "nil" : "set")"
            )
            return
        }

        surface = nil
        // The caller frees the surface next. A `receive` mid-parse still holds
        // the pointer; let it return first. Nothing new can start once
        // `surface` is nil, so this only waits out the parse already running.
        while surfaceUses > 0 {
            state.wait()
        }
        TerminalDebugLog.log(.lifecycle, "in-memory session surface=nil matched")
    }

    var currentSurface: ghostty_surface_t? {
        state.lock()
        defer { state.unlock() }
        return surface
    }

    /// Runs `body` against the attached surface, keeping the surface from
    /// being freed underneath it without holding any lock across the call.
    /// Returns `nil` when no surface is attached.
    private func withSurface<T>(_ body: (ghostty_surface_t) -> T) -> T? {
        state.lock()
        guard let surface else {
            state.unlock()
            return nil
        }
        surfaceUses += 1
        state.unlock()
        defer {
            state.lock()
            surfaceUses -= 1
            state.broadcast()
            state.unlock()
        }
        return body(surface)
    }

    // MARK: - Viewport Read

    /// Returns the active viewport as a UTF-8 string, or `nil` if no surface
    /// is attached. Lines are separated by `\n`. The `ghostty_text_s`
    /// lifecycle (allocate via `ghostty_surface_read_text`, free via
    /// `ghostty_surface_free_text`) is fully encapsulated — callers never
    /// touch the C buffer.
    ///
    /// Selection grammar: `(VIEWPORT, TOP_LEFT)` to `(VIEWPORT, BOTTOM_RIGHT)`
    /// with `rectangle: false` (linear flow). This reads exactly the visible
    /// rows and ignores scrollback. Empty viewports return an empty string.
    ///
    /// Thread-safe, and it does not wait for `receive(_:)`: libghostty
    /// serializes the read against the parser itself, so a caller on the main
    /// thread is never parked behind a stalled reader.
    public func readViewportText() -> String? {
        let text: String?? = withSurface { surface in
            let topLeft = ghostty_point_s(
                tag: GHOSTTY_POINT_VIEWPORT,
                coord: GHOSTTY_POINT_COORD_TOP_LEFT,
                x: 0,
                y: 0
            )
            let bottomRight = ghostty_point_s(
                tag: GHOSTTY_POINT_VIEWPORT,
                coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
                x: 0,
                y: 0
            )
            let selection = ghostty_selection_s(
                top_left: topLeft,
                bottom_right: bottomRight,
                rectangle: false
            )

            var out = ghostty_text_s()
            guard ghostty_surface_read_text(surface, selection, &out) else {
                return nil
            }
            defer { ghostty_surface_free_text(surface, &out) }

            guard let textPtr = out.text, out.text_len > 0 else {
                return ""
            }
            let bytes = UnsafeBufferPointer(start: textPtr, count: Int(out.text_len))
                .map { UInt8(bitPattern: $0) }
            return String(decoding: bytes, as: UTF8.self)
        }
        return text ?? nil
    }

    func updateViewport(_ size: TerminalGridMetrics) {
        TerminalDebugLog.log(.metrics, "in-memory viewport update \(size.debugSummary)")
        dispatchResize(InMemoryTerminalViewport(
            columns: size.columns,
            rows: size.rows,
            widthPixels: size.widthPixels,
            heightPixels: size.heightPixels,
            cellWidthPixels: size.cellWidthPixels,
            cellHeightPixels: size.cellHeightPixels
        ))
    }

    // MARK: - Receiving Data

    /// Feed data into the terminal from the host backend.
    public func receive(_ data: Data) {
        write(data)
    }

    /// Feed a UTF-8 string into the terminal from the host backend.
    public func receive(_ string: String) {
        guard let data = string.data(using: .utf8) else { return }
        receive(data)
    }

    /// The single path onto `ghostty_surface_write_buffer`. Buffers while no
    /// surface is attached; otherwise writes whatever was buffered ahead of
    /// `data` in one call, so the pre-surface prompt and the first live bytes
    /// reach the terminal in the order the host produced them.
    private func write(_ data: Data) {
        writeLock.lock()
        defer { writeLock.unlock() }

        state.lock()
        guard let surface else {
            // No surface yet — buffer instead of dropping so the shell's first
            // prompt survives the spawn→attach race. Flushed in `setSurface`.
            pendingPreSurface.append(data)
            if pendingPreSurface.count > Self.pendingPreSurfaceCap {
                pendingPreSurface.removeFirst(pendingPreSurface.count - Self.pendingPreSurfaceCap)
            }
            state.unlock()
            TerminalDebugLog.log(
                .output,
                "terminal <- host buffered pre-surface \(TerminalDebugLog.describe(data))"
            )
            return
        }
        let flushed = pendingPreSurface.count
        var chunk = pendingPreSurface
        pendingPreSurface.removeAll(keepingCapacity: false)
        chunk.append(data)
        surfaceUses += 1
        state.unlock()
        defer {
            state.lock()
            surfaceUses -= 1
            state.broadcast()
            state.unlock()
        }

        if flushed > 0 {
            TerminalDebugLog.log(
                .output,
                "terminal <- host flushed pre-surface \(flushed) bytes"
            )
        }
        guard !chunk.isEmpty else { return }
        TerminalDebugLog.log(
            .output,
            "terminal <- host \(TerminalDebugLog.describe(data))"
        )

        chunk.withUnsafeBytes { buffer in
            guard let ptr = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return
            }
            ghostty_surface_write_buffer(surface, ptr, UInt(buffer.count))
        }
    }

    /// Inject input bytes directly into the host-side consumer.
    ///
    /// This bypasses `ghostty_surface_key` translation and is intended for
    /// control sequences that the in-memory backend must interpret itself.
    public func sendInput(_ data: Data) {
        TerminalDebugLog.log(
            .input,
            "host <- direct input \(TerminalDebugLog.describe(data))"
        )
        writeHandler(data)
    }

    // MARK: - Process Exit

    /// Signal that the host-managed process has exited.
    public func finish(exitCode: UInt32, runtimeMilliseconds: UInt64) {
        let delivered = withSurface { surface in
            ghostty_surface_process_exit(surface, exitCode, runtimeMilliseconds)
        }
        guard delivered != nil else {
            TerminalDebugLog.log(
                .lifecycle,
                "process exit ignored: missing surface exitCode=\(exitCode) runtimeMs=\(runtimeMilliseconds)"
            )
            return
        }
        TerminalDebugLog.log(
            .lifecycle,
            "process exit exitCode=\(exitCode) runtimeMs=\(runtimeMilliseconds)"
        )
    }

    // MARK: - C Callbacks

    static let receiveBufferCallback: ghostty_surface_receive_buffer_cb = { userdata, ptr, len in
        guard let userdata, let ptr else { return }
        let session = Unmanaged<InMemoryTerminalSession>
            .fromOpaque(userdata)
            .takeUnretainedValue()
        let data = Data(bytes: ptr, count: len)
        TerminalDebugLog.log(
            .input,
            "host <- terminal \(TerminalDebugLog.describe(data))"
        )
        session.writeHandler(data)
    }

    static let receiveResizeCallback: ghostty_surface_receive_resize_cb = { userdata, cols, rows, widthPx, heightPx in
        guard let userdata else { return }
        let session = Unmanaged<InMemoryTerminalSession>
            .fromOpaque(userdata)
            .takeUnretainedValue()
        TerminalDebugLog.log(
            .metrics,
            "receive resize cols=\(cols) rows=\(rows) pixels=\(widthPx)x\(heightPx)"
        )
        session.dispatchResize(InMemoryTerminalViewport(
            columns: cols,
            rows: rows,
            widthPixels: widthPx,
            heightPixels: heightPx
        ))
    }

    /// Called by libghostty's io thread (`receiveResizeCallback`) and by the
    /// view (`updateViewport`). It touches only `resizeLock`, so neither
    /// caller can be parked behind a `receive` that is mid-parse.
    private func dispatchResize(_ resize: InMemoryTerminalViewport) {
        resizeLock.lock()
        let mergedResize = mergedResize(resize)
        guard mergedResize != lastResize else {
            resizeLock.unlock()
            TerminalDebugLog.log(
                .metrics,
                "resize unchanged cols=\(mergedResize.columns) rows=\(mergedResize.rows) pixels=\(mergedResize.widthPixels)x\(mergedResize.heightPixels) cell=\(mergedResize.cellWidthPixels)x\(mergedResize.cellHeightPixels)"
            )
            return
        }
        lastResize = mergedResize
        resizeLock.unlock()

        TerminalDebugLog.log(
            .metrics,
            "resize dispatched cols=\(mergedResize.columns) rows=\(mergedResize.rows) pixels=\(mergedResize.widthPixels)x\(mergedResize.heightPixels) cell=\(mergedResize.cellWidthPixels)x\(mergedResize.cellHeightPixels)"
        )
        resizeHandler(mergedResize)
    }

    private func mergedResize(_ resize: InMemoryTerminalViewport) -> InMemoryTerminalViewport {
        guard let lastResize else { return resize }

        return InMemoryTerminalViewport(
            columns: resize.columns,
            rows: resize.rows,
            widthPixels: resize.widthPixels == 0 ? lastResize.widthPixels : resize.widthPixels,
            heightPixels: resize.heightPixels == 0 ? lastResize.heightPixels : resize.heightPixels,
            cellWidthPixels: resize.cellWidthPixels == 0 ? lastResize.cellWidthPixels : resize.cellWidthPixels,
            cellHeightPixels: resize.cellHeightPixels == 0 ? lastResize.cellHeightPixels : resize.cellHeightPixels
        )
    }
}
