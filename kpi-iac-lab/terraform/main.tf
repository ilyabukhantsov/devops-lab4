terraform {
  required_version = ">= 1.0"
  required_providers {
    libvirt = {
      source  = "dmacvicar/libvirt"
      version = "0.7.6"
    }
  }
}

provider "libvirt" {
  uri = "qemu:///system"
}

resource "libvirt_volume" "base_image" {
  name   = "ubuntu-base.qcow2"
  pool   = "default"
  source = "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
  format = "qcow2"
}

resource "libvirt_volume" "worker_disk" {
  name           = "worker.qcow2"
  pool           = "default"
  base_volume_id = libvirt_volume.base_image.id
  size           = 10737418240 # 10GB
}

resource "libvirt_volume" "db_disk" {
  name           = "db.qcow2"
  pool           = "default"
  base_volume_id = libvirt_volume.base_image.id
  size           = 10737418240 # 10GB
}


resource "libvirt_cloudinit_disk" "common_init" {
  name      = "common_init.iso"
  pool      = "default"
  user_data = templatefile("${path.module}/cloud_init.cfg", {
    ssh_public_key = file("~/.ssh/id_ed25519.pub")
  })
}

resource "libvirt_network" "kpi_net" {
  name      = "kpi_network"
  mode      = "nat"
  addresses = ["192.168.150.0/24"]
  dhcp {
    enabled = true
  }
}

resource "libvirt_domain" "worker" {
  name   = "kpi-worker"
  memory = "2048"
  vcpu   = 2
  type   = "kvm"

  cloudinit = libvirt_cloudinit_disk.common_init.id

  network_interface {
    network_id     = libvirt_network.kpi_net.id
    wait_for_lease = true
  }

  disk {
    volume_id = libvirt_volume.worker_disk.id
  }

  console {
    type        = "pty"
    target_port = "0"
    target_type = "serial"
  }
}

resource "libvirt_domain" "db" {
  name   = "kpi-db"
  memory = "2048"
  vcpu   = 2
  type   = "kvm"

  cloudinit = libvirt_cloudinit_disk.common_init.id

  network_interface {
    network_id     = libvirt_network.kpi_net.id
    wait_for_lease = true
  }

  disk {
    volume_id = libvirt_volume.db_disk.id
  }

  console {
    type        = "pty"
    target_port = "0"
    target_type = "serial"
  }
}

output "worker_ip" { 
  value = length(libvirt_domain.worker.network_interface[0].addresses) > 0 ? libvirt_domain.worker.network_interface[0].addresses[0] : "No IP yet" 
}

output "db_ip" { 
  value = length(libvirt_domain.db.network_interface[0].addresses) > 0 ? libvirt_domain.db.network_interface[0].addresses[0] : "No IP yet" 
}