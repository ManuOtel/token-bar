import Foundation

/// Bounded-memory UTF-8 JSONL line reader used by the file parsers.
///
/// Why this exists: `CodexParser.parseFile` and `ClaudeParser.parseFile`
/// used `String(contentsOf:)` plus `components(separatedBy: .newlines)`,
/// which materializes the whole file as one `String` plus an array holding
/// every line before parsing starts. Large histories pay that peak twice
/// over. This reader streams the file in fixed 64 KiB chunks and hands each
/// line to the caller, so peak input memory is two fixed chunk buffers plus
/// the longest single line plus whatever records the caller keeps. Per-file
/// parsing stays strictly serial; the bounded parallel file scheduler in
/// `ParallelFileParse` is unchanged (distinct files may still parse
/// concurrently; this type holds no shared state).
///
/// Contract, kept deliberately small:
/// - Splitting matches `components(separatedBy: .newlines)` exactly: every
///   member of `CharacterSet.newlines` (U+000A-U+000D, U+0085, U+2028,
///   U+2029) ends the current line, each occurrence separately. CRLF
///   therefore still yields its phantom empty component, and line numbers
///   (1-based component ordinals, blanks included) are identical to the old
///   path, so `path:line` fallback ids never change.
/// - Multi-byte separators (U+0085 = `C2 85`, U+2028 = `E2 80 A8`,
///   U+2029 = `E2 80 A9`) are recognized even when split across chunk
///   boundaries via a at-most-2-byte carry. These byte sequences cannot
///   occur inside any other UTF-8 character, so byte-level scanning splits
///   exactly where the old `String`-level split did.
/// - The final line is emitted even without a trailing newline. A trailing
///   separator leaves no observable empty line: the old trailing empty
///   split was always blank-skipped (never a record, never counted), so it
///   is not emitted, with zero observable difference.
/// - UTF-8 is strict per line and the whole file keeps the old strictness:
///   any line that is not valid UTF-8 makes the reader return `false`, and
///   the caller must discard all partial work and report the old
///   `([], 0)` whole-file result, exactly like `String(contentsOf: .utf8)`
///   failing. IO errors (missing file, read failure) also return `false`.
/// - Blank handling stays with the caller: this reader emits every line
///   including empty ones, and the parsers skip whitespace-only lines free
///   (not counted as skipped), as before.
/// - No prompts, bodies, paths, or raw blobs are retained: each line's
///   bytes are converted to a transient `String` and handed to the caller;
///   nothing is cached.
public enum JSONLLineReader {
    /// Fixed read chunk: the only input buffers besides the longest line
    /// are the read chunk and one scan buffer of the same size.
    public static let chunkSize = 64 * 1024

    /// Streams every line of `url` to `body` as `(line, lineNumber)`.
    ///
    /// Returns `true` when the file streamed cleanly (including empty
    /// files, which yield zero lines), `false` when the file cannot be
    /// opened/read or any line is not valid UTF-8. On `false` the caller
    /// must discard everything `body` already received.
    @discardableResult
    public static func forEachLine(at url: URL, body: (String, Int) -> Void) -> Bool {
        guard let stream = InputStream(url: url) else { return false }
        stream.open()
        defer { stream.close() }
        var chunk = [UInt8](repeating: 0, count: chunkSize)
        var buf: [UInt8] = []
        buf.reserveCapacity(chunkSize + 2)
        var carry: [UInt8] = []
        var pending = Data()
        pending.reserveCapacity(chunkSize)
        var lineNumber = 0
        var failed = false
        var finished = false

        func emitCurrent() -> Bool {
            lineNumber += 1
            guard let text = String(data: pending, encoding: .utf8) else { return false }
            pending.removeAll(keepingCapacity: true)
            body(text, lineNumber)
            return true
        }

        while !failed && !finished {
            let count = chunk.withUnsafeMutableBufferPointer { pointer -> Int in
                guard let base = pointer.baseAddress else { return 0 }
                return stream.read(base, maxLength: chunkSize)
            }
            if count < 0 { return false }
            if count == 0 { finished = true }
            buf.removeAll(keepingCapacity: true)
            buf.append(contentsOf: carry)
            carry.removeAll(keepingCapacity: true)
            if count > 0 {
                buf.append(contentsOf: chunk[0..<count])
            }
            var index = 0
            var runStart = 0
            let end = buf.count
            while index < end {
                let byte = buf[index]
                if byte == 0x0A || byte == 0x0B || byte == 0x0C || byte == 0x0D {
                    // Single-byte separator (LF, VT, FF, CR): each occurrence
                    // ends the line on its own, exactly like the old split.
                    if runStart < index {
                        pending.append(contentsOf: buf[runStart..<index])
                    }
                    if !emitCurrent() { failed = true; break }
                    index += 1
                    runStart = index
                } else if byte == 0xC2 {
                    if index + 1 < end, buf[index + 1] == 0x85 {
                        // U+0085 (NEL) separator.
                        if runStart < index {
                            pending.append(contentsOf: buf[runStart..<index])
                        }
                        if !emitCurrent() { failed = true; break }
                        index += 2
                        runStart = index
                    } else if index + 1 >= end, !finished {
                        // Possible separator split across chunks: hold the
                        // byte for the next round instead of guessing.
                        if runStart < index {
                            pending.append(contentsOf: buf[runStart..<index])
                        }
                        carry = [byte]
                        index += 1
                        runStart = index
                    } else {
                        // Ordinary byte, or a truncated tail at EOF (which
                        // then fails strict UTF-8, as the old path did).
                        index += 1
                    }
                } else if byte == 0xE2 {
                    if index + 2 < end, buf[index + 1] == 0x80,
                       (buf[index + 2] == 0xA8 || buf[index + 2] == 0xA9)
                    {
                        // U+2028 / U+2029 separator.
                        if runStart < index {
                            pending.append(contentsOf: buf[runStart..<index])
                        }
                        if !emitCurrent() { failed = true; break }
                        index += 3
                        runStart = index
                    } else if index + 2 >= end, !finished {
                        // Possible separator split across chunks: hold the
                        // remainder for the next round instead of guessing.
                        if runStart < index {
                            pending.append(contentsOf: buf[runStart..<index])
                        }
                        carry = Array(buf[index..<end])
                        runStart = end
                        index = end
                    } else {
                        // Ordinary byte, or a truncated tail at EOF (which
                        // then fails strict UTF-8, as the old path did).
                        index += 1
                    }
                } else {
                    index += 1
                }
            }
            if !failed, runStart < end {
                pending.append(contentsOf: buf[runStart..<end])
            }
        }
        if stream.streamStatus == .error || failed { return false }
        if !pending.isEmpty {
            if !emitCurrent() { return false }
        }
        return stream.streamStatus != .error
    }
}
