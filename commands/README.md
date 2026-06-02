# Redpanda Commands

This folder contains documentation and details for commonly used [Redpanda](https://redpanda.com/) administration and troubleshooting commands.

---

## Installation & Upgrade

### Setup Redpanda Repository (Debian/Ubuntu)
Configures the Redpanda repository on Debian/Ubuntu systems to allow package installations and updates.

```bash
curl -1sLf 'https://dl.redpanda.com/public/redpanda/setup.deb.sh' | sudo -E bash
```

### Install Specific Redpanda Version
Installs the Redpanda broker, tuner, and rpk CLI utility at a specific version (e.g., `25.3.14*`) using the `apt` package manager.

```bash
sudo apt-get install -y redpanda=25.3.14*  redpanda-tuner=25.3.14*  redpanda-rpk=25.3.14*
```

### Install Specific Redpanda Version with Downgrades Allowed
Installs the Redpanda broker, tuner, and rpk CLI utility at a specific version, allowing downgrades if a newer version is currently installed.

```bash
sudo apt-get install --allow-downgrades -y redpanda=25.3.14* redpanda-tuner=25.3.14* redpanda-rpk=25.3.14*
```

### View Held Packages
Lists all packages on the system that are currently set to "hold" (prevented from being automatically installed, upgraded, or removed).

```bash
apt-mark showhold
```

### Hold Redpanda Package
Sets the Redpanda package to "hold" to prevent it from being automatically upgraded during system updates.

```bash
sudo apt-mark hold redpanda
```

### Unhold Redpanda Package
Removes the "hold" flag from the Redpanda package, allowing it to be upgraded during future system updates.

```bash
sudo apt-mark unhold redpanda
```

---

## Service Management

### Restart Redpanda Service
Restarts the Redpanda systemd service on the host machine. This is typically used after modifying cluster or node configurations, or to recover the service.

```bash
sudo systemctl restart redpanda
```

---

## Cluster Health & Status

Redpanda provides the `rpk` (Redpanda Keeper) command-line tool to interact with the cluster.

### Check Cluster Status
Displays the state of all nodes in the cluster, including their IDs, internal/external IP addresses, and overall status.

```bash
rpk cluster status
```

### Check Cluster Health
Provides a summary of the cluster's health. This includes critical metrics like leaderless partitions, under-replicated partitions, and node connectivity.

```bash
rpk cluster health
```

---

## Cluster Maintenance

### Check Cluster Maintenance Status
Checks the current maintenance mode status of all nodes in the cluster.

```bash
rpk cluster maintenance status
```

### Enable Maintenance Mode on a Node
Enables maintenance mode on a specific node (e.g., node ID `5`) and waits for the data to migrate safely off the node before continuing.

```bash
rpk cluster maintenance enable 5 --wait
```

### Disable Maintenance Mode on a Node
Disables maintenance mode on a specific node (e.g., node ID `0`), returning it to normal cluster participation.

```bash
rpk cluster maintenance disable 0
```

---

## Cluster Configuration

### Disable Unsafe Log Operations
Configures the cluster to disallow legacy unsafe log operations.

```bash
rpk cluster config set legacy_permit_unsafe_log_operation false
```

### Check Unsafe Log Operations Status
Retrieves the current setting for legacy unsafe log operations.

```bash
rpk cluster config get legacy_permit_unsafe_log_operation
```

---

## Log Management

### Vacuum Systemd Journal Logs
Cleans up the systemd journal logs to free up disk space, keeping only the most recent logs up to a size of 500MB.

```bash
sudo journalctl --vacuum-size=500M
```

### Clear Fluent Bit Buffer
Clears the Fluent Bit buffer files to free up disk space or resolve buffering issues.

```bash
sudo rm -rf /var/log/fluent-bit/buffer/*
```

---

## Network Utilities

### Check External IPv4 Address
Retrieves the external IPv4 address of the host machine using `ifconfig.me`.

```bash
curl -4 ifconfig.me
```

### Check External IPv6 Address
Retrieves the external IPv6 address of the host machine using `ifconfig.me`.

```bash
curl -6 ifconfig.me
```

---

## Kubernetes & Karpenter

### Get EC2NodeClass AMI Selector Alias
Retrieves all Karpenter `EC2NodeClass` resources and outputs their names along with the configured AMI selector alias (e.g., `al2023`, `bottlerocket`, or custom AMI tags/versions like `v20260520`).

```bash
kubectl get ec2nodeclass -o jsonpath="{range .items[*]}{.metadata.name}{': '}{.spec.amiSelectorTerms[0].alias}{'\n'}{end}"
```
