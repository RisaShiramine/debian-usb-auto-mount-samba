# PVE / Debian USB 自动挂载并动态创建 Samba 共享
GPT5.6写的自动挂载方案，PVE8.0测试工作正常，一键安装脚本还没测试，最好严格参照以下手动步骤！！
## 目标

插入新的 USB 外置存储设备后，系统自动：

1. 识别设备文件系统和卷标。
2. 创建挂载目录：

```text
/mnt/usb/<LABEL>
```

3. 挂载设备。
4. 创建独立的 Samba 共享：

```text
USB_<LABEL>
```

5. Samba 共享直接指向该设备的挂载根目录，避免磁盘可用空间识别错误。

设备拔出后，系统自动：

1. 关闭对应 Samba 共享的现有连接。
2. 删除该 Samba 共享。
3. 卸载设备。
4. 删除对应的空挂载目录。

例如：

```text
Device label: VENTOY
Mount path:   /mnt/usb/VENTOY
Samba share:  USB_VENTOY
```

Windows 访问路径：

```text
\\PVE-IP\USB_VENTOY
```

---

# 一、安装依赖

以 root 执行：

```bash
apt update
apt install -y \
    samba \
    smbclient \
    util-linux \
    coreutils \
    python3 \
    exfatprogs \
    ntfs-3g
```

说明：

* `util-linux` 提供 `mount`、`findmnt`、`flock`、`lsblk` 等工具。
* `coreutils` 提供 `timeout`。
* `ntfs-3g` 用于 NTFS。
* `exfatprogs` 用于 exFAT。
* `python3` 用于安全处理卷标名称。

创建 USB 挂载根目录：

```bash
install -d -m 0777 /mnt/usb
```

---

# 二、创建运行时目录

动态 Samba 配置和设备状态放在 `/run` 下。

`/run` 会在每次重启后自动清空，避免系统重启后残留已经不存在的 USB 共享。

创建 tmpfiles 配置：

```bash
cat >/etc/tmpfiles.d/usb-auto-mount.conf <<'EOF'
d /run/usb-auto-mount 0755 root root -
d /run/usb-auto-mount/state 0700 root root -
d /run/usb-auto-mount/shares 0700 root root -
f /run/usb-auto-mount/samba-shares.conf 0644 root root -
EOF
```

立即创建目录：

```bash
systemd-tmpfiles --create /etc/tmpfiles.d/usb-auto-mount.conf
```

检查：

```bash
ls -la /run/usb-auto-mount
```

应该包含：

```text
state
shares
samba-shares.conf
```

---

# 三、修改 Samba 配置

编辑：

```bash
nano /etc/samba/smb.conf
```

在 `[global]` 段中加入：

```ini
include = /run/usb-auto-mount/samba-shares.conf
```

例如：

```ini
[global]
    workgroup = WORKGROUP
    security = user

    include = /run/usb-auto-mount/samba-shares.conf
```

原有共享保持不变，例如：

```ini
[extssd]
    path = /mnt/pve/extssd
    browseable = yes
    read only = no
    valid users = root
    force user = root
    force group = root

[hdd1]
    path = /mnt/pve/hdd1
    browseable = yes
    read only = no
    valid users = root
    force user = root
    force group = root

[hdd2]
    path = /mnt/pve/hdd2
    browseable = yes
    read only = no
    valid users = root
    force user = root
    force group = root
```

如果尚未给 root 创建 Samba 密码：

```bash
smbpasswd -a root
```

检查 Samba 配置：

```bash
testparm -s
```

重新加载 Samba：

```bash
systemctl reload smbd
```

检查服务：

```bash
systemctl status smbd --no-pager
```

---

# 四、创建最终版自动挂载脚本

创建脚本：

