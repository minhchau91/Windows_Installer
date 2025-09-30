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

echo "URL nè: $URL"

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

cat > /tmp/windows_install.sh << EOF
#!/bin/bash

# Tải file về
wget -O- --no-check-certificate \
$WINDOWS_IMAGE_URL \
| gunzip | dd of=/dev/sda bs=1M status=progress; \
echo 3 > /proc/sys/vm/drop_caches; \
echo s > /proc/sysrq-trigger
echo u > /proc/sysrq-trigger
echo o > /proc/sysrq-trigger

EOF

chmod +x /tmp/windows_install.sh
screen -dmS windows_install /tmp/windows_install.sh
