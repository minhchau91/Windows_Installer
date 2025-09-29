#!/bin/bash
# Windows 10 VPS Installer - Production Safe Version
# This version is designed specifically for VPS environments

# =============================================================================
# CONFIGURATION
# =============================================================================
WINDOWS_IMAGE_URL="https://download1585.mediafire.com/o5491hknzjpgXDMnnIBehISjrEfnDzSsGXFVJBDOG6v5wT3eOI2373OllDGCIE8s2nBii11nVbVQCcZIAGQgSBuDQFSbhPUrbiRbOrLR4YJoNSoGDNmOfTKb9K4YbTn3zdXL9ebR8eGcgWFlCLyYm9f__FO0oovAidvMUsHgCnYhow/hpp7sdtlgnyzj4y/Windows10.gz"

export LANG=C

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${BLUE}[$(date '+%H:%M:%S')]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }

# Root check
if [ "$(id -u)" != "0" ]; then
    sudo bash "$0" "$@"
    exit $?
fi

# VPS Detection and Warning
detect_vps_environment() {
    log "Detecting VPS environment..."
    
    VPS_TYPE="unknown"
    
    # Check for common VPS indicators
    if [ -d /proc/vz ]; then
        VPS_TYPE="OpenVZ"
    elif [ -f /.dockerenv ]; then
        VPS_TYPE="Docker"
    elif systemd-detect-virt >/dev/null 2>&1; then
        VPS_TYPE=$(systemd-detect-virt)
    elif dmesg | grep -i "hypervisor" >/dev/null 2>&1; then
        VPS_TYPE="VM"
    fi
    
    # Check cloud providers
    if curl -s --connect-timeout 3 http://169.254.169.254/latest/meta-data/instance-id >/dev/null 2>&1; then
        CLOUD_PROVIDER="AWS"
    elif curl -s --connect-timeout 3 -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/id >/dev/null 2>&1; then
        CLOUD_PROVIDER="GCP"
    elif curl -s --connect-timeout 3 -H "Metadata: true" http://169.254.169.254/metadata/instance/compute/vmId >/dev/null 2>&1; then
        CLOUD_PROVIDER="Azure"
    else
        CLOUD_PROVIDER="Unknown"
    fi
    
    log "Environment: $VPS_TYPE on $CLOUD_PROVIDER"
    
    # Warnings for problematic environments
    if [ "$VPS_TYPE" = "OpenVZ" ] || [ "$VPS_TYPE" = "lxc" ]; then
        error "Container environments ($VPS_TYPE) are not supported!"
        error "This installer requires full virtualization (KVM/Xen/VMware)"
        exit 1
    fi
}

# Improved disk detection for VPS
detect_vps_disk() {
    log "Detecting VPS disk configuration..."
    
    # Show current disk layout
    echo
    echo "Current disk layout:"
    lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,FSTYPE
    echo
    
    # Find the boot disk
    BOOT_DISK=$(df / | tail -1 | awk '{print $1}' | sed 's/[0-9]*$//')
    log "Boot disk detected: $BOOT_DISK"
    
    # Check if there are multiple disks
    DISK_COUNT=$(lsblk -rno NAME,TYPE | awk '$2=="disk"' | wc -l)
    log "Total disks found: $DISK_COUNT"
    
    if [ "$DISK_COUNT" -eq 1 ]; then
        warning "Only one disk found - this is the boot disk!"
        warning "Installing Windows will immediately crash this system"
        echo
        echo "RECOMMENDED SOLUTIONS:"
        echo "1. Add a second disk to your VPS"
        echo "2. Create a snapshot/backup first"
        echo "3. Use rescue mode installation"
        echo "4. Use cloud provider's Windows image instead"
        echo
        #read -p "Continue with single disk anyway? (type 'CRASH'): " crash_confirm
        
        #if [ "$crash_confirm" != "CRASH" ]; then
        #    log "Installation cancelled for safety"
        #    exit 0
        #fi
        
        TARGET_DISK="$BOOT_DISK"
        DANGEROUS_MODE=true
    else
        # Multiple disks - let user choose
        echo "Multiple disks detected:"
        lsblk -rno NAME,SIZE,TYPE | awk '$3=="disk" {print NR ". /dev/" $1 " (" $2 ")"}'
        echo
        #read -p "Select target disk number (or 'auto' for second disk): " disk_choice
        
        #if [ "$disk_choice" = "auto" ]; then
        TARGET_DISK=$(lsblk -rno NAME,TYPE | awk '$2=="disk" {print "/dev/" $1}' | sed -n '2p')
        #else
        #    TARGET_DISK=$(lsblk -rno NAME,TYPE | awk '$2=="disk" {print "/dev/" $1}' | sed -n "${disk_choice}p")
        #fi
        
        DANGEROUS_MODE=false
    fi
    
    if [ -z "$TARGET_DISK" ]; then
        error "Could not determine target disk"
        exit 1
    fi
    
    log "Target disk: $TARGET_DISK"
    
    # Final safety check
    if [ "$TARGET_DISK" = "$BOOT_DISK" ]; then
        warning "TARGET DISK IS THE SAME AS BOOT DISK!"
        warning "THIS WILL CRASH THE SYSTEM IMMEDIATELY!"
        DANGEROUS_MODE=true
    fi
}

