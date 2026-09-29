terraform {
  required_version = ">= 1.0"
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.73"
    }
  }
}

variable "proxmox_host_endpoint" { type = string }
variable "proxmox_environment_secret" { type = string }
variable "ssh_public_key" { type = string }
variable "node_name" { type = string }
variable "vm_name" { type = string }
variable "vm_ip" { type = string }
variable "vm_gateway" { type = string }
variable "vm_cidr" { type = string }
variable "vm_dns" { type = list(string) }
variable "image_user" { type = string }

variable "proxmox_datastore_id" { type = string } # storage ID the template lives on (e.g. "proxmox-templates") - must allow the "snippets" content type
variable "template_vm_id" { type = number }       # VMID of the Flatcar template to clone from (106)

variable "proxmox_ssh_username" { type = string } # snippet uploads (source_raw) go over SSH, not the API - Proxmox has no upload endpoint for the "snippets" content type
variable "proxmox_ssh_key_path" { type = string }

variable "nfs_server" { type = string }
variable "nfs_jellyfin_export" { type = string }      # dedicated export for this VM (e.g. "/mnt/storage/jellyfin") - media and any persisted Jellyfin config live here, not on the disposable VM disk
variable "nfs_jellyfin_mount_point" { type = string } # no dashes in the path - the systemd unit name is derived from it below

variable "jellyfin_client_cidrs" { type = list(string) } # who may reach the Jellyfin web UI/API on 8096 and the Seerr request page on 5055
variable "admin_cidrs" { type = list(string) }           # who may SSH in

provider "proxmox" {
  endpoint  = var.proxmox_host_endpoint
  api_token = var.proxmox_environment_secret
  // self signed certificate
  insecure = true

  ssh {
    username    = var.proxmox_ssh_username
    private_key = file(var.proxmox_ssh_key_path)
  }
}

