#!/usr/bin/env python3
"""
CPU Loading Monitor - Visualization Tool
Parse and visualize CPU usage data from the cpuloading_monitor kernel module.

Usage:
    python3 visualize_cpu.py <input_file> [options]

Input formats:
    - JSON format: /proc/cpuloading/json
    - CSV format: /proc/cpuloading/csv
    - Raw format: /proc/cpuloading/raw

Examples:
    # Copy data from kernel module
    cat /proc/cpuloading/json > cpu_data.json
    python3 visualize_cpu.py cpu_data.json

    # Or directly from /proc
    sudo cat /proc/cpuloading/json | python3 visualize_cpu.py -

    # Filter by PID
    python3 visualize_cpu.py cpu_data.json --pid 1234

    # Generate specific chart
    python3 visualize_cpu.py cpu_data.json --type timeline
    python3 visualize_cpu.py cpu_data.json --type heatmap
    python3 visualize_cpu.py cpu_data.json --type stacked
"""

import json
import csv
import sys
import argparse
from datetime import datetime
from collections import defaultdict
import os

try:
    import matplotlib
    matplotlib.use('Agg')
    import matplotlib.pyplot as plt
    import matplotlib.dates as mdates
    from matplotlib.gridspec import GridSpec
    import numpy as np
    HAS_MATPLOTLIB = True
except ImportError:
    HAS_MATPLOTLIB = False
    print("Warning: matplotlib not found. Install with: pip install matplotlib numpy")
    print("Text output will be generated instead.")


def parse_json_file(filepath):
    """Parse JSON format data."""
    if filepath == '-':
        data = json.load(sys.stdin)
    else:
        with open(filepath, 'r') as f:
            data = json.load(f)
    
    samples = []
    for s in data.get('samples', []):
        samples.append({
            'timestamp_ms': s['timestamp_ms'],
            'pid': s['pid'],
            'comm': s['comm'],
            'cpu_usage_percent': s['cpu_usage_percent'],
            'utime_delta': s.get('utime_delta', 0),
            'stime_delta': s.get('stime_delta', 0)
        })
    
    return {
        'sample_interval_ms': data.get('sample_interval_ms', 1000),
        'monitor_pid': data.get('monitor_pid', -1),
        'samples': samples
    }


def parse_csv_file(filepath):
    """Parse CSV format data."""
    samples = []
    
    if filepath == '-':
        reader = csv.DictReader(sys.stdin)
    else:
        f = open(filepath, 'r')
        reader = csv.DictReader(f)
    
    for row in reader:
        samples.append({
            'timestamp_ms': int(row['timestamp_ms']),
            'pid': int(row['pid']),
            'comm': row['comm'],
            'cpu_usage_percent': float(row['cpu_usage_percent']),
            'utime_delta': int(row.get('utime_delta', 0)),
            'stime_delta': int(row.get('stime_delta', 0))
        })
    
    if filepath != '-':
        f.close()
    
    return {'samples': samples}


def parse_raw_file(filepath):
    """Parse raw format data."""
    samples = []
    
    if filepath == '-':
        lines = sys.stdin.readlines()
    else:
        with open(filepath, 'r') as f:
            lines = f.readlines()
    
    for line in lines:
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        
        parts = line.split()
        if len(parts) >= 4:
            samples.append({
                'timestamp_ms': int(parts[0]),
                'pid': int(parts[1]),
                'comm': parts[2],
                'cpu_usage_percent': float(parts[3]),
                'utime_delta': int(parts[4]) if len(parts) > 4 else 0,
                'stime_delta': int(parts[5]) if len(parts) > 5 else 0
            })
    
    return {'samples': samples}


def detect_format(filepath):
    """Auto-detect file format."""
    if filepath == '-':
        first_line = sys.stdin.readline()
        sys.stdin.seek(0) if hasattr(sys.stdin, 'seek') else None
        if first_line.strip().startswith('{'):
            return 'json'
        elif 'timestamp_ms' in first_line:
            return 'csv'
        return 'raw'
    
    with open(filepath, 'r') as f:
        first_line = f.readline().strip()
    
    if first_line.startswith('{'):
        return 'json'
    elif 'timestamp_ms' in first_line or first_line.startswith('timestamp_ms'):
        return 'csv'
    else:
        return 'raw'


