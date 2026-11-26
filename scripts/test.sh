#!/bin/bash
# Usage: scripts/test.sh <scheme> [xcodebuild-args...]
# Runs xcodebuild test on an iPhone simulator with the newest iOS 18+ runtime. TERMAPP_TEST_* shell
# variables are re-exported as TEST_RUNNER_TERMAPP_TEST_* so they reach the simulator.
set -euo pipefail
SCHEME="${1:?usage: scripts/test.sh <scheme> [xcodebuild-args...]}"
shift
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

while IFS= read -r v; do
  [ -n "$v" ] || continue
  export "TEST_RUNNER_$v=${!v}"
done < <(compgen -e | grep '^TERMAPP_TEST_' || true)

# Newest iOS runtime (18 or later) that has an available iPhone simulator.
SIM_ID="$(xcrun simctl list devices available -j | /usr/bin/python3 -c '
import json, re, sys
best = None
for runtime, devs in json.load(sys.stdin)["devices"].items():
    m = re.search(r"iOS-(\d+)-(\d+)", runtime)
    if not m or int(m.group(1)) < 18:
        continue
    ver = (int(m.group(1)), int(m.group(2)))
    for d in devs:
        if d.get("isAvailable") and d["name"].startswith("iPhone") and (best is None or ver > best[0]):
            best = (ver, d["udid"])
print(best[1] if best else "")
')"
[ -n "$SIM_ID" ] || { echo "no available iPhone simulator" >&2; exit 1; }

if [ -d "$ROOT/Packages/$SCHEME" ] && [ ! -f "$ROOT/TermApp.xcodeproj/xcshareddata/xcschemes/$SCHEME.xcscheme" ]; then
  cd "$ROOT/Packages/$SCHEME"
  exec xcodebuild test -scheme "$SCHEME" -destination "platform=iOS Simulator,id=$SIM_ID" "$@"
fi
cd "$ROOT"
exec xcodebuild test -project TermApp.xcodeproj -scheme "$SCHEME" -destination "platform=iOS Simulator,id=$SIM_ID" "$@"
