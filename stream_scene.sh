#!/usr/bin/env bash
set -euo pipefail

: "${YOUTUBE_STREAM_KEY:?YOUTUBE_STREAM_KEY is required}"

SCENE_URL="${SCENE_URL:-http://127.0.0.1:8765/live}"
W=1920; H=1080; FPS="${FPS:-24}"
GOP=$((FPS * 2))
DISPLAY_NUM=99
RTMP="rtmp://a.rtmp.youtube.com/live2/${YOUTUBE_STREAM_KEY}"
DURATION="${DURATION:-21000}"

CHROME_BIN="$(command -v chromium-browser || command -v chromium || command -v google-chrome || true)"
[ -n "$CHROME_BIN" ] || { echo "::error::Chromium/Chrome not found"; exit 1; }

Xvfb ":${DISPLAY_NUM}" -screen 0 "${W}x${H}x24" -ac +extension GLX +render -noreset > /tmp/xvfb.log 2>&1 &
XVFB_PID=$!
export DISPLAY=":${DISPLAY_NUM}"
sleep 3

"$CHROME_BIN" \
  --no-sandbox --disable-gpu --disable-dev-shm-usage \
  --kiosk --start-fullscreen --window-position=0,0 \
  --window-size="${W},${H}" \
  --hide-scrollbars --disable-infobars --no-first-run \
  --autoplay-policy=no-user-gesture-required \
  --force-device-scale-factor=1 \
  "$SCENE_URL" > /tmp/chrome.log 2>&1 &
CHROME_PID=$!
sleep 8

PLAYLIST="/tmp/playlist.txt"
: > "$PLAYLIST"
if ls music/*.mp3 >/dev/null 2>&1; then
  for f in $(ls music/*.mp3 | sort -R); do
    echo "file '$(pwd)/$f'" >> "$PLAYLIST"
  done
fi

cleanup() {
  kill "$CHROME_PID" 2>/dev/null || true
  kill "$XVFB_PID" 2>/dev/null || true
}
trap cleanup EXIT

if [ -s "$PLAYLIST" ]; then
  AUDIO_IN=(-f concat -safe 0 -stream_loop -1 -i "$PLAYLIST")
else
  AUDIO_IN=(-f lavfi -i anullsrc=channel_layout=stereo:sample_rate=44100)
fi

ffmpeg -hide_banner -loglevel warning \
  -f x11grab -draw_mouse 0 -video_size "${W}x${H}" -framerate "${FPS}" -i ":${DISPLAY_NUM}.0" \
  "${AUDIO_IN[@]}" \
  -c:v libx264 -preset veryfast -pix_fmt yuv420p \
  -b:v 6000k -maxrate 6800k -bufsize 12000k -g "${GOP}" -keyint_min "${GOP}" \
  -c:a aac -b:a 128k -ar 44100 \
  -map 0:v:0 -map 1:a:0 \
  -t "${DURATION}" \
  -f flv "${RTMP}"