def parse_file(filepath, fmt='auto'):
    """Parse input file with auto-detection."""
    if fmt == 'auto':
        fmt = detect_format(filepath)
    
    print(f"Detected format: {fmt}")
    
    if fmt == 'json':
        return parse_json_file(filepath)
    elif fmt == 'csv':
        return parse_csv_file(filepath)
    else:
        return parse_raw_file(filepath)


def print_text_report(data, filter_pid=None, top_n=10):
    """Generate text-based report."""
    samples = data['samples']
    
    if filter_pid is not None:
        samples = [s for s in samples if s['pid'] == filter_pid]
    
    if not samples:
        print("No samples found.")
        return
    
    pid_stats = defaultdict(lambda: {
        'comm': '',
        'samples': [],
        'total_cpu': 0,
        'max_cpu': 0,
        'count': 0
    })
    
    for s in samples:
        pid = s['pid']
        pid_stats[pid]['comm'] = s['comm']
        pid_stats[pid]['samples'].append(s)
        pid_stats[pid]['total_cpu'] += s['cpu_usage_percent']
        pid_stats[pid]['count'] += 1
        if s['cpu_usage_percent'] > pid_stats[pid]['max_cpu']:
            pid_stats[pid]['max_cpu'] = s['cpu_usage_percent']
    
    print("\n" + "="*70)
    print("CPU Loading Monitor - Analysis Report")
    print("="*70)
    print(f"Total samples: {len(samples)}")
    print(f"Unique processes: {len(pid_stats)}")
    if data.get('sample_interval_ms'):
        print(f"Sample interval: {data['sample_interval_ms']} ms")
    print()
    
    sorted_pids = sorted(pid_stats.items(), 
                        key=lambda x: x[1]['total_cpu'], 
                        reverse=True)
    
    print(f"Top {top_n} CPU-consuming processes:")
    print("-"*70)
    print(f"{'PID':<8} {'COMM':<16} {'AVG%':<10} {'MAX%':<10} {'SAMPLES':<10}")
    print("-"*70)
    
    for pid, stats in sorted_pids[:top_n]:
        avg_cpu = stats['total_cpu'] / stats['count'] if stats['count'] > 0 else 0
        print(f"{pid:<8} {stats['comm']:<16} {avg_cpu:<10.2f} {stats['max_cpu']:<10.2f} {stats['count']:<10}")
    
    if filter_pid is not None and filter_pid in pid_stats:
        stats = pid_stats[filter_pid]
        print(f"\nDetailed statistics for PID {filter_pid}:")
        print("-"*70)
        avg_cpu = stats['total_cpu'] / stats['count'] if stats['count'] > 0 else 0
        print(f"  Process name: {stats['comm']}")
        print(f"  Sample count: {stats['count']}")
        print(f"  Average CPU:  {avg_cpu:.2f}%")
        print(f"  Maximum CPU:  {stats['max_cpu']:.2f}%")
        
        if stats['samples']:
            first_ts = stats['samples'][0]['timestamp_ms']
            last_ts = stats['samples'][-1]['timestamp_ms']
            duration_sec = (last_ts - first_ts) / 1000
            print(f"  Duration:     {duration_sec:.1f} seconds")


