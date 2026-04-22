#!/bin/bash
# =============================================================================
# 03_resource_comparison.sh
# Scenario 3: Resource Comparison — Pi Nodes vs VMs
#
# WHAT THIS TESTS:
#   Compares CPU, RAM, network and disk I/O utilization between:
#   - Physical Pi nodes (bare metal)
#   - Ubuntu VMs running inside the cluster
#   Both at idle and under controlled load.
#
# HOW IT WORKS:
#   Phase 1 — Idle baseline (5 minutes)
#     Records metrics from all Pi nodes and both VMs at rest.
#
#   Phase 2 — VM load only (5 minutes)
#     Applies CPU+memory stress inside both VMs.
#     Records Pi node overhead from hosting the VMs under load.
#
#   Phase 3 — Recovery (2 minutes)
#     Stops load, records return to baseline.
#
# REQUIREMENTS:
#   - All 3 Pi nodes running
#   - Both VMs running
#   - stress-ng installed inside VMs
#
# USAGE:
#   bash 03_resource_comparison.sh
#
# RESULTS:
#   Saved to experiments/results/03_resource_comparison_<timestamp>/
#   - metrics_snapshots.csv — all metrics across all phases
#   - *_timeseries.csv      — time series data for graphing
# =============================================================================

set -e
source "$(dirname "$0")/00_common.sh"

# =============================================================================
# CONFIGURATION
# =============================================================================

# Duration of each measurement phase in seconds
IDLE_DURATION=300       # 5 minutes idle baseline
LOAD_DURATION=300       # 5 minutes under load
RECOVERY_DURATION=120   # 2 minutes recovery

# Metrics collection interval in seconds
COLLECTION_INTERVAL=5

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

ensure_stress_ng_on_vms() {
    log_info "Checking stress-ng on VMs..."
    for port in "$VM1_SSH_PORT" "$VM2_SSH_PORT"; do
        local result
        result=$(ssh -i "$SSH_KEY" -p "$port" \
            -o StrictHostKeyChecking=no \
            ubuntu@"$MASTER_IP" \
            "which stress-ng 2>/dev/null || echo 'not_found'")
        if [ "$result" == "not_found" ]; then
            install_stress_ng "$port"
        fi
    done
    log_info "stress-ng ready on both VMs ✓"
}

# Collect metrics from Pi nodes AND VMs
take_full_snapshot() {
    local label=$1
    local results_dir=$2
    local timestamp=$(now)
    local csv_file="$results_dir/metrics_snapshots.csv"

    if [ ! -f "$csv_file" ]; then
        echo "timestamp,label,source_type,source_name,cpu_pct,ram_pct,net_rx_kbs,net_tx_kbs,disk_read_kbs,disk_write_kbs" > "$csv_file"
    fi

    # Pi node metrics
    for node_info in "k3s-master:${MASTER_INSTANCE}" "k3s-worker1:${WORKER1_INSTANCE}" "k3s-worker2:${WORKER2_INSTANCE}"; do
        local node_name="${node_info%%:*}"
        local instance="${node_info#*:}"

        local cpu=$(get_cpu_usage "$instance")
        local ram=$(get_ram_usage "$instance")
        local net_rx=$(get_net_rx "$instance")
        local net_tx=$(get_net_tx "$instance")
        local disk_r=$(get_disk_read "$instance")
        local disk_w=$(get_disk_write "$instance")

        echo "$timestamp,$label,pi_node,$node_name,$cpu,$ram,$net_rx,$net_tx,$disk_r,$disk_w" >> "$csv_file"
    done

    # VM metrics (via their node_exporter instances)
    local vm1_ip
    local vm2_ip
    vm1_ip=$(kubectl get vmi ubuntu-vm-1 -o jsonpath='{.status.interfaces[0].ipAddress}' 2>/dev/null || echo "")
    vm2_ip=$(kubectl get vmi ubuntu-vm-2 -o jsonpath='{.status.interfaces[0].ipAddress}' 2>/dev/null || echo "")

    # VM metrics come through the ubuntu-vm-*-metrics services
    for vm_info in "ubuntu-vm-1:ubuntu-vm-1-metrics" "ubuntu-vm-2:ubuntu-vm-2-metrics"; do
        local vm_name="${vm_info%%:*}"
        local svc_name="${vm_info#*:}"

        # Get pod IP from service endpoint
        local pod_ip
        pod_ip=$(kubectl get endpoints "$svc_name" -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null || echo "")

        if [ -n "$pod_ip" ]; then
            local vm_instance="${pod_ip}:9100"
            local cpu=$(get_cpu_usage "$vm_instance")
            local ram=$(get_ram_usage "$vm_instance")
            local net_rx=$(get_net_rx "$vm_instance")
            local net_tx=$(get_net_tx "$vm_instance")
            local disk_r=$(get_disk_read "$vm_instance")
            local disk_w=$(get_disk_write "$vm_instance")

            echo "$timestamp,$label,vm,$vm_name,$cpu,$ram,$net_rx,$net_tx,$disk_r,$disk_w" >> "$csv_file"
        else
            echo "$timestamp,$label,vm,$vm_name,N/A,N/A,N/A,N/A,N/A,N/A" >> "$csv_file"
        fi
    done

    log_info "Full snapshot taken: $label"
}