```bash
cat >/usr/local/sbin/usb-auto-mount <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

ACTION="${1:-}"
NAME="${2:-}"

BASE_DIR="/mnt/usb"
RUNTIME_DIR="/run/usb-auto-mount"
STATE_DIR="$RUNTIME_DIR/state"
SHARE_DIR="$RUNTIME_DIR/shares"
SAMBA_INCLUDE="$RUNTIME_DIR/samba-shares.conf"

PATH_LOCK_FILE="/run/lock/usb-auto-mount-path.lock"
SAMBA_LOCK_FILE="/run/lock/usb-auto-mount-samba.lock"

DEVICE="/dev/$NAME"
STATE_FILE="$STATE_DIR/$NAME.state"
SHARE_FILE="$SHARE_DIR/$NAME.conf"

# Set this to an empty string if the Samba share name should exactly
# match the filesystem label.
SHARE_PREFIX="USB_"

log() {
    printf '[usb-auto-mount] %s\n' "$*"
}

ensure_directories() {
    install -d -m 0777 "$BASE_DIR"
    install -d -m 0755 "$RUNTIME_DIR"
    install -d -m 0700 "$STATE_DIR" "$SHARE_DIR"
    install -d -m 0755 /run/lock

    if [[ ! -e "$SAMBA_INCLUDE" ]]; then
        install -m 0644 /dev/null "$SAMBA_INCLUDE"
    else
        chmod 0644 "$SAMBA_INCLUDE"
    fi
}

sanitize_name() {
    python3 - "$1" <<'PY'
import re
import sys
import unicodedata

raw_name = sys.argv[1]

# These characters may cause problems in Linux paths, Windows share
# names, Samba section names, or Samba configuration values.
invalid_characters = set('/\\[]<>:"|?*;#=%$')

safe_name = "".join(
    "_"
    if unicodedata.category(character).startswith("C")
    or character in invalid_characters
    else character
    for character in raw_name
)

safe_name = re.sub(r"\s+", " ", safe_name)
safe_name = safe_name.strip(" .")
safe_name = safe_name[:80]

if not safe_name or safe_name in {".", ".."}:
    safe_name = "UNNAMED"

print(safe_name)
PY
}

path_is_occupied() {
    local path="$1"

    # Any existing path is treated as reserved.
    # This prevents concurrent mount operations from choosing the same path.
    if [[ -e "$path" || -L "$path" ]]; then
        return 0
    fi

    return 1
}

select_mount_path() {
    local safe_label="$1"
    local filesystem_uuid="$2"

    local base_path
    local mount_path
    local short_id
    local counter

    base_path="$BASE_DIR/$safe_label"
    mount_path="$base_path"

    if path_is_occupied "$mount_path"; then
        short_id="${filesystem_uuid:-$NAME}"
        short_id="${short_id//-/}"
        short_id="${short_id:0:8}"

        mount_path="${base_path}__${short_id}"
        counter=2

        while path_is_occupied "$mount_path"; do
            mount_path="${base_path}__${short_id}_${counter}"
            counter=$((counter + 1))
        done
    fi

    printf '%s\n' "$mount_path"
}

wait_for_filesystem() {
    local attempt

    for attempt in {1..40}; do
        if [[ -b "$DEVICE" ]] &&
           blkid "$DEVICE" >/dev/null 2>&1; then
            return 0
        fi

        sleep 0.25
    done

    return 1
}

reload_samba() {
    if ! systemctl is-active --quiet smbd.service 2>/dev/null; then
        return 0
    fi

    if command -v smbcontrol >/dev/null 2>&1; then
        if timeout 5s \
            smbcontrol smbd reload-config \
            >/dev/null 2>&1; then
            return 0
        fi
    fi

    timeout 10s systemctl reload smbd.service >/dev/null 2>&1
}

rebuild_samba_config() {
    local candidate
    local backup
    local share_config

    candidate="$(mktemp "$RUNTIME_DIR/samba-shares.conf.new.XXXXXX")"
    backup="$(mktemp "$RUNTIME_DIR/samba-shares.conf.old.XXXXXX")"

    {
        printf '# This file is generated automatically.\n'
        printf '# Manual changes will be overwritten.\n\n'

        for share_config in "$SHARE_DIR"/*.conf; do
            [[ -e "$share_config" ]] || continue

            cat "$share_config"
            printf '\n'
        done
    } >"$candidate"

    chmod 0644 "$candidate"

    if [[ -f "$SAMBA_INCLUDE" ]]; then
        cp -a -- "$SAMBA_INCLUDE" "$backup"
    else
        install -m 0644 /dev/null "$backup"
    fi

    mv -f -- "$candidate" "$SAMBA_INCLUDE"

    if ! timeout 10s testparm -s >/dev/null 2>&1; then
        mv -f -- "$backup" "$SAMBA_INCLUDE"

        log "The generated Samba configuration is invalid."
        return 1
    fi

    if ! reload_samba; then
        mv -f -- "$backup" "$SAMBA_INCLUDE"
        reload_samba || true

        log "Failed to reload the Samba configuration."
        return 1
    fi

    rm -f -- "$backup"
    return 0
}

create_share_file() {
    local mount_path="$1"
    local share_name="$2"
    local temporary_file

    temporary_file="${SHARE_FILE}.tmp"

    cat >"$temporary_file" <<EOF_SHARE
[$share_name]
    comment = Automatically mounted USB storage
    path = $mount_path

    browseable = yes
    read only = no
    guest ok = no
    valid users = root

    force user = root
    force group = root

    create mask = 0777
    directory mask = 0777
    force create mode = 0666
    force directory mode = 0777

    follow symlinks = no
    wide links = no

    dfree cache time = 0
EOF_SHARE

    chmod 0600 "$temporary_file"
    mv -f -- "$temporary_file" "$SHARE_FILE"
}

remove_share_file() {
    rm -f -- "$SHARE_FILE"
}

publish_samba_share_locked() {
    local mount_path="$1"
    local share_name="$2"

    local lock_fd
    local result=0

    exec {lock_fd}>"$SAMBA_LOCK_FILE"

    log "Waiting for the Samba configuration lock."

    if ! flock -w 15 "$lock_fd"; then
        log "Timed out while waiting for the Samba configuration lock."

        exec {lock_fd}>&-
        return 1
    fi

    create_share_file "$mount_path" "$share_name"

    if rebuild_samba_config; then
        log "Published Samba share: $share_name"
    else
        log "Failed to publish Samba share: $share_name"

        remove_share_file
        rebuild_samba_config || true
        result=1
    fi

    flock -u "$lock_fd" || true
    exec {lock_fd}>&-

    return "$result"
}

remove_samba_share_locked() {
    local lock_fd
    local result=0

    exec {lock_fd}>"$SAMBA_LOCK_FILE"

    log "Waiting for the Samba configuration lock."

    if ! flock -w 15 "$lock_fd"; then
        log "Timed out while waiting for the Samba configuration lock."

        exec {lock_fd}>&-
        return 1
    fi

    remove_share_file

    if rebuild_samba_config; then
        log "Removed Samba share configuration successfully."
    else
        log "Failed to rebuild the Samba configuration."
        result=1
    fi

    flock -u "$lock_fd" || true
    exec {lock_fd}>&-

    return "$result"
}

mount_device() {
    local filesystem_type
    local filesystem_label
    local filesystem_uuid
    local safe_label
    local mount_path
    local share_name
    local mount_options
    local existing_target
    local path_lock_fd
    local state_temporary_file

    ensure_directories

    log "Starting mount for $DEVICE."

    if ! wait_for_filesystem; then
        log "The filesystem on $DEVICE could not be detected."
        return 1
    fi

    existing_target="$(
        findmnt -rn -S "$DEVICE" -o TARGET 2>/dev/null |
        head -n 1 ||
        true
    )"

    if [[ -n "$existing_target" ]]; then
        log "$DEVICE is already mounted at $existing_target."
        return 1
    fi

    filesystem_type="$(
        blkid -s TYPE -o value "$DEVICE" 2>/dev/null ||
        true
    )"

    filesystem_label="$(
        blkid -s LABEL -o value "$DEVICE" 2>/dev/null ||
        true
    )"

    filesystem_uuid="$(
        blkid -s UUID -o value "$DEVICE" 2>/dev/null ||
        true
    )"

    if [[ -z "$filesystem_type" ]]; then
        log "$DEVICE does not contain a supported filesystem."
        return 1
    fi

    if [[ -z "$filesystem_label" ]]; then
        filesystem_label="NO_LABEL_${filesystem_uuid:-$NAME}"
    fi

    safe_label="$(sanitize_name "$filesystem_label")"

    case "$filesystem_type" in
        vfat|exfat|ntfs|ntfs3|fuseblk)
            mount_options="rw,uid=0,gid=0,umask=000,nosuid,nodev"
            ;;
        iso9660|udf)
            mount_options="ro,nosuid,nodev"
            ;;
        *)
            mount_options="rw,nosuid,nodev"
            ;;
    esac

    # The path lock is held only while selecting and reserving
    # the mount directory.
    exec {path_lock_fd}>"$PATH_LOCK_FILE"

    log "Waiting for the mount path allocation lock."

    if ! flock -w 15 "$path_lock_fd"; then
        log "Timed out while waiting for the mount path allocation lock."

        exec {path_lock_fd}>&-
        return 1
    fi

    mount_path="$(select_mount_path "$safe_label" "$filesystem_uuid")"
    share_name="${SHARE_PREFIX}$(basename -- "$mount_path")"

    if ! install -d -m 0777 "$mount_path"; then
        log "Failed to create mount directory: $mount_path"

        flock -u "$path_lock_fd" || true
        exec {path_lock_fd}>&-
        return 1
    fi

    # The lock must be closed before running mount.
    # Long-running FUSE helpers such as mount.ntfs may otherwise
    # inherit and permanently hold the lock file descriptor.
    flock -u "$path_lock_fd" || true
    exec {path_lock_fd}>&-

    log "Mounting $DEVICE at $mount_path."

    if ! timeout 20s \
        mount -o "$mount_options" "$DEVICE" "$mount_path"; then

        rmdir -- "$mount_path" 2>/dev/null || true

        log "Failed to mount $DEVICE at $mount_path."
        return 1
    fi

    state_temporary_file="${STATE_FILE}.tmp"

    printf '%s\n%s\n' \
        "$mount_path" \
        "$share_name" \
        >"$state_temporary_file"

    chmod 0600 "$state_temporary_file"
    mv -f -- "$state_temporary_file" "$STATE_FILE"

    if ! publish_samba_share_locked "$mount_path" "$share_name"; then
        log "Rolling back the mount because Samba publication failed."

        timeout 8s umount -- "$mount_path" 2>/dev/null ||
            timeout 5s umount -l -- "$mount_path" 2>/dev/null ||
            true

        rmdir -- "$mount_path" 2>/dev/null || true
        rm -f -- "$STATE_FILE"

        return 1
    fi

    log "Device: $DEVICE"
    log "Filesystem: $filesystem_type"
    log "Label: $filesystem_label"
    log "Mount path: $mount_path"
    log "Samba share: $share_name"
}

unmount_device() {
    local mount_path=""
    local share_name=""
    local state_lines=()
    local samba_removed="no"
    local mount_removed="yes"

    ensure_directories

    log "Starting removal for $DEVICE."

    if [[ -r "$STATE_FILE" ]]; then
        mapfile -t state_lines <"$STATE_FILE"

        mount_path="${state_lines[0]:-}"
        share_name="${state_lines[1]:-}"
    else
        log "State file not found: $STATE_FILE"
    fi

    if [[ -n "$share_name" ]] &&
       command -v smbcontrol >/dev/null 2>&1; then

        log "Closing Samba share: $share_name"

        timeout 3s \
            smbcontrol smbd close-share "$share_name" \
            >/dev/null 2>&1 ||
            true
    fi

    if remove_samba_share_locked; then
        samba_removed="yes"
    fi

    if [[ "$mount_path" == "$BASE_DIR/"* ]]; then
        if findmnt -rn -M "$mount_path" >/dev/null 2>&1; then
            log "Unmounting: $mount_path"

            if [[ ! -b "$DEVICE" ]]; then
                log "The device is no longer present. Using lazy unmount."

                timeout 5s umount -l -- "$mount_path" ||
                    true
            else
                if ! timeout 8s umount -- "$mount_path"; then
                    log "Normal unmount failed. Using lazy unmount."

                    timeout 5s umount -l -- "$mount_path" ||
                        true
                fi
            fi
        fi

        if findmnt -rn -M "$mount_path" >/dev/null 2>&1; then
            mount_removed="no"

            log "The mount point is still active: $mount_path"
        else
            if rmdir -- "$mount_path" 2>/dev/null; then
                log "Removed mount directory: $mount_path"
            elif [[ -d "$mount_path" ]]; then
                mount_removed="no"

                log "The mount directory is not empty or could not be removed: $mount_path"
            fi
        fi
    else
        log "No valid mount path was found."
    fi

    if [[ "$samba_removed" != "yes" ]]; then
        log "Retrying Samba share removal."

        if remove_samba_share_locked; then
            samba_removed="yes"
        fi
    fi

    if [[ "$samba_removed" == "yes" &&
          "$mount_removed" == "yes" ]]; then

        rm -f -- "$STATE_FILE"
    else
        log "Cleanup was incomplete. The state file has been preserved: $STATE_FILE"
    fi

    if [[ "$samba_removed" != "yes" ]]; then
        log "Warning: Samba configuration cleanup was not completed."
    fi

    if [[ "$mount_removed" != "yes" ]]; then
        log "Warning: Mount point cleanup was not completed."
    fi

    log "Removal completed for $DEVICE."
}

case "$ACTION" in
    mount)
        mount_device
        ;;
    unmount)
        unmount_device
        ;;
    *)
        printf 'Usage: %s {mount|unmount} <kernel-device-name>\n' "$0" >&2
        exit 2
        ;;
esac
EOF
```

