#!/bin/bash
# =============================================================================
# 02_live_migration.sh
# Scenario 2: Live Migration Testing
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

set -e
source "$(dirname "$0")/00_common.sh"

# =============================================================================
# CONFIGURATION
# =============================================================================

TEST_VM="ubuntu-vm-1"
TEST_VM_HTTP="$VM1_HTTP"
TEST_VM_SSH_PORT="$VM1_SSH_PORT"

REPETITIONS=10

# Wait between migration runs (seconds)
BETWEEN_RUNS_WAIT=30

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

# Ensure stress-ng is installed inside VM
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

# Trigger migration and wait for completion
# Returns migration duration in seconds
trigger_and_wait_migration() {
    local original_node
    original_node=$(get_vm_node "$TEST_VM")
    log_info "Starting migration of $TEST_VM from $original_node..."

    local start=$(now)

    # Trigger migration
    virtctl migrate "$TEST_VM"

    # Wait for completion
    local elapsed
    elapsed=$(wait_for_migration "$TEST_VM" "$original_node" 600)

    local new_node
    new_node=$(get_vm_node "$TEST_VM")
    log_info "Migration complete: $original_node → $new_node in ${elapsed}s"

    echo "$elapsed"
}

# Count HTTP failures from monitor log
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
    local mode=$2        # "unloaded" or "loaded"
    local results_dir=$3

    log_step "Run $run_number / $REPETITIONS ($mode)"

    local http_log="$results_dir/http_run${run_number}_${mode}.csv"

    # Take baseline snapshot
    take_snapshot "baseline_${mode}_run${run_number}" "$results_dir"

    # Start HTTP monitoring
    local http_pid
    (
        echo "timestamp,status,response_time_ms" > "$http_log"
        while true; do
            local start_ms=$(date +%s%3N)
            local http_code
            http_code=$(curl -s -o /dev/null -w "%{http_code}" \
                --connect-timeout 2 --max-time 3 "$TEST_VM_HTTP" 2>/dev/null)
            local end_ms=$(date +%s%3N)
            local rt=$((end_ms - start_ms))
            if [[ "$http_code" == "200" ]]; then
                echo "$(now),OK,$rt" >> "$http_log"
            else
                echo "$(now),FAIL_${http_code},$rt" >> "$http_log"
            fi
            sleep 1
        done
    ) &
    http_pid=$!

    # Start metrics collection
    local metrics_pid
    metrics_pid=$(start_metrics_collection "$results_dir" 5)

    # Wait a moment for monitoring to start
    sleep 3

    # Trigger migration and measure time
    local migration_elapsed
    migration_elapsed=$(trigger_and_wait_migration)

    # Take post-migration snapshot
    sleep 5
    take_snapshot "post_migration_${mode}_run${run_number}" "$results_dir"

    # Stop monitoring
    kill "$http_pid" 2>/dev/null; wait "$http_pid" 2>/dev/null || true
    stop_metrics_collection "$metrics_pid"

    # Record results
    record_timing "$results_dir" "${mode}_run${run_number}_migration_duration" "$migration_elapsed"

    local failures
    failures=$(count_http_failures "$http_log")
    log_info "Run $run_number ($mode): duration=${migration_elapsed}s, HTTP failures=${failures}"

    # Wait between runs
    log_info "Waiting ${BETWEEN_RUNS_WAIT}s before next run..."
    sleep "$BETWEEN_RUNS_WAIT"
}

# =============================================================================
# MAIN
# =============================================================================

main() {
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

    # Write config
    cat > "$results_dir/scenario_config.txt" << EOF
Scenario: Live Migration Testing
Date: $(now_human)
Test VM: $TEST_VM
Repetitions per condition: $REPETITIONS
Conditions: unloaded, loaded
EOF

    # Ensure stress-ng is available
    ensure_stress_ng

    # -------------------------
    # Part A: Unloaded migration
    # -------------------------
    log_step "Part A: Unloaded Migration (${REPETITIONS} runs)"
    local unloaded_dir="$results_dir/unloaded"
    mkdir -p "$unloaded_dir"

    for i in $(seq 1 "$REPETITIONS"); do
        run_migration "$i" "unloaded" "$unloaded_dir"
    done

    print_timing_summary "$unloaded_dir"

    # -------------------------
    # Part B: Loaded migration
    # -------------------------
    log_step "Part B: Loaded Migration (${REPETITIONS} runs)"
    local loaded_dir="$results_dir/loaded"
    mkdir -p "$loaded_dir"

    for i in $(seq 1 "$REPETITIONS"); do
        # Start load before migration
        start_vm_load "$TEST_VM" "$TEST_VM_SSH_PORT"
        sleep 10  # Let load stabilize

        run_migration "$i" "loaded" "$loaded_dir"

        # Stop load after migration
        stop_vm_load "$TEST_VM" "$TEST_VM_SSH_PORT"
        sleep 5
    done

    print_timing_summary "$loaded_dir"

    # Export time series metrics
    log_step "Exporting detailed metrics..."
    local end_ts=$(now)
    local start_ts=$((end_ts - 7200))

    for dir in "$unloaded_dir" "$loaded_dir"; do
        export_metrics_to_csv \
            "100 - (avg(rate(node_cpu_seconds_total{mode='idle'}[1m])) * 100)" \
            "$start_ts" "$end_ts" 15 \
            "$dir/cpu_timeseries.csv" "cpu_pct"

        export_metrics_to_csv \
            "rate(node_network_transmit_bytes_total{device='eth0'}[1m])" \
            "$start_ts" "$end_ts" 15 \
            "$dir/network_timeseries.csv" "net_tx_bytes_per_sec"
    done

    log_step "All migration tests complete!"
    log_info "Results saved to: $results_dir"

    # Print comparison summary
    echo ""
    log_step "COMPARISON SUMMARY"
    echo "Unloaded migrations:"
    grep "migration_duration" "$unloaded_dir/timing_summary.csv" | column -t -s','
    echo ""
    echo "Loaded migrations:"
    grep "migration_duration" "$loaded_dir/timing_summary.csv" | column -t -s','
}

main "$@"