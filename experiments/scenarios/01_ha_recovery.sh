#!/bin/bash
# =============================================================================
# 01_ha_recovery.sh
# Scenario 1: High Availability Recovery Testing
# =============================================================================

source "$(dirname "$0")/00_common.sh"

# =============================================================================
# CONFIGURATION
# =============================================================================

FAILURE_NODE="k3s-worker2"
FAILURE_NODE_IP="$WORKER2_IP"

TEST_VM="ubuntu-vm-1"
TEST_VM_HTTP="$VM1_HTTP"
TEST_VM_SSH_PORT="$VM1_SSH_PORT"

REPETITIONS=10
EVICTION_TIMEOUTS=(300 60 30)
STABILIZATION_WAIT=120

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

# Helper: ensure value is a clean integer or -1
sanitize_number() {
    local val="$1"
    val=$(echo "$val" | grep -oE '^[0-9]+$' | tail -1)
    [ -z "$val" ] && val="-1"
    echo "$val"
}

set_eviction_timeout() {
    local timeout_seconds=$1
    log_info "Setting eviction timeout to ${timeout_seconds}s on master..."

    # Modify systemd unit file in-place — replace existing values
    ssh -i "$SSH_KEY" "$MASTER_USER@$MASTER_IP" "sudo sed -i \
        -e 's|default-not-ready-toleration-seconds=[0-9]*|default-not-ready-toleration-seconds=${timeout_seconds}|g' \
        -e 's|default-unreachable-toleration-seconds=[0-9]*|default-unreachable-toleration-seconds=${timeout_seconds}|g' \
        /etc/systemd/system/k3s.service" >/dev/null 2>&1 || true

    # Reload systemd and restart k3s so the new args take effect
    ssh -i "$SSH_KEY" "$MASTER_USER@$MASTER_IP" \
        "sudo systemctl daemon-reload && sudo systemctl restart k3s" >/dev/null 2>&1 || true

    log_info "Waiting 30s for k3s to restart..."
    sleep 30

    wait_for_nodes_ready 120 || log_warn "Some nodes not ready after k3s restart"

    # Verify setting actually applied by reading the systemd unit file
    local applied
    applied=$(ssh -i "$SSH_KEY" "$MASTER_USER@$MASTER_IP" \
        "sudo grep -oE 'default-not-ready-toleration-seconds=[0-9]+' /etc/systemd/system/k3s.service | head -1" 2>/dev/null)
    if [[ "$applied" == *"=${timeout_seconds}"* ]]; then
        log_info "✓ Eviction timeout confirmed at ${timeout_seconds}s in systemd unit"
    else
        log_warn "⚠ Could not verify eviction timeout! Got: '$applied'"
    fi
}

ensure_vm_on_failure_node() {
    # Defensive uncordon — clear any leftover state from previous runs
    kubectl uncordon k3s-master >/dev/null 2>&1 || true
    kubectl uncordon k3s-worker1 >/dev/null 2>&1 || true
    kubectl uncordon k3s-worker2 >/dev/null 2>&1 || true

    local current_node
    current_node=$(get_vm_node "$TEST_VM")

    if [ "$current_node" == "$FAILURE_NODE" ]; then
        log_info "VM already on $FAILURE_NODE"
        return 0
    fi

    log_info "Moving VM to $FAILURE_NODE (currently on $current_node)..."

    # Cordon worker1 only — master can't run VMs anyway, no need to cordon it
    kubectl cordon k3s-worker1 >/dev/null 2>&1 || true

    virtctl migrate "$TEST_VM" >/dev/null 2>&1 || true

    # Wait for migration via temp file to avoid subshell hang
    local mig_file="/tmp/ha_migration.tmp"
    echo "-1" > "$mig_file"
    wait_for_migration "$TEST_VM" "$current_node" 300 > "$mig_file" 2>/dev/null || true
    rm -f "$mig_file"

    kubectl uncordon k3s-worker1 >/dev/null 2>&1 || true

    local new_node
    new_node=$(get_vm_node "$TEST_VM")
    if [ "$new_node" != "$FAILURE_NODE" ]; then
        log_warn "VM ended up on $new_node instead of $FAILURE_NODE"
    else
        log_info "VM is now on $FAILURE_NODE"
    fi
    sleep 10
}

power_off_node() {
    log_warn "Powering off $FAILURE_NODE ($FAILURE_NODE_IP)..."
    ssh -i "$SSH_KEY" -o ConnectTimeout=5 \
        "$MASTER_USER@$FAILURE_NODE_IP" \
        "sudo poweroff" >/dev/null 2>&1 || true
    log_info "Power off command sent to $FAILURE_NODE"
}

