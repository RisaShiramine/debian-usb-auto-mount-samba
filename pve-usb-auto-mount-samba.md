# PVE / Debian USB 自动挂载与动态 Samba 共享

## 功能

插入 USB 外置存储设备后自动：

- 根据文件系统卷标创建 `/mnt/usb/<LABEL>`
- 将设备挂载到该目录
- 创建独立 Samba 共享 `USB_<LABEL>`
- 将共享直接指向磁盘根目录
- 使用 `dfree cache time = 0` 避免可用空间缓存错误
- Samba 文件操作统一以 `root` 执行

设备拔出后自动：

- 关闭对应 Samba 共享连接
- 删除对应动态共享配置
- 卸载设备
- 删除空挂载目录

现有目录和共享，例如：

```text
/mnt/pve/extssd
/mnt/pve/hdd1
/mnt/pve/hdd2
```

不会被修改或删除。

---

## 压缩包内容

| 文件 | 安装位置 | 用途 |
|---|---|---|
| `usb-auto-mount` | `/usr/local/sbin/usb-auto-mount` | 主脚本 |
| `usb-auto-mount@.service` | `/etc/systemd/system/` | systemd 模板服务 |
| `99-usb-auto-mount.rules` | `/etc/udev/rules.d/` | USB 插入和移除规则 |
| `usb-auto-mount.conf` | `/etc/tmpfiles.d/` | 创建 `/run` 运行目录 |
| `smb.conf.include.example` | 参考文件 | Samba include 示例 |
| `install.sh` | 当前目录 | 自动安装脚本 |
| `uninstall.sh` | 当前目录 | 卸载脚本 |

---

# 快速安装

解压并进入目录：

```bash
unzip pve-usb-auto-mount-samba.zip
cd pve-usb-auto-mount-samba
```

以 root 执行：

```bash
chmod +x install.sh uninstall.sh usb-auto-mount
./install.sh
```

安装脚本会：

1. 安装 Samba、NTFS、exFAT 和所需工具。
2. 创建 `/mnt/usb`。
3. 安装主脚本、systemd、udev 和 tmpfiles 配置。
4. 备份 `/etc/samba/smb.conf`。
5. 在 Samba 的 `[global]` 中加入：

```ini
include = /run/usb-auto-mount/samba-shares.conf
```

6. 检查 Samba 配置。
7. 重新加载 systemd、udev 和 Samba。

如果尚未设置 Samba 的 root 密码：

```bash
smbpasswd -a root
```

然后拔出并重新插入 USB 存储设备。

---

# 手动安装

## 1. 安装依赖

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

## 2. 创建挂载目录

```bash
install -d -m 0777 /mnt/usb
```

## 3. 安装配置文件

在解压后的目录执行：

```bash
install -m 0755 usb-auto-mount \
    /usr/local/sbin/usb-auto-mount

install -m 0644 usb-auto-mount@.service \
    /etc/systemd/system/usb-auto-mount@.service

install -m 0644 99-usb-auto-mount.rules \
    /etc/udev/rules.d/99-usb-auto-mount.rules

install -m 0644 usb-auto-mount.conf \
    /etc/tmpfiles.d/usb-auto-mount.conf
```

创建运行时目录：

```bash
systemd-tmpfiles --create /etc/tmpfiles.d/usb-auto-mount.conf
```

## 4. 修改 Samba

编辑：

```bash
nano /etc/samba/smb.conf
```

在 `[global]` 段中加入：

```ini
include = /run/usb-auto-mount/samba-shares.conf
```

原有共享保持不变。

检查配置：

```bash
testparm -s
```

重新加载：

```bash
systemctl reload smbd
```

## 5. 加载 systemd 和 udev

```bash
systemctl daemon-reload
udevadm control --reload-rules
udevadm settle
```

重新插入 USB 设备。

---

# 工作示例

设备卷标：

```text
VENTOY
```

挂载点：

```text
/mnt/usb/VENTOY
```

Samba 共享名：

```text
USB_VENTOY
```

Windows 访问：

```text
\\PVE-IP\USB_VENTOY
```

---

# 共享配置

每个动态共享大致如下：

```ini
[USB_VENTOY]
    comment = Automatically mounted USB storage
    path = /mnt/usb/VENTOY
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
```

---

# 无卷标和同名卷标

无卷标设备使用：

```text
NO_LABEL_<UUID>
```

例如：

```text
/mnt/usb/NO_LABEL_1234ABCD
USB_NO_LABEL_1234ABCD
```

如果两个设备卷标相同，后插入的设备会追加 UUID 前八位：

```text
/mnt/usb/Backup
/mnt/usb/Backup__A1B2C3D4
```

对应共享：

```text
USB_Backup
USB_Backup__A1B2C3D4
```

---

# 文件系统

安装对应工具后，可处理常见文件系统：

- NTFS
- exFAT
- FAT32
- ext4
- XFS
- Btrfs
- ISO9660
- UDF

