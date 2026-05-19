# Cluster Experiments

This directory contains automated scripts for measuring ARM microcluster performance and resilience. The experiments are designed to produce quantitative data suitable for a bachelor's thesis, including timing measurements, resource utilization data, and automatically generated graphs.

---

## Table of Contents

1. [Directory Structure](#1-directory-structure)
2. [Big Picture — How Everything Fits Together](#2-big-picture--how-everything-fits-together)
3. [Before Running Any Experiment](#3-before-running-any-experiment)
4. [Scenario 1 — HA Recovery](#4-scenario-1--ha-recovery)
5. [Scenario 2 — Live Migration](#5-scenario-2--live-migration)
6. [Scenario 3 — Resource Comparison](#6-scenario-3--resource-comparison)
7. [Scenario 4 — VM Deployment Time](#7-scenario-4--vm-deployment-time)
8. [Scenario 5 — Cluster Startup Time](#8-scenario-5--cluster-startup-time)
9. [Generating Graphs](#9-generating-graphs)
10. [Common Issues](#10-common-issues)

---

## 1. Directory Structure

```
experiments/
  scenarios/
    00_common.sh              <- shared functions used by all scripts
    01_ha_recovery.sh         <- Scenario 1: node failure and recovery
    02_live_migration.sh      <- Scenario 2: live VM migration
    03_resource_comparison.sh <- Scenario 3: Pi node vs VM resources
    04_vm_spinup.sh           <- Scenario 4: VM deployment timing
    05_cluster_startup.sh     <- Scenario 5: full cluster startup timing
  results/                    <- all CSV results saved here automatically
  generate_graphs.py          <- Python script to generate thesis graphs
  README.md                   <- this file
```

---

## 2. Big Picture — How Everything Fits Together

Before diving into individual scenarios, here is the overall flow of the experiment process:

```
CLUSTER RUNNING
      |
      v
[Sanity Check]
  source ./00_common.sh
  check_prerequisites
  check_experiment_prerequisites
      |
      v
[Run Scenario Script]
  bash 01_ha_recovery.sh
      |
      |-- collects metrics from Prometheus every 5 seconds (background)
      |-- monitors HTTP endpoint every 1 second (background)
      |-- records timestamps at key events
      |-- saves everything to CSV files in experiments/results/
      |
      v
[CSV Results]
  timing_summary.csv       <- when things happened and how long they took
  metrics_snapshots.csv    <- CPU, RAM, network, disk at key moments
  http_monitor_*.csv       <- HTTP request success/failure log
      |
      v
[Generate Graphs]
  python3 generate_graphs.py --results experiments/results/01_ha_... --scenario 1
      |
      v
[PNG Graphs ready for thesis]
  box plots, line charts, bar charts, summary tables
```

### What the scripts measure and why

The scripts measure two categories of data:

**Timing data** — answers questions like:
- How long did recovery take?
- How long did migration take?
- How long until the cluster was fully operational?

**Resource data** — answers questions like:
- How much CPU did the Pi nodes use during a node failure?
- What is the overhead of running VMs compared to bare metal?
- How much network traffic does live migration generate?

Both categories are needed for a complete thesis analysis. Timing data gives you the headlines ("recovery took 287 seconds on average"). Resource data explains the why ("because the remaining nodes had to handle 40% more CPU load during replica rebuilding").

### Recommended experiment order

Run experiments in this order — each one builds on the cluster being stable:

```
Scenario 3 first  <- only 15 minutes, no manual steps, good warm-up
Scenario 2 second <- 1-2 hours, no manual steps
Scenario 4 third  <- 2-3 hours, no manual steps
Scenario 1 fourth <- 3-4 hours, requires manual node power cycling
Scenario 5 last   <- 3-4 hours, requires full cluster power cycling
```

---

## 3. Before Running Any Experiment

### Step 1 — Verify cluster health

```bash
kubectl get nodes           # all 3: Ready
kubectl get vms             # both: Running
kubectl get pods -A | grep -v Running   # should return nothing
```

### Step 2 — Navigate to scenarios directory

**This is mandatory.** All scripts must run from this exact directory:

```bash
cd ~/pi-cluster-k3s/experiments/scenarios
```

The `source ./00_common.sh` line in each script looks for `00_common.sh` in the current directory. If you run from anywhere else, the script will immediately fail.

### Step 3 — Run the sanity check

```bash
source ./00_common.sh
check_prerequisites
check_experiment_prerequisites
```

Expected output:
```
[INFO] kubectl v
[INFO] virtctl v
[INFO] Cluster connectivity v
[INFO] Prometheus v
[INFO] SSH key v
[INFO] Results directory: .../results v
[INFO] All prerequisites satisfied
[INFO] Prometheus on k3s-master v
[INFO] Grafana on k3s-master v
[INFO] No VMs on k3s-master v
[INFO] All experiment prerequisites satisfied v
```

If any check fails, do not proceed. Fix the issue first.

### Why Prometheus and Grafana must be on master

During experiments involving node failures (Scenario 1) and cluster restart (Scenario 5), worker nodes get powered off. If Prometheus were running on a worker node, all metric collection would stop the moment that node goes down — leaving gaps in the data exactly when the most interesting things are happening.

By pinning Prometheus and Grafana to the master node (which never gets powered off during experiments), metric collection continues uninterrupted throughout every scenario.

### Why VMs must not be on master

The master node runs the Kubernetes control plane (the API server, scheduler, and other critical components). If a VM is also running on master and consuming CPU and RAM, it distorts all measurements. The Pi node resource comparisons would be inaccurate because master would be doing double duty.

Additionally, during HA recovery tests, we always fail a worker node — never master. If a VM were on master, it would never experience a failure, making the HA test pointless.

---

## 4. Scenario 1 — HA Recovery

**Script:** `01_ha_recovery.sh`
**Duration:** 3-4 hours
**Manual steps:** Yes — powering node back on after each run

### What is being tested and why it matters

High Availability (HA) means the system keeps running even when individual components fail. In Kubernetes, when a node goes offline, the scheduler detects this and moves the workloads that were running on that node to healthy nodes.

The key question is: **how long does this take?**

The answer depends on the `eviction timeout` — a Kubernetes setting that controls how long the system waits before declaring a node truly dead and rescheduling its workloads. A longer timeout means Kubernetes waits longer to be sure the node is really gone (not just temporarily unreachable due to a network glitch). A shorter timeout means faster recovery but higher risk of unnecessary rescheduling.

This scenario tests three different timeout values to show the tradeoff:
- **300s** (5 minutes) — the Kubernetes default
- **60s** (1 minute) — a reasonable compromise
- **30s** — aggressive, fastest recovery

### Step by step flow

```
START
  |
  v
[Pre-flight check]
  Verify Prometheus on master, VMs on workers
  |
  v
[For each eviction timeout: 300s, 60s, 30s]
  |
  |-- Set eviction timeout on k3s master
  |-- Restart k3s (takes ~30 seconds)
  |-- Wait for all nodes Ready
  |
  |-- [For each of 10 repetitions:]
  |     |
  |     |-- Move ubuntu-vm-1 to k3s-worker2 (the node we will fail)
  |     |-- Take baseline metrics snapshot (CPU, RAM, network, disk)
  |     |-- Start HTTP monitor (curl every 1 second to VM web page)
  |     |-- Start background metrics collection (every 5 seconds)
  |     |-- Record timestamp: FAILURE START
  |     |-- Power off k3s-worker2 (ssh poweroff command)
  |     |-- Wait for k3s-worker2 to show NotReady
  |     |-- Record timestamp: NODE NOT READY
  |     |-- Wait for ubuntu-vm-1 to appear Running on a healthy node
  |     |-- Record timestamp: VM RECOVERED
  |     |-- Take post-recovery metrics snapshot
  |     |-- Stop HTTP monitor and metrics collection
  |     |-- Count HTTP failures from log
  |     |-- PROMPT: "Please power on k3s-worker2 now"
  |     |-- Wait for k3s-worker2 to rejoin cluster
  |     |-- Wait 120s for cluster to stabilize
  |
  v
[Export time series data from Prometheus]
[Generate graphs]
END
```

### What each measurement means

**Node not ready time** — how long from power-off until Kubernetes detected the node is gone. This is usually 10-20 seconds — the kubelet heartbeat timeout. Not affected much by eviction timeout settings.

**VM recovery time** — how long from power-off until the VM is Running again on a healthy node. This IS directly controlled by the eviction timeout setting. With 300s timeout, you wait ~5 minutes. With 30s timeout, you wait ~30-45 seconds.

**HTTP downtime** — the number of seconds during which the web page returned an error or timed out. This reflects real user impact — how long the service was unavailable. It should be close to the VM recovery time since traffic is routed to the VM via NodePort services.

### Graphs generated and how to read them

---

**Graph: `01_ha_recovery_time_boxplot.png`**

A box plot with three boxes, one per eviction timeout setting (300s, 60s, 30s).

How to read a box plot:
```
        |            <- maximum value
     -------
     |     |
     |  *  |  <- box represents middle 50% of measurements
     |     |     top = 75th percentile
     -------     bottom = 25th percentile
        |            <- minimum value
   ─────────        <- median line (middle of box)
```

What good results look like:
- The 300s box should be centered around 290-310 seconds
- The 60s box should be centered around 65-80 seconds
- The 30s box should be centered around 35-50 seconds
- Small boxes (tight spread) mean consistent results — good
- Large boxes (wide spread) mean variable results — investigate why

What it proves for the thesis:
This graph is your main evidence that eviction timeout directly controls recovery time. The visual separation between the three boxes makes the relationship immediately obvious. Cite this when claiming that "reducing eviction timeout from 300s to 30s reduces recovery time by approximately 86%".

---

**Graph: `01_ha_recovery_time_per_run.png`**

A line chart showing recovery time for each of the 10 runs, with separate lines for each timeout value.

How to read it:
- X axis = run number (1-10)
- Y axis = recovery time in seconds
- Each line = one eviction timeout setting

What good results look like:
- Lines should be relatively flat (consistent across runs)
- Occasional spikes are normal (Longhorn replica rebuilding, network variance)
- All three lines should be clearly separated from each other

What it proves for the thesis:
Shows the consistency of results across 10 repetitions, which validates the statistical reliability of the averages. If the lines are flat and separated, your results are reliable. If they are erratic, you need to investigate what caused variance.

---

**Graph: `01_ha_http_downtime.png`**

A bar chart showing average HTTP downtime (seconds of failed web requests) for each eviction timeout, with error bars showing standard deviation.

How to read it:
- Taller bar = more seconds of HTTP downtime = worse user experience
- Error bars = variability across 10 runs (smaller = more consistent)

What good results look like:
- The 300s bar should be around 285-295 seconds
- The 60s bar should be around 65-75 seconds
- The 30s bar should be around 35-45 seconds
- HTTP downtime should be slightly less than VM recovery time (the service comes back slightly before the full recovery is confirmed)

What it proves for the thesis:
Translates technical measurements into user impact. Instead of "Kubernetes took 287 seconds to reschedule", you can say "users experienced 284 seconds of service unavailability". This is more meaningful from a business perspective.

---

**Graph: `01_ha_summary_table.png`**

A statistics table showing average, minimum, maximum, and standard deviation for recovery time and HTTP downtime across all 10 runs, for each eviction timeout.

How to read it:
- Each row = one eviction timeout setting
- Lower standard deviation = more consistent results
- Gap between min and max shows range of outcomes

What it proves for the thesis:
Provides the exact numbers to cite in the thesis text. Every claim you make about recovery times should reference specific numbers from this table.

---

## 5. Scenario 2 — Live Migration

**Script:** `02_live_migration.sh`
**Duration:** 1-2 hours
**Manual steps:** None

### What is being tested and why it matters

Live migration is the ability to move a running virtual machine from one physical host to another without stopping it. This is a key feature of KubeVirt on Kubernetes and a major advantage over traditional bare-metal deployments.

The critical question is: **does live migration cause service interruption?**

Ideally, from the user's perspective, nothing changes — the web page keeps responding, the VM keeps running, it just appears on a different Pi node. In reality, there is usually a brief pause during the final memory synchronization phase.

This scenario tests live migration under two conditions:
- **Unloaded** — VM is idle, minimal memory changes during migration
- **Loaded** — VM has active CPU and memory workload (stress-ng), memory changes rapidly, making migration harder

### Step by step flow

```
START
  |
  v
[Pre-flight check]
  Verify prerequisites, install stress-ng on VMs
  |
  v
[Part A: Unloaded migration - 10 runs]
  |
  |-- [For each of 10 runs:]
  |     |
  |     |-- Take baseline metrics snapshot
  |     |-- Start HTTP monitor (curl every 1 second)
  |     |-- Start background metrics collection
  |     |-- Wait 3 seconds for monitoring to initialize
  |     |-- Trigger live migration: virtctl migrate ubuntu-vm-1
  |     |-- Wait for VM to appear on different node
  |     |-- Record migration duration
  |     |-- Take post-migration snapshot
  |     |-- Stop monitoring
  |     |-- Count HTTP failures
  |     |-- Wait 30s before next run
  |
  v
[Part B: Loaded migration - 10 runs]
  |
  |-- [For each of 10 runs:]
  |     |
  |     |-- Start stress-ng inside VM (CPU + 200MB memory load)
  |     |-- Wait 10s for load to stabilize
  |     |-- [Same steps as Part A]
  |     |-- Stop stress-ng after migration completes
  |     |-- Wait 30s before next run
  |
  v
[Export time series data]
[Generate graphs]
END
```

### What each measurement means

**Migration duration** — how long from `virtctl migrate` command until the VM is confirmed Running on the new node. Includes: pre-migration checks, memory copy phase, final synchronization, and pod scheduling on destination.

**HTTP failures** — number of one-second intervals during which the web page returned an error. Zero failures means truly zero-downtime migration. Even one or two failures means there was a brief interruption that users would notice.

**Network throughput** — the amount of data transferred between nodes during migration. This is essentially the VM's memory being copied over the network. Higher under load (because memory changes faster and needs to be re-copied).

### Graphs generated and how to read them

---

**Graph: `02_migration_duration_boxplot.png`**

A box plot comparing migration duration between unloaded and loaded conditions.

How to read it:
- Left box = unloaded migration
- Right box = loaded migration
- Taller and higher box = longer migration time

What good results look like:
- Unloaded migrations should take 60-120 seconds on SD card hardware
- Loaded migrations should take 150-250 seconds (longer because memory changes faster)
- The separation between boxes demonstrates the load impact clearly

What it proves for the thesis:
Shows that live migration duration is directly affected by the VM's memory activity. This is the core KubeVirt live migration characteristic — memory-intensive workloads take longer to migrate because the hypervisor must continuously re-copy memory pages that change during the migration process.

---

**Graph: `02_migration_duration_per_run.png`**

A line chart showing migration duration for each run, comparing loaded vs unloaded.

How to read it:
- Two lines: green (unloaded) and red (loaded)
- X axis = run number (1-10)
- Y axis = duration in seconds

What good results look like:
- Green line should be consistently below red line
- Both lines should be relatively stable across runs
- Occasional outliers are normal (Longhorn I/O variance)

What it proves for the thesis:
Validates that the loaded/unloaded difference is consistent across all 10 runs, not just a single lucky or unlucky measurement.

---

**Graph: `02_migration_http_failures.png`**

A grouped bar chart showing HTTP request failures per run for both conditions.

How to read it:
- Each run has two bars: green (unloaded) and red (loaded)
- Bar height = number of failed HTTP requests during migration
- Zero bars = zero downtime migration

What good results look like:
- Most bars should be 0 or close to 0 (live migration is designed to be zero-downtime)
- Occasional 1-2 failures are acceptable and expected
- Loaded migrations may show slightly more failures

What it proves for the thesis:
This is your key evidence for whether KubeVirt live migration achieves zero-downtime on ARM hardware. If bars are consistently at 0, you can claim zero-downtime live migration. If there are regular failures, you need to discuss why (SD card I/O latency during final memory sync).

---

**Graph: `02_migration_summary_table.png`**

Statistics table comparing unloaded and loaded migration across all 10 runs.

What it proves for the thesis:
The definitive numbers for your thesis text. Quote average duration and average HTTP failures directly from this table.

---

## 6. Scenario 3 — Resource Comparison

**Script:** `03_resource_comparison.sh`
**Duration:** ~15 minutes
**Manual steps:** None

### What is being tested and why it matters

This scenario answers a fundamental question: **what is the resource cost of running virtual machines inside a Kubernetes cluster on ARM hardware?**

There are two layers of resource consumption:
1. The Pi nodes themselves (CPU, RAM, network, disk) — measured via node_exporter
2. The Ubuntu VMs running inside the cluster — also measured via node_exporter running inside the VMs

By measuring both at idle and under load, you can determine:
- How much overhead KubeVirt/Kubernetes adds just by running
- How efficiently the VMs utilize the physical Pi node resources
- Whether running VMs creates resource contention between the hypervisor layer and the guest OS

### Step by step flow

```
START
  |
  v
[Pre-flight check]
  Install stress-ng on both VMs
  |
  v
[Phase 1: Idle baseline - 5 minutes]
  |
  Collect metrics every 5 seconds from:
    - k3s-master, k3s-worker1, k3s-worker2 (Pi nodes)
    - ubuntu-vm-1, ubuntu-vm-2 (VMs)
  Save to phase1_idle/metrics_snapshots.csv
  |
  v
[Phase 2: VM load - 5 minutes]
  |
  Start stress-ng on ubuntu-vm-1:
    --cpu 1 (saturate 1 CPU core)
    --vm 1 --vm-bytes 200M (allocate and write 200MB memory)
  Start stress-ng on ubuntu-vm-2: same
  |
  Wait 15s for load to stabilize
  |
  Collect metrics every 5 seconds (same sources as Phase 1)
  Save to phase2_loaded/metrics_snapshots.csv
  |
  v
[Phase 3: Recovery - 2 minutes]
  |
  Stop stress-ng on both VMs
  |
  Collect metrics every 5 seconds
  Save to phase3_recovery/metrics_snapshots.csv
  |
  v
[Export full time series from Prometheus]
[Generate graphs]
END
```

### What each measurement means

**Pi node CPU %** — percentage of Pi CPU time spent on all work including: Kubernetes system processes, KubeVirt hypervisor, Longhorn storage, Prometheus/Grafana monitoring, and VM guest workloads. Higher than pure VM CPU because of all the infrastructure overhead.

**VM CPU %** — percentage of CPU time inside the Ubuntu VM. Only includes what the VM thinks it is doing. The VM cannot see the hypervisor overhead or Kubernetes overhead.

**The gap between Pi node CPU and VM CPU** — this gap represents the overhead of the virtualization stack. For example, if a VM shows 80% CPU but the Pi node shows 95% CPU, the 15% difference is the cost of running KubeVirt, Kubernetes, Longhorn, and monitoring.

**RAM comparison** — similarly, the VM reports less RAM usage than the Pi node because the Pi node is also running all the infrastructure components.

### Graphs generated and how to read them

---

**Graph: `03_cpu_comparison.png`**

Two side-by-side bar charts — Pi node CPU on the left, VM CPU on the right. Each chart has three groups of bars (idle, loaded, recovery) with one bar per node/VM.

How to read it:
- Taller bars = higher CPU usage
- Compare left chart (Pi nodes) to right chart (VMs) for the same phase
- The difference between left and right shows virtualization overhead

What good results look like:
- Idle phase: Pi nodes at 5-15%, VMs at 1-5% (low baseline expected)
- Loaded phase: VMs at 80-100% (stress-ng saturates CPU), Pi nodes at 85-100% (VM load + overhead)
- Recovery phase: both should return close to idle levels within 1-2 minutes

What it proves for the thesis:
Demonstrates the resource efficiency of KubeVirt virtualization on ARM hardware. The overhead gap tells you how much of the Pi's resources are consumed by infrastructure vs actual VM workloads.

---

**Graph: `03_ram_comparison.png`**

Same structure as CPU comparison but for RAM usage.

What good results look like:
- Pi nodes will consistently show higher RAM% than VMs (Kubernetes + KubeVirt + Longhorn + monitoring consume significant RAM)
- Under stress-ng load, VM RAM increases noticeably (200MB allocation)
- Pi node RAM increase under load should be slightly larger (VM RAM + hypervisor overhead for managing that RAM)

What it proves for the thesis:
Shows the memory overhead of the virtualization stack. Important for understanding practical limits — how many VMs can the cluster run before running out of RAM?

---

**Graph: `03_network_timeseries.png`**

A line chart showing network receive rate over the entire experiment duration (all three phases).

How to read it:
- X axis = time
- Y axis = KB/s received across all nodes
- You should be able to see three distinct sections: low (idle), higher (loaded — VMs receiving stress-ng data), back to low (recovery)

What it proves for the thesis:
Shows that VM CPU/memory load has minimal network impact (stress-ng is purely local workload). Contrast this with the network spike visible during live migration (if you run Scenario 2 before this and export the same time range).

---

## 7. Scenario 4 — VM Deployment Time

**Script:** `04_vm_spinup.sh`
**Duration:** 2-3 hours
**Manual steps:** None

### What is being tested and why it matters

One of the practical questions for edge computing deployments is: **how quickly can you spin up a new VM from scratch?**

This matters for:
- Disaster recovery — how fast can services be restored after complete failure?
- Scaling — how quickly can you add VM capacity to handle increased load?
- Automation validation — does the IaC deployment actually work end-to-end?

The total deployment time is broken into stages because different stages have very different optimization opportunities:
- **Disk import** is dominated by download speed and Longhorn write speed
- **VM boot** is dominated by KubeVirt scheduling and QEMU startup
- **Network init** is fixed by cloud-init processing time
- **HTTP ready** is dominated by the web server startup time

### Step by step flow

```
START
  |
  v
[Pre-flight check]
  Verify ubuntu-vm-2.yaml manifest exists
  Delete any existing ubuntu-vm-2 and its PVC (force clean start)
  |
  v
[For each of 10 runs:]
  |
  |-- Start background metrics collection
  |-- Take pre-deployment snapshot
  |-- Record T0: deployment start
  |
  |-- kubectl apply ubuntu-vm-2.yaml (creates VM and PVC)
  |-- kubectl apply ubuntu-vm-2-services.yaml (creates NodePorts)
  |-- Record T1: manifests applied
  |
  |-- Wait for DataVolume to reach Succeeded phase
  |   (Ubuntu cloud image downloaded and written to Longhorn)
  |-- Record T2: disk import complete
  |   Elapsed since T1 = disk_import time
  |
  |-- Wait for VMI to reach Running phase
  |   (KubeVirt started QEMU, VM booting)
  |-- Record T3: VM running
  |   Elapsed since T2 = vm_running time
  |
  |-- Wait 30 seconds (cloud-init runs: sets hostname, user, SSH key,
  |   writes netplan config, removes old netplan, starts web server)
  |-- Record T4: network initialized
  |   30s fixed = network_init time
  |
  |-- Poll VM2 HTTP endpoint until 200 OK response
  |-- Record T5: HTTP ready
  |   Elapsed since T4 = http_ready time
  |
  |-- Total = T5 - T0
  |-- Take post-deployment snapshot
  |-- Stop metrics collection
  |
  |-- Delete ubuntu-vm-2 and its PVC (clean up for next run)
  |-- Wait 60s for Longhorn to clean up
  |
  v
[Export time series data]
[Generate graphs]
END

NOTE: ubuntu-vm-1 stays running throughout all 10 runs.
      Only ubuntu-vm-2 is deleted and recreated each time.
```

### What each measurement means

**Disk import time** — the largest component. CDI (Containerized Data Importer) downloads the Ubuntu cloud image from `cloud-images.ubuntu.com` and writes it to a Longhorn PVC. First run may be slower than subsequent runs if CDI caches the image locally.

**VM running time** — how long after the disk is ready until KubeVirt has QEMU running and the VM has started booting. Should be consistent across all runs (10-30 seconds typically).

**Network init time** — fixed at 30 seconds to allow cloud-init to complete. Cloud-init runs on every boot and: sets hostname, creates the ubuntu user, writes the SSH public key, configures netplan, and starts the Python web server.

**HTTP ready time** — how long after the 30s cloud-init wait until the web server actually responds. Should be short (5-15 seconds) if cloud-init completed successfully.

**Total time** — end-to-end from `kubectl apply` to web page accessible. This is the number you quote in the thesis as "deployment time".

### Graphs generated and how to read them

---

**Graph: `04_spinup_stacked_bar.png`**

A stacked bar chart with one bar per run. Each bar is divided into colored segments representing each deployment stage. A dotted line shows the total time per run.

How to read it:
- Bar height = total deployment time for that run
- Colored segments = time spent in each stage
- Dotted line = should match bar height (sanity check)
- Compare bar heights across runs to see consistency

What good results look like:
- The disk_import segment (blue) should dominate — typically 60-70% of total time
- The vm_running segment (green) should be small and consistent
- The network_init segment (orange) should be fixed at 30 seconds every run
- Run 1 may show a taller disk_import if the image was not cached

What it proves for the thesis:
Shows both the total deployment time and where that time is spent. This tells you where optimization efforts would have the most impact (disk import is the bottleneck, not VM boot).

---

**Graph: `04_spinup_total_boxplot.png`**

A single box plot showing the distribution of total deployment times across all 10 runs.

How to read it:
- The red dashed line shows the mean
- A tight box (small spread) means consistent deployment times
- A wide box means variable results — likely due to network speed variation during image download

What it proves for the thesis:
Gives you the definitive deployment time number to quote: "average deployment time of X seconds with standard deviation of Y seconds across 10 runs".

---

**Graph: `04_spinup_stage_averages.png`**

A bar chart showing the average time per stage across all 10 runs, with error bars showing standard deviation.

How to read it:
- Each bar = one deployment stage
- Bar height = average time for that stage
- Error bars = how much that stage varied across runs
- Stages with large error bars are the ones causing inconsistency

What it proves for the thesis:
Identifies which stage is the bottleneck (disk import) and which stages are reliable and fast. This supports recommendations for optimization — for example, pre-caching VM images would eliminate most of the disk import time.

---

## 8. Scenario 5 — Cluster Startup Time

**Script:** `05_cluster_startup.sh`
**Duration:** 3-4 hours
**Manual steps:** Yes — powering cluster on and off 10 times

### What is being tested and why it matters

Edge computing deployments often face power interruptions. After a power cut, how quickly does the entire ARM microcluster become fully operational again? This is a realistic and important question for anyone considering deploying infrastructure on Raspberry Pis.

This scenario measures the time from physical power-on to the moment every component is fully ready and accessible — broken down into milestones so you can see which components take the longest.

### Step by step flow

```
START (cluster is powered OFF)
  |
  v
[For each of 10 runs:]
  |
  |-- PROMPT: "Run shutdown-cluster.sh and power off all Pi nodes"
  |-- PROMPT: "Power on k3s-master FIRST — press Enter immediately (timer starts)"
  |-- Record T0: power-on time (master powered on)
  |-- [Power on k3s-worker1 and k3s-worker2 20-30 seconds later]
  |-- Start pod count tracker (records running/pending/total pods every 10s)
  |
  |-- Poll kubectl until API server responds
  |-- Record T1: API server ready (elapsed from T0)
  |
  |-- Poll kubectl get nodes until all 3 show Ready
  |-- Record T2: all nodes ready (elapsed from T0)
  |
  |-- Poll Longhorn nodes until all 3 show Schedulable
  |-- Record T3: Longhorn healthy (elapsed from T0)
  |
  |-- Poll Prometheus /-/healthy endpoint
  |-- Record T4: Prometheus ready (elapsed from T0)
  |
  |-- Poll Grafana HTTP until 200/302 response
  |-- Record T5: Grafana ready (elapsed from T0)
  |
  |-- Poll kubectl get vmi until both VMs show Running
  |-- Record T6: VMs running (elapsed from T0)
  |
  |-- Poll VM HTTP endpoints until both return 200
  |-- Record T7: VM HTTP ready = TOTAL (elapsed from T0)
  |
  |-- PROMPT: "Please run shutdown-cluster.sh and power off"
  |-- Wait 60s
  |
  v
[Generate graphs]
END
```

### What each measurement means

> **Important:** Always power on k3s-master first, press Enter to start
> the timer, then power on both workers 20-30 seconds later. Powering
> all three simultaneously causes workers to fail connecting to master
> and adds inconsistent delays to measurements.

All times are measured from the moment of power-on (T0).

**API server ready** — when the k3s Kubernetes API server is responding. This is the first sign of life from the cluster. Usually 30-60 seconds after power-on.

**All nodes ready** — when all three Pi nodes have joined the cluster and reported healthy. The workers need to connect to master and synchronize. Usually 60-90 seconds.

**Longhorn healthy** — when Longhorn storage is ready to serve volumes. This takes longer because Longhorn needs to reconnect all replicas and verify data integrity. Usually 90-150 seconds.

**Prometheus ready** — when the monitoring system is collecting metrics. Requires Longhorn to be ready (for its persistent storage). Usually 120-180 seconds.

**Grafana ready** — similar to Prometheus, requires storage. Usually shortly after Prometheus.

**VMs running** — when KubeVirt has restarted both VMs. Requires nodes ready and Longhorn healthy. VMs must reconnect their disk volumes and boot. Usually 200-300 seconds.

**VM HTTP ready (TOTAL)** — the final milestone. Cloud-init must complete inside the VMs and the web server must start. This is the true end-to-end time.

### Graphs generated and how to read them

---

**Graph: `05_startup_timeline.png`**

A horizontal bar chart showing the average time from power-on to each milestone, across all 10 runs.

How to read it:
- Each bar represents one milestone
- Bar length = average seconds from power-on to that milestone
- Read from top to bottom: earlier milestones at top, later at bottom
- Error bars show variability across 10 runs

What good results look like:
- API server: 40-70 seconds
- All nodes ready: 70-100 seconds
- Longhorn healthy: 100-160 seconds
- Prometheus/Grafana: 130-180 seconds
- VMs running: 220-310 seconds
- VM HTTP (TOTAL): 250-350 seconds

What it proves for the thesis:
The most visually clear graph for showing startup sequence. Shows which components are the bottleneck (Longhorn and VMs take the longest). Suitable for a "time to operational" comparison in the thesis conclusions.

---

**Graph: `05_startup_total_per_run.png`**

A bar chart showing total startup time for each of the 10 runs, with a red dashed line showing the mean.

How to read it:
- Each bar = one startup run
- Bar height = total seconds from power-on to fully operational
- Secondary Y axis on right shows the same values in minutes
- Red line = average across all runs

What good results look like:
- All bars should be within 20-30% of the mean (consistent)
- Occasional outliers are expected (Longhorn replica sync can vary)
- Mean should be in the 5-7 minute range for this hardware

What it proves for the thesis:
The headline number — "the cluster becomes fully operational in X minutes after a cold power-on". This is directly useful for disaster recovery planning.

---

**Graph: `05_pod_count_growth.png`**

A time series chart showing how many pods are Running, Pending, and total during cluster startup.

How to read it:
- Green fill = Running pods (good, these are working)
- Orange fill = Pending pods (scheduled but not yet started)
- Blue line = total pods
- Watch for: rapid growth phase, then stabilization

What good results look like:
- Starts at 0 pods
- Total pods grows quickly as k3s starts system components
- Pending pods should decrease as Running pods increase
- Should reach final steady state (all pods Running) around the same time as VM HTTP ready

What it proves for the thesis:
Provides a visual story of the cluster coming to life. Shows that Kubernetes is orchestrating the startup sequence automatically — system pods first, then storage, then monitoring, then VMs. This demonstrates the self-organizing nature of Kubernetes.

---

## 9. Generating Graphs

### Setup (one time only)

```bash
pip3 install pandas matplotlib numpy --break-system-packages
```

### Usage

Run from the repo root:

```bash
cd ~/pi-cluster-k3s

python3 experiments/generate_graphs.py \
  --results experiments/results/RESULTS_DIRECTORY_NAME \
  --scenario SCENARIO_NUMBER
```

Find your results directory:

```bash
ls experiments/results/
# Example output:
# 01_ha_recovery_20260417_120000
# 02_live_migration_20260417_140000
```

### Examples

```bash
# Scenario 1 - HA Recovery
python3 experiments/generate_graphs.py \
  --results experiments/results/01_ha_recovery_20260417_120000 \
  --scenario 1

# Scenario 2 - Live Migration
python3 experiments/generate_graphs.py \
  --results experiments/results/02_live_migration_20260417_140000 \
  --scenario 2

# Scenario 3 - Resource Comparison
python3 experiments/generate_graphs.py \
  --results experiments/results/03_resource_comparison_20260417_150000 \
  --scenario 3

# Scenario 4 - VM Spinup
python3 experiments/generate_graphs.py \
  --results experiments/results/04_vm_spinup_20260417_160000 \
  --scenario 4

# Scenario 5 - Cluster Startup
python3 experiments/generate_graphs.py \
  --results experiments/results/05_cluster_startup_20260417_170000 \
  --scenario 5
```

### Output location

Graphs are saved to a `graphs/` subdirectory inside your results folder:

```
experiments/results/01_ha_recovery_20260417_120000/
  graphs/
    01_ha_recovery_time_boxplot.png
    01_ha_recovery_time_per_run.png
    01_ha_http_downtime.png
    01_ha_summary_table.png
```

All graphs are 150 DPI PNG files — ready to insert directly into a Word document or thesis PDF.

---

## 10. Common Issues

### "source: 00_common.sh: file not found"

You are not in the correct directory:
```bash
cd ~/pi-cluster-k3s/experiments/scenarios
```

### "Prometheus not reachable"

```bash
kubectl get pods -n monitoring   # check all Running
kubectl get svc -n monitoring | grep 30091   # check NodePort exists
curl -s http://192.168.1.155:30091/-/healthy   # should return "Prometheus Server is Healthy."
```

### "virtctl not found"

```bash
export PATH=$PATH:/usr/local/bin
echo 'export PATH=$PATH:/usr/local/bin' >> ~/.bashrc
```

### "SSH connection refused to VM"

VM network interface is down. Fix:
```bash
virtctl console ubuntu-vm-1
# Inside VM (login: ubuntu / ubuntu123):
sudo ip link set enp1s0 up
sudo netplan apply
ip addr show enp1s0   # should show 10.0.2.2
```

### "Experiment prerequisites check failed — Prometheus not on k3s-master"

Prometheus is on a worker node. Re-run playbook 04:
```bash
ansible-playbook playbooks/04_monitoring.yml
kubectl get pods -n monitoring -o wide | grep prometheus-0
# Wait until it shows k3s-master
```

### "Experiment prerequisites check failed — VMs on k3s-master"

Delete and let VMs reschedule with the affinity rule:
```bash
kubectl delete vmi ubuntu-vm-1 ubuntu-vm-2
# Wait 30s, then check:
kubectl get vmi -o wide   # both should show worker nodes
```

### "stress-ng: command not found" inside VM

The scenario script installs it automatically. If it fails, install manually:
```bash
ssh -i ~/.ssh/ansible_id -p 30001 ubuntu@192.168.1.155 \
  "sudo apt-get install -y stress-ng"
ssh -i ~/.ssh/ansible_id -p 30002 ubuntu@192.168.1.155 \
  "sudo apt-get install -y stress-ng"
```

### Scenario stuck waiting for a milestone

Press `Ctrl+C` to abort. All results collected up to that point are already saved in the results directory. You can re-run the scenario — it will create a new timestamped results directory.

### Graphs show "No data found"

The results directory structure does not match what the graph script expects. Check that the correct scenario number is passed with `--scenario`. Also verify the results directory contains the expected CSV files:
```bash
ls experiments/results/YOUR_RESULTS_DIR/
```
