#!/bin/bash
# Script hoàn chỉnh cuối cùng

if [ "$1" == "2012" ]; then 
    URL="https://www.mediafire.com/file/z9rb02f5lwy4ibt/WindowsServer2012.gz/file"
    WinVersion="2012"
elif [ "$1" == "10" ]; then 
    URL="https://www.mediafire.com/file/hpp7sdtlgnyzj4y/Windows10.gz/file"
    WinVersion="10"
else 
    URL="https://www.mediafire.com/file/okcaojtvpksdb9z/Windows2016.gz/file"
    WinVersion="2016"
fi

echo "URL: $URL"

echo "=== CÀI ĐẶT WINDOWS $WinVersion TRÊN VPS ==="

# Kiểm tra disk
echo "Disk hiện tại:"
lsblk

#read -p "Xác nhận xóa toàn bộ /dev/sda? (YES/no): " confirm
#if [ "$confirm" != "YES" ]; then
#    echo "Hủy bỏ"
#    exit 1
#fi

WINDOWS_IMAGE_URL=$(curl -sL -A "Mozilla/5.0" "$URL" | grep -oP 'href="\Khttps://download[0-9]+\.mediafire\.com[^"]+')
echo "Direct Link: $WINDOWS_IMAGE_URL"

# Tạo script đơn giản
#cat > /tmp/final_install.sh << SCRIPT
##!/bin/bash
exec > /tmp/windows_install.log 2>&1

echo "$(date): Bắt đầu tải Windows 10..."

# Tải file về
curl -L --insecure "$WINDOWS_IMAGE_URL" -o /tmp/windows.gz
echo "File windows already downloaded and saved in: /tmp/windows.gz"
# Giải nén và ghi sau
gunzip -c /tmp/windows.gz | dd of=/dev/sda bs=1M status=progress

echo "$(date): Hoàn thành. Đang sync và reboot..."
sync
sleep 3
reboot
#SCRIPT

chmod +x /tmp/final_install.sh

# Chạy với screen để có thể detach
#screen -dmS windows_install 
#bash /tmp/final_install.sh

echo "Quá trình cài đặt đã bắt đầu!"
echo "Xem tiến trình:"
echo "  screen -r windows_install  # Attach vào session"
echo "  tail -f /tmp/windows_install.log  # Xem log"
echo ""
echo "Disconnect SSH ngay để tránh gián đoạn!"
