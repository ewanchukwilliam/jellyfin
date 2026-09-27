Architecture

This project deploys Jellyfin as a disposable, reproducible workload on Proxmox. The primary goals are strong isolation of untrusted media processing, minimal persistent state on the application VM, and the ability to regularly destroy and recreate the entire compute environment from a known-good base.

Architecture Overview

Physical Server
│
├── Proxmox VE
│   │
│   ├── QEMU/KVM
│   │   │
│   │   └── Flatcar Linux VM
│   │       │
│   │       └── Docker
│   │           │
│   │           ├── Jellyfin
│   │           │
│   │           └── Media Scanner
│   │               ├── ffprobe / FFmpeg
│   │               ├── file / libmagic
│   │               └── ClamAV
│   │
│   └── Proxmox Firewall / Network Policy
│
└── Persistent Storage
    └── Media

The primary isolation boundary is a QEMU/KVM virtual machine. Containers provide an additional isolation layer inside the VM, but the VM boundary is treated as the security boundary protecting the Proxmox host.

Flatcar Base Image

The VM runs Flatcar Container Linux.

Rather than installing Flatcar from an ISO, the official Flatcar Proxmox/QEMU disk image is imported directly into Proxmox:

flatcar_production_proxmoxve_image.img
        ↓
Proxmox VM
        ↓
Proxmox VM template

The current base template is VM 106 (flatcar-template).

Its Flatcar disk resides on the NFS-backed proxmox-templates Proxmox storage rather than local-lvm:

proxmox-templates:106/vm-106-disk-0.raw

The imported disk is attached as:

scsi0

using:

virtio-scsi-single

and configured as the VM’s boot device.

The template intentionally contains very little environment-specific configuration. Its purpose is to provide a known-good Flatcar installation from which deployment VMs can be cloned.

Terraform

Terraform owns deployed VM configuration and lifecycle.

The Flatcar template itself is maintained separately from the normal Terraform lifecycle. Terraform does not reinstall Flatcar whenever the Jellyfin VM is recreated.

Instead:

Flatcar template
      ↓
Terraform
      ↓
Proxmox linked clone
      ↓
Disposable Jellyfin VM

Terraform defines instance-specific resources such as:

* CPU and memory
* networking
* firewall policy
* IP configuration
* storage/mount configuration
* instance provisioning
* VM lifecycle

The template’s CPU and memory settings are therefore not authoritative. Terraform overrides them when creating the actual workload VM.

Linked clones are used where appropriate:

clone {
  vm_id = var.template_vm_id
  full  = false
}

This allows new VMs to be created quickly without duplicating the complete base disk.

Provisioning

Flatcar uses Ignition rather than traditional cloud-init for host provisioning.

Ignition is responsible for machine-level configuration required when a new Flatcar VM is created, such as:

* SSH authorized keys
* systemd units
* mounts
* files required by the host
* other boot-time Flatcar configuration

Deployment-specific configuration should not be manually baked into the golden template when it can instead be declared reproducibly.

Container Runtime

Flatcar provides Docker/containerd as part of the container-host environment.

The host remains intentionally minimal. Utilities used to inspect potentially hostile media are not installed into the Flatcar host OS.

Instead, application and diagnostic software runs in containers.

Flatcar
│
└── Docker
    ├── Jellyfin container
    └── Media scanner container

Jellyfin

Jellyfin runs as a Docker container rather than directly on Flatcar.

Its deployment is defined declaratively, with a pinned container version/digest rather than relying on a mutable latest tag.

Conceptually:

Jellyfin container
├── /config
├── /cache
└── /media → persistent media storage

Persistent media should be mounted read-only into Jellyfin wherever Jellyfin does not require write access.

Runtime configuration, secrets, caches, media, and Terraform state are not stored in Git.

Untrusted Media Scanning

Media files are treated as potentially hostile input.

Parsers such as FFmpeg/ffprobe and libmagic process complex attacker-controlled file structures and therefore should not unnecessarily execute directly on the Flatcar host.

A dedicated diagnostic/scanner container contains tools such as:

ffprobe / FFmpeg
file / libmagic
ClamAV
sha256sum
stat

The scanner should operate with restrictive container settings where practical:

read-only container filesystem
no network access
all unnecessary Linux capabilities dropped
no-new-privileges
read-only media mount
resource limits

Conceptually:

Potentially hostile media
        ↓
read-only mount
        ↓
Scanner container
        ↓
ffprobe / file / ClamAV

A compromise of one of these parsers therefore first encounters the container boundary.

If the container boundary is escaped, the attacker reaches the disposable Flatcar guest rather than the Proxmox host.

