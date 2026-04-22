#!/bin/bash
# =============================================================================
# 05_cluster_startup.sh
# Scenario 5: Cluster Startup Time Measurement
#
# WHAT THIS TESTS:
#   How long does it take for the entire cluster to become fully operational
#   after a cold power-on, broken down into stages:
#     - Node OS boot and network ready
#     - k3s master ready (API server up)
#     - Worker nodes joined (all nodes Ready)
#     - Longhorn storage healthy
#     - Monitoring stack ready (Prometheus + Grafana)
#     - VMs running and HTTP accessible
#
# HOW IT WORKS:
#   This script cannot automate the power-on (physical action required).
#   Instead it:
#     1. Records the moment the user powers on the cluster
#     2. Polls each milestone and records exact timestamp when reached
#     3. Calculates elapsed time for each stage
#     4. Repeats 10 times
#
# REQUIREMENTS:
#   - Cluster is powered OFF before starting
#   - User can physically power on the Pi nodes
#   - Script runs from jumphost (which stays on)
#
# USAGE:
#   bash 05_cluster_startup.sh
#
# RESULTS:
#   Saved to experiments/results/05_cluster_startup_<timestamp>/
#   - timing_summary.csv — milestone times per run
#   - pod_count_timeseries.csv — pod count growth during startup
# =============================================================================

set -e
source "$(dirname "$0")/00_common.sh"

# =============================================================================
# CONFIGURATION
# =============================================================================

REPETITIONS=10

# How long to wait after cluster is fully up before shutting down again
BETWEEN_RUNS_WAIT=60

# =============================================================================
# MILESTONE DETECTION FUNCTIONS
# =============================================================================

# Wait for master node API to respond
wait_for_api_server() {
    local timeout=300
    local start=$(now)
    log_info "Waiting for k3s API server..."

    while true; do
        if kubectl get nodes &>/dev/null 2>&1; then
            local elapsed=$(($(now) - start))
            log_info "API server ready after ${elapsed}s"
            echo "$elapsed"
            return 0
        fi

        if [ $(($(now) - start)) -gt "$timeout" ]; then
            log_error "Timeout waiting for API server"
            echo "timeout"
            return 1
        fi

        sleep 2
    done
}

# Wait for all 3 nodes to be Ready
wait_for_all_nodes() {
    local timeout=300
    local start=$(now)
    log_info "Waiting for all 3 nodes to be Ready..."

    while true; do
        local ready_count
        ready_count=$(kubectl get nodes --no-headers 2>/dev/null | grep " Ready" | wc -l)

        if [ "$ready_count" -ge 3 ]; then
            local elapsed=$(($(now) - start))
            log_info "All 3 nodes Ready after ${elapsed}s"
            echo "$elapsed"
            return 0
        fi

        if [ $(($(now) - start)) -gt "$timeout" ]; then
            log_error "Timeout waiting for all nodes"
            echo "timeout"
            return 1
        fi

        sleep 5
    done
}

# Wait for Longhorn to be healthy
wait_for_longhorn() {
    local timeout=300
    local start=$(now)
    log_info "Waiting for Longhorn storage to be healthy..."

    while true; do
        local healthy_nodes
        healthy_nodes=$(kubectl get nodes.longhorn.io -n longhorn-system \
            --no-headers 2>/dev/null | grep "True" | wc -l)

        if [ "$healthy_nodes" -ge 3 ]; then
            local elapsed=$(($(now) - start))
            log_info "Longhorn healthy after ${elapsed}s"
            echo "$elapsed"
            return 0
        fi

        if [ $(($(now) - start)) -gt "$timeout" ]; then
            log_warn "Timeout waiting for Longhorn"
            echo "timeout"
            return 1
        fi

        sleep 5
    done
}

# Wait for Prometheus to respond
wait_for_prometheus() {
    local timeout=300
    local start=$(now)
    log_info "Waiting for Prometheus..."

    while true; do
        if curl -sf "${PROMETHEUS_URL}/-/healthy" &>/dev/null; then
            local elapsed=$(($(now) - start))
            log_info "Prometheus ready after ${elapsed}s"
            echo "$elapsed"
            return 0
        fi

        if [ $(($(now) - start)) -gt "$timeout" ]; then
            log_warn "Timeout waiting for Prometheus"
            echo "timeout"
            return 1
        fi

        sleep 5
    done
}

# Wait for Grafana to respond
wait_for_grafana() {
    local timeout=300
    local start=$(now)
    log_info "Waiting for Grafana..."

    while true; do
        local http_code
        http_code=$(curl -s -o /dev/null -w "%{http_code}" \
            --connect-timeout 2 "http://${MASTER_IP}:32000" 2>/dev/null)

        if [ "$http_code" == "200" ] || [ "$http_code" == "302" ]; then
            local elapsed=$(($(now) - start))
            log_info "Grafana ready after ${elapsed}s"
            echo "$elapsed"
            return 0
        fi

        if [ $(($(now) - start)) -gt "$timeout" ]; then
            log_warn "Timeout waiting for Grafana"
            echo "timeout"
            return 1
        fi

        sleep 5
    done
}

