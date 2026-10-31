#!/usr/bin/env bash
# capture.sh — phase 1 of the two-phase flow: swipe + screenshot + metadata, NO image reading.
#
#   ./capture.sh -n 5 -d 5                 # 5 videos, dwell 5s each
#   ./capture.sh -n 6 -d 3 --skip-shopping # keep swiping until 6 non-shopping videos
#   ./capture.sh -n 5 -r 5-10 --ui         # random 5..10s dwell, also grab the UI text
#
# Output: out/shots/f<N>.png + out/captures.tsv (idx, time, dwell, psnr, shop, activity, shot, ui)
# Phase 2 is montage.sh (stitch thumbnails into one image) — one image read for N items.
. "$(dirname "$0")/lib.sh"

N=5; DWELL=5; RANDOM_RANGE=""; WITH_UI=0; SKIP_SHOP=0
GESTURE="${GESTURE:-540 2100 540 300 500}"   # x1 y1 x2 y2 duration_ms

while [ $# -gt 0 ]; do
  case "$1" in
    -n|--count)      N="$2"; shift 2 ;;
    -d|--dwell)      DWELL="$2"; shift 2 ;;
    -r|--random)     RANDOM_RANGE="$2"; shift 2 ;;
    --ui)            WITH_UI=1; shift ;;
    --skip-shopping) SKIP_SHOP=1; shift ;;
    -h|--help)       sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

[ -f "$TSV" ] || printf "idx\ttime\tdwell\tpsnr\tshop\tactivity\tshot\tui\n" > "$TSV"

# shopping / advertising markers rendered by the UI (nav-tab words like 购物/商城 are excluded on purpose)
SHOP_KW='广告|立即咨询|点击进入直播间|消费券|已售|讲解中|券后|领券|立即购买|购物车|小店|抢购|下单|代金券|¥'

psnr() {  # psnr <a.png> <b.png>  -> number or "-"
  command -v ffmpeg >/dev/null 2>&1 || { echo "-"; return; }
  ffmpeg -hide_banner -loglevel info -i "$1" -i "$2" -lavfi psnr -f null - 2>&1 \
    | grep -o "average:[0-9.inf]*" | tail -1 | cut -d: -f2
}

shot() { MSYS_NO_PATHCONV=1 "$ADB" -s "$(device)" exec-out screencap -p > "$1"; }

swipe_up() { sh_ "input swipe $GESTURE" >/dev/null 2>&1; }

wake_device
shot "$SHOTS/prev.png"; prev="$SHOTS/prev.png"

kept=0; attempts=0; max_attempts=$(( N * 4 ))
while [ "$kept" -lt "$N" ] && [ "$attempts" -lt "$max_attempts" ]; do
  attempts=$(( attempts + 1 ))
  t0=$(date +%s%N 2>/dev/null || echo 0)
  swipe_up

  # dwell: fixed or random in range
  wait="$DWELL"
  if [ -n "$RANDOM_RANGE" ]; then
    lo="${RANDOM_RANGE%-*}"; hi="${RANDOM_RANGE#*-}"
    wait=$(python -c "import random;print(random.randint($lo,$hi))")
  fi

  n=$(( $(tail -n +2 "$TSV" | grep -c . ) + 1 ))
  f="$SHOTS/f$n.png"; u="$SHOTS/ui$n.txt"
  if [ "$WITH_UI" = "1" ] || [ "$SKIP_SHOP" = "1" ]; then
    shot "$f" &
    MSYS_NO_PATHCONV=1 "$ADB" -s "$(device)" exec-out uiautomator dump --compressed /dev/tty 2>/dev/null > "$SHOTS/ui$n.xml" &
    wait
    python - "$SHOTS/ui$n.xml" "$u" <<'PY'
import re, sys
xml = open(sys.argv[1], encoding="utf-8", errors="replace").read()
out = []
for m in re.finditer(r"<node\s([^>]*?)/?>", xml):
    a = dict(re.findall(r'([\w-]+)="([^"]*)"', m.group(1)))
    t = (a.get("text") or "").strip() or (a.get("content-desc") or "").strip()
    if t and t not in out:
        out.append(t)
open(sys.argv[2], "w", encoding="utf-8").write("\n".join(out))
PY
    shop=0; grep -qE "$SHOP_KW" "$u" 2>/dev/null && shop=1
  else
    shot "$f"; shop="-"; : > "$u"
  fi

  p=$(psnr "$prev" "$f")
  act=$(sh_ "dumpsys activity activities" 2>/dev/null | grep -m1 topResumedActivity | grep -oE "[a-zA-Z0-9._]+/[A-Za-z0-9.$]+" | head -1)
  prev="$f"

  if [ "$SKIP_SHOP" = "1" ] && [ "$shop" = "1" ]; then
    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" "$n" "$(date +%H:%M:%S)" "$wait" "$p" "shop-skip" "$act" \
      "shots/$(basename "$f")" "${u:+shots/$(basename "$u")}" >> "$TSV"
    printf '#%s dwell=%ss PSNR=%s -> skipped (shopping/ad)\n' "$n" "$wait" "$p"
  else
    kept=$(( kept + 1 ))
    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" "$n" "$(date +%H:%M:%S)" "$wait" "$p" "$shop" "$act" \
      "shots/$(basename "$f")" "${u:+shots/$(basename "$u")}" >> "$TSV"
    printf '#%s dwell=%ss PSNR=%s kept %s/%s\n' "$n" "$wait" "$p" "$kept" "$N"
  fi

  # pad the dwell so each item takes ~`wait` seconds wall clock
  el=$(( ( $(date +%s%N 2>/dev/null || echo 0) - t0 ) / 1000000 ))
  rest=$(( wait * 1000 - el ))
  [ "$rest" -gt 0 ] && sleep "$(python -c "print($rest/1000)")"
done

echo "done: $kept kept in $attempts attempts -> $TSV"
echo "next: ./montage.sh   # stitch into 1 image per 5 items, then read that image once"
