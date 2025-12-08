#!/usr/bin/env python3
"""
Quick helper to visualize the CSV that mi_event_log writes.

Usage:
    python tools/plot_mi_log.py /path/to/mimalloc-events.csv [output.png]
If an output path is provided the plot is saved there, otherwise a window is shown.
"""

import csv
import sys
from pathlib import Path

import matplotlib.pyplot as plt


def load_events(csv_path):
  timestamps = []
  delta = []
  allocs = []
  frees = []
  with open(csv_path, newline="") as handle:
    reader = csv.DictReader(handle)
    for row in reader:
      timestamps.append(int(row["timestamp_us"]))
      allocs.append(int(row["alloc_count"]))
      frees.append(int(row["free_count"]))
      delta.append(int(row["delta"]))
  return timestamps, delta, allocs, frees


def plot(csv_path, output_path=None):
  timestamps, delta, allocs, frees = load_events(csv_path)
  if not timestamps:
    print("No rows found in", csv_path)
    return

  # Convert to milliseconds for easier reading in plots.
  times_ms = [(t / 1000.0) for t in timestamps]

  fig, axes = plt.subplots(2, 1, figsize=(10, 6), sharex=True)
  axes[0].plot(times_ms, allocs, label="alloc_count", color="tab:blue")
  axes[0].plot(times_ms, frees, label="free_count", color="tab:orange")
  axes[0].set_ylabel("Count")
  axes[0].legend()
  axes[0].grid(True, linestyle="--", alpha=0.3)

  axes[1].plot(times_ms, delta, label="delta (alloc-free)", color="tab:green")
  axes[1].set_xlabel("Time (ms since start)")
  axes[1].set_ylabel("Delta")
  axes[1].legend()
  axes[1].grid(True, linestyle="--", alpha=0.3)

  fig.suptitle("mimalloc allocation/free timeline")
  fig.tight_layout()

  if output_path:
    fig.savefig(output_path, dpi=150)
    print(f"Saved plot to {output_path}")
  else:
    plt.show()


def main():
  if len(sys.argv) < 2:
    print("Usage: python tools/plot_mi_log.py /path/to/log.csv [output.png]")
    sys.exit(1)
  csv_path = Path(sys.argv[1]).expanduser()
  output_path = Path(sys.argv[2]).expanduser() if len(sys.argv) > 2 else None
  plot(csv_path, output_path)


if __name__ == "__main__":
  main()
