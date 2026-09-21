#!/bin/sh
# test-popover.sh - contract checks for the MenuBarExtra popover layout.
#
# Pins the transparent-bands fix (0.4.2) plus the empty-Details fix (0.4.3):
# the popover window must size to its content instead of forcing a fixed
# expanded height that leaves bare host material above and below the
# dashboard, and the expanded Details view must actually render (a
# ScrollView has no intrinsic vertical size, so a maxHeight-only cap
# resolves to ~0pt in the content-sized window). Asserts (POSIX sh + grep):
#   - TokenBarApp.swift sets a fixed content width (400) with no forced
#     outer height (no `height:`/`maxHeight` on the MenuBarExtra frame, no
#     660 literal in TokenBarApp sources), so the details ScrollView cap is
#     the sole expanded-height owner
#   - no containerBackground modifier in App sources: the MenuBarExtra
#     .window style already owns the system window material, and
#     ContainerBackgroundPlacement.window is absent from the macOS 14 SDK
#     (referencing it breaks the macOS 14 CI build); a second material
#     would also compete with the system surface
#   - no custom glassEffect on the MenuBarExtra content itself (charts,
#     cards, and text stay off custom glass; glass lives only on the
#     functional chip/action surfaces in LiquidGlass.swift)
#   - the details ScrollView keeps a nonzero viewport (minHeight) with its
#     380pt maxHeight cap (sole expanded-height owner), and no macOS
#     14-incompatible ScrollView gutter override was added (no
#     scrollContentBackground in App sources)
#   - notices live inside the expanded ScrollView content (first viewport
#     shows details, long notice lists scroll with them) and stay outside
#     only for the empty/no-scope states; no expanded-outside
#     `} else { notices }` branch remains
#   - empty conditional slots are omitted from the hierarchy (no bare
#     EmptyView spacing gaps): statusBanner/notices/comparison render only
#     under a parent `if`, so hidden slots leave no bare window-material
#     strip above/below the content; the compact path keeps exactly one
#     vertical ScrollView (expanded only) with the root padding + width-400
#     geometry intact
#
# Run: ./scripts/test-popover.sh (from the repo root).
set -eu
cd "$(dirname "$0")/.."

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'PASS %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s -- %s\n' "$1" "$2"; }

APP="Sources/TokenBarApp/TokenBarApp.swift"
DASH="Sources/TokenBarApp/DashboardView.swift"
GLASS="Sources/TokenBarApp/LiquidGlass.swift"

# --- 1. Files exist ---
for f in "$APP" "$DASH" "$GLASS"; do
  if [ -f "$f" ]; then
    ok "popover source exists ($f)"
  else
    bad "popover source exists" "missing $f"
  fi
done

# --- 2. No forced outer height on the MenuBarExtra frame ---
if grep -q 'height:' "$APP"; then
  bad "no forced outer height in TokenBarApp" "found 'height:' in $APP"
else
  ok "no forced outer height in TokenBarApp"
