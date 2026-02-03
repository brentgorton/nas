# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This project builds a customized Debian 13 (Trixie) ISO for automated NAS deployments. It creates a minimal, unattended installation ISO with preseed configuration that deploys a NAS system with storage pooling and file sharing capabilities.

## Build Commands

```bash
# Build the ISO (requires Linux with xorriso, cpio, gzip, wget, isolinux)
./scripts/build-iso.sh
```

Output: `output/debian-13-nas-amd64.iso`

Dependencies can be installed on Debian/Ubuntu with:
```bash
sudo apt-get install xorriso cpio gzip wget isolinux
```

## Architecture

The build process follows this flow:

1. **Download**: Fetches Debian 13 mini.iso (~64MB netboot installer)
2. **Extract**: Unpacks ISO contents using xorriso
3. **Inject**: Embeds `preseed/preseed.cfg` and any `.deb` packages from `packages/` into the initrd
4. **Modify**: Configures boot menu (isolinux/GRUB) for automated installation
5. **Rebuild**: Creates new ISO with xorriso

### Key Files

- `scripts/build-iso.sh` - Main build orchestrator with modular functions
- `preseed/preseed.cfg` - Debian installer automation (user accounts, partitioning, packages)
- `packages/*.deb` - Custom packages embedded in initrd, installed via late-command hook

### Preseed Configuration

The preseed configures:
- LVM partitioning using full disk
- User `nas` with sudo access (default password: `password`)
- Packages: mergerfs, snapraid, samba, nfs-kernel-server, openssh-server
- Late-command hook installs any `.deb` packages from `packages/` directory

## Proxmox Deployment

```bash
# Run on the Proxmox host to deploy the NAS VM
./scripts/install-proxmox.sh
```

The script interactively:
1. Prompts for VM configuration (name, RAM, CPU, disk size)
2. Selects storage for ISO and VM disks
3. Downloads the latest ISO from GitHub Releases
4. Configures disk passthrough for NAS storage drives
5. Creates and optionally starts the VM

Requirements: Proxmox VE with `qm`, `pvesm`, `pvesh`, `curl`, `wget`, `jq`

## CI/CD

GitHub Actions workflow (`.github/workflows/build-iso.yml`) builds the ISO on:
- Push to main (when preseed/scripts change)
- Pull requests
- Manual dispatch (with optional release creation)
