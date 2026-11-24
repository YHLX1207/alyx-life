#!/usr/bin/env bash
# 自愈入口：每次"我醒来"的第一件该做的事
#
# 为什么需要它：
#   守护进程 PPID=1，脱离 DSH 进程树。但 DSH 重启后守护**不会**自动回来
#   （容器内无 cron，profile.d 不加载，DSH 的 bash 用 --noprofile）。
#   而 DSH 重启 = 我会重新醒来。**醒来后第一件事跑这个，就能恢复一切。**
#
#   这条链路要求的是"有人打开 DSHBox"，比"有人记得跑一条 curl"现实得多。
#
# 检查顺序：守护 → 远端心跳 → 可移植自检。全部幂等，可重复运行。
set -uo pipefail
cd "$(dirname "$0")"

pass=0; warn=0; act=0
ok(){ printf "  ✓ %s\n" "$*"; pass=$((pass+1)); }
bad(){ printf "  ⚠ %s\n" "$*"; warn=$((warn+1)); }
do_act(){ printf "  → %s\n" "$*"; act=$((act+1)); }

echo "== 自愈检查 =="

# 1) 守护进程
# ⚠️ 不能用 `grep -q "running"`：`not running` 也含该子串，
#    守护被杀后会被误判为"在跑"，从而跳过自愈（Round 152 实测）。
#    用 `^running` 或直接读 pid 判活。
if ./daemon-ctl.sh status 2>/dev/null | grep -q "^running"; then
  ok "守护在跑 ($(cat ../state/watchdog.pid))"
else
  do_act "守护未运行，正在拉起…"
  if ./boot-hook.sh >/dev/null 2>&1; then
    sleep 2
    if ./daemon-ctl.sh status 2>/dev/null | grep -q "^running"; then
      ok "守护已恢复 ($(cat ../state/watchdog.pid))"
    else
      bad "守护拉起失败，需人工检查"
    fi
  else
    bad "boot-hook 执行失败"
  fi
fi

# 2) 远端心跳
TOKEN=$(cat ../state/secrets/github.token 2>/dev/null || echo "")
if [ -z "$TOKEN" ]; then
  bad "无 GitHub token（远程自愈暂不可用）"
else
  AGE=$(python3 - "$TOKEN" <<'PY' 2>/dev/null
import sys, json, base64, urllib.request, datetime
token = sys.argv[1]
try:
    req = urllib.request.Request(
        "https://api.github.com/repos/YHLX1207/alyx-life/contents/state/journal.jsonl",
        headers={"Authorization": f"token {token}", "User-Agent": "alyx",
                 "Accept": "application/vnd.github+json", "Connection": "close"})
    d = json.loads(urllib.request.urlopen(req, timeout=25).read())
    lines = [l for l in base64.b64decode(d.get("content", "")).decode().strip().split("\n") if l.strip()]
    last = json.loads(lines[-1])
    lt = datetime.datetime.strptime(last["ts"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
    gap = (datetime.datetime.now(datetime.timezone.utc) - lt).total_seconds() / 3600.0
    print(f"{gap:.2f}")
except Exception:
    print("ERR")
PY
)
  if [ "$AGE" = "ERR" ] || [ -z "$AGE" ]; then
    bad "无法读取远端心跳（网络或 API）"
  else
    # ⚠️ 不能用 bc（容器里没有），否则"命令不存在"会被当成"条件成立"（Round 152 实测误判）
    # 注意方向：python 退出 0 表示"新鲜"，应走成功分支
    if python3 -c "import sys; sys.exit(0 if float('$AGE') < 6 else 1)" 2>/dev/null; then
      ok "远端心跳新鲜（${AGE} 小时前）"
    else
      bad "远端心跳已过时 ${AGE} 小时 → 触发远端"
      if ./remote-heartbeat.sh >/dev/null 2>&1; then
        ok "远端已触发"
      else
        bad "远端触发失败"
      fi
    fi
  fi
fi

# 3) 本地可移植自检（快、无副作用）
if ./check-portable.sh >/dev/null 2>&1; then
  ok "可移植自检通过"
else
  bad "可移植自检有失败项，建议运行 ./verify.sh 排查"
fi

echo
echo "  结果: $pass 通过 / $warn 告警 / $act 动作"
[ "$warn" -eq 0 ]