fi
if grep -q '660' Sources/TokenBarApp/*.swift; then
  bad "no 660pt expanded-height literal in App sources" "found 660 in Sources/TokenBarApp"
else
  ok "no 660pt expanded-height literal in App sources"
fi

# --- 3. Fixed content width preserved (content-sized height, fixed width) ---
if grep -q '\.frame(width: 400)' "$APP"; then
  ok "MenuBarExtra keeps the fixed 400pt content width"
else
  bad "MenuBarExtra keeps the fixed 400pt content width" "missing '.frame(width: 400)' in $APP"
fi

# --- 4. No containerBackground modifier in App sources (portable) ---
# The MenuBarExtra .window style already owns the system window material.
# ContainerBackgroundPlacement.window is absent from the macOS 14 SDK, so
# any such modifier breaks the macOS 14 CI build; a second material would
# also compete with the system surface. Modifier applications start the
# (indented) line with `.containerBackground`; prose mentions in comments
# do not count.
BG_COUNT="$(grep -c '^[[:space:]]*\.containerBackground' "$APP" || true)"
if [ "$BG_COUNT" = "0" ]; then
  ok "no containerBackground modifier in TokenBarApp (system window owns background)"
else
  bad "no containerBackground modifier in TokenBarApp" "found $BG_COUNT (ContainerBackgroundPlacement.window is absent from the macOS 14 SDK)"
fi
OTHER_BG="$(grep -l '^[[:space:]]*\.containerBackground' "$DASH" "$GLASS" 2>/dev/null || true)"
if [ -n "$OTHER_BG" ]; then
  bad "no containerBackground modifier in DashboardView/LiquidGlass" "found in: $OTHER_BG"
else
  ok "no containerBackground modifier in DashboardView/LiquidGlass"
fi

# --- 5. No custom glassEffect on the MenuBarExtra content itself ---
if grep -q 'glassEffect' "$APP" || grep -q 'glassEffect' "$DASH"; then
  bad "no custom glassEffect on popover content" "content (charts/cards/text) must stay off custom glass"
else
  ok "no custom glassEffect on popover content"
fi

# --- 6. Details ScrollView keeps a nonzero viewport with the 380pt cap ---
# The ScrollView is the sole expanded-height owner. The minHeight is
# load-bearing: a ScrollView has no intrinsic vertical size, so in the
# content-sized MenuBarExtra window a maxHeight-only cap resolves to ~0pt
# and Details renders only the outside notices card. Plain frame, macOS
# 14-safe; no forced outer height is reintroduced.
if grep -Fq '.frame(minHeight: 280, maxHeight: 380)' "$DASH"; then
  ok "details ScrollView keeps the nonzero 280pt viewport with the 380pt cap"
else
  bad "details ScrollView keeps the nonzero 280pt viewport with the 380pt cap" "missing '.frame(minHeight: 280, maxHeight: 380)' in $DASH"
fi
if grep -Eq '\.frame\(height: [0-9]{3}' Sources/TokenBarApp/*.swift; then
  bad "no popover-scale fixed height in App sources" "found a 100pt+ '.frame(height:' in Sources/TokenBarApp; small fixed bar heights (8/10pt) are fine, the ScrollView viewport must stay a min/max range"
else
  ok "no popover-scale fixed height in App sources"
fi
if grep -q 'maxHeight' "$APP"; then
  bad "no competing height cap in TokenBarApp" "found 'maxHeight' in $APP; the Dashboard ScrollView must be the sole expanded-height owner"
else
  ok "no competing height cap in TokenBarApp"
fi

# --- 7. Notices scroll with the expanded details (0.4.3) ---
# The expanded notices card must live inside the ScrollView content so the
# first viewport shows details and long notice lists scroll with them.
# Notices stay outside only for the empty/no-scope states. Statically:
# exactly two bare `notices` placements exist, the first inside the
# ScrollView region (between ScrollView and its viewport frame), the
# second after it, and no `} else { notices }` expanded-outside branch
# remains.
SCROLL_LINE="$(grep -n 'ScrollView {' "$DASH" | head -1 | cut -d: -f1)"
FRAME_LINE="$(grep -n 'minHeight: 280, maxHeight: 380' "$DASH" | head -1 | cut -d: -f1)"
NOTICES_LINES="$(grep -n '^[[:space:]]*notices$' "$DASH" | cut -d: -f1)"
NOTICES_COUNT="$(printf '%s\n' "$NOTICES_LINES" | grep -c '[0-9]' || true)"
FIRST_NOTICES="$(printf '%s\n' "$NOTICES_LINES" | head -1)"
LAST_NOTICES="$(printf '%s\n' "$NOTICES_LINES" | tail -1)"
if [ "$NOTICES_COUNT" = "2" ] && [ -n "$SCROLL_LINE" ] && [ -n "$FRAME_LINE" ] \
  && [ "$FIRST_NOTICES" -gt "$SCROLL_LINE" ] && [ "$FIRST_NOTICES" -lt "$FRAME_LINE" ] \
  && [ "$LAST_NOTICES" -gt "$FRAME_LINE" ]; then
  ok "notices live inside the expanded ScrollView, outside only for empty/no-scope states"
else
  bad "notices live inside the expanded ScrollView" "expected exactly 2 placements (scroll=$SCROLL_LINE frame=$FRAME_LINE notices='$(printf '%s' "$NOTICES_LINES" | tr '\n' ' ')')"
fi
if grep -A1 '} else {' "$DASH" | grep -q '^[[:space:]]*notices$'; then
  bad "no expanded-outside notices branch" "found a '} else {' branch rendering notices outside the ScrollView"
else
  ok "no expanded-outside notices branch"
fi

# --- 8. No ScrollView gutter override (none is macOS 14-safe and needed) ---
if grep -q 'scrollContentBackground' Sources/TokenBarApp/*.swift; then
  bad "no ScrollView gutter override in App sources" "found scrollContentBackground in Sources/TokenBarApp"
else
  ok "no ScrollView gutter override in App sources"
fi

# --- 9. No empty-slot spacing gaps (top/bottom strip guard) ---
# A conditional view that renders EmptyView still consumes its parent
# VStack spacing, leaving a bare window-material gap that reads as a
# light/translucent strip in light appearance. The parent must omit
# statusBanner (top slot below the Divider), notices (bottom slots), and
# the nil comparison line (trend stacks) entirely when they have nothing
# to show, so the content-sized popover hugs its content. Plain `if`
# only: no material, height, blur, or animation change.
if grep -q 'showsStatusBanner' "$DASH" && grep -q 'if showsStatusBanner' "$DASH"; then
  ok "statusBanner omitted when empty (no top spacing gap)"
else
  bad "statusBanner omitted when empty" "missing 'showsStatusBanner' helper + 'if showsStatusBanner' guard in $DASH"
fi
if grep -B2 '^[[:space:]]*statusBanner$' "$DASH" | grep -q 'if showsStatusBanner'; then
  ok "statusBanner placement sits under its parent guard"
else
  bad "statusBanner placement sits under its parent guard" "bare statusBanner line is not under 'if showsStatusBanner' in $DASH"
fi
if grep -q 'hasNotices' "$DASH"; then
  HAS_COUNT="$(grep -c 'if hasNotices' "$DASH" || true)"
  if [ "$HAS_COUNT" -ge 2 ]; then
    ok "notices omitted when empty (no bottom spacing gap)"
  else
    bad "notices omitted when empty" "expected >=2 'if hasNotices' guards in $DASH, found $HAS_COUNT"
  fi
else
  bad "notices omitted when empty" "missing 'hasNotices' helper in $DASH"
fi
if grep -B3 '^[[:space:]]*notices$' "$DASH" | grep -q 'if hasNotices'; then
  GUARDED_NOTICES="$(grep -B3 '^[[:space:]]*notices$' "$DASH" | grep -c 'if hasNotices' || true)"
  if [ "$GUARDED_NOTICES" -ge 2 ]; then
    ok "notices placements sit under parent guards"
  else
    bad "notices placements sit under parent guards" "expected both notices lines under 'if hasNotices', found $GUARDED_NOTICES"
  fi
else
  bad "notices placements sit under parent guards" "bare notices lines are not under 'if hasNotices' in $DASH"
fi
CMP_GUARDS="$(grep -c 'if comparison != nil' "$DASH" || true)"
CMP_LINES="$(grep -c 'TrendComparisonLine(comparison:' "$DASH" || true)"
if [ "$CMP_GUARDS" -ge 2 ] && [ "$CMP_LINES" = "2" ]; then
  ok "nil comparison line omitted (no trend spacing gap)"
else
  bad "nil comparison line omitted" "expected >=2 'if comparison != nil' guards with 2 TrendComparisonLine placements (found guards=$CMP_GUARDS lines=$CMP_LINES)"
fi
VSCROLL="$(grep -c 'ScrollView {' "$DASH" || true)"
if [ "$VSCROLL" = "1" ]; then
  ok "compact path keeps no vertical scroll region (expanded only)"
else
  bad "compact path keeps no vertical scroll region" "expected exactly 1 'ScrollView {' in $DASH (expanded only), found $VSCROLL"
fi
if grep -q '\.padding(16)' "$DASH" && grep -q '\.frame(width: 400)' "$DASH"; then
  ok "root popover keeps padding-16 + width-400 content-sized geometry"
else
  bad "root popover keeps padding-16 + width-400 content-sized geometry" "missing '.padding(16)' or '.frame(width: 400)' in $DASH"
fi

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
