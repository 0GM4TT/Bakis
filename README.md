# ARM Microcluster — Open Source Infrastructure on Raspberry Pi

A fully automated, Infrastructure-as-Code deployment of a 3-node ARM Kubernetes cluster running on Raspberry Pi 5 hardware. Built as a bachelor's thesis project at Vilnius Tech (VGTU), this system deploys k3s Kubernetes, KubeVirt virtualisation, Longhorn distributed storage, and Prometheus/Grafana monitoring — all from a single Ansible automation stack.

The cluster runs Ubuntu VMs inside Kubernetes pods, supports live VM migration between nodes, recovers automatically from node failures, and ships with 5 pre-built Grafana dashboards and a full experiment suite for performance measurement.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│  Your PC                                                        │
│  ┌─────────────────────┐                                        │
│  │  CentOS Stream 10   │  ← Ansible jumphost (VMware/VirtualBox)│
│  │  Jumphost VM        │    runs all automation from here       │
│  └──────────┬──────────┘                                        │
└─────────────┼───────────────────────────────────────────────────┘
              │ Ethernet (Bridged networking)
              │
┌─────────────▼───────────────────────────────────────────────────┐
│  Home Network (192.168.1.x)                                    │
│                                                                 │
│  ┌──────────────────┐  ┌──────────────────┐  ┌──────────────┐  │
│  │  k3s-master      │  │  k3s-worker1     │  │  k3s-worker2 │  │
│  │  .155            │  │  .160            │  │  .103        │  │
│  │                  │  │                  │  │              │  │
│  │  k3s control     │  │  KubeVirt        │  │  KubeVirt    │  │
│  │  Prometheus      │  │  ubuntu-vm-2     │  │  ubuntu-vm-1 │  │
│  │  Grafana         │  │  Longhorn replica│  │  Longhorn    │  │
│  │  Longhorn mgr    │  │                  │  │  replica     │  │
│  └──────────────────┘  └──────────────────┘  └──────────────┘  │
│                                                                 │
│  Hardware: Raspberry Pi 5 (4GB RAM) × 3, 128GB SD cards        │
└─────────────────────────────────────────────────────────────────┘
```

---

## What's Included

| Component | Version | Purpose |
|-----------|---------|---------|
| k3s | v1.35.3+k3s1 | Lightweight Kubernetes for ARM |
| KubeVirt | v1.8.0 | Run VMs inside Kubernetes pods |
| CDI | v1.64.0 | Import VM disk images automatically |
| Longhorn | v1.11.1 | Distributed block storage across nodes |
| kube-prometheus-stack | 82.16.1 | Prometheus + Grafana monitoring |
| Ubuntu VMs | 24.04 Noble | Guest VMs (ARM64 cloud image) |

---

## Quick Start

### Prerequisites

- 3 × Raspberry Pi 5 (4GB RAM) with 128GB SD cards
- A PC running VMware Workstation or VirtualBox
- CentOS Stream 10 ISO for the jumphost VM
- Basic Linux command line knowledge

### Setup in 6 steps

```bash
# 1. Flash SD cards with Raspberry Pi Imager
#    Hostnames: k3s-master, k3s-worker1, k3s-worker2
#    See docs/setup.md Section 4 for full instructions

# 2. Set static IPs on each Pi
#    k3s-master  → 192.168.1.155
#    k3s-worker1 → 192.168.1.160
#    k3s-worker2 → 192.168.1.103
#    See docs/setup.md Section 5

# 3. Create a CentOS jumphost VM in Bridged networking mode
#    See docs/setup.md Section 6

# 4. Clone this repo and run the jumphost setup script
git clone https://YOUR_TOKEN@github.com/Marr0chi/pi-cluster-k3s.git
cd pi-cluster-k3s
bash setup-jumphost.sh

# 5. Configure all files for your network in one command
bash configure.sh