def plot_timeline(data, output_file, filter_pid=None, top_n=5):
    """Generate timeline plot for CPU usage."""
    if not HAS_MATPLOTLIB:
        print("matplotlib not available. Cannot generate plot.")
        return
    
    samples = data['samples']
    
    pid_data = defaultdict(list)
    for s in samples:
        pid_data[s['pid']].append(s)
    
    if filter_pid is not None:
        pids_to_plot = [filter_pid] if filter_pid in pid_data else []
    else:
        sorted_pids = sorted(pid_data.items(), 
                            key=lambda x: sum(s['cpu_usage_percent'] for s in s[1]),
                            reverse=True)
        pids_to_plot = [p[0] for p in sorted_pids[:top_n]]
    
    if not pids_to_plot:
        print("No data to plot.")
        return
    
    fig, ax = plt.subplots(figsize=(14, 6))
    
    colors = plt.cm.tab10(np.linspace(0, 1, len(pids_to_plot)))
    
    for idx, pid in enumerate(pids_to_plot):
        pid_samples = pid_data[pid]
        timestamps = [datetime.fromtimestamp(s['timestamp_ms'] / 1000) for s in pid_samples]
        cpu_values = [s['cpu_usage_percent'] for s in pid_samples]
        comm = pid_samples[0]['comm'] if pid_samples else str(pid)
        
        ax.plot(timestamps, cpu_values, label=f"{comm} (PID {pid})", 
               color=colors[idx], linewidth=1.5, alpha=0.8)
    
    ax.set_xlabel('Time', fontsize=12)
    ax.set_ylabel('CPU Usage (%)', fontsize=12)
    ax.set_title('CPU Usage Timeline', fontsize=14, fontweight='bold')
    ax.legend(loc='upper right', fontsize=9)
    ax.grid(True, alpha=0.3)
    ax.xaxis.set_major_formatter(mdates.DateFormatter('%H:%M:%S'))
    fig.autofmt_xdate()
    
    plt.tight_layout()
    plt.savefig(output_file, dpi=150, bbox_inches='tight')
    print(f"Timeline plot saved to: {output_file}")


def plot_stacked(data, output_file, top_n=10):
    """Generate stacked area chart for CPU usage."""
    if not HAS_MATPLOTLIB:
        print("matplotlib not available. Cannot generate plot.")
        return
    
    samples = data['samples']
    
    pid_data = defaultdict(list)
    for s in samples:
        pid_data[s['pid']].append(s)
    
    sorted_pids = sorted(pid_data.items(), 
                        key=lambda x: sum(s['cpu_usage_percent'] for s in s[1]),
                        reverse=True)
    top_pids = [p[0] for p in sorted_pids[:top_n]]
    
    all_timestamps = sorted(set(s['timestamp_ms'] for s in samples))
    
    pid_cpu_by_time = {}
    for pid in top_pids:
        pid_cpu_by_time[pid] = {}
        for s in pid_data[pid]:
            pid_cpu_by_time[pid][s['timestamp_ms']] = s['cpu_usage_percent']
    
    timestamps_dt = [datetime.fromtimestamp(ts / 1000) for ts in all_timestamps]
    
    fig, ax = plt.subplots(figsize=(14, 6))
    
    stacks = []
    labels = []
    colors = plt.cm.tab10(np.linspace(0, 1, len(top_pids)))
    
    for idx, pid in enumerate(top_pids):
        values = [pid_cpu_by_time[pid].get(ts, 0) for ts in all_timestamps]
        stacks.append(values)
        comm = pid_data[pid][0]['comm'] if pid_data[pid] else str(pid)
        labels.append(f"{comm} (PID {pid})")
    
    ax.stackplot(timestamps_dt, stacks, labels=labels, colors=colors, alpha=0.8)
    
    ax.set_xlabel('Time', fontsize=12)
    ax.set_ylabel('CPU Usage (%)', fontsize=12)
    ax.set_title('CPU Usage Stacked View (Top Processes)', fontsize=14, fontweight='bold')
    ax.legend(loc='upper right', fontsize=8, ncol=2)
    ax.grid(True, alpha=0.3)
    ax.xaxis.set_major_formatter(mdates.DateFormatter('%H:%M:%S'))
    fig.autofmt_xdate()
    
    plt.tight_layout()
    plt.savefig(output_file, dpi=150, bbox_inches='tight')
    print(f"Stacked plot saved to: {output_file}")


