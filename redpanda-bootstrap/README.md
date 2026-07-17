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
├── actions/
│   ├── start.sh                   # Start all EC2 instances
│   ├── stop.sh                    # Topic backup → stop all EC2 instances
│   ├── ping.sh                    # ICMP + SSH connectivity check on all nodes
│   ├── disk-mount-tune.sh         # NVMe mount + XFS format + rpk tune (all nodes)
│   ├── config-update.sh           # rpk cluster config + topic creation (single node)
│   └── restart.sh                 # systemctl restart redpanda (all nodes)
│
├── ec2-instance-start/            # Legacy standalone script (reference only)
├── ec2-instance-stop/             # Legacy standalone script (reference only)
├── disk-mounting-tune/            # Legacy standalone script (reference only)
├── config-update/                 # Legacy standalone script (reference only)
├── redpanda-restart/              # Legacy standalone script (reference only)
└── topic-backup/                  # Legacy standalone script (reference only)
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
| `ACTION` | Choice | `start`, `stop`, `ping`, `disk-mount-tune`, `config-update`, `restart-redpanda` |

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
Starts all EC2 instances for the selected colour/cluster using instance IDs from `inventory.txt`. Waits until all instances reach the `running` state.

```
Reads from inventory: instance IDs (column 1)
AWS calls: ec2 start-instances, ec2 wait instance-running
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

### `ping`
Connectivity health check across all nodes. For each IP in `inventory.txt`:
- ICMP ping (3 packets, 5s timeout) — warns if blocked by security group, does not fail
- SSH check (`echo SSH_OK`) — **fails** if SSH is not reachable

Prints a per-node summary table at the end.

```
Reads from inventory: all IPs (column 2)
```

---

### `disk-mount-tune`
Runs the NVMe disk initialisation and Redpanda tuning script on **every node**:
1. SCP `disk-mounting-tune/script.sh` to the node
2. Execute via `sudo bash` (requires root/sudo)
3. Script: detects NVMe instance storage → formats as XFS → mounts to `/mnt/vectorized` → sets ownership → runs `rpk redpanda mode prod` + `rpk redpanda tune all`

```
Reads from inventory: all IPs
Requires: sudo on target nodes
```

---

### `config-update`
Applies cluster configuration and recreates all topics on the **first node** only:
1. SCP `topic.txt` and `partition.txt` to node `/tmp/`
2. SSH: apply `rpk cluster config set` settings (idempotent)
3. SSH: create `__consumer_offsets` with correct partition count
4. SSH: recreate all application topics from `topic.txt` / `partition.txt`

```
Reads from inventory: first IP only + topic.txt + partition.txt
```

---

### `restart-redpanda`
Restarts the Redpanda service on **every node** via SSH:
1. `sudo systemctl restart redpanda`
2. Polls `systemctl is-active redpanda` every 5 seconds for up to 60 seconds
3. Fails the build if any node does not become active

```
Reads from inventory: all IPs
```

---

## Action × Inventory Mapping

| Action | Instance IDs | All IPs | First IP only |
|--------|:---:|:---:|:---:|
| `start` | ✅ | | |
| `stop` | ✅ | | ✅ (backup) |
| `ping` | | ✅ | |
| `disk-mount-tune` | | ✅ | |
| `config-update` | | | ✅ |
| `restart-redpanda` | | ✅ | |

---

## Recommended Validation Order

When deploying a new cluster for the first time, run actions in this order:

```
ping  →  disk-mount-tune  →  config-update  →  restart-redpanda  →  start
```

Run `stop` only after traffic has been fully drained.

---

## Local Usage (without Jenkins)

```bash
# Set required parameters as env vars
export COLOUR=blue
export CLUSTER_NAME=core
export ACTION=ping

# Optional overrides
export SSH_USER=ubuntu
export SSH_PORT=22

# Run
bash redpanda-bootstrap.sh
```

Positional args are also supported as a fallback:

```bash
bash redpanda-bootstrap.sh blue core ping
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
