#!/bin/bash
# =============================================================================
# 01_ha_recovery.sh
# Scenario 1: High Availability Recovery Testing
#
# WHAT THIS TESTS:
#   How long does the cluster take to recover VM workloads after a node failure,
#   using different pod eviction timeout settings.
#
# HOW IT WORKS:
#   1. Records baseline metrics (CPU, RAM, network, disk I/O)
#   2. Powers off a worker Pi node (simulates hardware failure)
#   3. Measures time until VM is rescheduled and running on a healthy node
#   4. Records recovery metrics
#   5. Powers the node back on and waits for cluster to stabilize
#   6. Repeats for different eviction timeout values
#
# REQUIREMENTS:
#   - All 3 Pi nodes running
#   - Both VMs running
#   - Pi nodes must have SSH access from jumphost
#   - User must have sudo on Pi nodes (passwordless sudo configured by bootstrap)
#
# USAGE:
#   bash 01_ha_recovery.sh
#
# RESULTS:
#   Saved to experiments/results/01_ha_recovery_<timestamp>/
#   - timing_summary.csv    — recovery times per run
#   - metrics_snapshots.csv — CPU/RAM/network/disk before and after
#   - http_monitor_*.csv    — HTTP availability during failure
# =============================================================================

set -e
source "$(dirname "$0")/00_common.sh"

# =============================================================================
# CONFIGURATION
# =============================================================================

# Node to simulate failure on — we use worker2 so worker1 can receive the VM
FAILURE_NODE="k3s-worker2"
FAILURE_NODE_IP="$WORKER2_IP"

# VM that will be affected by the failure
# We will place it on worker2 before each test run
TEST_VM="ubuntu-vm-1"
TEST_VM_HTTP="$VM1_HTTP"
TEST_VM_SSH_PORT="$VM1_SSH_PORT"

# Number of times to repeat each eviction timeout test
REPETITIONS=10

# Eviction timeout values to test (in seconds)
# Default Kubernetes value is 300s (5 minutes)
EVICTION_TIMEOUTS=(300 60 30)

# How long to wait after node recovers before next test (seconds)
STABILIZATION_WAIT=120

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

# Set k3s node eviction timeout
# This modifies the k3s server config and restarts k3s
set_eviction_timeout() {
    local timeout_seconds=$1
    log_info "Setting eviction timeout to ${timeout_seconds}s on master..."

    ssh -i "$SSH_KEY" "$MASTER_USER@$MASTER_IP" \
        "sudo sed -i '/node-status-update-frequency/d' /etc/rancher/k3s/config.yaml; \
         sudo sed -i '/default-not-ready-toleration-seconds/d' /etc/rancher/k3s/config.yaml; \
         echo 'kube-apiserver-arg:' | sudo tee -a /etc/rancher/k3s/config.yaml; \
         echo '  - default-not-ready-toleration-seconds=${timeout_seconds}' | sudo tee -a /etc/rancher/k3s/config.yaml; \
         echo '  - default-unreachable-toleration-seconds=${timeout_seconds}' | sudo tee -a /etc/rancher/k3s/config.yaml; \
         sudo systemctl restart k3s"

    log_info "Waiting 30s for k3s to restart..."
    sleep 30

    # Wait for all nodes to be Ready again
    wait_for_nodes_ready 120
}

# Migrate VM to the failure node so we can test recovery from it
ensure_vm_on_failure_node() {
    local current_node
    current_node=$(get_vm_node "$TEST_VM")

    if [ "$current_node" == "$FAILURE_NODE" ]; then
        log_info "VM already on $FAILURE_NODE"
        return 0
    fi

    log_info "Moving VM to $FAILURE_NODE (currently on $current_node)..."

    # Cordon all nodes except failure node
    kubectl cordon k3s-master 2>/dev/null || true
    kubectl cordon k3s-worker1 2>/dev/null || true

    # Migrate VM
    virtctl migrate "$TEST_VM"
    wait_for_migration "$TEST_VM" "$current_node" 300

    # Uncordon
    kubectl uncordon k3s-master 2>/dev/null || true
    kubectl uncordon k3s-worker1 2>/dev/null || true

    log_info "VM is now on $FAILURE_NODE"
    sleep 10
}

