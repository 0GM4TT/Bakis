#!/bin/bash
# =============================================================================
# 02_live_migration.sh
# Scenario 2: Live Migration Testing
# =============================================================================
#
# WHAT THIS TESTS:
#   How long does live migration take, and how much HTTP downtime occurs,
#   comparing an idle VM versus a VM under CPU/memory load.
#
# HOW IT WORKS:
#   Part A — Unloaded migration:
#     1. Records baseline metrics
#     2. Starts HTTP monitor on VM1
#     3. Triggers live migration
#     4. Records migration duration and HTTP downtime
#     5. Repeats 10 times
#
#   Part B — Loaded migration:
#     1. Starts stress-ng load inside VM (CPU + memory)
#     2. Records baseline metrics under load
#     3. Starts HTTP monitor
#     4. Triggers live migration
#     5. Records migration duration and HTTP downtime
#     6. Stops load
#     7. Repeats 10 times
#
# REQUIREMENTS:
#   - All 3 Pi nodes running
#   - Both VMs running
#   - stress-ng installed inside VMs (script will install if missing)
#
# USAGE:
#   bash 02_live_migration.sh
#
# RESULTS:
#   Saved to experiments/results/02_live_migration_<timestamp>/
#   - timing_summary.csv     — migration times per run
#   - metrics_snapshots.csv  — resource usage before/during/after
#   - http_monitor_*.csv     — HTTP availability during migration
# =============================================================================

source "$(dirname "$0")/00_common.sh"

# =============================================================================
# CONFIGURATION
# =============================================================================

TEST_VM="ubuntu-vm-1"
TEST_VM_HTTP="$VM1_HTTP"
TEST_VM_SSH_PORT="$VM1_SSH_PORT"

REPETITIONS=10
BETWEEN_RUNS_WAIT=30

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

ensure_stress_ng() {
    log_info "Checking if stress-ng is installed in $TEST_VM..."
    local result
    result=$(ssh -i "$SSH_KEY" -p "$TEST_VM_SSH_PORT" \
        -o StrictHostKeyChecking=no \
        ubuntu@"$MASTER_IP" \
        "which stress-ng 2>/dev/null || echo 'not_found'")

    if [ "$result" == "not_found" ]; then
        log_info "Installing stress-ng..."
        install_stress_ng "$TEST_VM_SSH_PORT"
    else
        log_info "stress-ng already installed ✓"
    fi
}

trigger_and_wait_migration() {
    local original_node
    original_node=$(get_vm_node "$TEST_VM")
    echo "[INFO] $(date '+%H:%M:%S') Starting migration of $TEST_VM from $original_node..." >&2

    # Safety: uncordon everything first to ensure clean state
    kubectl uncordon k3s-worker1 >/dev/null 2>&1 || true
    kubectl uncordon k3s-worker2 >/dev/null 2>&1 || true

    # Determine destination node
    local destination_node
    if [ "$original_node" == "k3s-worker1" ]; then
        destination_node="k3s-worker2"
    else
        destination_node="k3s-worker1"
    fi

    echo "[INFO] $(date '+%H:%M:%S') Cordoning $original_node to force migration to $destination_node..." >&2
    kubectl cordon "$original_node" >/dev/null 2>&1 || true

    virtctl migrate "$TEST_VM" >/dev/null 2>&1 || true

    local elapsed
    elapsed=$(wait_for_migration "$TEST_VM" "$original_node" 600 2>/dev/null) || elapsed="-1"
    
    # Strip any non-numeric characters as a safety net
    elapsed=$(echo "$elapsed" | grep -oE '^[0-9]+$' | tail -1)
    [ -z "$elapsed" ] && elapsed="-1"

    echo "[INFO] $(date '+%H:%M:%S') Uncordoning $original_node..." >&2
    kubectl uncordon "$original_node" >/dev/null 2>&1 || true

    if [ "$elapsed" == "-1" ]; then
        echo "[ERROR] $(date '+%H:%M:%S') Migration failed or timed out — skipping this run" >&2
        echo "-1"
        return 0
    fi

    local new_node
    new_node=$(get_vm_node "$TEST_VM")
    echo "[INFO] $(date '+%H:%M:%S') Migration complete: $original_node → $new_node in ${elapsed}s" >&2

    echo "$elapsed"
    return 0
}

count_http_failures() {
    local log_file=$1
    if [ -f "$log_file" ]; then
        python3 -c "
import csv
fails = 0
total = 0
with open('$log_file') as f:
    for row in csv.DictReader(f):
        total += 1
        if row['status'] != 'OK':
            fails += 1
print(f'{fails}/{total}')
" 2>/dev/null || echo "0/0"
    else
        echo "0/0"
    fi
}

# =============================================================================
# SINGLE MIGRATION RUN
# =============================================================================

