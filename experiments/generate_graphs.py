#!/usr/bin/env python3
"""
generate_graphs.py
==================
Generates thesis-ready graphs from experiment CSV results.

Usage:
    python3 generate_graphs.py --results <path_to_results_dir> --scenario <1-5>

Examples:
    python3 generate_graphs.py --results experiments/results/01_ha_recovery_20260417_120000 --scenario 1
    python3 generate_graphs.py --results experiments/results/02_live_migration_20260417_140000 --scenario 2
    python3 generate_graphs.py --results experiments/results/03_resource_comparison_20260417_150000 --scenario 3
    python3 generate_graphs.py --results experiments/results/04_vm_spinup_20260417_160000 --scenario 4
    python3 generate_graphs.py --results experiments/results/05_cluster_startup_20260417_170000 --scenario 5

Output:
    PNG graphs saved to <results_dir>/graphs/
    Ready to insert into thesis document.
"""

import argparse
import os
import sys
import glob
import statistics
from pathlib import Path

import pandas as pd
import matplotlib.pyplot as plt
import matplotlib.patches as mpatches
import numpy as np

# =============================================================================
# STYLE CONFIGURATION
# Academic-friendly style - clean, readable, printable
# =============================================================================

COLORS = {
    'master':  '#2196F3',   # blue
    'worker1': '#4CAF50',   # green
    'worker2': '#FF9800',   # orange
    'vm1':     '#9C27B0',   # purple
    'vm2':     '#F44336',   # red
    'ok':      '#4CAF50',   # green
    'fail':    '#F44336',   # red
    'timeout_300': '#2196F3',
    'timeout_60':  '#FF9800',
    'timeout_30':  '#F44336',
    'unloaded': '#4CAF50',
    'loaded':   '#F44336',
}

def setup_style():
    plt.rcParams.update({
        'figure.dpi': 150,
        'font.family': 'sans-serif',
        'font.size': 11,
        'axes.titlesize': 13,
        'axes.labelsize': 11,
        'axes.grid': True,
        'grid.alpha': 0.3,
        'axes.spines.top': False,
        'axes.spines.right': False,
        'legend.framealpha': 0.9,
        'savefig.bbox': 'tight',
        'savefig.pad_inches': 0.2,
    })

