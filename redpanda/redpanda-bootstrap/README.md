# Redpanda Bootstrap

Modular orchestrator for managing Redpanda cluster lifecycle operations across **blue/green** environments from a Jenkins job.

A single entry-point script (`redpanda-bootstrap.sh`) receives three Jenkins parameters — **colour**, **cluster name**, and **action** — fetches the instance inventory from S3, and dispatches to the correct sub-function automatically.

---

## Repository Structure

```
redpanda-bootstrap/
├── redpanda-bootstrap.sh          # Jenkins entry-point (run this)
│
├── lib/
│   ├── logging.sh                 # Shared ANSI colour/icon log helpers
│   └── inventory.sh               # S3 inventory fetch + parse helpers
│
└── actions/
   ├── start.sh                   # Start all EC2 instances
   ├── stop.sh                    # Topic backup → stop all EC2 instances
   ├── ping.sh                    # ICMP + SSH connectivity check on all nodes
   ├── disk-mount-tune.sh         # NVMe mount + XFS format + rpk tune (all nodes)
   ├── config-update.sh           # rpk cluster config + topic creation (single node)
   └── restart.sh                 # systemctl restart redpanda (all nodes)
```

---
## S3 Inventory Layout

The orchestrator fetches three inventory files from S3 before every run.

**Bucket:** `s3://redpanda-config/<colour>/<cluster>/`

```
s3://redpanda-config/
├── blue/
│   ├── core/
│   │   ├── inventory.txt     # <instance-id>  <private-ip>  (one per line)
│   │   ├── partition.txt     # partition count per topic     (one per line)
│   │   └── topic.txt         # topic name                   (one per line)
│   ├── ingest/
│   │   └── ...
│   └── analytics/
│       └── ...
└── green/
    ├── core/   ...
    ├── ingest/ ...
    └── analytics/ ...
```

### `inventory.txt` format

```
i-0abc123def456789a  10.0.1.10
i-0abc456def789012b  10.0.1.11
i-0abc789def012345c  10.0.1.12
```

### `topic.txt` / `partition.txt` format

Both files must have the **same number of lines** — each line in `topic.txt` pairs with the corresponding line in `partition.txt`.

```
# topic.txt          # partition.txt
orders               12
payments             6
notifications        3
```

---

## Jenkins Job Setup

### Parameters

| Parameter | Type | Allowed Values |
|-----------|------|----------------|
| `COLOUR` | Choice | `blue`, `green` |
| `CLUSTER_NAME` | Choice | `core`, `ingest`, `analytics` |
| `ACTION` | Choice | `start`, `stop`, `ping`*, `disk-mount-tune`*, `config-update`*, `restart-redpanda`* |

> \* **Note on Actions**: Standalone execution of helper actions (`ping`, `disk-mount-tune`, `config-update`, `restart-redpanda`) is currently commented out in the dispatch block of `redpanda-bootstrap.sh`. Instead, they run sequentially as part of the unified `start` action pipeline.

### Shell Build Step

```bash
COLOUR=${COLOUR} \
CLUSTER_NAME=${CLUSTER_NAME} \
ACTION=${ACTION} \
bash ${WORKSPACE}/redpanda-bootstrap/redpanda-bootstrap.sh
```

### Environment Variables / Jenkins Credentials

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `SSH_USER` | No | `ubuntu` | SSH login user for all nodes |
| `SSH_PORT` | No | `22` | SSH port |
| `GREEN_TRAFFIC` | `stop` only | — | Set to `0` when green-side traffic is fully drained |
| `BLUE_TRAFFIC` | `stop` only | — | Set to `0` when blue-side traffic is fully drained |
| `BACKUP_S3_BUCKET` | `stop` only | — | S3 URI to sync topic backups (e.g. `s3://my-backups/redpanda`) |
| `CORE_PARTITIONS` | No | `77` | `__consumer_offsets` partition count for `core` cluster |
| `INGEST_PARTITIONS` | No | `55` | `__consumer_offsets` partition count for `ingest` cluster |
| `ANALYTICS_PARTITIONS` | No | `16` | `__consumer_offsets` partition count for `analytics` cluster |

> **SSH Key**: Add your private key via the Jenkins SSH Agent plugin or `ssh-add` before the build step. The scripts do not manage SSH keys internally.

---

## Actions Reference

