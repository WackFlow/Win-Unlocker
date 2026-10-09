#!/bin/bash

MOUNT_POINT="/mnt/win"
PARTITION="$1"

if [ "$EUID" -ne 0 ]; then
    echo "[!] Запустите через sudo: sudo $0 $*"
    exit 1
fi

# --- Зависимости ---
echo "[*] Ставлю зависимости..."
apt-get update -qq && apt-get install -y -qq chntpw ntfs-3g

# --- Освобождение раздела ---
cleanup_partition() {
    fuser -km "$1" 2>/dev/null || true
    umount "$1" 2>/dev/null || true
    for m in /media/ubuntu/*; do
        [ -d "$m" ] && mountpoint -q "$m" && umount "$m" 2>/dev/null || true
    done
    ntfsfix "$1" >/dev/null 2>&1 || true
}

# --- Автопоиск раздела, если не указан ---
find_partition() {
    for dev in $(lsblk -l -o NAME,FSTYPE | awk '$2=="ntfs"{print $1}'); do
        p="/dev/$dev"
        [ ! -b "$p" ] && continue
        cleanup_partition "$p"
        mkdir -p /tmp/winprobe
        if mount -t ntfs-3g -o remove_hiberfile,force "$p" /tmp/winprobe 2>/dev/null; then
            if [ -f /tmp/winprobe/Windows/System32/config/SAM ]; then
                umount /tmp/winprobe 2>/dev/null || true
                echo "$p"
                return 0
            fi
            umount /tmp/winprobe 2>/dev/null || true
        fi
    done
    rmdir /tmp/winprobe 2>/dev/null || true
    return 1
}

if [ -z "$PARTITION" ]; then
    echo "[*] Ищу раздел с Windows..."
    PARTITION=$(find_partition)
fi

if [ -z "$PARTITION" ] || [ ! -b "$PARTITION" ]; then
    echo "[!] NTFS раздел с Windows не найден. Доступные разделы:"
    lsblk -f
    exit 1
fi

echo "[*] Раздел: $PARTITION"

# --- Монтирование ---
cleanup_partition "$PARTITION"
mkdir -p "$MOUNT_POINT"

mount -t ntfs-3g -o remove_hiberfile,force "$PARTITION" "$MOUNT_POINT" 2>/dev/null \
    || mount -t ntfs-3g -o rw "$PARTITION" "$MOUNT_POINT" \
    || { echo "[!] Не удалось примонтировать $PARTITION"; exit 1; }

CONFIG_DIR="$MOUNT_POINT/Windows/System32/config"
if [ ! -f "$CONFIG_DIR/SAM" ]; then
    echo "[!] Файл SAM не найден в $CONFIG_DIR"
    umount "$MOUNT_POINT" 2>/dev/null || true
    exit 1
fi

echo "=========================================================="
echo " Раздел готов. Сейчас запустится chntpw."

exec < /dev/tty
cd "$CONFIG_DIR"
chntpw -i SAM

# --- Завершение ---
cd /
sync
umount "$MOUNT_POINT" 2>/dev/null || true
echo "[+] Раздел успешно размонтирован."

read -p "Перезагрузить компьютер сейчас? (y/n): " ans
if [[ "$ans" =~ ^[Yy]$ ]]; then
    reboot
fi
