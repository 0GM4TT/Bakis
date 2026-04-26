#!/bin/bash
# =============================================================================
# 04_vm_spinup.sh
# Scenario 4: VM Deployment Time Measurement
#
# WHAT THIS TESTS:
#   How long does it take to deploy a fresh VM from a YAML manifest,
#   broken down into stages:
#     - DataVolume import (disk image download + write to Longhorn)
#     - VM scheduling and boot
#     - Network initialization
#     - Application ready (web server responding)
#
# HOW IT WORKS:
#   1. Deletes existing test VM
#   2. Records start timestamp
#   3. Applies VM manifest
#   4. Records timestamp at each milestone
#   5. Measures total time to full readiness
#   6. Repeats 10 times
#
# REQUIREMENTS:
#   - All 3 Pi nodes running
#   - Longhorn storage healthy
#
# USAGE:
#   bash 04_vm_spinup.sh
#
# NOTE:
#   First run will be slower because the Ubuntu image is not cached.
#   Subsequent runs may be faster due to CDI caching.
#   Both are recorded — this difference is itself an interesting finding.
#
# RESULTS:
#   Saved to experiments/results/04_vm_spinup_<timestamp>/
#   - timing_summary.csv — stage timings per run
#   - metrics_snapshots.csv — cluster resource usage during deployment
# =============================================================================

source "$(dirname "$0")/00_common.sh"

# =============================================================================
# CONFIGURATION
# =============================================================================

# We use VM2 for spinup tests to leave VM1 running for HTTP availability
TEST_VM="ubuntu-vm-2"
TEST_VM_MANIFEST="$(dirname "$0")/../../manifests/vms/ubuntu-vm-2.yaml"
TEST_VM_HTTP="$VM2_HTTP"
TEST_VM_SSH_PORT="$VM2_SSH_PORT"
TEST_VM_SERVICES="$(dirname "$0")/../../manifests/vms/ubuntu-vm-2-services.yaml"

REPETITIONS=10

# Time to wait between runs for Longhorn to clean up
BETWEEN_RUNS_WAIT=60

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

# Delete VM and its PVC to force fresh deployment
cleanup_test_vm() {
    echo "[INFO] $(date '+%H:%M:%S') Cleaning up $TEST_VM for fresh deployment..." >&2

    kubectl delete vm "$TEST_VM" --ignore-not-found=true >/dev/null 2>&1 || true
    kubectl delete vmi "$TEST_VM" --ignore-not-found=true >/dev/null 2>&1 || true

    # Wait for VMI to be gone
    local timeout=60
    local start
    start=$(now)
    while kubectl get vmi "$TEST_VM" >/dev/null 2>&1; do
        if [ $(($(now) - start)) -gt "$timeout" ]; then
            echo "[WARN] $(date '+%H:%M:%S') Timeout waiting for VMI deletion" >&2
            break
        fi
        sleep 2
    done

    kubectl delete pvc "${TEST_VM}-disk" --ignore-not-found=true >/dev/null 2>&1 || true

    start=$(now)
    while kubectl get pvc "${TEST_VM}-disk" >/dev/null 2>&1; do
        if [ $(($(now) - start)) -gt "$timeout" ]; then
            echo "[WARN] $(date '+%H:%M:%S') Timeout waiting for PVC deletion" >&2
            break
        fi
        sleep 2
    done

    echo "[INFO] $(date '+%H:%M:%S') Cleanup complete" >&2
    sleep 10
}

# Wait for DataVolume to be Ready (disk image imported)
# Echoes only the elapsed seconds to stdout
wait_for_datavolume() {
    local timeout=600
    local start
    start=$(now)
    echo "[INFO] $(date '+%H:%M:%S') Waiting for DataVolume to be ready..." >&2

    while true; do
        local phase
        phase=$(kubectl get datavolume "${TEST_VM}-disk" \
            -o jsonpath='{.status.phase}' 2>/dev/null) || phase="NotFound"

        if [ "$phase" == "Succeeded" ]; then
            local elapsed=$(($(now) - start))
            echo "[INFO] $(date '+%H:%M:%S') DataVolume ready after ${elapsed}s" >&2
            echo "$elapsed"
            return 0
        fi

        if [ $(($(now) - start)) -gt "$timeout" ]; then
            echo "[ERROR] $(date '+%H:%M:%S') Timeout waiting for DataVolume" >&2
            echo "-1"
            return 1
        fi

        sleep 5
    done
}