# Collect metrics continuously
collect_phase_metrics() {
    local label=$1
    local duration=$2
    local results_dir=$3
    local interval=$4

    log_info "Collecting metrics for ${duration}s (phase: $label)..."
    local start=$(now)
    local count=0

    while [ $(($(now) - start)) -lt "$duration" ]; do
        take_full_snapshot "${label}_sample${count}" "$results_dir"
        count=$((count + 1))
        sleep "$interval"
    done

    log_info "Phase $label complete — $count samples collected"
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    log_step "Scenario 3: Resource Comparison — Pi Nodes vs VMs"
    log_info "This scenario compares resource utilization between physical"
    log_info "Pi nodes and VMs running inside the cluster."
    log_info ""
    log_info "Phases:"
    log_info "  Phase 1: Idle baseline (${IDLE_DURATION}s)"
    log_info "  Phase 2: VM load (${LOAD_DURATION}s)"
    log_info "  Phase 3: Recovery (${RECOVERY_DURATION}s)"
    log_info "  Total duration: ~$((IDLE_DURATION + LOAD_DURATION + RECOVERY_DURATION))s (~$((( IDLE_DURATION + LOAD_DURATION + RECOVERY_DURATION) / 60)) minutes)"
    log_info ""
    read -p "Press ENTER to start, or Ctrl+C to cancel..."

    check_prerequisites
    check_experiment_prerequisites
    ensure_stress_ng_on_vms

    local results_dir
    results_dir=$(init_results_dir "03_resource_comparison")
    log_info "Results will be saved to: $results_dir"

    # Write config
    cat > "$results_dir/scenario_config.txt" << EOF
Scenario: Resource Comparison
Date: $(now_human)
Idle duration: ${IDLE_DURATION}s
Load duration: ${LOAD_DURATION}s
Recovery duration: ${RECOVERY_DURATION}s
Collection interval: ${COLLECTION_INTERVAL}s
EOF

    # -------------------------
    # Phase 1: Idle baseline
    # -------------------------
    log_step "Phase 1: Idle Baseline"
    log_info "Collecting baseline metrics with no load..."
    local phase1_dir="$results_dir/phase1_idle"
    mkdir -p "$phase1_dir"
    collect_phase_metrics "idle" "$IDLE_DURATION" "$phase1_dir" "$COLLECTION_INTERVAL"

    # -------------------------
    # Phase 2: VM load
    # -------------------------
    log_step "Phase 2: VM Load"
    log_info "Starting stress load on both VMs..."
    start_vm_load "ubuntu-vm-1" "$VM1_SSH_PORT"
    start_vm_load "ubuntu-vm-2" "$VM2_SSH_PORT"

    log_info "Waiting 15s for load to stabilize..."
    sleep 15

    local phase2_dir="$results_dir/phase2_loaded"
    mkdir -p "$phase2_dir"
    collect_phase_metrics "loaded" "$LOAD_DURATION" "$phase2_dir" "$COLLECTION_INTERVAL"

    # Stop load
    log_info "Stopping stress load..."
    stop_vm_load "ubuntu-vm-1" "$VM1_SSH_PORT"
    stop_vm_load "ubuntu-vm-2" "$VM2_SSH_PORT"

    # -------------------------
    # Phase 3: Recovery
    # -------------------------
    log_step "Phase 3: Recovery"
    local phase3_dir="$results_dir/phase3_recovery"
    mkdir -p "$phase3_dir"
    collect_phase_metrics "recovery" "$RECOVERY_DURATION" "$phase3_dir" "$COLLECTION_INTERVAL"

    # -------------------------
    # Export time series
    # -------------------------
    log_step "Exporting time series data..."
    local end_ts=$(now)
    local start_ts=$((end_ts - IDLE_DURATION - LOAD_DURATION - RECOVERY_DURATION - 60))

    # CPU per node
    for instance in "$MASTER_INSTANCE" "$WORKER1_INSTANCE" "$WORKER2_INSTANCE"; do
        local node_name
        node_name=$(echo "$instance" | cut -d: -f1 | tr '.' '_')
        export_metrics_to_csv \
            "100 - (avg(rate(node_cpu_seconds_total{mode='idle',instance='${instance}'}[1m])) * 100)" \
            "$start_ts" "$end_ts" 15 \
            "$results_dir/cpu_${node_name}.csv" "cpu_pct"
    done

    # RAM per node
    for instance in "$MASTER_INSTANCE" "$WORKER1_INSTANCE" "$WORKER2_INSTANCE"; do
        local node_name
        node_name=$(echo "$instance" | cut -d: -f1 | tr '.' '_')
        export_metrics_to_csv \
            "100 * (1 - node_memory_MemAvailable_bytes{instance='${instance}'} / node_memory_MemTotal_bytes{instance='${instance}'})" \
            "$start_ts" "$end_ts" 15 \
            "$results_dir/ram_${node_name}.csv" "ram_pct"
    done

    # Network across all nodes
    export_metrics_to_csv \
        "rate(node_network_receive_bytes_total{device='eth0'}[1m])" \
        "$start_ts" "$end_ts" 15 \
        "$results_dir/network_rx_all.csv" "rx_bytes_per_sec"

    # Disk I/O across all nodes
    export_metrics_to_csv \
        "rate(node_disk_written_bytes_total[1m])" \
        "$start_ts" "$end_ts" 15 \
        "$results_dir/disk_write_all.csv" "write_bytes_per_sec"

    log_step "Resource comparison complete!"
    log_info "Results saved to: $results_dir"
    log_info ""
    log_info "Key files:"
    log_info "  phase1_idle/metrics_snapshots.csv    — idle baseline"
    log_info "  phase2_loaded/metrics_snapshots.csv  — under VM load"
    log_info "  phase3_recovery/metrics_snapshots.csv — recovery"
    log_info "  cpu_*.csv, ram_*.csv                 — time series for graphs"
}

main "$@"