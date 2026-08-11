# Redpanda Production Reinstallation Runbook

This runbook outlines the step-by-step process for performing a clean reinstallation of Redpanda on production servers. Use this document when a full recreation of the Redpanda service is required.

> [!WARNING]
> This procedure will **PURGE** all existing Redpanda data, topics, and local configurations. Ensure you have successfully completed all backup steps before proceeding to the teardown phase.

---

## Pre-Reinstallation Checklist
- [ ] Active backup of all topic structures and partition counts.
- [ ] Backup of current node-specific `redpanda.yaml` config.
- [ ] Clean environment variables (e.g., target version, cluster ID).

---

## Step-by-Step Reinstallation Procedure

### Phase 1: Pre-Requisites & Backups

#### Step 1: Backup Topics & Partition Configurations
Run the backup script located in your DevOps script repository to capture the current state of all Kafka/Redpanda topics and partition counts.

```bash
# Navigate to your devops script directory and run:
./recreate.sh
```

> [!TIP]
> If you encounter a script execution error due to Windows carriage returns (`\r\n`), sanitize the script file line endings by running:
> ```bash
> sed -i 's/\r$//' recreator.sh
> ```

#### Step 2: Backup the Current Redpanda Configuration
Safeguard the node-specific configuration file (`redpanda.yaml`) before deleting the installation.

```bash
# Create a backup directory and copy the configuration
mkdir -p backup && cp -r /etc/redpanda/redpanda.yaml backup/redpanda.yaml
```

---

### Phase 2: Teardown & Purge

#### Step 3: Stop the Redpanda Service
Gracefully shut down the Redpanda daemon.

```bash
sudo systemctl stop redpanda
```

#### Step 4: Remove Redpanda Packages
Purge all installed Redpanda-related packages from the server.

```bash
sudo apt-get purge -y redpanda*
```
if redpanda in hold, unhold it first

```bash
sudo apt-mark unhold redpanda*
```

#### Step 5: Clean Up Redpanda Directories
Delete all data, configuration, and storage mounts associated with the previous Redpanda installation.

> [!CAUTION]
> This operation is destructive and cannot be undone. Double-check your backups.

```bash
sudo rm -rf /var/lib/redpanda && \
sudo rm -rf /etc/redpanda && \
sudo rm -rf /mnt/vectorized/*
```

---

### Phase 3: Installation & Initial Setup

#### Step 6: Install Redpanda
Configure the official Redpanda repository and install the packages.

**Option A: Install the Latest Version**
```bash
curl -1sLf 'https://dl.redpanda.com/public/redpanda/setup.deb.sh' | sudo -E bash
sudo apt-get install -y redpanda
```

**Option B: Install a Specific Version (Recommended for Production Consistency)**
To prevent version mismatches across the cluster, install explicit versions (e.g., `25.3.14*`):
```bash
sudo apt-get install -y redpanda=25.3.14* redpanda-tuner=25.3.14* redpanda-rpk=25.3.14*
```

> [!NOTE]
> To prevent unintended automatic package upgrades during system-wide updates, hold the package:
> ```bash
> sudo apt-mark hold redpanda
> ```

#### Step 7: Restore or Bootstrapping Configuration

**Scenario A: Restore Existing Config (Standard)**
If you successfully backed up `redpanda.yaml` in **Step 2**:
```bash
sudo cp backup/redpanda.yaml /etc/redpanda/redpanda.yaml
```

**Scenario B: Bootstrap New Config (If Backup is Missing/Corrupted)**
If the config file is missing, bootstrap a new configuration:
```bash
rpk redpanda config bootstrap --self <node_ip> --ips <seed_node_ips>
```
*After bootstrapping, manually update `redpanda.yaml` to include rack details and set the data directory path to `/mnt/vectorized`.*

#### Step 8: Tune Redpanda for Production
Run Redpanda tuners to optimize the server for production workloads.

```bash
sudo rpk redpanda mode prod
sudo rpk redpanda tune all -r /mnt/vectorized
```

---
#### Step 9: Start the Redpanda Service
Start the Redpanda systemd daemon.

```bash
sudo systemctl start redpanda
```


### Phase 4: Cluster-Wide Configuration

