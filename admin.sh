#!/bin/bash

MOUNT_POINT="/mnt/win"
PARTITION="$1"

if [ "$EUID" -ne 0 ]; then
    echo "[!] Запустите через sudo: sudo $0 $*"
    exit 1
fi

# --- Автопоиск раздела, если не указан ---
if [ -z "$PARTITION" ]; then
    for dev in $(lsblk -l -o NAME,FSTYPE | awk '$2=="ntfs"{print $1}'); do
        p="/dev/$dev"
        [ ! -b "$p" ] && continue
        mkdir -p /tmp/winprobe
        if mount -t ntfs-3g -o ro "$p" /tmp/winprobe 2>/dev/null; then
            if [ -d /tmp/winprobe/Windows/System32/config ]; then
                PARTITION="$p"
                umount /tmp/winprobe
                break
            fi
            umount /tmp/winprobe
        fi
    done
    rmdir /tmp/winprobe 2>/dev/null || true
fi

if [ -z "$PARTITION" ] || [ ! -b "$PARTITION" ]; then
    echo "[!] NTFS раздел с Windows не найден. Доступные разделы:"
    lsblk -f
    exit 1
fi

echo "[*] Раздел: $PARTITION"

# --- Зависимости ---
echo "[*] Ставлю зависимости..."
apt-get update -qq && apt-get install -y -qq chntpw ntfs-3g

# --- Отмонтирование старых монтирований ---
umount "$PARTITION" 2>/dev/null || true
for m in /media/ubuntu/*; do
    [ -d "$m" ] && mountpoint -q "$m" && umount "$m" 2>/dev/null || true
done

# --- Сброс dirty-флага и монтирование ---
ntfsfix "$PARTITION" >/dev/null 2>&1 || true
mkdir -p "$MOUNT_POINT"

if ! mount -t ntfs-3g -o remove_hiberfile,force "$PARTITION" "$MOUNT_POINT" 2>/dev/null; then
    mount -t ntfs-3g -o rw "$PARTITION" "$MOUNT_POINT"
fi

CONFIG_DIR="$MOUNT_POINT/Windows/System32/config"
if [ ! -f "$CONFIG_DIR/SAM" ]; then
    echo "[!] Файл SAM не найден в $CONFIG_DIR"
    umount "$MOUNT_POINT" 2>/dev/null || true
    exit 1
fi

echo "=========================================================="
echo " Раздел готов. Сейчас запустится chntpw."

cd "$CONFIG_DIR"
chntpw -i SAM

cd /
sync
umount "$MOUNT_POINT" 2>/dev/null || true
echo "[+] Раздел успешно размонтирован."

read -p "Перезагрузить компьютер сейчас? (y/n): " ans
if [[ "$ans" =~ ^[Yy]$ ]]; then
    reboot
fi
