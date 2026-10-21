#!/usr/bin/env bash
# Smoke-test an ffmpeg executable the way imageio-ffmpeg uses it: encode test
# videos/audio with each available library encoder, then decode the frames
# through a raw video pipe and check the byte count.
#
# Usage: build/test-ffmpeg.sh FFMPEG [REQUIRED_ENCODER...]
#   REQUIRED_ENCODER defaults to libx264 (imageio-ffmpeg's default codec).
#
# In GitHub Actions, the result is added to the job summary (labelled with
# $TEST_NAME, default "Smoke test") and failures are reported as annotations.
set -euo pipefail

ff=$1
shift
required=("${@:-libx264}")
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
passed=() skipped=()
summary_file="${GITHUB_STEP_SUMMARY:-}"
if [[ -n "$summary_file" ]] && command -v cygpath >/dev/null; then
    summary_file="$(cygpath -u "$summary_file")"
fi
summary() {
    if [[ -n "$summary_file" ]]; then
        printf '%s **%s** `%s`: %s\n\n' "$1" "${TEST_NAME:-Smoke test}" "$(basename "$ff")" "$2" \
            >> "$summary_file"
    fi
}
fail() {
    echo "FAIL: $*" >&2
    if [[ "${GITHUB_ACTIONS:-}" == true ]]; then
        echo "::error title=${TEST_NAME:-Smoke test} failed ($(basename "$ff"))::$*"
    fi
    summary "❌" "failed: $*"
    exit 1
}
export SVT_LOG=1  # only errors from SVT-AV1, which ignores ffmpeg's -v

version="$("$ff" -hide_banner -version)"
echo "${version%%$'\n'*}"
encoders="$("$ff" -hide_banner -encoders)"
for e in "${required[@]}"; do
    grep -qE "^ [^ ]+ $e " <<< "$encoders" || fail "missing required encoder $e"
done

w=128 h=96 n=10
for spec in "libx264 mp4" "libx265 mp4" "libvpx-vp9 webm" "libsvtav1 mkv" "mpeg4 avi"; do
    read -r codec ext <<< "$spec"
    grep -qE "^ [^ ]+ $codec " <<< "$encoders" || { echo "skip $codec (not available)"; skipped+=("$codec"); continue; }
    out="$tmp/$codec.$ext"
    "$ff" -nostdin -v error -f lavfi -i "testsrc=size=${w}x${h}:rate=10" -frames:v $n \
        -c:v "$codec" -pix_fmt yuv420p -y "$out" || fail "encoding with $codec"
    bytes=$("$ff" -nostdin -v error -i "$out" -f image2pipe -pix_fmt rgb24 -vcodec rawvideo - | wc -c)
    (( bytes == n * w * h * 3 )) || fail "$codec: decoded $bytes bytes, expected $((n * w * h * 3))"
    echo "ok   $codec ($ext)"
    passed+=("$codec")
done

for spec in "libmp3lame mp3" "libopus opus" "libvorbis ogg"; do
    read -r codec ext <<< "$spec"
    grep -qE "^ [^ ]+ $codec " <<< "$encoders" || { echo "skip $codec (not available)"; skipped+=("$codec"); continue; }
    out="$tmp/$codec.$ext"
    "$ff" -nostdin -v error -f lavfi -i "sine=frequency=440:duration=1" -c:a "$codec" -y "$out" \
        || fail "encoding with $codec"
    "$ff" -nostdin -v error -i "$out" -f null - || fail "decoding $codec"
    echo "ok   $codec ($ext)"
    passed+=("$codec")
done

sample="$ROOT_DIR/images/cockatoo.mp4"
if [[ -f "$sample" ]]; then
    bytes=$("$ff" -nostdin -v error -i "$sample" -f image2pipe -pix_fmt rgb24 -vcodec rawvideo - | wc -c)
    (( bytes > 0 )) || fail "decoding $sample"
    echo "ok   decode $(basename "$sample") ($bytes bytes)"
    passed+=("decode $(basename "$sample")")
fi
echo "All tests passed"
result="passed: $(IFS=,; echo "${passed[*]}" | sed 's/,/, /g')"
if ((${#skipped[@]})); then result+="; not available: $(IFS=,; echo "${skipped[*]}" | sed 's/,/, /g')"; fi
summary "✅" "$result"