# Wait for node to go NotReady — echoes only seconds to stdout
wait_for_node_not_ready() {
    local timeout=120
    local start
    start=$(now)
    echo "[INFO] $(date '+%H:%M:%S') Waiting for $FAILURE_NODE to go NotReady..." >&2

    while true; do
        local status
        status=$(kubectl get node "$FAILURE_NODE" --no-headers 2>/dev/null | awk '{print $2}') || status=""
        if [[ "$status" == *"NotReady"* ]]; then
            local elapsed=$(($(now) - start))
            echo "[INFO] $(date '+%H:%M:%S') $FAILURE_NODE is NotReady after ${elapsed}s" >&2
            echo "$elapsed"
            return 0
        fi

        if [ $(($(now) - start)) -gt "$timeout" ]; then
            echo "[WARN] $(date '+%H:%M:%S') Timeout waiting for $FAILURE_NODE to go NotReady" >&2
            echo "-1"
            return 1
        fi

        sleep 2
    done
}

# Wait for VM recovery — echoes only seconds to stdout
wait_for_vm_recovery() {
    local timeout=600
    local start
    start=$(now)
    echo "[INFO] $(date '+%H:%M:%S') Waiting for $TEST_VM to recover on a healthy node..." >&2

    while true; do
        local phase
        local node
        phase=$(kubectl get vmi "$TEST_VM" -o jsonpath='{.status.phase}' 2>/dev/null) || phase=""
        node=$(get_vm_node "$TEST_VM") || node=""

        if [ "$phase" == "Running" ] && [ "$node" != "$FAILURE_NODE" ] && [ -n "$node" ]; then
            local elapsed=$(($(now) - start))
            echo "[INFO] $(date '+%H:%M:%S') VM recovered on $node after ${elapsed}s" >&2
            echo "$elapsed"
            return 0
        fi

        if [ $(($(now) - start)) -gt "$timeout" ]; then
            echo "[ERROR] $(date '+%H:%M:%S') Timeout waiting for VM recovery" >&2
            echo "-1"
            return 1
        fi

        sleep 5
    done
}