### `start`
Starts all EC2 instances for the selected colour/cluster using instance IDs from `inventory.txt`. Once all instances reach the `running` state, it automatically runs the complete setup and initialization pipeline sequentially:
1. **`ping`** (Connectivity health check across all nodes)
2. **`disk-mount-tune`** (NVMe disk formatting, mounting, and production tuning on all nodes)
3. **`config-update`** (Cluster config application and topic creation on the first node)
4. **`restart-redpanda`** (Redpanda service restart and status validation on all nodes)

```
Reads from inventory: Instance IDs, All IPs, First IP only
AWS calls: ec2 start-instances, ec2 wait instance-running
SSH calls: Formats/mounts NVMe, tunes rpk, updates cluster configs, restarts services
```

---

### `stop`
Full safe-stop sequence:
1. **Traffic guard** — aborts if `GREEN_TRAFFIC` / `BLUE_TRAFFIC` is non-zero (prevents stopping live traffic)
2. **Topic backup** — SSH to the first node, runs `rpk topic list` + `rpk topic describe` for every topic, saves to `/tmp/`
3. **SCP backup** — copies backup files to the Jenkins workspace
4. **S3 sync** — syncs backup to `BACKUP_S3_BUCKET` (if configured)
5. **EC2 stop** — stops all instances and waits for `stopped` state

```
Reads from inventory: instance IDs + first IP
AWS calls: ec2 stop-instances, ec2 wait instance-stopped, s3 sync
```

> ⚠️ **Always set `BLUE_TRAFFIC=0` or `GREEN_TRAFFIC=0` before running stop.**

---

### Standalone Helpers (Run as part of `start`)

The following helper modules are sourced and executed within the `start` pipeline, but their standalone execution dispatch blocks are currently commented out:

#### `ping`
Connectivity health check across all nodes. For each IP in `inventory.txt`:
- ICMP ping (3 packets, 5s timeout) — warns if blocked by security group, does not fail
- SSH check (`echo SSH_OK`) — **fails** if SSH is not reachable

#### `disk-mount-tune`
Runs the NVMe disk initialisation and Redpanda tuning script on **every node**:
1. SCP `disk-mounting-tune/script.sh` to the node
2. Execute via `sudo bash` (requires root/sudo)
3. Script: detects NVMe instance storage → formats as XFS → mounts to `/mnt/vectorized` → sets ownership → runs `rpk redpanda mode prod` + `rpk redpanda tune all`

#### `config-update`
Applies cluster configuration and recreates all topics on the **first node** only:
1. SCP `topic.txt` and `partition.txt` to node `/tmp/`
2. SSH: apply `rpk cluster config set` settings (idempotent)
3. SSH: create `__consumer_offsets` with correct partition count
4. SSH: recreate all application topics from `topic.txt` / `partition.txt`

#### `restart-redpanda`
Restarts the Redpanda service on **every node** via SSH:
1. `sudo systemctl restart redpanda`
2. Polls `systemctl is-active redpanda` every 5 seconds for up to 60 seconds
3. Fails the build if any node does not become active

---

## Action × Inventory Mapping

| Action | Instance IDs | All IPs | First IP only | Sourced Helper Actions |
|--------|:---:|:---:|:---:|---|
| `start` | ✅ | ✅ | ✅ | Runs `ping` → `disk-mount-tune` → `config-update` → `restart-redpanda` |
| `stop` | ✅ | | ✅ (backup) | None |

---

## Execution Sequence

When starting/deploying a cluster, run:
```
start (automatically runs: ping → disk-mount-tune → config-update → restart-redpanda)
```

Run `stop` only after traffic has been fully drained.

---

## Local Usage (without Jenkins)

```bash
# Set required parameters as env vars
export COLOUR=blue
export CLUSTER_NAME=core
export ACTION=start

# Optional overrides
export SSH_USER=ubuntu
export SSH_PORT=22

# Run
bash redpanda-bootstrap.sh
```

Positional args are also supported as a fallback:

```bash
bash redpanda-bootstrap.sh blue core start
```

---

## Dependencies

| Tool | Used by |
|------|---------|
| `aws` CLI | Inventory fetch, EC2 start/stop, S3 sync |
| `ssh` / `scp` | All SSH actions |
| `rpk` | Installed on Redpanda nodes; invoked remotely |
| `nvme` CLI | On Redpanda nodes; used by `disk-mount-tune` |
| `jq` | On Redpanda nodes; used by `stop` topic backup |
| `bash` ≥ 4.0 | `mapfile`, `${var,,}` lowercase expansion |
