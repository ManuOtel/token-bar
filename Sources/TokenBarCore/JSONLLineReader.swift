import Foundation

/// Bounded-memory UTF-8 JSONL line reader used by the file parsers.
///
/// Why this exists: `CodexParser.parseFile` and `ClaudeParser.parseFile`
/// used `String(contentsOf:)` plus `components(separatedBy: .newlines)`,
/// which materializes the whole file as one `String` plus an array holding
/// every line before parsing starts. Large histories pay that peak twice
/// over. This reader streams the file in fixed 64 KiB chunks and hands each
/// logical line to the caller, so peak input memory is one chunk plus the
/// longest single line plus whatever records the caller keeps. Per-file
/// parsing stays strictly serial; the bounded parallel file scheduler in
/// `ParallelFileParse` is unchanged (distinct files may still parse
/// concurrently; this type holds no shared state).
///
/// Contract, kept deliberately small:
/// - Logical lines split on LF (`0x0A`) only. One trailing CR (`0x0D`) per
///   line is stripped, so LF and CRLF files yield the same lines.
/// - The final line is emitted even without a trailing newline. A trailing
///   newline emits no extra empty line (the old trailing empty split was
///   always blank-skipped, so counts are unaffected).
/// - Line numbers are dense logical ordinals starting at 1: blank lines
///   still consume a number, but CRLF no longer consumes two (see below).
///   Callers pass the number through as the stable `path:line` fallback id.
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
///
/// Documented deviations from `components(separatedBy: .newlines)`:
/// - CRLF numbering: the old split treated `\r` and `\n` as two separate
///   separators, so each CRLF break produced a phantom empty element that
///   consumed a line number (fallback ids in CRLF files had gaps, e.g. the
///   second record id ended in `:3`). The reader counts one logical line
///   per break, so CRLF fallback ids are dense (`:1`, `:2`, ...). Pure-LF
///   files are unaffected: numbering is identical to before.
/// - Lone CR and Unicode line separators (`U+0085`, `U+2028`, `U+2029`,
///   `U+000B`, `U+000C`) no longer split lines. JSONL delimits records with
///   LF; the old behavior split inside JSON string values carrying those
///   characters and produced spurious malformed lines. Such files are not
///   observed in practice; if one appears, lines now stay whole and decode
///   or skip as one unit instead of fragmenting.
public enum JSONLLineReader {
    /// Fixed read chunk: the only input buffer besides the longest line.
    public static let chunkSize = 64 * 1024

    /// Streams every logical line of `url` to `body` as `(line, lineNumber)`.
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
        var pending = Data()
        pending.reserveCapacity(chunkSize)
        var lineNumber = 0
        var failed = false

        func emit(_ raw: Data) -> Bool {
            lineNumber += 1
            var bytes = raw
            if bytes.last == 0x0D { bytes.removeLast() } // single trailing CR (CRLF)
            guard let text = String(data: bytes, encoding: .utf8) else { return false }
            body(text, lineNumber)
            return true
        }

        while stream.hasBytesAvailable && !failed {
            let count = chunk.withUnsafeMutableBufferPointer { pointer -> Int in
                guard let base = pointer.baseAddress else { return 0 }
                return stream.read(base, maxLength: chunkSize)
            }
            if count < 0 { return false }
            if count == 0 { break }
            var start = 0
            var index = 0
            while index < count {
                if chunk[index] == 0x0A {
                    pending.append(contentsOf: chunk[start..<index])
                    if !emit(pending) { failed = true; break }
                    pending.removeAll(keepingCapacity: true)
                    start = index + 1
                }
                index += 1
            }
            if failed { break }
            if start < count {
                pending.append(contentsOf: chunk[start..<count])
            }
        }
        if stream.streamStatus == .error || failed { return false }
        if !pending.isEmpty {
            if !emit(pending) { return false }
        }
        return stream.streamStatus != .error
    }
}
