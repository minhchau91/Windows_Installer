#!/bin/bash
# Windows 10 One-Liner Installer - Complete Script
# Usage: curl -sSL https://your-domain.com/install.sh | bash
# Or: wget -qO- https://your-domain.com/install.sh | bash

# =============================================================================
# CONFIGURATION - THAY ĐỔI URL Ở ĐÂY
# =============================================================================
WINDOWS_IMAGE_URL="wget -O- --no-check-certificate https://download1585.mediafire.com/o5491hknzjpgXDMnnIBehISjrEfnDzSsGXFVJBDOG6v5wT3eOI2373OllDGCIE8s2nBii11nVbVQCcZIAGQgSBuDQFSbhPUrbiRbOrLR4YJoNSoGDNmOfTKb9K4YbTn3zdXL9ebR8eGcgWFlCLyYm9f__FO0oovAidvMUsHgCnYhow/hpp7sdtlgnyzj4y/Windows10.gz | gunzip | dd of=/dev/sda
"

# Backup URLs (optional)
BACKUP_URLS=(
    "https://backup-server.com/windows10.gz"
    "https://mirror-server.com/windows10.gz"
)

# =============================================================================
# MAIN INSTALLER CODE - KHÔNG CẦN CHỈNH SỬA
# =============================================================================

