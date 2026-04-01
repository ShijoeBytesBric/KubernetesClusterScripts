# ============================================================
# Proxmox connection
# ============================================================
variable "proxmox_api_url" {
  description = "Proxmox API URL (e.g. https://192.168.1.10:8006/api2/json)"
  type        = string
}

variable "proxmox_api_token_id" {
  description = "API token ID (e.g. root@pam!terraform)"
  type        = string
}

variable "proxmox_api_token_secret" {
  description = "API token secret"
  type        = string
  sensitive   = true
}

variable "proxmox_node" {
  description = "Proxmox node name to deploy on"
  type        = string
  default     = "pve"
}

# ============================================================
# LXC template
# ============================================================
variable "lxc_template" {
  description = "Template to use for containers"
  type        = string
  default     = "local:vztmpl/ubuntu-25.04-standard_25.04-1.1_amd64.tar.zst"
}

variable "storage_pool" {
  description = "Proxmox storage pool for container rootfs"
  type        = string
  default     = "local-lvm"
}

# ============================================================
# Network
# ============================================================
variable "network_bridge" {
  description = "Proxmox network bridge"
  type        = string
  default     = "vmbr0"
}

variable "network_gateway" {
  description = "Default gateway for containers"
  type        = string
  default     = "192.168.1.1"
}

variable "network_cidr_prefix" {
  description = "CIDR prefix length (e.g. 24 for /24)"
  type        = number
  default     = 24
}

variable "dns_server" {
  description = "DNS server for containers"
  type        = string
  default     = "8.8.8.8"
}

# ============================================================
# Master node
# ============================================================
variable "master_count" {
  description = "Number of master nodes (1 for single-master, 3 for HA)"
  type        = number
  default     = 1
}

variable "master_id_start" {
  description = "Starting container ID for master nodes"
  type        = number
  default     = 200
}

variable "master_ip_start" {
  description = "Starting IP for master nodes (last octet); increments per node"
  type        = number
  default     = 30
}

variable "master_ip_base" {
  description = "First three octets of the IP range for master nodes"
  type        = string
  default     = "192.168.1"
}

variable "master_cores" {
  type    = number
  default = 2
}

variable "master_memory" {
  description = "Memory in MB"
  type        = number
  default     = 4096
}

variable "master_disk_size" {
  description = "Root disk size in GB"
  type        = number
  default     = 30
}

# ============================================================
# Worker nodes
# ============================================================
variable "worker_count" {
  description = "Number of worker nodes"
  type        = number
  default     = 2
}

variable "worker_id_start" {
  description = "Starting container ID for worker nodes"
  type        = number
  default     = 210
}

variable "worker_ip_start" {
  description = "Starting IP for worker nodes (last octet); increments per node"
  type        = number
  default     = 40
}

variable "worker_ip_base" {
  description = "First three octets of the IP range for worker nodes"
  type        = string
  default     = "192.168.1"
}

variable "worker_cores" {
  type    = number
  default = 2
}

variable "worker_memory" {
  description = "Memory in MB"
  type        = number
  default     = 4096
}

variable "worker_disk_size" {
  description = "Root disk size in GB"
  type        = number
  default     = 30
}

# ============================================================
# Kubernetes
# ============================================================
variable "k8s_version" {
  description = "Kubernetes minor version (e.g. 1.31)"
  type        = string
  default     = "1.31"
}

variable "pod_network_cidr" {
  description = "Pod network CIDR for kubeadm (must not overlap with host network)"
  type        = string
  default     = "10.244.0.0/16"
}

variable "calico_version" {
  description = "Calico CNI version"
  type        = string
  default     = "3.28.2"
}

# ============================================================
# SSH / Access
# ============================================================
variable "root_password" {
  description = "Root password for all containers"
  type        = string
  sensitive   = true
  default     = "KubeAdmin@2024!"
}

variable "ssh_public_key" {
  description = "SSH public key to inject into containers (optional)"
  type        = string
  default     = ""
}
