#!/usr/bin/env bash
# montage.sh — phase 2: stitch captured screenshots into one image per N items,
# so a single image read covers N videos instead of N reads.
#
#   ./montage.sh              # 5 per strip, 300px wide tiles
#   ./montage.sh -p 6 -w 250  # 6 per strip, smaller tiles (cheaper tokens)
#
# Reads  out/shots/f*.png  -> writes out/shots/strip_<first>_<last>.png
. "$(dirname "$0")/lib.sh"

PER=5; WIDTH=300
while [ $# -gt 0 ]; do
  case "$1" in
    -p|--per)   PER="$2"; shift 2 ;;
    -w|--width) WIDTH="$2"; shift 2 ;;
    -h|--help)  sed -n '2,9p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

command -v ffmpeg >/dev/null 2>&1 || { echo "ffmpeg is required for montage" >&2; exit 1; }

python - "$SHOTS" "$PER" "$WIDTH" <<'PY'
import glob, os, subprocess, sys

shots, per, width = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
height = int(width * 1.735)  # 9:19.5 phone aspect

def key(p):
    base = os.path.basename(p)[1:-4]
    return int("".join(c for c in base if c.isdigit()) or 0)

files = sorted((f for f in glob.glob(os.path.join(shots, "f*.png")) if "prev" not in f), key=key)
files = [f for f in files if not os.path.basename(f).startswith("strip")]

for i in range(0, len(files), per):
    chunk = files[i:i + per]
    if not chunk:
        continue
    ins, chain = [], ""
    for j, f in enumerate(chunk):
        ins += ["-i", f]
        chain += (f"[{j}]scale={width}:{height}:force_original_aspect_ratio=decrease,"
                  f"pad={width}:{height}:(ow-iw)/2:(oh-ih)/2:color=black[p{j}];")
    chain += "".join(f"[p{j}]" for j in range(len(chunk))) + f"hstack=inputs={len(chunk)}"
    out = os.path.join(shots, f"strip_{key(chunk[0]):02d}_{key(chunk[-1]):02d}.png")
    r = subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", *ins,
                        "-filter_complex", chain, "-frames:v", "1", out])
    if r.returncode == 0:
        print(f"strip_{key(chunk[0]):02d}_{key(chunk[-1]):02d}.png  ({len(chunk)} tiles) -> {out}")
    else:
        print(f"failed for {chunk}", file=sys.stderr)
PY
