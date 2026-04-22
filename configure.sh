#!/bin/bash
# =============================================================================
# configure.sh
# One-time configuration script for the ARM Microcluster project.
# Updates all hardcoded IPs, usernames, SSH keys and passwords across
# all configuration files in the repository.
#
# Run this ONCE after cloning the repository and before running any playbooks.
# Run it again if you need to change any settings.
#
# USAGE:
#   bash configure.sh [OPTIONS]
#
# OPTIONS:
#   --master-ip       IP address for k3s-master        (default: 192.168.50.200)
#   --worker1-ip      IP address for k3s-worker1       (default: 192.168.50.201)
#   --worker2-ip      IP address for k3s-worker2       (default: 192.168.50.202)
#   --username        Pi OS username                    (default: msm)
#   --ssh-key         Ansible SSH public key            (from ~/.ssh/ansible_id.pub)
#   --grafana-pass    Grafana admin password            (default: admin123)
#   --dry-run         Show what would be changed without making changes
#
# EXAMPLES:
#   # Interactive mode (prompts for each value):
#   bash configure.sh
#
#   # Non-interactive with all options:
#   bash configure.sh \
#     --master-ip 192.168.1.100 \
#     --worker1-ip 192.168.1.101 \
#     --worker2-ip 192.168.1.102 \
#     --username pi \
#     --ssh-key "$(cat ~/.ssh/ansible_id.pub)" \
#     --grafana-pass mysecretpassword
#
#   # Dry run - see what would change without modifying files:
#   bash configure.sh --dry-run
#
# FILES UPDATED:
#   inventory/hosts.ini
#   ansible.cfg
#   setup-jumphost.sh
#   experiments/scenarios/00_common.sh
#   manifests/monitoring/grafana-dashboard-configmap.yaml
#   manifests/vms/ubuntu-vm-1.yaml
#   manifests/vms/ubuntu-vm-2.yaml
#   playbooks/04_monitoring.yml
# =============================================================================
 
set -e
 
# =============================================================================
# DEFAULTS
# =============================================================================
DEFAULT_MASTER_IP="192.168.50.200"
DEFAULT_WORKER1_IP="192.168.50.201"
DEFAULT_WORKER2_IP="192.168.50.202"
DEFAULT_USERNAME="msm"
DEFAULT_GRAFANA_PASS="admin123"
 
# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'
 
# =============================================================================
# ARGUMENT PARSING
# =============================================================================
MASTER_IP=""
WORKER1_IP=""
WORKER2_IP=""
USERNAME=""
SSH_KEY=""
GRAFANA_PASS=""
DRY_RUN=false
 
while [[ $# -gt 0 ]]; do
    case $1 in
        --master-ip)   MASTER_IP="$2";   shift 2 ;;
        --worker1-ip)  WORKER1_IP="$2";  shift 2 ;;
        --worker2-ip)  WORKER2_IP="$2";  shift 2 ;;
        --username)    USERNAME="$2";    shift 2 ;;
        --ssh-key)     SSH_KEY="$2";     shift 2 ;;
        --grafana-pass) GRAFANA_PASS="$2"; shift 2 ;;
        --dry-run)     DRY_RUN=true;     shift ;;
        --help|-h)
            head -50 "$0" | grep "^#" | sed 's/^# \?//'
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            echo "Run 'bash configure.sh --help' for usage."
            exit 1
            ;;
    esac
done
 
# =============================================================================
# HELPERS
# =============================================================================
 
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHANGED_FILES=()
 
log_info() { echo -e "${GREEN}[INFO]${NC}  $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_step() {
    echo ""
    echo -e "${BLUE}${BOLD}── $1 ${NC}"
}
 
