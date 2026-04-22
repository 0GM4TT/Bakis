#!/bin/bash
# =============================================================================
# show_cluster_info.sh
# Displays a quick overview of the cluster status and all access points.
# Run this from the jumphost at any time to see the current cluster state.
#
# Usage:
#   bash show_cluster_info.sh
# =============================================================================

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

MASTER_IP="192.168.1.155"

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

print_header() {
    echo ""
    echo -e "${BLUE}${BOLD}========================================${NC}"
    echo -e "${BLUE}${BOLD}  $1${NC}"
    echo -e "${BLUE}${BOLD}========================================${NC}"
}

print_row() {
    local label=$1
    local value=$2
    local status=$3
    printf "  %-20s %s" "$label" "$value"
    if [ -n "$status" ]; then
        echo -e "  $status"
    else
        echo ""
    fi
}

check_http() {
    local url=$1
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 2 "$url" 2>/dev/null)
    if [[ "$code" == "200" || "$code" == "302" ]]; then
        echo -e "${GREEN}UP${NC}"
    else
        echo -e "${RED}DOWN${NC}"
    fi
}

check_tcp() {
    local host=$1
    local port=$2
    if nc -z -w2 "$host" "$port" 2>/dev/null; then
        echo -e "${GREEN}UP${NC}"
    else
        echo -e "${RED}DOWN${NC}"
    fi
}

node_status() {
    local node=$1
    local status
    status=$(kubectl get node "$node" --no-headers 2>/dev/null | awk '{print $2}')
    if [ "$status" == "Ready" ]; then
        echo -e "${GREEN}Ready${NC}"
    elif [ -n "$status" ]; then
        echo -e "${RED}$status${NC}"
    else
        echo -e "${RED}Unreachable${NC}"
    fi
}

node_role() {
    local node=$1
    local roles
    roles=$(kubectl get node "$node" --no-headers 2>/dev/null | awk '{print $3}')
    if [ -z "$roles" ] || [ "$roles" == "<none>" ]; then
        echo "worker"
    else
        echo "$roles"
    fi
}

# =============================================================================
# MAIN
# =============================================================================

clear
echo ""
echo -e "${BOLD}${CYAN}"
echo "  ██████╗ ██╗      ██████╗██╗     ██╗   ██╗███████╗████████╗███████╗██████╗ "
echo "  ██╔════╝██║     ██╔════╝██║     ██║   ██║██╔════╝╚══██╔══╝██╔════╝██╔══██╗"
echo "  ██║     ██║     ██║     ██║     ██║   ██║███████╗   ██║   █████╗  ██████╔╝"
echo "  ██║     ██║     ██║     ██║     ██║   ██║╚════██║   ██║   ██╔══╝  ██╔══██╗"
echo "  ╚██████╗███████╗╚██████╗███████╗╚██████╔╝███████║   ██║   ███████╗██║  ██║"
echo "   ╚═════╝╚══════╝ ╚═════╝╚══════╝ ╚═════╝ ╚══════╝   ╚═╝   ╚══════╝╚═╝  ╚═╝"
echo -e "${NC}"
echo -e "  ${BOLD}ARM Microcluster — Status Dashboard${NC}"
echo -e "  $(date '+%Y-%m-%d %H:%M:%S')"

# =============================================================================
# NODE STATUS
# =============================================================================

print_header "NODE STATUS"

for node in k3s-master k3s-worker1 k3s-worker2; do
    # Get IP from hosts.ini equivalent
    case $node in
        k3s-master)  ip="192.168.1.155" ;;
        k3s-worker1) ip="192.168.1.160" ;;
        k3s-worker2) ip="192.168.1.103" ;;
    esac

    status=$(node_status "$node")
    role=$(node_role "$node")

    # Get CPU and RAM from node
    cpu=$(kubectl top node "$node" --no-headers 2>/dev/null | awk '{print $3}')
    ram=$(kubectl top node "$node" --no-headers 2>/dev/null | awk '{print $5}')

    printf "  %-15s %-18s %-12s" "$node" "$ip" "$role"
    echo -e "$status  CPU: ${cpu:-N/A}  RAM: ${ram:-N/A}"
done

# =============================================================================
# VM STATUS
# =============================================================================

