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
#   1. Records baseline metrics
#   2. Powers off a worker Pi node (simulates hardware failure)
#   3. Measures time until VM is rescheduled on a healthy node
#   4. Records recovery metrics
#   5. Prompts user to power the node back on
#   6. Waits for cluster to stabilize
#   7. Repeats for different eviction timeout values
#
# REQUIREMENTS:
#   - All 3 Pi nodes running
#   - Both VMs running on worker nodes (not master)
#   - Pi nodes must have SSH access from jumphost
#
# USAGE:
#   cd ~/Bakis/experiments/scenarios
#   bash 01_ha_recovery.sh
#
# RESULTS:
#   Saved to /home/augisugnius/Bakis/experiments/results/01_ha_recovery_<timestamp>/
# =============================================================================

source "$(dirname "$0")/00_common.sh"

# =============================================================================
# CONFIGURATION
# =============================================================================

FAILURE_NODE="k3s-worker2"
FAILURE_NODE_IP="$WORKER2_IP"

TEST_VM="ubuntu-vm-1"
TEST_VM_HTTP="$VM1_HTTP"

REPETITIONS=10

# Only run 300s timeout first — comment in others once 300s is validated
# EVICTION_TIMEOUTS=(300)
EVICTION_TIMEOUTS=(300 60 30)

# How long to wait after node recovers before next test
STABILIZATION_WAIT=600

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

sanitize_number() {
    local val="$1"
    val=$(echo "$val" | grep -oE '^[0-9]+$' | tail -1)
    [ -z "$val" ] && val="-1"
    echo "$val"
}

# Set eviction timeout via systemd unit file — the only reliable method on k3s
set_eviction_timeout() {
    local timeout_seconds=$1
    echo "[INFO] $(date '+%H:%M:%S') Setting eviction timeout to ${timeout_seconds}s on master..." >&2

    ssh -i "$SSH_KEY" "$MASTER_USER@$MASTER_IP" "sudo sed -i \
        -e 's|default-not-ready-toleration-seconds=[0-9]*|default-not-ready-toleration-seconds=${timeout_seconds}|g' \
        -e 's|default-unreachable-toleration-seconds=[0-9]*|default-unreachable-toleration-seconds=${timeout_seconds}|g' \
        /etc/systemd/system/k3s.service" >/dev/null 2>&1 || true

    ssh -i "$SSH_KEY" "$MASTER_USER@$MASTER_IP" \
        "sudo systemctl daemon-reload && sudo systemctl restart k3s" >/dev/null 2>&1 || true

    echo "[INFO] $(date '+%H:%M:%S') Waiting 30s for k3s to restart..." >&2
    sleep 30

    wait_for_nodes_ready 120 || log_warn "Some nodes not ready after k3s restart"

    # Verify via systemd unit file
    local applied
    applied=$(ssh -i "$SSH_KEY" "$MASTER_USER@$MASTER_IP" \
        "sudo grep -oE 'default-not-ready-toleration-seconds=[0-9]+' /etc/systemd/system/k3s.service | head -1" 2>/dev/null) || applied=""
    if [[ "$applied" == *"=${timeout_seconds}"* ]]; then
        log_info "✓ Eviction timeout confirmed at ${timeout_seconds}s"
    else
        log_warn "⚠ Could not verify eviction timeout! Got: '$applied'"
    fi
}

