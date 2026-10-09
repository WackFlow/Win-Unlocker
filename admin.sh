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

# --- Освобождение раздела (только для целевого!) ---
cleanup_partition() {
    local dev="$1"
    fuser -km "$dev" 2>/dev/null || true
    umount "$dev" 2>/dev/null || true
    for m in /media/ubuntu/*; do
        [ -d "$m" ] && mountpoint -q "$m" && umount "$m" 2>/dev/null || true
    done
}

# --- Автопоиск раздела (безопасный, только чтение) ---
find_partition() {
    local probe="/tmp/winprobe"
    mkdir -p "$probe"

    for dev in $(lsblk -l -o NAME,FSTYPE | awk '$2=="ntfs"{print $1}'); do
        p="/dev/$dev"
        [ ! -b "$p" ] && continue

        local cur=$(lsblk -no MOUNTPOINT "$p" | head -n 1)
        local check_dir=""
        local external=false

        if [ -n "$cur" ]; then
            check_dir="$cur"
            external=true
        else
            mount -t ntfs-3g -o ro,force "$p" "$probe" 2>/dev/null || continue
            check_dir="$probe"
        fi

        # Надежная регистронезависимая проверка через find
        local found_sam=$(find "$check_dir" -maxdepth 4 -type f -iregex ".*/windows/system32/config/sam" 2>/dev/null | head -n 1)

        if [ -n "$found_sam" ]; then
            [ "$external" = false ] && umount "$probe" 2>/dev/null
            rmdir "$probe" 2>/dev/null
            echo "$p"
            return 0
        fi

        [ "$external" = false ] && umount "$probe" 2>/dev/null
    done

    rmdir "$probe" 2>/dev/null
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

# --- Подготовка выбранного раздела ---
cleanup_partition "$PARTITION"
ntfsfix "$PARTITION" >/dev/null 2>&1 || true
mkdir -p "$MOUNT_POINT"

mount -t ntfs-3g -o remove_hiberfile,force "$PARTITION" "$MOUNT_POINT" 2>/dev/null \
    || mount -t ntfs-3g -o rw "$PARTITION" "$MOUNT_POINT" \
    || { echo "[!] Не удалось примонтировать $PARTITION"; exit 1; }

# --- Поиск SAM (регистронезависимо) ---
SAM_FILE=$(find "$MOUNT_POINT" -maxdepth 4 -type f -iregex ".*/windows/system32/config/sam" 2>/dev/null | head -n 1)

if [ -z "$SAM_FILE" ] || [ ! -f "$SAM_FILE" ]; then
    echo "[!] Файл SAM не найден в $MOUNT_POINT"
    umount "$MOUNT_POINT" 2>/dev/null || true
    exit 1
fi

CONFIG_DIR=$(dirname "$SAM_FILE")

echo "=========================================================="
echo " Раздел готов. Сейчас запустится chntpw."

exec < /dev/tty
cd "$CONFIG_DIR"
chntpw -i "$(basename "$SAM_FILE")"

# --- Завершение ---
cd /
sync
umount "$MOUNT_POINT" 2>/dev/null || true
echo "[+] Раздел успешно размонтирован."

read -p "Перезагрузить компьютер сейчас? (y/n): " ans
if [[ "$ans" =~ ^[Yy]$ ]]; then
    reboot
fi