print_header "VIRTUAL MACHINE STATUS"

vm_output=$(kubectl get vmi -o wide --no-headers 2>/dev/null)

if [ -z "$vm_output" ]; then
    echo -e "  ${RED}No VMs running${NC}"
else
    printf "  %-15s %-15s %-15s %-10s %-10s\n" "NAME" "NODE" "IP" "READY" "MIGRATABLE"
    echo "  ──────────────────────────────────────────────────────────────"
    while IFS= read -r line; do
        name=$(echo "$line" | awk '{print $1}')
        phase=$(echo "$line" | awk '{print $3}')
        ip=$(echo "$line" | awk '{print $4}')
        node=$(echo "$line" | awk '{print $5}')
        ready=$(echo "$line" | awk '{print $6}')
        migratable=$(echo "$line" | awk '{print $7}')

        if [ "$phase" == "Running" ]; then
            phase_color="${GREEN}Running${NC}"
        else
            phase_color="${YELLOW}$phase${NC}"
        fi

        if [ "$migratable" == "True" ]; then
            mig_color="${GREEN}True${NC}"
        else
            mig_color="${RED}False${NC}"
        fi

        printf "  %-15s %-15s %-15s %-10s " "$name" "$node" "$ip" "$ready"
        echo -e "$mig_color"
    done <<< "$vm_output"
fi

# =============================================================================
# WEB ACCESS POINTS
# =============================================================================

print_header "WEB ACCESS POINTS"

echo -e "  Open these URLs in your browser:\n"

# Grafana
status=$(check_http "http://$MASTER_IP:32000")
printf "  %-12s %s" "Grafana:" "http://$MASTER_IP:32000"
echo -e "    $status  (login: admin / your_password)"

# Longhorn
status=$(check_http "http://$MASTER_IP:30090")
printf "  %-12s %s" "Longhorn:" "http://$MASTER_IP:30090"
echo -e "    $status  (no login required)"

# Prometheus
status=$(check_http "http://$MASTER_IP:30091")
printf "  %-12s %s" "Prometheus:" "http://$MASTER_IP:30091"
echo -e "    $status  (no login required)"

# VM1 HTTP
status=$(check_http "http://$MASTER_IP:30011")
printf "  %-12s %s" "VM1 HTTP:" "http://$MASTER_IP:30011"
echo -e "    $status"

# VM2 HTTP
status=$(check_http "http://$MASTER_IP:30012")
printf "  %-12s %s" "VM2 HTTP:" "http://$MASTER_IP:30012"
echo -e "    $status"

# =============================================================================
# SSH ACCESS
# =============================================================================

print_header "SSH ACCESS"

echo -e "  Connect to VMs from this jumphost:\n"

# VM1 SSH
status=$(check_tcp "$MASTER_IP" 30001)
printf "  %-8s %s" "VM1:" "ssh -i ~/.ssh/ansible_id -p 30001 ubuntu@$MASTER_IP"
echo -e "    $status"

# VM2 SSH
status=$(check_tcp "$MASTER_IP" 30002)
printf "  %-8s %s" "VM2:" "ssh -i ~/.ssh/ansible_id -p 30002 ubuntu@$MASTER_IP"
echo -e "    $status"

echo ""
echo -e "  Connect to Pi nodes:\n"
printf "  %-12s %s\n" "Master:" "ssh bakalauras@192.168.1.155"
printf "  %-12s %s\n" "Worker1:" "ssh bakalauras@192.168.1.160"
printf "  %-12s %s\n" "Worker2:" "ssh bakalauras@192.168.1.103"

# =============================================================================
# STORAGE STATUS
# =============================================================================

print_header "STORAGE STATUS"

vol_output=$(kubectl get volumes.longhorn.io -n longhorn-system --no-headers 2>/dev/null)

if [ -z "$vol_output" ]; then
    echo -e "  ${RED}Longhorn not available${NC}"