locals {
  static_network = join("\n", concat(
    [
      "[Match]",
      "Name=eth* en*",
      "",
      "[Network]",
      "Address=${var.vm_ip}/${var.vm_cidr}",
      "Gateway=${var.vm_gateway}",
      "LinkLocalAddressing=no", # IPv4-only - the firewall's LAN blocklist is IPv4 ranges, so don't give the VM an IPv6 path around it
      "IPv6AcceptRA=no",
    ],
    [for dns in var.vm_dns : "DNS=${dns}"],
    [""],
  ))

  # Every bind-mount source compose.yaml uses on the NFS share - see the ExecStartPre in jellyfin.service for why they're pre-created.
  nfs_dirs = [
    "config", # Jellyfin
    "media/movies", "media/shows", "media/downloads",
    "appdata/seerr", "appdata/radarr", "appdata/sonarr", "appdata/prowlarr", "appdata/qbittorrent/qBittorrent",
  ]

  # systemd requires a mount unit's name to match its path: /mnt/jellyfin -> mnt-jellyfin.mount
  nfs_mount_unit = "${replace(trimprefix(var.nfs_jellyfin_mount_point, "/"), "/", "-")}.mount"

  # Flatcar has no cloud-init, so the ecommerce VM's `mounts:` cloud-config becomes a systemd mount unit.
  # Wanted (not required) by remote-fs.target, so a missing/unreachable export fails this unit but doesn't block boot or SSH.
  nfs_mount = <<-EOF
    [Unit]
    Description=Jellyfin NFS storage
    Wants=network-online.target
    After=network-online.target

    [Mount]
    What=${var.nfs_server}:${var.nfs_jellyfin_export}
    Where=${var.nfs_jellyfin_mount_point}
    Type=nfs
    Options=defaults,_netdev

    [Install]
    WantedBy=remote-fs.target
  EOF

  # Flatcar ships the docker binary but not the compose plugin - it comes from Flatcar's sysext-bakery as a system extension.
  # Bump deliberately: https://github.com/flatcar/sysext-bakery/releases (tags "docker-compose-<version>"), hash from that release's SHA256SUMS.
  compose_sysext_file   = "docker-compose-5.5.1-x86-64.raw"
  compose_sysext_url    = "https://github.com/flatcar/sysext-bakery/releases/download/docker-compose-5.5.1/${local.compose_sysext_file}"
  compose_sysext_sha256 = "0b493085204a829ec0d7ab87c825a1b874d4fed618649c73ed7c0dc2a7457898"
  compose_sysext_path   = "/opt/extensions/docker-compose/${local.compose_sysext_file}"

  # Sandbox for the download-and-install units below. They run as root (they write root-owned system paths) but with no capabilities, a
  # read-only filesystem apart from each unit's ReadWritePaths, and a private /tmp - so a bad download or a curl bug can't reach the rest of the host.
  # Target directories are created by Ignition (storage.directories), since ProtectSystem=strict would stop the units creating them.
  install_sandbox = <<-EOF
    PrivateTmp=yes
    PrivateDevices=yes
    ProtectSystem=strict
    ProtectHome=yes
    ProtectKernelTunables=yes
    ProtectKernelModules=yes
    ProtectKernelLogs=yes
    ProtectControlGroups=yes
    ProtectClock=yes
    ProtectHostname=yes
    NoNewPrivileges=yes
    CapabilityBoundingSet=
    RestrictSUIDSGID=yes
    RestrictNamespaces=yes
    RestrictRealtime=yes
    LockPersonality=yes
    RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK
    SystemCallFilter=@system-service
    SystemCallArchitectures=native
    UMask=0022
  EOF

  # Downloaded after boot rather than by Ignition itself: Ignition fetches from the initramfs, before the static IP exists, which would need
  # DHCP - and the Proxmox firewall blocks DHCP and any source address other than vm_ip for this VM.
  # Split in two: the download runs sandboxed, the merge can't. `systemd-sysext refresh` needs its own mount namespace to read the image's
  # metadata, and RestrictNamespaces/SystemCallFilter are seccomp filters that still apply to a "+" ExecStart - it fails with
  # "Failed to read metadata for image ...: Operation not permitted". So the refresh lives in its own unsandboxed unit that runs nothing else.
  compose_download_unit = <<-EOF
    [Unit]
    Description=Download docker compose system extension
    Wants=network-online.target
    After=network-online.target
    ConditionPathExists=!/etc/extensions/docker-compose.raw

    [Service]
    Type=oneshot
    RemainAfterExit=yes
    ${local.install_sandbox}
    ReadWritePaths=/opt/extensions/docker-compose /etc/extensions
    ExecStart=/usr/bin/curl -fsSL --retry 5 --retry-all-errors -o ${local.compose_sysext_path}.tmp ${local.compose_sysext_url}
    ExecStart=/usr/bin/sh -c 'echo "${local.compose_sysext_sha256}  ${local.compose_sysext_path}.tmp" | sha256sum -c -'
    ExecStart=/usr/bin/mv ${local.compose_sysext_path}.tmp ${local.compose_sysext_path}
    ExecStart=/usr/bin/ln -sf ${local.compose_sysext_path} /etc/extensions/docker-compose.raw
  EOF

  compose_sysext_unit = <<-EOF
    [Unit]
    Description=Merge docker compose system extension
    Requires=docker-compose-download.service
    After=docker-compose-download.service

    [Service]
    Type=oneshot
    RemainAfterExit=yes
    ExecStart=/usr/bin/systemd-sysext refresh

    [Install]
    WantedBy=multi-user.target
  EOF

  # lazydocker for watching the containers - talks to the root docker socket, so run it as core (`sudo lazydocker`); a single static binary into /opt/bin (on Flatcar's default PATH).
  # Downloaded after boot for the same reason as the compose sysext above.
  # Bump deliberately: https://github.com/jesseduffield/lazydocker/releases, hash from that release's checksums.txt.
  lazydocker_version = "0.25.2"                                                           # no leading "v"
  lazydocker_sha256  = "0d9dbfc26068b218e7ed84b104748cadc6e3cf733c0afd35465306fb39b9523c" # lazydocker_0.25.2_Linux_x86_64.tar.gz
  lazydocker_url     = "https://github.com/jesseduffield/lazydocker/releases/download/v${local.lazydocker_version}/lazydocker_${local.lazydocker_version}_Linux_x86_64.tar.gz"

  lazydocker_unit = <<-EOF
    [Unit]
    Description=Install lazydocker
    Wants=network-online.target
    After=network-online.target
    ConditionPathExists=!/opt/bin/lazydocker

    [Service]
    Type=oneshot
    RemainAfterExit=yes
    ${local.install_sandbox}
    ReadWritePaths=/opt/bin
    # /tmp is private to this unit (PrivateTmp), so nothing else can swap the tarball between the hash check and the extract
    ExecStart=/usr/bin/curl -fsSL --retry 5 --retry-all-errors -o /tmp/lazydocker.tar.gz ${local.lazydocker_url}
    ExecStart=/usr/bin/sh -c 'echo "${local.lazydocker_sha256}  /tmp/lazydocker.tar.gz" | sha256sum -c -'
    ExecStart=/usr/bin/tar --no-same-owner --no-same-permissions -xzf /tmp/lazydocker.tar.gz -C /opt/bin lazydocker
    ExecStart=/usr/bin/chmod 0755 /opt/bin/lazydocker

    [Install]
    WantedBy=multi-user.target
  EOF

  # Everything under ../docker lands at /opt/jellyfin/<same path> on first boot, embedded in the Ignition snippet.
  # Small text only (configs, compose, scripts) - worker code with dependencies should be an image built in CI instead.
  docker_dir = "${path.module}/../docker"
  docker_files = [
    for f in fileset(local.docker_dir, "**") : {
      path      = "/opt/jellyfin/${f}"
      mode      = endswith(f, ".sh") ? 493 : 420 # 0755 scripts, 0644 everything else
      overwrite = true
      contents  = { source = "data:;base64,${filebase64("${local.docker_dir}/${f}")}" }
    }
  ]

  # Ignition spec v3 - written as HCL and jsonencode'd so there's no butane/ct provider to install.
  # Ignition runs once, on each clone's first boot, and reads this from the cloud-init drive's user-data.
  ignition = {
    ignition = { version = "3.3.0" }

    passwd = {
      users = [
        {
          name              = "core" # Flatcar's built-in user, already has passwordless sudo
          sshAuthorizedKeys = [var.ssh_public_key]
        },
        {
          # Deliberately NOT in "sudo" or "docker" - the docker group is root-equivalent (`docker run -v /:/host ...`).
          # It can only start/stop Jellyfin and open the inspection container, via the fixed commands in /etc/sudoers.d/jellyfin.
          # systemd-journal lets it read logs (`journalctl -u jellyfin`) without sudo - journalctl/less as root would be a shell escape.
          name              = var.image_user
          groups            = ["systemd-journal"]
          sshAuthorizedKeys = [var.ssh_public_key]
        },
      ]
    }

    storage = {
      directories = [
        {
          # local, disposable Jellyfin cache - must exist as 2000:2000 before the container starts, or Docker creates it root-owned and Jellyfin can't write
          path  = "/var/lib/jellyfin/cache"
          mode  = 493 # 0755
          user  = { id = 2000 }
          group = { id = 2000 }
        },
        # install targets for the sandboxed download units - they run with ProtectSystem=strict and can't create these themselves
        { path = "/opt/extensions/docker-compose", mode = 493 },
        { path = "/etc/extensions", mode = 493 },
        { path = "/opt/bin", mode = 493 },
      ]

      files = concat([
        {
          path      = "/etc/hostname"
          mode      = 420 # 0644
          overwrite = true
          contents  = { source = "data:,${var.vm_name}" }
        },
        {
          # "00-" so it sorts ahead of Flatcar's default DHCP .network file - networkd uses the first file that matches
          path      = "/etc/systemd/network/00-static.network"
          mode      = 420
          overwrite = true
          contents = {
            # urlencode() emits "+" for spaces, which data: URLs don't decode - swap for %20
            source = "data:,${replace(urlencode(local.static_network), "+", "%20")}"
          }
        },
        {
          # Exact commands only - sudo refuses any other arguments, and `""` means inspect.sh takes none.
          # No `systemctl status`/`journalctl` here: their pager (less) running as root can drop to a root shell.
          path      = "/etc/sudoers.d/jellyfin"
          mode      = 288 # 0440 - sudo ignores sudoers files that are writable
          overwrite = true
          contents = {
            source = "data:;base64,${base64encode(join(", ", [
              "${var.image_user} ALL=(root) NOPASSWD: /usr/bin/systemctl start jellyfin.service",
              "/usr/bin/systemctl stop jellyfin.service",
              "/usr/bin/systemctl restart jellyfin.service",
              "/opt/jellyfin/inspect.sh \"\"\n",
            ]))}"
          }
        },
        {
          # Daemon-wide defaults, so they apply even to containers started without them in compose:
          # no-new-privileges blocks setuid escalation inside containers; log caps stop a chatty container filling the disk;
          # live-restore keeps Jellyfin running across a daemon restart.
          path      = "/etc/docker/daemon.json"
          mode      = 420
          overwrite = true
          contents = {
            source = "data:;base64,${base64encode(jsonencode({
              "no-new-privileges" = true
              "live-restore"      = true
              "log-driver"        = "local"
              "log-opts"          = { "max-size" = "10m", "max-file" = "3" }
            }))}"
          }
        },
      ], local.docker_files)
    }

    systemd = {
      units = [
        {
          name     = local.nfs_mount_unit
          enabled  = true
          contents = local.nfs_mount
        },
        {
          # pulled in by docker-compose-sysext.service's Requires= - no [Install] section, so not enabled on its own
          name     = "docker-compose-download.service"
          contents = local.compose_download_unit
        },
        {
          name     = "docker-compose-sysext.service"
          enabled  = true
          contents = local.compose_sysext_unit
        },
        {
          name     = "lazydocker-install.service"
          enabled  = true
          contents = local.lazydocker_unit
        },
        # Starts Jellyfin on every boot - required for the nightly destroy/recreate.
        # RequiresMountsFor keeps it from starting before NFS is up - otherwise Docker creates an empty /mnt/jellyfin/config on the local disk and Jellyfin boots with no library.
        # ExecStartPre mkdir: Docker auto-creates missing bind-mount sources and then chowns them, which the all_squash export refuses ("chown ... operation not permitted").
        # A plain mkdir is fine - it lands as 2000:2000.
        {
          name     = "jellyfin.service"
          enabled  = true
          contents = <<-EOF
            [Unit]
            Description=Jellyfin (docker compose)
            Requires=docker.service docker-compose-sysext.service
            After=docker.service docker-compose-sysext.service network-online.target
            Wants=network-online.target
            RequiresMountsFor=${var.nfs_jellyfin_mount_point}

            [Service]
            Type=oneshot
            RemainAfterExit=yes
            TimeoutStartSec=30min
            WorkingDirectory=/opt/jellyfin
            ExecStartPre=/usr/bin/mkdir -p ${join(" ", [for d in local.nfs_dirs : "${var.nfs_jellyfin_mount_point}/${d}"])}
            # first boot only, never overwrites UI changes: seed qBittorrent's settings, see docker/qbittorrent.conf
            # (not `cp -n` - some coreutils versions exit non-zero when it skips, which would fail the unit on every later boot)
            ExecStartPre=/usr/bin/sh -c 'test -e "$$1" || cp /opt/jellyfin/qbittorrent.conf "$$1"' _ ${var.nfs_jellyfin_mount_point}/appdata/qbittorrent/qBittorrent/qBittorrent.conf
            ExecStart=/usr/bin/docker compose -f /opt/jellyfin/compose.yaml up -d --remove-orphans
            ExecStop=/usr/bin/docker compose -f /opt/jellyfin/compose.yaml down

            [Install]
            WantedBy=multi-user.target
          EOF
        },
      ]
    }
  }
}