# Download function optimized for VPS
download_image_vps() {
    local url="$1"
    local output="$2"
    
    log "Starting download from MediaFire..."
    log "Expected size: ~5GB"
    log "Estimated time: 5-15 minutes on typical VPS connection"
    
    # Check available space
    local available_space=$(df /tmp --output=avail | tail -n1)
    local required_space=$((6 * 1024 * 1024))  # 6GB in KB
    
    if [ "$available_space" -lt "$required_space" ]; then
        error "Insufficient disk space in /tmp"
        error "Available: $((available_space / 1024 / 1024))GB, Required: 6GB"
        exit 1
    fi
    
    # Download with progress
    if wget -c --progress=bar:force --timeout=60 -O "$output" "$url"; then
        if [ -s "$output" ]; then
            success "Download completed"
            return 0
        fi
    fi
    
    error "Download failed"
    return 1
}

# Safe installation for VPS
install_windows_vps() {
    local image_file="$1"
    
    log "Preparing for VPS Windows installation..."
    
    if [ "$DANGEROUS_MODE" = true ]; then
        echo
        echo "🚨 DANGER MODE ACTIVE 🚨"
        echo "Installing to boot disk will crash system immediately"
        echo "Make sure you have:"
        echo "- VPS console access (VNC/KVM)"
        echo "- Rescue mode available"
        echo "- Recent backup/snapshot"
        echo
        echo "The system will:"
        echo "1. Become unresponsive immediately after dd starts"
        echo "2. Reboot to Windows installation"
        echo "3. Require console access for Windows setup"
        echo
        #read -p "Final confirmation - type 'DANGEROUS': " final_confirm
        
        #if [ "$final_confirm" != "DANGEROUS" ]; then
        #    log "Installation cancelled"
        #    exit 0
        #fi
        
        log "Starting dangerous installation in 15 seconds..."
        log "Last chance to abort with Ctrl+C..."
        
        for i in {15..1}; do
            echo -ne "\rStarting in $i seconds... "
            sleep 1
        done
        echo
    fi
    
    # Create installation script that will run even if session disconnects
    cat > /tmp/do_install.sh << 'INSTALL_SCRIPT'
#!/bin/bash
exec > /tmp/windows_install.log 2>&1

echo "[$(date)] Starting Windows installation..."
echo "Target disk: $TARGET_DISK"
echo "Image file: $1"

# Kill everything we can
killall -9 ssh sshd 2>/dev/null || true

# Unmount target disk
for partition in $(mount | grep "^$TARGET_DISK" | awk '{print $1}'); do
    echo "[$(date)] Unmounting $partition"
    umount "$partition" 2>/dev/null || true
done

# Final sync
sync

echo "[$(date)] Writing image to disk..."
if gunzip -c "$1" | dd of="$TARGET_DISK" bs=1M; then
    echo "[$(date)] Installation completed successfully"
    sync
    sleep 5
    echo "[$(date)] Rebooting..."
    reboot -f
else
    echo "[$(date)] Installation failed"
    exit 1
fi
INSTALL_SCRIPT
    
    chmod +x /tmp/do_install.sh
    
    # Start installation in background
    log "Starting installation process..."
    log "Progress will be logged to /tmp/windows_install.log"
    
    nohup /tmp/do_install.sh "$image_file" &
    local install_pid=$!
    
    log "Installation started (PID: $install_pid)"
    
    if [ "$DANGEROUS_MODE" = true ]; then
        log "System will become unresponsive shortly..."
        log "Monitor via console/VNC for Windows boot"
    fi
    
    # Monitor for a few seconds
    sleep 5
    
    if kill -0 $install_pid 2>/dev/null; then
        success "Installation process is running"
        if [ "$DANGEROUS_MODE" = true ]; then
            log "You should disconnect now - system will crash soon"
        fi
    else
        error "Installation process failed to start"
        exit 1
    fi
}

# Main VPS installation
main() {
    echo "Windows 10 VPS Installer"
    echo "========================"
    
    detect_vps_environment
    detect_vps_disk
    
    echo
    echo "Installation Summary:"
    echo "- Environment: $VPS_TYPE on $CLOUD_PROVIDER"
    echo "- Target disk: $TARGET_DISK"
    echo "- Dangerous mode: $DANGEROUS_MODE"
    echo "- Image URL: $WINDOWS_IMAGE_URL"
    echo
    
    # Download image
    local work_dir="/tmp/win10_vps"
    local image_file="$work_dir/windows10.gz"
    
    mkdir -p "$work_dir"
    cd "$work_dir"
    
    if ! download_image_vps "$WINDOWS_IMAGE_URL" "$image_file"; then
        error "Failed to download Windows image"
        exit 1
    fi
    
    # Verify image
    log "Verifying image..."
    if ! gunzip -t "$image_file"; then
        error "Downloaded image is corrupted"
        exit 1
    fi
    
    local file_size=$(stat -c%s "$image_file")
    log "Image size: $((file_size / 1024 / 1024))MB"
    
    # Install
    install_windows_vps "$image_file"
    
    echo
    echo "Installation initiated!"
    echo "Monitor: tail -f /tmp/windows_install.log"
    
    if [ "$DANGEROUS_MODE" = true ]; then
        echo
        echo "SYSTEM WILL CRASH SHORTLY!"
        echo "Have console access ready"
        echo "Windows should boot after reboot"
    fi
}

# Run main function
main "$@"
