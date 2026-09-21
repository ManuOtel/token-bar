#!/bin/sh
# test-popover.sh - contract checks for the MenuBarExtra popover layout.
#
# Pins the transparent-bands fix (0.4.2): the popover window must size to
# its content instead of forcing a fixed expanded height that leaves bare
# host material above and below the dashboard. Asserts (POSIX sh + grep):
#   - TokenBarApp.swift sets a fixed content width (400) with no forced
#     outer height (no `height:` on the MenuBarExtra frame, no 660 literal
#     in TokenBarApp sources)
#   - exactly one containerBackground owner for the window, using adaptive
#     regular material (macOS 14 API; the system renders the Liquid Glass
#     window material on macOS 26 and later)
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

# --- 4. Exactly one adaptive containerBackground owner for the window ---
# Modifier applications start the (indented) line with `.containerBackground`;
# prose mentions in comments do not count.
BG_COUNT="$(grep -c '^[[:space:]]*\.containerBackground' "$APP" || true)"
if [ "$BG_COUNT" = "1" ]; then
  ok "exactly one containerBackground owner in TokenBarApp"
else
  bad "exactly one containerBackground owner in TokenBarApp" "found $BG_COUNT"
fi
if grep -Fq 'containerBackground(.regularMaterial, for: .window)' "$APP"; then
  ok "window background is adaptive regular material (.window)"
else
  bad "window background is adaptive regular material (.window)" "missing 'containerBackground(.regularMaterial, for: .window)' in $APP"
fi
OTHER_BG="$(grep -l '^[[:space:]]*\.containerBackground' "$DASH" "$GLASS" 2>/dev/null || true)"
if [ -n "$OTHER_BG" ]; then
  bad "no second containerBackground owner in DashboardView/LiquidGlass" "found in: $OTHER_BG"
else
  ok "no second containerBackground owner in DashboardView/LiquidGlass"
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

# --- 7. No ScrollView gutter override (none is macOS 14-safe and needed) ---
if grep -q 'scrollContentBackground' Sources/TokenBarApp/*.swift; then
  bad "no ScrollView gutter override in App sources" "found scrollContentBackground in Sources/TokenBarApp"
else
  ok "no ScrollView gutter override in App sources"
fi

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
