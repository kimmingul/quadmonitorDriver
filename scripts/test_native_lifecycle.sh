#!/bin/bash
# Offline integration tests: real SCK frames, no USB bulk output.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
app="${1:-$root/build/Quad Monitor.app}"
evidence="${2:-$(mktemp -d /tmp/quad-native-lifecycle.XXXXXX)}"
mkdir -p "$evidence"
helper="$app/Contents/Helpers/VerifiedSession"
active=''
trap 'if [ -n "$active" ] && kill -0 "$active" 2>/dev/null; then kill -TERM "$active"; wait "$active" || true; fi' EXIT
field() { plutil -extract "$2" raw -o - "$1" 2>/dev/null; }
wait_state() {
  local expected="$1" n=0
  while [ "$(field "$control/status.json" state || true)" != "$expected" ]; do
    kill -0 "$active" 2>/dev/null || { cat "$control/status.json"; return 1; }
    n=$((n+1)); [ "$n" -lt 400 ] || return 1
    sleep 0.1
  done
}
for scenario in bounded manual_stop worker_failure; do
  control="$evidence/$scenario/control"
  args=(--run --demo --fps 10 --takeover-vendor --control-dir "$control")
  if [ "$scenario" = bounded ]; then args+=(--seconds 4); else args+=(--continuous); fi
  "$helper" "${args[@]}" > "$evidence/$scenario.log" 2>&1 & active=$!
  wait_state running
  case "$scenario" in
    manual_stop) touch "$(field "$control/status.json" stop_file)" ;;
    worker_failure)
      victim=''
      for pid in $(pgrep -P "$active"); do
        if ps -p "$pid" -o comm= | grep -q 'VerifiedCapture$'; then victim="$pid"; break; fi
      done
      [ -n "$victim" ]; kill -KILL "$victim" ;;
  esac
  code=0; wait "$active" || code=$?
  active=''
  if [ "$scenario" = worker_failure ]; then
    [ "$code" -ne 0 ]; [ "$(field "$control/status.json" state)" = failed ]
    field "$control/status.json" error | grep -q 'capture exited: 9'
  else
    [ "$code" -eq 0 ]; [ "$(field "$control/status.json" state)" = stopped ]
    for role in right left top; do
      [ "$(field "$control/status.json" "panels.$role.transfer_errors")" -eq 0 ]
      [ "$(field "$control/status.json" "panels.$role.frames")" -ge 2 ]
    done
  fi
  if pgrep -x VerifiedCapture >/dev/null || pgrep -x VerifiedDesktopHost >/dev/null; then
    echo 'Leaked capture/host process' >&2; exit 1
  fi
  echo "$scenario: PASS (exit=$code)"
done
printf 'Evidence: %s\n' "$evidence"