#### Step 10: Configure Custom Cluster Settings
Once the configuration is restored, apply cluster-wide settings via the Redpanda Keeper (`rpk`) tool:

```bash
# 1. Enable auto-creation of topics (if required) and disable legacy idempotence settings
rpk cluster config set auto_create_topics_enabled true
rpk cluster config set enable_idempotence false

# 2. Set default replication and partitions
rpk cluster config set default_topic_replications 3
rpk cluster config set default_topic_partitions 3

# 3. Configure log retention policies (3 days = 259,200,000 ms)
rpk cluster config set delete_retention_ms 259200000
rpk cluster config set log_segment_ms 259200000

# 4. Enable rack awareness for high availability
rpk cluster config set enable_rack_awareness true

# 5. Pre-create critical diagnostic/validation topics
rpk topic create producer_validation_events --replicas 3 --partitions 3
```

**Single-line command for quick copy-paste execution:**

```bash
rpk cluster config set auto_create_topics_enabled true && rpk cluster config set enable_idempotence false && rpk cluster config set default_topic_replications 3 && rpk cluster config set default_topic_partitions 3 && rpk cluster config set delete_retention_ms 259200000 && rpk cluster config set log_segment_ms 259200000 && rpk cluster config set enable_rack_awareness true && rpk topic create producer_validation_events --replicas 3 --partitions 3
```


#### Step 10: Set the Cluster ID
Apply the designated environment/cluster identifier (e.g., your control plane or environment name):

```bash
rpk cluster config set cluster_id <color_plane>
```

---

### Phase 5: Restart & Verify Redpanda

#### Step 11: Restart Redpanda

```bash
sudo systemctl restart redpanda
```

#### Step 12: Verify Cluster Status & Health
Ensure that the node is running properly and has successfully joined/formed the cluster.

```bash
# Check service status
sudo systemctl status redpanda

# Verify cluster nodes and connectivity
rpk cluster status

# Inspect cluster health
rpk cluster health
```

---

### Phase 6: Topic Recreation & Special Topic Configurations

#### Step 13: Recreate All Topics
Use the backup script to recreate all topics and partition mappings captured in **Step 1**:

```bash
# Navigate to the devops script directory and run:
./recreator.sh
```

Confirm that the topics were created successfully:
```bash
rpk topic list
```

#### Step 14: Tune Protected Special Topics (`__consumer_offsets`)
By default, internal topics like `__consumer_offsets` and `_schemas` are protected and cannot be deleted or modified. To adjust their retention policies:

1. **Check current protected topics:**
   ```bash
   rpk cluster config get kafka_nodelete_topics
   ```

2. **Temporarily unlock protected topics:**
   ```bash
   rpk cluster config set kafka_nodelete_topics '[]'
   ```

3. **Update configurations (set retention to 20 days = 1728000000 ms):**
   *You can do this directly via CLI (Recommended) or through the Redpanda Console UI:*
   
   **Via RPK CLI:**
   ```bash
   rpk topic alter-config __consumer_offsets --set retention.ms=1728000000 --set segment.ms=1728000000
   ```
   
   **Via Console UI:**
   Navigate to the `__consumer_offsets` topic configuration in the browser frontend, and update `retention.ms` and `segment.ms` to `1728000000`.

4. **To adjust the partition count use this command**
   ```bash
   rpk topic add-partitions __consumer_offset -n <number>> --force
   ```
   where `<number>` is the additional number of partion to be added
   *For Current Setup:*
   ```
   27 for ingest cluster
   16 (no change) for the Analytics cluster
   77 for core
   ```

5. **Restore protection settings:**
   ```bash
   rpk cluster config set kafka_nodelete_topics '["__consumer_offsets", "_schemas"]'
   ```


---

## Troubleshooting & Maintenance Tips

- **Check Logs in Real-time:**
  ```bash
  journalctl -u redpanda -f
  ```
- **Vacuum Logs (If system storage is low):**
  ```bash
  sudo journalctl --vacuum-size=500M
  ```
- **Toggle Maintenance Mode:**
  If a node needs temporary offline updates without disrupting the cluster:
  ```bash
  # Enable
  rpk cluster maintenance enable <node_id> --wait
  # Disable
  rpk cluster maintenance disable <node_id>
  ```


