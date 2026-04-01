# Kubernetes on Proxmox LXC — Full Automation Guide

> **Terraform + Ansible** | Dynamic IPs & Container IDs | Scalable to N masters + N workers

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Prerequisites](#prerequisites)
3. [Project Structure](#project-structure)
4. [How It Works (Pipeline)](#how-it-works-pipeline)
5. [Terraform — Infrastructure Layer](#terraform--infrastructure-layer)
   - [Provider Setup (Proxmox API Token)](#provider-setup-proxmox-api-token)
   - [variables.tf](#variablestf)
   - [main.tf](#maintf)
   - [outputs.tf](#outputstf)
   - [terraform.tfvars.example](#terraformtfvarsexample)
6. [Ansible — Configuration Layer](#ansible--configuration-layer)
   - [Inventory Generator (gen_inventory.py)](#inventory-generator-gen_inventorypy)
   - [group_vars/all.yml](#group_varsallyml)
   - [roles/common/tasks/main.yml](#rolescommontasksmain.yml)
   - [roles/master/tasks/main.yml](#rolesmastertasksmain.yml)
   - [roles/worker/tasks/main.yml](#rolesworkertasksmain.yml)
   - [site.yml](#siteyml)
   - [ansible.cfg](#ansiblecfg)
7. [End-to-End Wrapper (deploy.sh)](#end-to-end-wrapper-deploysh)
8. [Scaling the Cluster](#scaling-the-cluster)
9. [Teardown](#teardown)
10. [Troubleshooting](#troubleshooting)
11. [Design Decisions & Industry Standards Applied](#design-decisions--industry-standards-applied)

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────┐
│  Your workstation (runs Terraform + Ansible)        │
│                                                     │
│  terraform apply  ──►  Proxmox API                  │
│                           │                         │
│                    creates LXC containers           │
│                    patches lxc.conf                 │
│                    starts containers                │
│                           │                         │
│  ansible-playbook ──►  SSH into each container      │
│                    installs containerd, kubeadm     │
│                    kubeadm init  (master)           │
│                    kubeadm join  (workers)          │
│                    deploys Calico CNI               │
│                    fixes kube-proxy for LXC         │
└─────────────────────────────────────────────────────┘

Dynamic allocation:
  Container IDs  →  var.master_id_start + index   (e.g. 200, 201, 202)
  IP addresses   →  var.master_ip_base + (var.master_ip_start + index)
  Hostnames      →  k8s-master-0, k8s-master-1, k8s-worker-0, k8s-worker-1 ...
```

Scaling is a single `terraform.tfvars` change:

```hcl
master_count = 1   # → change to 3 for HA control plane
worker_count = 2   # → change to 5, 10, etc.
```

---

## Prerequisites

### On your workstation

| Tool | Version | Install |
|------|---------|---------|
| Terraform | ≥ 1.5 | https://developer.hashicorp.com/terraform/install |
| Ansible | ≥ 2.15 | `pip install ansible` |
| Python | ≥ 3.9 | system package |
| sshpass | any | `apt install sshpass` or `brew install sshpass` |

```bash
# Install Ansible collections needed by the playbook
ansible-galaxy collection install ansible.posix community.general
```

### On the Proxmox host

Run this once to load kernel modules and set sysctl params on the **PVE host** (not inside containers):

```bash
# Load kernel modules
modprobe ip_tables ip6_tables nf_nat overlay br_netfilter

# Persist across reboots
cat << 'EOF' > /etc/modules-load.d/k8s.conf
ip_tables
ip6_tables
nf_nat
overlay
br_netfilter
EOF

# Sysctl
cat << 'EOF' > /etc/sysctl.d/k8s.conf
net.netfilter.nf_conntrack_max=524288
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
net.ipv4.ip_forward=1
EOF
sysctl -p /etc/sysctl.d/k8s.conf

# Download Ubuntu template if not already present
pveam update
pveam download local ubuntu-25.04-standard_25.04-1.1_amd64.tar.zst
```

### Create a Proxmox API token for Terraform

```bash
# On the Proxmox host
pveum user add terraform@pve
pveum aclmod / -user terraform@pve -role PVEAdmin
pveum user token add terraform@pve terraform --privsep 0
# Copy the token secret shown — you will never see it again
```

---

## Project Structure

```
k8s-proxmox-automation/
├── deploy.sh                        # One-shot wrapper: Terraform → Ansible
├── .gitignore
│
├── terraform/
│   ├── main.tf                      # LXC container resources (dynamic)
│   ├── variables.tf                 # All tuneable parameters
│   ├── outputs.tf                   # Exports IPs/hostnames for Ansible
│   └── terraform.tfvars.example     # Copy → terraform.tfvars and fill in
│
└── ansible/
    ├── ansible.cfg                  # SSH tuning, inventory path
    ├── site.yml                     # Master playbook (4 plays)
    ├── scripts/
    │   └── gen_inventory.py         # Generates hosts.ini from tf output
    ├── inventory/
    │   ├── hosts.ini                # Auto-generated — do not edit
    │   └── hosts.yml                # Auto-generated YAML form
    ├── group_vars/
    │   └── all.yml                  # Shared vars (k8s version, CIDR, etc.)
    └── roles/
        ├── common/tasks/main.yml    # Bootstrap: containerd, kubeadm, ssh
        ├── master/tasks/main.yml    # kubeadm init, Calico, kube-proxy fix
        └── worker/tasks/main.yml    # kubeadm join
```

---

## How It Works (Pipeline)

```
Step 1  terraform init && terraform apply
        └─► creates LXC containers with dynamic IDs and IPs
        └─► patches /etc/pve/lxc/<id>.conf with k8s LXC directives
        └─► starts containers, waits 10s for boot

Step 2  python3 scripts/gen_inventory.py
        └─► reads `terraform output -json`
        └─► writes ansible/inventory/hosts.ini and hosts.yml

Step 3  ansible-playbook site.yml
        Play 1 — [all nodes]   common role   → containerd, kubeadm, ssh
        Play 2 — [masters]     master role   → kubeadm init, Calico, kube-proxy patch
        Play 3 — [workers]     worker role   → kubeadm join
        Play 4 — [master-0]    verify        → wait for Ready nodes, show status
```

All four steps are automated by `deploy.sh`.

---

## Terraform — Infrastructure Layer

### Provider Setup (Proxmox API Token)

The `bpg/proxmox` provider is used (most actively maintained, supports LXC fully).

```hcl
# terraform/main.tf (excerpt)
provider "proxmox" {
  endpoint  = var.proxmox_api_url                               # https://pve-host:8006/api2/json
  api_token = "${var.proxmox_api_token_id}=${var.proxmox_api_token_secret}"
  insecure  = true   # set false if your PVE has a valid TLS cert
}
```

### variables.tf

```hcl
# terraform/variables.tf

# ── Proxmox connection ──────────────────────────────────────
variable "proxmox_api_url"          { type = string }
variable "proxmox_api_token_id"     { type = string }
variable "proxmox_api_token_secret" { type = string; sensitive = true }
variable "proxmox_node"             { type = string; default = "pve" }

# ── LXC template ───────────────────────────────────────────
variable "lxc_template"  { type = string; default = "local:vztmpl/ubuntu-25.04-standard_25.04-1.1_amd64.tar.zst" }
variable "storage_pool"  { type = string; default = "local-lvm" }

# ── Network ────────────────────────────────────────────────
variable "network_bridge"      { type = string; default = "vmbr0" }
variable "network_gateway"     { type = string; default = "192.168.1.1" }
variable "network_cidr_prefix" { type = number; default = 24 }
variable "dns_server"          { type = string; default = "8.8.8.8" }

# ── Master nodes ───────────────────────────────────────────
variable "master_count"    { type = number; default = 1 }     # ← dynamic count
variable "master_id_start" { type = number; default = 200 }   # ← dynamic IDs
variable "master_ip_base"  { type = string; default = "192.168.1" }
variable "master_ip_start" { type = number; default = 30 }    # ← dynamic IPs
variable "master_cores"    { type = number; default = 2 }
variable "master_memory"   { type = number; default = 4096 }
variable "master_disk_size"{ type = number; default = 30 }

# ── Worker nodes ───────────────────────────────────────────
variable "worker_count"    { type = number; default = 2 }
variable "worker_id_start" { type = number; default = 210 }
variable "worker_ip_base"  { type = string; default = "192.168.1" }
variable "worker_ip_start" { type = number; default = 40 }
variable "worker_cores"    { type = number; default = 2 }
variable "worker_memory"   { type = number; default = 4096 }
variable "worker_disk_size"{ type = number; default = 30 }

# ── Kubernetes ─────────────────────────────────────────────
variable "k8s_version"      { type = string; default = "1.31" }
variable "pod_network_cidr" { type = string; default = "10.244.0.0/16" }
variable "calico_version"   { type = string; default = "3.28.2" }

# ── Access ─────────────────────────────────────────────────
variable "root_password"   { type = string; sensitive = true }
variable "ssh_public_key"  { type = string; default = "" }
```

### main.tf

Key design: `for_each` on a computed map means IDs/IPs are derived from variables — never hardcoded.

```hcl
# terraform/main.tf (key excerpts)

locals {
  masters = {
    for i in range(var.master_count) :
    "k8s-master-${i}" => {
      vm_id    = var.master_id_start + i               # 200, 201, 202 ...
      ip       = "${var.master_ip_base}.${var.master_ip_start + i}"  # .30, .31 ...
      hostname = "k8s-master-${i}"
    }
  }
  workers = {
    for i in range(var.worker_count) :
    "k8s-worker-${i}" => {
      vm_id    = var.worker_id_start + i               # 210, 211, 212 ...
      ip       = "${var.worker_ip_base}.${var.worker_ip_start + i}"  # .40, .41 ...
      hostname = "k8s-worker-${i}"
    }
  }
}

resource "proxmox_virtual_environment_container" "master" {
  for_each     = local.masters
  node_name    = var.proxmox_node
  vm_id        = each.value.vm_id
  unprivileged = false          # MUST be privileged for Kubernetes

  initialization {
    hostname = each.value.hostname
    ip_config {
      ipv4 {
        address = "${each.value.ip}/${var.network_cidr_prefix}"
        gateway = var.network_gateway
      }
    }
    user_account {
      password = var.root_password
      keys     = var.ssh_public_key != "" ? [var.ssh_public_key] : []
    }
  }
  # ... cpu, memory, disk, network_interface, features ...
}
```

The `null_resource.patch_*_lxc_config` resources SSH into the Proxmox host after container creation to append the required `lxc.*` directives that the API provider cannot yet set natively:

```hcl
resource "null_resource" "patch_master_lxc_config" {
  for_each   = local.masters
  depends_on = [proxmox_virtual_environment_container.master]

  connection {
    type     = "ssh"
    host     = regex("https?://([^:]+):", var.proxmox_api_url)[0]
    user     = "root"
    password = var.root_password
  }

  provisioner "remote-exec" {
    inline = [
      "pct stop ${each.value.vm_id} || true",
      "sed -i '/^lxc\\./d' /etc/pve/lxc/${each.value.vm_id}.conf",
      "echo 'lxc.apparmor.profile: unconfined' >> /etc/pve/lxc/${each.value.vm_id}.conf",
      "echo 'lxc.cap.drop:' >> /etc/pve/lxc/${each.value.vm_id}.conf",
      "echo 'lxc.cgroup2.devices.allow: a' >> /etc/pve/lxc/${each.value.vm_id}.conf",
      "echo 'lxc.mount.auto: proc:rw sys:rw cgroup:rw' >> /etc/pve/lxc/${each.value.vm_id}.conf",
      "echo 'lxc.mount.entry: /dev/kmsg dev/kmsg none bind,create=file' >> /etc/pve/lxc/${each.value.vm_id}.conf",
      "pct start ${each.value.vm_id}",
      "sleep 10",
    ]
  }
}
```

### outputs.tf

```hcl
# terraform/outputs.tf
output "master_nodes" {
  value = { for k, v in local.masters : k => { ip = v.ip, hostname = v.hostname, vm_id = v.vm_id } }
}
output "worker_nodes" {
  value = { for k, v in local.workers : k => { ip = v.ip, hostname = v.hostname, vm_id = v.vm_id } }
}
output "primary_master_ip" {
  value = "${var.master_ip_base}.${var.master_ip_start}"
}
```

### terraform.tfvars.example

```hcl
# Copy to terraform.tfvars — never commit this file (it is gitignored)

proxmox_api_url          = "https://192.168.1.10:8006/api2/json"
proxmox_api_token_id     = "root@pam!terraform"
proxmox_api_token_secret = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
proxmox_node             = "pve"

lxc_template = "local:vztmpl/ubuntu-25.04-standard_25.04-1.1_amd64.tar.zst"
storage_pool = "local-lvm"

network_bridge      = "vmbr0"
network_gateway     = "192.168.1.1"
network_cidr_prefix = 24
dns_server          = "192.168.1.1"

master_count    = 1        # set 3 for HA
master_id_start = 200
master_ip_base  = "192.168.1"
master_ip_start = 30
master_cores    = 2
master_memory   = 4096
master_disk_size = 30

worker_count    = 2
worker_id_start = 210
worker_ip_base  = "192.168.1"
worker_ip_start = 40
worker_cores    = 2
worker_memory   = 4096
worker_disk_size = 30

k8s_version      = "1.31"
pod_network_cidr = "10.244.0.0/16"
calico_version   = "3.28.2"

root_password  = "KubeAdmin@2024!"
ssh_public_key = "ssh-ed25519 AAAA... you@host"
```

---

## Ansible — Configuration Layer

### Inventory Generator (gen_inventory.py)

Reads Terraform's JSON output and emits `hosts.ini` and `hosts.yml` automatically.

```bash
# Run after terraform apply
cd ansible/
terraform -chdir=../terraform output -json | python3 scripts/gen_inventory.py
```

Example generated `hosts.ini`:

```ini
# Auto-generated by gen_inventory.py — do not edit by hand

[masters]
k8s-master-0  ansible_host=192.168.1.30  ansible_user=root

[workers]
k8s-worker-0  ansible_host=192.168.1.40  ansible_user=root
k8s-worker-1  ansible_host=192.168.1.41  ansible_user=root

[k8s_cluster:children]
masters
workers

[k8s_cluster:vars]
ansible_ssh_common_args='-o StrictHostKeyChecking=no'
primary_master_ip=192.168.1.30
```

### group_vars/all.yml

```yaml
# ansible/group_vars/all.yml
k8s_version: "1.31"
pod_network_cidr: "10.244.0.0/16"
calico_version: "3.28.2"
containerd_config_path: /etc/containerd/config.toml
root_password: "KubeAdmin@2024!"
ssh_password_auth: "yes"
ssh_permit_root_login: "yes"
ansible_python_interpreter: /usr/bin/python3
ansible_ssh_common_args: "-o StrictHostKeyChecking=no"
```

### roles/common/tasks/main.yml

Runs on **every node**. Installs: essential packages, kernel modules, sysctl params, containerd, Kubernetes packages, SSH config.

Key tasks summary:

```
1.  apt-get update + install: net-tools, curl, ssh, cron, conntrack, gnupg
2.  Load overlay + br_netfilter kernel modules (with LXC ignore_errors)
3.  Sysctl: bridge-nf-call-iptables=1, ip_forward=1
4.  Disable swap (swapoff -a + fstab comment)
5.  Install containerd.io from Docker repo
6.  Set SystemdCgroup = true in containerd config
7.  Add Kubernetes apt repo (pkgs.k8s.io) + install kubeadm/kubelet/kubectl
8.  Hold k8s packages (prevent accidental upgrades)
9.  Set KUBELET_EXTRA_ARGS=--fail-swap-on=false
10. Enable SSH + password auth + permit root
11. Set root password via ansible user module (hashed)
```

### roles/master/tasks/main.yml

Runs on **master nodes only**.

```
1.  kubeadm config images pull
2.  kubeadm init --pod-network-cidr={{ pod_network_cidr }} --ignore-preflight-errors=all
    (idempotent: skips if /etc/kubernetes/admin.conf exists)
3.  Copy admin.conf to /root/.kube/config
4.  Deploy Calico tigera-operator
5.  Deploy Calico custom-resources.yaml
6.  Wait for kube-proxy configmap to exist, then patch it:
      mode: ""           →  mode: "iptables"
      maxPerCore: null   →  maxPerCore: 0
      min: null          →  min: 0
7.  Restart kube-proxy pods
8.  kubeadm token create --print-join-command → /joincluster.sh
9.  Wait for all control-plane pods to be Running
```

### roles/worker/tasks/main.yml

Runs on **worker nodes only**.

```
1.  Slurp /joincluster.sh from primary master (via delegate_to)
2.  Check if already joined (/etc/kubernetes/kubelet.conf exists → skip)
3.  Execute join command with --ignore-preflight-errors=SystemVerification
4.  Ensure kubelet is enabled and running
```

### site.yml

```yaml
# ansible/site.yml
- name: Bootstrap all cluster nodes
  hosts: k8s_cluster
  roles: [common]
  tags: [common, bootstrap]

- name: Configure Kubernetes master(s)
  hosts: masters
  serial: 1              # initialise one master at a time (HA safe)
  roles: [master]
  tags: [master, control-plane]

- name: Join worker nodes to cluster
  hosts: workers
  roles: [worker]
  tags: [worker]

- name: Verify cluster health
  hosts: "{{ groups['masters'][0] }}"
  tasks:
    - wait for all nodes to be Ready (retries 40, delay 15s)
    - kubectl get nodes
    - kubectl get pods -A
  tags: [verify]
```

### ansible.cfg

```ini
[defaults]
inventory          = inventory/hosts.ini
host_key_checking  = False
stdout_callback    = yaml

[ssh_connection]
pipelining = True
ssh_args   = -o ControlMaster=auto -o ControlPersist=60s -o StrictHostKeyChecking=no
```

---

## End-to-End Wrapper (deploy.sh)

```bash
#!/usr/bin/env bash
# Usage:
#   ./deploy.sh           # provision + configure
#   ./deploy.sh --destroy # tear everything down
```

The script chains all four steps automatically:

```
1. terraform init && plan && apply
2. gen_inventory.py (from tf output)
3. Wait for SSH on primary master
4. ansible-playbook site.yml
```

---

## Scaling the Cluster

### Add more workers

Edit `terraform.tfvars`:

```hcl
worker_count = 5   # was 2 — adds 3 more workers
```

```bash
cd terraform && terraform apply
cd ../ansible
terraform -chdir=../terraform output -json | python3 scripts/gen_inventory.py
ansible-playbook -i inventory/hosts.ini site.yml --tags worker
```

Terraform creates only the **new** containers (existing state is unchanged). Ansible's worker role is idempotent — nodes already joined are skipped.

### HA Control Plane (3 masters)

```hcl
master_count = 3
```

> **Note:** For production HA you also need a load balancer in front of the API server (`--control-plane-endpoint`). Update `kubeadm init` in the master role to add `--control-plane-endpoint=<VIP>:6443` and `--upload-certs`. A full HA setup with keepalived/HAProxy is beyond this guide's scope but the Terraform side (3 master containers) is handled automatically.

---

## Teardown

```bash
./deploy.sh --destroy
# or manually:
cd terraform && terraform destroy
```

This removes all LXC containers Terraform created. The Proxmox host config (`/etc/modules-load.d/k8s.conf`, sysctl) is **not** removed as it does not interfere with other workloads.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `400 too many arguments` on pct create | Proxmox shell backslash issue | Terraform API does not have this problem — irrelevant in automation |
| `null_resource` SSH fails during `terraform apply` | PVE not accepting password SSH | Set `private_key` in the null_resource connection block instead |
| `[ERROR FileExisting-conntrack]` | conntrack not installed | Handled by common role `apt install conntrack` |
| `[ERROR FileContent--proc-sys-net-ipv4-ip_forward]` | ip_forward not enabled | Handled by common role sysctl task + shell fallback |
| `[ERROR SystemVerification]` | Proxmox kernel lacks `configs` module | `--ignore-preflight-errors=SystemVerification` added to all join commands |
| `kube-proxy CrashLoopBackOff` | LXC denied `nf_conntrack_max` write | Handled by master role kube-proxy patch (mode=iptables, conntrack=0) |
| CoreDNS stuck in `Pending` | Calico not ready yet | Playbook waits; run `kubectl get pods -A` and wait 2–5 min |
| Ansible `SSH connection refused` | Container still booting | Increase `sleep 10` in null_resource to `sleep 20` |
| `sysctl: setting key net.bridge...` fails | br_netfilter not loaded in LXC | Handled by `ignore_errors: true` — host PVE sysctl covers this |
| `kubeadm init` fails on second run | Cluster already initialized | Idempotency check on `/etc/kubernetes/admin.conf` skips re-init |

---

## Design Decisions & Industry Standards Applied

| Decision | Rationale |
|----------|-----------|
| **Terraform `for_each` + computed maps** | Industry standard for dynamic resource counts; avoids `count` index drift on destroy |
| **`bpg/proxmox` provider** | Most complete Proxmox provider; supports containers, VMs, storage |
| **`null_resource` for lxc.conf patch** | The provider cannot set raw `lxc.*` directives yet; null_resource bridges the gap without bespoke scripts |
| **Ansible roles** | Separation of concerns: `common` / `master` / `worker`; each role is independently re-runnable |
| **Idempotent tasks** | Every task checks current state before acting (`creates:`, `stat`, `until` checks) — safe to re-run |
| **`serial: 1` on master play** | Ensures HA masters initialize sequentially; critical for etcd quorum |
| **`delegate_to` for join command** | Worker nodes fetch the join script directly from the master via Ansible delegation — no manual copy step |
| **`dpkg_selections: hold`** | Prevents `apt upgrade` from accidentally updating Kubernetes components |
| **`pod_network_cidr = 10.244.0.0/16`** | Uses RFC1918 range that does not overlap typical home/lab `192.168.x.x` subnets |
| **Secrets handling** | `terraform.tfvars` is gitignored; passwords are `sensitive = true`; production use should replace with Vault or SOPS |
| **Ansible Vault ready** | `root_password` and other secrets in `group_vars/all.yml` can be encrypted with `ansible-vault encrypt_string` |
