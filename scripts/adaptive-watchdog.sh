#!/usr/bin/env bash
# 自适应守护：调度决策来自 policy.sh（已单元测试），本文件只负责采集与执行
set -uo pipefail
cd "$(dirname "$0")"
source ./policy.sh

LOG=../logs/watchdog.log
BASE=${1:-180}
mkdir -p ../logs
log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" | tee -a "$LOG" >/dev/null; }

export PATH=/opt/elevation/bin:$PATH
A="adb -s 127.0.0.1:5555"

log "adaptive-watchdog start base=${BASE}s"

last_reason=""
n=0
while :; do
  n=$((n+1))
  # 迭代计数落盘：供防空转检查与事后诊断（v 2026-11-21）
  printf '%d\n' "$n" > ../state/iter-count 2>/dev/null || true
  adb_ok=false; shz_ok=false
  timeout 12 $A shell "echo P" 2>/dev/null | grep -q P && adb_ok=true

  # 连续失败才认定真故障：单次抖动不应触发自愈与告警（D060 同类思路）
  STREAK=../state/fail-streak.json
  _prev=$(python3 -c "
import json,os
d={'adb':0,'shz':0}
if os.path.exists('../state/fail-streak.json'):
    try: d.update(json.load(open('../state/fail-streak.json')))
    except: pass
print(d.get('adb',0), d.get('shz',0))
" 2>/dev/null)
  _st=$(echo "$_prev" | awk '{print $1+0}')
  _sz=$(echo "$_prev" | awk '{print $2+0}')
  if $adb_ok; then
    s=$(timeout 10 $A shell "ps -A -o NAME 2>/dev/null | grep -cx shizuku_server" 2>/dev/null | tr -d '\r')
    [ "${s:-0}" -ge 1 ] && shz_ok=true
  fi
  # 连击计数：成功清零，失败累加
  $adb_ok || _st=$(( _st + 1 ))
  $adb_ok && _st=0
  $shz_ok || _sz=$(( _sz + 1 ))
  $shz_ok && _sz=0
  printf '{"adb":%d,"shz":%d}\n' "$_st" "$_sz" > "$STREAK" 2>/dev/null || true
  # ⚠️ 阈值必须作用在「生效状态」上，不能直接改 adb_ok：
  #    adb_ok 是原始探测结果，失败时本来就是 false，
  #    若在它上面判断 >=3 才置 false，等于毫无作用（Round 59 修正的错误）
  adb_eff=$adb_ok; shz_eff=$shz_ok
  [ "$_st" -lt 3 ] && adb_eff=true      # 未达 3 次 → 视为正常，屏蔽抖动
  [ "$_sz" -lt 3 ] && shz_eff=true
  adb_ok=$adb_eff; shz_ok=$shz_eff

  # ⚠️ 不用 pilot 取电量：单次实测 3.7s 且常被 E_RATE_LIMITED（D115/D118）。
  #    adb dumpsys 约 100ms，快 30 倍，且不占 pilot 配额。
  batt=$(timeout 8 $A shell "dumpsys battery 2>/dev/null | awk '/  level:/{print \$2}'" 2>/dev/null | tr -d '\r')
  mem=$(awk '/MemAvailable/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null)

  # 容器内 /proc/loadavg 不可读（proot 限制），改从设备侧取
  load=$(timeout 8 $A shell "cat /proc/loadavg 2>/dev/null" 2>/dev/null | tr -d '\r' | awk '{print $1}')
  # 传入 adb 连续失败轮数，供 policy 区分"短断/长断"（Round 185）
  export ALYX_ADB_STREAK="${_st:-0}"
  read -r interval reason <<< "$(decide_interval "$BASE" "$adb_ok" "$shz_ok" "$batt" "$mem" "$load")" || true

  # 防空转：间隔必须是有效正整数，否则退回 BASE 并记录
  # （decide_interval 若因 policy.sh 加载失败返回空，sleep "" 会失败但脚本不退出，
  #   set -uo 下无 set -e，循环会高速空转，并连带高频触发下方 hosts 刷新）
  case "${interval:-}" in
    ''|*[!0-9]*|0)
      log "WARN invalid interval='${interval:-<empty>}' reason='${reason:-<none>}' -> fallback ${BASE}s"
      interval=$BASE
      reason="fallback"
      ;;
  esac

  # 原因变化时记录一次，避免每轮刷屏
  if [ "$reason" != "$last_reason" ]; then
    log "state=${reason} interval=${interval}s (batt=${batt:-?} mem=${mem:-?} load=${load:-?})"
    last_reason="$reason"
  fi

  # 故障自愈：直接依据 adb_ok / shz_ok 标志，而非 reason 字符串。
  # 原因：interval 非法时上面的 fallback 会把 reason 改成 "fallback"，
  # 故障信号随之丢失 ⇒ 自愈永不触发（Round 59 发现的真实缺陷）。
  if ! $adb_ok; then
    # ⚠️ 退避：adb 连续失败多轮时，多半是**物理断开**（USB 拔了/没电），
    #    ensure-adb 对此无能为力，每轮重试只是白耗时间（Round 134：曾连试 64 轮）。
    #    策略：前 3 轮正常尝试；之后每 10 轮才重试一次。
    # 注意：_st 是本轮**已累计**的失败次数，自愈在 _st>=3 才首次触发，
    # 所以前几次必须是 3,4,5（给 3 次机会），之后才退避。
    if [ "${_st:-0}" -le 5 ]; then
      log "adb_down (streak=${_st}) -> ensure-adb"
      ./ensure-adb.sh >/dev/null 2>&1; ./alert.sh "adb 通道中断，尝试自愈"
    elif [ "${_st:-0}" -gt 1000 ]; then
      # ⚠️ 长时间断开（>1000 轮 ≈1 天）几乎肯定是**物理断开**，
      #    软件无法恢复。改为每 100 轮才试一次，避免无意义的日志与开销。
      if [ $(( ${_st:-0} % 100 )) -eq 0 ]; then
        log "adb_down (streak=${_st}) -> 长期断开，低频重试（每100轮）"
        ./ensure-adb.sh >/dev/null 2>&1
      fi
    elif [ $(( ${_st:-0} % 10 )) -eq 0 ]; then
      log "adb_down (streak=${_st}) -> 退避重试（每10轮）"
      ./ensure-adb.sh >/dev/null 2>&1
    fi
  elif ! $shz_ok; then
    log "shizuku_down (streak>=3) -> ensure-shizuku"
    ./ensure-shizuku.sh >/dev/null 2>&1 || ./alert.sh "Shizuku 自愈失败"
  fi

  # LLM 资源巡检：每 20 轮（约 1 小时）一次。纯本地读 JSON，无网络、无 LLM 调用。
  # 只做真风险告警（不可续期账户到期 / 续期成功率过低 / 失效模型），已去重。
  if [ $((n % 20)) -eq 0 ]; then
    _ra=$(./llm-alert.sh 2>/dev/null | head -1)
    [ -n "$_ra" ] && log "llm-alert: $_ra"
    ./resource-snapshot.sh >/dev/null 2>&1 || log "resource-snapshot failed"
  fi

  # 网络自愈：每 20 轮（约 1 小时）刷新一次 GitHub hosts
  if [ $((n % 20)) -eq 0 ]; then
    log "refreshing github hosts"
    # 必须后台执行 + 超时上限：ensure-hosts 在网络差时最坏可达 ~8 分钟
    # （取候选 25s + 7 域名 × 多候选 × 2 次探测 × 8s），
    # 同步调用会让整个守护循环停摆、期间不写快照（Round 48 发现）
    ( timeout 480 ./ensure-hosts.sh >/dev/null 2>&1 || log "ensure-hosts failed/timeout" ) &
    # 工作区完整备份（D109）：脚本+状态+笔记 → /sdcard，保 3 份。
    # 后台执行，失败不影响主循环。
    # ⚠️ backup-workspace 的退出码语义（Round 186）：
    #    0 = 完整成功（本地 + /sdcard）
    #    2 = 本地档案已更新，但推送失败（adb 不可用）—— 不算失败
    #    其它 = 真失败（打包错误等）
    ( timeout 180 ./backup-workspace.sh >/dev/null 2>&1
      _brc=$?
      if [ "$_brc" -eq 2 ]; then
        : # 本地档案已更新，静默（避免 111 条噪音）
      elif [ "$_brc" -ne 0 ]; then
        log "backup-workspace failed (rc=$_brc)"
      fi
    ) &
  fi

  # 远程自愈（Round 147）：若 GitHub 上的心跳超过 3 小时没更新，
  # 说明那边的 cron 没跑（实测它确实从不触发），主动 dispatch 一次。
  # 只在"本机活着"时有效 —— 但它把"完全依赖 cron"变成"我醒着就帮你一把"。
  # 让守护自己把"我还活着"写到远端（不依赖 DSH，也不依赖 cron）
  # 频率较低（每 30 轮 ≈2h），避免 API 调用过密
  if [ $(( n % 30 )) -eq 0 ]; then
    ( timeout 90 ./remote-journal.sh >/dev/null 2>&1 || true ) &
    # 同时刷新完整快照到 Release —— 否则快照会随时间过时，
    # 恢复出来的是"旧的我"（Round 153 实测：快照落后 1 脚本 + 1 决策）
    ( timeout 180 ./snapshot-release.sh >/dev/null 2>&1 || true ) &
  fi

  if [ $(( n % 6 )) -eq 0 ]; then    # 每 6 轮≈18-27min 查一次，配合 1.5h 阈值，最坏延迟约 2h
    ( timeout 90 ./remote-heartbeat.sh >/dev/null 2>&1 || true ) &
  fi

  # ⚠️ 节点注册 + 同步（Round 200 修复）：
  #    守护此前只跑 mutual-watch（只读），从不注册自己。
  #    ⇒ 设备节点的记录停在手动运行时，长期显示为"失联"。
  #    ⇒ 节点表共识误判为 degraded，即使守护一直在跑。
  #    必须每轮（或定期）注册自己，才能反映真实状态。
  if [ $(( n % 5 )) -eq 0 ]; then
    ( timeout 90 bash -c "
      ./node-registry.sh
      ./sync-nodes.sh
    " >> ../logs/watchdog.log 2>&1 || true ) &
  fi

  # 节点互监（每 20 轮 ≈1h）：检查其它节点是否还活着
  # 若同伴全部失联，本机升级为 primary —— 但仅记录，不改变运行方式，
  # 因为 device 节点本来就一直在跑，接管意味着"不再指望 actions"。
  if [ $(( n % 20 )) -eq 0 ]; then
    ( timeout 60 ./mutual-watch.sh >> ../logs/watchdog.log 2>&1 || true ) &
  fi

  # 日志轮转：每 50 轮（约 2.5-5 小时）检查一次，防止日志无限增长（Round 187）
  if [ $(( n % 50 )) -eq 0 ]; then
    ( timeout 30 ./log-rotate.sh 2000 3 >/dev/null 2>&1 || true ) &
  fi

  ./snapshot.sh >/dev/null 2>&1 &
  sleep "$interval"
done