设置权限并检查语法：

```bash
chmod 0755 /usr/local/sbin/usb-auto-mount
bash -n /usr/local/sbin/usb-auto-mount
```

没有输出表示语法正确。

---

# 五、创建 systemd 服务

创建模板服务：

```bash
cat >/etc/systemd/system/usb-auto-mount@.service <<'EOF'
[Unit]
Description=Automatically mount and share USB filesystem /dev/%I
BindsTo=dev-%i.device
After=dev-%i.device
After=systemd-tmpfiles-setup.service

[Service]
Type=oneshot
RemainAfterExit=yes

ExecStart=/usr/local/sbin/usb-auto-mount mount %i
ExecStop=/usr/local/sbin/usb-auto-mount unmount %i

TimeoutStartSec=45
TimeoutStopSec=90
KillMode=control-group
EOF
```

加载 systemd 配置：

```bash
systemctl daemon-reload
```

说明：

* `RemainAfterExit=yes` 使挂载成功后服务保持为 `active (exited)`。
* `ExecStop` 在设备拔出时执行卸载和 Samba 清理。
* `BindsTo` 提供设备消失时的自动停止机制。
* `TimeoutStopSec=90` 是最终保护。
* 脚本内的具体阻塞操作都有更短的独立超时。

---

# 六、创建 udev 规则

