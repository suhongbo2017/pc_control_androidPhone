#!/usr/bin/env bash
# wechat_send.sh — send a WeChat message on a connected phone in one shot (~10s), 1 verification screenshot.
#
#   ./wechat_send.sh -q "阿宿" -m "我是苏洪波"            # Chinese query works (ADBKeyboard, no IME candidates)
#   ./wechat_send.sh -q asu -m "我是苏洪波" -r 1         # pinyin/ASCII query, -r = result row (default 1)
#   ./wechat_send.sh -q asu -m "..." --dry              # fill only (prepare), never sends
#   ./wechat_send.sh -q asu -m "..." --auto-send        # verify every step with OCR, then send
#   ./wechat_send.sh --confirm                          # send what a previous --dry prepared (after you eyeballed it)
#
# Verification checkpoints (each one aborts with a distinct exit code instead of sending blindly):
#   4 = target name not found in results  -> guided mode: confirm the task/target name
#   3 = opened chat title != target      -> wrong chat, nothing sent
#   5 = typed text != message            -> nothing sent
#   6 = send button not found            -> nothing sent
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
Q=""; MSG=""; ROW=1; DRY=0; AUTOSEND=0; CONFIRM=0
SEARCH_XY="${SEARCH_XY:-960 212}"      # top-right magnifier on the chat list
RESULT_X="${RESULT_X:-309}"            # x of the first search-result row
RESULT_Y0="${RESULT_Y0:-546}"          # y of the first result row (联系人 section, 1156x2510 layout)
ROW_PITCH="${ROW_PITCH:-190}"          # row pitch inside a section
MAX_ROWS="${MAX_ROWS:-5}"              # how many candidate rows to try before giving up
INPUT_XY="${INPUT_XY:-583 2386}"       # chat input box
KBD_TOGGLE_XY="${KBD_TOGGLE_XY:-65 2386}"    # 语音/文字切换键：输入框最左侧、紧挨"按住说话"左边的小键盘图标

while [ $# -gt 0 ]; do
  case "$1" in
    -q|--query)   Q="$2"; shift 2 ;;
    -m|--message) MSG="$2"; shift 2 ;;
    -r|--row)     ROW="$2"; shift 2 ;;
    --dry|--prepare) DRY=1; shift ;;
    --auto-send)  AUTOSEND=1; shift ;;
    --confirm)    CONFIRM=1; shift ;;
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
winpath() { python -c "import os,sys;print(os.path.abspath(sys.argv[1]).replace('/', chr(92)))" "$1"; }
norm() { python -c "import re,sys;print(re.sub(r'\s+','',sys.stdin.read()))"; }
ocr_text() {  # OCR a screenshot -> utf8 lines
  local p="$1"
  [ -f "$(dirname "$0")/ocr.ps1" ] || { echo ""; return; }
  powershell -NoProfile -ExecutionPolicy Bypass -File "$(dirname "$0")/ocr.ps1" -Path "$(winpath "$p")" 2>/dev/null
}
shot_ocr() { A exec-out screencap -p > "$SHOTS/.chk.png" 2>/dev/null; ocr_text "$SHOTS/.chk.png"; }
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

# ---- --confirm: only tap send on whatever is prepared right now
if [ "$CONFIRM" = "1" ]; then
  xy="$(send_xy)"; [ -n "$xy" ] || { echo "未定位到发送按钮，未发送" >&2; exit 6; }
  A shell "input tap $xy" >/dev/null; sleep 1.0
  A exec-out screencap -p > "$SHOTS/wechat_sent.png"
  echo "已点击发送（$xy）-> $SHOTS/wechat_sent.png"
  exit 0
fi

# ---- 0) 回到已知状态：微信「聊天列表」（用 OCR 核对底部四个 tab 存在）
S_ "ime enable $ADBKB" >/dev/null 2>&1
S_ "ime set $ADBKB" >/dev/null
S_ "input keyevent 224" >/dev/null; S_ "wm dismiss-keyguard" >/dev/null
S_ "am start -n com.tencent.mm/.ui.LauncherUI" >/dev/null; sleep 1.0
at_list=0
for i in 1 2 3 4; do
  txt="$(shot_ocr)"
  if echo "$txt" | norm | grep -q "通讯录" && echo "$txt" | norm | grep -q "发现"; then at_list=1; break; fi
  A shell "am broadcast -a ADB_CLEAR_TEXT" >/dev/null 2>&1
  A shell "input keyevent 4" >/dev/null; sleep 0.7      # 退出聊天/键盘
  S_ "am start -n com.tencent.mm/.ui.LauncherUI" >/dev/null; sleep 0.8
done
if [ "$at_list" != "1" ]; then
  A exec-out screencap -p > "$SHOTS/wechat_nolist.png"
  echo "核对失败：没能回到微信聊天列表（可能被其他界面挡住）。未做任何发送。" >&2
  echo "截图：$SHOTS/wechat_nolist.png" >&2
  exit 7
