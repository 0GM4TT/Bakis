#!/bin/bash
# =============================================================================
# 00_common.sh
# Shared functions for all experiment scripts
# Source this file at the beginning of each experiment script:
#   source ./00_common.sh
# =============================================================================

# =============================================================================
# CONFIGURATION
# Edit these values to match your cluster setup
# =============================================================================

PROMETHEUS_URL="http://192.168.1.155:30091"
MASTER_IP="192.168.1.155"
WORKER1_IP="192.168.1.160"
WORKER2_IP="192.168.1.103"
MASTER_USER="bakalauras"
SSH_KEY="$HOME/.ssh/ansible_id"

# Hardcoded absolute results path — avoids all $() / BASH_SOURCE resolution issues
RESULTS_DIR="/home/augisugnius/Bakis/experiments/results"

# Node exporter instance labels (as seen in Prometheus)
MASTER_INSTANCE="192.168.1.155:9100"
WORKER1_INSTANCE="192.168.1.160:9100"
WORKER2_INSTANCE="192.168.1.103:9100"

# VM NodePort endpoints
VM1_HTTP="http://192.168.1.155:30011"
VM2_HTTP="http://192.168.1.155:30012"
VM1_SSH_PORT="30001"
VM2_SSH_PORT="30002"

# Colors for terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# =============================================================================
# LOGGING FUNCTIONS
# All write to stderr so they never pollute $() captures
# =============================================================================

log_info() {
    echo -e "${GREEN}[INFO]${NC} $(date '+%H:%M:%S') $1" >&2
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $(date '+%H:%M:%S') $1" >&2
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $(date '+%H:%M:%S') $1" >&2
}

log_step() {
    echo "" >&2
    echo -e "${BLUE}========================================${NC}" >&2
    echo -e "${BLUE} $1${NC}" >&2
    echo -e "${BLUE}========================================${NC}" >&2
}

# =============================================================================
# TIMESTAMP FUNCTIONS
# =============================================================================

now() {
    date +%s
}

now_human() {
    date '+%Y-%m-%d %H:%M:%S'
}

ts_to_human() {
    date -d "@$1" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -r "$1" '+%Y-%m-%d %H:%M:%S'
}

elapsed() {
    local start=$1
    local end=$2
    echo $((end - start))
}

# =============================================================================
# RESULTS DIRECTORY FUNCTIONS
# =============================================================================

init_results_dir() {
    local scenario_name=$1
    local timestamp
    timestamp=$(date '+%Y%m%d_%H%M%S')
    local dir="${RESULTS_DIR}/${scenario_name}_${timestamp}"
    mkdir -p "$dir" >&2 || true
    echo "$dir"
}

# =============================================================================
# PROMETHEUS QUERY FUNCTIONS
# =============================================================================

