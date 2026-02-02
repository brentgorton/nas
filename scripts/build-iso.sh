#!/bin/bash
# Build custom Debian NAS ISO with preseed automation
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="${PROJECT_DIR}/build"
OUTPUT_DIR="${PROJECT_DIR}/output"

# Debian 13 (Trixie) netinst ISO - current stable
DEBIAN_VERSION="13.3.0"
DEBIAN_CODENAME="trixie"
DEBIAN_ARCH="amd64"
DEBIAN_ISO_URL="https://cdimage.debian.org/debian-cd/current/${DEBIAN_ARCH}/iso-cd/debian-${DEBIAN_VERSION}-${DEBIAN_ARCH}-netinst.iso"
DEBIAN_ISO_FILENAME="debian-${DEBIAN_VERSION}-${DEBIAN_ARCH}-netinst.iso"
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
    log_info "Downloading Debian ${DEBIAN_VERSION} netinst ISO..."

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
    log_info "Injecting preseed configuration..."

    local iso_extract_dir="${BUILD_DIR}/iso_extract"
    local initrd_dir="${BUILD_DIR}/initrd"
    local initrd_path="${iso_extract_dir}/install.amd/initrd.gz"

    # Extract initrd
    rm -rf "$initrd_dir"
    mkdir -p "$initrd_dir"
    cd "$initrd_dir"

    gunzip -c "$initrd_path" | cpio -id 2>/dev/null || true

    # Copy preseed.cfg to initrd root
    cp "${PROJECT_DIR}/preseed/preseed.cfg" "${initrd_dir}/preseed.cfg"

    # Repack initrd
    find . | cpio -o -H newc 2>/dev/null | gzip -9 > "$initrd_path"

    cd "$PROJECT_DIR"
    log_info "Preseed injected into initrd."
}

modify_boot_menu() {
    log_info "Modifying boot menu for automated installation..."

    local iso_extract_dir="${BUILD_DIR}/iso_extract"

    # Modify BIOS boot menu (isolinux)
    local isolinux_cfg="${iso_extract_dir}/isolinux/isolinux.cfg"
    if [ -f "$isolinux_cfg" ]; then
        # Set timeout to 1 second and default to auto install
        sed -i 's/timeout 0/timeout 10/' "$isolinux_cfg"
    fi

    # Modify the txt.cfg for BIOS boot
    local txt_cfg="${iso_extract_dir}/isolinux/txt.cfg"
    if [ -f "$txt_cfg" ]; then
        # Add auto preseed to the default install option
        sed -i 's|append vga=788 initrd=/install.amd/initrd.gz|append vga=788 initrd=/install.amd/initrd.gz auto=true priority=critical preseed/file=/preseed.cfg|' "$txt_cfg"
    fi

    # Modify UEFI boot menu (grub)
    local grub_cfg="${iso_extract_dir}/boot/grub/grub.cfg"
    if [ -f "$grub_cfg" ]; then
        # Add preseed parameters to linux line
        sed -i 's|linux\s\+/install.amd/vmlinuz|linux /install.amd/vmlinuz auto=true priority=critical preseed/file=/preseed.cfg|' "$grub_cfg"
        # Set timeout
        sed -i 's/set timeout=.*/set timeout=1/' "$grub_cfg"
    fi

    log_info "Boot menu modified."
}

rebuild_iso() {
    log_info "Rebuilding ISO..."

    local iso_extract_dir="${BUILD_DIR}/iso_extract"
    mkdir -p "$OUTPUT_DIR"

    # Regenerate md5sum
    cd "$iso_extract_dir"
    find . -type f ! -name "md5sum.txt" -exec md5sum {} \; > md5sum.txt
    cd "$PROJECT_DIR"

    # Build the new ISO with both BIOS and UEFI support
    xorriso -as mkisofs \
        -r -V "Debian 13 NAS" \
        -o "${OUTPUT_DIR}/${OUTPUT_ISO}" \
        -J -joliet-long \
        -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
        -partition_offset 16 \
        -c isolinux/boot.cat \
        -b isolinux/isolinux.bin \
        -no-emul-boot -boot-load-size 4 -boot-info-table \
        -eltorito-alt-boot \
        -e boot/grub/efi.img \
        -no-emul-boot -isohybrid-gpt-basdat \
        "$iso_extract_dir"

    log_info "ISO built: ${OUTPUT_DIR}/${OUTPUT_ISO}"
}

cleanup() {
    log_info "Cleaning up build directory..."
    rm -rf "${BUILD_DIR}/iso_extract"
    rm -rf "${BUILD_DIR}/initrd"
    log_info "Cleanup complete."
}

main() {
    log_info "Starting Debian 13 NAS ISO build..."
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