# Power off the failure node
power_off_node() {
    log_warn "Powering off $FAILURE_NODE ($FAILURE_NODE_IP)..."
    ssh -i "$SSH_KEY" "$MASTER_USER@$FAILURE_NODE_IP" \
        "sudo poweroff" 2>/dev/null || true
    log_info "Power off command sent to $FAILURE_NODE"
}

# Wait for the failure node to go NotReady
wait_for_node_not_ready() {
    local timeout=120
    local start=$(now)
    log_info "Waiting for $FAILURE_NODE to go NotReady..."

    while true; do
        local status
        status=$(kubectl get node "$FAILURE_NODE" --no-headers 2>/dev/null | awk '{print $2}')
        if [[ "$status" == *"NotReady"* ]]; then
            local elapsed=$(($(now) - start))
            log_info "$FAILURE_NODE is NotReady after ${elapsed}s"
            echo "$elapsed"
            return 0
        fi

        if [ $(($(now) - start)) -gt "$timeout" ]; then
            log_warn "Timeout waiting for $FAILURE_NODE to go NotReady"
            echo "timeout"
            return 1
        fi

        sleep 2
    done
}

# Wait for VM to be rescheduled on a healthy node
wait_for_vm_recovery() {
    local timeout=600
    local start=$(now)
    log_info "Waiting for $TEST_VM to recover on a healthy node..."

    while true; do
        local phase
        local node
        phase=$(kubectl get vmi "$TEST_VM" -o jsonpath='{.status.phase}' 2>/dev/null)
        node=$(get_vm_node "$TEST_VM")

        if [ "$phase" == "Running" ] && [ "$node" != "$FAILURE_NODE" ] && [ -n "$node" ]; then
            local elapsed=$(($(now) - start))
            log_info "VM recovered on $node after ${elapsed}s"
            echo "$elapsed"
            return 0
        fi

        if [ $(($(now) - start)) -gt "$timeout" ]; then
            log_error "Timeout waiting for VM recovery"
            echo "timeout"
            return 1
        fi

        sleep 5
    done
}

# Power on the failure node (manual step — user must do this)
wait_for_node_recovery() {
    log_warn "============================================"
    log_warn " MANUAL ACTION REQUIRED"
    log_warn " Please power on $FAILURE_NODE now"
    log_warn " Press ENTER when the node is powered on"
    log_warn "============================================"
    read -r

    log_info "Waiting for $FAILURE_NODE to rejoin cluster..."
    local start=$(now)
    local timeout=300

    while true; do
        local status
        status=$(kubectl get node "$FAILURE_NODE" --no-headers 2>/dev/null | awk '{print $2}')
        if [ "$status" == "Ready" ]; then
            local elapsed=$(($(now) - start))
            log_info "$FAILURE_NODE is Ready again after ${elapsed}s"
            return 0
        fi

        if [ $(($(now) - start)) -gt "$timeout" ]; then
            log_error "Timeout waiting for $FAILURE_NODE to recover"
            return 1
        fi

        sleep 5
    done
}

# =============================================================================
# SINGLE TEST RUN
# =============================================================================