def save_fig(fig, path, title=""):
    """Save figure and print confirmation."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fig.savefig(path, dpi=150, bbox_inches='tight')
    plt.close(fig)
    print(f"  Saved: {path}")

# =============================================================================
# SCENARIO 1 - HA RECOVERY GRAPHS
# =============================================================================

def generate_ha_recovery_graphs(results_dir, graphs_dir):
    print("\nGenerating Scenario 1 - HA Recovery graphs...")

    timeouts = [300, 60, 30]
    recovery_data = {}
    downtime_data = {}

    for timeout in timeouts:
        timeout_dir = os.path.join(results_dir, f"timeout_{timeout}s")
        summary_file = os.path.join(timeout_dir, "timing_summary.csv")

        if not os.path.exists(summary_file):
            print(f"  WARNING: No data for timeout {timeout}s - skipping")
            continue

        df = pd.read_csv(summary_file)

        # Extract VM recovery times
        recovery = df[df['label'].str.contains('vm_recovery')]['seconds']
        recovery = pd.to_numeric(recovery, errors='coerce').dropna()
        if len(recovery) > 0:
            recovery_data[timeout] = recovery.tolist()

        # Extract HTTP downtime
        downtime = df[df['label'].str.contains('http_downtime')]['seconds']
        downtime = pd.to_numeric(downtime, errors='coerce').dropna()
        if len(downtime) > 0:
            downtime_data[timeout] = downtime.tolist()

    if not recovery_data:
        print("  No recovery data found - skipping HA graphs")
        return

    # --- Graph 1: VM Recovery Time Box Plot ---
    fig, ax = plt.subplots(figsize=(8, 5))

    labels = [f"{t}s\neviction" for t in recovery_data.keys()]
    data = list(recovery_data.values())
    colors = [COLORS[f'timeout_{t}'] for t in recovery_data.keys()]

    bp = ax.boxplot(data, labels=labels, patch_artist=True, notch=False)
    for patch, color in zip(bp['boxes'], colors):
        patch.set_facecolor(color)
        patch.set_alpha(0.7)

    ax.set_title('VM Recovery Time by Eviction Timeout')
    ax.set_xlabel('Eviction Timeout Setting')
    ax.set_ylabel('Recovery Time (seconds)')

    # Add mean values above boxes
    for i, values in enumerate(data):
        mean_val = statistics.mean(values)
        ax.text(i + 1, max(values) + 2, f'avg: {mean_val:.0f}s',
                ha='center', va='bottom', fontsize=9, color='#333333')

    save_fig(fig, os.path.join(graphs_dir, '01_ha_recovery_time_boxplot.png'))

    # --- Graph 2: Recovery Time per Run (Line Chart) ---
    fig, ax = plt.subplots(figsize=(10, 5))

    for timeout, values in recovery_data.items():
        runs = list(range(1, len(values) + 1))
        ax.plot(runs, values, 'o-',
                label=f'{timeout}s eviction',
                color=COLORS[f'timeout_{timeout}'],
                linewidth=2, markersize=6)

    ax.set_title('VM Recovery Time per Run')
    ax.set_xlabel('Run Number')
    ax.set_ylabel('Recovery Time (seconds)')
    ax.legend()
    ax.set_xticks(range(1, max(len(v) for v in recovery_data.values()) + 1))

    save_fig(fig, os.path.join(graphs_dir, '01_ha_recovery_time_per_run.png'))

    # --- Graph 3: HTTP Downtime Comparison ---
    if downtime_data:
        fig, ax = plt.subplots(figsize=(8, 5))

        labels = [f"{t}s" for t in downtime_data.keys()]
        means = [statistics.mean(v) for v in downtime_data.values()]
        stds = [statistics.stdev(v) if len(v) > 1 else 0 for v in downtime_data.values()]
        colors = [COLORS[f'timeout_{t}'] for t in downtime_data.keys()]

        bars = ax.bar(labels, means, yerr=stds, color=colors, alpha=0.7,
                      capsize=5, error_kw={'linewidth': 2})

        ax.set_title('Average HTTP Downtime by Eviction Timeout')
        ax.set_xlabel('Eviction Timeout Setting')
        ax.set_ylabel('HTTP Downtime (seconds)')

        for bar, mean in zip(bars, means):
            ax.text(bar.get_x() + bar.get_width() / 2,
                    bar.get_height() + 1,
                    f'{mean:.0f}s', ha='center', va='bottom', fontsize=10)

        save_fig(fig, os.path.join(graphs_dir, '01_ha_http_downtime.png'))

    # --- Graph 4: Summary statistics table ---
    fig, ax = plt.subplots(figsize=(10, 4))
    ax.axis('off')

    table_data = []
    for timeout in recovery_data:
        vals = recovery_data[timeout]
        row = [
            f"{timeout}s",
            f"{statistics.mean(vals):.1f}s",
            f"{min(vals):.1f}s",
            f"{max(vals):.1f}s",
            f"{statistics.stdev(vals):.1f}s" if len(vals) > 1 else "N/A",
            f"{statistics.mean(downtime_data.get(timeout, [0])):.1f}s"
        ]
        table_data.append(row)

    columns = ['Eviction\nTimeout', 'Avg Recovery', 'Min Recovery',
               'Max Recovery', 'Std Dev', 'Avg HTTP\nDowntime']
    table = ax.table(cellText=table_data, colLabels=columns,
                     loc='center', cellLoc='center')
    table.auto_set_font_size(False)
    table.set_fontsize(10)
    table.scale(1.2, 2)

    # Style header
    for j in range(len(columns)):
        table[0, j].set_facecolor('#2196F3')
        table[0, j].set_text_props(color='white', fontweight='bold')

    ax.set_title('HA Recovery Statistics Summary', pad=20, fontsize=13)
    save_fig(fig, os.path.join(graphs_dir, '01_ha_summary_table.png'))

    print("  Scenario 1 graphs complete!")

# =============================================================================
# SCENARIO 2 - LIVE MIGRATION GRAPHS
# =============================================================================

def generate_migration_graphs(results_dir, graphs_dir):
    print("\nGenerating Scenario 2 - Live Migration graphs...")

    conditions = ['unloaded', 'loaded']
    migration_data = {}
    http_data = {}

    for condition in conditions:
        condition_dir = os.path.join(results_dir, condition)
        summary_file = os.path.join(condition_dir, "timing_summary.csv")

        if not os.path.exists(summary_file):
            print(f"  WARNING: No data for {condition} - skipping")
            continue

        df = pd.read_csv(summary_file)

        durations = df[df['label'].str.contains('migration_duration')]['seconds']
        durations = pd.to_numeric(durations, errors='coerce').dropna()
        if len(durations) > 0:
            migration_data[condition] = durations.tolist()

        # Collect HTTP failure data from CSV files
        http_files = glob.glob(os.path.join(condition_dir, 'http_run*.csv'))
        fails_per_run = []
        for hf in sorted(http_files):
            try:
                hdf = pd.read_csv(hf)
                total = len(hdf)
                fails = len(hdf[hdf['status'] != 'OK'])
                fails_per_run.append(fails)
            except Exception:
                pass
        if fails_per_run:
            http_data[condition] = fails_per_run

    if not migration_data:
        print("  No migration data found - skipping")
        return

    # --- Graph 1: Migration Duration Box Plot ---
    fig, ax = plt.subplots(figsize=(7, 5))

    labels = list(migration_data.keys())
    data = list(migration_data.values())
    colors = [COLORS[c] for c in labels]

    bp = ax.boxplot(data, labels=[l.capitalize() for l in labels],
                    patch_artist=True)
    for patch, color in zip(bp['boxes'], colors):
        patch.set_facecolor(color)
        patch.set_alpha(0.7)

    ax.set_title('Live Migration Duration: Idle vs Under Load')
    ax.set_xlabel('VM Condition During Migration')
    ax.set_ylabel('Migration Duration (seconds)')

    for i, values in enumerate(data):
        mean_val = statistics.mean(values)
        ax.text(i + 1, max(values) + 1, f'avg: {mean_val:.0f}s',
                ha='center', va='bottom', fontsize=9)

    save_fig(fig, os.path.join(graphs_dir, '02_migration_duration_boxplot.png'))

    # --- Graph 2: Migration Time per Run ---
    fig, ax = plt.subplots(figsize=(10, 5))

    for condition, values in migration_data.items():
        runs = list(range(1, len(values) + 1))
        ax.plot(runs, values, 'o-',
                label=condition.capitalize(),
                color=COLORS[condition],
                linewidth=2, markersize=6)

    ax.set_title('Migration Duration per Run')
    ax.set_xlabel('Run Number')
    ax.set_ylabel('Duration (seconds)')
    ax.legend()
    ax.set_xticks(range(1, max(len(v) for v in migration_data.values()) + 1))

    save_fig(fig, os.path.join(graphs_dir, '02_migration_duration_per_run.png'))

    # --- Graph 3: HTTP Failures During Migration ---
    if http_data:
        fig, ax = plt.subplots(figsize=(10, 5))

        for condition, values in http_data.items():
            runs = list(range(1, len(values) + 1))
            ax.bar([r + (0.2 if condition == 'loaded' else -0.2) for r in runs],
                   values, width=0.35,
                   label=condition.capitalize(),
                   color=COLORS[condition], alpha=0.7)

        ax.set_title('HTTP Request Failures During Migration')
        ax.set_xlabel('Run Number')
        ax.set_ylabel('Number of Failed Requests')
        ax.legend()
        ax.set_xticks(range(1, max(len(v) for v in http_data.values()) + 1))

        save_fig(fig, os.path.join(graphs_dir, '02_migration_http_failures.png'))

    # --- Graph 4: Summary comparison ---
    fig, ax = plt.subplots(figsize=(8, 4))
    ax.axis('off')

    table_data = []
    for condition in migration_data:
        vals = migration_data[condition]
        http_fails = http_data.get(condition, [0])
        row = [
            condition.capitalize(),
            f"{statistics.mean(vals):.1f}s",
            f"{min(vals):.1f}s",
            f"{max(vals):.1f}s",
            f"{statistics.stdev(vals):.1f}s" if len(vals) > 1 else "N/A",
            f"{statistics.mean(http_fails):.1f}"
        ]
        table_data.append(row)

    columns = ['Condition', 'Avg Duration', 'Min', 'Max', 'Std Dev', 'Avg HTTP\nFailures']
    table = ax.table(cellText=table_data, colLabels=columns,
                     loc='center', cellLoc='center')
    table.auto_set_font_size(False)
    table.set_fontsize(10)
    table.scale(1.2, 2)

    for j in range(len(columns)):
        table[0, j].set_facecolor('#4CAF50')
        table[0, j].set_text_props(color='white', fontweight='bold')

    ax.set_title('Live Migration Statistics Summary', pad=20, fontsize=13)
    save_fig(fig, os.path.join(graphs_dir, '02_migration_summary_table.png'))

    print("  Scenario 2 graphs complete!")

# =============================================================================
# SCENARIO 3 - RESOURCE COMPARISON GRAPHS
# =============================================================================

def generate_resource_graphs(results_dir, graphs_dir):
    print("\nGenerating Scenario 3 - Resource Comparison graphs...")

    phases = {
        'phase1_idle': 'Idle Baseline',
        'phase2_loaded': 'Under VM Load',
        'phase3_recovery': 'Recovery'
    }

    all_data = {}
    for phase_dir, phase_label in phases.items():
        snapshot_file = os.path.join(results_dir, phase_dir, 'metrics_snapshots.csv')
        if os.path.exists(snapshot_file):
            df = pd.read_csv(snapshot_file)
            all_data[phase_label] = df

    if not all_data:
        print("  No resource data found - skipping")
        return

    # Combine all phases
    combined = pd.concat(all_data.values(), keys=all_data.keys())
    combined = combined.reset_index(level=0).rename(columns={'level_0': 'phase'})

    # --- Graph 1: CPU comparison Pi nodes vs VMs across phases ---
    fig, axes = plt.subplots(1, 2, figsize=(14, 5))

    for ax, source_type, title in zip(
        axes,
        ['pi_node', 'vm'],
        ['Pi Node CPU Usage', 'VM CPU Usage']
    ):
        phase_labels = []
        node_data = {}

        for phase_label in phases.values():
            if phase_label in all_data:
                df = all_data[phase_label]
                subset = df[df.get('source_type', df.get('node', '')).str.contains(
                    source_type if 'source_type' in df.columns else '', na=False
                )]
                if 'source_type' not in df.columns:
                    # Fall back to node column
                    subset = df

                for node in subset.get('source_name', subset.get('node', pd.Series())).unique():
                    if node not in node_data:
                        node_data[node] = []
                    node_vals = subset[
                        subset.get('source_name', subset.get('node', pd.Series())) == node
                    ]['cpu_pct'].dropna()
                    node_data[node].append(
                        pd.to_numeric(node_vals, errors='coerce').mean()
                    )

            phase_labels.append(phase_label)

        x = np.arange(len(phase_labels))
        width = 0.25
        node_colors = list(COLORS.values())

        for i, (node, values) in enumerate(node_data.items()):
            offset = (i - len(node_data) / 2) * width
            ax.bar(x + offset, values, width,
                   label=node, alpha=0.8,
                   color=node_colors[i % len(node_colors)])

        ax.set_title(title)
        ax.set_xlabel('Phase')
        ax.set_ylabel('CPU Usage (%)')
        ax.set_xticks(x)
        ax.set_xticklabels(phase_labels, rotation=10)
        ax.legend(fontsize=9)
        ax.set_ylim(0, 100)

    fig.suptitle('CPU Usage: Pi Nodes vs VMs Across Phases', fontsize=14)
    plt.tight_layout()
    save_fig(fig, os.path.join(graphs_dir, '03_cpu_comparison.png'))

    # --- Graph 2: RAM comparison ---
    fig, ax = plt.subplots(figsize=(10, 5))

    phase_list = list(phases.values())
    x = np.arange(len(phase_list))
    width = 0.15
    nodes = ['k3s-master', 'k3s-worker1', 'k3s-worker2', 'ubuntu-vm-1', 'ubuntu-vm-2']
    node_colors = [COLORS['master'], COLORS['worker1'], COLORS['worker2'],
                   COLORS['vm1'], COLORS['vm2']]

    for i, (node, color) in enumerate(zip(nodes, node_colors)):
        values = []
        for phase_label in phase_list:
            if phase_label in all_data:
                df = all_data[phase_label]
                node_col = 'source_name' if 'source_name' in df.columns else 'node'
                node_rows = df[df[node_col] == node]['ram_pct']
                node_rows = pd.to_numeric(node_rows, errors='coerce')
                values.append(node_rows.mean() if len(node_rows) > 0 else 0)
            else:
                values.append(0)

        offset = (i - len(nodes) / 2) * width
        ax.bar(x + offset, values, width, label=node,
               alpha=0.8, color=color)

    ax.set_title('RAM Usage: Pi Nodes vs VMs Across Phases')
    ax.set_xlabel('Phase')
    ax.set_ylabel('RAM Usage (%)')
    ax.set_xticks(x)
    ax.set_xticklabels(phase_list)
    ax.legend(fontsize=9)
    ax.set_ylim(0, 100)

    save_fig(fig, os.path.join(graphs_dir, '03_ram_comparison.png'))

    # --- Graph 3: Network I/O time series ---
    net_file = os.path.join(results_dir, 'network_rx_all.csv')
    if os.path.exists(net_file):
        fig, ax = plt.subplots(figsize=(12, 4))
        df = pd.read_csv(net_file)
        df['datetime'] = pd.to_datetime(df['datetime'])
        df['rx_bytes_per_sec'] = pd.to_numeric(df.get('rx_bytes_per_sec', df.iloc[:, 2]),
                                                errors='coerce')
        df['rx_kbs'] = df['rx_bytes_per_sec'] / 1024

        ax.plot(df['datetime'], df['rx_kbs'], color=COLORS['master'],
                linewidth=1.5, alpha=0.8)
        ax.set_title('Network Receive Rate During Experiment')
        ax.set_xlabel('Time')
        ax.set_ylabel('Receive Rate (KB/s)')
        plt.xticks(rotation=30)

        save_fig(fig, os.path.join(graphs_dir, '03_network_timeseries.png'))

    print("  Scenario 3 graphs complete!")

# =============================================================================
# SCENARIO 4 - VM SPINUP GRAPHS
# =============================================================================

def generate_spinup_graphs(results_dir, graphs_dir):
    print("\nGenerating Scenario 4 - VM Spinup graphs...")

    summary_file = os.path.join(results_dir, 'timing_summary.csv')
    if not os.path.exists(summary_file):
        print("  No timing data found - skipping")
        return

    df = pd.read_csv(summary_file)
    df['seconds'] = pd.to_numeric(df['seconds'], errors='coerce')

    stages = ['disk_import', 'vm_running', 'network_init', 'http_ready', 'TOTAL']
    stage_data = {}

    for stage in stages:
        rows = df[df['label'].str.contains(stage)]['seconds'].dropna()
        if len(rows) > 0:
            stage_data[stage] = rows.tolist()

    if not stage_data:
        print("  No stage data found - skipping")
        return

    # --- Graph 1: Stacked bar chart of deployment stages ---
    fig, ax = plt.subplots(figsize=(10, 5))

    stage_colors = ['#2196F3', '#4CAF50', '#FF9800', '#9C27B0', '#607D8B']
    stage_labels = {
        'disk_import': 'Disk Import',
        'vm_running': 'VM Boot',
        'network_init': 'Network Init',
        'http_ready': 'HTTP Ready',
        'TOTAL': 'Total'
    }

    # Only plot non-TOTAL stages stacked
    plot_stages = [s for s in stages if s != 'TOTAL' and s in stage_data]
    n_runs = max(len(stage_data[s]) for s in plot_stages) if plot_stages else 0

    if n_runs > 0:
        x = np.arange(1, n_runs + 1)
        bottom = np.zeros(n_runs)

        for i, stage in enumerate(plot_stages):
            values = stage_data[stage][:n_runs]
            # Pad if needed
            while len(values) < n_runs:
                values.append(0)
            ax.bar(x, values, bottom=bottom,
                   label=stage_labels.get(stage, stage),
                   color=stage_colors[i], alpha=0.85)
            bottom += np.array(values)

        # Add total line
        if 'TOTAL' in stage_data:
            totals = stage_data['TOTAL'][:n_runs]
            ax.plot(x, totals, 'ko--', linewidth=2,
                    markersize=6, label='Total Time', zorder=5)

        ax.set_title('VM Deployment Time by Stage')
        ax.set_xlabel('Run Number')
        ax.set_ylabel('Time (seconds)')
        ax.legend(loc='upper right', fontsize=9)
        ax.set_xticks(x)

        save_fig(fig, os.path.join(graphs_dir, '04_spinup_stacked_bar.png'))

    # --- Graph 2: Box plot of total deployment time ---
    if 'TOTAL' in stage_data:
        fig, ax = plt.subplots(figsize=(6, 5))

        bp = ax.boxplot(stage_data['TOTAL'], patch_artist=True)
        bp['boxes'][0].set_facecolor('#2196F3')
        bp['boxes'][0].set_alpha(0.7)

        mean_val = statistics.mean(stage_data['TOTAL'])
        ax.axhline(y=mean_val, color='red', linestyle='--',
                   linewidth=1.5, label=f'Mean: {mean_val:.0f}s')

        ax.set_title('Total VM Deployment Time Distribution')
        ax.set_ylabel('Total Time (seconds)')
        ax.set_xticklabels(['All Runs'])
        ax.legend()

        save_fig(fig, os.path.join(graphs_dir, '04_spinup_total_boxplot.png'))

    # --- Graph 3: Stage averages bar chart ---
    fig, ax = plt.subplots(figsize=(9, 5))

    plot_stages_with_totals = [s for s in stages if s in stage_data]
    stage_means = [statistics.mean(stage_data[s]) for s in plot_stages_with_totals]
    stage_stds = [statistics.stdev(stage_data[s]) if len(stage_data[s]) > 1 else 0
                  for s in plot_stages_with_totals]
    colors = stage_colors[:len(plot_stages_with_totals)]

    bars = ax.bar([stage_labels.get(s, s) for s in plot_stages_with_totals],
                  stage_means, yerr=stage_stds,
                  color=colors, alpha=0.8, capsize=5,
                  error_kw={'linewidth': 2})

    for bar, mean in zip(bars, stage_means):
        ax.text(bar.get_x() + bar.get_width() / 2,
                bar.get_height() + 1,
                f'{mean:.0f}s', ha='center', va='bottom', fontsize=9)

    ax.set_title('Average Time per Deployment Stage')
    ax.set_xlabel('Stage')
    ax.set_ylabel('Average Time (seconds)')
    plt.xticks(rotation=15)

    save_fig(fig, os.path.join(graphs_dir, '04_spinup_stage_averages.png'))

    print("  Scenario 4 graphs complete!")

# =============================================================================
# SCENARIO 5 - CLUSTER STARTUP GRAPHS
# =============================================================================

def generate_startup_graphs(results_dir, graphs_dir):
    print("\nGenerating Scenario 5 - Cluster Startup graphs...")

    summary_file = os.path.join(results_dir, 'timing_summary.csv')
    if not os.path.exists(summary_file):
        print("  No timing data found - skipping")
        return

    df = pd.read_csv(summary_file)
    df['seconds'] = pd.to_numeric(df['seconds'], errors='coerce')

    milestones = [
        'api_server_ready',
        'all_nodes_ready',
        'longhorn_healthy',
        'prometheus_ready',
        'grafana_ready',
        'vms_running',
        'vm_http_ready',
        'TOTAL'
    ]

    milestone_labels = {
        'api_server_ready': 'API Server',
        'all_nodes_ready': 'Nodes Ready',
        'longhorn_healthy': 'Longhorn',
        'prometheus_ready': 'Prometheus',
        'grafana_ready': 'Grafana',
        'vms_running': 'VMs Running',
        'vm_http_ready': 'VM HTTP',
        'TOTAL': 'TOTAL'
    }

    milestone_data = {}
    for m in milestones:
        rows = df[df['label'].str.contains(m)]['seconds'].dropna()
        if len(rows) > 0:
            milestone_data[m] = rows.tolist()

    if not milestone_data:
        print("  No milestone data found - skipping")
        return

    # --- Graph 1: Average startup timeline ---
    fig, ax = plt.subplots(figsize=(12, 5))

    plot_milestones = [m for m in milestones if m != 'TOTAL' and m in milestone_data]
    means = [statistics.mean(milestone_data[m]) for m in plot_milestones]
    stds = [statistics.stdev(milestone_data[m]) if len(milestone_data[m]) > 1 else 0
            for m in plot_milestones]
    labels = [milestone_labels[m] for m in plot_milestones]

    colors = plt.cm.Blues(np.linspace(0.4, 0.9, len(plot_milestones)))

    bars = ax.barh(labels, means, xerr=stds,
                   color=colors, alpha=0.85, capsize=4,
                   error_kw={'linewidth': 1.5})

    for bar, mean in zip(bars, means):
        ax.text(mean + 2, bar.get_y() + bar.get_height() / 2,
                f'{mean:.0f}s', va='center', fontsize=9)

    ax.set_title('Average Cluster Startup Time per Milestone\n(from power-on)')
    ax.set_xlabel('Time from Power-On (seconds)')
    ax.invert_yaxis()

    save_fig(fig, os.path.join(graphs_dir, '05_startup_timeline.png'))

    # --- Graph 2: Total startup time per run ---
    if 'TOTAL' in milestone_data:
        fig, ax = plt.subplots(figsize=(10, 4))

        runs = list(range(1, len(milestone_data['TOTAL']) + 1))
        totals = milestone_data['TOTAL']
        mean_val = statistics.mean(totals)

        ax.bar(runs, totals, color='#2196F3', alpha=0.7)
        ax.axhline(y=mean_val, color='red', linestyle='--',
                   linewidth=2, label=f'Mean: {mean_val:.0f}s ({mean_val/60:.1f}min)')

        ax.set_title('Total Cluster Startup Time per Run')
        ax.set_xlabel('Run Number')
        ax.set_ylabel('Startup Time (seconds)')
        ax.legend()
        ax.set_xticks(runs)

        # Add secondary y-axis in minutes
        ax2 = ax.twinx()
        ax2.set_ylim(ax.get_ylim()[0] / 60, ax.get_ylim()[1] / 60)
        ax2.set_ylabel('Startup Time (minutes)')

        save_fig(fig, os.path.join(graphs_dir, '05_startup_total_per_run.png'))

    # --- Graph 3: Pod count growth during startup ---
    pod_file = os.path.join(results_dir, 'pod_count_timeseries.csv')
    if os.path.exists(pod_file):
        fig, ax = plt.subplots(figsize=(12, 4))
        df_pods = pd.read_csv(pod_file)
        df_pods['datetime'] = pd.to_datetime(df_pods['datetime'])

        ax.fill_between(df_pods['datetime'], df_pods['running_pods'],
                        alpha=0.5, color='#4CAF50', label='Running')
        ax.fill_between(df_pods['datetime'], df_pods['pending_pods'],
                        alpha=0.5, color='#FF9800', label='Pending')
        ax.plot(df_pods['datetime'], df_pods['total_pods'],
                'b-', linewidth=2, label='Total')

        ax.set_title('Pod Count Growth During Cluster Startup')
        ax.set_xlabel('Time')
        ax.set_ylabel('Number of Pods')
        ax.legend()
        plt.xticks(rotation=30)

        save_fig(fig, os.path.join(graphs_dir, '05_pod_count_growth.png'))

    print("  Scenario 5 graphs complete!")

# =============================================================================
# MAIN
# =============================================================================

def main():
    parser = argparse.ArgumentParser(
        description='Generate thesis graphs from experiment CSV results'
    )
    parser.add_argument('--results', required=True,
                        help='Path to scenario results directory')
    parser.add_argument('--scenario', required=True, type=int, choices=[1, 2, 3, 4, 5],
                        help='Scenario number (1-5)')
    args = parser.parse_args()

    results_dir = args.results
    if not os.path.exists(results_dir):
        print(f"ERROR: Results directory not found: {results_dir}")
        sys.exit(1)

    graphs_dir = os.path.join(results_dir, 'graphs')
    os.makedirs(graphs_dir, exist_ok=True)

    setup_style()

    print(f"Results directory: {results_dir}")
    print(f"Graphs will be saved to: {graphs_dir}")

    generators = {
        1: generate_ha_recovery_graphs,
        2: generate_migration_graphs,
        3: generate_resource_graphs,
        4: generate_spinup_graphs,
        5: generate_startup_graphs,
    }

    generators[args.scenario](results_dir, graphs_dir)

    print(f"\nDone! All graphs saved to: {graphs_dir}")
    print("Files generated:")
    for f in sorted(os.listdir(graphs_dir)):
        if f.endswith('.png'):
            print(f"  {f}")


if __name__ == '__main__':
    main()