resource "proxmox_virtual_environment_file" "jellyfin_ignition" {
  content_type = "snippets"
  datastore_id = var.proxmox_datastore_id
  node_name    = var.node_name

  source_raw {
    file_name = "${var.vm_name}-ignition.json"
    data      = jsonencode(local.ignition)
  }
}

resource "proxmox_virtual_environment_vm" "jellyfin" {
  name      = var.vm_name
  node_name = var.node_name

  clone {
    vm_id = var.template_vm_id
    full  = false # linked clone off the Flatcar template - fast to recreate, the VM is disposable
  }

  cpu {
    cores = 8
    type  = "host"
  }

  memory {
    dedicated = 4096 * 4
  }

  agent {
    enabled = true
    timeout = "30s" # default ~15m - fail fast instead of hanging if the guest agent isn't responding on a fresh clone
  }

  operating_system {
    type = "l26"
  }

  disk {
    datastore_id = var.proxmox_datastore_id
    interface    = "scsi0"
    discard      = "on"
    size         = 30 # grows the ~12.6G image disk; Flatcar expands the root partition to fill it on first boot
  }

  network_device {
    bridge   = "vmbr0"
    model    = "virtio"
    firewall = true # without this the firewall rules below exist but never attach to the NIC
  }

  serial_device {} # lets you run `qm terminal <vmid>` on the Proxmox host for a real scrolling console, instead of the noVNC display

  initialization {
    datastore_id      = var.proxmox_datastore_id
    user_data_file_id = proxmox_virtual_environment_file.jellyfin_ignition.id # replaces Proxmox's generated user-data entirely - Ignition reads it as its config, so no user_account/ip_config here (that's all in local.ignition)
  }
}

