# KubernetesClusterScripts

Automated **Kubernetes cluster provisioning on Proxmox LXC** using Terraform (HCL), Ansible (via Python inventory generator), and Shell scripts.

---

## Overview

This repository provisions and bootstraps Kubernetes clusters inside **Proxmox LXC containers**. Terraform creates the containers with dynamic IDs and IPs, a Python script generates the Ansible inventory from Terraform output, and Ansible configures containerd, kubeadm, Calico CNI, and joins all nodes — fully automated via a single `deploy.sh` wrapper.

```
Terraform → LXC Containers (Proxmox)
Python    → Ansible Inventory (from tf output)
Ansible   → containerd + kubeadm + Calico + node join
deploy.sh → chains all steps end-to-end
```

## References
https://github.com/justmeandopensource/kubernetes/blob/master/lxd-provisioning/bootstrap-kube.sh

---

## Prerequisites

### Workstation

| Tool | Version |
|------|---------|
| Terraform | >= 1.5 |
| Ansible | >= 2.15 |
| Python | >= 3.9 |
| sshpass | any |

```bash
pip install ansible
ansible-galaxy collection install ansible.posix community.general
```

### Proxmox Host

Run once on the **PVE host** (not inside containers):

```bash
modprobe ip_tables ip6_tables nf_nat overlay br_netfilter

cat << 'EOF' > /etc/modules-load.d/k8s.conf
ip_tables
ip6_tables
nf_nat
overlay
br_netfilter
EOF

cat << 'EOF' > /etc/sysctl.d/k8s.conf
net.netfilter.nf_conntrack_max=524288
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
net.ipv4.ip_forward=1
EOF
sysctl -p /etc/sysctl.d/k8s.conf

# Download Ubuntu template
pveam update
pveam download local ubuntu-25.04-standard_25.04-1.1_amd64.tar.zst
```

### Proxmox API Token (for Terraform)

```bash
pveum user add terraform@pve
pveum aclmod / -user terraform@pve -role PVEAdmin
pveum user token add terraform@pve terraform --privsep 0
# Save the token secret — shown only once
```

---

## Repository Structure

```
k8s-proxmox-automation/
├── deploy.sh                        # One-shot wrapper: Terraform + Ansible
├── .gitignore
│
├── terraform/
│   ├── main.tf                      # LXC container resources (dynamic for_each)
│   ├── variables.tf                 # All tuneable parameters
│   ├── outputs.tf                   # Exports IPs/hostnames for Ansible
│   └── terraform.tfvars.example     # Copy to terraform.tfvars and fill in
│
└── ansible/
    ├── ansible.cfg                  # SSH tuning, inventory path
    ├── site.yml                     # Master playbook (4 plays)
    ├── scripts/
    │   └── gen_inventory.py         # Generates hosts.ini from terraform output
    ├── inventory/
    │   ├── hosts.ini                # Auto-generated — do not edit
    │   └── hosts.yml                # Auto-generated YAML form
    ├── group_vars/
    │   └── all.yml                  # Shared vars (k8s version, CIDR, etc.)
    └── roles/
        ├── common/tasks/main.yml    # Bootstrap: containerd, kubeadm, SSH
        ├── master/tasks/main.yml    # kubeadm init, Calico, kube-proxy fix
        └── worker/tasks/main.yml    # kubeadm join
```

---

## Usage

### 1. Configure

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
# Edit terraform.tfvars with your Proxmox details, IPs, and credentials
```

### 2. Deploy (all-in-one)

```bash
./deploy.sh
```

This runs all four steps automatically:
1. `terraform init && apply` — creates LXC containers with dynamic IDs and IPs
2. `gen_inventory.py` — generates Ansible inventory from Terraform output
3. Waits for SSH on the primary master
4. `ansible-playbook site.yml` — installs and configures the full cluster

### 3. Destroy

```bash
./deploy.sh --destroy
# or manually:
cd terraform && terraform destroy
```

---

## Configuration

Key variables in `terraform.tfvars`:

| Variable | Description | Default |
|---|---|---|
| `proxmox_api_url` | Proxmox API endpoint | — |
| `proxmox_api_token_id` | API token ID | — |
| `proxmox_api_token_secret` | API token secret | — |
| `master_count` | Number of master nodes | `1` |
| `worker_count` | Number of worker nodes | `2` |
| `master_ip_base` / `master_ip_start` | Master IP range | `192.168.1.30+` |
| `worker_ip_base` / `worker_ip_start` | Worker IP range | `192.168.1.40+` |
| `k8s_version` | Kubernetes version | `1.31` |
| `pod_network_cidr` | Pod network CIDR | `10.244.0.0/16` |
| `root_password` | Root password for LXC containers | — |

> `terraform.tfvars` is gitignored — never commit it.

---

## Scaling

### Add workers

```hcl
# terraform.tfvars
worker_count = 5  # was 2
```

```bash
cd terraform && terraform apply
cd ../ansible
terraform -chdir=../terraform output -json | python3 scripts/gen_inventory.py
ansible-playbook -i inventory/hosts.ini site.yml --tags worker
```

### HA Control Plane

```hcl
master_count = 3
```

> For production HA, a load balancer (keepalived/HAProxy) in front of the API server is also needed. Update `kubeadm init` in the master role with `--control-plane-endpoint=<VIP>:6443 --upload-certs`.

---

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `null_resource` SSH fails during `terraform apply` | Use `private_key` in the connection block instead of password auth |
| `kube-proxy CrashLoopBackOff` | Handled automatically by master role (patches mode=iptables, conntrack=0) |
| CoreDNS stuck in `Pending` | Wait 2-5 min for Calico to become ready |
| Ansible `SSH connection refused` | Container still booting — increase `sleep 10` to `sleep 20` in null_resource |
| `kubeadm init` fails on second run | Cluster already initialised — idempotency check on `/etc/kubernetes/admin.conf` skips re-init |
| `sysctl: setting key net.bridge...` fails in LXC | Expected — PVE host sysctl covers this; `ignore_errors: true` handles it in the role |
