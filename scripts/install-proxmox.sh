#!/bin/bash
# Deploy NAS VM on Proxmox with disk passthrough
#
# Usage:
#   ./install-proxmox.sh           - Create VM and install OS
#   ./install-proxmox.sh add-disks - Add passthrough disks to existing VM
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# GitHub repository for ISO releases
GITHUB_REPO="brentgorton/nas"
ISO_FILENAME="debian-13-nas-amd64.iso"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# VM configuration defaults
VM_NAME="nas"
VM_MEMORY=4096
VM_CORES=2
VM_DISK_SIZE="32G"
ISO_STORAGE=""
VM_STORAGE=""
NETWORK_BRIDGE=""
PASSTHROUGH_DISKS=()
VMID=""

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_step() {
    echo -e "\n${CYAN}${BOLD}==> $1${NC}"
}

prompt_value() {
    local prompt="$1"
    local default="$2"
    local result

    if [ -n "$default" ]; then
        read -r -p "$prompt [$default]: " result
        echo "${result:-$default}"
    else
        read -r -p "$prompt: " result
        echo "$result"
    fi
}

prompt_selection() {
    local prompt="$1"
    shift
    local options=("$@")
    local i=1

    echo "$prompt"
    for opt in "${options[@]}"; do
        echo "  $i) $opt"
        ((i++))
    done

    local selection
    while true; do
        read -r -p "Selection [1-${#options[@]}]: " selection
        if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -le "${#options[@]}" ]; then
            echo "${options[$((selection-1))]}"
            return
        fi
        echo "Invalid selection. Please enter a number between 1 and ${#options[@]}."
    done
}

prompt_yes_no() {
    local prompt="$1"
    local default="${2:-y}"
    local result

    if [ "$default" = "y" ]; then
        read -r -p "$prompt [Y/n]: " result
        result="${result:-y}"
    else
        read -r -p "$prompt [y/N]: " result
        result="${result:-n}"
    fi

    [[ "${result,,}" =~ ^y(es)?$ ]]
}

