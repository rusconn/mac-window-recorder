#!/bin/bash
# Copyright (C) 2026 rusconn
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, see <https://www.gnu.org/licenses/>.

set -euo pipefail

if [ $# -lt 1 ]; then
    echo "Usage: $0 <video_file> [expected_fps] [skip_seconds]"
    exit 1
fi

VIDEO_FILE="$1"
EXPECTED_FPS="${2:-60}"
SKIP_SECONDS="${3:-1.0}"

if [ ! -f "$VIDEO_FILE" ]; then
    echo "Error: file not found: $VIDEO_FILE"
    exit 1
fi

FRAME_INTERVAL=$(echo "scale=6; 1.0 / $EXPECTED_FPS" | bc)
JITTER_THRESHOLD=$(echo "scale=6; $FRAME_INTERVAL * 0.5" | bc)

TMPFILE=$(mktemp)
trap 'rm -f "$TMPFILE"' EXIT

ffprobe -v quiet -select_streams v:0 \
    -show_entries frame=pts_time \
    -of csv=p=0 "$VIDEO_FILE" | sed 's/,//g' > "$TMPFILE"

TOTAL_LINES=$(wc -l < "$TMPFILE" | tr -d ' ')

if [ "$TOTAL_LINES" -lt 2 ]; then
    echo "Error: not enough frames in $VIDEO_FILE"
    exit 1
fi

FIRST_TS=$(head -1 "$TMPFILE")

read -r ALL_TOTAL ALL_STUTTER ALL_MAX ALL_AVG ALL_RATE < <(
    awk -v interval="$FRAME_INTERVAL" -v threshold="$JITTER_THRESHOLD" '
BEGIN {
    total = 0; stutter = 0; max_j = 0; sum_j = 0; prev = -1
}
{
    ts = $1 + 0
    total++
    if (prev >= 0) {
        delta = ts - prev
        dev = delta - interval
        if (dev < 0) dev = -dev
        sum_j += dev
        if (dev > max_j) max_j = dev
        if (dev > threshold) stutter++
    }
    prev = ts
}
END {
    n = total - 1
    if (n <= 0) { print "0 0 0 0 0"; exit }
    printf "%d %d %.6f %.6f %.2f\n", total, stutter, max_j, sum_j / n, stutter * 100 / n
}' "$TMPFILE"
)

SKIP_TS=$(echo "$FIRST_TS + $SKIP_SECONDS" | bc)

read -r STABLE_TOTAL STABLE_STUTTER STABLE_MAX STABLE_AVG STABLE_RATE < <(
    awk -v interval="$FRAME_INTERVAL" -v threshold="$JITTER_THRESHOLD" -v skip="$SKIP_TS" '
BEGIN {
    total = 0; stutter = 0; max_j = 0; sum_j = 0; prev = -1
}
{
    ts = $1 + 0
    if (ts < skip) next
    total++
    if (prev >= 0) {
        delta = ts - prev
        dev = delta - interval
        if (dev < 0) dev = -dev
        sum_j += dev
        if (dev > max_j) max_j = dev
        if (dev > threshold) stutter++
    }
    prev = ts
}
END {
    n = total - 1
    if (n <= 0) { print "0 0 0 0 0"; exit }
    printf "%d %d %.6f %.6f %.2f\n", total, stutter, max_j, sum_j / n, stutter * 100 / n
}' "$TMPFILE"
)

LAST_TS=$(tail -1 "$TMPFILE")
DURATION=$(echo "$LAST_TS - $FIRST_TS" | bc)
ACTUAL_FPS=$(echo "scale=2; ($ALL_TOTAL - 1) / $DURATION" | bc)

echo "=== Stutter Verification ==="
echo "File:            $VIDEO_FILE"
echo "Total frames:    $ALL_TOTAL"
echo "Duration:        ${DURATION}s"
echo "Expected FPS:    $EXPECTED_FPS"
echo "Actual FPS:      $ACTUAL_FPS"
echo "Frame interval:  ${FRAME_INTERVAL}s"
echo "Jitter threshold: ${JITTER_THRESHOLD}s"
echo ""
echo "=== All Frames ==="
echo "Stutters:        $ALL_STUTTER / $((ALL_TOTAL - 1)) frames"
echo "Stutter rate:    ${ALL_RATE}%"
echo "Max jitter:      ${ALL_MAX}s"
echo "Avg jitter:      ${ALL_AVG}s"
echo ""
echo "=== Stable (skip first ${SKIP_SECONDS}s) ==="
echo "Stutters:        $STABLE_STUTTER / $((STABLE_TOTAL - 1)) frames"
echo "Stutter rate:    ${STABLE_RATE}%"
echo "Max jitter:      ${STABLE_MAX}s"
echo "Avg jitter:      ${STABLE_AVG}s"
echo ""

if [ "$(echo "$STABLE_RATE > 5" | bc)" -eq 1 ]; then
    echo "FAIL: stable stutter rate exceeds 5%"
    exit 1
elif [ "$(echo "$STABLE_RATE > 1" | bc)" -eq 1 ]; then
    echo "WARN: stable stutter rate exceeds 1%"
    exit 0
else
    echo "PASS: minimal stutter detected"
    exit 0
fi