# Wait for user to power node back on
wait_for_node_recovery() {
    echo ""
    echo ""
    log_warn "============================================"
    log_warn " MANUAL ACTION REQUIRED"
    log_warn " Please power on $FAILURE_NODE NOW"
    log_warn " (Unplug and replug USB-C power cable)"
    log_warn ""
    log_warn " Press ENTER when the node is powered on"
    log_warn "============================================"
    echo ""
    read -r

    log_info "Waiting for $FAILURE_NODE to rejoin cluster..."
    local start
    start=$(now)
    local timeout=300

    while true; do
        local status
        status=$(kubectl get node "$FAILURE_NODE" --no-headers 2>/dev/null | awk '{print $2}') || status=""
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

count_http_failures() {
    local log_file=$1
    if [ -f "$log_file" ]; then
        python3 -c "
import csv
fails = 0
with open('$log_file') as f:
    for row in csv.DictReader(f):
        if row['status'] != 'OK':
            fails += 1
print(fails)
" 2>/dev/null || echo "0"
    else
        echo "0"
    fi
}

# =============================================================================
# SINGLE TEST RUN
# =============================================================================

run_single_test() {
    local run_number=$1
    local eviction_timeout=$2
    local results_dir=$3

    log_step "Run $run_number / $REPETITIONS (eviction timeout: ${eviction_timeout}s)"

    # Step 1: VM placement
    ensure_vm_on_failure_node

    # Step 2: Baseline snapshot
    take_snapshot "baseline_run${run_number}" "$results_dir" || true

    # Step 3: Start HTTP monitor — direct background spawn, not $()
    local http_log="$results_dir/http_run${run_number}.csv"
    (
        echo "timestamp,status,response_time_ms" > "$http_log"
        while true; do
            local start_ms
            start_ms=$(date +%s%3N)
            local http_code
            http_code=$(curl -s -o /dev/null -w "%{http_code}" \
                --connect-timeout 2 --max-time 3 "$TEST_VM_HTTP" 2>/dev/null) || http_code="000"
            local end_ms
            end_ms=$(date +%s%3N)
            local rt=$((end_ms - start_ms))
            if [[ "$http_code" == "200" ]]; then
                echo "$(now),OK,$rt" >> "$http_log"
            else
                echo "$(now),FAIL_${http_code},$rt" >> "$http_log"
            fi
            sleep 1
        done
    ) &
    local http_pid=$!
    log_info "HTTP monitoring started (PID: $http_pid)"

    # Step 4: Start metrics collection — direct background spawn, not $()
    local metrics_pid_file="/tmp/ha_metrics_pid_${run_number}.tmp"
    (
        while true; do
            take_snapshot "running" "$results_dir" >/dev/null 2>&1 || true
            sleep 5
        done
    ) &
    echo $! > "$metrics_pid_file"
    local metrics_pid
    metrics_pid=$(cat "$metrics_pid_file")
    log_info "Metrics collection started (PID: $metrics_pid)"

    # Step 5: Failure simulation
    log_info "Failure simulation starting at $(now_human)"
    power_off_node

    # Step 6: Wait for NotReady — capture via temp file
    local nr_file="/tmp/ha_notready_${run_number}.tmp"
    echo "-1" > "$nr_file"
    wait_for_node_not_ready > "$nr_file" || true
    local not_ready_elapsed
    not_ready_elapsed=$(sanitize_number "$(cat "$nr_file")")
    rm -f "$nr_file"
    record_timing "$results_dir" "run${run_number}_node_not_ready" "$not_ready_elapsed" || true

    # Step 7: Wait for VM recovery — capture via temp file
    local rec_file="/tmp/ha_recovery_${run_number}.tmp"
    echo "-1" > "$rec_file"
    wait_for_vm_recovery > "$rec_file" || true
    local recovery_elapsed
    recovery_elapsed=$(sanitize_number "$(cat "$rec_file")")
    rm -f "$rec_file"
    record_timing "$results_dir" "run${run_number}_vm_recovery" "$recovery_elapsed" || true

    # Step 8: Post-recovery snapshot
    take_snapshot "recovered_run${run_number}" "$results_dir" || true

    # Step 9: Stop monitoring BEFORE prompting user — so prompt is visible
    kill "$http_pid" 2>/dev/null || true
    wait "$http_pid" 2>/dev/null || true
    kill "$metrics_pid" 2>/dev/null || true
    wait "$metrics_pid" 2>/dev/null || true
    rm -f "$metrics_pid_file"

    # Step 10: HTTP downtime calculation
    local downtime_seconds
    downtime_seconds=$(count_http_failures "$http_log")
    record_timing "$results_dir" "run${run_number}_http_downtime" "$downtime_seconds" || true

    log_info "Run $run_number complete:"
    log_info "  Node went NotReady: ${not_ready_elapsed}s"
    log_info "  VM recovered: ${recovery_elapsed}s"
    log_info "  HTTP downtime: ${downtime_seconds}s"

    # Step 11: Prompt user to power node back on
    wait_for_node_recovery

    # Step 12: Stabilization wait
    log_info "Waiting ${STABILIZATION_WAIT}s for cluster to stabilize..."
    sleep "$STABILIZATION_WAIT"

    return 0
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    # Safety cleanup on exit
    trap 'pkill -f "take_snapshot" 2>/dev/null || true; \
          kubectl uncordon k3s-master 2>/dev/null || true; \
          kubectl uncordon k3s-worker1 2>/dev/null || true; \
          kubectl uncordon k3s-worker2 2>/dev/null || true; \
          rm -f /tmp/ha_*.tmp 2>/dev/null || true' EXIT

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
    log_warn "Total prompts to expect: $((REPETITIONS * ${#EVICTION_TIMEOUTS[@]}))"
    log_warn ""
    read -p "Press ENTER to start, or Ctrl+C to cancel..."

    check_prerequisites
    check_experiment_prerequisites

    local results_dir
    results_dir=$(init_results_dir "01_ha_recovery")
    log_info "Results will be saved to: $results_dir"

    cat > "$results_dir/scenario_config.txt" << EOF
Scenario: HA Recovery Testing
Date: $(now_human)
Failure node: $FAILURE_NODE
Test VM: $TEST_VM
Repetitions: $REPETITIONS
Eviction timeouts tested: ${EVICTION_TIMEOUTS[*]}s
EOF

    for timeout in "${EVICTION_TIMEOUTS[@]}"; do
        log_step "Testing with eviction timeout: ${timeout}s"

        set_eviction_timeout "$timeout"

        local timeout_dir="$results_dir/timeout_${timeout}s"
        mkdir -p "$timeout_dir"

        for i in $(seq 1 "$REPETITIONS"); do
            run_single_test "$i" "$timeout" "$timeout_dir" || true
        done

        print_timing_summary "$timeout_dir"

        log_info "Exporting detailed metrics..."
        local end_ts
        end_ts=$(now)
        local start_ts=$((end_ts - 7200))

        export_metrics_to_csv \
            "100 - (avg(rate(node_cpu_seconds_total{mode='idle'}[1m])) * 100)" \
            "$start_ts" "$end_ts" 15 \
            "$timeout_dir/cpu_timeseries.csv" "cpu_pct" || true

        export_metrics_to_csv \
            "100 * (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)" \
            "$start_ts" "$end_ts" 15 \
            "$timeout_dir/ram_timeseries.csv" "ram_pct" || true
    done

    log_step "All tests complete!"
    log_info "Results saved to: $results_dir"
    log_info ""
    log_info "Files generated:"
    ls -la "$results_dir"/*/timing_summary.csv 2>/dev/null || true
}

main "$@"
