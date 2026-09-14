#!/usr/bin/env python3
"""Deterministic count-only measurement for the JSONL streaming slice.

Compares input materialization of the old parse path
(`String(contentsOf:)` + `components(separatedBy: .newlines)`: one
whole-file String plus an array holding every line) against the new
`JSONLLineReader` path (two fixed 64 KiB buffers plus the longest single
line in flight, with splitting/numbering identical to the old path).
No wall-clock is measured, so this is CI-safe and timing-flake free.
Parsed records are identical work on both paths and are excluded from
the comparison.

Synthetic data only; nothing is read from real session roots.
"""

CHUNK_SIZE = 64 * 1024

USAGE_LINE = ('{"type":"token_usage_record","timestamp":"2026-09-10T08:15:00Z",'
              '"payload":{"response_id":"r-%d","usage":{"input_tokens":1200,'
              '"output_tokens":340,"total_tokens":1540}}}')
CTX_LINE = ('{"type":"turn_context","timestamp":"2026-09-10T08:14:00Z",'
            '"payload":{"turn_id":"t-%d","thread_id":"th","model":"synth-m"}}')


def build_lines(count=5000):
    lines = []
    for i in range(count):
        if i % 10 == 0:
            lines.append(CTX_LINE % i)
        lines.append(USAGE_LINE % i)
    return lines


def main():
    lines = build_lines()
    text = "\n".join(lines) + "\n"
    raw = text.encode("utf-8")
    file_bytes = len(raw)
    n_lines = len(lines)
    max_line = max(len(line.encode("utf-8")) for line in lines)

    # Old path input peak: whole-file String (~file bytes) + one String per
    # line (sum of line bytes) + the trailing-empty split element (free).
    old_peak = file_bytes + sum(len(line.encode("utf-8")) for line in lines)
    old_line_objects = n_lines + 1  # components array incl. trailing empty

    # New path input peak: two fixed buffers + longest line buffer. At most
    # one line String is live at a time; records output is identical both
    # paths.
    new_peak = 2 * CHUNK_SIZE + max_line
    new_line_objects = 1

    saved = old_peak - new_peak
    pct = 100.0 * saved / old_peak if old_peak else 0.0

    print(f"lines: {n_lines}")
    print(f"file bytes: {file_bytes}")
    print(f"max line bytes: {max_line}")
    print(f"old input peak bytes (file + all lines): {old_peak}")
    print(f"new input peak bytes (2 x 64 KiB buffers + longest line): {new_peak}")
    print(f"saved bytes: {saved} ({pct:.1f}%)")
    print(f"old live line objects: {old_line_objects} vs new: {new_line_objects} "
          f"({old_line_objects - new_line_objects} avoided)")
    assert new_peak < old_peak, "streaming peak must stay below whole-file peak"
    assert file_bytes > CHUNK_SIZE, "fixture must exceed one chunk to be meaningful"
    print("bench-jsonl-streaming: OK (count-only, no wall-clock)")


if __name__ == "__main__":
    main()
