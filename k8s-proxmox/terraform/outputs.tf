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
