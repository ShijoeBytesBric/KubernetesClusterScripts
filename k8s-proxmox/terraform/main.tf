terraform {
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
  insecure  = true
}

locals {
  masters = {
    for i in range(var.master_count) :
    "k8s-master-${i}" => {
      vm_id    = var.master_id_start + i
      ip       = "${var.master_ip_base}.${var.master_ip_start + i}"
      hostname = "k8s-master-${i}"
    }
  }
  workers = {
    for i in range(var.worker_count) :
    "k8s-worker-${i}" => {
      vm_id    = var.worker_id_start + i
      ip       = "${var.worker_ip_base}.${var.worker_ip_start + i}"
      hostname = "k8s-worker-${i}"
    }
  }
}

resource "proxmox_virtual_environment_container" "master" {
  for_each    = local.masters
  node_name   = var.proxmox_node
  vm_id       = each.value.vm_id
  unprivileged = false

  operating_system {
    template_file_id = var.lxc_template
    type             = "ubuntu"
  }

  initialization {
    hostname = each.value.hostname
    ip_config {
      ipv4 {
        address = "${each.value.ip}/${var.network_cidr_prefix}"
        gateway = var.network_gateway
      }
    }
    dns {
      server = var.dns_server
    }
    user_account {
      password = var.root_password
      keys     = var.ssh_public_key != "" ? [var.ssh_public_key] : []
    }
  }

  cpu {
    cores = var.master_cores
  }

  memory {
    dedicated = var.master_memory
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
    nesting = false
  }

  started = false
}

resource "proxmox_virtual_environment_container" "worker" {
  for_each    = local.workers
  node_name   = var.proxmox_node
  vm_id       = each.value.vm_id
  unprivileged = false

  operating_system {
    template_file_id = var.lxc_template
    type             = "ubuntu"
  }

  initialization {
    hostname = each.value.hostname
    ip_config {
      ipv4 {
        address = "${each.value.ip}/${var.network_cidr_prefix}"
        gateway = var.network_gateway
      }
    }
    dns {
      server = var.dns_server
    }
    user_account {
      password = var.root_password
      keys     = var.ssh_public_key != "" ? [var.ssh_public_key] : []
    }
  }

  cpu {
    cores = var.worker_cores
  }

  memory {
    dedicated = var.worker_memory
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
    nesting = false
  }

  started = false
}

resource "null_resource" "patch_master_lxc_config" {
  for_each   = local.masters
  depends_on = [proxmox_virtual_environment_container.master]

  provisioner "local-exec" {
    command = <<-EOT
      pct stop ${each.value.vm_id} || true
      sleep 2
      sed -i '/^lxc\./d' /etc/pve/lxc/${each.value.vm_id}.conf
      echo 'lxc.apparmor.profile: unconfined' >> /etc/pve/lxc/${each.value.vm_id}.conf
      echo 'lxc.cap.drop:' >> /etc/pve/lxc/${each.value.vm_id}.conf
      echo 'lxc.cgroup2.devices.allow: a' >> /etc/pve/lxc/${each.value.vm_id}.conf
      echo 'lxc.mount.auto: proc:rw sys:rw cgroup:rw' >> /etc/pve/lxc/${each.value.vm_id}.conf
      echo 'lxc.mount.entry: /dev/kmsg dev/kmsg none bind,create=file' >> /etc/pve/lxc/${each.value.vm_id}.conf
      pct start ${each.value.vm_id}
      sleep 15
    EOT
  }
}

resource "null_resource" "patch_worker_lxc_config" {
  for_each   = local.workers
  depends_on = [proxmox_virtual_environment_container.worker]

  provisioner "local-exec" {
    command = <<-EOT
      pct stop ${each.value.vm_id} || true
      sleep 2
      sed -i '/^lxc\./d' /etc/pve/lxc/${each.value.vm_id}.conf
      echo 'lxc.apparmor.profile: unconfined' >> /etc/pve/lxc/${each.value.vm_id}.conf
      echo 'lxc.cap.drop:' >> /etc/pve/lxc/${each.value.vm_id}.conf
      echo 'lxc.cgroup2.devices.allow: a' >> /etc/pve/lxc/${each.value.vm_id}.conf
      echo 'lxc.mount.auto: proc:rw sys:rw cgroup:rw' >> /etc/pve/lxc/${each.value.vm_id}.conf
      echo 'lxc.mount.entry: /dev/kmsg dev/kmsg none bind,create=file' >> /etc/pve/lxc/${each.value.vm_id}.conf
      pct start ${each.value.vm_id}
      sleep 15
    EOT
  }
}
