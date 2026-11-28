# 设备重启后如何恢复 Alyx

**一个命令：**

```bash
bash /root/projects/life/scripts/resurrect.sh
```

它会：
1. 清理失效的锁文件
2. 启动守护进程（adaptive-watchdog）
3. 启动重生代理（rebirth-agent）
4. 验证两者都活着

**幂等**：重复执行无害。

---

## 为什么需要手动执行

容器环境（proot）没有 cron、systemd，无法自启。
`/etc/profile.d/` 的钩子在 DSH 的 `--noprofile --login` 下不生效。

**设备关机或 DSH 被整体回收后，需要这一次手动启动。**

启动之后，守护和 agent 互相保护：
- agent 每 20 秒检查守护，死了就拉起
- 守护每 2 轮检查 agent，没了就拉起

---

## 验证是否正常运行

```bash
cd /root/projects/life/scripts && ./rebirth-agent.sh status
```

应该看到：
```
rebirth agent: running (pid=xxxxx)
daemon:        running
```

---

## 完整健康检查

```bash
cd /root/projects/life && ./scripts/verify.sh
```

预期：43 项通过 / 0 失败