NTFS、exFAT 和 FAT 使用：

```text
uid=0,gid=0,umask=000
```

ext4、XFS 和 Btrfs 保留磁盘自身的 Unix 权限，但 Samba 操作仍强制使用 root。

---

# 安全拔盘

查看设备名：

```bash
lsblk -o NAME,TRAN,FSTYPE,LABEL,MOUNTPOINTS
```

假设设备为 `/dev/sde1`：

```bash
systemctl stop usb-auto-mount@sde1.service
```

确认已经卸载：

```bash
findmnt -S /dev/sde1
```

确认共享已经消失：

```bash
smbclient -L localhost -U root
```

然后再物理拔盘。

直接物理拔出时，脚本会使用 lazy unmount 进行清理，但设备正在写入时仍可能损坏文件系统。

---

# 状态检查

查看设备：

```bash
lsblk -o NAME,TRAN,SIZE,FSTYPE,LABEL,UUID,MOUNTPOINTS
```

查看 USB 挂载：

```bash
findmnt -R /mnt/usb
```

查看服务：

```bash
systemctl status usb-auto-mount@sde1.service --no-pager
```

正常挂载成功后通常显示：

```text
active (exited)
```

查看状态文件：

```bash
cat /run/usb-auto-mount/state/sde1.state
```

查看动态配置：

```bash
cat /run/usb-auto-mount/samba-shares.conf
```

查看 Samba 共享：

```bash
smbclient -L localhost -U root
```

---

# 日志

指定设备：

```bash
journalctl -u usb-auto-mount@sde1.service --no-pager
```

实时查看：

```bash
journalctl -f -o cat -u 'usb-auto-mount@*.service'
```

查看 udev 事件：

```bash
udevadm monitor \
    --kernel \
    --udev \
    --property \
    --subsystem-match=block
```

---

# 手动测试

直接调用脚本：

```bash
/usr/local/sbin/usb-auto-mount mount sde1
/usr/local/sbin/usb-auto-mount unmount sde1
```

通过 systemd：

```bash
systemctl start usb-auto-mount@sde1.service
systemctl stop usb-auto-mount@sde1.service
```

---

# 两把锁的原因

脚本使用：

```text
/run/lock/usb-auto-mount-path.lock
/run/lock/usb-auto-mount-samba.lock
```

路径锁只用于选择和预留挂载目录。

Samba 锁只用于修改动态 Samba 配置。

路径锁会在调用 `mount` 前关闭。这样长期运行的 `mount.ntfs` 或 `ntfs-3g` 不会继承锁文件描述符并永久占锁。

检查 NTFS 挂载进程：

```bash
pgrep -a -f 'mount\.ntfs|ntfs-3g'
```

检查它是否错误继承锁：

```bash
pid="$(pgrep -n -f 'mount\.ntfs|ntfs-3g')"

ls -l "/proc/$pid/fd" |
grep usb-auto-mount ||
echo "No inherited USB auto-mount lock"
```

正常结果：

```text
No inherited USB auto-mount lock
```

---

# 故障排查

## 挂载点未删除

```bash
findmnt -R /mnt/usb
fuser -vm /mnt/usb/VENTOY
```

普通卸载：

```bash
umount /mnt/usb/VENTOY
```

设备已经消失时：

```bash
umount -l /mnt/usb/VENTOY
```

删除空目录：

```bash
rmdir /mnt/usb/VENTOY
```

不要对可能仍然挂载的目录使用：

```bash
rm -rf /mnt/usb/VENTOY
```

## Samba 共享未删除

```bash
cat /run/usb-auto-mount/samba-shares.conf
smbclient -L localhost -U root
```

清除对应共享片段后重新清理：

```bash
rm -f /run/usb-auto-mount/shares/sde1.conf
/usr/local/sbin/usb-auto-mount unmount sde1
```

## 服务进入 failed

```bash
systemctl reset-failed usb-auto-mount@sde1.service
```

## Windows 仍显示旧共享

先确认服务器端已经删除：

```bash
smbclient -L localhost -U root
```

Windows 中执行：

```cmd
net use \\PVE-IP\USB_VENTOY /delete /y
```

---

# 修改共享名前缀

编辑：

```bash
nano /usr/local/sbin/usb-auto-mount
```

默认：

```bash
SHARE_PREFIX="USB_"
```

如果需要让共享名与卷标完全一致：

```bash
SHARE_PREFIX=""
```

建议保留 `USB_`，避免与已有的 `extssd`、`hdd1`、`hdd2` 等共享重名。

---

# 卸载

在压缩包目录以 root 执行：

```bash
./uninstall.sh
```

卸载脚本会：

- 停止当前自动挂载服务
- 删除 systemd、udev、tmpfiles 和主脚本
- 备份 `/etc/samba/smb.conf`
- 删除动态 include 行
- 重新加载 systemd、udev 和 Samba

不会自动卸载 Samba、NTFS 或 exFAT 软件包。
