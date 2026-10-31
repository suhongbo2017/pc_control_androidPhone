#!/usr/bin/env bash
# install_adbkeyboard.sh — install + enable ADBKeyboard, surviving HyperOS/MIUI's "USB 安装" confirmation.
#
#   ./install_adbkeyboard.sh                 # download APK (17 KB) and install with the on-device handshake
#   ./install_adbkeyboard.sh -f x.apk        # install an APK you already have
#
# HyperOS/MIUI shows 设置 → 开发者选项 → USB 安装 → "USB 安装提示 / 继续安装 (8)" and auto-cancels after ~8s,
# so a plain `adb install` fails with INSTALL_FAILED_USER_RESTRICTED. This script runs the install in the
# background and taps 继续安装 while the dialog is up.
. "$(dirname "$0")/lib.sh"
require_adb

APK_X="${CONFIRM_X:-336}"; APK_Y="${CONFIRM_Y:-2272}"   # 继续安装 button (1156x2510 layouts)
URL="https://github.com/senzhk/ADBKeyBoard/raw/master/ADBKeyboard.apk"
TMP="${TMPDIR:-/tmp}/ADBKeyboard.apk"

while [ $# -gt 0 ]; do
  case "$1" in
    -f|--file) TMP="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [ ! -f "$TMP" ]; then
  echo "downloading ADBKeyboard.apk..."
  # GitHub may need a proxy in some networks:  HTTPS_PROXY=http://127.0.0.1:7897 ./install_adbkeyboard.sh
  curl -fsSL -m 120 ${HTTPS_PROXY:+-x "$HTTPS_PROXY"} -o "$TMP" "$URL" || {
    echo "download failed — pass -f /path/to/ADBKeyboard.apk (or set HTTPS_PROXY)" >&2; exit 1; }
fi
echo "APK: $TMP ($(wc -c < "$TMP") bytes)"

DEV="$(device)"
echo "installing on $DEV ..."
( "$ADB" -s "$DEV" install -r "$TMP" > /tmp/adbkb_install.log 2>&1 ) &
for _ in 1 2 3 4 5 6; do
  sleep 1.6
  "$ADB" -s "$DEV" shell "input tap $APK_X $APK_Y" >/dev/null 2>&1   # 继续安装
  grep -qE "Success|Failure" /tmp/adbkb_install.log 2>/dev/null && break
done
wait 2>/dev/null
tail -1 /tmp/adbkb_install.log

if grep -q "Success" /tmp/adbkb_install.log; then
  "$ADB" -s "$DEV" shell "ime enable com.android.adbkeyboard/.AdbIME" >/dev/null 2>&1
  echo "ADBKeyboard enabled. wechat_send.sh can now inject exact text (CJK included)."
else
  echo "install did not succeed — check 开发者选项 → USB 安装 is ON, then re-run" >&2
  exit 1
fi