# Master switch for Proxmox's firewall - per-VM rules are ignored while it's off. Global to the whole Proxmox host, not just this VM:
# ACCEPT policies leave the host and every other VM exactly as open as before. Belongs in the server repo long term, since
# destroying this project may turn it back off.
resource "proxmox_virtual_environment_cluster_firewall" "enabled" {
  enabled       = true
  input_policy  = "ACCEPT"
  output_policy = "ACCEPT"
}

# Enforced by the Proxmox host on the VM's network interface, outside the guest - root or Docker's iptables changes inside the VM can't loosen it.
# Proxmox accepts ESTABLISHED/RELATED traffic before these rules, so replies to allowed connections (LAN streams, outbound downloads) flow both ways.
resource "proxmox_virtual_environment_firewall_options" "jellyfin" {
  depends_on = [proxmox_virtual_environment_cluster_firewall.enabled]

  node_name = var.node_name
  vm_id     = proxmox_virtual_environment_vm.jellyfin.vm_id

  enabled       = true
  input_policy  = "DROP"
  output_policy = "DROP"
  ipfilter      = true # only lets the VM send from the addresses in ipfilter-net0 - stops a compromised guest taking another VM's IP (NFS exports trust source IPs)
  macfilter     = true
  dhcp          = false # static IP from Ignition, no DHCP needed
  radv          = false
}

