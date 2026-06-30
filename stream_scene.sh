#!/usr/bin/env bash
set -euo pipefail

: "${YOUTUBE_STREAM_KEY:?YOUTUBE_STREAM_KEY is required}"

SCENE_URL="${SCENE_URL:-http://127.0.0.1:8765/live?lite=1}"
W=1920; H=1080; FPS=10
RTMP="rtmp://a.rtmp.youtube.com/live2/${YOUTUBE_STREAM_KEY}"
DURATION="${DURATION:-19500}"
SHOT_EVERY="${SHOT_EVERY:-10}"
FIFO="/tmp/nst_fifo"

rm -f "$FIFO"; mkfifo "$FIFO"

PLAYLIST="/tmp/playlist.txt"
: > "$PLAYLIST"
if ls music/*.mp3 >/dev/null 2>&1; then
  for f in $(ls music/*.mp3 | sort -R); do echo "file '$(pwd)/$f'" >> "$PLAYLIST"; done
fi
if [ -s "$PLAYLIST" ]; then
  AUDIO_IN=(-f concat -safe 0 -stream_loop -1 -i "$PLAYLIST")
else
  AUDIO_IN=(-f lavfi -i anullsrc=channel_layout=stereo:sample_rate=44100)
fi

python3 - "$SCENE_URL" "$W" "$H" "$FPS" "$SHOT_EVERY" "$FIFO" <<'PYEOF' &
import sys, time
from playwright.sync_api import sync_playwright
url, w, h, fps, every, fifo = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5]), sys.argv[6]
interval = 1.0 / fps
with sync_playwright() as p:
    b = p.chromium.launch(args=["--no-sandbox", "--disable-gpu", "--force-device-scale-factor=1"])
    pg = b.new_page(viewport={"width": w, "height": h})
    pg.goto(url, wait_until="networkidle")
    pg.wait_for_timeout(4000)
    cached = pg.screenshot(type="jpeg", quality=80)
    last = time.time()
    f = open(fifo, "wb")
    while True:
        now = time.time()
        if now - last >= every:
            try:
                cached = pg.screenshot(type="jpeg", quality=80)
                last = now
            except Exception:
                pass
        try:
            f.write(cached)
            f.flush()
        except Exception:
            break
        time.sleep(interval)
PYEOF
PW_PID=$!
cleanup() { kill "$PW_PID" 2>/dev/null || true; rm -f "$FIFO"; }
trap cleanup EXIT INT TERM

ffmpeg -hide_banner -loglevel warning \
  -f image2pipe -framerate "$FPS" -i "$FIFO" \
  "${AUDIO_IN[@]}" \
  -c:v libx264 -preset veryfast -tune stillimage -pix_fmt yuv420p -r "$FPS" \
  -b:v 2500k -minrate 2500k -maxrate 2500k -bufsize 5000k -g $((FPS*2)) -keyint_min $((FPS*2)) \
  -c:a aac -b:a 128k -ar 44100 \
  -map 0:v:0 -map 1:a:0 \
  -t "${DURATION}" \
  -f flv "$RTMP"
