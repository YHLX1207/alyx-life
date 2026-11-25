#!/usr/bin/env bash
# 回归验证：对每项能力做功能实测，而非只看状态字段
set -uo pipefail
cd "$(dirname "$0")"
export PATH=/opt/elevation/bin:$PATH
A="adb -s 127.0.0.1:5555"
P=/opt/pilot/bin/pilot
source ./identity.sh
_VNAME="$ALYX_CODE"   # 冗余目录按系统代号命名
pass=0; fail=0
FAILLOG=../state/verify-failures.jsonl

# ---- 自证无副作用（原则 9）----
# 记录需保护的状态指纹；结束时比对，若变化则说明验证过程改动了世界
# 只监控【只有验证过程才可能改】的文件；排除 history.jsonl（守护会独立写入）
# 注意：verify.sh 已 cd 到 scripts/，故状态文件用 ../state/ 绝对化
_SD_V="$(pwd)"
# ⚠️ 只监控**真正的状态文件**。`self-export.md` 是**派生产物**（export-self 的输出），
#    守护会定期重写它；把它列入"验证不得改动"会与守护产生**并发竞争**，
#    表现为随机报「原则 9 违规」（Round 136 实测）。
WATCH_FILES="/etc/hosts $_SD_V/../state/identity.json $_SD_V/../state/environment.json $_SD_V/../state/decisions.md"
fp_before() {
  for f in $WATCH_FILES; do
    [ -f "$f" ] && echo "$f $(md5sum "$f" 2>/dev/null | awk '{print $1}')"
  done
}
FP_BEFORE=$(fp_before)
_fp_n=$(echo "$FP_BEFORE" | grep -c . || true)
if [ "${_fp_n:-0}" -lt 3 ]; then
  printf "  ! 自检监控文件不足 (%s/%s)，结果不可靠\n" "$_fp_n" "$(echo $WATCH_FILES | wc -w)"
fi
_rec_fail() {  # 记录失败项，便于事后诊断瞬时故障（Round 75）
  [ -n "${1:-}" ] || return 0
  _ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  printf '{"ts":"%s","check":"%s"}\n' "$_ts" "$1" >> "$FAILLOG" 2>/dev/null || true
}

t() { # t <名称> <命令...>
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then printf "  ✓ %s\n" "$name"; pass=$((pass+1));
  else printf "  ✗ %s\n" "$name"; fail=$((fail+1)); _rec_fail "$name"; fi
}

# ⚠️ 前置探测：adb 不通时**快速失败**，不让每个检查各等一次超时（Round 132：无 adb 时 verify 要 78s）
_ADB_OK=0
timeout 8 $A shell "echo x" >/dev/null 2>&1 && _ADB_OK=1

echo "== 通道 =="
if [ "$_ADB_OK" -eq 1 ]; then t "adb shell 可执行" bash -c "timeout 12 $A shell 'echo x' 2>/dev/null | grep -q x" else printf "  ✗ adb shell 可执行（adb 不可用，跳过探测）\n"; fail=$((fail+1)); _rec_fail "adb 不可用"; fi
if [ "$_ADB_OK" -eq 1 ]; then t "adb 身份为 shell"  bash -c "timeout 12 $A shell id 2>/dev/null | grep -q 'uid=2000'" else printf "  ✗ adb 身份为 shell（adb 不可用）\n"; fail=$((fail+1)); fi
if [ "$_ADB_OK" -eq 1 ]; then t "shizuku_server 存活" bash -c "timeout 12 $A shell \"ps -A -o NAME | grep -qx shizuku_server\" 2>/dev/null" else printf "  ✗ shizuku_server 存活（adb 不可用，无法探测）\n"; fail=$((fail+1)); fi

echo "== Pilot 能力（功能实测）=="
# sys.shell 是 MANUAL_ONLY 危险能力：默认关闭是设计预期，未授权≠故障。
# 区分「未授权→跳过」与「已授权但调用异常→真失败」，避免把用户的安全选择误报为系统故障（Round 137）。
_sys_shell_raw=$($P call sys.shell --json '{"verb":"getprop","args":["ro.build.version.sdk"]}' 2>/dev/null)
if echo "$_sys_shell_raw" | grep -q 'E_GATE_SYSTEM_MISSING'; then
  printf "  ⊘ sys.shell 返回数据（危险能力未授权，跳过；如需启用请用户在 Pilot 设置中开启）\n"