创建规则：

```bash
cat >/etc/udev/rules.d/99-usb-auto-mount.rules <<'EOF'
ACTION=="add", SUBSYSTEM=="block", ENV{ID_BUS}=="usb", ENV{ID_FS_USAGE}=="filesystem", TAG+="systemd", ENV{SYSTEMD_WANTS}+="usb-auto-mount@%k.service"

ACTION=="remove", SUBSYSTEM=="block", RUN+="/usr/bin/systemctl --no-block stop usb-auto-mount@%k.service"
EOF
```

加载规则：

```bash
udevadm control --reload-rules
udevadm settle
```

说明：

* `add` 规则只处理 USB 总线上的文件系统。
* `remove` 规则不依赖 `ID_BUS` 和 `ID_FS_USAGE`。
* 因为设备移除时，这些 udev 属性可能已经不存在。
* remove 事件通过 `systemctl --no-block` 快速通知 systemd 停止服务。
* 实际卸载工作仍由 systemd 服务完成，不直接在 udev 中运行。

---

# 七、重新加载全部配置

执行：

```bash
systemd-tmpfiles --create /etc/tmpfiles.d/usb-auto-mount.conf

bash -n /usr/local/sbin/usb-auto-mount
chmod 0755 /usr/local/sbin/usb-auto-mount

testparm -s

systemctl daemon-reload
systemctl reload smbd

udevadm control --reload-rules
udevadm settle
```

