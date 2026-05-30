# Copy to terraform.tfvars — never commit this file (it is gitignored)

proxmox_api_url          = "https://192.168.31.227:8006/api2/json"
proxmox_api_token_id     = "root@pam!terraform"
proxmox_api_token_secret = "19e55a97-ef89-497f-973a-a01a1dcd89e9"
proxmox_node             = "pve"

lxc_template = "local:vztmpl/ubuntu-25.04-standard_25.04-1.1_amd64.tar.zst"
storage_pool = "local-lvm"

network_bridge      = "vmbr0"
network_gateway     = "192.168.31.1"
network_cidr_prefix = 24
dns_server          = "192.168.31.1"

master_count    = 1        # set 3 for HA
master_id_start = 200
master_ip_base  = "192.168.31"
master_ip_start = 30
master_cores    = 2
master_memory   = 4096
master_disk_size = 30

worker_count    = 2
worker_id_start = 210
worker_ip_base  = "192.168.31"
worker_ip_start = 40
worker_cores    = 2
worker_memory   = 4096
worker_disk_size = 30

k8s_version      = "1.31"
pod_network_cidr = "10.244.0.0/16"
calico_version   = "3.28.2"

root_password  = "KubeAdmin@2026!"
ssh_public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICBWRcQFTGXE8vyZ/r2kgT6pP4DuU5Z8DlXlSIacicJI k8s-proxmox"