# Wait for VM HTTP endpoint to respond
# Echoes only the elapsed seconds to stdout
wait_for_http_ready() {
    local timeout=120
    local start
    start=$(now)
    echo "[INFO] $(date '+%H:%M:%S') Waiting for HTTP endpoint to respond..." >&2

    while true; do
        local http_code
        http_code=$(curl -s -o /dev/null -w "%{http_code}" \
            --connect-timeout 2 --max-time 3 \
            "$TEST_VM_HTTP" 2>/dev/null) || http_code="000"

        if [ "$http_code" == "200" ]; then
            local elapsed=$(($(now) - start))
            echo "[INFO] $(date '+%H:%M:%S') HTTP ready after ${elapsed}s" >&2
            echo "$elapsed"
            return 0
        fi

        if [ $(($(now) - start)) -gt "$timeout" ]; then
            echo "[WARN] $(date '+%H:%M:%S') Timeout waiting for HTTP" >&2
            echo "-1"
            return 1
        fi

        sleep 3
    done
}

# Helper: ensure value is a clean integer or -1
sanitize_number() {
    local val="$1"
    val=$(echo "$val" | grep -oE '^[0-9]+$' | tail -1)
    [ -z "$val" ] && val="-1"
    echo "$val"
}

# =============================================================================
# SINGLE SPINUP RUN
# =============================================================================