def plot_heatmap(data, output_file, filter_pid=None):
    """Generate heatmap for CPU usage over time."""
    if not HAS_MATPLOTLIB:
        print("matplotlib not available. Cannot generate plot.")
        return
    
    samples = data['samples']
    
    if filter_pid is not None:
        samples = [s for s in samples if s['pid'] == filter_pid]
    
    if not samples:
        print("No data to plot.")
        return
    
    pid_data = defaultdict(list)
    for s in samples:
        pid_data[s['pid']].append(s)
    
    pids = sorted(pid_data.keys())
    
    all_timestamps = sorted(set(s['timestamp_ms'] for s in samples))
    
    n_bins = min(100, len(all_timestamps))
    time_bins = np.linspace(min(all_timestamps), max(all_timestamps), n_bins + 1)
    
    heatmap_data = np.zeros((len(pids), n_bins))
    
    for i, pid in enumerate(pids):
        for s in pid_data[pid]:
            ts = s['timestamp_ms']
            bin_idx = np.searchsorted(time_bins, ts) - 1
            if 0 <= bin_idx < n_bins:
                heatmap_data[i, bin_idx] = max(heatmap_data[i, bin_idx], s['cpu_usage_percent'])
    
    fig, ax = plt.subplots(figsize=(14, max(6, len(pids) * 0.3)))
    
    im = ax.imshow(heatmap_data, aspect='auto', cmap='YlOrRd', 
                   extent=[0, n_bins, len(pids)-0.5, -0.5])
    
    y_labels = []
    for pid in pids:
        comm = pid_data[pid][0]['comm'] if pid_data[pid] else str(pid)
        y_labels.append(f"{comm[:12]}:{pid}")
    
    ax.set_yticks(range(len(pids)))
    ax.set_yticklabels(y_labels, fontsize=8)
    
    ax.set_xlabel('Time Bins', fontsize=12)
    ax.set_ylabel('Process', fontsize=12)
    ax.set_title('CPU Usage Heatmap', fontsize=14, fontweight='bold')
    
    cbar = plt.colorbar(im, ax=ax)
    cbar.set_label('CPU Usage (%)', fontsize=10)
    
    plt.tight_layout()
    plt.savefig(output_file, dpi=150, bbox_inches='tight')
    print(f"Heatmap saved to: {output_file}")


def plot_summary(data, output_file, filter_pid=None):
    """Generate summary dashboard with multiple charts."""
    if not HAS_MATPLOTLIB:
        print("matplotlib not available. Cannot generate plot.")
        return
    
    samples = data['samples']
    
    if filter_pid is not None:
        samples = [s for s in samples if s['pid'] == filter_pid]
    
    if not samples:
        print("No data to plot.")
        return
    
    pid_stats = defaultdict(lambda: {'comm': '', 'samples': [], 'total': 0, 'max': 0})
    for s in samples:
        pid = s['pid']
        pid_stats[pid]['comm'] = s['comm']
        pid_stats[pid]['samples'].append(s)
        pid_stats[pid]['total'] += s['cpu_usage_percent']
        if s['cpu_usage_percent'] > pid_stats[pid]['max']:
            pid_stats[pid]['max'] = s['cpu_usage_percent']
    
    sorted_pids = sorted(pid_stats.items(), key=lambda x: x[1]['total'], reverse=True)
    top_pids = sorted_pids[:10]
    
    fig = plt.figure(figsize=(16, 10))
    gs = GridSpec(2, 2, figure=fig, hspace=0.3, wspace=0.3)
    
    ax1 = fig.add_subplot(gs[0, 0])
    pids = [p[0] for p in top_pids]
    avg_cpus = [p[1]['total'] / len(p[1]['samples']) for p in top_pids]
    comms = [p[1]['comm'][:10] for p in top_pids]
    
    bars = ax1.barh(range(len(pids)), avg_cpus, color='steelblue')
    ax1.set_yticks(range(len(pids)))
    ax1.set_yticklabels([f"{c}:{pid}" for c, pid in zip(comms, pids)])
    ax1.set_xlabel('Average CPU Usage (%)')
    ax1.set_title('Top 10 Processes by Average CPU', fontweight='bold')
    ax1.invert_yaxis()
    for i, v in enumerate(avg_cpus):
        ax1.text(v + 0.1, i, f'{v:.1f}%', va='center', fontsize=8)
    
    ax2 = fig.add_subplot(gs[0, 1])
    max_cpus = [p[1]['max'] for p in top_pids]
    bars = ax2.barh(range(len(pids)), max_cpus, color='coral')
    ax2.set_yticks(range(len(pids)))
    ax2.set_yticklabels([f"{c}:{pid}" for c, pid in zip(comms, pids)])
    ax2.set_xlabel('Maximum CPU Usage (%)')
    ax2.set_title('Top 10 Processes by Peak CPU', fontweight='bold')
    ax2.invert_yaxis()
    for i, v in enumerate(max_cpus):
        ax2.text(v + 0.1, i, f'{v:.1f}%', va='center', fontsize=8)
    
    ax3 = fig.add_subplot(gs[1, :])
    
    top_5_pids = [p[0] for p in top_pids[:5]]
    colors = plt.cm.tab10(np.linspace(0, 1, len(top_5_pids)))
    
    for idx, pid in enumerate(top_5_pids):
        pid_samples = pid_stats[pid]['samples']
        timestamps = [datetime.fromtimestamp(s['timestamp_ms'] / 1000) for s in pid_samples]
        cpu_values = [s['cpu_usage_percent'] for s in pid_samples]
        comm = pid_stats[pid]['comm']
        ax3.plot(timestamps, cpu_values, label=f"{comm} (PID {pid})", 
                color=colors[idx], linewidth=1.5, alpha=0.8)
    
    ax3.set_xlabel('Time', fontsize=12)
    ax3.set_ylabel('CPU Usage (%)', fontsize=12)
    ax3.set_title('CPU Usage Timeline (Top 5 Processes)', fontsize=14, fontweight='bold')
    ax3.legend(loc='upper right', fontsize=9)
    ax3.grid(True, alpha=0.3)
    ax3.xaxis.set_major_formatter(mdates.DateFormatter('%H:%M:%S'))
    fig.autofmt_xdate()
    
    fig.suptitle('CPU Loading Monitor - Summary Dashboard', fontsize=16, fontweight='bold', y=0.98)
    
    plt.tight_layout()
    plt.savefig(output_file, dpi=150, bbox_inches='tight')
    print(f"Summary dashboard saved to: {output_file}")


