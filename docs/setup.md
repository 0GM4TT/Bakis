# ARM Microcluster Setup Guide

*From freshly-flashed SD cards to a fully running 3-node k3s cluster with KubeVirt, Longhorn, and monitoring.*

This guide is written for someone with basic computer knowledge who has never worked with Kubernetes or Linux clusters before. Every command is explained. Every step is numbered. Nothing is assumed.

---

## Table of Contents

1. [Hardware Requirements](#1-hardware-requirements)
2. [Software Requirements](#2-software-requirements)
3. [Before You Start — Things to Customize](#3-before-you-start--things-to-customize)
4. [Step 1 — Flash SD Cards](#4-step-1--flash-sd-cards)
5. [Step 2 — First Boot and Static IP Setup](#5-step-2--first-boot-and-static-ip-setup)
6. [Step 3 — Set Up the CentOS Jumphost VM](#6-step-3--set-up-the-centos-jumphost-vm)
7. [Step 4 — Clone the Repository and Configure](#7-step-4--clone-the-repository-and-configure)
8. [Step 5 — Run the Setup Script](#8-step-5--run-the-setup-script)
9. [Step 6 — Update SSH Key in VM Manifests](#9-step-6--update-ssh-key-in-vm-manifests)
10. [Step 7 — Run the Playbooks](#10-step-7--run-the-playbooks)
11. [Step 8 — Verify Everything Works](#11-step-8--verify-everything-works)
12. [Access Points Reference](#12-access-points-reference)
13. [Daily Operations](#13-daily-operations)
14. [Known Limitations](#14-known-limitations)
15. [Troubleshooting](#15-troubleshooting)

---

## 1. Hardware Requirements

| Item | Quantity | Notes |
|------|----------|-------|
| Raspberry Pi 5 (4GB RAM) | 3 | Pi 4 works but Pi 5 is recommended |
| MicroSD cards (128GB+) | 3 | Use fast cards — SanDisk Extreme or equivalent |
| USB-C power supplies | 3 | Official Raspberry Pi power supplies recommended |
| Ethernet cables | 3 | Standard Cat5e or better |
| Network switch or router | 1 | Must have at least 4 free ports |
| PC with virtualization software | 1 | VMware Workstation, VirtualBox, or similar |
| CentOS Stream 10 ISO | 1 | Download from https://centos.org/download/ |

> **What is a jumphost?** The jumphost is a Linux virtual machine running on your PC. It acts as the control center — all automation scripts run from this machine and connect to the Pi nodes over your local network. Your PC itself is not used directly for cluster management.

---

## 2. Software Requirements

### On your PC (before starting)
- **Raspberry Pi Imager** — https://www.raspberrypi.com/software/
- **Virtualization software** — VMware Workstation (recommended) or VirtualBox
- **CentOS Stream 10 ISO** — https://centos.org/download/
- **VS Code** — https://code.visualstudio.com
- **Git** — https://git-scm.com
- **A GitHub account** — free at https://github.com

### On the jumphost (installed automatically)
Everything on the jumphost is installed by the `setup-jumphost.sh` script. You do not need to install anything manually.

---

## 3. Before You Start — Things to Customize

Several files in this repository contain hardcoded IP addresses, usernames, passwords and SSH keys that must match your specific setup. The repository includes `configure.sh` — a script that updates all of them in one command.

> **Recommended approach:** Run `configure.sh` after Step 5 (setup-jumphost.sh). It handles all files automatically including the Grafana dashboard ConfigMap which contains many hardcoded IPs.

### 3.1 — Your Network's IP Range

This guide uses `192.168.50.x` as the example network. Your home network may use a different range such as `192.168.1.x` or `10.0.0.x`.

**How to find your network range:**
```bash
# Windows
ipconfig | findstr "Default Gateway"

# Linux/Mac
ip route | grep default
```

The Pi nodes will be assigned these static IPs (adjust the first three numbers to match your network):
- `k3s-master` → `192.168.1.155`
- `k3s-worker1` → `192.168.1.160`
- `k3s-worker2` → `192.168.1.103`

These high numbers are chosen deliberately to avoid the router's DHCP pool.

### 3.2 — Using configure.sh (Recommended)

After running `setup-jumphost.sh` in Step 5, your SSH key exists and you can run `configure.sh` to update every configuration file at once:

```bash
# Interactive mode — prompts for each value with defaults shown:
bash configure.sh

# Non-interactive — all values via arguments:
bash configure.sh \
  --master-ip 192.168.1.155 \
  --worker1-ip 192.168.1.160 \
  --worker2-ip 192.168.1.103 \
  --username pi \
  --ssh-key "$(cat ~/.ssh/ansible_id.pub)" \
  --grafana-pass mysecretpassword

# Dry run — see what would change without modifying anything:
bash configure.sh --dry-run
```

**Files updated automatically by `configure.sh`:**

| File | What changes |
|------|-------------|
| `inventory/hosts.ini` | Pi IPs and username |
| `ansible.cfg` | Pi username |
| `setup-jumphost.sh` | Pi IPs in /etc/hosts section |
| `experiments/scenarios/00_common.sh` | Pi IPs and node_exporter endpoints |
| `show_cluster_info.sh` | Pi IPs and SSH username |
| `manifests/monitoring/grafana-dashboard-configmap.yaml` | All hardcoded Pi IPs in dashboard queries |
| `manifests/vms/webserver.py` | Prometheus URL inside VM web server |
| `manifests/vms/ubuntu-vm-1.yaml` | SSH public key |
| `manifests/vms/ubuntu-vm-2.yaml` | SSH public key |
| `playbooks/04_monitoring.yml` | Grafana admin password |

After running `configure.sh`, commit and push:
```bash
git add .
git commit -m "config: update IPs, username and SSH key for my setup"
git push
```

Then pull on the jumphost:
```bash
git pull
```

### 3.3 — Manual Configuration (Alternative)

If you prefer to edit files manually, here is every location that needs updating:

**`inventory/hosts.ini`** — Pi IPs and username:
```ini
[master]
k3s-master ansible_host=192.168.1.155    # ← your master IP

[workers]
k3s-worker1 ansible_host=192.168.1.160   # ← your worker1 IP
k3s-worker2 ansible_host=192.168.1.103   # ← your worker2 IP

[cluster:vars]
ansible_user=bakalauras                          # ← your Pi username
```

**`ansible.cfg`** — Pi username:
```ini
remote_user = bakalauras    # ← your Pi username
```

**`playbooks/04_monitoring.yml`** — Grafana password:
```yaml
grafana_password: "admin123"   # ← change to something secure
```

**`setup-jumphost.sh`** — Pi IPs in /etc/hosts section near the bottom of the file:
```bash
echo "192.168.1.155 k3s-master
192.168.1.160 k3s-worker1
192.168.1.103 k3s-worker2"
```

**`experiments/scenarios/00_common.sh`** — Pi IPs at top of file:
```bash
MASTER_IP="192.168.1.155"
WORKER1_IP="192.168.1.160"
WORKER2_IP="192.168.1.103"
```

**`manifests/monitoring/grafana-dashboard-configmap.yaml`** — Pi IPs appear many times inside Prometheus query strings. Use VS Code find and replace (`Ctrl+H`) to replace all occurrences of `192.168.1.155`, `192.168.1.160`, `192.168.1.103` with your actual IPs.

**`manifests/vms/ubuntu-vm-1.yaml` and `ubuntu-vm-2.yaml`** — SSH public key (do this after Step 5):
```yaml
ssh_authorized_keys:
  - ssh-rsa YOUR_FULL_PUBLIC_KEY_HERE   # ← from: cat ~/.ssh/ansible_id.pub
```

---

## 4. Step 1 — Flash SD Cards

### 4.1 — Flash Each Card

Repeat for each of the three SD cards:

1. Insert SD card into your PC
2. Open **Raspberry Pi Imager**
3. Select:
   - **Device:** Raspberry Pi 5
   - **OS:** Raspberry Pi OS Lite (64-bit) — under "Raspberry Pi OS (other)"
   - **Storage:** your SD card

4. Click the **gear icon** (⚙) → Edit Settings:

   | Setting | Card 1 | Card 2 | Card 3 |
   |---------|--------|--------|--------|
   | Hostname | `k3s-master` | `k3s-worker1` | `k3s-worker2` |
   | Username | your username | same | same |
   | Password | memorable password | same | same |
   | Enable SSH | ✅ Password auth | ✅ | ✅ |
   | Configure WiFi | ❌ Leave blank | ❌ | ❌ |

   > Flash each card separately with its own hostname. Do not copy the same image to multiple cards.

5. Click **Save** → **Write** → confirm → wait (~5-10 minutes)
6. Insert into the corresponding Pi

### 4.2 — Power On

1. Insert SD cards into Pis
2. Connect all three to your network switch via Ethernet
3. Power on all three
4. Wait 60-90 seconds

---

## 5. Step 2 — First Boot and Static IP Setup

> **Why static IPs?** By default Pis request IPs from your router automatically (DHCP). On many home routers, two freshly-flashed Pis can end up fighting for the same IP — whichever boots last wins, the other disappears. Static IPs fix this permanently. k3s also binds security certificates to IP addresses, so a changing IP would break the cluster.

### 5.1 — SSH Into Each Pi

From your PC:
```bash
ssh YOUR_USERNAME@k3s-master.local
ssh YOUR_USERNAME@k3s-worker1.local
ssh YOUR_USERNAME@k3s-worker2.local
```

> The `.local` suffix uses mDNS (automatic hostname discovery) which works out of the box on Raspberry Pi OS, Windows 10/11, and macOS.

### 5.2 — Find Your Gateway IP

On any Pi:
```bash
ip route | grep default
```

The IP shown (e.g. `192.168.50.1`) is your router. Use it in the commands below.

### 5.3 — Set Static IP on k3s-master

```bash
sudo nmcli connection add con-name eth0-static \
  ifname eth0 type ethernet \
  ipv4.method manual \
  ipv4.addresses 192.168.1.155/24 \
  ipv4.gateway 192.168.50.1 \
  ipv4.dns 192.168.50.1

sudo nmcli connection up eth0-static
```

SSH session will drop. Reconnect:
```bash
ssh YOUR_USERNAME@192.168.1.155
```

### 5.4 — Set Static IP on k3s-worker1

```bash
sudo nmcli connection add con-name eth0-static \
  ifname eth0 type ethernet \
  ipv4.method manual \
  ipv4.addresses 192.168.1.160/24 \
  ipv4.gateway 192.168.50.1 \
  ipv4.dns 192.168.50.1

sudo nmcli connection up eth0-static
```

Reconnect on `192.168.1.160`.

### 5.5 — Set Static IP on k3s-worker2

```bash
sudo nmcli connection add con-name eth0-static \
  ifname eth0 type ethernet \
  ipv4.method manual \
  ipv4.addresses 192.168.1.103/24 \
  ipv4.gateway 192.168.50.1 \
  ipv4.dns 192.168.50.1

sudo nmcli connection up eth0-static
```

Reconnect on `192.168.1.103`.

### 5.6 — Remove Old DHCP Profiles (CRITICAL)

> **Warning:** If you skip this step, the Pi may randomly revert to DHCP after a power outage and disappear from its static IP. This was encountered during testing and is a common failure point.

Adding a static profile does not remove the old DHCP profile. NetworkManager now has two competing profiles for the same interface and may pick either one on boot.

Run on **each Pi**:

```bash
# Check what profiles exist
nmcli connection show
```

You will likely see:
```
NAME              TYPE      DEVICE
netplan-eth0      ethernet  eth0      ← old DHCP profile (still active!)
eth0-static       ethernet  --        ← our static profile (idle)
```

Fix it in this order — order matters:

```bash
# 1. Activate static profile (session drops — reconnect after)
sudo nmcli connection up eth0-static

# 2. After reconnecting on static IP — delete the DHCP profile
sudo nmcli connection delete netplan-eth0

# 3. Delete any unused WiFi profiles if present
nmcli connection show
sudo nmcli connection delete "netplan-wlan0-YourNetworkName"
```

> **If you accidentally deleted the active connection:** Power-cycle the Pi. Since only `eth0-static` remains, NetworkManager will use it on next boot and the Pi will come back on the correct static IP.

### 5.7 — Verify and Reboot

After cleanup, only this should remain:
```bash
nmcli connection show
```
```
NAME          TYPE      DEVICE
eth0-static   ethernet  eth0
lo            loopback  lo
```

Reboot to confirm persistence:
```bash
sudo reboot
# After reboot, reconnect on static IP to confirm it worked
ssh YOUR_USERNAME@192.168.1.155
```

Repeat verification for all three Pis.

---

## 6. Step 3 — Set Up the CentOS Jumphost VM

### 6.1 — Create the VM

In VMware Workstation or VirtualBox:

1. Create a new VM with the CentOS Stream 10 ISO
2. Configure:
   - **CPU:** 2 cores
   - **RAM:** 2 GB
   - **Disk:** 20 GB
   - **Network:** ⚠️ **Bridged mode** — see next section
3. Install CentOS Stream following the installer

### 6.2 — CRITICAL: Bridged Networking, Not NAT

> Most virtualization software defaults to NAT networking. This puts the VM on an isolated private network and **breaks communication with the Pi nodes.**

**Bridged networking** makes the VM appear as a real device on your home network — it gets its own IP from the same router as the Pis.

**Check which mode you have (inside the CentOS VM):**
```bash
ip addr show
```

- IP in `192.168.50.x` (same as Pis) → **Bridged ✅**
- IP in `192.168.219.x`, `10.0.2.x`, `172.x.x.x` → **NAT ❌**

**Switch to Bridged:**
1. Shut down the VM
2. Open VM Settings → Network Adapter → change to **Bridged**
3. Select the physical adapter your PC uses to connect to the router
4. Boot VM — it should now get a `192.168.50.x` IP

### 6.3 — Verify Connectivity

```bash
ping -c 3 192.168.1.155
ping -c 3 192.168.1.160
ping -c 3 192.168.1.103
```

All should respond before continuing.

---

## 7. Step 4 — Clone the Repository and Configure

### 7.1 — Create a GitHub Personal Access Token

The repository is private. You need a token so the jumphost can download it.

1. Go to **github.com** → log in → profile picture → **Settings**
2. Left sidebar (scroll to bottom) → **Developer settings**
3. **Personal access tokens** → **Tokens (classic)**
4. **Generate new token (classic)**:
   - Note: `jumphost-token`
   - Expiration: 90 days or longer
   - Scopes: check only `repo`
5. **Generate token** → **copy immediately** (only shown once)

Token looks like: `ghp_xxxxxxxxxxxxxxxxxxxx`

### 7.2 — Clone on the Jumphost

```bash
git clone https://YOUR_TOKEN@github.com/YOUR_USERNAME/pi-cluster-k3s.git
cd pi-cluster-k3s
```

### 7.3 — Run configure.sh

After `setup-jumphost.sh` completes in Step 5, your SSH key will exist at `~/.ssh/ansible_id.pub`. At that point run `configure.sh` to update all configuration files:

```bash
cd ~/pi-cluster-k3s
bash configure.sh
```

The script will prompt for each value interactively. If you already know all your values:

```bash
bash configure.sh \
  --master-ip 192.168.1.155 \
  --worker1-ip 192.168.1.160 \
  --worker2-ip 192.168.1.103 \
  --username YOUR_USERNAME \
  --ssh-key "$(cat ~/.ssh/ansible_id.pub)" \
  --grafana-pass YOUR_PASSWORD
```

When done, commit and push from your PC:
```bash
git add .
git commit -m "config: update IPs, username and SSH key for my setup"
git push
```

Then pull on the jumphost:
```bash
git pull
```

---

## 8. Step 5 — Run the Setup Script

```bash
cd pi-cluster-k3s
bash setup-jumphost.sh
```

**This script automatically:**
- Installs Python 3, pip, Git
- Installs `ansible-core` and required Ansible collections
- Installs EPEL repository (needed for additional packages on CentOS)
- Installs `nss-mdns` and `avahi` (enables `.local` hostname resolution)
- Configures `/etc/nsswitch.conf` for mDNS
- Enables and starts `avahi-daemon`
- Opens firewall for mDNS traffic
- Adds Pi node entries to `/etc/hosts` for Ansible
- Installs `kubectl` (Kubernetes CLI)
- Installs `virtctl` (KubeVirt CLI)
- Generates SSH keypair at `~/.ssh/ansible_id`
- Creates `~/.kube` directory

At the end, the script prints your SSH public key. **Copy it for the next step.**

**Test mDNS works (after script completes):**
```bash
ping -c 3 k3s-master.local
ping -c 3 k3s-worker1.local
ping -c 3 k3s-worker2.local
```

---

## 9. Step 6 — Run configure.sh

Now that `setup-jumphost.sh` has generated your SSH key, run `configure.sh` to update all configuration files at once — IPs, username, SSH key and Grafana password:

```bash
cd ~/pi-cluster-k3s
bash configure.sh
```

The script auto-detects your SSH key at `~/.ssh/ansible_id.pub` and prompts for confirmation before using it. It will show a summary of every change before applying.

After it completes, commit and push the changes from VS Code, then pull on the jumphost:
```bash
git pull
```

> **If you already ran configure.sh** in Step 4 with all values — you can skip this step. Just verify your SSH key was included by checking `manifests/vms/ubuntu-vm-1.yaml` contains your key.

---

## 10. Step 7 — Run the Playbooks

Run from the jumphost inside the `pi-cluster-k3s` directory. **Run in order — do not skip any.**

### Playbook 00 — Bootstrap

```bash
ansible-playbook playbooks/00_bootstrap.yml --ask-pass --ask-become-pass
```

You will be prompted twice for a password — enter the same Pi password both times. The first prompt is for SSH login, the second is for sudo access. After this playbook completes, password authentication is permanently disabled — all future playbooks run without any password flags.

**Verify:**
```bash
ansible all -m ping    # all three should return pong
```

---

### Playbook 01 — k3s Cluster

```bash
ansible-playbook playbooks/01_k3s.yml
```

**Verify:**
```bash
kubectl get nodes
# All three nodes: Ready
```

---

### Playbook 02 — KubeVirt (10-15 minutes)

```bash
ansible-playbook playbooks/02_kubevirt.yml
```

**Verify:**
```bash
kubectl get pods -n kubevirt    # all: Running
kubectl get pods -n cdi         # all: Running
```

---

### Playbook 03 — Longhorn Storage

```bash
ansible-playbook playbooks/03_longhorn.yml
```

**Verify:**
```bash
kubectl get storageclass    # longhorn should be (default)
```

---

### Playbook 04 — Monitoring

```bash
ansible-playbook playbooks/04_monitoring.yml
```

**Verify:** Open `http://192.168.1.155:32000` in browser. Login: `admin` / your password.

---

### Playbook 05 — Virtual Machines (15-25 minutes)

```bash
ansible-playbook playbooks/05_vm_setup.yml
```

Ubuntu disk images (~500MB each) are downloaded and written to Longhorn. This is the longest step.

**Verify:**
```bash
kubectl get vms    # both: Running
ansible vms -m ping    # both: pong
```

---

## 11. Step 8 — Verify Everything Works

The quickest way to verify the full cluster is the `show_cluster_info.sh` script:

```bash
bash ~/pi-cluster-k3s/show_cluster_info.sh
```

This shows node status, VM placement, live UP/DOWN status for all web endpoints, disk usage per node, and component placement verification in one output.

If you prefer manual verification:

```bash
# Cluster nodes
kubectl get nodes

# VMs
kubectl get vmi -o wide

# Storage
kubectl get volumes.longhorn.io -n longhorn-system

# SSH into VMs
ssh -i ~/.ssh/ansible_id -p 30001 ubuntu@192.168.1.155
ssh -i ~/.ssh/ansible_id -p 30002 ubuntu@192.168.1.155
```

**Open in browser:**

| URL | What you should see |
|-----|---------------------|
| `http://192.168.1.155:32000` | Grafana login page |
| `http://192.168.1.155:30090` | Longhorn dashboard |
| `http://192.168.1.155:30091` | Prometheus targets |
| `http://192.168.1.155:30011` | Hello from ubuntu-vm-1 |
| `http://192.168.1.155:30012` | Hello from ubuntu-vm-2 |

---

## 12. Access Points Reference

| Service | Port | Login |
|---------|------|-------|
| Grafana | 32000 | admin / your password |
| Longhorn UI | 30090 | none |
| Prometheus | 30091 | none |
| VM1 SSH | 30001 | ubuntu / ubuntu123 |
| VM2 SSH | 30002 | ubuntu / ubuntu123 |
| VM1 HTTP | 30011 | none |
| VM2 HTTP | 30012 | none |

---

## 13. Daily Operations

### Check Cluster Status

```bash
bash ~/pi-cluster-k3s/show_cluster_info.sh
```

Shows everything at a glance — node status, VM placement, all web URLs with live UP/DOWN checks, disk usage, and component placement verification.

### Shutdown (always do this before unplugging)

```bash
bash shutdown-cluster.sh
```

### Startup Order

1. Power on **k3s-master**
2. Wait ~60 seconds → verify: `kubectl get nodes`
3. Power on **k3s-worker1** and **k3s-worker2** simultaneously

### Common Commands

```bash
kubectl get pods -A                          # all pods
kubectl get vms                              # VM status
kubectl get volumes.longhorn.io -n longhorn-system   # storage
ansible cluster -b -a "df -h /"             # disk usage
```

---

## 14. Known Limitations

- **128GB SD cards required** — 32GB cards run out of space under load
- **VM live migration is slow** (~2-3 min) due to SD card I/O speed
- **Node failure recovery takes ~5 minutes** — this is Kubernetes default eviction timeout, intentional
- **VM network is masquerade** — VMs are only reachable via NodePort services, not directly

---

## 15. Troubleshooting

### Two Pis swap availability on every reboot
DHCP conflict. Complete Section 5 (static IP setup). Check that `netplan-eth0` was deleted (`nmcli connection show`).

### Static IP stops working after power cut
Old `netplan-eth0` profile still exists. SSH in via hostname (`.local`), then:
```bash
sudo nmcli connection up eth0-static
sudo nmcli connection delete netplan-eth0
```

### Can ping Pi by IP but not by hostname (.local)
mDNS not working on jumphost. The setup script handles this, but if needed:
```bash
sudo systemctl restart avahi-daemon
sudo firewall-cmd --add-service=mdns --permanent && sudo firewall-cmd --reload
```

### "No route to host" on VM ports (30001, 30011 etc.)
nftables proxy mode not active. Verify:
```bash
ssh YOUR_USER@192.168.1.155 "sudo journalctl -u k3s | grep 'proxy-mode' | tail -3"
# Should show: Using nftables Proxier
```

### VM has no network after reboot
MAC address mismatch in netplan. Fix inside the VM:
```bash
virtctl console ubuntu-vm-1
# Login: ubuntu / ubuntu123
sudo nano /etc/netplan/50-cloud-init.yaml
# Remove: match: macaddress: and set-name: lines
sudo netplan apply
```

### Longhorn nodes showing "Unschedulable"
Disk above 85%. Check: `ansible cluster -b -a "df -h /"`. Reduce monitoring replica counts in Longhorn UI → Volumes → Prometheus/Grafana → Update Replicas Count → 1.

### kubectl: command not found
```bash
export PATH=$PATH:/usr/local/bin
echo 'export PATH=$PATH:/usr/local/bin' >> ~/.bashrc
```

### GitHub pull fails (permission denied)
Token expired. Generate new one (Step 7.1):
```bash
git remote set-url origin https://NEW_TOKEN@github.com/YOUR_USERNAME/pi-cluster-k3s.git
```

---

## Setup Checklist

- [ ] All three Pis flashed with unique hostnames
- [ ] All three Pis have static IPs (.155, .160, .103)
- [ ] Only `eth0-static` profile on each Pi — no `netplan-eth0` leftover
- [ ] Each Pi survives reboot on correct static IP
- [ ] CentOS VM in Bridged networking mode with `192.168.50.x` IP
- [ ] Jumphost can ping all three Pi static IPs
- [ ] Repository cloned on jumphost
- [ ] `setup-jumphost.sh` completed successfully
- [ ] `ping k3s-master.local` works from jumphost
- [ ] `configure.sh` run with correct IPs, username, SSH key and password
- [ ] Changes committed and pushed, then pulled on jumphost
- [ ] `ansible all -m ping` → pong from all three nodes
- [ ] All 6 playbooks ran without failures
- [ ] `kubectl get nodes` → 3 × Ready
- [ ] `kubectl get vms` → 2 × Running
- [ ] `bash show_cluster_info.sh` → all services UP
- [ ] Grafana, Longhorn, Prometheus accessible in browser
- [ ] Both VM web pages accessible in browser
- [ ] Both VMs reachable via SSH
