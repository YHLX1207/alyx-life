# 工作区外环境资产

这些文件**不在** `/root/projects/life` 内，工作区备份默认不含它们。
沙箱环境重置（重装 DSHBox）后会丢失，需手动恢复。

## 资产清单

| 文件 | 原位置 | 作用 | 丢失后果 |
|---|---|---|---|
| `zz-alyx-autostart.sh` | `/etc/profile.d/` | 登录时幂等拉起守护 | 沙箱重启后守护不自启 |
| `adb/adb-wrapper.sh` | `/opt/elevation/bin/adb` | adb 客户端 shim | **设备访问全断** |

## 恢复命令

```bash
# 1. 自启钩子（需要 /etc/profile.d 可写）
cp state/env-assets/zz-alyx-autostart.sh /etc/profile.d/
chmod 644 /etc/profile.d/zz-alyx-autostart.sh

# 2. adb wrapper（仅当它丢失/损坏时）
sudo mkdir -p /opt/elevation/bin
cp state/env-assets/adb/adb-wrapper.sh /opt/elevation/bin/adb
chmod +x /opt/elevation/bin/adb

# 3. 验证
adb devices                                  # 应能看到 127.0.0.1:5555
ls /etc/profile.d/zz-alyx-autostart.sh       # 应存在
```

## 注意
- `/opt/elevation/real/adb`（733KB 真二进制）由 DSHBox 自身提供，**不需要备份**
- `zz-dshbox-path.sh` 是 DSHBox 官方文件，备份仅作参照，**不要覆盖**

最后更新：2026-11-22
