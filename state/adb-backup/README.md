# adb 客户端单点故障备份

## 结构
```
/opt/elevation/bin/adb    ← 790 字节包装脚本（单点故障！）
/opt/elevation/real/adb   ← 733KB ARM64 真二进制
/opt/elevation/server.conf ← localfilesystem:/opt/elevation/adb.sock
```

`bin/adb` 只是设置 HOME/密钥/socket 的 shim。**它一坏，所有设备访问全断**，
且系统内没有第二份 adb。

## 已备份
- `adb-wrapper.sh` = `/opt/elevation/bin/adb` 的完整内容

## 重建方法（若 bin/adb 丢失）
```bash
mkdir -p /opt/elevation/bin
cp /root/projects/life/state/adb-backup/adb-wrapper.sh /opt/elevation/bin/adb
chmod +x /opt/elevation/bin/adb
```
或直接绕过 wrapper：
```bash
HOME=/opt/elevation/home \
ADB_VENDOR_KEYS=/opt/elevation/home/.android/keys \
ADB_SERVER_SOCKET=localfilesystem:/opt/elevation/adb.sock \
/opt/elevation/real/adb -s 127.0.0.1:5555 shell id
```

## 已验证（2026-11-21）
- wrapper md5: `cfcfc49f5179cabdfad18eb4acb040c6`（790 字节）
- 真二进制 md5: `b56c7bd0ef5f6ca78ca8266fc78de26c`（733264 字节，ARM64 ELF）
- 直连真二进制实测返回 `REAL_ADB_OK` ✓
