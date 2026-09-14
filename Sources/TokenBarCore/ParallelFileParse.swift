import Foundation

/// Bounded-parallel driver for independent JSONL file parses.
///
/// Why this exists: Codex sessions dominate the 7d window (audit: ~749 MB
/// across 455 JSONL files, ~27.21s sequential parse on the Mac; Claude is
/// ~0.20s). File parses are independent except for per-file attribution
/// state, so wall time scales with file count on a single thread.
///
/// Contract, kept deliberately small:
/// - Files are enumerated once, sequentially, then sorted by standardized
///   path so output order is deterministic across runs and hosts.
/// - Each file is still parsed strictly sequentially, line by line, by the
///   existing `parseFile` (per-file turn/thread attribution, skipped-line
///   counts, and parse semantics are untouched; no cross-file guessing).
/// - Files run on a bounded worker pool (`defaultMaxWorkers`, currently
///   capped at 8 and never above the host CPU count). No unbounded task
///   creation: one `Operation` per file, at most `maxWorkers` running.
/// - Results merge in sorted-file order (pure `mergeOrdered`), so record
///   order and skipped totals match a sequential run over the same sorted
///   list. No shared mutable parse state, no global state, no change to
///   `NormalizedUsage` / dedupe / token math.
/// - OpenCode storage is out of scope and does not use this helper.
public enum ParallelFileParse {
    /// Bounded worker count for file-level parallelism.
    ///
    /// `min(8, activeProcessorCount)`, floored at 1. Eight keeps large
    /// local trees (hundreds of JSONL files) from spawning hundreds of
    /// concurrent readers while still using the cores on typical Macs.
    /// File parsing here is a mix of IO and JSON decode, so a small
    /// multiple of core count is not needed; determinism comes from the
    /// ordered merge, never from thread scheduling.
    public static var defaultMaxWorkers: Int {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        guard cores > 1 else { return 1 }
        return min(8, cores)
    }

    /// Enumerate `*.jsonl` files under `root` (recursive, skips hidden
    /// files) and return them sorted by standardized path for a stable,
    /// host-independent order. Returns `[]` when the root cannot be
    /// enumerated, matching the old sequential early return.
    public static func sortedJSONLFiles(
        root: URL,
        fileManager: FileManager = .default
    ) -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var files: [URL] = []
        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "jsonl" else { continue }
            files.append(url)
        }
        files.sort { $0.standardizedFileURL.path < $1.standardizedFileURL.path }
        return files
    }

    /// Pure ordered merge: concatenate per-file record chunks in file order
    /// and sum per-file skipped counts. No concurrency here, so this is the
    /// directly unit-tested piece; the parallel driver must always merge
    /// through it (or an identical in-order concatenation).
    public static func mergeOrdered<T>(
        chunks: [[T]],
        skipped: [Int]
    ) -> (records: [T], skippedLines: Int) {
        precondition(chunks.count == skipped.count, "chunks/skipped length mismatch")
        var records: [T] = []
        records.reserveCapacity(chunks.reduce(0) { $0 + $1.count })
        for chunk in chunks {
            records.append(contentsOf: chunk)
        }
        return (records, skipped.reduce(0, +))
    }

    /// Run `parse` once per file on a bounded pool and return per-file
    /// values in the input order. `parse` must be thread-safe on distinct
    /// files (the existing `parseFile` variants only touch locals plus the
    /// file they are given, so they qualify). Single-file and
    /// single-worker inputs run sequentially with no threading.
    public static func mapOrdered<T>(
        files: [URL],
        maxWorkers: Int = defaultMaxWorkers,
        parse: @Sendable @escaping (URL) -> T
    ) -> [T] {
        guard !files.isEmpty else { return [] }
        let workers = max(1, min(maxWorkers, files.count))
        if workers <= 1 || files.count <= 1 {
            return files.map(parse)
        }
        let slots = OrderedSlots<T>(count: files.count)
        let queue = OperationQueue()
        queue.name = "TokenBar.ParallelFileParse"
        queue.maxConcurrentOperationCount = workers
        for (index, file) in files.enumerated() {
            queue.addOperation {
                let value = parse(file)
                slots.lock.lock()
                slots.values[index] = value
                slots.lock.unlock()
            }
        }
        queue.waitUntilAllOperationsAreFinished()
        return slots.values.map { $0! }
    }
}

/// Lock-guarded fixed-size slot array for the bounded pool above.
/// Each worker writes exactly one distinct index; the lock keeps the
/// Swift array buffer itself free of data races. File scope (rather than
/// function-local) for older-toolchain compatibility.
private final class OrderedSlots<U>: @unchecked Sendable {
    var values: [U?]
    let lock = NSLock()
    init(count: Int) { values = Array(repeating: nil, count: count) }
}
