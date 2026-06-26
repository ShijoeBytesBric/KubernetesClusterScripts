# Proxmox connection
variable "proxmox_api_url" {
  type = string
}
variable "proxmox_api_token_id" {
  type = string
}
variable "proxmox_api_token_secret" {
  type      = string
  sensitive = true
}
variable "proxmox_node" {
  type    = string
  default = "pve"
}

# LXC template
variable "lxc_template" {
  type    = string
  default = "local:vztmpl/ubuntu-25.04-standard_25.04-1.1_amd64.tar.zst"
}
variable "storage_pool" {
  type    = string
  default = "local-lvm"
}

# Network
variable "network_bridge" {
  type    = string
  default = "vmbr0"
}
variable "network_gateway" {
  type    = string
  default = "192.168.31.227"
}
variable "network_cidr_prefix" {
  type    = number
  default = 24
}
variable "dns_server" {
  type    = string
  default = "8.8.8.8"
}

# Master nodes
variable "master_count" {
  type    = number
  default = 1
}
variable "master_id_start" {
  type    = number
  default = 200
}
variable "master_ip_base" {
  type    = string
  default = "192.168.31"
}
variable "master_ip_start" {
  type    = number
  default = 30
}
variable "master_cores" {
  type    = number
  default = 2
}
variable "master_memory" {
  type    = number
  default = 4096
}
variable "master_disk_size" {
  type    = number
  default = 30
}

# Worker nodes
variable "worker_count" {
  type    = number
  default = 2
}
variable "worker_id_start" {
  type    = number
  default = 210
}
variable "worker_ip_base" {
  type    = string
  default = "192.168.31"
}
variable "worker_ip_start" {
  type    = number
  default = 40
}
variable "worker_cores" {
  type    = number
  default = 2
}
variable "worker_memory" {
  type    = number
  default = 4096
}
variable "worker_disk_size" {
  type    = number
  default = 30
}

# Kubernetes
variable "k8s_version" {
  type    = string
  default = "1.31"
}
variable "pod_network_cidr" {
  type    = string
  default = "10.244.0.0/16"
}
variable "calico_version" {
  type    = string
  default = "3.28.2"
}

# Access
variable "root_password" {
  type      = string
  sensitive = true
}
variable "ssh_public_key" {
  type    = string
  default = ""
}