else
    printf "  %-45s %-12s %-10s\n" "VOLUME" "STATE" "HEALTH"
    echo "  ──────────────────────────────────────────────────────────────"
    while IFS= read -r line; do
        name=$(echo "$line" | awk '{print $1}')
        state=$(echo "$line" | awk '{print $3}')
        health=$(echo "$line" | awk '{print $4}')
        size=$(echo "$line" | awk '{print $6}')

        # Shorten name for display
        short_name=$(echo "$name" | cut -c1-44)

        if [ "$health" == "healthy" ]; then
            health_color="${GREEN}healthy${NC}"
        else
            health_color="${RED}$health${NC}"
        fi

        printf "  %-45s %-12s " "$short_name" "$state"
        echo -e "$health_color"
    done <<< "$vol_output"
fi

# =============================================================================
# DISK USAGE
# =============================================================================

print_header "DISK USAGE ON PI NODES"

for node_info in "k3s-master:192.168.1.155" "k3s-worker1:192.168.1.160" "k3s-worker2:192.168.1.103"; do
    node_name="${node_info%%:*}"
    node_ip="${node_info#*:}"

    disk_info=$(ssh -i ~/.ssh/ansible_id -o ConnectTimeout=3 -o StrictHostKeyChecking=no \
        bakalauras@"$node_ip" "df -h / | tail -1" 2>/dev/null)

    if [ -n "$disk_info" ]; then
        used=$(echo "$disk_info" | awk '{print $3}')
        total=$(echo "$disk_info" | awk '{print $2}')
        pct=$(echo "$disk_info" | awk '{print $5}' | tr -d '%')

        # Color based on usage
        if [ "$pct" -ge 90 ]; then
            pct_color="${RED}${pct}%${NC}"
        elif [ "$pct" -ge 80 ]; then
            pct_color="${YELLOW}${pct}%${NC}"
        else
            pct_color="${GREEN}${pct}%${NC}"
        fi

        printf "  %-15s %s / %s used  " "$node_name" "$used" "$total"
        echo -e "$pct_color"
    else
        printf "  %-15s " "$node_name"
        echo -e "${RED}Unreachable${NC}"
    fi
done

# =============================================================================
# MONITORING PLACEMENT
# =============================================================================

print_header "COMPONENT PLACEMENT"

echo -e "  (Prometheus and Grafana must be on master for experiments)\n"

prom_node=$(kubectl get pod -n monitoring \
    -l app.kubernetes.io/name=prometheus \
    -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null)

grafana_node=$(kubectl get pod -n monitoring \
    -l app.kubernetes.io/name=grafana \
    -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null)

if [ "$prom_node" == "k3s-master" ]; then
    prom_status="${GREEN}k3s-master (correct)${NC}"
else
    prom_status="${RED}${prom_node:-unknown} (should be k3s-master!)${NC}"
fi

if [ "$grafana_node" == "k3s-master" ]; then
    grafana_status="${GREEN}k3s-master (correct)${NC}"
else
    grafana_status="${RED}${grafana_node:-unknown} (should be k3s-master!)${NC}"
fi

printf "  %-12s " "Prometheus:"
echo -e "$prom_status"

printf "  %-12s " "Grafana:"
echo -e "$grafana_status"

# Check for VMs on master
vms_on_master=$(kubectl get vmi -o wide --no-headers 2>/dev/null | \
    grep "k3s-master" | awk '{print $1}')

if [ -n "$vms_on_master" ]; then
    echo -e "\n  ${RED}WARNING: VMs running on k3s-master: $vms_on_master${NC}"
    echo -e "  ${RED}This will affect experiment results!${NC}"
else
    echo -e "\n  ${GREEN}No VMs on k3s-master (correct)${NC}"
fi

# =============================================================================
# QUICK COMMANDS
# =============================================================================

print_header "USEFUL COMMANDS"

echo "  Cluster health:"
echo "    kubectl get nodes"
echo "    kubectl get pods -A | grep -v Running"
echo ""
echo "  VM management:"
echo "    kubectl get vmi -o wide"
echo "    virtctl migrate ubuntu-vm-1"
echo "    virtctl console ubuntu-vm-1"
echo ""
echo "  Shutdown cluster gracefully:"
echo "    bash ~/pi-cluster-k3s/shutdown-cluster.sh"
echo ""
echo "  Run experiments:"
echo "    cd ~/pi-cluster-k3s/experiments/scenarios"
echo "    source ./00_common.sh && check_prerequisites && check_experiment_prerequisites"
echo ""

echo -e "${BLUE}${BOLD}========================================${NC}"
echo ""