check_dependencies() {
    log_step "Checking environment"

    # Check if running on Proxmox
    if [ ! -f /etc/pve/.version ]; then
        log_error "This script must be run on a Proxmox host"
        exit 1
    fi

    log_info "Proxmox detected: $(cat /etc/pve/.version 2>/dev/null || echo 'unknown version')"

    local missing=()
    for cmd in qm pvesm pvesh curl wget jq lsblk; do
        if ! command -v "$cmd" &> /dev/null; then
            missing+=("$cmd")
        fi
    done

    if [ ${#missing[@]} -ne 0 ]; then
        log_error "Missing dependencies: ${missing[*]}"
        exit 1
    fi

    log_info "All dependencies found"
}

get_next_vmid() {
    log_step "Getting next VM ID"

    VMID=$(pvesh get /cluster/nextid 2>/dev/null)
    log_info "Next available VM ID: $VMID"
}

prompt_vm_config() {
    log_step "VM Configuration"

    VM_NAME=$(prompt_value "VM name" "$VM_NAME")
    VM_MEMORY=$(prompt_value "Memory (MB)" "$VM_MEMORY")
    VM_CORES=$(prompt_value "CPU cores" "$VM_CORES")
    VM_DISK_SIZE=$(prompt_value "System disk size" "$VM_DISK_SIZE")
}

select_storage() {
    log_step "Storage Selection"

    # Get ISO storage options
    local iso_storages
    iso_storages=$(pvesm status --content iso 2>/dev/null | tail -n +2 | awk '{print $1}' || true)

    if [ -z "$iso_storages" ]; then
        log_error "No storage available for ISO files"
        exit 1
    fi

    local iso_array
    readarray -t iso_array <<< "$iso_storages"

    if [ ${#iso_array[@]} -eq 1 ]; then
        ISO_STORAGE="${iso_array[0]}"
        log_info "Using ISO storage: $ISO_STORAGE"
    else
        ISO_STORAGE=$(prompt_selection "Select ISO storage:" "${iso_array[@]}")
    fi

    # Get VM disk storage options
    local vm_storages
    vm_storages=$(pvesm status --content images 2>/dev/null | tail -n +2 | awk '{print $1}' || true)

    if [ -z "$vm_storages" ]; then
        log_error "No storage available for VM disks"
        exit 1
    fi

    local vm_array
    readarray -t vm_array <<< "$vm_storages"

    if [ ${#vm_array[@]} -eq 1 ]; then
        VM_STORAGE="${vm_array[0]}"
        log_info "Using VM storage: $VM_STORAGE"
    else
        VM_STORAGE=$(prompt_selection "Select VM disk storage:" "${vm_array[@]}")
    fi
}

select_network() {
    log_step "Network Selection"

    local bridges
    bridges=$(pvesh get /nodes/"$(hostname)"/network --output-format json 2>/dev/null | \
              jq -r '.[] | select(.type=="bridge") | .iface' || true)

    if [ -z "$bridges" ]; then
        # Fallback to ip link
        bridges=$(ip link show type bridge 2>/dev/null | grep -oP '^\d+: \K[^:]+' || true)
    fi

    if [ -z "$bridges" ]; then
        log_warn "No network bridges detected, using vmbr0"
        NETWORK_BRIDGE="vmbr0"
        return
    fi

    local bridge_array
    readarray -t bridge_array <<< "$bridges"

    if [ ${#bridge_array[@]} -eq 1 ]; then
        NETWORK_BRIDGE="${bridge_array[0]}"
        log_info "Using network bridge: $NETWORK_BRIDGE"
    else
        NETWORK_BRIDGE=$(prompt_selection "Select network bridge:" "${bridge_array[@]}")
    fi
}

download_iso() {
    log_step "Downloading ISO"

    local iso_path
    iso_path=$(pvesm path "${ISO_STORAGE}:iso/${ISO_FILENAME}" 2>/dev/null || true)

    if [ -n "$iso_path" ] && [ -f "$iso_path" ]; then
        log_info "ISO already exists: ${ISO_STORAGE}:iso/${ISO_FILENAME}"
        if ! prompt_yes_no "Re-download ISO?" "n"; then
            return
        fi
    fi

    log_info "Fetching latest release from GitHub..."

    local release_info
    release_info=$(curl -s "https://api.github.com/repos/${GITHUB_REPO}/releases/latest")

    local download_url
    download_url=$(echo "$release_info" | jq -r '.assets[]? | select(.name=="'"${ISO_FILENAME}"'") | .browser_download_url' 2>/dev/null || true)

    if [ -z "$download_url" ] || [ "$download_url" = "null" ]; then
        log_error "Could not find ISO in latest release"
        log_info "Please ensure ${ISO_FILENAME} is available at:"
        log_info "  https://github.com/${GITHUB_REPO}/releases"
        exit 1
    fi

    log_info "Downloading from: $download_url"

    # Get the ISO storage path
    local storage_path
    storage_path=$(pvesm path "${ISO_STORAGE}:iso/" 2>/dev/null | sed 's|/iso/$|/template/iso|' || true)

    if [ -z "$storage_path" ]; then
        # Fallback: try common paths
        storage_path="/var/lib/vz/template/iso"
    fi

    # Ensure directory exists
    mkdir -p "$storage_path"

    wget -O "${storage_path}/${ISO_FILENAME}" "$download_url"
    log_info "ISO downloaded to: ${storage_path}/${ISO_FILENAME}"
}

select_passthrough_disks() {
    log_step "Disk Passthrough Selection"

    echo "Available disks for passthrough:"
    echo ""

    # Get list of physical disks
    local disks_info
    disks_info=$(lsblk -d -n -o NAME,SIZE,MODEL,TYPE 2>/dev/null | awk '$NF=="disk"' || true)

    if [ -z "$disks_info" ]; then
        log_warn "No disks found for passthrough"
        return
    fi

    # Display disks with by-id paths
    local i=1
    local disk_map=()

    while IFS= read -r line; do
        local name size model
        name=$(echo "$line" | awk '{print $1}')
        size=$(echo "$line" | awk '{print $2}')
        model=$(echo "$line" | awk '{$1=$2=""; print $0}' | xargs)

        # Find by-id path for this disk
        local by_id_path=""
        for id_path in /dev/disk/by-id/*; do
            if [ -L "$id_path" ]; then
                local target
                target=$(readlink -f "$id_path")
                if [ "$target" = "/dev/$name" ]; then
                    # Prefer ata- or scsi- paths, skip partition and wwn entries
                    if [[ "$id_path" != *-part* ]] && [[ "$id_path" != */wwn-* ]]; then
                        by_id_path="$id_path"
                        # Prefer ata- or scsi- over others
                        if [[ "$id_path" == */ata-* ]] || [[ "$id_path" == */scsi-* ]]; then
                            break
                        fi
                    fi
                fi
            fi
        done

        if [ -n "$by_id_path" ]; then
            echo "  $i) /dev/$name - $size - $model"
            echo "     $by_id_path"
            disk_map+=("$by_id_path")
            ((i++))
        fi
    done <<< "$disks_info"

    echo ""
    echo "  0) Done selecting disks"
    echo ""

    if [ ${#disk_map[@]} -eq 0 ]; then
        log_warn "No disks with stable by-id paths found"
        return
    fi

    PASSTHROUGH_DISKS=()
    while true; do
        local selection
        read -r -p "Select disk to add (0 when done): " selection

        if [ "$selection" = "0" ]; then
            break
        fi

        if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -le "${#disk_map[@]}" ]; then
            local disk="${disk_map[$((selection-1))]}"
            if [[ " ${PASSTHROUGH_DISKS[*]} " =~ " ${disk} " ]]; then
                log_warn "Disk already selected"
            else
                PASSTHROUGH_DISKS+=("$disk")
                log_info "Added: $disk"
            fi
        else
            echo "Invalid selection"
        fi
    done

    if [ ${#PASSTHROUGH_DISKS[@]} -gt 0 ]; then
        log_info "Selected ${#PASSTHROUGH_DISKS[@]} disk(s) for passthrough"
    else
        log_info "No disks selected for passthrough"
    fi
}

show_install_summary() {
    log_step "Configuration Summary"

    echo ""
    echo -e "${BOLD}VM Settings:${NC}"
    echo "  VM ID:        $VMID"
    echo "  Name:         $VM_NAME"
    echo "  Memory:       ${VM_MEMORY} MB"
    echo "  CPU Cores:    $VM_CORES"
    echo "  System Disk:  $VM_DISK_SIZE on $VM_STORAGE"
    echo ""
    echo -e "${BOLD}Network:${NC}"
    echo "  Bridge:       $NETWORK_BRIDGE"
    echo ""
    echo -e "${BOLD}Installation:${NC}"
    echo "  ISO:          ${ISO_STORAGE}:iso/${ISO_FILENAME}"
    echo ""

    if ! prompt_yes_no "Proceed with VM creation?"; then
        log_info "Aborted by user"
        exit 0
    fi
}

create_vm() {
    log_step "Creating VM"

    log_info "Creating VM $VMID ($VM_NAME)..."

    qm create "$VMID" \
        --name "$VM_NAME" \
        --memory "$VM_MEMORY" \
        --cores "$VM_CORES" \
        --cpu host \
        --net0 "virtio,bridge=${NETWORK_BRIDGE}" \
        --scsihw virtio-scsi-pci \
        --ostype l26 \
        --agent enabled=1

    log_info "Adding system disk..."
    # Strip non-numeric characters - Proxmox expects just the number
    local disk_size="${VM_DISK_SIZE//[^0-9]/}"
    qm set "$VMID" --scsi0 "${VM_STORAGE}:${disk_size}"

    log_info "Attaching ISO..."
    qm set "$VMID" --ide2 "${ISO_STORAGE}:iso/${ISO_FILENAME},media=cdrom"

    log_info "Configuring boot order..."
    qm set "$VMID" --boot order=ide2

    log_info "VM created successfully"
}

configure_passthrough() {
    if [ ${#PASSTHROUGH_DISKS[@]} -eq 0 ]; then
        return
    fi

    log_step "Configuring Disk Passthrough"

    local i=1
    for disk in "${PASSTHROUGH_DISKS[@]}"; do
        log_info "Adding scsi$i: $disk"
        qm set "$VMID" --scsi$i "$disk"
        ((i++))
    done

    log_info "Disk passthrough configured"
}

offer_start_vm() {
    log_step "VM Ready"

    echo ""
    log_info "VM $VMID ($VM_NAME) has been created"
    echo ""

    if prompt_yes_no "Start VM now?"; then
        log_info "Starting VM..."
        qm start "$VMID"
        log_info "VM started. Access console with: qm terminal $VMID"
        echo ""
        log_info "Or open the Proxmox web UI to view the installation progress"
        echo ""
        log_warn "After installation completes, run this script again with 'add-disks' to add storage:"
        log_info "  ./install-proxmox.sh add-disks"
    else
        echo ""
        log_info "Start the VM later with: qm start $VMID"
        log_info "After installation, add disks with: ./install-proxmox.sh add-disks"
    fi
}

# ============================================================================
# Add Disks Mode - Add passthrough disks to existing VM
# ============================================================================

list_nas_vms() {
    log_step "Finding NAS VMs"

    local vms
    vms=$(qm list 2>/dev/null | tail -n +2 || true)

    if [ -z "$vms" ]; then
        log_error "No VMs found"
        exit 1
    fi

    echo "Available VMs:"
    echo ""
    echo "$vms" | while read -r line; do
        local vmid name status
        vmid=$(echo "$line" | awk '{print $1}')
        name=$(echo "$line" | awk '{print $2}')
        status=$(echo "$line" | awk '{print $3}')
        echo "  $vmid - $name ($status)"
    done
    echo ""
}

select_existing_vm() {
    list_nas_vms

    while true; do
        VMID=$(prompt_value "Enter VM ID to add disks to" "")

        if [ -z "$VMID" ]; then
            log_error "VM ID is required"
            continue
        fi

        # Verify VM exists
        if ! qm status "$VMID" &>/dev/null; then
            log_error "VM $VMID does not exist"
            continue
        fi

        local vm_name
        vm_name=$(qm config "$VMID" 2>/dev/null | grep "^name:" | awk '{print $2}')
        log_info "Selected VM: $VMID ($vm_name)"
        break
    done
}

check_vm_stopped() {
    local status
    status=$(qm status "$VMID" 2>/dev/null | awk '{print $2}')

    if [ "$status" = "running" ]; then
        log_warn "VM $VMID is currently running"
        if prompt_yes_no "Stop VM to add disks?"; then
            log_info "Stopping VM..."
            qm stop "$VMID"
            sleep 3
        else
            log_error "Cannot add disks to running VM"
            exit 1
        fi
    fi
}

fix_boot_order() {
    log_step "Configuring boot settings"

    # Change boot order to disk first
    log_info "Setting boot order to disk..."
    qm set "$VMID" --boot order=scsi0

    # Detach installation CD
    log_info "Detaching installation ISO..."
    qm set "$VMID" --ide2 none,media=cdrom

    log_info "Boot configuration updated"
}

show_disks_summary() {
    log_step "Disk Configuration Summary"

    echo ""
    echo -e "${BOLD}VM:${NC} $VMID"
    echo ""
    echo -e "${BOLD}Disks to add:${NC}"
    local i=1
    for disk in "${PASSTHROUGH_DISKS[@]}"; do
        echo "  scsi$i: $disk"
        ((i++))
    done
    echo ""

    if ! prompt_yes_no "Proceed with adding disks?"; then
        log_info "Aborted by user"
        exit 0
    fi
}

offer_start_vm_after_disks() {
    log_step "Disks Added"

    echo ""
    log_info "Passthrough disks have been added to VM $VMID"
    echo ""

    local status
    status=$(qm status "$VMID" 2>/dev/null | awk '{print $2}')

    if [ "$status" != "running" ]; then
        if prompt_yes_no "Start VM now?"; then
            log_info "Starting VM..."
            qm start "$VMID"
            log_info "VM started"
        fi
    fi
}

# ============================================================================
# Main Entry Points
# ============================================================================

mode_install() {
    echo -e "${BOLD}"
    echo "========================================"
    echo "  Proxmox NAS VM Deployment"
    echo "  Phase 1: Create VM & Install OS"
    echo "========================================"
    echo -e "${NC}"

    check_dependencies
    get_next_vmid
    prompt_vm_config
    select_storage
    select_network
    download_iso
    show_install_summary
    create_vm
    offer_start_vm

    echo ""
    log_info "Phase 1 complete!"
}

mode_add_disks() {
    echo -e "${BOLD}"
    echo "========================================"
    echo "  Proxmox NAS VM Deployment"
    echo "  Phase 2: Add Passthrough Disks"
    echo "========================================"
    echo -e "${NC}"

    check_dependencies
    select_existing_vm
    check_vm_stopped
    fix_boot_order
    select_passthrough_disks

    if [ ${#PASSTHROUGH_DISKS[@]} -eq 0 ]; then
        log_warn "No disks selected"
        exit 0
    fi

    show_disks_summary
    configure_passthrough
    offer_start_vm_after_disks

    echo ""
    log_info "Phase 2 complete!"
}

show_usage() {
    echo "Usage: $0 [command]"
    echo ""
    echo "Commands:"
    echo "  install     Create VM and install OS (default)"
    echo "  add-disks   Add passthrough disks to existing VM"
    echo ""
    echo "Typical workflow:"
    echo "  1. Run '$0' to create VM and start installation"
    echo "  2. Wait for OS installation to complete"
    echo "  3. Run '$0 add-disks' to add storage drives"
}

main() {
    local command="${1:-install}"

    case "$command" in
        install|"")
            mode_install
            ;;
        add-disks)
            mode_add_disks
            ;;
        -h|--help|help)
            show_usage
            ;;
        *)
            log_error "Unknown command: $command"
            show_usage
            exit 1
            ;;
    esac
}

main "$@"
