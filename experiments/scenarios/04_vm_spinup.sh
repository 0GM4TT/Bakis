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

set -e
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
    log_info "Cleaning up $TEST_VM for fresh deployment..."

    # Delete VM
    kubectl delete vm "$TEST_VM" --ignore-not-found=true
    kubectl delete vmi "$TEST_VM" --ignore-not-found=true

    # Wait for VMI to be gone
    local timeout=60
    local start=$(now)
    while kubectl get vmi "$TEST_VM" &>/dev/null; do
        if [ $(($(now) - start)) -gt "$timeout" ]; then
            log_warn "Timeout waiting for VMI deletion"
            break
        fi
        sleep 2
    done

    # Delete PVC (forces fresh disk image import)
    kubectl delete pvc "${TEST_VM}-disk" --ignore-not-found=true

    # Wait for PVC to be gone
    start=$(now)
    while kubectl get pvc "${TEST_VM}-disk" &>/dev/null; do
        if [ $(($(now) - start)) -gt "$timeout" ]; then
            log_warn "Timeout waiting for PVC deletion"
            break
        fi
        sleep 2
    done

    log_info "Cleanup complete"
    sleep 10
}

# Wait for DataVolume to be Ready (disk image imported)
wait_for_datavolume() {
    local timeout=600
    local start=$(now)
    log_info "Waiting for DataVolume to be ready (disk image import)..."

    while true; do
        local phase
        phase=$(kubectl get datavolume "${TEST_VM}-disk" \
            -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")

        if [ "$phase" == "Succeeded" ]; then
            local elapsed=$(($(now) - start))
            log_info "DataVolume ready after ${elapsed}s"
            echo "$elapsed"
            return 0
        fi

        if [ $(($(now) - start)) -gt "$timeout" ]; then
            log_error "Timeout waiting for DataVolume"
            echo "timeout"
            return 1
        fi

        sleep 5
    done
}

# Wait for VM HTTP endpoint to respond
wait_for_http_ready() {
    local timeout=120
    local start=$(now)
    log_info "Waiting for HTTP endpoint to respond..."

    while true; do
        local http_code
        http_code=$(curl -s -o /dev/null -w "%{http_code}" \
            --connect-timeout 2 --max-time 3 \
            "$TEST_VM_HTTP" 2>/dev/null)

        if [ "$http_code" == "200" ]; then
            local elapsed=$(($(now) - start))
            log_info "HTTP ready after ${elapsed}s"
            echo "$elapsed"
            return 0
        fi

        if [ $(($(now) - start)) -gt "$timeout" ]; then
            log_warn "Timeout waiting for HTTP — VM may need more time"
            echo "timeout"
            return 1
        fi

        sleep 3
    done
}

# =============================================================================
# SINGLE SPINUP RUN
# =============================================================================

run_spinup() {
    local run_number=$1
    local results_dir=$2

    log_step "Run $run_number / $REPETITIONS"

    # Start metrics collection
    local metrics_pid
    metrics_pid=$(start_metrics_collection "$results_dir" 5)

    # Take pre-deployment snapshot
    take_snapshot "pre_deploy_run${run_number}" "$results_dir"

    # Record start time
    local t_start=$(now)
    log_info "Deployment started at $(now_human)"

    # Apply VM manifest
    kubectl apply -f "$TEST_VM_MANIFEST"
    kubectl apply -f "$TEST_VM_SERVICES"
    local t_manifest_applied=$(now)
    record_timing "$results_dir" "run${run_number}_manifest_applied" \
        $((t_manifest_applied - t_start))

    # Wait for DataVolume (disk import)
    local dv_elapsed
    dv_elapsed=$(wait_for_datavolume)
    local t_dv_ready=$(now)
    record_timing "$results_dir" "run${run_number}_disk_import" "$dv_elapsed"

    # Wait for VMI to be Running
    local vm_elapsed
    vm_elapsed=$(wait_for_vm_ready "$TEST_VM" 300)
    local t_vm_running=$(now)
    record_timing "$results_dir" "run${run_number}_vm_running" \
        $((t_vm_running - t_dv_ready))

    # Wait for network (extra time for cloud-init)
    log_info "Waiting for network initialization (cloud-init)..."
    sleep 30
    local t_network=$(now)
    record_timing "$results_dir" "run${run_number}_network_init" \
        $((t_network - t_vm_running))

    # Wait for HTTP
    local http_elapsed
    http_elapsed=$(wait_for_http_ready)
    local t_http_ready=$(now)
    record_timing "$results_dir" "run${run_number}_http_ready" "$http_elapsed"

    # Calculate total time
    local total=$((t_http_ready - t_start))
    record_timing "$results_dir" "run${run_number}_TOTAL" "$total"

    # Take post-deployment snapshot
    take_snapshot "post_deploy_run${run_number}" "$results_dir"

    # Stop metrics collection
    stop_metrics_collection "$metrics_pid"

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
}

# =============================================================================
# MAIN
# =============================================================================

main() {
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

    # Write config
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
        run_spinup "$i" "$results_dir"
    done

    # Export metrics
    log_step "Exporting time series data..."
    local end_ts=$(now)
    local start_ts=$((end_ts - 7200))

    export_metrics_to_csv \
        "100 - (avg(rate(node_cpu_seconds_total{mode='idle'}[1m])) * 100)" \
        "$start_ts" "$end_ts" 15 \
        "$results_dir/cpu_timeseries.csv" "cpu_pct"

    export_metrics_to_csv \
        "rate(node_disk_written_bytes_total[1m])" \
        "$start_ts" "$end_ts" 15 \
        "$results_dir/disk_write_timeseries.csv" "write_bytes_per_sec"

    # Print final summary
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
        if val != 'timeout':
            # Extract stage name (remove run number prefix)
            stage = '_'.join(label.split('_')[2:]) if label.count('_') >= 2 else label
            timings[stage].append(float(val))

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