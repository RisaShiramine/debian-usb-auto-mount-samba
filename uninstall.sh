#!/usr/bin/env bash
set -Eeuo pipefail

SMB_CONF="/etc/samba/smb.conf"
INCLUDE_PATH="/run/usb-auto-mount/samba-shares.conf"

if [[ "$(id -u)" -ne 0 ]]; then
    echo "Run this uninstaller as root." >&2
    exit 1
fi

mapfile -t units < <(
    systemctl list-units \
        --all \
        --no-legend \
        --plain \
        'usb-auto-mount@*.service' |
    awk '{print $1}'
)

for unit in "${units[@]:-}"; do
    [[ -n "$unit" ]] || continue
    systemctl stop "$unit" || true
done

rm -f /etc/udev/rules.d/99-usb-auto-mount.rules
rm -f /etc/systemd/system/usb-auto-mount@.service
rm -f /usr/local/sbin/usb-auto-mount
rm -f /etc/tmpfiles.d/usb-auto-mount.conf

if [[ -f "$SMB_CONF" ]]; then
    backup="${SMB_CONF}.before-usb-auto-mount-uninstall.$(date +%Y%m%d-%H%M%S)"
    cp -a "$SMB_CONF" "$backup"
    sed -i "\|$INCLUDE_PATH|d" "$SMB_CONF"
    echo "Created Samba backup: $backup"
fi

rm -rf /run/usb-auto-mount
rmdir /mnt/usb 2>/dev/null || true

systemctl daemon-reload
udevadm control --reload-rules

if testparm -s >/dev/null 2>&1; then
    systemctl reload smbd.service || true
fi

echo "USB auto-mount and dynamic Samba sharing have been removed."
