#!/bin/sh
# test-popover.sh - contract checks for the MenuBarExtra popover layout.
#
# Pins the transparent-bands fix (0.4.2): the popover window must size to
# its content instead of forcing a fixed expanded height that leaves bare
# host material above and below the dashboard. Asserts (POSIX sh + grep):
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
#   - the details ScrollView keeps its 380pt cap (sole expanded-height
#     owner), and no macOS 14-incompatible ScrollView gutter override was
#     added (no scrollContentBackground in App sources)
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

# --- 6. Details ScrollView keeps its 380pt cap (sole expanded-height owner) ---
if grep -Fq '.frame(maxHeight: 380)' "$DASH"; then
  ok "details ScrollView keeps the 380pt cap"
else
  bad "details ScrollView keeps the 380pt cap" "missing '.frame(maxHeight: 380)' in $DASH"
fi
if grep -q 'maxHeight' "$APP"; then
  bad "no competing height cap in TokenBarApp" "found 'maxHeight' in $APP; the Dashboard ScrollView must be the sole expanded-height owner"
else
  ok "no competing height cap in TokenBarApp"
fi

# --- 7. No ScrollView gutter override (none is macOS 14-safe and needed) ---
if grep -q 'scrollContentBackground' Sources/TokenBarApp/*.swift; then
  bad "no ScrollView gutter override in App sources" "found scrollContentBackground in Sources/TokenBarApp"
else
  ok "no ScrollView gutter override in App sources"
fi

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
