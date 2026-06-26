# Kubernetes Cluster Automation for Proxmox

Provision a Kubernetes cluster using Proxmox LXC containers, Terraform, and Ansible.
This repository automates container creation and configuration for a small Kubernetes cluster on a Proxmox host.

## What it does

- Uses Terraform to create LXC containers on Proxmox.
- Applies container runtime patches to enable the Kubernetes workload environment.
- Waits for SSH access to each container.
- Generates an Ansible inventory from Terraform outputs.
- Uses Ansible to bootstrap nodes, configure a Kubernetes control plane, join workers, and verify cluster health.

## Repository layout

- `k8s-proxmox/deploy.sh` — primary deployment script.
- `k8s-proxmox/terraform/` — Terraform definitions and sample variables.
- `k8s-proxmox/ansible/` — Ansible playbook and role structure.

## Prerequisites

- Linux machine with access to a Proxmox VE cluster.
- `terraform` installed.
- `ansible` installed inside a Python virtual environment.
- `ssh` client installed.
- A Proxmox API token with permissions to create and manage LXC containers.
- An Ubuntu LXC template available on Proxmox, matching `terraform/lxc_template`.

## Setup

1. Clone this repository to your home directory or update `deploy.sh` if you keep it elsewhere.

2. Copy the Terraform example variables:

```bash
cp k8s-proxmox/terraform/terraform.tfvars.example k8s-proxmox/terraform/terraform.tfvars
```

3. Edit `k8s-proxmox/terraform/terraform.tfvars` with your Proxmox API endpoint and token values.

4. Set a root password for the new containers and optionally add your SSH public key:

- `root_password`
- `ssh_public_key`

5. Create and install Ansible in a virtual environment at `~/ansible-venv`.

Example:

```bash
python3 -m venv ~/ansible-venv
source ~/ansible-venv/bin/activate
pip install ansible
```

> If you prefer a different virtualenv location, update `k8s-proxmox/deploy.sh` to point to the correct `activate` path.

## Usage

Change into the repository root and run the deploy script:

```bash
cd ~/k8s-proxmox
./deploy.sh
```

### Common options

- `./deploy.sh` — full cluster creation and configuration.
- `./deploy.sh --destroy` — remove the cluster and cleanup SSH known_hosts entries.
- `./deploy.sh --ansible` — run only the Ansible configuration step when containers already exist.
- `./deploy.sh --from-step N` — resume from step `N` where:
  - `1` = Terraform provisioning
  - `2` = SSH readiness checks
  - `3` = inventory generation
  - `4` = Ansible configuration

## How it works

1. Terraform provisions LXC containers for masters and workers and sets networking.
2. A local null resource patches each container's `/etc/pve/lxc/<id>.conf` with Kubernetes-friendly settings.
3. The script waits for SSH to become available on each container IP.
4. An inventory file is generated at `~/k8s-proxmox/ansible/inventory/hosts.ini`.
5. Ansible bootstraps the cluster using roles:
   - `common`
   - `master`
   - `worker`

## Customization

- Adjust cluster size and resources in `k8s-proxmox/terraform/terraform.tfvars`.
- Change Kubernetes version, pod network CIDR, and Calico version via Terraform variables.
- Edit the Ansible roles under `k8s-proxmox/ansible/roles/` to tune OS or Kubernetes configuration.

## Notes

- `deploy.sh` currently assumes the repository is available at `~/k8s-proxmox` and the Ansible venv is at `~/ansible-venv`.
- The Terraform provider uses `insecure = true` for Proxmox API access. Use a trusted network or update the provider configuration for production.
- Do not commit `terraform/terraform.tfvars` if it contains secrets.

## Troubleshooting

- If SSH waits fail, verify the containers are running and accessible from the deployment host.
- If Terraform cannot connect to Proxmox, check `proxmox_api_url` and API token details.
- If Ansible fails, confirm the virtual environment is activated and Ansible can reach each container.

## Cleanup

To destroy the cluster and remove SSH keys from your known hosts file:

```bash
cd ~/k8s-proxmox
./deploy.sh --destroy
```

## License

This repository is provided as automation tooling for Kubernetes cluster deployment on Proxmox. Customize it for your environment and use at your own risk.