resource "proxmox_virtual_environment_firewall_ipset" "jellyfin_ipfilter" {
  node_name = var.node_name
  vm_id     = proxmox_virtual_environment_vm.jellyfin.vm_id
  name      = "ipfilter-net0" # magic name - ipfilter uses this set for net0
  comment   = "only address the VM may send from"

  cidr {
    name = var.vm_ip
  }
}

# First match wins, top to bottom.
resource "proxmox_virtual_environment_firewall_rules" "jellyfin" {
  node_name = var.node_name
  vm_id     = proxmox_virtual_environment_vm.jellyfin.vm_id

  rule {
    type    = "in"
    action  = "ACCEPT"
    comment = "Jellyfin clients (LAN only)"
    source  = join(",", var.jellyfin_client_cidrs)
    proto   = "tcp"
    dport   = "8096"
  }

  rule {
    type    = "in"
    action  = "ACCEPT"
    comment = "Seerr request page (LAN only) - same clients as Jellyfin; Radarr/Sonarr/Prowlarr/qBittorrent stay on 127.0.0.1, reached over SSH"
    source  = join(",", var.jellyfin_client_cidrs)
    proto   = "tcp"
    dport   = "5055"
  }

  rule {
    type    = "in"
    action  = "ACCEPT"
    comment = "admin SSH"
    source  = join(",", var.admin_cidrs)
    proto   = "tcp"
    dport   = "22"
  }

  rule {
    type    = "out"
    action  = "ACCEPT"
    comment = "NFS (v4 only needs 2049) - the one LAN destination allowed"
    dest    = var.nfs_server
    proto   = "tcp"
    dport   = "2049"
  }

  rule {
    type    = "out"
    action  = "DROP"
    comment = "no lateral movement - every private range: router UI, NAS, Proxmox, other VMs, Tailscale CGNAT"
    dest    = "10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,169.254.0.0/16,100.64.0.0/10"
  }

  rule {
    type    = "out"
    action  = "DROP"
    comment = "no IPv6 LAN paths (ULA + link-local)"
    dest    = "fc00::/7,fe80::/10"
  }

  rule {
    type    = "out"
    action  = "ACCEPT"
    comment = "public internet - downloads, DNS (1.1.1.1), NTP, image pulls"
  }
}

output "ssh" {
  value = "ssh ${var.image_user}@${var.vm_ip}"
}
