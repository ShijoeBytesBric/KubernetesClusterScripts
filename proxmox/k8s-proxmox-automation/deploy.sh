#!/usr/bin/env bash
# deploy.sh — End-to-end Kubernetes cluster provisioning on Proxmox LXC
# Usage: ./deploy.sh [--destroy]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="$SCRIPT_DIR/terraform"
ANSIBLE_DIR="$SCRIPT_DIR/ansible"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[deploy]${NC} $*"; }
warn() { echo -e "${YELLOW}[deploy]${NC} $*"; }
err()  { echo -e "${RED}[deploy]${NC} $*" >&2; exit 1; }

# ── Destroy mode ──────────────────────────────────────────
if [[ "${1:-}" == "--destroy" ]]; then
  warn "Destroying all Terraform-managed resources..."
  cd "$TERRAFORM_DIR"
  terraform destroy -auto-approve
  exit 0
fi

# ── Pre-flight checks ─────────────────────────────────────
command -v terraform  >/dev/null 2>&1 || err "terraform not found. Install from https://developer.hashicorp.com/terraform/install"
command -v ansible-playbook >/dev/null 2>&1 || err "ansible-playbook not found. Install: pip install ansible"
command -v python3    >/dev/null 2>&1 || err "python3 not found"

[[ -f "$TERRAFORM_DIR/terraform.tfvars" ]] \
  || err "Missing terraform/terraform.tfvars — copy terraform.tfvars.example and fill in your values"

# ── Step 1: Terraform ─────────────────────────────────────
log "=== STEP 1: Provisioning LXC containers with Terraform ==="
cd "$TERRAFORM_DIR"
terraform init -upgrade
terraform validate
terraform plan -out=tfplan
terraform apply tfplan

# ── Step 2: Generate Ansible inventory ───────────────────
log "=== STEP 2: Generating Ansible inventory from Terraform output ==="
cd "$ANSIBLE_DIR"
terraform -chdir="$TERRAFORM_DIR" output -json \
  | python3 scripts/gen_inventory.py

log "Generated inventory:"
cat inventory/hosts.ini

# ── Step 3: Wait for SSH to come up ───────────────────────
log "=== STEP 3: Waiting for SSH on all nodes ==="
MASTER_IP=$(terraform -chdir="$TERRAFORM_DIR" output -raw primary_master_ip)
MAX_WAIT=120
ELAPSED=0
until ssh -o StrictHostKeyChecking=no -o ConnectTimeout=3 \
         -o PasswordAuthentication=no \
         root@"$MASTER_IP" echo "SSH up" 2>/dev/null; do
  if [[ $ELAPSED -ge $MAX_WAIT ]]; then
    warn "SSH not available after ${MAX_WAIT}s — continuing anyway (password auth will be used)"
    break
  fi
  sleep 5; ELAPSED=$((ELAPSED+5))
  echo -n "."
done
echo ""

# ── Step 4: Ansible ───────────────────────────────────────
log "=== STEP 4: Running Ansible to configure cluster ==="
cd "$ANSIBLE_DIR"

# Install required Ansible collections if not present
ansible-galaxy collection install ansible.posix community.general --ignore-errors

ansible-playbook \
  -i inventory/hosts.ini \
  site.yml \
  --extra-vars "ansible_ssh_pass=$(grep root_password "$TERRAFORM_DIR/terraform.tfvars" | awk -F'"' '{print $2}')" \
  -v

# ── Done ──────────────────────────────────────────────────
log "=== CLUSTER PROVISIONING COMPLETE ==="
log "Connect to master: ssh root@${MASTER_IP}"
log "Run: kubectl get nodes"