run_single_test() {
    local run_number=$1
    local eviction_timeout=$2
    local results_dir=$3

    log_step "Run $run_number / $REPETITIONS (eviction timeout: ${eviction_timeout}s)"

    # Step 1: Make sure VM is on the failure node
    ensure_vm_on_failure_node

    # Step 2: Take baseline snapshot
    take_snapshot "baseline_run${run_number}" "$results_dir"

    # Step 3: Start HTTP monitoring
    local http_pid
    http_pid=$(start_http_monitor "$TEST_VM_HTTP" "$results_dir")
    log_info "HTTP monitoring started (PID: $http_pid)"

    # Step 4: Start continuous metrics collection
    local metrics_pid
    metrics_pid=$(start_metrics_collection "$results_dir" 5)
    log_info "Metrics collection started (PID: $metrics_pid)"

    # Step 5: Record failure start time
    local failure_start=$(now)
    log_info "Failure simulation starting at $(now_human)"

    # Step 6: Power off the node
    power_off_node

    # Step 7: Record when node goes NotReady
    local not_ready_elapsed
    not_ready_elapsed=$(wait_for_node_not_ready)
    local not_ready_time=$(now)
    record_timing "$results_dir" "run${run_number}_node_not_ready" "$not_ready_elapsed"

    # Step 8: Wait for VM recovery
    local recovery_elapsed
    recovery_elapsed=$(wait_for_vm_recovery)
    local recovery_time=$(now)
    record_timing "$results_dir" "run${run_number}_vm_recovery" "$recovery_elapsed"

    # Step 9: Take post-recovery snapshot
    take_snapshot "recovered_run${run_number}" "$results_dir"

    # Step 10: Stop monitoring
    stop_http_monitor "$http_pid"
    stop_metrics_collection "$metrics_pid"

    # Step 11: Calculate total downtime from HTTP monitor log
    local http_log="$results_dir/http_monitor_$(echo $TEST_VM_HTTP | sed 's/[^0-9]/_/g').csv"
    local downtime_seconds=0
    if [ -f "$http_log" ]; then
        downtime_seconds=$(python3 -c "
import csv
fails = 0
with open('$http_log') as f:
    for row in csv.DictReader(f):
        if row['status'] != 'OK':
            fails += 1
print(fails)
" 2>/dev/null || echo "0")
    fi
    record_timing "$results_dir" "run${run_number}_http_downtime" "$downtime_seconds"

    log_info "Run $run_number complete:"
    log_info "  Node went NotReady: ${not_ready_elapsed}s"
    log_info "  VM recovered: ${recovery_elapsed}s"
    log_info "  HTTP downtime: ${downtime_seconds}s"

    # Step 12: Restore node
    wait_for_node_recovery

    # Step 13: Wait for cluster to stabilize
    log_info "Waiting ${STABILIZATION_WAIT}s for cluster to stabilize..."
    sleep "$STABILIZATION_WAIT"
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    log_step "Scenario 1: HA Recovery Testing"
    log_info "This scenario tests how long the cluster takes to recover"
    log_info "VM workloads after a node failure, with different eviction timeouts."
    log_info ""
    log_info "Configuration:"
    log_info "  Failure node: $FAILURE_NODE"
    log_info "  Test VM: $TEST_VM"
    log_info "  Repetitions per timeout: $REPETITIONS"
    log_info "  Eviction timeouts: ${EVICTION_TIMEOUTS[*]}s"
    log_info ""
    log_warn "IMPORTANT: This test will power off $FAILURE_NODE ($FAILURE_NODE_IP)"
    log_warn "You will be prompted to power it back on after each run."
    log_warn ""
    read -p "Press ENTER to start, or Ctrl+C to cancel..."

    # Check prerequisites
    check_prerequisites
    check_experiment_prerequisites

    # Create results directory
    local results_dir
    results_dir=$(init_results_dir "01_ha_recovery")
    log_info "Results will be saved to: $results_dir"

    # Write scenario config to results
    cat > "$results_dir/scenario_config.txt" << EOF
Scenario: HA Recovery Testing
Date: $(now_human)
Failure node: $FAILURE_NODE
Test VM: $TEST_VM
Repetitions: $REPETITIONS
Eviction timeouts tested: ${EVICTION_TIMEOUTS[*]}s
EOF

    # Run tests for each eviction timeout
    for timeout in "${EVICTION_TIMEOUTS[@]}"; do
        log_step "Testing with eviction timeout: ${timeout}s"

        # Set eviction timeout
        set_eviction_timeout "$timeout"

        # Create sub-directory for this timeout
        local timeout_dir="$results_dir/timeout_${timeout}s"
        mkdir -p "$timeout_dir"

        # Run repetitions
        for i in $(seq 1 "$REPETITIONS"); do
            run_single_test "$i" "$timeout" "$timeout_dir"
        done

        # Print summary for this timeout
        print_timing_summary "$timeout_dir"

        # Export full metric time series to CSV
        log_info "Exporting detailed metrics..."
        local end_ts=$(now)
        local start_ts=$((end_ts - 7200)) # Last 2 hours

        export_metrics_to_csv \
            "100 - (avg(rate(node_cpu_seconds_total{mode='idle'}[1m])) * 100)" \
            "$start_ts" "$end_ts" 15 \
            "$timeout_dir/cpu_timeseries.csv" "cpu_pct"

        export_metrics_to_csv \
            "100 * (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)" \
            "$start_ts" "$end_ts" 15 \
            "$timeout_dir/ram_timeseries.csv" "ram_pct"
    done

    # Final summary
    log_step "All tests complete!"
    log_info "Results saved to: $results_dir"
    log_info ""
    log_info "Files generated:"
    ls -la "$results_dir"/*/timing_summary.csv 2>/dev/null
}

main "$@"