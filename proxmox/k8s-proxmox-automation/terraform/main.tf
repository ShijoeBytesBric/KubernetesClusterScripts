terraform {
  required_version = ">= 1.5.0"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.66"
    }
  }
}

provider "proxmox" {
  endpoint  = var.proxmox_api_url
  api_token = "${var.proxmox_api_token_id}=${var.proxmox_api_token_secret}"
  insecure  = true # set false if you have a valid TLS cert
}

# ============================================================
# Local computed values
# ============================================================
locals {
  # Build a map of master nodes: { "k8s-master-0" = { id, ip }, ... }
  masters = {
    for i in range(var.master_count) :
    "k8s-master-${i}" => {
      vm_id    = var.master_id_start + i
      ip       = "${var.master_ip_base}.${var.master_ip_start + i}"
      hostname = "k8s-master-${i}"
    }
  }

  # Build a map of worker nodes
  workers = {
    for i in range(var.worker_count) :
    "k8s-worker-${i}" => {
      vm_id    = var.worker_id_start + i
      ip       = "${var.worker_ip_base}.${var.worker_ip_start + i}"
      hostname = "k8s-worker-${i}"
    }
  }

  # LXC extra config applied to every container for Kubernetes compatibility
  lxc_k8s_config = [
    "lxc.apparmor.profile: unconfined",
    "lxc.cap.drop:",
    "lxc.cgroup2.devices.allow: a",
    "lxc.mount.auto: proc:rw sys:rw cgroup:rw",
    "lxc.mount.entry: /dev/kmsg dev/kmsg none bind,create=file",
  ]
}

# ============================================================
# Master LXC containers
# ============================================================
resource "proxmox_virtual_environment_container" "master" {
  for_each = local.masters

  node_name  = var.proxmox_node
  vm_id      = each.value.vm_id
  description = "Kubernetes master node — managed by Terraform"
  tags        = ["kubernetes", "master"]

  unprivileged = false # privileged required for k8s
  started      = true

  initialization {
    hostname = each.value.hostname

    ip_config {
      ipv4 {
        address = "${each.value.ip}/${var.network_cidr_prefix}"
        gateway = var.network_gateway
      }
    }

    dns {
      servers = [var.dns_server]
    }

    user_account {
      password = var.root_password
      keys     = var.ssh_public_key != "" ? [var.ssh_public_key] : []
    }
  }

  operating_system {
    template_file_id = var.lxc_template
    type             = "ubuntu"
  }

  cpu {
    cores = var.master_cores
  }

  memory {
    dedicated = var.master_memory
    swap      = 0
  }

  disk {
    datastore_id = var.storage_pool
    size         = var.master_disk_size
  }

  network_interface {
    name   = "eth0"
    bridge = var.network_bridge
  }

  features {
    keyctl  = true
    nesting = true
  }

  # Inject Kubernetes-required LXC raw config
  dynamic "hook_script" {
    for_each = []
    content {}
  }

  lifecycle {
    ignore_changes = [
      initialization[0].user_account[0].password,
    ]
  }
}

# ============================================================
# Worker LXC containers
# ============================================================
resource "proxmox_virtual_environment_container" "worker" {
  for_each = local.workers

  node_name   = var.proxmox_node
  vm_id       = each.value.vm_id
  description = "Kubernetes worker node — managed by Terraform"
  tags        = ["kubernetes", "worker"]

  unprivileged = false
  started      = true

  initialization {
    hostname = each.value.hostname

    ip_config {
      ipv4 {
        address = "${each.value.ip}/${var.network_cidr_prefix}"
        gateway = var.network_gateway
      }
    }

    dns {
      servers = [var.dns_server]
    }

    user_account {
      password = var.root_password
      keys     = var.ssh_public_key != "" ? [var.ssh_public_key] : []
    }
  }

  operating_system {
    template_file_id = var.lxc_template
    type             = "ubuntu"
  }

  cpu {
    cores = var.worker_cores
  }

  memory {
    dedicated = var.worker_memory
    swap      = 0
  }

  disk {
    datastore_id = var.storage_pool
    size         = var.worker_disk_size
  }

  network_interface {
    name   = "eth0"
    bridge = var.network_bridge
  }

  features {
    keyctl  = true
    nesting = true
  }

  lifecycle {
    ignore_changes = [
      initialization[0].user_account[0].password,
    ]
  }
}

# ============================================================
# Patch LXC config files on the Proxmox host after creation
# (bpg/proxmox provider does not expose raw lxc.* directives yet)
# This null_resource SSHes into the PVE host and appends them.
# ============================================================
resource "null_resource" "patch_master_lxc_config" {
  for_each = local.masters

  depends_on = [proxmox_virtual_environment_container.master]

  connection {
    type     = "ssh"
    host     = regex("https?://([^:]+):", var.proxmox_api_url)[0]
    user     = "root"
    password = var.root_password # or use private_key
  }

  provisioner "remote-exec" {
    inline = [
      # Stop the container so config changes take effect cleanly
      "pct stop ${each.value.vm_id} || true",
      # Append k8s required directives (idempotent: remove then re-add)
      "sed -i '/^lxc\\./d' /etc/pve/lxc/${each.value.vm_id}.conf",
      "echo 'lxc.apparmor.profile: unconfined' >> /etc/pve/lxc/${each.value.vm_id}.conf",
      "echo 'lxc.cap.drop:' >> /etc/pve/lxc/${each.value.vm_id}.conf",
      "echo 'lxc.cgroup2.devices.allow: a' >> /etc/pve/lxc/${each.value.vm_id}.conf",
      "echo 'lxc.mount.auto: proc:rw sys:rw cgroup:rw' >> /etc/pve/lxc/${each.value.vm_id}.conf",
      "echo 'lxc.mount.entry: /dev/kmsg dev/kmsg none bind,create=file' >> /etc/pve/lxc/${each.value.vm_id}.conf",
      "pct start ${each.value.vm_id}",
      "sleep 10", # give the container time to fully boot
    ]
  }
}

resource "null_resource" "patch_worker_lxc_config" {
  for_each = local.workers

  depends_on = [proxmox_virtual_environment_container.worker]

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
