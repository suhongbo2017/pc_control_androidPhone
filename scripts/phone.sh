#!/usr/bin/env bash
# phone.sh — small adb wrapper for humans (and for agents without the extension).
#
#   ./phone.sh devices
#   ./phone.sh screen [query]        # compact UI tree
#   ./phone.sh tap "Login"           # tap a node by text / content-desc
#   ./phone.sh key back
#   ./phone.sh type "hello world"    # ASCII only
#   ./phone.sh launch com.android.settings
#   ./phone.sh shot out.png
#   ./phone.sh shell "cmd uimode night yes"
#   ./phone.sh wake
. "$(dirname "$0")/lib.sh"

cmd="${1:-help}"; shift 2>/dev/null || true
require_adb

case "$cmd" in
  devices)
    MSYS_NO_PATHCONV=1 "$ADB" devices -l
    ;;
  screen)
    wake_device; ui_dump "${1:-}"
    ;;
  tap)
    [ -n "${1:-}" ] || { echo "usage: phone.sh tap <text>" >&2; exit 2; }
    wake_device
    xy=$(ui_dump "$1" | awk 'NR==1{print $1}')
    [ -n "$xy" ] || { echo "not found: $1" >&2; exit 1; }
    sh_ "input tap ${xy%,*} ${xy#*,}" >/dev/null
    echo "tapped '$1' at $xy"
    ;;
  key)
    [ -n "${1:-}" ] || { echo "usage: phone.sh key <name>" >&2; exit 2; }
    case "$1" in
      back) c=4 ;; home) c=3 ;; recent) c=187 ;; enter) c=66 ;; tab) c=61 ;;
      esc) c=111 ;; space) c=62 ;; del) c=67 ;; power) c=26 ;; wakeup) c=224 ;;
      volume_up) c=24 ;; volume_down) c=25 ;; *) c="$1" ;;
    esac
    sh_ "input keyevent $c" >/dev/null; echo "key $1 ($c)"
    ;;
  type)
    [ -n "${1:-}" ] || { echo "usage: phone.sh type <ascii text>" >&2; exit 2; }
    esc=$(printf '%s' "$1" | sed "s/ /%s/g")
    sh_ "input text $esc" >/dev/null; echo "typed: $1"
    ;;
  launch)
    [ -n "${1:-}" ] || { echo "usage: phone.sh launch <pkg[/.Activity]>" >&2; exit 2; }
    sh_ "monkey -p $1 -c android.intent.category.LAUNCHER 1" | grep -E "Events injected|No activities"
    ;;
  stop)
    sh_ "am force-stop $1" >/dev/null; echo "stopped $1"
    ;;
  shot)
    out="${1:-shot.png}"
    MSYS_NO_PATHCONV=1 "$ADB" -s "$(device)" exec-out screencap -p > "$out"
    echo "saved $out ($(wc -c < "$out") bytes)"
    ;;
  shell)
    [ -n "${1:-}" ] || { echo "usage: phone.sh shell '<command>'" >&2; exit 2; }
    sh_ "$1"
    ;;
  wake)
    wake_device; echo "awake"
    ;;
  *)
    sed -n '2,17p' "$0"
    ;;
esac