# Wait for both VMs to be running
wait_for_vms() {
    local timeout=600
    local start=$(now)
    log_info "Waiting for both VMs to be Running..."

    while true; do
        local running_count
        running_count=$(kubectl get vmi --no-headers 2>/dev/null | grep "Running" | wc -l)

        if [ "$running_count" -ge 2 ]; then
            local elapsed=$(($(now) - start))
            log_info "Both VMs Running after ${elapsed}s"
            echo "$elapsed"
            return 0
        fi

        if [ $(($(now) - start)) -gt "$timeout" ]; then
            log_warn "Timeout waiting for VMs"
            echo "timeout"
            return 1
        fi

        sleep 10
    done
}

# Wait for VM HTTP endpoints to respond
wait_for_vm_http() {
    local timeout=180
    local start=$(now)
    log_info "Waiting for VM HTTP endpoints..."

    while true; do
        local vm1_ok=false
        local vm2_ok=false

        local code1
        code1=$(curl -s -o /dev/null -w "%{http_code}" \
            --connect-timeout 2 "$VM1_HTTP" 2>/dev/null)
        [ "$code1" == "200" ] && vm1_ok=true

        local code2
        code2=$(curl -s -o /dev/null -w "%{http_code}" \
            --connect-timeout 2 "$VM2_HTTP" 2>/dev/null)
        [ "$code2" == "200" ] && vm2_ok=true

        if $vm1_ok && $vm2_ok; then
            local elapsed=$(($(now) - start))
            log_info "Both VM HTTP endpoints ready after ${elapsed}s"
            echo "$elapsed"
            return 0
        fi

        if [ $(($(now) - start)) -gt "$timeout" ]; then
            log_warn "Timeout waiting for VM HTTP"
            echo "timeout"
            return 1
        fi

        sleep 5
    done
}

# Track pod count in background during startup
track_pod_count() {
    local results_dir=$1
    local duration=$2
    local csv_file="$results_dir/pod_count_timeseries.csv"

    echo "timestamp,datetime,total_pods,running_pods,pending_pods" > "$csv_file"

    (
        local start=$(now)
        while [ $(($(now) - start)) -lt "$duration" ]; do
            local ts=$(now)
            local dt=$(now_human)
            local total running pending
            total=$(kubectl get pods -A --no-headers 2>/dev/null | wc -l)
            running=$(kubectl get pods -A --no-headers 2>/dev/null | grep "Running" | wc -l)
            pending=$(kubectl get pods -A --no-headers 2>/dev/null | grep "Pending" | wc -l)
            echo "$ts,$dt,$total,$running,$pending" >> "$csv_file"
            sleep 10
        done
    ) &
    echo $!
}

# =============================================================================
# SINGLE STARTUP RUN
# =============================================================================

