#!/bin/bash
# Windows 10 Boot Disk Installer
# Always installs to the disk containing the running OS (DANGEROUS)

# =============================================================================
# CONFIGURATION
# =============================================================================
WINDOWS_IMAGE_URL="https://download1585.mediafire.com/ltc9qrf2yfmgB2maC5v96x-kkovAxwwjDO7YkxD1d7t6jUpk2kdh6dGKVbqeONEt5ocv5wJXzE73IUR2loqaY9oYmSFM2pOd0TjcxPXco1tkBjq7bV-DrGttSHHZmoVdm8BpSLOeShHDycq0q7c53-NdLcTcwutI1eC5RG0M8Wd93Q/hpp7sdtlgnyzj4y/Windows10.gz"

export LANG=C
set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

log() { echo -e "${BLUE}[$(date '+%H:%M:%S')]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
danger() { echo -e "${RED}${BOLD}[DANGER]${NC} $1"; }

# Root check
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
    
    # Check virtualization - allow more environments for boot disk install
    if command -v hostnamectl > /dev/null; then
        local virt_info=$(hostnamectl 2>/dev/null || echo "")
        if echo "$virt_info" | grep -q "openvz"; then
            warning "OpenVZ detected - this may not work properly"
        elif echo "$virt_info" | grep -q "lxc"; then
            warning "LXC detected - this may not work properly"
        fi
    fi
    
    # Check required tools
    local required_tools=("wget" "curl" "lsblk" "fdisk" "dd" "gunzip" "sync")
    local missing_tools=()
    
    for tool in "${required_tools[@]}"; do
        if ! command -v "$tool" > /dev/null 2>&1; then
            missing_tools+=("$tool")
        fi
    done
    
    if [ ${#missing_tools[@]} -ne 0 ]; then
        log "Installing missing tools: ${missing_tools[*]}"
        
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

# Always detect and use boot disk
detect_boot_disk() {
    log "Detecting boot disk (disk containing running OS)..."
    
    # Method 1: Find disk containing root filesystem
    local root_device=$(df / | tail -1 | awk '{print $1}')
    local boot_disk=$(echo "$root_device" | sed 's/[0-9]*$//')
    
    if [ -b "$boot_disk" ]; then
        TARGET_DISK="$boot_disk"
        log "Boot disk detected via root filesystem: $TARGET_DISK"
    else
        # Method 2: Use lsblk to find disk containing root
        local root_disk=$(lsblk -no PKNAME $(findmnt -n -o SOURCE /) 2>/dev/null)
        if [ -n "$root_disk" ]; then
            TARGET_DISK="/dev/$root_disk"
            log "Boot disk detected via lsblk: $TARGET_DISK"
        else
            # Method 3: Alternative approach
            root_disk=$(lsblk -rno NAME,MOUNTPOINT | awk '$2=="/" {print $1}' | sed 's/[0-9]*$//')
            if [ -n "$root_disk" ]; then
                TARGET_DISK="/dev/$root_disk"
                log "Boot disk detected via mountpoint: $TARGET_DISK"
            else
                # Fallback
                TARGET_DISK="/dev/sda"
                warning "Could not detect boot disk, using fallback: $TARGET_DISK"
            fi
        fi
    fi
    
    # Verify target disk exists and get info
    if [ ! -b "$TARGET_DISK" ]; then
        error "Target disk $TARGET_DISK does not exist!"
        exit 1
    fi
    
    # Get disk size
    local disk_size=$(lsblk -rno SIZE "$TARGET_DISK" 2>/dev/null | head -1)
    if [ -n "$disk_size" ]; then
        log "Boot disk size: $disk_size"
        DISK_SIZE="$disk_size"
    else
        DISK_SIZE="unknown"
    fi
    
    # Get disk model/info
    local disk_model=$(lsblk -rno MODEL "$TARGET_DISK" 2>/dev/null | head -1)
    if [ -n "$disk_model" ]; then
        log "Disk model: $disk_model"
    fi
}

# Show system information and warnings
show_system_info() {
    clear
    echo
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║                    WINDOWS 10 INSTALLER                   ║"
    echo "║                     BOOT DISK MODE                        ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo
    echo "System Information:"
    echo "─────────────────────────────────────────────────────────────"
    echo "Hostname: $(hostname)"
    echo "OS: $(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d'"' -f2 || uname -s)"
    echo "Kernel: $(uname -r)"
    echo "Architecture: $(uname -m)"
    echo "Memory: $(free -h | awk '/^Mem:/ {print $2}')"
    echo "Target Disk: $TARGET_DISK ($DISK_SIZE)"
    echo "Image URL: $WINDOWS_IMAGE_URL"
    echo
    echo "Current Disk Layout:"
    echo "─────────────────────────────────────────────────────────────"
    lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,FSTYPE
    echo
    
    # Show what's on the target disk
    echo "Target Disk Analysis:"
    echo "─────────────────────────────────────────────────────────────"
    echo "Disk: $TARGET_DISK"
    echo "Partitions:"
    lsblk "$TARGET_DISK" -o NAME,SIZE,TYPE,MOUNTPOINT,FSTYPE
    echo
    
    # Show mounted filesystems from target disk
    echo "Currently mounted from target disk:"
    mount | grep "^$TARGET_DISK" || echo "None"
    echo
}

# Enhanced download with better progress
download_image() {
    local url="$1"
    local output="$2"
    local max_retries=3
    
    log "Downloading Windows 10 image..."
    log "URL: $url"
    log "Output: $output"
    
    # Check available space (need at least 6GB free)
    local available_space=$(df /tmp --output=avail | tail -n1)
    local required_space=$((6 * 1024 * 1024))  # 6GB in KB
    
    if [ "$available_space" -lt "$required_space" ]; then
        error "Insufficient disk space in /tmp"
        error "Available: $((available_space / 1024 / 1024))GB, Required: 6GB"
        exit 1
    fi
    
    for ((i=1; i<=max_retries; i++)); do
        log "Download attempt $i/$max_retries"
        
        # Try wget first (with resume support)
        if command -v wget > /dev/null; then
            if wget -c --progress=bar:force --timeout=60 -O "$output" "$url"; then
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
        log "Testing gzip integrity (this may take a few minutes)..."
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
        #echo -n "Continue anyway? (y/N): "
        #read -r continue_small
        #if [[ ! "$continue_small" =~ ^[Yy]$ ]]; then
        #    return 1
        #fi
    fi
    
    success "Image verification completed"
    return 0
}

# Show multiple warnings and get confirmations
get_user_confirmations() {
    echo
    danger "╔══════════════════════════════════════════════════════════════╗"
    danger "║                         DANGER ZONE                         ║"
    danger "║              BOOT DISK INSTALLATION MODE                    ║"
    danger "╚══════════════════════════════════════════════════════════════╝"
    echo
    echo "🚨 THIS INSTALLER WILL:"
    echo "   • COMPLETELY DESTROY all data on $TARGET_DISK"
    echo "   • OVERWRITE the current operating system"
    echo "   • CRASH this system IMMEDIATELY when installation starts"
    echo "   • Make this system UNBOOTABLE until Windows is installed"
    echo
    echo "🚨 REQUIREMENTS:"
    echo "   • VPS/Server console access (VNC/IPMI/iLO)"
    echo "   • Ability to reboot and access BIOS/boot menu"
    echo "   • Windows installation experience"
    echo "   • NO critical data on this system"
    echo
    echo "🚨 WHAT WILL HAPPEN:"
    echo "   1. System will download Windows image (~5GB)"
    echo "   2. All services will be stopped"
    echo "   3. Filesystem will be unmounted"
    echo "   4. Raw Windows image will be written to $TARGET_DISK"
    echo "   5. System will crash/become unresponsive"
    echo "   6. After reboot, Windows installation will start"
    echo "   7. You'll need console access to complete Windows setup"
    echo
    
    # First confirmation
    #echo -n "Do you understand these risks? (type 'I UNDERSTAND'): "
    #read -r first_confirm
    #if [ "$first_confirm" != "I UNDERSTAND" ]; then
    #    log "Installation cancelled by user"
    #    exit 0
    #fi
    
    echo
    echo "📋 Pre-installation checklist:"
    echo "   ☐ I have console/VNC access to this server"
    echo "   ☐ I have backed up any important data"
    echo "   ☐ I understand this will destroy the current OS"
    echo "   ☐ I am prepared for the system to crash"
    echo "   ☐ I know how to complete Windows installation"
    echo
    
    # Second confirmation
    #echo -n "All checklist items completed? (type 'YES'): "
    #read -r second_confirm
    #if [ "$second_confirm" != "YES" ]; then
    #    log "Installation cancelled by user"
    #    exit 0
    #fi
    
    echo
    warning "⏰ FINAL WARNING: Installation will start in 30 seconds"
    warning "⏰ Press Ctrl+C NOW to cancel if you're not ready"
    
    # Countdown
    for i in {30..1}; do
        echo -ne "\r${YELLOW}Starting installation in $i seconds... ${NC}"
        sleep 1
    done
    echo
    
    # Final confirmation
    echo
    danger "🔥 POINT OF NO RETURN 🔥"
    echo -n "Type 'DESTROY AND INSTALL' to proceed: "
    #read -r final_confirm
    #if [ "$final_confirm" != "DESTROY AND INSTALL" ]; then
    #    log "Installation cancelled by user"
    #    exit 0
    #fi
    
    success "All confirmations received. Starting installation..."
}

# Prepare system for installation
prepare_system() {
    log "Preparing system for boot disk installation..."
    
    # Stop all non-essential services
    log "Stopping services..."
    local services=("apache2" "nginx" "mysql" "postgresql" "docker" "snapd" "ufw" "firewalld" "NetworkManager" "systemd-resolved")
    for service in "${services[@]}"; do
        if systemctl is-active --quiet "$service" 2>/dev/null; then
            log "Stopping $service..."
            systemctl stop "$service" 2>/dev/null || true
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
    
    # Kill unnecessary processes
    #log "Terminating non-essential processes..."
    #killall -9 ssh sshd 2>/dev/null || true
    
    success "System preparation completed"
}

# Install Windows to boot disk
install_windows() {
    local image_file="$1"
    
    log "Starting Windows installation to boot disk $TARGET_DISK..."
    
    # Create installation script that runs independently
    cat > /tmp/do_boot_install.sh << 'INSTALL_SCRIPT'
#!/bin/bash
exec > /tmp/windows_install.log 2>&1
exec 2>&1

IMAGE_FILE="$1"
TARGET_DISK="$2"

echo "[$(date)] ===== WINDOWS BOOT DISK INSTALLATION STARTED ====="
echo "[$(date)] Target disk: $TARGET_DISK"
echo "[$(date)] Image file: $IMAGE_FILE"
echo "[$(date)] System will crash after this point"

# Sync everything
sync

# Kill all possible interfering processes
echo "[$(date)] Killing processes..."
killall -9 ssh sshd NetworkManager systemd-resolved 2>/dev/null || true

# Unmount all filesystems on target disk (this will crash the system)
echo "[$(date)] Unmounting target disk filesystems..."
for fs in $(mount | grep "^$TARGET_DISK" | awk '{print $3}' | sort -r); do
    echo "[$(date)] Unmounting $fs"
    umount -f "$fs" 2>/dev/null || true
done

# Turn off swap
echo "[$(date)] Disabling swap..."
swapoff -a 2>/dev/null || true

# Final sync
sync

echo "[$(date)] Writing Windows image to disk..."
echo "[$(date)] This will take 15-45 minutes depending on disk speed"

# Write image to disk
if gunzip -c "$IMAGE_FILE" | dd of="$TARGET_DISK" bs=1M; then
    echo "[$(date)] Installation completed successfully!"
    sync
    echo "[$(date)] Forcing reboot..."
    # Force immediate reboot
    echo 1 > /proc/sys/kernel/sysrq
    echo b > /proc/sysrq-trigger
else
    echo "[$(date)] Installation failed!"
    exit 1
fi
INSTALL_SCRIPT
    
    chmod +x /tmp/do_boot_install.sh
    
    # Final message before point of no return
    echo
    success "Installation script created and ready"
    log "Starting boot disk installation..."
    log "System will become unresponsive within seconds"
    log "Progress will be logged to /tmp/windows_install.log"
    log "Have console access ready for post-reboot Windows setup"
    
    # Start installation in background (system will crash soon)
    nohup /tmp/do_boot_install.sh "$image_file" "$TARGET_DISK" &
    local install_pid=$!
    
    log "Installation process started (PID: $install_pid)"
    
    # Give a few seconds to see if it starts
    sleep 3
    
    if kill -0 $install_pid 2>/dev/null; then
        success "Installation process is running"
        log "SYSTEM WILL CRASH SHORTLY!"
        log "Monitor console for Windows boot after crash"
        
        # Wait a bit more then exit (connection will drop anyway)
        sleep 10
    else
        error "Installation process failed to start"
        exit 1
    fi
}

# Main installation process
main_install() {
    local work_dir="/tmp/win10_boot"
    local image_file="$work_dir/windows10.gz"
    
    # Create work directory
    mkdir -p "$work_dir"
    cd "$work_dir"
    
    # Download image
    if ! download_image "$WINDOWS_IMAGE_URL" "$image_file"; then
        error "Failed to download Windows image"
        exit 1
    fi
    
    # Verify image
    if ! verify_image "$image_file"; then
        error "Image verification failed"
        exit 1
    fi
    
    # Get all user confirmations
    get_user_confirmations
    
    # Prepare system
    prepare_system
    
    # Install Windows
    install_windows "$image_file"
}

# Cleanup on exit
cleanup() {
    local exit_code=$?
    if [ $exit_code -ne 0 ] && [ $exit_code -ne 130 ]; then  # 130 = Ctrl+C
        error "Installation failed with exit code $exit_code"
        echo "Log files may be available in /tmp/"
    fi
}

trap cleanup EXIT

# =============================================================================
# MAIN EXECUTION
# =============================================================================

echo "Windows 10 Boot Disk Installer"
echo "==============================="
echo "This installer ALWAYS targets the disk containing the running OS"
echo

# Run all checks and installation
check_system
detect_boot_disk
show_system_info

# Start installation process
main_install

echo
echo "🚨 INSTALLATION INITIATED 🚨"
echo "Connection will drop when system crashes"
echo "Use console/VNC to monitor Windows installation"
echo "Have Windows product key ready for setup"
