#!/bin/sh
# Runs inside the ffmpeg container. Polls the served HLS, saves playlist + segments, then decodes.
# Usage: fetch-and-decode.sh <base-url> <expected-min-frames> <poll-seconds>
BASE="$1"; MIN_FRAMES="$2"; POLL="$3"
OUT=/work/fetched
rm -rf "$OUT"; mkdir -p "$OUT"
fail() { echo "HARNESS FAIL: $*"; exit 1; }

i=0
until curl -sf "$BASE/stream.m3u8" -o "$OUT/probe.m3u8"; do
  i=$((i+1)); [ $i -gt 120 ] && fail "playlist never became available at $BASE/stream.m3u8"
  sleep 0.5
done
echo "playlist available"

end=$(( $(date +%s) + POLL ))
while [ "$(date +%s)" -lt "$end" ]; do
  if curl -sf "$BASE/stream.m3u8" -o "$OUT/latest.m3u8"; then
    for seg in $(grep -v '^#' "$OUT/latest.m3u8"); do
      [ -f "$OUT/$seg" ] || curl -sf "$BASE/$seg" -o "$OUT/$seg" || rm -f "$OUT/$seg"
    done
  fi
  sleep 0.5
done
[ -f "$OUT/latest.m3u8" ] || fail "no playlist captured"
echo "--- playlist ---"; cat "$OUT/latest.m3u8"

# Local copy of the playlist, closed so ffmpeg reads to the end.
grep -v '^#EXT-X-ENDLIST' "$OUT/latest.m3u8" > "$OUT/vod.m3u8"
echo "#EXT-X-ENDLIST" >> "$OUT/vod.m3u8"
for seg in $(grep -v '^#' "$OUT/vod.m3u8"); do
  [ -s "$OUT/$seg" ] || fail "segment $seg listed but not fetched"
done

# 1. Decode each segment alone and as the full playlist; any stderr output at warning level fails.
for f in "$OUT"/*.ts; do
  ffmpeg -v warning -xerror -i "$f" -f null - 2> "$OUT/err.txt" || { cat "$OUT/err.txt"; fail "decoder error in $f"; }
  [ -s "$OUT/err.txt" ] && { cat "$OUT/err.txt"; fail "decoder warnings in $f"; }
done
ffmpeg -v warning -xerror -allowed_extensions ALL -i "$OUT/vod.m3u8" -f null - 2> "$OUT/err.txt" || { cat "$OUT/err.txt"; fail "decoder error in playlist"; }
[ -s "$OUT/err.txt" ] && { cat "$OUT/err.txt"; fail "decoder warnings in playlist"; }

# 2. Frame count.
FRAMES=$(ffprobe -v error -allowed_extensions ALL -count_frames -select_streams v:0 -show_entries stream=nb_read_frames -of csv=p=0 "$OUT/vod.m3u8" | head -n1)
echo "decoded frames: $FRAMES (minimum $MIN_FRAMES)"
[ -n "$FRAMES" ] && [ "$FRAMES" -ge "$MIN_FRAMES" ] || fail "frame count $FRAMES below $MIN_FRAMES"

# 3. PTS must never go backwards (no B-frames, so packet order is presentation order).
ffprobe -v error -allowed_extensions ALL -select_streams v:0 -show_entries packet=pts -of default=nw=1:nk=1 "$OUT/vod.m3u8" > "$OUT/pts.txt"
awk 'NR>1 && $1 < prev { bad=NR } { prev=$1 } END { if (bad) { print "PTS went backwards at packet " bad; exit 1 } }' "$OUT/pts.txt" || fail "PTS regression"
[ -s "$OUT/pts.txt" ] || fail "no packets found"

echo "HARNESS PASS"