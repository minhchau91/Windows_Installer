```bash
#!/bin/bash

#
# ============================================================
# WINDOWS VPS AUTO INSTALLER
# ============================================================
#
# Flow:
#
# 1. Detect disk
# 2. Validate disk
# 3. Generate random Administrator password
# 4. Echo password
# 5. POST password lên API
# 6. Chỉ tiếp tục nếu API HTTP 2xx
# 7. Chuẩn bị tool cần thiết vào RAM (/dev/shm)
# 8. Download + gunzip + dd Windows image
# 9. Detect Windows partition
# 10. Mount Windows NTFS
# 11. Inject PowerShell đổi password
# 12. Inject Windows service chạy LocalSystem
# 13. Unmount + sync
# 14. drop_caches + sysrq shutdown
#
# Không cần rebuild Windows image.
#
# ============================================================


set -u
set -o pipefail


# ============================================================
# CONFIG
# ============================================================

API_ENDPOINT="https://example.com/api/windows-password"

# Nếu không dùng token thì để rỗng.
API_TOKEN=""

#
# Ví dụ chạy:
#
# ./install.sh 2022 12345
#
# $1 = Windows version
# $2 = VPS ID
#
VPS_ID="${2:-}"


# ============================================================
# WINDOWS IMAGE
# ============================================================

case "${1:-}" in

    2012)
        URL="https://www.mediafire.com/file/z9rb02f5lwy4ibt/WindowsServer2012.gz/file"
        WinVersion="2012"
        ;;

    10)
        URL="https://www.mediafire.com/file/hpp7sdtlgnyzj4y/Windows10.gz/file"
        WinVersion="10"
        ;;

    2022)
        URL="https://www.mediafire.com/file/qg6yk73i7vjyg33/Windows2022.gz/file"
        WinVersion="2022"
        ;;

    linode)
        URL="https://www.mediafire.com/file/yxsf6jrm2zutzim/LinodeWindows2022.gz/file"
        WinVersion="2022"
        ;;

    *)
        URL="https://www.mediafire.com/file/okcaojtvpksdb9z/Windows2016.gz/file"
        WinVersion="2016"
        ;;

esac


echo
echo "======================================================"
echo "      CÀI ĐẶT WINDOWS $WinVersion TRÊN VPS"
echo "======================================================"
echo
echo "MediaFire URL:"
echo "$URL"
echo


# ============================================================
# REQUIRE ROOT
# ============================================================

if [ "$(id -u)" -ne 0 ]; then
    echo "Lỗi: Script phải chạy bằng root."
    exit 1
fi


# ============================================================
# DETECT SYSTEM DISK
# ============================================================

ROOT=$(findmnt -no SOURCE /)
ROOT=$(readlink -f "$ROOT")

echo "Root filesystem:"
echo "$ROOT"
echo


DISK_PARENT=$(lsblk -ndo PKNAME "$ROOT" 2>/dev/null || true)


if [ -n "$DISK_PARENT" ]; then

    DISK="/dev/$DISK_PARENT"

else

    #
    # Fallback: lấy disk đầu tiên.
    #

    DISK=$(
        lsblk -ndo NAME,TYPE \
        | awk '$2=="disk"{print "/dev/"$1; exit}'
    )

fi


if [ -z "${DISK:-}" ] || [ ! -b "$DISK" ]; then
    echo "Lỗi: Không detect được system disk."
    exit 1
fi


echo "Disk hệ thống:"
echo "$DISK"
echo

lsblk

echo


# ============================================================
# SAFETY CHECK
# ============================================================

SIZE_BYTES=$(blockdev --getsize64 "$DISK")

MIN_BYTES=$((15 * 1024 * 1024 * 1024))


if [ "$SIZE_BYTES" -lt "$MIN_BYTES" ]; then

    echo
    echo "======================================================"
    echo "LỖI:"
    echo "$DISK nhỏ hơn 15GB."
    echo
    echo "Dừng để tránh ghi nhầm disk."
    echo "======================================================"

    exit 1

fi


echo "Disk size:"
echo "$SIZE_BYTES bytes"
echo


# ============================================================
# INSTALL REQUIRED PACKAGES
#
# Phải làm TRƯỚC dd.
# ============================================================

echo "=== Cài đặt công cụ cần thiết ==="

export DEBIAN_FRONTEND=noninteractive


apt-get update || {
    echo "apt-get update thất bại."
    exit 1
}


apt-get install -y \
    curl \
    wget \
    gzip \
    openssl \
    chntpw \
    kpartx \
    ntfs-3g \
    util-linux || {

        echo "Không cài được các package cần thiết."
        exit 1
    }


echo
echo "Tool preparation OK."
echo


# ============================================================
# GENERATE PASSWORD
# ============================================================

#
# Chỉ dùng charset không gây rắc rối cho:
#
# Bash
# JSON
# PowerShell
# net.exe
#
# Password:
#
# 16 random alphanumeric
# +
# Aa1!
#

RANDOM_BASE=$(
    openssl rand -base64 64 \
    | tr -dc 'A-Za-z0-9' \
    | head -c 16
)


if [ "${#RANDOM_BASE}" -ne 16 ]; then

    echo "Lỗi: Không generate được random password."
    exit 1

fi


WIN_PASSWORD="${RANDOM_BASE}Aa1!"


# ============================================================
# ECHO PASSWORD
# ============================================================

echo
echo "======================================================"
echo "          WINDOWS INSTALL INFORMATION"
echo "======================================================"
echo
echo "Windows Version : $WinVersion"
echo "Username        : Administrator"
echo "Password        : $WIN_PASSWORD"
echo "VPS ID          : ${VPS_ID:-N/A}"
echo
echo "======================================================"
echo


# ============================================================
# JSON ESCAPE
#
# Password hiện tại chỉ dùng charset an toàn nên thực tế không
# cần escape phức tạp.
# ============================================================

JSON_PAYLOAD=$(printf \
    '{"vps_id":"%s","windows_version":"%s","username":"Administrator","password":"%s"}' \
    "$VPS_ID" \
    "$WinVersion" \
    "$WIN_PASSWORD"
)


# ============================================================
# SEND PASSWORD TO API
#
# QUAN TRỌNG:
#
# Nếu API fail -> STOP.
# Không đụng tới disk.
# ============================================================

echo "=== Gửi password lên API ==="
echo

API_RESPONSE_FILE="/tmp/windows-install-api-response.$$"


if [ -n "$API_TOKEN" ]; then

    HTTP_CODE=$(
        curl \
            --silent \
            --show-error \
            --connect-timeout 10 \
            --max-time 30 \
            --retry 3 \
            --retry-delay 2 \
            --output "$API_RESPONSE_FILE" \
            --write-out "%{http_code}" \
            -X POST \
            "$API_ENDPOINT" \
            -H "Content-Type: application/json" \
            -H "Authorization: Bearer $API_TOKEN" \
            --data "$JSON_PAYLOAD"
    )

    CURL_STATUS=$?

else

    HTTP_CODE=$(
        curl \
            --silent \
            --show-error \
            --connect-timeout 10 \
            --max-time 30 \
            --retry 3 \
            --retry-delay 2 \
            --output "$API_RESPONSE_FILE" \
            --write-out "%{http_code}" \
            -X POST \
            "$API_ENDPOINT" \
            -H "Content-Type: application/json" \
            --data "$JSON_PAYLOAD"
    )

    CURL_STATUS=$?

fi


echo


# ============================================================
# CHECK CURL
# ============================================================

if [ "$CURL_STATUS" -ne 0 ]; then

    echo
    echo "======================================================"
    echo "API ERROR"
    echo "======================================================"
    echo
    echo "curl exit code: $CURL_STATUS"
    echo
    echo "Windows installation CANCELLED."
    echo "Disk CHƯA bị ghi đè."
    echo

    rm -f "$API_RESPONSE_FILE"

    exit 1

fi


# ============================================================
# CHECK HTTP STATUS
# ============================================================

case "$HTTP_CODE" in

    200|201|202|204)

        echo "API xác nhận thành công."
        echo "HTTP status: $HTTP_CODE"

        ;;

    *)

        echo
        echo "======================================================"
        echo "API KHÔNG XÁC NHẬN THÀNH CÔNG"
        echo "======================================================"
        echo
        echo "HTTP status: $HTTP_CODE"

        if [ -s "$API_RESPONSE_FILE" ]; then

            echo
            echo "API response:"
            cat "$API_RESPONSE_FILE"
            echo

        fi

        echo
        echo "Windows installation CANCELLED."
        echo "Disk CHƯA bị ghi đè."
        echo

        rm -f "$API_RESPONSE_FILE"

        exit 1

        ;;

esac


if [ -s "$API_RESPONSE_FILE" ]; then

    echo
    echo "API response:"
    cat "$API_RESPONSE_FILE"
    echo

fi


rm -f "$API_RESPONSE_FILE"


echo
echo "======================================================"
echo "Password đã được lưu lên API."
echo "Bắt đầu quá trình cài Windows."
echo "======================================================"
echo


# ============================================================
# GET MEDIAFIRE DIRECT LINK
#
# Thực hiện trước dd.
# ============================================================

echo "=== Lấy MediaFire direct link ==="


WINDOWS_IMAGE_URL=$(
    curl \
        -sL \
        -A "Mozilla/5.0" \
        "$URL" \
    | grep -oP \
        'href="\Khttps://download[0-9]+\.mediafire\.com[^"]+' \
    | head -n1
)


if [ -z "$WINDOWS_IMAGE_URL" ]; then

    echo
    echo "Lỗi: Không lấy được MediaFire direct URL."
    echo
    echo "Disk chưa bị ghi đè."

    exit 1

fi


echo
echo "Direct Link:"
echo "$WINDOWS_IMAGE_URL"
echo


# ============================================================
# TEST DOWNLOAD URL
# ============================================================

echo "Kiểm tra image URL..."


curl \
    --silent \
    --show-error \
    --fail \
    --location \
    --range 0-1023 \
    --max-time 30 \
    "$WINDOWS_IMAGE_URL" \
    -o /dev/null


if [ $? -ne 0 ]; then

    echo
    echo "Lỗi: Windows image không thể download."
    echo "Dừng trước khi ghi disk."

    exit 1

fi


echo "Image URL OK."
echo


# ============================================================
# PREPARE RAM ENVIRONMENT
#
# Sau dd, filesystem Ubuntu trên $DISK sẽ bị ghi đè.
#
# Do đó:
#
# - Copy script vào RAM
# - Copy binary cần dùng sau dd vào RAM
# - Copy shared libraries vào RAM
#
# ============================================================

RAMROOT="/dev/shm/windows-installer-runtime"

rm -rf "$RAMROOT"

mkdir -p "$RAMROOT"
mkdir -p "$RAMROOT/bin"
mkdir -p "$RAMROOT/libs"


# ============================================================
# COPY CURRENT SCRIPT TO RAM
#
# Giúp bash không còn phụ thuộc file script trên root disk.
# ============================================================

if [ -f "$0" ]; then
    cp -f "$0" "$RAMROOT/installer-source.sh" 2>/dev/null || true
fi


# ============================================================
# COPY BINARY + DEPENDENCIES
# ============================================================

copy_binary()
{
    local CMD="$1"
    local BIN

    BIN=$(command -v "$CMD" 2>/dev/null || true)


    if [ -z "$BIN" ]; then

        echo "WARNING: Không tìm thấy command: $CMD"
        return 1

    fi


    cp -L "$BIN" "$RAMROOT/bin/$CMD"


    #
    # Copy shared libraries.
    #

    ldd "$BIN" 2>/dev/null \
    | awk '
        /=> \// { print $3 }
        /^[[:space:]]*\// { print $1 }
    ' \
    | while read -r LIB
    do

        [ -f "$LIB" ] || continue

        mkdir -p "$RAMROOT/libs$(dirname "$LIB")"

        cp -L \
            "$LIB" \
            "$RAMROOT/libs$LIB"

    done


    return 0
}


#
# Command cần SAU dd.
#

POST_DD_COMMANDS=(
    bash
    kpartx
    reged
    mount
    umount
    sync
    sleep
    mkdir
    rm
    cat
    grep
    sed
    awk
    head
    basename
    printf
    tr
    find
)


for CMD in "${POST_DD_COMMANDS[@]}"
do
    copy_binary "$CMD" || true
done


#
# ntfs-3g có thể nằm /usr/bin hoặc /bin.
#

copy_binary ntfs-3g || true
copy_binary mount.ntfs-3g || true


# ============================================================
# COPY DYNAMIC LINKER
# ============================================================

while read -r LOADER
do

    [ -f "$LOADER" ] || continue

    mkdir -p "$RAMROOT/libs$(dirname "$LOADER")"

    cp -L \
        "$LOADER" \
        "$RAMROOT/libs$LOADER"

done < <(
    find \
        /lib \
        /lib64 \
        /usr/lib \
        /usr/lib64 \
        -type f \
        \( \
            -name 'ld-linux*.so*' \
            -o \
            -name 'ld-*.so*' \
        \) \
        2>/dev/null
)


# ============================================================
# RUNTIME WRAPPER
# ============================================================

cat > "$RAMROOT/run" <<'EOF'
#!/bin/bash

RAMROOT="/dev/shm/windows-installer-runtime"

#
# Include common Debian/Ubuntu library locations.
#

export LD_LIBRARY_PATH="\
$RAMROOT/libs/lib:\
$RAMROOT/libs/lib64:\
$RAMROOT/libs/usr/lib:\
$RAMROOT/libs/usr/lib64:\
$RAMROOT/libs/lib/x86_64-linux-gnu:\
$RAMROOT/libs/usr/lib/x86_64-linux-gnu:\
$RAMROOT/libs/lib/aarch64-linux-gnu:\
$RAMROOT/libs/usr/lib/aarch64-linux-gnu"


CMD="$1"
shift


exec "$RAMROOT/bin/$CMD" "$@"
EOF


chmod +x "$RAMROOT/run"


RUN="$RAMROOT/run"


# ============================================================
# VERIFY IMPORTANT RAM TOOLS
# ============================================================

for CMD in kpartx reged mount umount sync
do

    if [ ! -x "$RAMROOT/bin/$CMD" ]; then

        echo
        echo "Lỗi: Không copy được $CMD vào RAM."
        echo "Dừng trước khi ghi disk."

        exit 1

    fi

done


echo "RAM runtime prepared."
echo


# ============================================================
# CREATE POWERSHELL SCRIPT IN RAM
#
# Làm trước dd.
#
# Password được nhúng tại đây.
# ============================================================

POWERSHELL_FILE="$RAMROOT/SetPassword.ps1"


cat > "$POWERSHELL_FILE" <<EOF
\$ErrorActionPreference = "Stop"


\$Password = '${WIN_PASSWORD}'


try {

    #
    # Built-in Administrator luôn có RID 500
    # SID kết thúc bằng -500.
    #
    # Get-WmiObject có trên Windows Server 2012 trở lên.
    #

    \$Admin = Get-WmiObject Win32_UserAccount |
        Where-Object {

            \$_.LocalAccount -eq \$true -and
            \$_.SID -match '-500\$'

        } |
        Select-Object -First 1


    if (-not \$Admin) {

        throw "Cannot find local Administrator account SID ending -500"

    }


    \$AdminName = \$Admin.Name


    #
    # Enable Administrator.
    #

    & "\$env:SystemRoot\\System32\\net.exe" \
        user \
        "\$AdminName" \
        /active:yes


    if (\$LASTEXITCODE -ne 0) {

        throw "Failed to enable Administrator. Exit code: \$LASTEXITCODE"

    }


    #
    # Change password.
    #

    & "\$env:SystemRoot\\System32\\net.exe" \
        user \
        "\$AdminName" \
        "\$Password"


    if (\$LASTEXITCODE -ne 0) {

        throw "Failed to set Administrator password. Exit code: \$LASTEXITCODE"

    }


    #
    # Success marker.
    #

    \$SuccessMessage = @"
Password changed successfully.
Account: \$AdminName
Time: \$(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
"@


    \$SuccessMessage |
        Set-Content \
            "C:\\VPSSetup\\password-changed.txt"


    #
    # Disable service immediately.
    #
    # Nếu delete thất bại, service cũng không chạy lại.
    #

    & "\$env:SystemRoot\\System32\\sc.exe" \
        config \
        VPSInitialPassword \
        start= disabled


    #
    # Delete service registration.
    #

    & "\$env:SystemRoot\\System32\\sc.exe" \
        delete \
        VPSInitialPassword


    #
    # Tạo cleanup script.
    #
    # Password plaintext hiện nằm trong SetPassword.ps1,
    # nên sau khi hoàn tất phải xóa file.
    #

    \$Cleanup = @'
@echo off
ping 127.0.0.1 -n 8 >nul
del /f /q C:\\VPSSetup\\SetPassword.ps1
del /f /q "%~f0"
'@


    \$Cleanup |
        Set-Content \
            "C:\\VPSSetup\\cleanup.cmd" \
            -Encoding ASCII


    Start-Process \
        -FilePath "cmd.exe" \
        -ArgumentList "/c C:\\VPSSetup\\cleanup.cmd" \
        -WindowStyle Hidden


    exit 0

}
catch {

    \$Message = @"

==============================
\$(Get-Date -Format "yyyy-MM-dd HH:mm:ss")

\$($_ | Out-String)

"@


    \$Message |
        Out-File \
            "C:\\VPSSetup\\password-error.txt" \
            -Append


    #
    # Không disable service nếu lỗi.
    #
    # Windows sẽ thử lại ở lần boot tiếp theo.
    #

    exit 1

}
EOF


# ============================================================
# PREPARE REGISTRY FILE
# ============================================================

SERVICE_REG="$RAMROOT/VPSInitialPassword.reg"


#
# Chưa biết Current ControlSet.
# File sẽ được tạo sau khi đọc SYSTEM hive.
#


# ============================================================
# FINAL WARNING BEFORE DD
# ============================================================

echo
echo "======================================================"
echo "API STATUS : SUCCESS"
echo
echo "Windows Password:"
echo "$WIN_PASSWORD"
echo
echo "Bắt đầu ghi image vào:"
echo "$DISK"
echo
echo "TỪ THỜI ĐIỂM NÀY UBUNTU SẼ BỊ GHI ĐÈ."
echo "======================================================"
echo


# ============================================================
# WRITE WINDOWS IMAGE
# ============================================================

echo "=== WRITE WINDOWS IMAGE ==="
echo


wget \
    -O- \
    --no-check-certificate \
    "$WINDOWS_IMAGE_URL" \
| gunzip \
| dd \
    of="$DISK" \
    bs=4M \
    status=progress \
    conv=fsync


PIPE_RESULT=("${PIPESTATUS[@]}")


WGET_STATUS="${PIPE_RESULT[0]}"
GUNZIP_STATUS="${PIPE_RESULT[1]}"
DD_STATUS="${PIPE_RESULT[2]}"


echo
echo "wget   status: $WGET_STATUS"
echo "gunzip status: $GUNZIP_STATUS"
echo "dd     status: $DD_STATUS"
echo


if [ "$WGET_STATUS" -ne 0 ] || \
   [ "$GUNZIP_STATUS" -ne 0 ] || \
   [ "$DD_STATUS" -ne 0 ]; then

    echo
    echo "======================================================"
    echo "CRITICAL ERROR"
    echo "======================================================"
    echo
    echo "Windows image write FAILED."
    echo
    echo "Không shutdown tự động."
    echo "Kiểm tra console VPS."
    echo

    exit 1

fi


echo
echo "Windows image write complete."
echo


# ============================================================
# IMPORTANT
#
# TỪ ĐÂY CHỈ DÙNG TOOL ĐÃ COPY VÀO /dev/shm
# càng nhiều càng tốt.
# ============================================================


# ============================================================
# CREATE DEVICE MAPPER PARTITIONS
# ============================================================

echo "=== Detect Windows partitions ==="


"$RUN" sync


"$RUN" kpartx \
    -av \
    "$DISK"


KPARTX_STATUS=$?


if [ "$KPARTX_STATUS" -ne 0 ]; then

    echo
    echo "CRITICAL: kpartx failed."
    echo "Không thể detect Windows partition."
    echo

    exit 1

fi


"$RUN" sleep 3


echo
echo "Partition mappings created."
echo


# ============================================================
# FIND WINDOWS PARTITION
# ============================================================

MOUNT_DIR="/dev/shm/windows-mounted"

"$RUN" mkdir -p "$MOUNT_DIR"


DISK_NAME="${DISK##*/}"

WINDOWS_PART=""


#
# kpartx thường tạo:
#
# /dev/mapper/sda1
#
# hoặc:
#
# /dev/mapper/nvme0n1p1
#
# tùy tên disk / phiên bản kpartx.
#

CANDIDATES=""


for DEV in \
    /dev/mapper/${DISK_NAME}p* \
    /dev/mapper/${DISK_NAME}[0-9]*
do

    if [ -b "$DEV" ]; then
        CANDIDATES="$CANDIDATES $DEV"
    fi

done


if [ -z "$CANDIDATES" ]; then

    echo
    echo "Không tìm thấy partition mapping từ kpartx."
    echo

    exit 1

fi


echo "Các partition candidate:"

for PART in $CANDIDATES
do
    echo "  $PART"
done

echo


# ============================================================
# MOUNT EACH PARTITION
# ============================================================

for PART in $CANDIDATES
do

    echo "Thử partition:"
    echo "$PART"


    #
    # Thử ntfs-3g trước.
    #

    if [ -x "$RAMROOT/bin/ntfs-3g" ]; then

        "$RUN" ntfs-3g \
            "$PART" \
            "$MOUNT_DIR" \
            -o rw,remove_hiberfile \
            2>/dev/null

        MOUNT_STATUS=$?

    else

        "$RUN" mount \
            -t ntfs \
            -o rw \
            "$PART" \
            "$MOUNT_DIR" \
            2>/dev/null

        MOUNT_STATUS=$?

    fi


    if [ "$MOUNT_STATUS" -ne 0 ]; then

        echo "  Không mount được."
        continue

    fi


    #
    # Windows partition phải có SYSTEM + SOFTWARE hive.
    #

    if [ -f "$MOUNT_DIR/Windows/System32/config/SYSTEM" ] && \
       [ -f "$MOUNT_DIR/Windows/System32/config/SOFTWARE" ]; then

        WINDOWS_PART="$PART"

        echo
        echo "======================================================"
        echo "WINDOWS PARTITION FOUND"
        echo "$WINDOWS_PART"
        echo "======================================================"
        echo

        break

    fi


    "$RUN" umount "$MOUNT_DIR" 2>/dev/null || true

done


# ============================================================
# WINDOWS PARTITION NOT FOUND
# ============================================================

if [ -z "$WINDOWS_PART" ]; then

    echo
    echo "======================================================"
    echo "CRITICAL ERROR"
    echo "======================================================"
    echo
    echo "Không tìm thấy Windows partition."
    echo
    echo "Password đã được API lưu:"
    echo "$WIN_PASSWORD"
    echo
    echo "Nhưng password CHƯA được inject vào Windows."
    echo
    echo "Không shutdown tự động."
    echo

    exit 1

fi


# ============================================================
# CREATE VPS DIRECTORY
# ============================================================

VPS_DIR="$MOUNT_DIR/VPSSetup"


"$RUN" mkdir -p "$VPS_DIR"


# ============================================================
# COPY POWERSHELL INTO WINDOWS
# ============================================================

"$RUN" cat "$POWERSHELL_FILE" \
    > "$VPS_DIR/SetPassword.ps1"


if [ ! -s "$VPS_DIR/SetPassword.ps1" ]; then

    echo
    echo "CRITICAL: Không copy được SetPassword.ps1."
    echo

    exit 1

fi


echo "PowerShell script injected."
echo


# ============================================================
# WINDOWS SYSTEM HIVE
# ============================================================

SYSTEM_HIVE="$MOUNT_DIR/Windows/System32/config/SYSTEM"


if [ ! -f "$SYSTEM_HIVE" ]; then

    echo "SYSTEM hive không tồn tại."
    exit 1

fi


# ============================================================
# EXPORT SELECT KEY
#
# SYSTEM\Select\Current cho biết Windows đang dùng
# ControlSet001 / ControlSet002 ...
# ============================================================

SELECT_REG="$RAMROOT/select.reg"


rm -f "$SELECT_REG"


"$RUN" reged \
    -x \
    "$SYSTEM_HIVE" \
    'HKEY_LOCAL_MACHINE\SYSTEM' \
    'Select' \
    "$SELECT_REG"


if [ ! -s "$SELECT_REG" ]; then

    echo
    echo "WARNING:"
    echo "Không export được SYSTEM\\Select."
    echo "Fallback sang ControlSet001."
    echo

    CURRENT_CS=1

else

    #
    # Ví dụ:
    #
    # "Current"=dword:00000001
    #

    CURRENT_HEX=$(
        "$RUN" grep \
            -i \
            '"Current"=dword:' \
            "$SELECT_REG" \
        | "$RUN" head -n1 \
        | "$RUN" sed 's/.*dword://' \
        | "$RUN" tr -d '\r\n '
    )


    case "$CURRENT_HEX" in

        00000001|1)
            CURRENT_CS=1
            ;;

        00000002|2)
            CURRENT_CS=2
            ;;

        00000003|3)
            CURRENT_CS=3
            ;;

        00000004|4)
            CURRENT_CS=4
            ;;

        *)
            echo "Không đọc được Current ControlSet."
            echo "Value: $CURRENT_HEX"
            echo "Fallback ControlSet001."

            CURRENT_CS=1
            ;;

    esac

fi


CONTROLSET=$(
    "$RUN" printf \
        "ControlSet%03d" \
        "$CURRENT_CS"
)


echo
echo "Windows ControlSet:"
echo "$CONTROLSET"
echo


# ============================================================
# CREATE WINDOWS SERVICE REGISTRY FILE
#
# Service chạy:
#
# powershell.exe
#     -NoProfile
#     -NonInteractive
#     -ExecutionPolicy Bypass
#     -File C:\VPSSetup\SetPassword.ps1
#
# Type 0x10 = Win32 own process
# Start 0x02 = Automatic
# ErrorControl 0x01 = Normal
#
# ObjectName LocalSystem
# ============================================================

cat > "$SERVICE_REG" <<EOF
Windows Registry Editor Version 5.00

[HKEY_LOCAL_MACHINE\\SYSTEM\\${CONTROLSET}\\Services\\VPSInitialPassword]
"DisplayName"="VPS Initial Password"
"Description"="Set unique initial Administrator password"
"Type"=dword:00000010
"Start"=dword:00000002
"ErrorControl"=dword:00000001
"ImagePath"="C:\\\\Windows\\\\System32\\\\WindowsPowerShell\\\\v1.0\\\\powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File C:\\\\VPSSetup\\\\SetPassword.ps1"
"ObjectName"="LocalSystem"
EOF


echo "Inject Windows service..."
echo


# ============================================================
# IMPORT SERVICE INTO OFFLINE SYSTEM HIVE
# ============================================================

"$RUN" reged \
    -C \
    -I \
    "$SYSTEM_HIVE" \
    'HKEY_LOCAL_MACHINE\SYSTEM' \
    "$SERVICE_REG"


REG_STATUS=$?


if [ "$REG_STATUS" -ne 0 ]; then

    echo
    echo "======================================================"
    echo "CRITICAL ERROR"
    echo "======================================================"
    echo
    echo "Không import được Windows service."
    echo
    echo "reged status: $REG_STATUS"
    echo
    echo "Không shutdown tự động."
    echo

    exit 1

fi


echo
echo "Windows service injected successfully."
echo


# ============================================================
# VERIFY REGISTRY SERVICE
# ============================================================

VERIFY_REG="$RAMROOT/service-verify.reg"


rm -f "$VERIFY_REG"


"$RUN" reged \
    -x \
    "$SYSTEM_HIVE" \
    'HKEY_LOCAL_MACHINE\SYSTEM' \
    "${CONTROLSET}\\Services\\VPSInitialPassword" \
    "$VERIFY_REG"


if [ ! -s "$VERIFY_REG" ]; then

    echo
    echo "WARNING:"
    echo "Không verify được service sau khi import."
    echo
    echo "Dừng để tránh boot Windows với password cũ."
    echo

    exit 1

fi


if ! "$RUN" grep \
    -q \
    'VPSInitialPassword' \
    "$VERIFY_REG"
then

    echo
    echo "CRITICAL:"
    echo "Service verification failed."
    echo

    exit 1

fi


echo "Service registry verification OK."
echo


# ============================================================
# FLUSH WINDOWS FILESYSTEM
# ============================================================

echo "Flush filesystem..."


"$RUN" sync

"$RUN" sleep 2


# ============================================================
# UNMOUNT WINDOWS
# ============================================================

echo "Unmount Windows partition..."


"$RUN" umount "$MOUNT_DIR"


UMOUNT_STATUS=$?


if [ "$UMOUNT_STATUS" -ne 0 ]; then

    echo
    echo "CRITICAL:"
    echo "Không unmount được Windows partition."
    echo
    echo "Không shutdown tự động."
    echo

    exit 1

fi


# ============================================================
# REMOVE KPARTX MAPPING
# ============================================================

"$RUN" kpartx \
    -d \
    "$DISK" \
    2>/dev/null || true


"$RUN" sync


# ============================================================
# FINAL INFORMATION
# ============================================================

echo
echo
echo "======================================================"
echo "             WINDOWS INSTALL COMPLETE"
echo "======================================================"
echo
echo "Version  : Windows $WinVersion"
echo "Username : Administrator"
echo "Password : $WIN_PASSWORD"
echo
echo "Password API upload : OK"
echo "Windows image       : OK"
echo "Password injection  : OK"
echo "Service injection   : OK"
echo
echo "Windows sẽ tự đổi password khi boot lần đầu."
echo
echo "======================================================"
echo


# ============================================================
# ORIGINAL FINAL STEPS
# ============================================================

echo "Dropping caches..."

echo 3 > /proc/sys/vm/drop_caches


echo "Sync disks..."

echo s > /proc/sysrq-trigger


echo "Remount filesystems read-only..."

echo u > /proc/sysrq-trigger


echo "Power off..."

echo o > /proc/sysrq-trigger
```
