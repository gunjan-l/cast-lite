#!/bin/sh
# Runs inside the ffmpeg container. Proves fetch-and-decode.sh really fails on each failure mode:
# a positive control must pass, and each negative fixture must exit non-zero with the expected reason.
# Usage: self-test.sh   (expects /harness = scripts/harness, /work writable)
H=/harness
F=/work/selftest
MIN=60
rm -rf "$F"; mkdir -p "$F/good"

# 4 s, 25 fps, 1 s GOP, no B-frames: four 1 s segments, 100 frames.
ffmpeg -v error -f lavfi -i testsrc2=size=1280x720:rate=25 -t 4 -c:v libx264 -preset ultrafast -bf 0 -g 25 \
  -x264-params keyint=25:min-keyint=25:scenecut=0:repeat-headers=1 -pix_fmt yuv420p \
  -f hls -hls_time 1 -hls_list_size 0 -hls_segment_filename "$F/good/seg%d.ts" "$F/good/latest.m3u8" || { echo "fixture generation failed"; exit 2; }

playlist() { # playlist <dir> <seg...>
  dir=$1; shift
  { echo "#EXTM3U"; echo "#EXT-X-VERSION:3"; echo "#EXT-X-TARGETDURATION:1"; echo "#EXT-X-MEDIA-SEQUENCE:0"
    for s in "$@"; do echo "#EXTINF:1.0,"; echo "$s"; done; } > "$dir/latest.m3u8"
}

# (a) corrupted segment: overwrite the middle of seg1 with random bytes.
mkdir -p "$F/corrupt"; cp "$F/good"/* "$F/corrupt"/
dd if=/dev/urandom of="$F/corrupt/seg1.ts" bs=1 seek=20000 count=4000 conv=notrunc 2>/dev/null

# (b) too few frames: only the first segment (25 frames) is listed.
mkdir -p "$F/short"; cp "$F/good/seg0.ts" "$F/short"/; playlist "$F/short" seg0.ts

# (c) backwards PTS: decodes cleanly, but B-frames make PTS go backwards in packet order.
mkdir -p "$F/backwards"
ffmpeg -v error -f lavfi -i testsrc2=size=1280x720:rate=25 -t 4 -c:v libx264 -preset veryfast -bf 2 -g 25 \
  -x264-params keyint=25:min-keyint=25:scenecut=0:repeat-headers=1 -pix_fmt yuv420p \
  -f hls -hls_time 1 -hls_list_size 0 -hls_segment_filename "$F/backwards/seg%d.ts" "$F/backwards/latest.m3u8" || { echo "fixture generation failed"; exit 2; }

# (c2) backwards timestamps across segments (played out of order): ffmpeg itself rejects this at decode.
mkdir -p "$F/reordered"; cp "$F/good"/seg*.ts "$F/reordered"/; playlist "$F/reordered" seg2.ts seg3.ts seg0.ts seg1.ts

status=0
run_case() { # run_case <name> <fixture> <expected-reason-regex or PASS>
  name=$1; fixture=$2; want=$3
  out=$(FIXTURE_DIR="$fixture" sh "$H/fetch-and-decode.sh" http://unused "$MIN" 0 2>&1); code=$?
  last=$(printf '%s\n' "$out" | tail -n 3)
  echo "=== $name: exit=$code"
  printf '%s\n' "$last"
  if [ "$want" = PASS ]; then
    if [ $code -eq 0 ] && printf '%s' "$out" | grep -q "HARNESS PASS"; then echo "SELFTEST OK ($name passes)"; else echo "SELFTEST BAD ($name should pass)"; status=1; fi
  else
    if [ $code -ne 0 ] && printf '%s' "$out" | grep -Eq "HARNESS FAIL: .*($want)"; then echo "SELFTEST OK ($name fails as expected)"; else echo "SELFTEST BAD ($name should fail with: $want)"; status=1; fi
  fi
}

run_case "control (good segments)" "$F/good" PASS
run_case "(a) corrupted segment" "$F/corrupt" "decoder (error|warnings)"
run_case "(b) too few frames" "$F/short" "frame count"
run_case "(c) backwards PTS (B-frames)" "$F/backwards" "PTS regression"
run_case "(c2) backwards PTS (segments out of order)" "$F/reordered" "decoder error|PTS regression"

[ $status -eq 0 ] && echo "SELFTEST PASSED" || echo "SELFTEST FAILED"
exit $status