# Ensure VM is on failure node before each test
ensure_vm_on_failure_node() {
    # Defensive: clear any leftover cordons from previous runs
    kubectl uncordon k3s-master >/dev/null 2>&1 || true
    kubectl uncordon k3s-worker1 >/dev/null 2>&1 || true
    kubectl uncordon k3s-worker2 >/dev/null 2>&1 || true

    local current_node
    current_node=$(get_vm_node "$TEST_VM") || current_node=""

    if [ "$current_node" == "$FAILURE_NODE" ]; then
        log_info "VM already on $FAILURE_NODE ✓"
        return 0
    fi

    log_info "Moving VM to $FAILURE_NODE (currently on ${current_node:-unknown})..."

    # Cordon worker1 only — master cannot run VMs (affinity rule)
    kubectl cordon k3s-worker1 >/dev/null 2>&1 || true

    virtctl migrate "$TEST_VM" >/dev/null 2>&1 || true

    # Wait for migration via temp file to avoid subshell hang
    local mig_file="/tmp/ha_ensure_mig_$$.tmp"
    echo "-1" > "$mig_file"
    wait_for_migration "$TEST_VM" "$current_node" 300 > "$mig_file" 2>/dev/null || true
    rm -f "$mig_file"

    kubectl uncordon k3s-worker1 >/dev/null 2>&1 || true

    local new_node
    new_node=$(get_vm_node "$TEST_VM") || new_node=""
    if [ "$new_node" == "$FAILURE_NODE" ]; then
        log_info "VM is now on $FAILURE_NODE ✓"
    else
        log_warn "VM ended up on ${new_node:-unknown} instead of $FAILURE_NODE"
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

# Wait for VM to recover on healthy node — echoes only seconds to stdout
wait_for_vm_recovery() {
    local timeout=1800
    local start
    start=$(now)
    echo "[INFO] $(date '+%H:%M:%S') Waiting for $TEST_VM to recover on a healthy node (timeout: ${timeout}s)..." >&2

    while true; do
        local phase node
        phase=$(kubectl get vmi "$TEST_VM" -o jsonpath='{.status.phase}' 2>/dev/null) || phase=""
        node=$(get_vm_node "$TEST_VM") || node=""

        if [ "$phase" == "Running" ] && [ "$node" != "$FAILURE_NODE" ] && [ -n "$node" ]; then
            local elapsed=$(($(now) - start))
            echo "[INFO] $(date '+%H:%M:%S') VM recovered on $node after ${elapsed}s" >&2
            echo "$elapsed"
            return 0
        fi
        if [ $(($(now) - start)) -gt "$timeout" ]; then
            echo "[ERROR] $(date '+%H:%M:%S') Timeout waiting for VM recovery after ${timeout}s" >&2
            echo "-1"
            return 1
        fi
        sleep 5
    done
}

# Prompt user to power node back on, then wait for it to rejoin
wait_for_node_recovery() {
    echo "" >&2
    echo "" >&2
    echo -e "${YELLOW}============================================${NC}" >&2
    echo -e "${YELLOW} MANUAL ACTION REQUIRED${NC}" >&2
    echo -e "${YELLOW}============================================${NC}" >&2
    echo -e "${YELLOW} Power on k3s-worker2 NOW:${NC}" >&2
    echo -e "${YELLOW}   1. Power on k3s-master first (already on)${NC}" >&2
    echo -e "${YELLOW}   2. Plug in USB-C power for k3s-worker2${NC}" >&2
    echo -e "${YELLOW}   3. Press ENTER immediately after plugging in${NC}" >&2
    echo -e "${YELLOW}============================================${NC}" >&2
    echo "" >&2
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

    # Safety: uncordon everything before each run
    kubectl uncordon k3s-master >/dev/null 2>&1 || true
    kubectl uncordon k3s-worker1 >/dev/null 2>&1 || true
    kubectl uncordon k3s-worker2 >/dev/null 2>&1 || true

    # Step 1: VM placement
    ensure_vm_on_failure_node

    # Step 2: Baseline snapshot
    take_snapshot "baseline_run${run_number}" "$results_dir" || true

    # Step 3: Start HTTP monitor — inline background process, NOT $()
    local http_log="$results_dir/http_run${run_number}.csv"
    (
        echo "timestamp,status,response_time_ms" > "$http_log"
        while true; do
            local start_ms end_ms http_code rt
            start_ms=$(date +%s%3N)
            http_code=$(curl -s -o /dev/null -w "%{http_code}" \
                --connect-timeout 2 --max-time 3 "$TEST_VM_HTTP" 2>/dev/null) || http_code="000"
            end_ms=$(date +%s%3N)
            rt=$((end_ms - start_ms))
            if [[ "$http_code" == "200" ]]; then
                echo "$(now),OK,$rt" >> "$http_log"
            else
                echo "$(now),FAIL_${http_code},$rt" >> "$http_log"
            fi
            sleep 1
        done
    ) &
    local http_pid=$!

    # Step 4: Start metrics collection — temp file PID, NOT $()
    local metrics_pid_file="/tmp/ha_metrics_${run_number}_$$.tmp"
    (
        while true; do
            take_snapshot "running" "$results_dir" >/dev/null 2>&1 || true
            sleep 5
        done
    ) &
    echo $! > "$metrics_pid_file"
    local metrics_pid
    metrics_pid=$(cat "$metrics_pid_file")

    # Step 5: Power off node
    log_info "Failure simulation starting at $(now_human)"
    power_off_node

    # Step 6: Wait for NotReady — temp file capture, NOT $()
    local nr_file="/tmp/ha_notready_${run_number}_$$.tmp"
    echo "-1" > "$nr_file"
    wait_for_node_not_ready > "$nr_file" || true
    local not_ready_elapsed
    not_ready_elapsed=$(sanitize_number "$(cat "$nr_file")")
    rm -f "$nr_file"
    record_timing "$results_dir" "run${run_number}_node_not_ready" "$not_ready_elapsed" || true

    # Force Longhorn to release volumes from dead node
    # Without this Longhorn holds volumes until dead node returns — blocking VM recovery
    log_info "Waiting 60s then force-detaching Longhorn volumes from $FAILURE_NODE..."
    sleep 60
    for vol in $(kubectl get volumes.longhorn.io -n longhorn-system \
        --no-headers 2>/dev/null | awk '{print $1}'); do
        kubectl patch volume.longhorn.io "$vol" -n longhorn-system \
            --type=merge \
            -p "{\"spec\":{\"nodeID\":\"\"}}" >/dev/null 2>&1 || true
    done
    log_info "Force detach applied — Longhorn will reattach to healthy node"

    # Force delete stuck virt-launcher pods on failed node
    # These get stuck in Terminating and block VM rescheduling indefinitely
    log_info "Force deleting stuck virt-launcher pods on $FAILURE_NODE..."
    sleep 10
    kubectl get pods -n default -o wide --no-headers 2>/dev/null | \
        grep "$FAILURE_NODE" | awk '{print $1}' | while read pod; do
        echo "[INFO] $(date '+%H:%M:%S') Force deleting stuck pod: $pod" >&2
        kubectl delete pod "$pod" --force --grace-period=0 \
            -n default >/dev/null 2>&1 || true
    done
    log_info "Stuck pods cleared — VM should reschedule on healthy node shortly"

    local rec_file="/tmp/ha_recovery_${run_number}_$$.tmp"
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

    # Step 10: HTTP downtime
    local downtime_seconds
    downtime_seconds=$(count_http_failures "$http_log")
    record_timing "$results_dir" "run${run_number}_http_downtime" "$downtime_seconds" || true

    log_info "Run $run_number complete:"
    log_info "  Node went NotReady: ${not_ready_elapsed}s"
    log_info "  VM recovered: ${recovery_elapsed}s"
    log_info "  HTTP downtime: ${downtime_seconds}s"

    # Step 11: Prompt user to power node back on
    wait_for_node_recovery || log_warn "Node recovery wait timed out — check cluster state"

    # Step 12: Stabilization wait
    log_info "Waiting ${STABILIZATION_WAIT}s for cluster to stabilize (Longhorn replica rebuild)..."
    sleep "$STABILIZATION_WAIT"

    return 0
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    # Safety cleanup on any exit — uncordon nodes, kill orphan processes, remove temp files
    trap 'kubectl uncordon k3s-master 2>/dev/null || true; \
          kubectl uncordon k3s-worker1 2>/dev/null || true; \
          kubectl uncordon k3s-worker2 2>/dev/null || true; \
          pkill -f "take_snapshot" 2>/dev/null || true; \
          rm -f /tmp/ha_*.tmp /tmp/ha_metrics_*.tmp 2>/dev/null || true' EXIT

    log_step "Scenario 1: HA Recovery Testing"
    log_info "This scenario tests how long the cluster takes to recover"
    log_info "VM workloads after a node failure, with different eviction timeouts."
    log_info ""
    log_info "Configuration:"
    log_info "  Failure node: $FAILURE_NODE ($FAILURE_NODE_IP)"
    log_info "  Test VM: $TEST_VM"
    log_info "  Repetitions per timeout: $REPETITIONS"
    log_info "  Eviction timeouts: ${EVICTION_TIMEOUTS[*]}s"
    log_info "  Recovery timeout: 1800s (30 min max per run)"
    log_info "  Stabilization wait: ${STABILIZATION_WAIT}s between runs"
    log_info ""
    log_warn "IMPORTANT: This test will power off $FAILURE_NODE"
    log_warn "You will be prompted to power it back on after each run."
    log_warn "Total power cycles: $((REPETITIONS * ${#EVICTION_TIMEOUTS[@]}))"
    log_warn ""
    read -p "Press ENTER to start, or Ctrl+C to cancel..."

    check_prerequisites
    check_experiment_prerequisites

    # Hardcoded absolute path — avoids all $() / path resolution bugs
    local results_dir="/home/augisugnius/Bakis/experiments/results/01_ha_recovery_$(date '+%Y%m%d_%H%M%S')"
    mkdir -p "$results_dir"
    log_info "Results will be saved to: $results_dir"

    cat > "$results_dir/scenario_config.txt" << EOF
Scenario: HA Recovery Testing
Date: $(now_human)
Failure node: $FAILURE_NODE
Test VM: $TEST_VM
Repetitions: $REPETITIONS
Eviction timeouts tested: ${EVICTION_TIMEOUTS[*]}s
Recovery timeout per run: 1800s
Stabilization wait: ${STABILIZATION_WAIT}s
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
    ls -la "$results_dir"/*/timing_summary.csv 2>/dev/null >&2 || true
}

main "$@"