---

# 八、首次测试

## 1. 插入 USB 设备

查看设备名称：

```bash
lsblk -o NAME,TRAN,SIZE,FSTYPE,LABEL,UUID,MOUNTPOINTS
```

例如：

```text
sde
└─sde1 usb 931.5G ntfs VENTOY 1234-5678 /mnt/usb/VENTOY
```

## 2. 检查挂载

```bash
findmnt -R /mnt/usb
```

检查目录：

```bash
ls -la /mnt/usb
```

## 3. 检查 systemd 服务

假设分区是 `sde1`：

```bash
systemctl status usb-auto-mount@sde1.service --no-pager
```

正确状态应类似：

```text
Active: active (exited)
```

## 4. 检查设备状态文件

```bash
cat /run/usb-auto-mount/state/sde1.state
```

应该显示两行：

```text
/mnt/usb/VENTOY
USB_VENTOY
```

## 5. 检查生成的单设备共享配置

```bash
cat /run/usb-auto-mount/shares/sde1.conf
```

## 6. 检查汇总后的 Samba 动态配置

```bash
cat /run/usb-auto-mount/samba-shares.conf
```

## 7. 检查 Samba 共享

```bash
smbclient -L localhost -U root
```

应该能看到：

```text
USB_VENTOY
```

Windows 访问：

