#!/bin/bash
# Build custom Debian NAS ISO with preseed automation
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="${PROJECT_DIR}/build"
OUTPUT_DIR="${PROJECT_DIR}/output"

# Debian 13 (Trixie) mini.iso - minimal network installer (~64MB)
DEBIAN_CODENAME="trixie"
DEBIAN_ARCH="amd64"
DEBIAN_ISO_URL="https://deb.debian.org/debian/dists/${DEBIAN_CODENAME}/main/installer-${DEBIAN_ARCH}/current/images/netboot/mini.iso"
DEBIAN_ISO_FILENAME="mini.iso"
OUTPUT_ISO="debian-13-nas-${DEBIAN_ARCH}.iso"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_dependencies() {
    log_info "Checking dependencies..."
    local missing=()

    for cmd in xorriso cpio gzip gunzip wget; do
        if ! command -v "$cmd" &> /dev/null; then
            missing+=("$cmd")
        fi
    done

    if [ ${#missing[@]} -ne 0 ]; then
        log_error "Missing dependencies: ${missing[*]}"
        log_info "Install with: sudo apt-get install xorriso cpio gzip wget"
        exit 1
    fi

    log_info "All dependencies found."
}

download_iso() {
    log_info "Downloading Debian ${DEBIAN_CODENAME} mini.iso..."

    if [ -f "${BUILD_DIR}/${DEBIAN_ISO_FILENAME}" ]; then
        log_info "ISO already exists, skipping download."
        return
    fi

    wget -O "${BUILD_DIR}/${DEBIAN_ISO_FILENAME}" "${DEBIAN_ISO_URL}"
    log_info "Download complete."
}

extract_iso() {
    log_info "Extracting ISO contents..."

    local iso_extract_dir="${BUILD_DIR}/iso_extract"
    rm -rf "$iso_extract_dir"
    mkdir -p "$iso_extract_dir"

    xorriso -osirrox on -indev "${BUILD_DIR}/${DEBIAN_ISO_FILENAME}" \
        -extract / "$iso_extract_dir"

    # Make files writable
    chmod -R u+w "$iso_extract_dir"

    log_info "ISO extracted to ${iso_extract_dir}"
}

inject_preseed() {
    log_info "Injecting preseed configuration and packages..."

    local iso_extract_dir="${BUILD_DIR}/iso_extract"
    local initrd_dir="${BUILD_DIR}/initrd"
    local packages_dir="${PROJECT_DIR}/packages"

    # Find the initrd file (mini.iso uses different paths)
    local initrd_path=""
    for path in "${iso_extract_dir}/initrd.gz" "${iso_extract_dir}/install.amd/initrd.gz" "${iso_extract_dir}/d-i/initrd.gz"; do
        if [ -f "$path" ]; then
            initrd_path="$path"
            break
        fi
    done

    if [ -z "$initrd_path" ]; then
        log_error "Could not find initrd.gz in ISO"
        exit 1
    fi

    log_info "Found initrd at: $initrd_path"

    # Extract initrd
    rm -rf "$initrd_dir"
    mkdir -p "$initrd_dir"
    cd "$initrd_dir"

    gunzip -c "$initrd_path" | cpio -id 2>/dev/null || true

    # Copy preseed.cfg to initrd root
    cp "${PROJECT_DIR}/preseed/preseed.cfg" "${initrd_dir}/preseed.cfg"

    # Copy custom .deb packages into initrd
    if [ -d "$packages_dir" ] && [ "$(ls -A "$packages_dir"/*.deb 2>/dev/null)" ]; then
        mkdir -p "${initrd_dir}/custom-packages"
        cp "$packages_dir"/*.deb "${initrd_dir}/custom-packages/"
        log_info "Embedded packages in initrd: $(ls "$packages_dir"/*.deb | xargs -n1 basename)"
    else
        log_warn "No .deb packages found in ${packages_dir}"
    fi

    # Repack initrd
    find . | cpio -o -H newc 2>/dev/null | gzip -9 > "$initrd_path"

    cd "$PROJECT_DIR"
    log_info "Preseed and packages injected into initrd."
}

modify_boot_menu() {
    log_info "Modifying boot menu for automated installation..."

    local iso_extract_dir="${BUILD_DIR}/iso_extract"

    # Find kernel and initrd paths relative to ISO root
    local kernel_path=""
    local initrd_path=""

    for kpath in "linux" "vmlinuz" "install.amd/vmlinuz" "d-i/vmlinuz"; do
        if [ -f "${iso_extract_dir}/${kpath}" ]; then
            kernel_path="/${kpath}"
            break
        fi
    done

    for ipath in "initrd.gz" "install.amd/initrd.gz" "d-i/initrd.gz"; do
        if [ -f "${iso_extract_dir}/${ipath}" ]; then
            initrd_path="/${ipath}"
            break
        fi
    done

    log_info "Kernel: $kernel_path, Initrd: $initrd_path"

    # Create isolinux config for BIOS boot
    mkdir -p "${iso_extract_dir}/isolinux"

    # Copy isolinux.bin if it exists, or we'll need it from the system
    if [ ! -f "${iso_extract_dir}/isolinux/isolinux.bin" ]; then
        if [ -f "/usr/lib/ISOLINUX/isolinux.bin" ]; then
            cp /usr/lib/ISOLINUX/isolinux.bin "${iso_extract_dir}/isolinux/"
        fi
    fi

    # Copy ldlinux.c32 if available
    if [ -f "/usr/lib/syslinux/modules/bios/ldlinux.c32" ]; then
        cp /usr/lib/syslinux/modules/bios/ldlinux.c32 "${iso_extract_dir}/isolinux/"
    fi

    cat > "${iso_extract_dir}/isolinux/isolinux.cfg" << ISOLINUX_EOF
default auto
timeout 10
prompt 0

label auto
    kernel ${kernel_path}
    append initrd=${initrd_path} auto=true priority=critical preseed/file=/preseed.cfg --- quiet
ISOLINUX_EOF

    # Create GRUB config for UEFI boot if grub directory exists
    if [ -d "${iso_extract_dir}/boot/grub" ]; then
        cat > "${iso_extract_dir}/boot/grub/grub.cfg" << GRUB_EOF
set timeout=1
set default=0

menuentry "Automated Install" {
    linux ${kernel_path} auto=true priority=critical preseed/file=/preseed.cfg --- quiet
    initrd ${initrd_path}
}
GRUB_EOF
    fi

    log_info "Boot menu modified."
}

rebuild_iso() {
    log_info "Rebuilding ISO..."

    local iso_extract_dir="${BUILD_DIR}/iso_extract"
    mkdir -p "$OUTPUT_DIR"

    # Regenerate md5sum
    cd "$iso_extract_dir"
    find . -type f ! -name "md5sum.txt" -exec md5sum {} \; > md5sum.txt 2>/dev/null || true
    cd "$PROJECT_DIR"

    # Check if we have UEFI support
    local uefi_opts=""
    if [ -f "${iso_extract_dir}/boot/grub/efi.img" ]; then
        uefi_opts="-eltorito-alt-boot -e boot/grub/efi.img -no-emul-boot -isohybrid-gpt-basdat"
    fi

    # Build the ISO
    xorriso -as mkisofs \
        -r -V "Debian 13 NAS" \
        -o "${OUTPUT_DIR}/${OUTPUT_ISO}" \
        -J -joliet-long \
        -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
        -partition_offset 16 \
        -c isolinux/boot.cat \
        -b isolinux/isolinux.bin \
        -no-emul-boot -boot-load-size 4 -boot-info-table \
        $uefi_opts \
        "$iso_extract_dir"

    log_info "ISO built: ${OUTPUT_DIR}/${OUTPUT_ISO}"

    # Show final size
    local size=$(du -h "${OUTPUT_DIR}/${OUTPUT_ISO}" | cut -f1)
    log_info "ISO size: $size"
}

cleanup() {
    log_info "Cleaning up build directory..."
    rm -rf "${BUILD_DIR}/iso_extract"
    rm -rf "${BUILD_DIR}/initrd"
    log_info "Cleanup complete."
}

main() {
    log_info "Starting Debian 13 NAS ISO build (mini.iso)..."
    log_info "Project directory: ${PROJECT_DIR}"

    mkdir -p "$BUILD_DIR"

    check_dependencies
    download_iso
    extract_iso
    inject_preseed
    modify_boot_menu
    rebuild_iso
    cleanup

    log_info "Build complete!"
    log_info "Output: ${OUTPUT_DIR}/${OUTPUT_ISO}"
}

main "$@"
