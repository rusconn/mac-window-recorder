#!/usr/bin/env python3
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

"""Verify frame stutter in a recorded video file.

Extracts per-frame PTS timestamps via ffprobe and reports jitter statistics
compared against an expected frame rate.
"""

import argparse
import math
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path


@dataclass
class StutterReport:
    total_frames: int
    stutter_count: int
    max_jitter: float
    avg_jitter: float
    stutter_rate: float

    @property
    def frame_count(self) -> int:
        return self.total_frames - 1


def extract_frame_timestamps(video: Path) -> list[float]:
    result = subprocess.run(
        [
            "ffprobe", "-v", "quiet", "-select_streams", "v:0",
            "-show_entries", "frame=pts_time",
            "-of", "csv=p=0", str(video),
        ],
        capture_output=True, text=True, check=True,
    )
    return [float(line.strip().rstrip(",")) for line in result.stdout.splitlines() if line.strip()]


def compute_stutter(timestamps: list[float], interval: float, threshold: float) -> StutterReport:
    if len(timestamps) < 2:
        return StutterReport(total_frames=len(timestamps), stutter_count=0,
                             max_jitter=0.0, avg_jitter=0.0, stutter_rate=0.0)

    total = len(timestamps)
    stutter = 0
    max_jitter = 0.0
    sum_jitter = 0.0

    for i in range(1, total):
        delta = timestamps[i] - timestamps[i - 1]
        dev = abs(delta - interval)
        sum_jitter += dev
        if dev > max_jitter:
            max_jitter = dev
        if dev > threshold:
            stutter += 1

    n = total - 1
    return StutterReport(
        total_frames=total,
        stutter_count=stutter,
        max_jitter=max_jitter,
        avg_jitter=sum_jitter / n,
        stutter_rate=stutter * 100.0 / n,
    )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("video_file", type=Path, help="Video file to analyze")
    parser.add_argument("expected_fps", type=float, nargs="?", default=60.0,
                        help="Expected frame rate (default: 60)")
    parser.add_argument("skip_seconds", type=float, nargs="?", default=1.0,
                        help="Seconds to skip for stable measurement (default: 1.0)")
    args = parser.parse_args()

    if not args.video_file.is_file():
        print(f"Error: file not found: {args.video_file}", file=sys.stderr)
        sys.exit(1)

    interval = math.trunc(1.0 / args.expected_fps * 1_000_000) / 1_000_000
    threshold = math.trunc(interval * 0.5 * 1_000_000) / 1_000_000

    timestamps = extract_frame_timestamps(args.video_file)
    if len(timestamps) < 2:
        print(f"Error: not enough frames in {args.video_file}", file=sys.stderr)
        sys.exit(1)

    duration = timestamps[-1] - timestamps[0]
    actual_fps = (len(timestamps) - 1) / duration if duration > 0 else 0.0

    all_report = compute_stutter(timestamps, interval, threshold)

    skip_ts = timestamps[0] + args.skip_seconds
    stable_timestamps = [t for t in timestamps if t >= skip_ts]
    stable_report = compute_stutter(stable_timestamps, interval, threshold)

    print("=== Stutter Verification ===")
    print(f"File:            {args.video_file}")
    print(f"Total frames:    {all_report.total_frames}")
    print(f"Duration:        {duration}s")
    print(f"Expected FPS:    {args.expected_fps}")
    print(f"Actual FPS:      {actual_fps:.2f}")
    print(f"Frame interval:  {interval}s")
    print(f"Jitter threshold: {threshold}s")
    print()
    print("=== All Frames ===")
    print(f"Stutters:        {all_report.stutter_count} / {all_report.frame_count} frames")
    print(f"Stutter rate:    {all_report.stutter_rate:.2f}%")
    print(f"Max jitter:      {all_report.max_jitter:.6f}s")
    print(f"Avg jitter:      {all_report.avg_jitter:.6f}s")
    print()
    print(f"=== Stable (skip first {args.skip_seconds}s) ===")
    print(f"Stutters:        {stable_report.stutter_count} / {stable_report.frame_count} frames")
    print(f"Stutter rate:    {stable_report.stutter_rate:.2f}%")
    print(f"Max jitter:      {stable_report.max_jitter:.6f}s")
    print(f"Avg jitter:      {stable_report.avg_jitter:.6f}s")
    print()

    if stable_report.stutter_rate > 5:
        print("FAIL: stable stutter rate exceeds 5%")
        sys.exit(1)
    elif stable_report.stutter_rate > 1:
        print("WARN: stable stutter rate exceeds 1%")
    else:
        print("PASS: minimal stutter detected")


if __name__ == "__main__":
    main()