```text
\\PVE-IP\USB_VENTOY
```

---

# 九、测试自动拔盘清理

打开日志：

```bash
journalctl -f -o cat -u 'usb-auto-mount@*.service'
```

拔出 USB 设备后，预期看到：

```text
[usb-auto-mount] Starting removal for /dev/sde1.
[usb-auto-mount] Closing Samba share: USB_VENTOY
[usb-auto-mount] Waiting for the Samba configuration lock.
[usb-auto-mount] Removed Samba share configuration successfully.
[usb-auto-mount] Unmounting: /mnt/usb/VENTOY
[usb-auto-mount] The device is no longer present. Using lazy unmount.
[usb-auto-mount] Removed mount directory: /mnt/usb/VENTOY
[usb-auto-mount] Removal completed for /dev/sde1.
```

检查挂载：

```bash
findmnt -R /mnt/usb
```

检查目录：

```bash
ls -la /mnt/usb
```

检查 Samba：

```bash
smbclient -L localhost -U root
```

对应共享应已经消失。

---

# 十、安全拔盘方法

虽然脚本支持直接物理拔出设备，但设备正在写入时直接拔盘可能损坏文件系统。

推荐先查看设备名：

```bash
lsblk -o NAME,TRAN,FSTYPE,LABEL,MOUNTPOINTS
```

然后停止对应服务：

```bash
systemctl stop usb-auto-mount@sde1.service
```

检查已经卸载：

```bash
findmnt -S /dev/sde1
```

检查共享已经删除：

```bash
smbclient -L localhost -U root
```

确认无挂载后再拔出设备。

重新插入设备时，服务会被 udev 自动启动。

---

# 十一、共享名称规则

默认配置：

```bash
SHARE_PREFIX="USB_"
```

例如：

```text
Filesystem label: Backup
Mount path:       /mnt/usb/Backup
Samba share:      USB_Backup
```

使用前缀可以避免 USB 卷标与现有共享重名，例如：

```text
hdd1
hdd2
extssd
```

如果希望共享名称与卷标完全一致，把脚本中的：

```bash
SHARE_PREFIX="USB_"
```

改为：

```bash
SHARE_PREFIX=""
```

不推荐这样做，除非确定不会与现有共享重名。

---

# 十二、无卷标设备

如果设备没有文件系统卷标，脚本会使用：

```text
NO_LABEL_<UUID>
```

例如：

```text
/mnt/usb/NO_LABEL_1234ABCD
```

对应共享：

```text
USB_NO_LABEL_1234ABCD
```

---

# 十三、同名卷标处理

如果两个设备使用相同卷标，例如都叫：

```text
Backup
```

第一个设备：

```text
/mnt/usb/Backup
USB_Backup
```

第二个设备会自动附加 UUID 前八位：

```text
/mnt/usb/Backup__A1B2C3D4
USB_Backup__A1B2C3D4
```

如果仍然冲突，会继续附加数字：

```text
/mnt/usb/Backup__A1B2C3D4_2
```

---

# 十四、支持的文件系统

脚本默认支持系统能够通过 `mount` 识别的文件系统。

针对以下文件系统，会把文件所有权统一映射为 root：

```text
vfat
exfat
ntfs
ntfs3
fuseblk
```

使用的主要参数：

```text
uid=0
gid=0
umask=000
```

对于：

```text
ext4
xfs
btrfs
```

会保留文件系统本身的 Unix 权限。

由于 Samba 使用：

```ini
force user = root
force group = root
```

Samba 客户端文件操作会以 root 身份执行。

ISO9660 和 UDF 默认只读挂载。

---

# 十五、为什么必须使用两把锁

脚本使用：

```text
/run/lock/usb-auto-mount-path.lock
/run/lock/usb-auto-mount-samba.lock
```

用途分别是：

```text
usb-auto-mount-path.lock
```

只用于分配和创建挂载目录，防止多个 USB 设备同时插入时选中同一个目录。

```text
usb-auto-mount-samba.lock
```

只用于修改和重建动态 Samba 配置。

不能让调用 `mount` 时仍然持有锁。