run_migration() {
    local run_number=$1
    local mode=$2
    local results_dir=$3

    log_step "Run $run_number / $REPETITIONS ($mode)"

    # Safety: ensure no nodes are cordoned before starting
    kubectl uncordon k3s-worker1 2>/dev/null || true
    kubectl uncordon k3s-worker2 2>/dev/null || true

    # Verify VM is actually migratable before proceeding
    local migratable
    migratable=$(kubectl get vmi "$TEST_VM" \
        -o jsonpath='{.status.conditions[?(@.type=="LiveMigratable")].status}' 2>/dev/null) || migratable=""
    if [ "$migratable" != "True" ]; then
        log_warn "VM $TEST_VM is not migratable right now, waiting 15s..."
        sleep 15
    fi

    local http_log="$results_dir/http_run${run_number}_${mode}.csv"

    take_snapshot "baseline_${mode}_run${run_number}" "$results_dir" || true

    # Start HTTP monitor in background
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

    # Start metrics collection avoiding $() subshell hang
    local metrics_pid_file="/tmp/metrics_pid_${run_number}_${mode}.tmp"
    (
        while true; do
            take_snapshot "running" "$results_dir" || true
            sleep 5
        done
    ) &
    echo $! > "$metrics_pid_file"
    local metrics_pid
    metrics_pid=$(cat "$metrics_pid_file")

    sleep 3

    # Trigger migration avoiding $() subshell hang
    local migration_elapsed_file="/tmp/migration_elapsed_${run_number}_${mode}.tmp"
    echo "-1" > "$migration_elapsed_file"
    trigger_and_wait_migration > "$migration_elapsed_file" || true
    local migration_elapsed
    migration_elapsed=$(cat "$migration_elapsed_file")

    sleep 5
    take_snapshot "post_migration_${mode}_run${run_number}" "$results_dir" || true

    # Clean up background processes
    kill "$http_pid" 2>/dev/null || true
    wait "$http_pid" 2>/dev/null || true
    kill "$metrics_pid" 2>/dev/null || true
    wait "$metrics_pid" 2>/dev/null || true
    rm -f "$metrics_pid_file" "$migration_elapsed_file"

    record_timing "$results_dir" "${mode}_run${run_number}_migration_duration" "$migration_elapsed" || true

    local failures
    failures=$(count_http_failures "$http_log")
    log_info "Run $run_number ($mode): duration=${migration_elapsed}s, HTTP failures=${failures}"

     # Collect Kubernetes events for this run

    log_info "Collecting Kubernetes events for run ${run_number}..."

    kubectl get events --all-namespaces --sort-by='.lastTimestamp' -o json \

        > "$results_dir/events_run${run_number}_${mode}.json" 2>/dev/null || true

    log_info "Events saved to events_run${run_number}_${mode}.json"

    log_info "Waiting ${BETWEEN_RUNS_WAIT}s before next run..."
    sleep "$BETWEEN_RUNS_WAIT"

    return 0
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    # Safety cleanup — uncordon all nodes if script exits for any reason
    trap 'kubectl uncordon k3s-worker1 2>/dev/null || true; kubectl uncordon k3s-worker2 2>/dev/null || true' EXIT

    log_step "Scenario 2: Live Migration Testing"
    log_info "This scenario measures VM live migration duration and HTTP"
    log_info "availability impact under both idle and loaded conditions."
    log_info ""
    log_info "Configuration:"
    log_info "  Test VM: $TEST_VM"
    log_info "  Repetitions: $REPETITIONS (per condition)"
    log_info "  Total migrations: $((REPETITIONS * 2))"
    log_info ""
    read -p "Press ENTER to start, or Ctrl+C to cancel..."

    check_prerequisites
    check_experiment_prerequisites

    local results_dir
    results_dir=$(init_results_dir "02_live_migration")
    log_info "Results will be saved to: $results_dir"

    cat > "$results_dir/scenario_config.txt" << EOF
Scenario: Live Migration Testing
Date: $(now_human)
Test VM: $TEST_VM
Repetitions per condition: $REPETITIONS
Conditions: unloaded, loaded
EOF

    ensure_stress_ng

    # Part A: Unloaded migration
    log_step "Part A: Unloaded Migration (${REPETITIONS} runs)"
    local unloaded_dir="$results_dir/unloaded"
    mkdir -p "$unloaded_dir"

    for i in $(seq 1 "$REPETITIONS"); do
        run_migration "$i" "unloaded" "$unloaded_dir" || true
    done

    print_timing_summary "$unloaded_dir"

    # Part B: Loaded migration
    log_step "Part B: Loaded Migration (${REPETITIONS} runs)"
    local loaded_dir="$results_dir/loaded"
    mkdir -p "$loaded_dir"

    for i in $(seq 1 "$REPETITIONS"); do
        start_vm_load "$TEST_VM" "$TEST_VM_SSH_PORT" || true
        sleep 10

        run_migration "$i" "loaded" "$loaded_dir" || true

        stop_vm_load "$TEST_VM" "$TEST_VM_SSH_PORT" || true
        sleep 5
    done

    print_timing_summary "$loaded_dir"

    log_step "Exporting detailed metrics..."
    local end_ts
    end_ts=$(now)
    local start_ts=$((end_ts - 7200))

    for dir in "$unloaded_dir" "$loaded_dir"; do
        export_metrics_to_csv \
            "100 - (avg(rate(node_cpu_seconds_total{mode='idle'}[1m])) * 100)" \
            "$start_ts" "$end_ts" 15 \
            "$dir/cpu_timeseries.csv" "cpu_pct" || true

        export_metrics_to_csv \
            "rate(node_network_transmit_bytes_total{device='eth0'}[1m])" \
            "$start_ts" "$end_ts" 15 \
            "$dir/network_timeseries.csv" "net_tx_bytes_per_sec" || true
    done

    log_step "All migration tests complete!"
    log_info "Results saved to: $results_dir"

    echo ""
    log_step "COMPARISON SUMMARY"
    echo "Unloaded migrations:"
    grep "migration_duration" "$unloaded_dir/timing_summary.csv" | column -t -s',' || true
    echo ""
    echo "Loaded migrations:"
    grep "migration_duration" "$loaded_dir/timing_summary.csv" | column -t -s',' || true
}

main "$@"