fi

# ---- 2) search the contact and open the Nth result
A shell "input tap $SEARCH_XY" >/dev/null; sleep 0.8
send_b64 "$Q"; sleep 0.5
A shell "input keyevent 66" >/dev/null; sleep 1.3
if [ "$AUTOSEND" = "1" ]; then
  txt="$(shot_ocr)"
  # 只要求「目标名字在搜索结果里出现过」；分组标题（联系人/最常使用）OCR 不稳定，不作硬判据。
  if ! echo "$txt" | norm | grep -q "$(echo "$Q" | norm)"; then
    A exec-out screencap -p > "$SHOTS/wechat_nocontact.png"
    echo "核对失败：搜索结果里没有出现「$Q」（可能不是好友，或名字不对）。未发送。" >&2
    echo "截图：$SHOTS/wechat_nocontact.png" >&2
    echo "OCR 前几行：$(echo "$txt" | head -6 | tr '
' ' ')" >&2
    exit 4
  fi
fi
# 逐个候选行尝试，每进一个聊天就核对标题；不对就返回继续试下一行
opened=0
for i in $(seq 0 $(( MAX_ROWS - 1 ))); do
  A shell "input tap $RESULT_X $(( RESULT_Y0 + i * ROW_PITCH ))" >/dev/null; sleep 1.5
  if [ "$AUTOSEND" = "1" ]; then
    txt="$(shot_ocr)"
    if echo "$txt" | norm | grep -q "$(echo "$Q" | norm)"; then opened=1; break; fi
    A shell "input keyevent 4" >/dev/null; sleep 0.8      # 不是目标 → 退回搜索结果
  else
    opened=1; break                                        # 未开启自动核对时按第一行处理
  fi
done
if [ "$opened" != "1" ]; then
  A exec-out screencap -p > "$SHOTS/wechat_notfound.png"
  echo "核对失败：试了 $MAX_ROWS 个结果行，都没进入标题含「$Q」的聊天。未发送。" >&2
  echo "截图：$SHOTS/wechat_notfound.png" >&2
  exit 3
fi

# ---- 2.5) 核对聊天标题 == 目标
if [ "$AUTOSEND" = "1" ]; then
  txt="$(shot_ocr)"
  if ! echo "$txt" | norm | grep -q "$(echo "$Q" | norm)"; then
    A exec-out screencap -p > "$SHOTS/wechat_wrongchat.png"
    echo "核对失败：打开的聊天标题里没有「$Q」。未发送。" >&2
    echo "截图：$SHOTS/wechat_wrongchat.png" >&2
    exit 3
  fi
fi

# ---- 3) focus the input；若是"按住说话"（语音模式）先切回文字模式，否则文本注入会静默丢失
A shell "input tap $INPUT_XY" >/dev/null; sleep 0.5
if [ "$AUTOSEND" = "1" ]; then
  if shot_ocr | norm | grep -q "按住说话"; then
    A shell "input tap $KBD_TOGGLE_XY" >/dev/null; sleep 0.6
    if shot_ocr | norm | grep -q "按住说话"; then
      A exec-out screencap -p > "$SHOTS/wechat_voicemode.png"
      echo "核对失败：输入框处于语音模式且切换失败，文本无法注入。未发送。" >&2
      echo "截图：$SHOTS/wechat_voicemode.png" >&2
      exit 8
    fi
  fi
fi
A shell "am broadcast -a ADB_CLEAR_TEXT" >/dev/null 2>&1; sleep 0.3
send_b64 "$MSG"; sleep 0.4

# ---- 3.5) 核对输入框正文 == 消息原文
if [ "$AUTOSEND" = "1" ]; then
  txt="$(shot_ocr)"
  if ! echo "$txt" | norm | grep -q "$(echo "$MSG" | norm)"; then
    A exec-out screencap -p > "$SHOTS/wechat_badtext.png"
    echo "核对失败：输入框里没有完整的消息原文。未发送。" >&2
    echo "截图：$SHOTS/wechat_badtext.png" >&2
    exit 5
  fi
fi

# ---- 4) send (dry run stops here)
if [ "$DRY" = "1" ] || [ "$AUTOSEND" != "1" ]; then
  A exec-out screencap -p > "$SHOTS/wechat_dry.png"
  echo "PREPARED 已填未发 -> $SHOTS/wechat_dry.png  发送按钮=$(send_xy)"
  echo "核对无误后执行：$0 --confirm"
  exit 0
fi
xy="$(send_xy)"; [ -n "$xy" ] || { echo "未定位到发送按钮" >&2; exit 1; }
A shell "input tap $xy" >/dev/null; sleep 1.0
A exec-out screencap -p > "$SHOTS/wechat_sent.png"
echo "已发送（发送按钮 $xy）-> $SHOTS/wechat_sent.png"