prom_query() {
    local query=$1
    local result
    result=$(curl -sf "${PROMETHEUS_URL}/api/v1/query" \
        --data-urlencode "query=${query}" \
        2>/dev/null | python3 -c "
import json, sys
data = json.load(sys.stdin)
results = data.get('data', {}).get('result', [])
if results:
    print(results[0]['value'][1])
else:
    print('N/A')
" 2>/dev/null)
    echo "${result:-N/A}"
}

prom_query_range() {
    local query=$1
    local start=$2
    local end=$3
    local step=${4:-15}
    curl -sf "${PROMETHEUS_URL}/api/v1/query_range" \
        --data-urlencode "query=${query}" \
        --data-urlencode "start=${start}" \
        --data-urlencode "end=${end}" \
        --data-urlencode "step=${step}s" \
        2>/dev/null
}

# =============================================================================
# METRICS SNAPSHOT FUNCTIONS
# =============================================================================

get_cpu_usage() {
    local instance=$1
    prom_query "100 - (avg(rate(node_cpu_seconds_total{mode='idle',instance='${instance}'}[1m])) * 100)"
}

get_ram_usage() {
    local instance=$1
    local total
    local available
    total=$(prom_query "node_memory_MemTotal_bytes{instance='${instance}'}")
    available=$(prom_query "node_memory_MemAvailable_bytes{instance='${instance}'}")
    if [[ "$total" != "N/A" && "$available" != "N/A" ]]; then
        python3 -c "print(round((1 - $available / $total) * 100, 1))"
    else
        echo "N/A"
    fi
}

get_net_rx() {
    local instance=$1
    local bytes
    bytes=$(prom_query "rate(node_network_receive_bytes_total{instance='${instance}',device='eth0'}[1m])")
    if [[ "$bytes" != "N/A" ]]; then
        python3 -c "print(round($bytes / 1024, 2))"
    else
        echo "N/A"
    fi
}

get_net_tx() {
    local instance=$1
    local bytes
    bytes=$(prom_query "rate(node_network_transmit_bytes_total{instance='${instance}',device='eth0'}[1m])")
    if [[ "$bytes" != "N/A" ]]; then
        python3 -c "print(round($bytes / 1024, 2))"
    else
        echo "N/A"
    fi
}

get_disk_read() {
    local instance=$1
    local bytes
    bytes=$(prom_query "rate(node_disk_read_bytes_total{instance='${instance}'}[1m])")
    if [[ "$bytes" != "N/A" ]]; then
        python3 -c "print(round($bytes / 1024, 2))"
    else
        echo "N/A"
    fi
}

get_disk_write() {
    local instance=$1
    local bytes
    bytes=$(prom_query "rate(node_disk_written_bytes_total{instance='${instance}'}[1m])")
    if [[ "$bytes" != "N/A" ]]; then
        python3 -c "print(round($bytes / 1024, 2))"
    else
        echo "N/A"
    fi
}

take_snapshot() {
    local label=$1
    local results_dir=$2
    local timestamp
    timestamp=$(now)
    local csv_file="$results_dir/metrics_snapshots.csv"

    if [ ! -f "$csv_file" ]; then
        echo "timestamp,label,node,cpu_pct,ram_pct,net_rx_kbs,net_tx_kbs,disk_read_kbs,disk_write_kbs" > "$csv_file"
    fi

    for node_info in "k3s-master:${MASTER_INSTANCE}" "k3s-worker1:${WORKER1_INSTANCE}" "k3s-worker2:${WORKER2_INSTANCE}"; do
        local node_name="${node_info%%:*}"
        local instance="${node_info#*:}"
        local cpu ram net_rx net_tx disk_r disk_w
        cpu=$(get_cpu_usage "$instance")
        ram=$(get_ram_usage "$instance")
        net_rx=$(get_net_rx "$instance")
        net_tx=$(get_net_tx "$instance")
        disk_r=$(get_disk_read "$instance")
        disk_w=$(get_disk_write "$instance")
        echo "$timestamp,$label,$node_name,$cpu,$ram,$net_rx,$net_tx,$disk_r,$disk_w" >> "$csv_file"
    done

    log_info "Snapshot taken: $label"
}

# =============================================================================
# CONTINUOUS METRICS COLLECTION
# Uses temp file for PID — avoids $() subshell hang
# =============================================================================

start_metrics_collection() {
    local results_dir=$1
    local interval=${2:-5}
    local pid_file="/tmp/metrics_collection_$$.pid"

    (
        while true; do
            take_snapshot "running" "$results_dir" || true
            sleep "$interval"
        done
    ) &

    echo $! > "$pid_file"
    echo $!
}

stop_metrics_collection() {
    local pid=$1
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
}

# =============================================================================
# HTTP AVAILABILITY MONITORING
# =============================================================================

start_http_monitor() {
    local url=$1
    local results_dir=$2
    local log_file="$results_dir/http_monitor_$(echo "$url" | sed 's/[^0-9]/_/g').csv"

    echo "timestamp,status,response_time_ms" > "$log_file"

    (
        while true; do
            local start_ms
            start_ms=$(date +%s%3N)
            local http_code
            http_code=$(curl -s -o /dev/null -w "%{http_code}" \
                --connect-timeout 2 --max-time 3 "$url" 2>/dev/null) || http_code="000"
            local end_ms
            end_ms=$(date +%s%3N)
            local response_time=$((end_ms - start_ms))
            if [[ "$http_code" == "200" ]]; then
                echo "$(now),OK,$response_time" >> "$log_file"
            else
                echo "$(now),FAIL_${http_code},$response_time" >> "$log_file"
            fi
            sleep 1
        done
    ) &

    echo $!
}

stop_http_monitor() {
    local pid=$1
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
}

# =============================================================================
# CLUSTER STATE FUNCTIONS
# =============================================================================

wait_for_nodes_ready() {
    local timeout=${1:-300}
    local start
    start=$(now)
    log_info "Waiting for all nodes to be Ready (timeout: ${timeout}s)..."

    while true; do
        local not_ready
        not_ready=$(kubectl get nodes --no-headers 2>/dev/null | grep -v " Ready" | wc -l) || not_ready=99
        if [ "$not_ready" -eq 0 ]; then
            local elapsed=$(($(now) - start))
            log_info "All nodes Ready after ${elapsed}s"
            return 0
        fi
        if [ $(($(now) - start)) -gt "$timeout" ]; then
            log_error "Timeout waiting for nodes to be Ready"
            return 1
        fi
        sleep 5
    done
}

wait_for_vm_ready() {
    local vm_name=$1
    local timeout=${2:-300}
    local start
    start=$(now)
    log_info "Waiting for VM ${vm_name} to be Running (timeout: ${timeout}s)..."

    while true; do
        local phase
        phase=$(kubectl get vmi "$vm_name" -o jsonpath='{.status.phase}' 2>/dev/null) || phase=""
        if [ "$phase" == "Running" ]; then
            local elapsed=$(($(now) - start))
            log_info "VM ${vm_name} Running after ${elapsed}s"
            echo "$elapsed"
            return 0
        fi
        if [ $(($(now) - start)) -gt "$timeout" ]; then
            log_error "Timeout waiting for VM ${vm_name}"
            echo "-1"
            return 1
        fi
        sleep 5
    done
}

get_vm_node() {
    local vm_name=$1
    kubectl get vmi "$vm_name" -o jsonpath='{.status.nodeName}' 2>/dev/null
}

wait_for_migration() {
    local vm_name=$1
    local original_node=$2
    local timeout=${3:-300}
    local start
    start=$(now)
    log_info "Waiting for ${vm_name} to migrate away from ${original_node}..."

    while true; do
        local current_node
        current_node=$(get_vm_node "$vm_name") || current_node=""
        if [ "$current_node" != "$original_node" ] && [ -n "$current_node" ]; then
            local elapsed=$(($(now) - start))
            log_info "Migration completed after ${elapsed}s → now on ${current_node}"
            echo "$elapsed"
            return 0
        fi
        if [ $(($(now) - start)) -gt "$timeout" ]; then
            log_error "Timeout waiting for migration of ${vm_name}"
            echo "-1"
            return 1
        fi
        sleep 2
    done
}

# =============================================================================
# STRESS LOAD FUNCTIONS
# =============================================================================

start_vm_load() {
    local vm_name=$1
    local ssh_port=$2
    log_info "Starting stress load inside ${vm_name}..."
    ssh -i "$SSH_KEY" -p "$ssh_port" \
        -o StrictHostKeyChecking=no \
        ubuntu@"$MASTER_IP" \
        "nohup stress-ng --cpu 1 --vm 1 --vm-bytes 200M --timeout 0 > /dev/null 2>&1 &" || true
    log_info "Load started on ${vm_name}"
}

stop_vm_load() {
    local vm_name=$1
    local ssh_port=$2
    log_info "Stopping stress load inside ${vm_name}..."
    ssh -i "$SSH_KEY" -p "$ssh_port" \
        -o StrictHostKeyChecking=no \
        ubuntu@"$MASTER_IP" \
        "sudo pkill stress-ng 2>/dev/null || true" || true
    log_info "Load stopped on ${vm_name}"
}

install_stress_ng() {
    local ssh_port=$1
    log_info "Installing stress-ng inside VM (port ${ssh_port})..."
    ssh -i "$SSH_KEY" -p "$ssh_port" \
        -o StrictHostKeyChecking=no \
        ubuntu@"$MASTER_IP" \
        "sudo apt-get install -y stress-ng -q" || true
    log_info "stress-ng installed"
}

# =============================================================================
# RESULTS EXPORT FUNCTIONS
# =============================================================================

export_metrics_to_csv() {
    local query=$1
    local start=$2
    local end=$3
    local step=${4:-15}
    local output_file=$5
    local label=${6:-"value"}

    log_info "Exporting metrics to $output_file..."

    prom_query_range "$query" "$start" "$end" "$step" | python3 -c "
import json, sys, csv

label = '${label}'
data = json.load(sys.stdin)
results = data.get('data', {}).get('result', [])

with open('${output_file}', 'w', newline='') as f:
    writer = csv.writer(f)
    writer.writerow(['timestamp', 'datetime', label])
    for series in results:
        for ts, val in series.get('values', []):
            from datetime import datetime
            dt = datetime.fromtimestamp(float(ts)).strftime('%Y-%m-%d %H:%M:%S')
            writer.writerow([ts, dt, val])

print(f'Exported data points')
" 2>/dev/null || true
}

record_timing() {
    local results_dir=$1
    local label=$2
    local seconds=$3
    local summary_file="$results_dir/timing_summary.csv"

    if [ ! -f "$summary_file" ]; then
        echo "label,seconds,datetime" > "$summary_file"
    fi

    echo "$label,$seconds,$(now_human)" >> "$summary_file"
    log_info "Recorded: $label = ${seconds}s"
}

print_timing_summary() {
    local results_dir=$1
    local summary_file="$results_dir/timing_summary.csv"

    if [ -f "$summary_file" ]; then
        echo "" >&2
        log_step "TIMING SUMMARY"
        column -t -s',' "$summary_file" >&2
        echo "" >&2
    fi
}

# =============================================================================
# PREREQUISITE CHECKS
# =============================================================================

check_prerequisites() {
    log_step "Checking prerequisites"
    local ok=true

    if ! command -v kubectl &>/dev/null; then
        log_error "kubectl not found"
        ok=false
    else
        log_info "kubectl ✓"
    fi

    if ! command -v virtctl &>/dev/null; then
        log_error "virtctl not found"
        ok=false
    else
        log_info "virtctl ✓"
    fi

    if ! kubectl get nodes &>/dev/null; then
        log_error "Cannot connect to Kubernetes cluster"
        ok=false
    else
        log_info "Cluster connectivity ✓"
    fi

    if ! curl -sf "${PROMETHEUS_URL}/-/healthy" &>/dev/null; then
        log_warn "Prometheus not reachable at ${PROMETHEUS_URL}"
    else
        log_info "Prometheus ✓"
    fi

    if [ ! -f "$SSH_KEY" ]; then
        log_error "SSH key not found at $SSH_KEY"
        ok=false
    else
        log_info "SSH key ✓"
    fi

    mkdir -p "$RESULTS_DIR" || true
    log_info "Results directory: $RESULTS_DIR ✓"

    if [ "$ok" = false ]; then
        log_error "Prerequisites check failed. Fix the above errors and retry."
        exit 1
    fi

    log_info "All prerequisites satisfied"
}

check_experiment_prerequisites() {
    log_step "Checking experiment prerequisites"
    local ok=true

    local prom_node
    prom_node=$(kubectl get pod -n monitoring \
        -l app.kubernetes.io/name=prometheus \
        -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null) || prom_node=""

    if [ "$prom_node" != "k3s-master" ]; then
        log_error "Prometheus is on ${prom_node:-unknown} — must be on k3s-master!"
        ok=false
    else
        log_info "Prometheus on k3s-master ✓"
    fi

    local grafana_node
    grafana_node=$(kubectl get pod -n monitoring \
        -l app.kubernetes.io/name=grafana \
        -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null) || grafana_node=""

    if [ "$grafana_node" != "k3s-master" ]; then
        log_error "Grafana is on ${grafana_node:-unknown} — must be on k3s-master!"
        ok=false
    else
        log_info "Grafana on k3s-master ✓"
    fi

    local vms_on_master
    vms_on_master=$(kubectl get vmi -o wide --no-headers 2>/dev/null | \
        grep "k3s-master" | awk '{print $1}') || vms_on_master=""

    if [ -n "$vms_on_master" ]; then
        log_error "VMs running on k3s-master: $vms_on_master"
        ok=false
    else
        log_info "No VMs on k3s-master ✓"
    fi

    # Check no nodes are cordoned
    local cordoned
    cordoned=$(kubectl get nodes --no-headers 2>/dev/null | grep "SchedulingDisabled" | awk '{print $1}') || cordoned=""
    if [ -n "$cordoned" ]; then
        log_error "Cordoned nodes detected: $cordoned"
        log_error "Run: kubectl uncordon $cordoned"
        ok=false
    else
        log_info "No cordoned nodes ✓"
    fi

    if [ "$ok" = false ]; then
        log_error "Experiment prerequisites failed. Fix above issues before running."
        exit 1
    fi

    log_info "All experiment prerequisites satisfied ✓"
}
