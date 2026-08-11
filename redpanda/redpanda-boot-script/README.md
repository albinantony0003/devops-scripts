# Redpanda Cluster Bootstrap Orchestrator

This script automates the bootstrapping of Redpanda configurations and topic creation for specific environments (`core`, `ingest`, or `analytics`) from a Jenkins job.

---

## Features

- **Dynamic Environment Selection**: Select between `core`, `ingest`, and `analytics` clusters.
- **Auto Directory Navigation**: Automatically creates and navigates to the folder corresponding to the selected cluster name.
- **Partition & Topic File Upload**: Each cluster subfolder (`core/`, `ingest/`, `analytics/`) has its own `topic_names.txt` and `partition_counts.txt`. The script switches into the selected cluster's folder first, then copies those files to the remote node via SCP.
- **Internal Topic Configuration**: Automatically creates/tunes the internal `__consumer_offsets` topic on the remote node with partitions mapping directly to the environment:
  - **`core`**: 77 partitions
  - **`ingest`**: 55 partitions
  - **`analytics`**: 16 partitions
- **Bulk Topic Creation**: Runs `recreate_topics` on the remote cluster node to read `topic_names.txt` and `partition_counts.txt` line-by-line and create the topics with corresponding partition counts.

---

## Directory Structure

Each cluster has its **own dedicated subfolder** containing a separate set of `topic_names.txt` and `partition_counts.txt` files. When the script runs, it switches into the folder matching the selected cluster before performing the SCP transfer, so the correct cluster-specific files are always used.

```text
devops-tools/
└── redpanda-boot-script/
    ├── script.sh
    ├── core/               ← used when CLUSTER_NAME=core
    │   ├── topic_names.txt
    │   └── partition_counts.txt
    ├── ingest/             ← used when CLUSTER_NAME=ingest
    │   ├── topic_names.txt
    │   └── partition_counts.txt
    └── analytics/          ← used when CLUSTER_NAME=analytics
        ├── topic_names.txt
        └── partition_counts.txt
```

> **Important**: The files in each cluster folder are independent. You must maintain separate `topic_names.txt` and `partition_counts.txt` per cluster, since topic names and partition counts differ across environments.

---

## File Formats

Both files must have the same number of lines (one topic/partition count per line).

### `topic_names.txt`
```text
clickstream_events
user_login_events
transaction_logs
```

### `partition_counts.txt`
```text
12
6
24
```

---

## Configuration Variables

You can configure target hosts and override default topic behaviors using the following environment variables:

| Variable | Default Value | Description |
| :--- | :--- | :--- |
| `CLUSTER_NAME` | *(None)* | The target cluster selection. Can also be passed as the first CLI argument (`$1`). |
| `SSH_USER` | `ubuntu` | SSH username to connect to remote nodes. |
| `SSH_PORT` | `22` | Port to use for SSH and SCP operations. |
| `CORE_NODE` | *(None)* | Hostname/IP address of a node in the **Core** cluster. |
| `INGEST_NODE` | *(None)* | Hostname/IP address of a node in the **Ingest** cluster. |
| `ANALYTICS_NODE` | *(None)* | Hostname/IP address of a node in the **Analytics** cluster. |
| `CORE_PARTITIONS` | `77` | Partition count to set for `__consumer_offsets` on core cluster. |
| `INGEST_PARTITIONS` | `55` | Partition count to set for `__consumer_offsets` on ingest cluster. |
| `ANALYTICS_PARTITIONS` | `16` | Partition count to set for `__consumer_offsets` on analytics cluster. |

---

## Jenkins Job Integration

### Choice Parameter Setup

Add a **Choice Parameter** to the Jenkins Job:
- **Name**: `CLUSTER_NAME`
- **Choices**:
  - `core`
  - `ingest`
  - `analytics`

### Pipeline Step Example

Use the pipeline script below to trigger the bootstrap:

```groovy
pipeline {
    agent any
    environment {
        // Set target node IPs/Hostnames
        CORE_NODE      = '10.100.1.15'
        INGEST_NODE    = '10.100.2.15'
        ANALYTICS_NODE = '10.100.3.15'
    }
    stages {
        stage('Bootstrap Redpanda Topics') {
            steps {
                sh "chmod +x redpanda-boot-script/script.sh"
                sh "./redpanda-boot-script/script.sh ${params.CLUSTER_NAME}"
            }
        }
    }
}
```

---

## Execution Check & Troubleshooting

If you need to run syntax checks or perform test runs locally:

1. **Syntax Check**:
   ```bash
   bash -n redpanda-boot-script/script.sh
   ```

2. **Verify Variable Resolution**:
   ```bash
   CLUSTER_NAME=core CORE_NODE=127.0.0.1 bash redpanda-boot-script/script.sh
   ```
