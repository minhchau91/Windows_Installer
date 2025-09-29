#!/bin/bash
# Script hoàn chỉnh cuối cùng

echo "=== CÀI ĐẶT WINDOWS 10 TRÊN VPS ==="

# Kiểm tra disk
echo "Disk hiện tại:"
lsblk

#read -p "Xác nhận xóa toàn bộ /dev/sda? (YES/no): " confirm
#if [ "$confirm" != "YES" ]; then
#    echo "Hủy bỏ"
#    exit 1
#fi

# Tạo script đơn giản
cat > /tmp/final_install.sh << 'SCRIPT'
#!/bin/bash
exec > /tmp/windows_install.log 2>&1

echo "$(date): Bắt đầu tải Windows 10..."

# Tải và ghi trực tiếp
curl -L --insecure \
"https://download1585.mediafire.com/1nexu7kctydggScpB4gxrEW_LWBHC5RxHWi5OeA4G3fCQZ7t4OdlgA__-vFjetuK0Po1xAPXknvoCsXa9-SQcdKbLCmeOHIL_9HAPQ1kJ0gIVE6G4Yufg6bgBvLiJAGg1phBJN3dD-dxCP_zyDl7u_rPhNAL5IOMXRcJec23tJB8tA/hpp7sdtlgnyzj4y/Windows10.gz" \
| gunzip | dd of=/dev/sda bs=1M status=progress

echo "$(date): Hoàn thành. Đang sync và reboot..."
sync
sleep 3
reboot
SCRIPT

chmod +x /tmp/final_install.sh

# Chạy với screen để có thể detach
screen -dmS windows_install /tmp/final_install.sh

echo "Quá trình cài đặt đã bắt đầu!"
echo "Xem tiến trình:"
echo "  screen -r windows_install  # Attach vào session"
echo "  tail -f /tmp/windows_install.log  # Xem log"
echo ""
echo "Disconnect SSH ngay để tránh gián đoạn!"