run_spinup() {
    local run_number=$1
    local results_dir=$2

    log_step "Run $run_number / $REPETITIONS"

    # Start metrics collection — avoid $() subshell which blocks on background processes
    local metrics_pid_file="/tmp/metrics_pid_spinup_${run_number}.tmp"
    (
        while true; do
            take_snapshot "running" "$results_dir" >/dev/null 2>&1 || true
            sleep 5
        done
    ) &
    echo $! > "$metrics_pid_file"
    local metrics_pid
    metrics_pid=$(cat "$metrics_pid_file")

    # Take pre-deployment snapshot
    take_snapshot "pre_deploy_run${run_number}" "$results_dir" || true

    # Record start time
    local t_start
    t_start=$(now)
    log_info "Deployment started at $(now_human)"

    # Apply VM manifest
    kubectl apply -f "$TEST_VM_MANIFEST" >/dev/null 2>&1 || true
    kubectl apply -f "$TEST_VM_SERVICES" >/dev/null 2>&1 || true
    local t_manifest_applied
    t_manifest_applied=$(now)
    record_timing "$results_dir" "run${run_number}_manifest_applied" \
        $((t_manifest_applied - t_start)) || true

    # Wait for DataVolume — capture via temp file to avoid subshell hang
    local dv_file="/tmp/dv_elapsed_${run_number}.tmp"
    echo "-1" > "$dv_file"
    wait_for_datavolume > "$dv_file" || true
    local dv_elapsed
    dv_elapsed=$(sanitize_number "$(cat "$dv_file")")
    rm -f "$dv_file"
    local t_dv_ready
    t_dv_ready=$(now)
    record_timing "$results_dir" "run${run_number}_disk_import" "$dv_elapsed" || true

    # Wait for VMI to be Running — capture via temp file
    local vm_file="/tmp/vm_elapsed_${run_number}.tmp"
    echo "-1" > "$vm_file"
    wait_for_vm_ready "$TEST_VM" 300 > "$vm_file" 2>/dev/null || true
    local vm_elapsed
    vm_elapsed=$(sanitize_number "$(cat "$vm_file")")
    rm -f "$vm_file"
    local t_vm_running
    t_vm_running=$(now)
    record_timing "$results_dir" "run${run_number}_vm_running" \
        $((t_vm_running - t_dv_ready)) || true

    # Wait for network (extra time for cloud-init)
    log_info "Waiting for network initialization (cloud-init)..."
    sleep 30
    local t_network
    t_network=$(now)
    record_timing "$results_dir" "run${run_number}_network_init" \
        $((t_network - t_vm_running)) || true

    # Wait for HTTP — capture via temp file
    local http_file="/tmp/http_elapsed_${run_number}.tmp"
    echo "-1" > "$http_file"
    wait_for_http_ready > "$http_file" || true
    local http_elapsed
    http_elapsed=$(sanitize_number "$(cat "$http_file")")
    rm -f "$http_file"
    local t_http_ready
    t_http_ready=$(now)
    record_timing "$results_dir" "run${run_number}_http_ready" "$http_elapsed" || true

    # Calculate total time
    local total=$((t_http_ready - t_start))
    record_timing "$results_dir" "run${run_number}_TOTAL" "$total" || true

    # Take post-deployment snapshot
    take_snapshot "post_deploy_run${run_number}" "$results_dir" || true

    # Stop metrics collection
    kill "$metrics_pid" 2>/dev/null || true
    wait "$metrics_pid" 2>/dev/null || true
    rm -f "$metrics_pid_file"

    log_info "Run $run_number complete:"
    log_info "  Disk import: ${dv_elapsed}s"
    log_info "  VM running: $((t_vm_running - t_dv_ready))s"
    log_info "  Network init: 30s"
    log_info "  HTTP ready: ${http_elapsed}s"
    log_info "  TOTAL: ${total}s"

    # Cleanup for next run
    log_info "Cleaning up for next run..."
    cleanup_test_vm
    log_info "Waiting ${BETWEEN_RUNS_WAIT}s before next run..."
    sleep "$BETWEEN_RUNS_WAIT"

    return 0
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    # Safety cleanup on exit
    trap 'pkill -f "take_snapshot" 2>/dev/null || true; rm -f /tmp/metrics_pid_spinup_*.tmp /tmp/dv_elapsed_*.tmp /tmp/vm_elapsed_*.tmp /tmp/http_elapsed_*.tmp 2>/dev/null || true' EXIT

    log_step "Scenario 4: VM Deployment Time Measurement"
    log_info "This scenario measures how long it takes to deploy a fresh VM"
    log_info "from a YAML manifest to fully operational."
    log_info ""
    log_info "Configuration:"
    log_info "  Test VM: $TEST_VM"
    log_info "  Repetitions: $REPETITIONS"
    log_info ""
    log_warn "NOTE: This test will DELETE and RECREATE $TEST_VM repeatedly."
    log_warn "VM2 web page will be unavailable during tests."
    log_warn ""
    read -p "Press ENTER to start, or Ctrl+C to cancel..."

    check_prerequisites
    check_experiment_prerequisites

    # Verify manifest exists
    if [ ! -f "$TEST_VM_MANIFEST" ]; then
        log_error "VM manifest not found: $TEST_VM_MANIFEST"
        exit 1
    fi

    local results_dir
    results_dir=$(init_results_dir "04_vm_spinup")
    log_info "Results will be saved to: $results_dir"

    cat > "$results_dir/scenario_config.txt" << EOF
Scenario: VM Deployment Time
Date: $(now_human)
Test VM: $TEST_VM
Repetitions: $REPETITIONS
Stages measured:
  - manifest_applied
  - disk_import (DataVolume ready)
  - vm_running (VMI phase = Running)
  - network_init (cloud-init)
  - http_ready (web server responding)
  - TOTAL
EOF

    # Initial cleanup
    cleanup_test_vm

    # Run tests
    for i in $(seq 1 "$REPETITIONS"); do
        run_spinup "$i" "$results_dir" || true
    done

    # Export metrics
    log_step "Exporting time series data..."
    local end_ts
    end_ts=$(now)
    local start_ts=$((end_ts - 7200))

    export_metrics_to_csv \
        "100 - (avg(rate(node_cpu_seconds_total{mode='idle'}[1m])) * 100)" \
        "$start_ts" "$end_ts" 15 \
        "$results_dir/cpu_timeseries.csv" "cpu_pct" || true

    export_metrics_to_csv \
        "rate(node_disk_written_bytes_total[1m])" \
        "$start_ts" "$end_ts" 15 \
        "$results_dir/disk_write_timeseries.csv" "write_bytes_per_sec" || true

    print_timing_summary "$results_dir"

    log_step "VM spinup tests complete!"
    log_info "Results saved to: $results_dir"

    # Compute averages
    log_info "Computing averages..."
    python3 -c "
import csv
from collections import defaultdict

timings = defaultdict(list)
with open('$results_dir/timing_summary.csv') as f:
    for row in csv.DictReader(f):
        label = row['label']
        val = row['seconds']
        try:
            v = float(val)
            if v >= 0:
                stage = '_'.join(label.split('_')[2:]) if label.count('_') >= 2 else label
                timings[stage].append(v)
        except ValueError:
            pass

print('\nAverage deployment times:')
print('-' * 40)
for stage, values in sorted(timings.items()):
    avg = sum(values) / len(values)
    mn = min(values)
    mx = max(values)
    print(f'  {stage:<25} avg={avg:.1f}s  min={mn:.1f}s  max={mx:.1f}s')
" 2>/dev/null || true
}

main "$@"
