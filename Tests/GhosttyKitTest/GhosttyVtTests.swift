import GhosttyKit
import GhosttyVt
import Testing

/// libghostty-vt beside the embedded surface's library: both link into one
/// binary, and the terminal core works on its own, snapshot round trip included.
struct GhosttyVtTests {
    @Test
    func `the vt terminal works beside the embedded library`() throws {
        #expect(ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS)

        var terminal: GhosttyTerminal?
        #expect(ghostty_terminal_new(nil, &terminal, 20, 4) == GHOSTTY_SUCCESS)
        let original = try #require(terminal)
        defer { ghostty_terminal_free(original) }
        let bytes = Array("\u{1b}[1;31mred\u{1b}[0m ok\r\n".utf8)
        ghostty_terminal_vt_write(original, bytes, bytes.count)
        #expect(ghostty_terminal_resize(original, 30, 6, 8, 16) == GHOSTTY_SUCCESS)

        var encoded: UnsafeMutablePointer<UInt8>?
        var length = 0
        #expect(ghostty_snapshot_encode_alloc(original, nil, &encoded, &length) == GHOSTTY_SUCCESS)
        let snapshot = try #require(encoded)
        defer { ghostty_free(nil, snapshot, length) }
        #expect(length > 0)

        var decoder: GhosttySnapshotDecoder?
        #expect(ghostty_snapshot_decoder_new_buf(nil, &decoder, snapshot, length) == GHOSTTY_SUCCESS)
        let snapshotDecoder = try #require(decoder)
        defer { ghostty_snapshot_decoder_free(snapshotDecoder) }
        var decoded: GhosttyTerminal?
        #expect(ghostty_snapshot_decoder_decode(snapshotDecoder, &decoded) == GHOSTTY_SUCCESS)
        let restored = try #require(decoded)
        defer { ghostty_terminal_free(restored) }

        var cols: UInt16 = 0
        #expect(ghostty_terminal_get(restored, GHOSTTY_TERMINAL_DATA_COLS, &cols) == GHOSTTY_SUCCESS)
        #expect(cols == 30)
    }
}