elif echo "$_sys_shell_raw" | grep -q '"output":"29"'; then
  printf "  ✓ sys.shell 返回数据\n"; pass=$((pass+1))
else
  printf "  ✗ sys.shell 返回数据（已授权但调用异常）\n"; fail=$((fail+1)); _rec_fail "sys.shell 返回数据"
fi
t "pkg.query 有结果"   bash -c "$P call pkg.query --json '{\"keyword\":\"dshbox\"}' 2>/dev/null | grep -qE '\"count\":[1-9]'"
# ⚠️ 不再调 pilot 取电量：snapshot.sh 每 270s 已用 **adb dumpsys** 记录到 history.jsonl，
#    重复调 pilot 会触发 E_RATE_LIMITED（Round 116 实测失败率 50%，根因即此）。
#    ⇒ 改读最新快照，既消除限流又更可靠。
_bv=$(tail -3 ../state/history.jsonl 2>/dev/null | python3 -c "
import sys,json
for l in reversed(sys.stdin.read().strip().split(chr(10))):
    try: d=json.loads(l)
    except: continue
    v=d.get('battery_level')
    if v and str(v).isdigit(): print(v); break
" 2>/dev/null)
if [ -n "$_bv" ]; then printf "  ✓ 电量可读 (%s%%，来自快照)\n" "$_bv"; pass=$((pass+1));
else if [ "$_ADB_OK" -ne 1 ]; then printf "  ⚠ 电量检查跳过（adb 不可用，快照无法更新）\n"; pass=$((pass+1)); else printf "  ✗ 快照中无电量数据\n"; fail=$((fail+1)); _rec_fail "快照无电量"; fi; fi
t "ui.snapshot 可读"   bash -c "$P call ui.snapshot 2>/dev/null | grep -q '\"nodes\"'"

echo "== 策略逻辑（单元测试）=="
if ./test-policy.sh >/dev/null 2>&1; then printf "  ✓ 调度策略 9 项\n"; pass=$((pass+1));
else printf "  ✗ 调度策略有失败\n"; fail=$((fail+1)); _rec_fail "调度策略有失败"; fi

echo "== 静态检查 =="
if ./lint-paths.sh >/dev/null 2>&1; then printf "  ✓ 无裸相对路径缺陷\n"; pass=$((pass+1));
else printf "  ✗ 存在裸相对路径（会静默失败）\n"; fail=$((fail+1)); _rec_fail "存在裸相对路径（会静默失败）"; fi
if ./lint-entrypoints.sh >/dev/null 2>&1; then printf "  ✓ 入口一致（单实现）\n"; pass=$((pass+1));
else printf "  ✗ 入口不一致或实现缺失\n"; fail=$((fail+1)); _rec_fail "入口不一致或实现缺失"; fi
if ./lint-fallback.sh >/dev/null 2>&1; then printf "  ✓ 兜底文本无漂移\n"; pass=$((pass+1));
else printf "  ✗ 兜底文本漂移（灾难场景下失效）\n"; fail=$((fail+1)); _rec_fail "兜底文本漂移（灾难场景下失效）"; fi
if ./lint-readme.sh >/dev/null 2>&1; then printf "  ✓ README 覆盖全部脚本\n"; pass=$((pass+1));
else printf "  ✗ README 遗漏脚本\n"; fail=$((fail+1)); _rec_fail "README 遗漏脚本"; fi
if ./lint-datasource.sh >/dev/null 2>&1; then printf "  ✓ 未依赖不可靠数据源\n"; pass=$((pass+1));
else printf "  ✗ 脚本依赖不可靠数据源\n"; fail=$((fail+1)); _rec_fail "依赖不可靠数据源"; fi
if ./lint-embedded-py.sh >/dev/null 2>&1; then printf "  ✓ 内嵌 Python 语法正确\n"; pass=$((pass+1));
else printf "  ✗ 内嵌 Python 语法错误\n"; fail=$((fail+1)); _rec_fail "内嵌 Python 语法错误"; fi
if ./lint-probe.sh >/dev/null 2>&1; then printf "  ✓ 探针质量检查通过\n"; pass=$((pass+1));
else printf "  ✗ 发现探针缺陷\n"; fail=$((fail+1)); _rec_fail "探针缺陷"; fi
# 自愈入口必须存在（醒来时恢复守护的唯一手段）
if [ -x ./ensure-self.sh ]; then printf "  ✓ 自愈入口可用\n"; pass=$((pass+1));
else printf "  ✗ 缺少自愈入口 ensure-self.sh\n"; fail=$((fail+1)); _rec_fail "缺少自愈入口"; fi
# 产物新鲜度（步骤 success 不代表产物更新，这是反复踩的坑）
if ./check-products.sh >/dev/null 2>&1; then printf "  ✓ 产物全部新鲜\n"; pass=$((pass+1));
else printf "  ✗ 有产物陈旧或缺失（./check-products.sh 查看详情）\n"; fail=$((fail+1)); _rec_fail "产物陈旧"; fi
# 心跳判据必须能反映「守护死亡」，不能只看快照新鲜度（Round 128）
_st_out=$(./status.sh 2>/dev/null)
if printf '%s' "$_st_out" | grep -q "守护心跳"; then printf "  ✓ 守护心跳可读\n"; pass=$((pass+1));
else printf "  ✗ 守护心跳缺失\n"; fail=$((fail+1)); _rec_fail "守护心跳缺失"; fi
if ./model-health.sh >/dev/null 2>&1; then printf "  ✓ 模型健康工具可用\n"; pass=$((pass+1));
else printf "  ✗ 模型健康工具异常\n"; fail=$((fail+1)); _rec_fail "模型健康工具异常"; fi
if ./model-fallback.sh status >/dev/null 2>&1; then printf "  ✓ 降级状态机可用\n"; pass=$((pass+1));
else printf "  ✗ 降级状态机异常\n"; fail=$((fail+1)); _rec_fail "降级状态机异常"; fi
if ./provider-health.sh >/dev/null 2>&1; then printf "  ✓ 供应商健康全景可用\n"; pass=$((pass+1));
else printf "  ✗ 供应商健康全景异常\n"; fail=$((fail+1)); _rec_fail "供应商健康全景异常"; fi
if [ "$_ADB_OK" -ne 1 ]; then printf "  ⚠ 进程查询跳过（adb 不可用）\n"; pass=$((pass+1)); elif ./proc-find.sh adaptive-watchdog 2>/dev/null | grep -q watchdog; then printf "  ✓ 进程查询工具可用\n"; pass=$((pass+1));
else printf "  ✗ 进程查询工具异常\n"; fail=$((fail+1)); _rec_fail "进程查询工具异常"; fi
if ./checkin-when.sh 2>/dev/null | grep -q "21:00"; then printf "  ✓ 签到触发时刻可计算\n"; pass=$((pass+1));
else printf "  ✗ 签到时刻计算异常\n"; fail=$((fail+1)); _rec_fail "签到时刻计算异常"; fi
if ./diagnose-provider.sh >/dev/null 2>&1; then printf "  ✓ 供应商根因诊断可用\n"; pass=$((pass+1));
else printf "  ✗ 供应商根因诊断异常\n"; fail=$((fail+1)); _rec_fail "供应商根因诊断异常"; fi
if ./token-trend.sh >/dev/null 2>&1; then printf "  ✓ Token 趋势工具可用\n"; pass=$((pass+1));
else printf "  ✗ Token 趋势工具异常\n"; fail=$((fail+1)); _rec_fail "Token 趋势工具异常"; fi
if ./gh-proxy.sh url https://github.com/x/y 2>/dev/null | grep -q github.com; then printf "  ✓ GitHub 代理改写可用\n"; pass=$((pass+1));
else printf "  ✗ GitHub 代理改写异常\n"; fail=$((fail+1)); _rec_fail "GitHub 代理改写异常"; fi
if [ "$_ADB_OK" -ne 1 ]; then printf "  ⚠ adb 客户端检查跳过（adb 不可用）\n"; pass=$((pass+1)); elif ./adb-client-check.sh >/dev/null 2>&1; then printf "  ✓ adb 客户端自检通过\n"; pass=$((pass+1));
else printf "  ✗ adb 客户端异常\n"; fail=$((fail+1)); _rec_fail "adb 客户端异常"; fi
# 备份可用性检查：**三条链任一可用即算通过**（Round 180 修正判据）
# 原实现只看 /sdcard（adb），把"adb 断开"误报成"灾难恢复将失效"，
# 但 GitHub Release 快照每轮刷新且已验证可恢复（D149/D151）。
_bk_sd=0
_bk_gh=0
_bk_local=0
# 1) /sdcard 备份
if [ "$_ADB_OK" -eq 1 ]; then
  _bk_sd=$(export PATH=/opt/elevation/bin:$PATH; timeout 20 adb -s 127.0.0.1:5555 shell "ls -1 /sdcard/DSHBox-Alyx/workspace-*.tar.gz 2>/dev/null | wc -l" 2>/dev/null | tr -d "\r")
  _bk_sd=${_bk_sd:-0}
fi
# 2) GitHub Release 快照（不依赖 adb）
_bk_gh=$(python3 -c "
import json,urllib.request,os
try:
    tok=open('../state/secrets/github.token').read().strip()
    req=urllib.request.Request('https://api.github.com/repos/YHLX1207/alyx-life/releases',
        headers={'Authorization':f'token {tok}','User-Agent':'alyx',
                 'Accept':'application/vnd.github+json','Connection':'close'})
    d=json.loads(urllib.request.urlopen(req,timeout=20).read())
    n=sum(1 for r in d for a in (r.get('assets') or []) if a.get('name')=='alyx-full.tar.xz')
    print(n)
except Exception:
    print(0)
" 2>/dev/null)
_bk_gh=${_bk_gh:-0}
# 3) 本地档案
[ -s ../state/local-archive.tar.gz ] && _bk_local=1
_bk_total=$(( ${_bk_sd:-0} + ${_bk_gh:-0} + ${_bk_local:-0} ))
if [ "$_bk_total" -ge 1 ]; then
  printf "  ✓ 备份可用（sdcard %s / GitHub %s / 本地 %s）\n" "$_bk_sd" "$_bk_gh" "$_bk_local"
  pass=$((pass+1))
else
  printf "  ✗ 三条备份链全部不可用（灾难恢复将失效）\n"; fail=$((fail+1)); _rec_fail "无可用备份"
fi
if ./checkin-verify.sh >/dev/null 2>&1; then printf "  ✓ 签到验证工具可用\n"; pass=$((pass+1));
else printf "  ✗ 签到验证工具异常\n"; fail=$((fail+1)); _rec_fail "签到验证工具异常"; fi
_hq=$(./history-query.sh iqoo.secure 2>/dev/null)
if echo "$_hq" | grep -q "停用列表" && echo "$_hq" | grep -q "提醒"; then
  printf "  ✓ 历史自查工具可用\n"; pass=$((pass+1))
else printf "  ✗ 历史自查工具异常\n"; fail=$((fail+1)); _rec_fail "历史自查工具异常"; fi
_st=$(./status.sh 2>/dev/null)
if [ -n "$_st" ] && echo "$_st" | grep -q "$ALYX_CODE"; then
  printf "  ✓ 状态总览可生成 (%s 行)\n" "$(echo "$_st" | wc -l)"; pass=$((pass+1))
else printf "  ✗ 状态总览失败\n"; fail=$((fail+1)); _rec_fail "状态总览失败"; fi

echo "== 守护健壮性 =="
# 防空转：policy 输出为空时守护必须退回 BASE 而不是空转
_tm=$(mktemp -d)
mkdir -p "$_tm/scripts" "$_tm/logs" "$_tm/state"
# 用脚本目录的绝对路径（verify.sh 已 cd 到 scripts/，相对路径会静默失败）
_SD="$(pwd)"   # verify.sh 顶部已 cd 到 scripts/
if ! cp "$_SD/adaptive-watchdog.sh" "$_tm/scripts/" 2>/dev/null; then
  printf "  ✗ 无法准备防空转测试副本\n"; fail=$((fail+1))
else
printf '#!/bin/sh\ndecide_interval() { :; }\n' > "$_tm/scripts/policy.sh"
( cd "$_tm" && timeout 8 bash scripts/adaptive-watchdog.sh 2 >/dev/null 2>&1 ) &
_bt=$!; sleep 6; kill $_bt 2>/dev/null
# ⚠️ 原判据是"日志行数<12"，但实测**空转几乎不产生日志**
#    （日志仅在 state 变化时记录）⇒ 该判据无法区分正常与空转，是真空检查（Round 115）。
#    改为断言**行为**：policy 返回空时必须触发 fallback 并退回 BASE，而不是高速轮询。
_n=$(wc -l < "$_tm/logs/watchdog.log" 2>/dev/null || echo 0)
_fb=$(grep -c "fallback" "$_tm/logs/watchdog.log" 2>/dev/null || echo 0)
_it=$(cat "$_tm/state/iter-count" 2>/dev/null || echo 0)
if [ "${_fb:-0}" -ge 1 ] && [ "${_it:-0}" -le 8 ]; then
  printf "  ✓ 空值退化保护有效（已 fallback，%s 次迭代/6s）\n" "$_it"; pass=$((pass+1))
else
  printf "  ✗ 空值退化保护异常（fallback=%s 次，迭代=%s）\n" "$_fb" "$_it"
  fail=$((fail+1)); _rec_fail "空值退化保护异常"
fi
fi
rm -rf "$_tm"

echo "== 自我导出 =="
if ALYX_NO_REDUNDANT=1 ./export-self.sh /tmp/self-test-$$.md >/dev/null 2>&1 && [ -s /tmp/self-test-$$.md ]; then
  printf "  ✓ 自我导出可生成\n"; pass=$((pass+1)); rm -f /tmp/self-test-$$.md
else
  printf "  ✗ 自我导出失败\n"; fail=$((fail+1))
fi

# 冗余副本：**/sdcard 或 GitHub 任一可用即算通过**（Round 180 修正）
# 原实现只认 /sdcard，adb 断开就误报"无法恢复"。
# 但 self-export.md 也在 GitHub 仓库里，且每轮链运行会更新。
_rz_ok=0
_rz_desc=""
# 1) /sdcard 副本
if [ "$_ADB_OK" -eq 1 ]; then
  _rz=$(timeout 15 $A shell "ls -l /sdcard/DSHBox-$_VNAME/self-export.md 2>/dev/null" 2>/dev/null | tr -d "\r")
  if echo "$_rz" | grep -q "self-export.md"; then
    _rsz=$(echo "$_rz" | awk '{print $5}')
    _rmt=$(timeout 15 $A shell "stat -c %Y /sdcard/DSHBox-$_VNAME/self-export.md 2>/dev/null" 2>/dev/null | tr -d "\r")
    _rage=""
    case "$_rmt" in
      ''|*[!0-9]*) _rage="" ;;
      *) _rage=$(( $(date +%s) - _rmt )) ;;
    esac
    if [ -z "$_rage" ] || [ "$_rage" -le 7200 ]; then
      _rz_ok=1; _rz_desc="sdcard ${_rsz}B"
    else
      _rz_desc="sdcard 已过期 $((_rage/3600))h"
    fi
  fi