validate_ip() {
    local ip=$1
    if [[ ! $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        echo -e "${RED}Invalid IP address: $ip${NC}"
        return 1
    fi
}
 
# Replace a pattern in a file
replace_in_file() {
    local file="$SCRIPT_DIR/$1"
    local old="$2"
    local new="$3"
    local description="$4"
 
    if [ ! -f "$file" ]; then
        log_warn "File not found: $1 — skipping"
        return 0
    fi
 
    if grep -qF "$old" "$file" 2>/dev/null; then
        if [ "$DRY_RUN" = true ]; then
            echo -e "  ${CYAN}[DRY RUN]${NC} $1: '$old' → '$new'"
        else
            # Use Python for safe replacement (handles special chars in SSH keys)
            python3 -c "
import sys
with open('$file', 'r') as f:
    content = f.read()
old = sys.stdin.read()
new = '''$new'''
content = content.replace(old, new)
with open('$file', 'w') as f:
    f.write(content)
" <<< "$old"
            # Track changed files
            if [[ ! " ${CHANGED_FILES[@]} " =~ " $1 " ]]; then
                CHANGED_FILES+=("$1")
            fi
        fi
        log_info "${description:-Updated $1}"
    fi
}
 
# Replace using sed (for simple patterns without special chars)
sed_replace() {
    local file="$SCRIPT_DIR/$1"
    local pattern="$2"
    local replacement="$3"
    local description="$4"
 
    if [ ! -f "$file" ]; then
        log_warn "File not found: $1 — skipping"
        return 0
    fi
 
    if grep -qE "$pattern" "$file" 2>/dev/null; then
        if [ "$DRY_RUN" = true ]; then
            echo -e "  ${CYAN}[DRY RUN]${NC} $1: pattern '$pattern' → '$replacement'"
        else
            sed -i "s|$pattern|$replacement|g" "$file"
            if [[ ! " ${CHANGED_FILES[@]} " =~ " $1 " ]]; then
                CHANGED_FILES+=("$1")
            fi
        fi
        log_info "${description:-Updated $1}"
    fi
}
 
# =============================================================================
# INTERACTIVE MODE
# =============================================================================
 
prompt_value() {
    local var_name=$1
    local prompt=$2
    local default=$3
    local current="${!var_name}"
 
    if [ -z "$current" ]; then
        echo -en "${CYAN}$prompt${NC} [${YELLOW}$default${NC}]: "
        read -r input
        if [ -z "$input" ]; then
            eval "$var_name='$default'"
        else
            eval "$var_name='$input'"
        fi
    fi
}
 
# =============================================================================
# MAIN
# =============================================================================
 
clear
echo ""
echo -e "${BOLD}${CYAN}ARM Microcluster — Configuration Setup${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "This script updates all configuration files in the repository"
echo "with your network settings, username, SSH key and passwords."
echo ""
 
if [ "$DRY_RUN" = true ]; then
    echo -e "${YELLOW}DRY RUN MODE — no files will be modified${NC}"
    echo ""
fi
 
# Collect values interactively if not provided via arguments
log_step "Network Configuration"
echo "  These must match the static IPs you assigned to your Pi nodes."
echo "  See docs/setup.md Section 5 for how to set static IPs."
echo ""
 
prompt_value MASTER_IP  "  k3s-master IP " "$DEFAULT_MASTER_IP"
validate_ip "$MASTER_IP" || exit 1
 
prompt_value WORKER1_IP "  k3s-worker1 IP" "$DEFAULT_WORKER1_IP"
validate_ip "$WORKER1_IP" || exit 1
 
prompt_value WORKER2_IP "  k3s-worker2 IP" "$DEFAULT_WORKER2_IP"
validate_ip "$WORKER2_IP" || exit 1
 
log_step "Pi Username"
echo "  The username you chose when flashing the SD cards."
echo "  Must be the same on all three Pi nodes."
echo ""
prompt_value USERNAME "  Pi username" "$DEFAULT_USERNAME"
 
log_step "SSH Public Key"
echo "  The public key from ~/.ssh/ansible_id on your jumphost."
echo "  Run: cat ~/.ssh/ansible_id.pub"
echo "  This key is injected into VMs to allow SSH access."
echo ""
 
if [ -z "$SSH_KEY" ]; then
    # Try to auto-detect from jumphost
    if [ -f "$HOME/.ssh/ansible_id.pub" ]; then
        DETECTED_KEY=$(cat "$HOME/.ssh/ansible_id.pub")
        echo -e "  ${GREEN}Detected key at ~/.ssh/ansible_id.pub${NC}"
        echo -e "  ${YELLOW}Key:${NC} ${DETECTED_KEY:0:60}..."
        echo -en "  Use this key? [Y/n]: "
        read -r use_detected
        if [[ "$use_detected" =~ ^[Nn]$ ]]; then
            echo -en "  Paste your SSH public key: "
            read -r SSH_KEY
        else
            SSH_KEY="$DETECTED_KEY"
        fi
    else
        echo -e "  ${YELLOW}No key found at ~/.ssh/ansible_id.pub${NC}"
        echo "  Run setup-jumphost.sh first to generate the key, then run configure.sh again."
        echo -en "  Or paste your SSH public key now (leave blank to skip): "
        read -r SSH_KEY
    fi
fi
 
log_step "Grafana Password"
echo "  Password for the Grafana admin user."
echo "  You will use this to log into http://${MASTER_IP}:32000"
echo ""
prompt_value GRAFANA_PASS "  Grafana password" "$DEFAULT_GRAFANA_PASS"
 
# Show summary
echo ""
echo -e "${BLUE}${BOLD}── Summary of changes ──${NC}"
echo ""
printf "  %-20s %s\n" "k3s-master IP:"  "$MASTER_IP"
printf "  %-20s %s\n" "k3s-worker1 IP:" "$WORKER1_IP"
printf "  %-20s %s\n" "k3s-worker2 IP:" "$WORKER2_IP"
printf "  %-20s %s\n" "Pi username:"    "$USERNAME"
printf "  %-20s %s\n" "Grafana password:" "$GRAFANA_PASS"
if [ -n "$SSH_KEY" ]; then
    printf "  %-20s %s...\n" "SSH key:" "${SSH_KEY:0:50}"
else
    printf "  %-20s %s\n" "SSH key:" "(skipped)"
fi
echo ""
 
if [ "$DRY_RUN" = false ]; then
    echo -en "${YELLOW}Apply these changes? [Y/n]: ${NC}"
    read -r confirm
    if [[ "$confirm" =~ ^[Nn]$ ]]; then
        echo "Cancelled."
        exit 0
    fi
fi
 
echo ""
log_step "Updating inventory/hosts.ini"
 
sed_replace "inventory/hosts.ini" \
    "ansible_host=${DEFAULT_MASTER_IP}" \
    "ansible_host=${MASTER_IP}" \
    "Updated master IP"
 
sed_replace "inventory/hosts.ini" \
    "ansible_host=${DEFAULT_WORKER1_IP}" \
    "ansible_host=${WORKER1_IP}" \
    "Updated worker1 IP"
 
sed_replace "inventory/hosts.ini" \
    "ansible_host=${DEFAULT_WORKER2_IP}" \
    "ansible_host=${WORKER2_IP}" \
    "Updated worker2 IP"
 
sed_replace "inventory/hosts.ini" \
    "ansible_user=${DEFAULT_USERNAME}" \
    "ansible_user=${USERNAME}" \
    "Updated ansible username"
 
log_step "Updating ansible.cfg"
 
sed_replace "ansible.cfg" \
    "remote_user = ${DEFAULT_USERNAME}" \
    "remote_user = ${USERNAME}" \
    "Updated remote_user"
 
log_step "Updating setup-jumphost.sh"
 
sed_replace "setup-jumphost.sh" \
    "${DEFAULT_MASTER_IP} k3s-master" \
    "${MASTER_IP} k3s-master" \
    "Updated master IP in /etc/hosts section"
 
sed_replace "setup-jumphost.sh" \
    "${DEFAULT_WORKER1_IP} k3s-worker1" \
    "${WORKER1_IP} k3s-worker1" \
    "Updated worker1 IP in /etc/hosts section"
 
sed_replace "setup-jumphost.sh" \
    "${DEFAULT_WORKER2_IP} k3s-worker2" \
    "${WORKER2_IP} k3s-worker2" \
    "Updated worker2 IP in /etc/hosts section"
 
log_step "Updating experiments/scenarios/00_common.sh"
 
sed_replace "experiments/scenarios/00_common.sh" \
    "MASTER_IP=\"${DEFAULT_MASTER_IP}\"" \
    "MASTER_IP=\"${MASTER_IP}\"" \
    "Updated MASTER_IP"
 
sed_replace "experiments/scenarios/00_common.sh" \
    "WORKER1_IP=\"${DEFAULT_WORKER1_IP}\"" \
    "WORKER1_IP=\"${WORKER1_IP}\"" \
    "Updated WORKER1_IP"
 
sed_replace "experiments/scenarios/00_common.sh" \
    "WORKER2_IP=\"${DEFAULT_WORKER2_IP}\"" \
    "WORKER2_IP=\"${WORKER2_IP}\"" \
    "Updated WORKER2_IP"
 
sed_replace "experiments/scenarios/00_common.sh" \
    "MASTER_INSTANCE=\"${DEFAULT_MASTER_IP}:9100\"" \
    "MASTER_INSTANCE=\"${MASTER_IP}:9100\"" \
    "Updated MASTER_INSTANCE"
 
sed_replace "experiments/scenarios/00_common.sh" \
    "WORKER1_INSTANCE=\"${DEFAULT_WORKER1_IP}:9100\"" \
    "WORKER1_INSTANCE=\"${WORKER1_IP}:9100\"" \
    "Updated WORKER1_INSTANCE"
 
sed_replace "experiments/scenarios/00_common.sh" \
    "WORKER2_INSTANCE=\"${DEFAULT_WORKER2_IP}:9100\"" \
    "WORKER2_INSTANCE=\"${WORKER2_IP}:9100\"" \
    "Updated WORKER2_INSTANCE"
 
log_step "Updating show_cluster_info.sh"
 
sed_replace "show_cluster_info.sh" \
    "MASTER_IP=\"${DEFAULT_MASTER_IP}\"" \
    "MASTER_IP=\"${MASTER_IP}\"" \
    "Updated MASTER_IP"
 
sed_replace "show_cluster_info.sh" \
    "\"192.168.50.200\"" \
    "\"${MASTER_IP}\"" \
    "Updated master IP references"
 
sed_replace "show_cluster_info.sh" \
    "\"192.168.50.201\"" \
    "\"${WORKER1_IP}\"" \
    "Updated worker1 IP references"
 
sed_replace "show_cluster_info.sh" \
    "\"192.168.50.202\"" \
    "\"${WORKER2_IP}\"" \
    "Updated worker2 IP references"
 
sed_replace "show_cluster_info.sh" \
    "msm@" \
    "${USERNAME}@" \
    "Updated SSH username"
 
log_step "Updating playbooks/04_monitoring.yml"
 
sed_replace "playbooks/04_monitoring.yml" \
    "grafana_password: \"${DEFAULT_GRAFANA_PASS}\"" \
    "grafana_password: \"${GRAFANA_PASS}\"" \
    "Updated Grafana password"
 
log_step "Updating manifests/monitoring/grafana-dashboard-configmap.yaml"
 
sed_replace "manifests/monitoring/grafana-dashboard-configmap.yaml" \
    "${DEFAULT_MASTER_IP}:9100" \
    "${MASTER_IP}:9100" \
    "Updated master node_exporter endpoint"
 
sed_replace "manifests/monitoring/grafana-dashboard-configmap.yaml" \
    "${DEFAULT_WORKER1_IP}:9100" \
    "${WORKER1_IP}:9100" \
    "Updated worker1 node_exporter endpoint"
 
sed_replace "manifests/monitoring/grafana-dashboard-configmap.yaml" \
    "${DEFAULT_WORKER2_IP}:9100" \
    "${WORKER2_IP}:9100" \
    "Updated worker2 node_exporter endpoint"
 
sed_replace "manifests/monitoring/grafana-dashboard-configmap.yaml" \
    "'${DEFAULT_MASTER_IP}'" \
    "'${MASTER_IP}'" \
    "Updated master IP in dashboard queries"
 
sed_replace "manifests/monitoring/grafana-dashboard-configmap.yaml" \
    "'${DEFAULT_WORKER1_IP}'" \
    "'${WORKER1_IP}'" \
    "Updated worker1 IP in dashboard queries"
 
sed_replace "manifests/monitoring/grafana-dashboard-configmap.yaml" \
    "'${DEFAULT_WORKER2_IP}'" \
    "'${WORKER2_IP}'" \
    "Updated worker2 IP in dashboard queries"
 
sed_replace "manifests/monitoring/grafana-dashboard-configmap.yaml" \
    "http://${DEFAULT_MASTER_IP}:" \
    "http://${MASTER_IP}:" \
    "Updated Prometheus URL in dashboard"
 
log_step "Updating VM manifests with SSH key"
 
if [ -n "$SSH_KEY" ]; then
    for vm_file in "manifests/vms/ubuntu-vm-1.yaml" "manifests/vms/ubuntu-vm-2.yaml"; do
        full_path="$SCRIPT_DIR/$vm_file"
        if [ -f "$full_path" ]; then
            if [ "$DRY_RUN" = true ]; then
                echo -e "  ${CYAN}[DRY RUN]${NC} $vm_file: Replace SSH key"
            else
                # Use Python for safe SSH key replacement
                python3 << PYEOF
import re
 
with open('$full_path', 'r') as f:
    content = f.read()
 
# Replace any existing ssh-rsa key line
new_key_line = '                - $SSH_KEY'
content = re.sub(
    r'                - ssh-rsa [A-Za-z0-9+/=]+ \S+',
    new_key_line,
    content
)
 
with open('$full_path', 'w') as f:
    f.write(content)
PYEOF
                if [[ ! " ${CHANGED_FILES[@]} " =~ " $vm_file " ]]; then
                    CHANGED_FILES+=("$vm_file")
                fi
                log_info "Updated SSH key in $vm_file"
            fi
        fi
    done
else
    log_warn "SSH key not provided — VM manifests not updated"
    log_warn "Run: bash configure.sh --ssh-key \"\$(cat ~/.ssh/ansible_id.pub)\""
fi
 
# =============================================================================
# SUMMARY
# =============================================================================
 
echo ""
echo -e "${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
 
if [ "$DRY_RUN" = true ]; then
    echo -e "${YELLOW}DRY RUN complete — no files were modified${NC}"
else
    echo -e "${GREEN}${BOLD}Configuration complete!${NC}"
    echo ""
    if [ ${#CHANGED_FILES[@]} -gt 0 ]; then
        echo "Files updated:"
        for f in "${CHANGED_FILES[@]}"; do
            echo -e "  ${GREEN}✓${NC} $f"
        done
    fi
 
    echo ""
    echo -e "${BOLD}Next steps:${NC}"
    echo "  1. Commit and push changes:"
    echo "     git add ."
    echo "     git commit -m \"config: update IPs, username and SSH key for my setup\""
    echo "     git push"
    echo ""
    echo "  2. Pull on jumphost:"
    echo "     git pull"
    echo ""
    echo "  3. Run the playbooks:"
    echo "     ansible-playbook playbooks/00_bootstrap.yml --ask-pass --ask-become-pass"
    echo "     ansible-playbook playbooks/01_k3s.yml"
    echo "     ansible-playbook playbooks/02_kubevirt.yml"
    echo "     ansible-playbook playbooks/03_longhorn.yml"
    echo "     ansible-playbook playbooks/04_monitoring.yml"
    echo "     ansible-playbook playbooks/05_vm_setup.yml"
    echo ""
    echo "  4. Verify cluster:"
    echo "     bash show_cluster_info.sh"
fi
 
echo -e "${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""