def main():
    parser = argparse.ArgumentParser(
        description='CPU Loading Monitor Visualization Tool',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  %(prog)s cpu_data.json
  %(prog)s cpu_data.json --pid 1234
  %(prog)s cpu_data.json --type summary -o dashboard.png
  cat /proc/cpuloading/json | %(prog)s -
        """
    )
    
    parser.add_argument('input_file', help='Input file path (use "-" for stdin)')
    parser.add_argument('--format', '-f', choices=['json', 'csv', 'raw', 'auto'],
                       default='auto', help='Input format (default: auto-detect)')
    parser.add_argument('--pid', '-p', type=int, default=None,
                       help='Filter by specific PID')
    parser.add_argument('--type', '-t', choices=['timeline', 'stacked', 'heatmap', 'summary'],
                       default='summary', help='Chart type (default: summary)')
    parser.add_argument('--output', '-o', default=None,
                       help='Output file for chart (default: cpu_<type>.png)')
    parser.add_argument('--text', action='store_true',
                       help='Output text report instead of chart')
    parser.add_argument('--top', type=int, default=10,
                       help='Number of top processes to show (default: 10)')
    
    args = parser.parse_args()
    
    data = parse_file(args.input_file, args.format)
    
    if not data['samples']:
        print("No samples found in input.")
        sys.exit(1)
    
    print(f"Loaded {len(data['samples'])} samples")
    
    if args.text or not HAS_MATPLOTLIB:
        print_text_report(data, args.pid, args.top)
        return
    
    if args.output is None:
        args.output = f"cpu_{args.type}.png"
    
    if args.type == 'timeline':
        plot_timeline(data, args.output, args.pid, args.top)
    elif args.type == 'stacked':
        plot_stacked(data, args.output, args.top)
    elif args.type == 'heatmap':
        plot_heatmap(data, args.output, args.pid)
    elif args.type == 'summary':
        plot_summary(data, args.output, args.pid)


if __name__ == '__main__':
    main()
