#!/bin/bash
# Check Windows installation status

echo "Checking Windows Installation Status"
echo "===================================="

if [ "$(id -u)" != "0" ]; then
    sudo bash "$0" "$@"
    exit $?
fi

echo "Current time: $(date)"
echo "System uptime: $(uptime)"
echo

# Check if system is still Linux
echo "Operating System Check:"
echo "----------------------"
echo "Kernel: $(uname -a)"
echo "OS: $(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d'"' -f2 || echo "Unknown")"
echo

# Check disk layout
echo "Current Disk Layout:"
echo "-------------------"
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,FSTYPE
echo

# Check what's on /dev/sda
echo "Boot Disk Analysis (/dev/sda):"
echo "------------------------------"
if [ -b /dev/sda ]; then
    echo "✓ /dev/sda exists"
    
    # Check first sector for Windows signatures
    echo "First 512 bytes of /dev/sda:"
    hexdump -C /dev/sda | head -5
    
    echo
    echo "Looking for Windows signatures:"
    if dd if=/dev/sda bs=512 count=16 2>/dev/null | strings | grep -i "ntfs\|windows\|microsoft"; then
        echo "✓ Windows signatures found!"
        WINDOWS_DETECTED=true
    else
        echo "✗ No Windows signatures detected"
        WINDOWS_DETECTED=false
    fi
    
    echo
    echo "File system detection:"
    file -s /dev/sda | head -3
    
else
    echo "✗ /dev/sda not found"
    WINDOWS_DETECTED=false
fi

echo

# Check installation logs
echo "Installation Logs:"
echo "-----------------"
for log_file in /tmp/windows_install.log /tmp/win10_boot/windows10.gz /tmp/do_boot_install.sh; do
    if [ -f "$log_file" ]; then
        echo "✓ Found: $log_file"
        echo "  Size: $(ls -lh "$log_file" | awk '{print $5}')"
        echo "  Modified: $(ls -l "$log_file" | awk '{print $6, $7, $8}')"
        
        if [[ "$log_file" == *.log ]]; then
            echo "  Content:"
            if [ -s "$log_file" ]; then
                tail -10 "$log_file" | sed 's/^/    /'
            else
                echo "    (empty log file)"
            fi
        fi
        echo
    else
        echo "✗ Not found: $log_file"
    fi
done

# Check for running installation processes
echo "Installation Processes:"
echo "----------------------"
ps aux | grep -E "(dd|gunzip|install)" | grep -v grep | head -10
if [ ${PIPESTATUS[1]} -eq 0 ]; then
    echo "✓ Installation processes found"
    INSTALLATION_RUNNING=true
else
    echo "✗ No installation processes running"
    INSTALLATION_RUNNING=false
fi

echo

# Check memory and I/O
echo "System Resources:"
echo "----------------"
echo "Memory usage:"
free -h
echo
echo "Disk I/O (if installation is running):"
iostat 1 3 2>/dev/null || echo "iostat not available"

echo

# Final analysis
echo "ANALYSIS:"
echo "========="

if [ "$WINDOWS_DETECTED" = true ]; then
    echo "🎉 SUCCESS: Windows signatures detected on /dev/sda"
    echo "   Installation appears to have completed or partially completed"
    echo "   However, system is still running Linux - this is unusual"
    echo
    echo "Possible explanations:"
    echo "1. Installation completed but system hasn't rebooted yet"
    echo "2. Installation is still in progress"
    echo "3. System is running from RAM/tmpfs"
    echo
    echo "RECOMMENDED ACTIONS:"
    echo "1. Check if installation is still running (processes above)"
    echo "2. Manually reboot the system: 'sudo reboot'"
    echo "3. Access console/VNC to see Windows boot"
    
elif [ "$INSTALLATION_RUNNING" = true ]; then
    echo "⏳ IN PROGRESS: Installation processes are still running"
    echo "   Wait for installation to complete"
    echo "   Monitor: tail -f /tmp/windows_install.log"
    
else
    echo "❌ FAILED: No Windows detected and no installation running"
    echo "   Installation likely failed or was interrupted"
    echo
    echo "TROUBLESHOOTING:"
    echo "1. Check installation logs above"
    echo "2. Check for error messages"
    echo "3. Re-run installation if needed"
fi

echo
echo "NEXT STEPS:"
echo "----------"
echo "1. If Windows is detected → Reboot system"
echo "2. If installation running → Wait and monitor"
echo "3. If failed → Check logs and retry"
echo
echo "Monitor installation: tail -f /tmp/windows_install.log"
echo "Force reboot: sudo reboot"
