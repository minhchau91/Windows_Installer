```bash
#!/bin/bash

set -u
set -o pipefail

# ============================================================
# WINDOWS VPS INSTALLER - RAM ONLY SECOND STAGE
#
# Usage:
#
#   ./install.sh 10     VPS_ID
#   ./install.sh 2012   VPS_ID
#   ./install.sh 2016   VPS_ID
#   ./install.sh 2022   VPS_ID
#   ./install.sh linode VPS_ID
#
# Stage 1:
#   Ubuntu bình thường
#   -> Generate password
#   -> POST API
#   -> Resolve MediaFire
#   -> Build mini rootfs trong tmpfs
#
# Stage 2:
#   chroot vào RAM rootfs
#   -> root Ubuntu remount RO
#   -> Range download
#   -> gunzip
#   -> dd /dev/sda
#   -> kpartx
#   -> mount Windows
#   -> inject PowerShell + Registry
#   -> shutdown
#
# ============================================================


# ============================================================
# CONFIG
# ============================================================

API_ENDPOINT=""

API_TOKEN=""


# ============================================================
# PASSWORD HIỆN TẠI CỦA IMAGE
# ============================================================

OLD_WIN_PASSWORD=""

IMAGE_USERNAME="Administrator"


# ============================================================
# ARGUMENT
# ============================================================

VERSION="${1:-}"
VPS_ID="${2:-}"


if [ -z "$VERSION" ] || [ -z "$VPS_ID" ]; then

    echo
    echo "Usage:"
    echo "  $0 10 VPS_ID"
    echo "  $0 2012 VPS_ID"
    echo "  $0 2016 VPS_ID"
    echo "  $0 2022 VPS_ID"
    echo "  $0 linode VPS_ID"
    echo

    exit 1
fi


# ============================================================
# IMAGE SELECT
# ============================================================

case "$VERSION" in

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

    2016|*)
        URL="https://www.mediafire.com/file/okcaojtvpksdb9z/Windows2016.gz/file"
        WinVersion="2016"
        ;;

esac


if [[ "$OLD_WIN_PASSWORD" == PASSWORD_CU_* ]]; then

    echo
    echo "Bạn chưa cấu hình password cũ của Windows image."
    echo

    exit 1
fi


# ============================================================
# ROOT CHECK
# ============================================================

if [ "$(id -u)" -ne 0 ]; then

    echo "Script phải chạy bằng root."
    exit 1

fi


echo
echo "======================================================"
echo "      CÀI ĐẶT WINDOWS $WinVersion"
echo "======================================================"
echo
echo "VPS ID   : $VPS_ID"
echo "Image    : $URL"
echo


# ============================================================
# DETECT ROOT DISK
# ============================================================

ROOT=$(findmnt -no SOURCE /)
ROOT=$(readlink -f "$ROOT")


ROOT_TYPE=$(lsblk -ndo TYPE "$ROOT" 2>/dev/null || true)

DISK_PARENT=$(lsblk -ndo PKNAME "$ROOT" 2>/dev/null || true)


if [ -n "$DISK_PARENT" ]; then

    DISK="/dev/$DISK_PARENT"

elif [ "$ROOT_TYPE" = "disk" ]; then

    DISK="$ROOT"

else

    DISK=$(
        lsblk -ndo NAME,TYPE |
        awk '$2=="disk"{print "/dev/"$1;exit}'
    )

fi


if [ -z "${DISK:-}" ] || [ ! -b "$DISK" ]; then

    echo "Không detect được target disk."
    exit 1

fi


echo "Root filesystem : $ROOT"
echo "Target disk     : $DISK"
echo

lsblk

echo


# ============================================================
# SAFETY CHECK
# ============================================================

SIZE_BYTES=$(blockdev --getsize64 "$DISK")

MIN_BYTES=$((15 * 1024 * 1024 * 1024))


if [ "$SIZE_BYTES" -lt "$MIN_BYTES" ]; then

    echo "Disk nhỏ hơn 15 GB."
    exit 1

fi


# ============================================================
# INSTALL REQUIRED TOOLS
# ============================================================

echo
echo "=== Chuẩn bị packages ==="
echo


export DEBIAN_FRONTEND=noninteractive


apt-get update || exit 1


apt-get install -y \
    curl \
    gzip \
    openssl \
    chntpw \
    kpartx \
    ntfs-3g \
    util-linux \
    busybox-static \
    dmsetup || {

        echo "Không cài được package."
        exit 1
    }


# ============================================================
# GENERATE RANDOM PASSWORD
# ============================================================

RANDOM_BASE=$(
    openssl rand -base64 96 |
    tr -dc 'A-Za-z0-9' |
    head -c 16
)


if [ "${#RANDOM_BASE}" -ne 16 ]; then

    echo "Không generate được password."
    exit 1

fi


WIN_PASSWORD="${RANDOM_BASE}Aa1!"


echo
echo "======================================================"
echo "          WINDOWS INSTALL INFORMATION"
echo "======================================================"
echo
echo "Windows  : $WinVersion"
echo "Username : $IMAGE_USERNAME"
echo "Password : $WIN_PASSWORD"
echo "VPS ID   : $VPS_ID"
echo
echo "======================================================"
echo


# ============================================================
# POST PASSWORD TO API
# ============================================================

API_RESPONSE="/tmp/windows-api.$$"


JSON_PAYLOAD=$(printf \
    '{"vps_id":"%s","windows_version":"%s","username":"%s","password":"%s"}' \
    "$VPS_ID" \
    "$WinVersion" \
    "$IMAGE_USERNAME" \
    "$WIN_PASSWORD"
)


echo "=== Gửi password lên API ==="
echo


if [ -n "$API_TOKEN" ]; then

    HTTP_CODE=$(
        curl \
            --silent \
            --show-error \
            --connect-timeout 10 \
            --max-time 30 \
            --retry 3 \
            --retry-delay 2 \
            --output "$API_RESPONSE" \
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
            --output "$API_RESPONSE" \
            --write-out "%{http_code}" \
            -X POST \
            "$API_ENDPOINT" \
            -H "Content-Type: application/json" \
            --data "$JSON_PAYLOAD"
    )

    CURL_STATUS=$?

fi


if [ "$CURL_STATUS" -ne 0 ]; then

    echo "API connection failed."
    rm -f "$API_RESPONSE"

    exit 1
fi


case "$HTTP_CODE" in

    200|201|202|204)
        ;;

    *)
        echo "API HTTP error: $HTTP_CODE"
        cat "$API_RESPONSE" 2>/dev/null || true

        rm -f "$API_RESPONSE"

        exit 1
        ;;
esac


#
# API hiện tại của bạn trả:
#
# {"status":"ok"}
#

if ! grep -Eq \
    '"status"[[:space:]]*:[[:space:]]*"ok"' \
    "$API_RESPONSE"
then

    echo
    echo "API không trả status=ok:"
    cat "$API_RESPONSE"

    rm -f "$API_RESPONSE"

    exit 1
fi


echo "API OK:"
cat "$API_RESPONSE"
echo


rm -f "$API_RESPONSE"


# ============================================================
# GET MEDIAFIRE DIRECT URL
# ============================================================

echo
echo "=== Resolve MediaFire ==="
echo


WINDOWS_IMAGE_URL=$(
    curl \
        -sL \
        -A "Mozilla/5.0" \
        "$URL" |
    grep -oP \
        'href="\Khttps://download[0-9]+\.mediafire\.com[^"]+' |
    head -n1
)


if [ -z "$WINDOWS_IMAGE_URL" ]; then

    echo "Không lấy được direct URL."
    exit 1

fi


echo "$WINDOWS_IMAGE_URL"
echo


# ============================================================
# GET RANGE INFO
# ============================================================

HEADER_FILE="/tmp/mediafire-header.$$"
BYTE_FILE="/tmp/mediafire-byte.$$"


curl \
    --silent \
    --show-error \
    --insecure \
    --connect-timeout 15 \
    --max-time 30 \
    --range 0-0 \
    --dump-header "$HEADER_FILE" \
    --output "$BYTE_FILE" \
    "$WINDOWS_IMAGE_URL"


if [ $? -ne 0 ]; then

    echo "MediaFire range test failed."
    exit 1

fi


HTTP_RANGE_CODE=$(
    awk '
        /^HTTP\// { code=$2 }
        END { print code }
    ' "$HEADER_FILE"
)


CONTENT_RANGE=$(
    tr -d '\r' < "$HEADER_FILE" |
    awk '
        tolower($1)=="content-range:" {
            print $3
        }
    ' |
    tail -n1
)


TOTAL_SIZE="${CONTENT_RANGE##*/}"


if [ "$HTTP_RANGE_CODE" != "206" ]; then

    echo "Server không hỗ trợ HTTP Range."
    exit 1

fi


if ! [[ "$TOTAL_SIZE" =~ ^[0-9]+$ ]]; then

    echo "Không detect được compressed image size."
    exit 1

fi


DOWNLOAD_HOST="${WINDOWS_IMAGE_URL#https://}"
DOWNLOAD_HOST="${DOWNLOAD_HOST%%/*}"


#
# Resolve IPv4 trước khi chúng ta phá root filesystem.
#

DOWNLOAD_IP=$(
    getent ahostsv4 "$DOWNLOAD_HOST" |
    awk '{print $1; exit}'
)


if [ -z "$DOWNLOAD_IP" ]; then

    echo "Không resolve được MediaFire IP."
    exit 1

fi


rm -f "$HEADER_FILE" "$BYTE_FILE"


echo "Range support    : OK"
echo "Compressed size  : $TOTAL_SIZE"
echo "Download host    : $DOWNLOAD_HOST"
echo "Download IP      : $DOWNLOAD_IP"
echo


# ============================================================
# CREATE REAL TMPFS ROOT
# ============================================================

RAMROOT="/run/windows-stage2-root"


mkdir -p "$RAMROOT"


#
# Dedicated tmpfs.
#
# size=256M chỉ là giới hạn tối đa,
# không allocate 256 MB ngay lập tức.
#

mount \
    -t tmpfs \
    -o size=256M,mode=0755 \
    tmpfs \
    "$RAMROOT" || {

        echo "Không mount được RAM root."
        exit 1
    }


mkdir -p \
    "$RAMROOT/bin" \
    "$RAMROOT/sbin" \
    "$RAMROOT/usr/bin" \
    "$RAMROOT/usr/sbin" \
    "$RAMROOT/lib" \
    "$RAMROOT/lib64" \
    "$RAMROOT/usr/lib" \
    "$RAMROOT/dev" \
    "$RAMROOT/proc" \
    "$RAMROOT/sys" \
    "$RAMROOT/tmp" \
    "$RAMROOT/mnt/windows" \
    "$RAMROOT/payload" \
    "$RAMROOT/config"


chmod 1777 "$RAMROOT/tmp"


# ============================================================
# STATIC BUSYBOX
# ============================================================

BUSYBOX=$(command -v busybox)


cp -L "$BUSYBOX" "$RAMROOT/bin/busybox"


chmod +x "$RAMROOT/bin/busybox"


#
# BusyBox applets.
#
for APP in \
    sh \
    ash \
    cat \
    cp \
    rm \
    mv \
    mkdir \
    sleep \
    sync \
    stat \
    grep \
    sed \
    awk \
    head \
    tail \
    tr \
    printf \
    basename \
    dirname \
    mount \
    umount \
    dd \
    gzip \
    gunzip \
    setsid \
    chroot \
    poweroff
do

    ln -sf busybox "$RAMROOT/bin/$APP"

done


# ============================================================
# COPY DYNAMIC EXECUTABLE + ALL DIRECT LIBRARIES
# ============================================================

copy_binary_to_root()
{
    CMD="$1"

    BIN=$(command -v "$CMD" 2>/dev/null || true)


    if [ -z "$BIN" ]; then

        echo "Không tìm thấy binary: $CMD"
        return 1

    fi


    DEST="$RAMROOT$BIN"

    mkdir -p "$(dirname "$DEST")"

    cp -L "$BIN" "$DEST" || return 1


    ldd "$BIN" 2>/dev/null |
    awk '
        /=> \// {
            print $3
        }

        /^[[:space:]]*\// {
            print $1
        }
    ' |
    while read -r LIB
    do

        [ -f "$LIB" ] || continue

        mkdir -p "$RAMROOT$(dirname "$LIB")"

        cp -L "$LIB" "$RAMROOT$LIB" || exit 1

    done


    return 0
}


#
# Chỉ còn những tool thực sự cần stage 2.
#

for CMD in \
    curl \
    kpartx \
    dmsetup \
    ntfs-3g \
    reged
do

    copy_binary_to_root "$CMD" || {

        echo "Không copy được $CMD."
        exit 1
    }

done


# ============================================================
# NSS / RESOLVER / OPTIONAL LIBS
# ============================================================

for LIB in \
    /lib/x86_64-linux-gnu/libnss_files.so.2 \
    /lib/x86_64-linux-gnu/libnss_dns.so.2 \
    /lib/x86_64-linux-gnu/libresolv.so.2
do

    if [ -f "$LIB" ]; then

        mkdir -p "$RAMROOT$(dirname "$LIB")"
        cp -L "$LIB" "$RAMROOT$LIB"

    fi

done


# ============================================================
# BIND KERNEL FILESYSTEMS INTO RAM ROOT
# ============================================================

mount --bind /dev "$RAMROOT/dev" || exit 1

mount --bind /proc "$RAMROOT/proc" || exit 1

mount --bind /sys "$RAMROOT/sys" || exit 1


# ============================================================
# CONFIG FILES
#
# Không dùng source shell với những string phức tạp.
# ============================================================

printf '%s' "$DISK" \
    > "$RAMROOT/config/disk"

printf '%s' "$TOTAL_SIZE" \
    > "$RAMROOT/config/total_size"

printf '%s' "$WINDOWS_IMAGE_URL" \
    > "$RAMROOT/config/url"

printf '%s' "$DOWNLOAD_HOST" \
    > "$RAMROOT/config/host"

printf '%s' "$DOWNLOAD_IP" \
    > "$RAMROOT/config/ip"

printf '%s' "$WinVersion" \
    > "$RAMROOT/config/version"

printf '%s' "$VPS_ID" \
    > "$RAMROOT/config/vps_id"

printf '%s' "$WIN_PASSWORD" \
    > "$RAMROOT/config/new_password"


# ============================================================
# BUILD POWERSHELL PAYLOAD
# ============================================================

cat > "$RAMROOT/payload/SetPassword.ps1" <<EOF
\$ErrorActionPreference = "Stop"

\$NewPassword = '${WIN_PASSWORD}'

try {

    \$Admin = Get-WmiObject Win32_UserAccount |
        Where-Object {
            \$_.LocalAccount -eq \$true -and
            \$_.SID -match '-500\$'
        } |
        Select-Object -First 1


    if (-not \$Admin) {
        throw "Cannot find local Administrator RID 500"
    }


    \$AdminName = \$Admin.Name


    & "\$env:SystemRoot\\System32\\net.exe" \
        user \
        "\$AdminName" \
        /active:yes


    if (\$LASTEXITCODE -ne 0) {

        throw "Failed to enable Administrator. Code=\$LASTEXITCODE"

    }


    & "\$env:SystemRoot\\System32\\net.exe" \
        user \
        "\$AdminName" \
        "\$NewPassword"


    if (\$LASTEXITCODE -ne 0) {

        throw "Failed to change password. Code=\$LASTEXITCODE"

    }


    #
    # Disable temporary AutoLogon.
    #

    \$Winlogon = \
        "HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Winlogon"


    Set-ItemProperty \
        -Path \$Winlogon \
        -Name "AutoAdminLogon" \
        -Value "0"


    Remove-ItemProperty \
        -Path \$Winlogon \
        -Name "DefaultPassword" \
        -ErrorAction SilentlyContinue


    Remove-ItemProperty \
        -Path \$Winlogon \
        -Name "DefaultUserName" \
        -ErrorAction SilentlyContinue


    Remove-ItemProperty \
        -Path \$Winlogon \
        -Name "DefaultDomainName" \
        -ErrorAction SilentlyContinue


    @"
Password changed successfully.
Account: \$AdminName
Time: \$(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
"@ |
    Set-Content \
        "C:\\VPSSetup\\password-changed.txt"


    #
    # Cleanup PowerShell chứa plaintext random password.
    #

    \$Cleanup = @'
@echo off
ping 127.0.0.1 -n 5 >nul
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


    #
    # Logout session dùng password cũ bằng reboot.
    #

    & "\$env:SystemRoot\\System32\\shutdown.exe" \
        /r \
        /t 5 \
        /f


    exit 0

}
catch {

    \$_ |
        Out-File \
            "C:\\VPSSetup\\password-error.txt" \
            -Append


    exit 1
}
EOF


# ============================================================
# ESCAPE OLD PASSWORD FOR .REG
# ============================================================

REG_OLD_PASSWORD="$OLD_WIN_PASSWORD"

REG_OLD_PASSWORD="${REG_OLD_PASSWORD//\\/\\\\}"
REG_OLD_PASSWORD="${REG_OLD_PASSWORD//\"/\\\"}"


REG_USERNAME="$IMAGE_USERNAME"

REG_USERNAME="${REG_USERNAME//\\/\\\\}"
REG_USERNAME="${REG_USERNAME//\"/\\\"}"


# ============================================================
# REGISTRY PAYLOAD
# ============================================================

cat > "$RAMROOT/payload/FirstBoot.reg" <<EOF
Windows Registry Editor Version 5.00

[HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Winlogon]
"AutoAdminLogon"="1"
"DefaultUserName"="$REG_USERNAME"
"DefaultPassword"="$REG_OLD_PASSWORD"

[HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\RunOnce]
"!VPSInitialPassword"="C:\\\\Windows\\\\System32\\\\WindowsPowerShell\\\\v1.0\\\\powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File C:\\\\VPSSetup\\\\SetPassword.ps1"
EOF


# ============================================================
# STAGE 2
# ============================================================

cat > "$RAMROOT/stage2.sh" <<'STAGE2'
#!/bin/sh

PATH=/bin:/sbin:/usr/bin:/usr/sbin

export PATH


LOG="/stage2.log"


log()
{
    echo "[$(date 2>/dev/null || true)] $*" >> "$LOG"
    echo "$*"
}


DISK=$(cat /config/disk)
TOTAL_SIZE=$(cat /config/total_size)
WINDOWS_IMAGE_URL=$(cat /config/url)
DOWNLOAD_HOST=$(cat /config/host)
DOWNLOAD_IP=$(cat /config/ip)
WIN_VERSION=$(cat /config/version)
VPS_ID=$(cat /config/vps_id)
NEW_PASSWORD=$(cat /config/new_password)


# ============================================================
# IMPORTANT
#
# Chúng ta hiện đã CHROOT vào tmpfs.
#
# "/" ở đây KHÔNG PHẢI Ubuntu /dev/sda.
# ============================================================

log "=========================================="
log "RAM-only stage 2 started"
log "Disk: $DISK"
log "Windows: $WIN_VERSION"
log "VPS ID: $VPS_ID"
log "=========================================="


# ============================================================
# DOWNLOAD SETTINGS
#
# 16 MiB/chunk:
# - ít RAM
# - retry nhanh
# ============================================================

CHUNK_SIZE=$((16 * 1024 * 1024))

MAX_RETRIES=20

CHUNK="/tmp/windows.chunk"


# ============================================================
# RESUMABLE RANGE STREAM
# ============================================================

download_stream()
{
    START=0


    while [ "$START" -lt "$TOTAL_SIZE" ]
    do

        END=$((START + CHUNK_SIZE - 1))


        if [ "$END" -ge "$TOTAL_SIZE" ]; then
            END=$((TOTAL_SIZE - 1))
        fi


        EXPECTED=$((END - START + 1))

        ATTEMPT=1


        while :
        do

            rm -f "$CHUNK"


            log \
                "Range $START-$END / $TOTAL_SIZE attempt=$ATTEMPT"


            curl \
                --silent \
                --show-error \
                --fail \
                --insecure \
                --connect-timeout 15 \
                --max-time 180 \
                --resolve "${DOWNLOAD_HOST}:443:${DOWNLOAD_IP}" \
                --range "${START}-${END}" \
                --output "$CHUNK" \
                "$WINDOWS_IMAGE_URL"


            CURL_STATUS=$?


            if [ -f "$CHUNK" ]; then

                GOT=$(stat -c '%s' "$CHUNK" 2>/dev/null)

            else

                GOT=0

            fi


            if [ "$CURL_STATUS" -eq 0 ] && \
               [ "$GOT" = "$EXPECTED" ]; then

                break

            fi


            log \
                "Chunk failed curl=$CURL_STATUS expected=$EXPECTED got=$GOT"


            rm -f "$CHUNK"


            if [ "$ATTEMPT" -ge "$MAX_RETRIES" ]; then

                log \
                    "Download failed permanently at $START-$END"

                return 1

            fi


            ATTEMPT=$((ATTEMPT + 1))


            sleep 3

        done


        cat "$CHUNK" || return 1


        rm -f "$CHUNK"


        START=$((END + 1))

    done


    return 0
}


# ============================================================
# WRITE WINDOWS
# ============================================================

log "Starting download -> gunzip -> dd"


download_stream |
    gzip -dc |
    dd \
        of="$DISK" \
        bs=1M \
        status=progress


DOWNLOAD_STATUS=${PIPESTATUS:-}


#
# BusyBox ash không hỗ trợ Bash PIPESTATUS.
#
# Vì vậy kiểm tra gzip integrity/download chủ yếu thông qua
# return status pipeline cuối.
#

PIPE_STATUS=$?


if [ "$PIPE_STATUS" -ne 0 ]; then

    log "CRITICAL: image pipeline failed status=$PIPE_STATUS"

    #
    # Không shutdown.
    # Kernel vẫn còn chạy RAM environment để debug console.
    #

    while :
    do
        sleep 3600
    done

fi


sync


log "Windows image written successfully"


# ============================================================
# DEVICE MAPPER
# ============================================================

log "Creating partition mappings"


kpartx -av "$DISK" >> "$LOG" 2>&1


if [ $? -ne 0 ]; then

    log "CRITICAL: kpartx failed"

    while :
    do
        sleep 3600
    done

fi


sleep 3


#
# Nếu udev không chạy được nữa, yêu cầu dmsetup tạo node.
#

dmsetup mknodes >> "$LOG" 2>&1 || true


# ============================================================
# FIND WINDOWS PARTITION
# ============================================================

DISK_NAME="${DISK##*/}"

WINDOWS_PART=""


mkdir -p /mnt/windows


for PART in \
    /dev/mapper/${DISK_NAME}p* \
    /dev/mapper/${DISK_NAME}[0-9]*
do

    [ -b "$PART" ] || continue


    log "Testing $PART"


    ntfs-3g \
        "$PART" \
        /mnt/windows \
        -o rw,remove_hiberfile \
        >> "$LOG" 2>&1


    if [ $? -ne 0 ]; then
        continue
    fi


    if [ -f /mnt/windows/Windows/System32/config/SOFTWARE ] && \
       [ -f /mnt/windows/Windows/System32/config/SYSTEM ]; then

        WINDOWS_PART="$PART"

        break

    fi


    umount /mnt/windows 2>/dev/null || true

done


if [ -z "$WINDOWS_PART" ]; then

    log "CRITICAL: Windows partition not found"

    while :
    do
        sleep 3600
    done

fi


log "Windows partition: $WINDOWS_PART"


# ============================================================
# COPY POWERSHELL
# ============================================================

mkdir -p /mnt/windows/VPSSetup


cp \
    /payload/SetPassword.ps1 \
    /mnt/windows/VPSSetup/SetPassword.ps1


if [ ! -s /mnt/windows/VPSSetup/SetPassword.ps1 ]; then

    log "CRITICAL: PowerShell injection failed"

    while :
    do
        sleep 3600
    done

fi


# ============================================================
# REGISTRY INJECTION
# ============================================================

SOFTWARE_HIVE="/mnt/windows/Windows/System32/config/SOFTWARE"


log "Injecting Winlogon/RunOnce registry"


reged \
    -C \
    -I \
    "$SOFTWARE_HIVE" \
    'HKEY_LOCAL_MACHINE\SOFTWARE' \
    /payload/FirstBoot.reg \
    >> "$LOG" 2>&1


if [ $? -ne 0 ]; then

    log "CRITICAL: reged import failed"

    while :
    do
        sleep 3600
    done

fi


# ============================================================
# VERIFY RUNONCE
# ============================================================

VERIFY="/tmp/verify.reg"


rm -f "$VERIFY"


reged \
    -x \
    "$SOFTWARE_HIVE" \
    'HKEY_LOCAL_MACHINE\SOFTWARE' \
    'Microsoft\Windows\CurrentVersion\RunOnce' \
    "$VERIFY" \
    >> "$LOG" 2>&1


if [ ! -s "$VERIFY" ]; then

    log "CRITICAL: RunOnce export verification failed"

    while :
    do
        sleep 3600
    done

fi


if ! grep -q VPSInitialPassword "$VERIFY"; then

    log "CRITICAL: RunOnce value missing"

    while :
    do
        sleep 3600
    done

fi


log "Registry injection verified"


# ============================================================
# SYNC / UNMOUNT
# ============================================================

sync

sleep 2


umount /mnt/windows


if [ $? -ne 0 ]; then

    log "CRITICAL: Windows unmount failed"

    while :
    do
        sleep 3600
    done

fi


kpartx -d "$DISK" >> "$LOG" 2>&1 || true


sync


log "=========================================="
log "INSTALL COMPLETE"
log "Windows: $WIN_VERSION"
log "VPS ID: $VPS_ID"
log "Password injection: OK"
log "=========================================="


# ============================================================
# FINAL KERNEL SYNC + POWER OFF
#
# Không phụ thuộc systemd.
# ============================================================

sync

sleep 2


#
# SysRq:
#
# s = sync
# u = remount RO
# o = poweroff
#

if [ -w /proc/sysrq-trigger ]; then

    echo s > /proc/sysrq-trigger

    sleep 2

    echo u > /proc/sysrq-trigger

    sleep 2

    echo o > /proc/sysrq-trigger

fi


#
# Fallback BusyBox poweroff.
#

poweroff -f


#
# Nếu vẫn chưa poweroff.
#

while :
do
    sleep 3600
done

STAGE2


chmod +x "$RAMROOT/stage2.sh"


# ============================================================
# TEST CHROOT BEFORE DESTROYING UBUNTU
# ============================================================

echo
echo "=== Test RAM rootfs ==="
echo


"$RAMROOT/bin/busybox" \
    chroot \
    "$RAMROOT" \
    /bin/busybox sh -c '
        echo "busybox: OK"

        curl --version >/dev/null ||
            exit 10

        echo "curl: OK"

        kpartx -V >/dev/null 2>&1 ||
            exit 11

        echo "kpartx: OK"

        ntfs-3g --version >/dev/null 2>&1 ||
            exit 12

        echo "ntfs-3g: OK"

        reged -h >/dev/null 2>&1 || true

        echo "reged: OK"

        test -b /dev/sda ||
            exit 13

        echo "/dev access: OK"
    '


TEST_STATUS=$?


if [ "$TEST_STATUS" -ne 0 ]; then

    echo
    echo "RAM rootfs test FAILED: $TEST_STATUS"
    echo
    echo "Disk CHƯA bị ghi."
    echo

    exit 1

fi


echo
echo "RAM rootfs test: SUCCESS"
echo


# ============================================================
# LAST SAFE POINT
# ============================================================

echo
echo "======================================================"
echo "              READY FOR STAGE 2"
echo "======================================================"
echo
echo "Windows      : $WinVersion"
echo "VPS ID       : $VPS_ID"
echo "Password     : $WIN_PASSWORD"
echo "Target disk  : $DISK"
echo
echo "API          : OK"
echo "RAM rootfs   : OK"
echo "MediaFire    : OK"
echo
echo "Sau bước tiếp theo SSH có thể bị disconnect."
echo "Đó là hành vi bình thường."
echo
echo "Stage 2 sẽ tiếp tục hoàn toàn trong RAM."
echo "======================================================"
echo


# ============================================================
# FLUSH UBUNTU FILESYSTEM
# ============================================================

sync


# ============================================================
# REMOUNT OLD UBUNTU ROOT READ-ONLY
#
# Rất quan trọng:
#
# ngăn ext4 Ubuntu tiếp tục ghi metadata/journal
# lên /dev/sda sau khi Windows DD bắt đầu.
# ============================================================

echo "Remount Ubuntu root read-only..."


mount -o remount,ro /


if [ $? -ne 0 ]; then

    echo
    echo "======================================================"
    echo "LỖI:"
    echo "Không remount được Ubuntu root read-only."
    echo
    echo "KHÔNG bắt đầu dd."
    echo "======================================================"
    echo

    exit 1

fi


echo "Ubuntu root is now READ-ONLY."


# ============================================================
# LAUNCH DETACHED STAGE 2
#
# Executable chạy:
#
#   /run/windows-stage2-root/bin/busybox
#
# nằm hoàn toàn trong tmpfs.
#
# Sau chroot:
#
#   / = RAMROOT
#
# Không còn phụ thuộc Ubuntu root.
# ============================================================

echo
echo "Launching RAM-only stage 2..."
echo


"$RAMROOT/bin/busybox" \
    setsid \
    "$RAMROOT/bin/busybox" \
    chroot \
    "$RAMROOT" \
    /bin/busybox sh /stage2.sh \
    > "$RAMROOT/stage2-console.log" \
    2>&1 \
    < /dev/null &


STAGE2_PID=$!


#
# Bash builtin disown.
#
disown "$STAGE2_PID" 2>/dev/null || true


sleep 2


if kill -0 "$STAGE2_PID" 2>/dev/null; then

    echo
    echo "======================================================"
    echo "RAM STAGE 2 ĐÃ KHỞI ĐỘNG"
    echo "======================================================"
    echo
    echo "PID: $STAGE2_PID"
    echo
    echo "SSH có thể disconnect ngay sau đây."
    echo
    echo "Không chạy thêm command trên VPS."
    echo "Stage 2 đang tiếp tục từ RAM."
    echo
    echo "Windows Password:"
    echo "$WIN_PASSWORD"
    echo
    echo "======================================================"
    echo

    exit 0

else

    echo
    echo "Stage 2 không start được."
    echo
    echo "Log:"
    cat "$RAMROOT/stage2-console.log" 2>/dev/null || true
    echo

    exit 1
fi
```
