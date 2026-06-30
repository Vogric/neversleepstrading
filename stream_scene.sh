#!/usr/bin/env bash
set -euo pipefail

: "${YOUTUBE_STREAM_KEY:?YOUTUBE_STREAM_KEY is required}"

SCENE_URL="${SCENE_URL:-http://127.0.0.1:8765/live?lite=1}"
W=1280; H=720
RTMP="rtmp://a.rtmp.youtube.com/live2/${YOUTUBE_STREAM_KEY}"
DURATION="${DURATION:-19500}"
REFRESH="${REFRESH:-480}"
CLIP="/tmp/nst_clip.mp4"
NEXT="/tmp/nst_next.mp4"

shot() {
  python3 - "$SCENE_URL" "$W" "$H" "$1" <<'PYEOF' 2>/dev/null
import sys
from playwright.sync_api import sync_playwright
url, w, h, out = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
with sync_playwright() as p:
    b = p.chromium.launch(args=["--no-sandbox", "--disable-gpu", "--force-device-scale-factor=1"])
    pg = b.new_page(viewport={"width": w, "height": h})
    pg.goto(url, wait_until="networkidle")
    pg.wait_for_timeout(4500)
    pg.screenshot(path=out, type="png")
    b.close()
PYEOF
}

build_clip() {
  local img="$1" out="$2" musicargs
  if ls music/*.mp3 >/dev/null 2>&1; then
    local m; m="$(ls music/*.mp3 | sort -R | head -1)"
    musicargs=(-stream_loop -1 -i "$m")
  else
    musicargs=(-f lavfi -i anullsrc=channel_layout=stereo:sample_rate=44100)
  fi
  ffmpeg -hide_banner -loglevel error -y \
    -loop 1 -framerate 10 -t "$REFRESH" -i "$img" \
    "${musicargs[@]}" \
    -c:v libx264 -preset veryfast -tune stillimage -pix_fmt yuv420p -r 10 \
    -b:v 2500k -maxrate 2500k -bufsize 5000k -g 20 -keyint_min 20 \
    -c:a aac -b:a 128k -ar 44100 -shortest -t "$REFRESH" \
    "$out"
}

shot /tmp/nst_scene.png
build_clip /tmp/nst_scene.png "$CLIP"

START=$(date +%s)

(
  while true; do
    sleep "$REFRESH"
    shot /tmp/nst_scene2.png || continue
    build_clip /tmp/nst_scene2.png "$NEXT" || continue
    mv -f "$NEXT" "$CLIP"
  done
) &
REGEN_PID=$!
cleanup() { kill "$REGEN_PID" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

while [ $(( $(date +%s) - START )) -lt "$DURATION" ]; do
  ffmpeg -hide_banner -loglevel warning \
    -re -stream_loop -1 -i "$CLIP" \
    -c copy -t "$REFRESH" \
    -f flv "$RTMP" || true
done