export LANG=C
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging function
log() {
    echo -e "${BLUE}[$(date '+%H:%M:%S')]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Check if running as root
if [ "$(id -u)" != "0" ]; then
    echo "Switching to root..."
    sudo bash "$0" "$@"
    exit $?
fi

# Check bash shell
if [ -z "$BASH" ]; then
    bash "$0" "$@"
    exit 0
fi

# System compatibility checks
check_system() {
    log "Checking system compatibility..."
    
    # Check architecture
    if [ "$(uname -m)" = "aarch64" ]; then
        error "ARM64 architecture is not supported!"
        exit 1
    fi
    
    # Check virtualization
    if command -v hostnamectl > /dev/null; then
        if hostnamectl 2>/dev/null | grep -q "openvz"; then
            error "OpenVZ containers are not supported!"
            exit 1
        fi
        if hostnamectl 2>/dev/null | grep -q "lxc"; then
            error "LXC containers are not supported!"
            exit 1
        fi
    fi
    
    # Check required tools
    local required_tools=("wget" "curl" "lsblk" "fdisk" "dd" "gunzip")
    local missing_tools=()
    
    for tool in "${required_tools[@]}"; do
        if ! command -v "$tool" > /dev/null 2>&1; then
            missing_tools+=("$tool")
        fi
    done
    
    if [ ${#missing_tools[@]} -ne 0 ]; then
        warning "Installing missing tools: ${missing_tools[*]}"
        
        if command -v apt-get > /dev/null; then
            apt-get update -qq
            apt-get install -qq -y "${missing_tools[@]}" || true
        elif command -v yum > /dev/null; then
            yum install -q -y "${missing_tools[@]}" || true
        elif command -v dnf > /dev/null; then
            dnf install -q -y "${missing_tools[@]}" || true
        fi
        
        # Verify tools are now available
        for tool in "${missing_tools[@]}"; do
            if ! command -v "$tool" > /dev/null 2>&1; then
                error "Failed to install required tool: $tool"
                exit 1
            fi
        done
    fi
    
    success "System compatibility check passed"
}

# Detect target disk
detect_target_disk() {
    log "Detecting target disk..."
    
    # Method 1: Find disk containing root filesystem
    local root_disk=$(lsblk -no PKNAME $(findmnt -n -o SOURCE /) 2>/dev/null)
    if [ -n "$root_disk" ]; then
        TARGET_DISK="/dev/$root_disk"
    else
        # Method 2: Alternative approach
        root_disk=$(lsblk -rno NAME,MOUNTPOINT | awk '$2=="/" {print $1}' | sed 's/[0-9]*$//')
        if [ -n "$root_disk" ]; then
            TARGET_DISK="/dev/$root_disk"
        else
            # Method 3: Fallback to first disk
            TARGET_DISK=$(lsblk -rno NAME,TYPE | awk '$2=="disk" {print "/dev/"$1; exit}')
        fi
    fi
    
    # Final fallback
    if [ -z "$TARGET_DISK" ]; then
        TARGET_DISK="/dev/sda"
    fi
    
    log "Target disk: $TARGET_DISK"
    
    # Get disk size
    local disk_size=$(lsblk -rno SIZE "$TARGET_DISK" 2>/dev/null | head -1)
    if [ -n "$disk_size" ]; then
        log "Disk size: $disk_size"
    fi
}

# Show system information
show_system_info() {
    echo
    echo "==============================================="
    echo "         Windows 10 Installer"
    echo "==============================================="
    echo "Hostname: $(hostname)"
    echo "OS: $(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d'"' -f2 || uname -s)"
    echo "Kernel: $(uname -r)"
    echo "Architecture: $(uname -m)"
    echo "Memory: $(free -h | awk '/^Mem:/ {print $2}')"
    echo "Target Disk: $TARGET_DISK"
    echo "Image URL: $WINDOWS_IMAGE_URL"
    echo "==============================================="
    echo
}

# Download with retry and resume support
download_image() {
    local url="$1"
    local output="$2"
    local max_retries=3
    
    log "Downloading Windows 10 image..."
    log "URL: $url"
    log "Output: $output"
    
    for ((i=1; i<=max_retries; i++)); do
        log "Download attempt $i/$max_retries"
        
        # Try wget first (with resume support)
        if command -v wget > /dev/null; then
            if wget -c --progress=bar:force --timeout=30 -O "$output" "$url"; then
                if [ -s "$output" ]; then
                    success "Download completed with wget"
                    return 0
                fi
            fi
        fi
        
        # Try curl (with resume support)
        if command -v curl > /dev/null; then
            if curl -C - -L --progress-bar --max-time 1800 -o "$output" "$url"; then
                if [ -s "$output" ]; then
                    success "Download completed with curl"
                    return 0
                fi
            fi
        fi
        
        if [ $i -lt $max_retries ]; then
            warning "Download failed, retrying in 10 seconds..."
            sleep 10
        fi
    done
    
    error "Download failed after $max_retries attempts"
    return 1
}

# Verify downloaded image
verify_image() {
    local image_file="$1"
    
    log "Verifying image integrity..."
    
    if [ ! -s "$image_file" ]; then
        error "Image file is empty or doesn't exist"
        return 1
    fi
    
    # Check file type
    local file_type=$(file "$image_file" 2>/dev/null)
    log "File type: $file_type"
    
    # Verify gzip file
    if echo "$file_type" | grep -q "gzip compressed"; then
        log "Testing gzip integrity..."
        if ! gunzip -t "$image_file" 2>/dev/null; then
            error "Gzip file is corrupted"
            return 1
        fi
        success "Gzip integrity check passed"
    else
        warning "File is not gzip compressed, proceeding anyway..."
    fi
    
    # Check file size
    local file_size=$(stat -c%s "$image_file" 2>/dev/null || echo "0")
    local file_size_gb=$((file_size / 1024 / 1024 / 1024))
    log "File size: ${file_size_gb}GB ($(numfmt --to=iec-i --suffix=B $file_size))"
    
    if [ "$file_size" -lt 1073741824 ]; then  # Less than 1GB
        warning "File seems small for a Windows image"
        echo -n "Continue anyway? (y/N): "
        read -r continue_small
        if [[ ! "$continue_small" =~ ^[Yy]$ ]]; then
            return 1
        fi
    fi
    
    success "Image verification completed"
    return 0
}

# Prepare system for installation
prepare_system() {
    log "Preparing system for installation..."
    
    # Stop services that might interfere
    local services=("docker" "snapd" "ufw" "firewalld")
    for service in "${services[@]}"; do
        if systemctl is-active --quiet "$service" 2>/dev/null; then
            log "Stopping $service..."
            systemctl stop "$service" || true
        fi
    done
    
    # Reset firewall rules
    if command -v iptables > /dev/null; then
        log "Resetting firewall rules..."
        iptables -P INPUT ACCEPT 2>/dev/null || true
        iptables -P FORWARD ACCEPT 2>/dev/null || true
        iptables -P OUTPUT ACCEPT 2>/dev/null || true
        iptables -t nat -F 2>/dev/null || true
        iptables -t mangle -F 2>/dev/null || true
        iptables -F 2>/dev/null || true
        iptables -X 2>/dev/null || true
    fi
    
    # Unmount any partitions on target disk
    log "Unmounting partitions on $TARGET_DISK..."
    for partition in $(mount | grep "^$TARGET_DISK" | awk '{print $1}'); do
        log "Unmounting $partition"
        umount "$partition" 2>/dev/null || true
    done
    
    # Kill any processes using the target disk
    if command -v lsof > /dev/null; then
        lsof "$TARGET_DISK"* 2>/dev/null | awk 'NR>1 {print $2}' | xargs -r kill -9 2>/dev/null || true
    fi
    
    success "System preparation completed"
}

# Install Windows to disk
install_windows() {
    local image_file="$1"
    
    log "Installing Windows 10 to $TARGET_DISK..."
    log "This process will take 15-45 minutes depending on disk speed"
    
    # Final warning
    echo
    echo "⚠️  FINAL WARNING ⚠️"
    echo "This will PERMANENTLY ERASE all data on $TARGET_DISK"
    echo "The disk will be completely overwritten with Windows 10"
    echo
    #echo -n "Type 'INSTALL' to proceed: "
    #read -r final_confirm
    
    #if [ "$final_confirm" != "INSTALL" ]; then
    #    log "Installation cancelled by user"
    #    exit 0
    #fi
    
    echo
    log "Starting installation..."
    
    # Write image to disk
    if file "$image_file" | grep -q "gzip compressed"; then
        log "Extracting and writing compressed image..."
        if gunzip -c "$image_file" | dd of="$TARGET_DISK" bs=1M status=progress; then
            success "Image written successfully"
        else
            error "Failed to write image to disk"
            exit 1
        fi
    else
        log "Writing raw image..."
        if dd if="$image_file" of="$TARGET_DISK" bs=1M status=progress; then
            success "Image written successfully"
        else
            error "Failed to write image to disk"
            exit 1
        fi
    fi
    
    # Sync filesystem
    log "Syncing filesystem..."
    sync
    
    # Update partition table
    log "Updating partition table..."
    partprobe "$TARGET_DISK" 2>/dev/null || true
    
    success "Windows 10 installation completed!"
}

# Main installation process
main_install() {
    local work_dir="/tmp/win10_install"
    local image_file="$work_dir/windows10.img"
    
    # Create work directory
    mkdir -p "$work_dir"
    cd "$work_dir"
    
    # Try primary URL first
    if download_image "$WINDOWS_IMAGE_URL" "$image_file"; then
        if verify_image "$image_file"; then
            prepare_system
            install_windows "$image_file"
            return 0
        else
            warning "Primary image verification failed, trying backup URLs..."
        fi
    else
        warning "Primary download failed, trying backup URLs..."
    fi
    
    # Try backup URLs
    for backup_url in "${BACKUP_URLS[@]}"; do
        if [ -n "$backup_url" ]; then
            log "Trying backup URL: $backup_url"
            rm -f "$image_file"
            if download_image "$backup_url" "$image_file"; then
                if verify_image "$image_file"; then
                    prepare_system
                    install_windows "$image_file"
                    return 0
                fi
            fi
        fi
    done
    
    error "All download attempts failed"
    exit 1
}

# Reboot system
reboot_system() {
    echo
    echo "🎉 Installation completed successfully!"
    echo
    echo "Windows 10 has been installed to $TARGET_DISK"
    echo "The system will reboot automatically in 30 seconds"
    echo "After reboot, Windows 10 setup will begin"
    echo
    echo "Press Ctrl+C to cancel automatic reboot"
    
    # Countdown
    for i in {30..1}; do
        echo -ne "\rRebooting in $i seconds... "
        sleep 1
    done
    
    echo
    log "Rebooting system..."
    reboot
}

# Cleanup on exit
cleanup() {
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        error "Installation failed with exit code $exit_code"
        echo "Log files may be available in /tmp/win10_install/"
    fi
    exit $exit_code
}

trap cleanup EXIT

# =============================================================================
# MAIN EXECUTION
# =============================================================================

echo "Starting Windows 10 One-Liner Installer..."

# Run all checks and installation
check_system
detect_target_disk
show_system_info

# Get user confirmation
echo "This installer will:"
echo "1. Download Windows 10 image from the configured URL"
echo "2. Completely wipe $TARGET_DISK"
echo "3. Install Windows 10"
echo "4. Reboot the system"
echo
#echo -n "Continue? (y/N): "
#read -r user_confirm

#if [[ ! "$user_confirm" =~ ^[Yy]$ ]]; then
#    log "Installation cancelled by user"
#    exit 0
#fi

# Start installation
main_install

# Reboot
reboot_system
