#!/usr/bin/env bash
set -Eeuo pipefail

SOURCE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SMB_CONF="/etc/samba/smb.conf"
INCLUDE_PATH="/run/usb-auto-mount/samba-shares.conf"

if [[ "$(id -u)" -ne 0 ]]; then
    echo "Run this installer as root." >&2
    exit 1
fi

apt update
apt install -y \
    samba \
    smbclient \
    util-linux \
    coreutils \
    python3 \
    exfatprogs \
    ntfs-3g

install -d -m 0777 /mnt/usb

install -m 0755 \
    "$SOURCE_DIR/usb-auto-mount" \
    /usr/local/sbin/usb-auto-mount

install -m 0644 \
    "$SOURCE_DIR/usb-auto-mount@.service" \
    /etc/systemd/system/usb-auto-mount@.service

install -m 0644 \
    "$SOURCE_DIR/99-usb-auto-mount.rules" \
    /etc/udev/rules.d/99-usb-auto-mount.rules

install -m 0644 \
    "$SOURCE_DIR/usb-auto-mount.conf" \
    /etc/tmpfiles.d/usb-auto-mount.conf

systemd-tmpfiles --create /etc/tmpfiles.d/usb-auto-mount.conf

if [[ ! -f "$SMB_CONF" ]]; then
    echo "$SMB_CONF does not exist." >&2
    exit 1
fi

backup="${SMB_CONF}.usb-auto-mount.backup.$(date +%Y%m%d-%H%M%S)"
cp -a "$SMB_CONF" "$backup"
echo "Created Samba backup: $backup"

if ! grep -Fq "$INCLUDE_PATH" "$SMB_CONF"; then
    python3 - "$SMB_CONF" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
include_line = "    include = /run/usb-auto-mount/samba-shares.conf"
lines = path.read_text().splitlines()

global_index = None
insert_index = None

for index, line in enumerate(lines):
    stripped = line.strip()

    if stripped.lower() == "[global]":
        global_index = index
        insert_index = index + 1
        continue

    if global_index is not None:
        if stripped.startswith("[") and stripped.endswith("]"):
            break
        insert_index = index + 1

if global_index is None:
    lines = ["[global]", include_line, ""] + lines
else:
    lines.insert(insert_index, include_line)

path.write_text("\n".join(lines) + "\n")
PY
fi

bash -n /usr/local/sbin/usb-auto-mount
testparm -s >/dev/null

systemctl daemon-reload
systemctl enable --now smbd.service
systemctl reload smbd.service

udevadm control --reload-rules
udevadm settle

echo
echo "Installation completed."
echo "Set the Samba root password if it has not been configured:"
echo "  smbpasswd -a root"
echo
echo "Unplug and reconnect the USB storage device to test the setup."
