#!/usr/bin/env bash
# wechat_send.sh — send a WeChat message on a connected phone in one shot (~10s), 1 verification screenshot.
#
#   ./wechat_send.sh -q "阿宿" -m "我是苏洪波"            # Chinese query works (ADBKeyboard, no IME candidates)
#   ./wechat_send.sh -q asu -m "我是苏洪波" -r 1         # pinyin/ASCII query, -r = result row (default 1)
#   ./wechat_send.sh -q asu -m "..." --dry              # everything except the final send tap
#   PI_ANDROID_DEVICE=<serial> ./wechat_send.sh ...
#
# Requires ADBKeyboard (com.android.adbkeyboard) installed + enabled:
#   adb install ADBKeyboard.apk && adb shell ime enable com.android.adbkeyboard/.AdbIME
# HyperOS additionally needs 开发者选项 → USB 安装 ON and the on-device "继续安装" tap
# (scripts/install_adbkeyboard.sh does that handshake for you).
#
# Design notes:
#  - Text goes in via ADBKeyboard broadcast → exact characters, no candidate guessing → no per-char vision rounds.
#  - ADBKeyboard stays active for the whole run (fewer IME switches ≈ faster, and the blank IME keeps the
#    layout stable), then the original IME is restored.
#  - The green 发送 button is located by pixel scan (#07C160) instead of a hardcoded coordinate,
#    so keyboard-open/closed layouts both work.
#  - One screenshot at the end is the whole verification budget.
. "$(dirname "$0")/lib.sh"
require_adb

DEV="$(device)"
Q=""; MSG=""; ROW=1; DRY=0
SEARCH_XY="${SEARCH_XY:-960 212}"      # top-right magnifier on the chat list
RESULT_X="${RESULT_X:-309}"            # x of the first search-result row
RESULT_Y0="${RESULT_Y0:-621}"          # y of the first row (this 1156x2510 layout)
ROW_PITCH="${ROW_PITCH:-270}"
INPUT_XY="${INPUT_XY:-583 2386}"       # chat input box

while [ $# -gt 0 ]; do
  case "$1" in
    -q|--query)   Q="$2"; shift 2 ;;
    -m|--message) MSG="$2"; shift 2 ;;
    -r|--row)     ROW="$2"; shift 2 ;;
    --dry)        DRY=1; shift ;;
    -h|--help)    sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
[ -n "$Q" ] && [ -n "$MSG" ] || { echo "need -q <search> and -m <message>" >&2; exit 2; }

A() { "$ADB" -s "$DEV" "$@"; }
S_() { A shell "$1" 2>&1 | tr -d '\r'; }
ADBKB="com.android.adbkeyboard/.AdbIME"
IME_ORIG="$(S_ "settings get secure default_input_method" | tail -1)"
restore_ime() { S_ "ime set $IME_ORIG" >/dev/null 2>&1; }
trap restore_ime EXIT

b64() { python -c "import base64,sys;print(base64.b64encode(sys.argv[1].encode()).decode())" "$1"; }
send_b64() { A shell "am broadcast -a ADB_INPUT_B64 --es msg $(b64 "$1")" >/dev/null 2>&1; }

# locate the WeChat green send button (#07C160) anywhere on screen
send_xy() {
  command -v ffmpeg >/dev/null 2>&1 || return
  A exec-out screencap -p > "$SHOTS/.wx.png" 2>/dev/null
  python - "$SHOTS/.wx.png" <<'PY'
import statistics, subprocess, sys
png = sys.argv[1]
w, h = map(int, subprocess.run(["ffprobe","-v","error","-select_streams","v:0",
        "-show_entries","stream=width,height","-of","csv=p=0",png],
        capture_output=True, text=True).stdout.strip().split(","))
raw = subprocess.run(["ffmpeg","-v","error","-i",png,"-f","rawvideo","-pix_fmt","rgb24","-"],
                     capture_output=True).stdout
xs, ys = [], []
for y in range(0, h, 2):
    row = y * w * 3
    for x in range(0, w, 2):
        i = row + x * 3
        r, g, b = raw[i], raw[i + 1], raw[i + 2]
        if g > 150 and r < 110 and 60 < b < 170:
            xs.append(x); ys.append(y)
print(f"{int(statistics.median(xs))} {int(statistics.median(ys))}" if len(xs) > 100 else "")
PY
}

# ---- 1) take over the keyboard once, wake, open WeChat chat list
S_ "ime enable $ADBKB" >/dev/null 2>&1
S_ "ime set $ADBKB" >/dev/null
S_ "input keyevent 224" >/dev/null; S_ "wm dismiss-keyguard" >/dev/null
S_ "am start -n com.tencent.mm/.ui.LauncherUI" >/dev/null; sleep 1.0

# ---- 2) search the contact and open the Nth result
A shell "input tap $SEARCH_XY" >/dev/null; sleep 0.8
send_b64 "$Q"; sleep 0.5
A shell "input keyevent 66" >/dev/null; sleep 1.3
A shell "input tap $RESULT_X $(( RESULT_Y0 + (ROW - 1) * ROW_PITCH ))" >/dev/null; sleep 1.6

# ---- 3) focus the input, clear leftovers, type the message
A shell "input tap $INPUT_XY" >/dev/null; sleep 0.5
A shell "am broadcast -a ADB_CLEAR_TEXT" >/dev/null 2>&1; sleep 0.3
send_b64 "$MSG"; sleep 0.4

# ---- 4) send (dry run stops here)
if [ "$DRY" = "1" ]; then
  A exec-out screencap -p > "$SHOTS/wechat_dry.png"
  echo "DRY 已填未发 -> $SHOTS/wechat_dry.png  发送按钮=$(send_xy)"
  exit 0
fi
xy="$(send_xy)"; [ -n "$xy" ] || { echo "未定位到发送按钮" >&2; exit 1; }
A shell "input tap $xy" >/dev/null; sleep 1.0
A exec-out screencap -p > "$SHOTS/wechat_sent.png"
echo "已发送（发送按钮 $xy）-> $SHOTS/wechat_sent.png"
