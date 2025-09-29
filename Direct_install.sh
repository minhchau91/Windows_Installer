#!/bin/bash
# Script hoàn chỉnh cuối cùng

echo "=== CÀI ĐẶT WINDOWS TRÊN VPS ==="

# Kiểm tra disk
echo "Disk hiện tại:"
lsblk

#read -p "Xác nhận xóa toàn bộ /dev/sda? (YES/no): " confirm
#if [ "$confirm" != "YES" ]; then
#    echo "Hủy bỏ"
#    exit 1
#fi

case "$1" in
  2012)
    URL="https://www.mediafire.com/file/z9rb02f5lwy4ibt/WindowsServer2012.gz/file"
    ;;
  10)
    URL="https://www.mediafire.com/file/hpp7sdtlgnyzj4y/Windows10.gz/file"
    ;;
  *)
    URL="https://www.mediafire.com/file/okcaojtvpksdb9z/Windows2016.gz/file"
    ;;
esac

WINDOWS_IMAGE_URL=$(curl -s "$URL" | grep 'download1585' | grep -oP 'href="\K[^"]+')

# Tạo script đơn giản
cat > /tmp/final_install.sh << 'SCRIPT'
#!/bin/bash
exec > /tmp/windows_install.log 2>&1

echo "$(date): Bắt đầu tải Windows 10..."

# Tải và ghi trực tiếp
curl -L --insecure \
$WINDOWS_IMAGE_URL \
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