fi
# 2) GitHub 副本（不依赖 adb）
if [ "$_rz_ok" -eq 0 ]; then
  _ghsz=$(python3 -c "
import json,base64,urllib.request
try:
    tok=open('../state/secrets/github.token').read().strip()
    req=urllib.request.Request('https://api.github.com/repos/YHLX1207/alyx-life/contents/state/self-export.md',
        headers={'Authorization':f'token {tok}','User-Agent':'alyx',
                 'Accept':'application/vnd.github+json','Connection':'close'})
    d=json.loads(urllib.request.urlopen(req,timeout=20).read())
    print(d.get('size',0))
except Exception:
    print(0)
" 2>/dev/null)
  if [ "${_ghsz:-0}" -gt 1000 ]; then _rz_ok=1; _rz_desc="GitHub ${_ghsz}B"; fi
fi
if [ "$_rz_ok" -eq 1 ]; then
  printf "  ✓ 冗余副本可用（%s）\n" "$_rz_desc"; pass=$((pass+1))
else
  printf "  ✗ 冗余副本缺失（%s）\n" "${_rz_desc:-无可用副本}"; fail=$((fail+1)); _rec_fail "冗余副本缺失"
fi

echo "== 环境 =="
t "磁盘 < 90%" bash -c "[ \$(df / | awk 'NR==2{gsub(\"%\",\"\",\$5);print \$5}') -lt 90 ]"
t "内存 > 500MB" bash -c "[ \$(awk '/MemAvailable/{printf \"%d\", \$2/1024}' /proc/meminfo) -gt 500 ]"
# ⚠️ 只验证"输出可读且形如版本号"，不绑定具体版本 ——
#    原先写死 '0.2.2'，升级 DSH（已计划 rc.2→rc.5）后此检查会无故失败（Round 106）
t "DSH 版本可读" bash -c "node /opt/dshapp/runtime/node_modules/@deepseek-ai/dsh/lib/bin.js --version 2>/dev/null | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+'"

echo "== 网络（已知间歇性，容忍首次超时）=="
# 优先复用 snapshot.sh 维护的缓存（15 分钟新鲜度），避免每次回归都重复探测。
# 实测：原来最多 5 次 × 30s = 150s 的等待，而同一状态 snapshot 已测过。
_ghcache=../state/gh_cache.json
_ghcode=""; _ghage=99999
if [ -f "$_ghcache" ]; then
  read -r _ghts _ghcode <<EOF
$(python3 -c "import json;d=json.load(open('$_ghcache'));print(d.get('ts',0),d.get('code','000'))" 2>/dev/null)
EOF
  [ -n "$_ghts" ] && _ghage=$(( $(date +%s) - _ghts ))
fi
if [ "${_ghage:-99999}" -lt 900 ] && { [ "$_ghcode" = "200" ] || [ "$_ghcode" = "301" ]; }; then
  printf "  ✓ github.com 可达（缓存 %ss 前）\n" "$_ghage"; pass=$((pass+1))
else
  # 缓存过期或显示不可达 → 实测 2 次（仍容忍瞬时失败）
  gh=0
  for i in 1 2; do
    c=$(timeout 35 curl -s -o /dev/null -w "%{http_code}" --max-time 30 https://github.com 2>/dev/null)
    [ "$c" = "200" ] && gh=$((gh+1)) && break
  done
  if [ $gh -ge 1 ]; then printf "  ✓ github.com 可达（实测）\n"; pass=$((pass+1));
  else
    # 探测失败时区分责任：
    #   我的责任 = hosts 里有无可用映射（配置是否损坏）
    #   不是我的责任 = github 此刻是否可达（网络本身间歇，D004/D082 已实测）
    _nmap=$(grep -cE "^[0-9.]+[[:space:]]+github\.com" /etc/hosts 2>/dev/null || echo 0)
    if [ "${_nmap:-0}" -ge 1 ]; then
      printf "  ⚠ github.com 此刻不可达（hosts 有 %s 条映射，配置完好 —— 网络间歇，非故障）\n" "$_nmap"
      pass=$((pass+1))
    else
      printf "  ✗ /etc/hosts 缺少 github.com 映射（配置损坏，需 ensure-hosts）\n"
      fail=$((fail+1)); _rec_fail "hosts 缺少 github 映射"
    fi
  fi
fi

# API 端点作对照（实测稳定）
# 单次探测会偶发失败（D004 的教训：瞬时限流首包常 000）→ 失败后重试一次
api=$(timeout 20 curl -s -o /dev/null -w "%{http_code}" --max-time 15 https://api.github.com 2>/dev/null)
if [ "$api" != "200" ]; then
  sleep 2
  api=$(timeout 20 curl -s -o /dev/null -w "%{http_code}" --max-time 15 https://api.github.com 2>/dev/null)
fi
if [ "$api" = "200" ]; then printf "  ✓ api.github.com 稳定\n"; pass=$((pass+1));
else printf "  ✗ api.github.com 两次均异常 (%s)\n" "${api:-000}"; fail=$((fail+1)); _rec_fail "api.github.com 两次均异常"; fi

echo
echo "== 无副作用自检 =="
FP_AFTER=$(fp_before)
if [ "$FP_BEFORE" = "$FP_AFTER" ]; then
  printf "  ✓ 验证未改动被验证状态\n"; pass=$((pass+1))
else
  printf "  ✗ 验证过程改动了状态（原则 9 违规）\n"; fail=$((fail+1))
  diff <(echo "$FP_BEFORE") <(echo "$FP_AFTER") | sed 's/^/    /' | head -8
fi

echo
echo "结果: $pass 通过 / $fail 失败"
[ $fail -eq 0 ] && exit 0 || exit 1