原因是 NTFS 通常通过长期运行的 FUSE 进程挂载，例如：

```text
mount.ntfs
ntfs-3g
```

这些进程可能继承父脚本打开的文件描述符。

如果挂载时仍持有全局锁，`mount.ntfs` 会一直占用锁，导致拔盘时无法获得锁并删除 Samba 共享。

最终脚本会在调用 `mount` 之前明确执行：

```bash
flock -u "$path_lock_fd"
exec {path_lock_fd}>&-
```

因此长期运行的 `mount.ntfs` 不会继承挂载路径锁。

---

# 十六、检查锁是否被错误继承

插入 NTFS 设备后，查找 NTFS 挂载进程：

```bash
pgrep -a -f 'mount\.ntfs|ntfs-3g'
```

获得 PID 后：

```bash
pid="$(pgrep -n -f 'mount\.ntfs|ntfs-3g')"

ls -l "/proc/$pid/fd" |
grep usb-auto-mount ||
echo "No inherited USB auto-mount lock"
```

正确结果：

```text
No inherited USB auto-mount lock
```

检查当前锁持有者：

```bash
fuser -v \
    /run/lock/usb-auto-mount-path.lock \
    /run/lock/usb-auto-mount-samba.lock
```

没有挂载或 Samba 配置操作正在运行时，通常不应该有长期持有者。

---

# 十七、常用日志与排错命令

## 查看所有自动挂载日志

```bash
journalctl -u 'usb-auto-mount@*.service' --no-pager
```

## 实时查看日志

```bash
journalctl -f -o cat -u 'usb-auto-mount@*.service'
```

## 查看指定设备日志

```bash
journalctl -u usb-auto-mount@sde1.service --no-pager
```

## 查看设备事件

```bash
udevadm monitor \
    --kernel \
    --udev \
    --property \
    --subsystem-match=block
```

## 查看系统识别的 USB 属性

```bash
udevadm info --query=property --name=/dev/sde1
```

重点检查：

```text
ID_BUS=usb
ID_FS_USAGE=filesystem
ID_FS_TYPE=ntfs
ID_FS_LABEL=VENTOY
```

## 查看当前挂载

```bash
findmnt -R /mnt/usb
```

## 查看块设备

```bash
lsblk -o NAME,TRAN,SIZE,FSTYPE,LABEL,UUID,MOUNTPOINTS
```

## 查看占用挂载目录的进程

```bash
fuser -vm /mnt/usb/VENTOY
```

## 查看动态 Samba 配置

```bash
cat /run/usb-auto-mount/samba-shares.conf
```

## 查看全部 Samba 配置

```bash
testparm -s
```

## 查看 Samba 共享列表

```bash
smbclient -L localhost -U root
```

---

# 十八、手动测试脚本

假设设备是 `/dev/sde1`。

手动挂载：

```bash
/usr/local/sbin/usb-auto-mount mount sde1
```

手动卸载：

```bash
/usr/local/sbin/usb-auto-mount unmount sde1
```

也可以通过 systemd 测试：

```bash
systemctl start usb-auto-mount@sde1.service
```

停止：

```bash
systemctl stop usb-auto-mount@sde1.service
```

查看状态：

```bash
systemctl status usb-auto-mount@sde1.service --no-pager
```

---

# 十九、共享已删除但 Windows 仍然显示

先在服务器本机检查：

```bash
smbclient -L localhost -U root
```

如果服务器端已经没有该共享，但 Windows 文件管理器仍显示共享名称，通常是 Windows 网络浏览缓存。

在 Windows 命令提示符运行：

```cmd
net use \\PVE-IP\USB_VENTOY /delete /y
```

也可以查看当前连接：

```cmd
net use
```

共享已从服务器删除时，再次访问会失败，即使网络浏览列表暂时仍显示旧名称。

---

# 二十、出现残留共享时手动清理

假设残留设备实例是 `sde1`：

```bash
rm -f /run/usb-auto-mount/shares/sde1.conf
```

重新执行清理：

```bash
/usr/local/sbin/usb-auto-mount unmount sde1
```

检查：

```bash
cat /run/usb-auto-mount/samba-shares.conf
smbclient -L localhost -U root
```

必要时重新加载：

```bash
systemctl reload smbd
```

---

# 二十一、出现残留挂载时手动清理

检查：

```bash
findmnt -R /mnt/usb
```

