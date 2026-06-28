#!/bin/bash
# Script hoàn chỉnh cuối cùng

if [ "$1" == "2012" ]; then 
    URL="https://www.mediafire.com/file/z9rb02f5lwy4ibt/WindowsServer2012.gz/file"
    WinVersion="2012"
elif [ "$1" == "10" ]; then 
    URL="https://www.mediafire.com/file/hpp7sdtlgnyzj4y/Windows10.gz/file"
    WinVersion="10"
elif [ "$1" == "2022" ]; then 
    URL="https://www.mediafire.com/file/qg6yk73i7vjyg33/Windows2022.gz/file"
    WinVersion="2022"
elif [ "$1" == "linode" ]; then
    URL="https://www.mediafire.com/file/0di3gve13jpieti/LinodeWindows2022.gz/file"
    WinVersion="2022"
else 
    URL="https://www.mediafire.com/file/okcaojtvpksdb9z/Windows2016.gz/file"
    WinVersion="2016"
fi

echo "URL nè: $URL"

echo "=== CÀI ĐẶT WINDOWS $WinVersion TRÊN VPS ==="

# Detect disk chứa /
ROOT=$(findmnt -no SOURCE /)
ROOT=$(readlink -f "$ROOT")

DISK=$(lsblk -ndo PKNAME "$ROOT")

if [ -n "$DISK" ]; then
    DISK="/dev/$DISK"
else
    DISK=$(lsblk -ndo NAME,TYPE | awk '$2=="disk"{print "/dev/"$1;exit}')
fi

echo "Disk hệ thống: $DISK"
lsblk

# chống ghi nhầm disk quá nhỏ
SIZE_BYTES=$(blockdev --getsize64 "$DISK")
MIN_BYTES=$((20 * 1024 * 1024 * 1024))

if [ "$SIZE_BYTES" -lt "$MIN_BYTES" ]; then
    echo "Lỗi: Disk $DISK nhỏ hơn 20GB, dừng để tránh ghi nhầm."
    exit 1
fi

WINDOWS_IMAGE_URL=$(curl -sL -A "Mozilla/5.0" "$URL" | grep -oP 'href="\Khttps://download[0-9]+\.mediafire\.com[^"]+')
echo "Direct Link: $WINDOWS_IMAGE_URL"

# Tải file về
wget -O- --no-check-certificate \
$WINDOWS_IMAGE_URL \
| gunzip | dd of="$DISK" bs=1M status=progress; \
echo 3 > /proc/sys/vm/drop_caches; \
echo s > /proc/sysrq-trigger
echo u > /proc/sysrq-trigger
echo o > /proc/sysrq-trigger