# 6. Run the Ansible playbooks in order
ansible-playbook playbooks/00_bootstrap.yml --ask-pass --ask-become-pass
ansible-playbook playbooks/01_k3s.yml
ansible-playbook playbooks/02_kubevirt.yml
ansible-playbook playbooks/03_longhorn.yml
ansible-playbook playbooks/04_monitoring.yml
ansible-playbook playbooks/05_vm_setup.yml
```

When all playbooks complete, verify the cluster:

```bash
bash show_cluster_info.sh
```

---

## Access Points

Once deployed, the cluster is accessible at these URLs (replace `192.168.1.155` if you used a different IP):

| Service | URL | Login |
|---------|-----|-------|
| Grafana | http://192.168.1.155:32000 | admin / your password |
| Longhorn | http://192.168.1.155:30090 | none |
| Prometheus | http://192.168.1.155:30091 | none |
| VM1 web | http://192.168.1.155:30011 | none |
| VM2 web | http://192.168.1.155:30012 | none |
| VM1 SSH | `ssh -i ~/.ssh/ansible_id -p 30001 ubuntu@192.168.1.155` | ubuntu / ubuntu123 |
| VM2 SSH | `ssh -i ~/.ssh/ansible_id -p 30002 ubuntu@192.168.1.155` | ubuntu / ubuntu123 |

---

## Repository Structure

```
pi-cluster-k3s/
│
├── configure.sh              ← Run once: updates all IPs, username, SSH key
├── setup-jumphost.sh         ← Run once: installs Ansible, kubectl, SSH key
├── shutdown-cluster.sh       ← Graceful cluster shutdown before power off
├── show_cluster_info.sh      ← Dashboard: shows cluster status and all URLs
│
├── inventory/
│   └── hosts.ini             ← Pi node IPs and Ansible groups
│
├── ansible.cfg               ← Ansible connection settings
│
├── playbooks/
│   ├── 00_bootstrap.yml      ← SSH keys, cgroups, swap, NTP
│   ├── 01_k3s.yml            ← Install k3s cluster
│   ├── 02_kubevirt.yml       ← Install KubeVirt + CDI
│   ├── 03_longhorn.yml       ← Install Longhorn storage
│   ├── 04_monitoring.yml     ← Install Prometheus + Grafana
│   └── 05_vm_setup.yml       ← Deploy Ubuntu VMs
│
├── manifests/
│   ├── vms/
│   │   ├── ubuntu-vm-1.yaml          ← VM definition (nodeAffinity: not master)
│   │   ├── ubuntu-vm-2.yaml
│   │   ├── ubuntu-vm-1-services.yaml ← NodePort services for SSH and HTTP
│   │   ├── ubuntu-vm-2-services.yaml
│   │   └── webserver.py              ← Python web server showing current Pi node
│   ├── monitoring/
│   │   ├── grafana-dashboard-configmap.yaml  ← All 5 Grafana dashboards
│   │   ├── prometheus-nodeport.yaml
│   │   ├── vm-metrics-service.yaml
│   │   └── vm-service-monitor.yaml
│   └── longhorn/
│       └── longhorn-ui-service.yaml
│
├── experiments/
│   ├── scenarios/
│   │   ├── 00_common.sh              ← Shared functions, prerequisites check
│   │   ├── 01_ha_recovery.sh         ← Node failure and recovery timing
│   │   ├── 02_live_migration.sh      ← VM live migration performance
│   │   ├── 03_resource_comparison.sh ← Pi node vs VM resource overhead
│   │   ├── 04_vm_spinup.sh           ← VM deployment time end-to-end
│   │   └── 05_cluster_startup.sh     ← Full cluster cold start timing
│   ├── generate_graphs.py            ← Generate thesis graphs from CSV results
│   └── README.md                     ← Detailed experiment documentation
│
└── docs/
    └── setup.md                      ← Full setup guide from scratch
```

---

## Grafana Dashboards

Five dashboards are provisioned automatically — no manual import needed:

| Dashboard | Purpose |
|-----------|---------|
| ARM Microcluster — Overview | General cluster health, all nodes and VMs |
| Scenario 1 — HA Recovery | Node status timeline, VM recovery, resource spikes |
| Scenario 2 — Live Migration | VM location, migration indicator, network spike |
| Scenario 3 — Resource Comparison | Pi node vs VM CPU/RAM overhead side by side |
| Scenario 4 — VM Deployment | Pod count, PVC import status, disk/network spikes |

All dashboards refresh every 5-10 seconds and are suitable for monitoring live experiment runs.

---

## Experiments

The `experiments/` directory contains automated scripts for 5 research scenarios. Each script collects timing and resource metrics, saves results to CSV, and can generate thesis-ready graphs.

```bash
# Navigate to scenarios directory (required)
cd ~/pi-cluster-k3s/experiments/scenarios

# Always run sanity check first
source ./00_common.sh
check_prerequisites
check_experiment_prerequisites

# Run a scenario
bash 01_ha_recovery.sh

# Generate graphs from results
cd ~/pi-cluster-k3s
python3 experiments/generate_graphs.py \
  --results experiments/results/01_ha_recovery_TIMESTAMP \
  --scenario 1
```

| Scenario | Tests | Duration | Manual steps |
|----------|-------|----------|--------------|
| 1 — HA Recovery | Node failure recovery with 3 eviction timeouts | 3-4 hours | Yes — power node on/off |
| 2 — Live Migration | VM migration idle vs under load | 1-2 hours | No |
| 3 — Resource Comparison | Pi node vs VM resource overhead | 15 minutes | No |
| 4 — VM Deployment | End-to-end VM spinup time | 2-3 hours | No |
| 5 — Cluster Startup | Cold start time across all milestones | 3-4 hours | Yes — power cluster on/off |

See `experiments/README.md` for detailed documentation of each scenario, what every measurement means, and how to read every graph.

---

## Key Design Decisions

**Prometheus and Grafana pinned to master** — worker nodes get powered off during HA and startup experiments. Pinning monitoring to the master node ensures metric collection is never interrupted during tests.

**VMs restricted from master** — VM nodeAffinity rules prevent VMs from scheduling on k3s-master, keeping the control plane isolated from workload noise. This ensures resource comparison measurements are accurate.

**nftables proxy mode** — required for NodePort services to route correctly across all nodes on Raspberry Pi OS. Configured before k3s installation.

**Sequential cluster startup** — always power on k3s-master first, wait 20-30 seconds, then power on workers. Simultaneous boot causes workers to fail connecting to the API server and adds inconsistent startup delays.

**RWX storage for VMs** — VM disk volumes use ReadWriteMany access mode (required for live migration). Longhorn replication factor of 2 ensures data survives a single node failure.

---

## Daily Operations

```bash
# Check cluster status
bash show_cluster_info.sh

# Graceful shutdown before unplugging
bash shutdown-cluster.sh

# Startup order after power on
# 1. Power on k3s-master first
# 2. Wait 20-30 seconds
# 3. Power on k3s-worker1 and k3s-worker2
```

---

## Documentation

- **Full setup guide** — [docs/setup.md](docs/setup.md)
  Step-by-step from freshly flashed SD cards to a fully running cluster. Written for someone who has never used Kubernetes before.

- **Experiments guide** — [experiments/README.md](experiments/README.md)
  Detailed documentation for every scenario: what is tested, step-by-step flow, what each measurement means, and how to read every graph.

---

## Authors

**Students:** Augustas Matuiza, Ugnius Sliesaravičius

**Advisor:** lekt. Martynas Urbanavičius

Vilnius Tech (VGTU) — Bachelor's Thesis, 2026
