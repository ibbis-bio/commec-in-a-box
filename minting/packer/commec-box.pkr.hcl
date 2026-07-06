# Master image build for commec-in-a-box.
# Base: Debian 'generic' qcow2 (UEFI+BIOS, cloud-init). Provisioned over SSH by Packer,
# DBs fed in via a second read-only virtio disk. Output: output/commec-box.qcow2.
#
# Invoked by build.sh (which fetches+verifies pinned inputs, generates the SSH key and
# cidata seed, builds the DB disk, and runs this under `sg kvm`). Do not run directly.

packer {
  required_plugins {
    qemu = {
      source  = "github.com/hashicorp/qemu"
      version = ">= 1.1.0"
    }
  }
}

# --- host-side artifacts (absolute paths from build.sh) ---
variable "base_image" { type = string }           # verified generic qcow2
variable "miniconda_installer" { type = string }  # verified Miniconda .sh
variable "db_disk" { type = string }              # raw ext4 image w/ the .zst tarballs
variable "db_sha256sums" { type = string }        # SHA256SUMS for the tarballs
variable "wallpaper_dir" { type = string }        # bg/wallpaper
variable "ssh_private_key_file" { type = string } # build-only key
variable "efi_vars" { type = string }             # writable OVMF VARS copy (from build.sh)
variable "seed_iso" { type = string }             # cloud-init NoCloud seed ISO (from build.sh)

# --- pinned values (passed from pins.json by build.sh) ---
variable "commec_version" {
  type    = string
  default = "1.0.5"
}
variable "biorisk_url" {
  type = string # pinned commec-dbs.zip URL
}

# --- TEMPORARY: gui-branch testing toggles (revert before the real gui->develop PR) ---
variable "commec_source" {
  type    = string
  default = "stable" # "gui" -> install a local gui-branch dev build (20-commec.sh)
}
variable "commec_channel" {
  type    = string
  default = "stable" # "devel" -> point the updater at the rose dev channel (47-update-system.sh)
}
variable "commec_gui_version" {
  type    = string
  default = "1.0.6.dev1"
}
variable "commec_update_url" {
  type    = string
  default = "http://10.0.2.2:8000" # QEMU user-net gateway = rose host (Phase-3 VM test)
}

# --- VM sizing ---
variable "output_dir" {
  type    = string
  default = "output"
}
variable "disk_size" {
  type    = string
  default = "40G" # master virtual size; ~15G used with the bundled ~7 GB DB (was 110G for nr+nt)
}
variable "memory" {
  type    = number
  default = 6144
}
variable "cpus" {
  type    = number
  default = 6
}

source "qemu" "commec" {
  # boot the (resized) base disk directly; no installer
  iso_url        = var.base_image
  iso_checksum   = "none" # build.sh already verified sha512
  disk_image     = true
  disk_size      = var.disk_size
  format         = "qcow2"
  disk_interface = "virtio"
  net_device     = "virtio-net"

  accelerator  = "kvm"
  machine_type = "q35"
  cpus         = var.cpus
  memory       = var.memory
  headless     = true

  # Supplying ANY -drive via qemuargs makes Packer drop ALL its default -drive entries
  # (OVMF pflash, the main disk, and the cidata seed CD). So we specify the complete
  # -drive set here, mirroring a verified-working manual qemu boot. -netdev/-device
  # (Packer's user-net + hostfwd for SSH) are NOT overridden, so they remain.
  #   vda = main OS disk, sr0 = cidata seed, vdb = DB tarball disk (read-only).
  qemuargs = [
    # Expose the real host CPU (Zen3): the default qemu64 model lacks x86-64-v2
    # features (SSE4.2/POPCNT) that conda-forge NumPy requires. The target box is
    # also Zen3, so this matches deployment.
    ["-cpu", "host"],
    ["-drive", "if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd"],
    ["-drive", "if=pflash,format=raw,file=${var.efi_vars}"],
    ["-drive", "file=${var.output_dir}/commec-box.qcow2,if=virtio,format=qcow2"],
    ["-drive", "file=${var.seed_iso},media=cdrom"],
    ["-drive", "file=${var.db_disk},if=virtio,format=raw,readonly=on"],
  ]

  ssh_username         = "commec-user"
  ssh_private_key_file = var.ssh_private_key_file
  ssh_timeout          = "30m"

  output_directory = var.output_dir
  vm_name          = "commec-box.qcow2"
  shutdown_command = "sudo shutdown -P now"
}

build {
  sources = ["source.qemu.commec"]

  # ---- upload payloads ----
  provisioner "file" {
    source      = var.miniconda_installer
    destination = "/tmp/miniconda.sh"
  }
  provisioner "file" {
    source      = "${path.root}/../firstboot"
    destination = "/tmp"
  }
  provisioner "file" {
    source      = "${path.root}/../assets"
    destination = "/tmp"
  }

  provisioner "file" {
    source      = "${path.root}/../update"
    destination = "/tmp"
  }

  # TEMPORARY (gui-branch testing): a local conda channel baked into the image so 20-commec.sh can
  # install a gui-branch dev build with COMMEC_SOURCE=gui. Empty (just .gitkeep) for stable builds.
  provisioner "file" {
    source      = "${path.root}/devchannel"
    destination = "/tmp"
  }

  # commec-gui (kiosk) source tree, staged from the gui branch. Installed by 48-commec-gui.sh.
  provisioner "file" {
    source      = "${path.root}/guisrc"
    destination = "/tmp"
  }
  # uploads <wallpaper_dir> as /tmp/wallpaper (basename of the dir is "wallpaper")
  provisioner "file" {
    source      = var.wallpaper_dir
    destination = "/tmp"
  }
  provisioner "file" {
    source      = var.db_sha256sums
    destination = "/tmp/db.SHA256SUMS"
  }

  # ---- provision ----
  provisioner "shell" {
    execute_command = "chmod +x {{ .Path }}; {{ .Vars }} sudo -E bash {{ .Path }}"
    environment_vars = [
      "COMMEC_VERSION=${var.commec_version}",
      "BIORISK_URL=${var.biorisk_url}",
      "COMMEC_SOURCE=${var.commec_source}",
      "COMMEC_CHANNEL=${var.commec_channel}",
      "COMMEC_GUI_VERSION=${var.commec_gui_version}",
      "COMMEC_UPDATE_URL=${var.commec_update_url}",
      "DEBIAN_FRONTEND=noninteractive",
    ]
    scripts = [
      "${path.root}/provision/00-base.sh",
      "${path.root}/provision/10-miniconda.sh",
      "${path.root}/provision/20-commec.sh",
      "${path.root}/provision/30-commec-setup.sh",
      "${path.root}/provision/40-desktop.sh",
      "${path.root}/provision/45-firstrun-password.sh",
      "${path.root}/provision/47-update-system.sh",
      "${path.root}/provision/48-commec-gui.sh",
      "${path.root}/provision/50-stage-dbs.sh",
      "${path.root}/provision/90-firstboot-install.sh",
      "${path.root}/provision/99-cleanup.sh",
    ]
  }

  # ---- pull the generated conda lockfile back for committing ----
  provisioner "file" {
    direction   = "download"
    source      = "/opt/commec/commec.lock"
    destination = "${path.root}/commec.lock"
  }
}