run_startup() {
    local run_number=$1
    local results_dir=$2

    log_step "Run $run_number / $REPETITIONS"

    # Prompt user to power off cluster
    log_warn "============================================"
    log_warn " Please run the shutdown script now:"
    log_warn " bash shutdown-cluster.sh"
    log_warn " Wait for it to complete, then power OFF"
    log_warn " Press ENTER when all nodes are powered off."
    log_warn "============================================"
    read -r

    log_info "Waiting 10s before starting timer..."
    sleep 10

# Prompt user to power on in correct sequence
    log_warn "============================================"
    log_warn " Power on nodes in this EXACT order:"
    log_warn ""
    log_warn " 1. Power on k3s-master FIRST"
    log_warn " 2. Press ENTER immediately (timer starts now)"
    log_warn " 3. Wait 20-30 seconds"
    log_warn " 4. Power on k3s-worker1 AND k3s-worker2"
    log_warn ""
    log_warn " Press ENTER right after powering on master."
    log_warn "============================================"
    read -r

    # Record power-on time
    local t_power_on=$(now)
    log_info "Timer started at $(now_human)"

    # Start pod count tracking (for 20 minutes)
    local pod_tracker_pid
    pod_tracker_pid=$(track_pod_count "$results_dir" 1200)

    # Milestone 1: API server
    local api_elapsed
    api_elapsed=$(wait_for_api_server)
    local t_api=$(now)
    record_timing "$results_dir" "run${run_number}_api_server_ready" \
        $((t_api - t_power_on))

    # Milestone 2: All nodes Ready
    local nodes_elapsed
    nodes_elapsed=$(wait_for_all_nodes)
    local t_nodes=$(now)
    record_timing "$results_dir" "run${run_number}_all_nodes_ready" \
        $((t_nodes - t_power_on))

    # Milestone 3: Longhorn
    local longhorn_elapsed
    longhorn_elapsed=$(wait_for_longhorn)
    local t_longhorn=$(now)
    record_timing "$results_dir" "run${run_number}_longhorn_healthy" \
        $((t_longhorn - t_power_on))

    # Milestone 4: Prometheus
    local prom_elapsed
    prom_elapsed=$(wait_for_prometheus)
    local t_prom=$(now)
    record_timing "$results_dir" "run${run_number}_prometheus_ready" \
        $((t_prom - t_power_on))

    # Milestone 5: Grafana
    local grafana_elapsed
    grafana_elapsed=$(wait_for_grafana)
    local t_grafana=$(now)
    record_timing "$results_dir" "run${run_number}_grafana_ready" \
        $((t_grafana - t_power_on))

    # Milestone 6: VMs Running
    local vms_elapsed
    vms_elapsed=$(wait_for_vms)
    local t_vms=$(now)
    record_timing "$results_dir" "run${run_number}_vms_running" \
        $((t_vms - t_power_on))

    # Milestone 7: VM HTTP ready
    local http_elapsed
    http_elapsed=$(wait_for_vm_http)
    local t_http=$(now)
    record_timing "$results_dir" "run${run_number}_vm_http_ready" \
        $((t_http - t_power_on))

    # Verify correct placement before recording results
    check_experiment_prerequisites

    # Total time
    local total=$((t_http - t_power_on))
    record_timing "$results_dir" "run${run_number}_TOTAL" "$total"

    # Stop pod tracker
    kill "$pod_tracker_pid" 2>/dev/null; wait "$pod_tracker_pid" 2>/dev/null || true

    log_info "Run $run_number complete! Total startup time: ${total}s ($((total/60))m $((total%60))s)"

    log_info "Waiting ${BETWEEN_RUNS_WAIT}s before next run..."
    sleep "$BETWEEN_RUNS_WAIT"
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    log_step "Scenario 5: Cluster Startup Time Measurement"
    log_info "This scenario measures how long the cluster takes to become"
    log_info "fully operational after a cold power-on."
    log_info ""
    log_info "Milestones measured (from power-on):"
    log_info "  1. k3s API server ready"
    log_info "  2. All 3 nodes Ready"
    log_info "  3. Longhorn storage healthy"
    log_info "  4. Prometheus ready"
    log_info "  5. Grafana ready"
    log_info "  6. Both VMs Running"
    log_info "  7. VM HTTP endpoints responding"
    log_info ""
    log_info "Repetitions: $REPETITIONS"
    log_warn ""
    log_warn "IMPORTANT: You will need to physically power the cluster"
    log_warn "on and off $REPETITIONS times during this test."
    log_warn ""
    read -p "Press ENTER to start, or Ctrl+C to cancel..."

    # Note: we don't check prerequisites here because cluster starts off
    mkdir -p "$RESULTS_DIR"

    local results_dir
    results_dir=$(init_results_dir "05_cluster_startup")
    log_info "Results will be saved to: $results_dir"

    # Write config
    cat > "$results_dir/scenario_config.txt" << EOF
Scenario: Cluster Startup Time
Date: $(now_human)
Repetitions: $REPETITIONS
Milestones: api_server, all_nodes, longhorn, prometheus, grafana, vms_running, vm_http
EOF

    # Run tests
    for i in $(seq 1 "$REPETITIONS"); do
        run_startup "$i" "$results_dir"
    done

    # Print summary
    print_timing_summary "$results_dir"

    # Compute averages per milestone
    log_step "Average startup times across $REPETITIONS runs:"
    python3 -c "
import csv
from collections import defaultdict

timings = defaultdict(list)
with open('$results_dir/timing_summary.csv') as f:
    for row in csv.DictReader(f):
        val = row['seconds']
        if val != 'timeout':
            # Extract milestone (remove run number)
            parts = row['label'].split('_')
            milestone = '_'.join(parts[2:])
            timings[milestone].append(float(val))

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

print(f'{'Milestone':<30} {'Avg':>8} {'Min':>8} {'Max':>8} {'StdDev':>8}')
print('-' * 70)
import statistics
for m in milestones:
    if m in timings and timings[m]:
        vals = timings[m]
        avg = statistics.mean(vals)
        mn = min(vals)
        mx = max(vals)
        std = statistics.stdev(vals) if len(vals) > 1 else 0
        print(f'{m:<30} {avg:>7.1f}s {mn:>7.1f}s {mx:>7.1f}s {std:>7.1f}s')
" 2>/dev/null || true

    log_step "Cluster startup tests complete!"
    log_info "Results saved to: $results_dir"
}

main "$@"