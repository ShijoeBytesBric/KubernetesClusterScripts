# ============================================================
# Outputs — used by the Ansible inventory generator
# ============================================================

output "master_nodes" {
  description = "Master node IPs and hostnames"
  value = {
    for k, v in local.masters : k => {
      ip       = v.ip
      hostname = v.hostname
      vm_id    = v.vm_id
    }
  }
}

output "worker_nodes" {
  description = "Worker node IPs and hostnames"
  value = {
    for k, v in local.workers : k => {
      ip       = v.ip
      hostname = v.hostname
      vm_id    = v.vm_id
    }
  }
}

output "primary_master_ip" {
  description = "IP of the primary (first) master node — used as kubeadm endpoint"
  value       = "${var.master_ip_base}.${var.master_ip_start}"
}

output "ansible_inventory_hint" {
  description = "Run this after terraform apply to generate the Ansible inventory"
  value       = "cd ../ansible && terraform -chdir=../terraform output -json | python3 scripts/gen_inventory.py"
}