Reaching the physical host would additionally require escaping the QEMU/KVM VM boundary.

Security Boundaries

The intended containment model is:

Potentially malicious media
          ↓
Parser
          ↓
Docker container
          ↓
Flatcar guest
          ↓
QEMU/KVM
          ↓
Proxmox host
          ↓
Physical server

Containers are defense in depth; they are not considered equivalent to a VM security boundary.

The Flatcar VM should therefore have minimal access to the surrounding infrastructure:

* no unnecessary Proxmox host mounts
* no unnecessary device passthrough
* no host credentials
* restricted network access
* read-only media access where possible
* minimal services exposed
* firewall policy managed declaratively

Flatcar’s minimal/image-based design also reduces the amount of general-purpose host software exposed inside the guest.

Disposable VM Lifecycle

The workload VM is designed to be disposable.

The intended lifecycle is approximately:

Known-good Flatcar template
          ↓
Terraform creates VM
          ↓
Ignition configures VM
          ↓
Docker starts workloads
          ↓
Jellyfin operates
          ↓
VM destroyed
          ↓
fresh clone created

The VM may be destroyed and recreated on a regular schedule, potentially daily.

Consequently, compromise of the guest should have limited opportunity to establish long-term persistence in the compute environment.

Anything that must survive recreation belongs on explicitly designated persistent storage rather than the VM’s disposable root disk.

Nightly Recreation

Recreate only the VM, not the whole Terraform project:

terraform apply -auto-approve -replace=proxmox_virtual_environment_vm.jellyfin

Do not use terraform destroy for this. The project also manages the Proxmox firewall master switch (proxmox_virtual_environment_cluster_firewall), and destroying it can turn the Proxmox firewall off for every VM on the host.

-replace clones a fresh VM from the template, and Ignition runs again on its first boot with the current contents of docker/. Media and Jellyfin config live on NFS and are unaffected.

Starting Jellyfin

Flatcar ships the docker binary but not the compose plugin. The docker-compose-sysext.service unit (terraform/jellyfinflatcar.tf) downloads Docker Compose from Flatcar's sysext-bakery on first boot, verifies it against a pinned SHA-256, and enables it as a system extension. The template is not modified.

Jellyfin starts automatically on boot via the jellyfin.service unit in terraform/jellyfinflatcar.tf. On a fresh VM the first start includes pulling the image, so it can take several minutes. To check:

ssh williamewanchuk@192.168.1.61
systemctl status docker-compose-sysext jellyfin
docker compose -f /opt/jellyfin/compose.yaml logs -f

The unit waits for the NFS mount (RequiresMountsFor); without it, Docker would create an empty /mnt/jellyfin/config on the local disk and Jellyfin would start with no library. It also creates config/ and media/ on the share before starting: Docker's own auto-creation of missing mount folders tries to chown them, which the all_squash NFS export refuses.

Image Caching

Container images may be pre-pulled into the Flatcar Proxmox template to reduce recreation time.

For example:

Flatcar template
└── Docker image cache
    ├── Jellyfin @ pinned digest
    └── media-scanner @ pinned digest

Because the deployment uses Proxmox linked clones, these cached layers can be inherited from the template rather than downloaded from the Internet every time a VM is recreated.

The template should be deliberately rebuilt when upgrading:

* Flatcar
* Jellyfin
* scanner tooling
* Docker images
* other trusted base components

This separates the trusted image-update process from routine VM recreation.

Persistent vs. Disposable State

The architecture deliberately separates persistent data from disposable compute.

PERSISTENT                    DISPOSABLE
Media                         Flatcar VM
Jellyfin configuration*       Container runtime state
Terraform state               Scanner containers
Required application data     Temporary files
                              Caches where practical

* Jellyfin configuration may be persisted if preserving server configuration, users, metadata, and library state across VM recreation is desired.

Destroying the Flatcar VM should therefore not destroy the media library or other intentionally persistent state.

Repository Responsibility

This repository describes how the Jellyfin environment is constructed, rather than storing its runtime data.

A likely structure is:

jellyfin-infra/
├── terraform/
│   ├── main.tf
│   ├── variables.tf
│   └── ...
│
├── ignition/
│   └── flatcar.bu
│
├── docker/
│   ├── compose.yaml
│   └── scanner/
│       └── Dockerfile
│
└── scripts/
    └── ...

The desired end state is that creation of the workload environment requires little or no manual configuration:

known-good Proxmox template
            +
       repository
            ↓
     terraform apply
            ↓
working disposable Jellyfin environment

The Proxmox template establishes the trusted base machine; Terraform defines the infrastructure; Ignition configures the Flatcar instance; and Docker defines the actual application workloads.
