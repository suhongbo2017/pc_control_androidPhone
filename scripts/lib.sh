#!/usr/bin/env bash
# lib.sh — shared helpers for the pi-android scripts.
# Source it:  . "$(dirname "$0")/lib.sh"

set -uo pipefail

ROOT="${PI_ANDROID_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SHOTS="${SHOTS:-$ROOT/out/shots}"
TSV="${TSV:-$ROOT/out/captures.tsv}"
mkdir -p "$SHOTS"

export PYTHONIOENCODING=utf-8   # keep CJK in UI dumps readable

# ---- locate adb (same order as the extension) --------------------------------
exe_for_adb() { if [ "${OS:-}" = "Windows_NT" ]; then echo adb.exe; else echo adb; fi; }

# scrcpy ships its own adb; people keep it unpacked in ~/Downloads or the desktop.
scrcpy_adb() {
  local exe s f d
  exe=$(exe_for_adb)
  for d in "$HOME/Downloads" "$HOME/Desktop" "$HOME" /opt /usr/local; do
    [ -d "$d" ] || continue
    for s in "$d"/scrcpy*/; do
      [ -d "$s" ] || continue
      for f in "$s$exe" "$s"*/"$exe"; do
        [ -x "$f" ] && { echo "$f"; return; }
      done
    done
  done
}

adb_bin() {
  local exe c; exe=$(exe_for_adb)
  for c in "${PI_ANDROID_ADB:-}" "${ADB:-}" \
           "${ANDROID_HOME:+$ANDROID_HOME/platform-tools/$exe}" \
           "${ANDROID_SDK_ROOT:+$ANDROID_SDK_ROOT/platform-tools/$exe}" \
           "C:/Program Files/scrcpy/adb.exe" \
           "$HOME/AppData/Local/Android/Sdk/platform-tools/adb.exe" \
           "/opt/homebrew/bin/adb" "/usr/local/bin/adb" "/usr/bin/adb"; do
    if [ -n "$c" ] && [ -x "$c" ]; then echo "$c"; return; fi
  done
  c=$(scrcpy_adb); [ -n "${c:-}" ] && { echo "$c"; return; }
  echo "$exe"   # last resort: whatever is on PATH
}

# Fail loudly with actionable advice instead of "adb.exe: command not found".
require_adb() {
  if ! "$ADB" version >/dev/null 2>&1; then
    cat >&2 <<EOF
adb not found (tried: PI_ANDROID_ADB, ADB, ANDROID_HOME/ANDROID_SDK_ROOT, common install paths, scrcpy folders, PATH).

Pick one:
  1) export PI_ANDROID_ADB="/path/to/platform-tools/adb"   # or the adb shipped inside scrcpy
  2) put platform-tools on PATH
  3) install scrcpy or Android SDK platform-tools
EOF
    exit 127
  fi
}

ADB="${PI_ANDROID_ADB:-$(adb_bin)}"

# ---- pick a device ----------------------------------------------------------
# PI_ANDROID_DEVICE wins; otherwise the first attached device.
device() {
  if [ -n "${PI_ANDROID_DEVICE:-}" ]; then echo "$PI_ANDROID_DEVICE"; return; fi
  MSYS_NO_PATHCONV=1 "$ADB" devices | awk 'NR>1 && $2=="device"{print $1; exit}'
}

# ---- run a command on the device, strip CR ----------------------------------
sh_() { MSYS_NO_PATHCONV=1 "$ADB" -s "$(device)" shell "$1" 2>&1 | tr -d '\r'; }

# ---- wake the screen (dozing makes uiautomator return an empty tree) --------
wake_device() {
  sh_ "input keyevent 224" >/dev/null 2>&1
  sh_ "wm dismiss-keyguard" >/dev/null 2>&1
  sleep 0.7
}

# ---- UI tree -> "x,y  Class  text=..." compact listing ----------------------
ui_dump() {
  local tmp; tmp="$(mktemp)"
  MSYS_NO_PATHCONV=1 "$ADB" -s "$(device)" exec-out uiautomator dump --compressed /dev/tty 2>/dev/null > "$tmp"
  python - "$tmp" "${1:-}" <<'PY'
import re, sys
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass
xml_path, query = sys.argv[1], (sys.argv[2] if len(sys.argv) > 2 else "")
xml = open(xml_path, encoding="utf-8", errors="replace").read()
start, end = xml.find("<?xml"), xml.rfind("</hierarchy>")
nodes = []
if start >= 0 and end >= 0:
    for m in re.finditer(r"<node\s([^>]*?)/?>", xml[start:end + 10]):
        a = dict(re.findall(r'([\w-]+)="([^"]*)"', m.group(1)))
        b = re.search(r"\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\]", a.get("bounds", ""))
        if not b:
            continue
        x1, y1, x2, y2 = map(int, b.groups())
        label = a.get("text") or a.get("content-desc") or ""
        rid = a.get("resource-id", "")
        if not label and not rid:
            continue
        if query and query.lower() not in f"{label} {a.get('content-desc','')} {rid}".lower():
            continue
        cls = a.get("class", "").split(".")[-1]
        flags = ",".join(f for f, k in (("click", "clickable"), ("scroll", "scrollable"), ("checked", "checked"))
                         if a.get(k) == "true")
        nodes.append((y1, f"{(x1+x2)//2},{(y1+y2)//2}".ljust(10) + f" {cls:<18} text={label!r}"
                      + (f" id={rid}" if rid else "") + (f" [{flags}]" if flags else "")))
for _, line in sorted(nodes)[:120]:
    print(line)
PY
  rm -f "$tmp"
}