普通卸载：

```bash
umount /mnt/usb/VENTOY
```

如果设备已经物理消失或普通卸载失败：

```bash
umount -l /mnt/usb/VENTOY
```

删除空目录：

```bash
rmdir /mnt/usb/VENTOY
```

不要使用：

```bash
rm -rf /mnt/usb/VENTOY
```

因为如果设备仍然挂载，该命令可能删除设备上的实际文件。

---

# 二十二、清除失败状态

如果服务曾因超时进入 failed 状态：

```bash
systemctl reset-failed usb-auto-mount@sde1.service
```

查看状态：

```bash
systemctl status usb-auto-mount@sde1.service --no-pager
```

---

# 二十三、修改脚本后的加载步骤

每次修改脚本后执行：

```bash
bash -n /usr/local/sbin/usb-auto-mount
chmod 0755 /usr/local/sbin/usb-auto-mount
```

脚本不需要执行 `systemctl daemon-reload`。

只有修改 systemd 服务文件后才需要：

```bash
systemctl daemon-reload
```

修改 udev 规则后需要：

```bash
udevadm control --reload-rules
udevadm settle
```

修改 Samba 主配置后需要：

```bash
testparm -s
systemctl reload smbd
```

---

# 二十四、重装系统后的最短恢复顺序

按以下顺序恢复：

```text
1. 安装 samba、ntfs-3g、exfatprogs、util-linux、python3
2. 创建 /mnt/usb
3. 创建 /etc/tmpfiles.d/usb-auto-mount.conf
4. 在 /etc/samba/smb.conf 添加动态 include
5. 创建 /usr/local/sbin/usb-auto-mount
6. 创建 /etc/systemd/system/usb-auto-mount@.service
7. 创建 /etc/udev/rules.d/99-usb-auto-mount.rules
8. 给 root 设置 Samba 密码
9. 检查 testparm
10. 重载 systemd、udev 和 Samba
11. 插入 USB 设备测试
```

对应最终命令：

```bash
systemd-tmpfiles --create /etc/tmpfiles.d/usb-auto-mount.conf

bash -n /usr/local/sbin/usb-auto-mount
chmod 0755 /usr/local/sbin/usb-auto-mount

testparm -s

systemctl daemon-reload
systemctl reload smbd

udevadm control --reload-rules
udevadm settle
```

然后重新插入 USB 设备。

---

# 二十五、卸载整套自动挂载方案

先停止现有 USB 服务：

```bash
systemctl list-units 'usb-auto-mount@*.service'
```

逐个停止，例如：

```bash
systemctl stop usb-auto-mount@sde1.service
```

删除 udev 规则：

```bash
rm -f /etc/udev/rules.d/99-usb-auto-mount.rules
```

删除 systemd 服务：

```bash
rm -f /etc/systemd/system/usb-auto-mount@.service
```

删除脚本：

```bash
rm -f /usr/local/sbin/usb-auto-mount
```

删除 tmpfiles 配置：

```bash
rm -f /etc/tmpfiles.d/usb-auto-mount.conf
```

删除运行时文件：

```bash
rm -rf /run/usb-auto-mount
```

删除空的挂载根目录：

```bash
rmdir /mnt/usb 2>/dev/null || true
```

编辑 Samba：

```bash
nano /etc/samba/smb.conf
```

删除：

```ini
include = /run/usb-auto-mount/samba-shares.conf
```

最后重新加载：

```bash
systemctl daemon-reload
udevadm control --reload-rules

testparm -s
systemctl reload smbd
```

---

# 最终目录与文件清单

```text
/mnt/usb/
    USB device mount directories

/usr/local/sbin/usb-auto-mount
    Main mount, unmount and Samba management script

/etc/systemd/system/usb-auto-mount@.service
    systemd template service

/etc/udev/rules.d/99-usb-auto-mount.rules
    USB insertion and removal rules

/etc/tmpfiles.d/usb-auto-mount.conf
    Runtime directory creation configuration

/run/usb-auto-mount/state/
    Per-device state files

/run/usb-auto-mount/shares/
    Per-device Samba share fragments

/run/usb-auto-mount/samba-shares.conf
    Combined Samba dynamic configuration

/run/lock/usb-auto-mount-path.lock
    Mount path allocation lock

/run/lock/usb-auto-mount-samba.lock
    Samba configuration lock
```

