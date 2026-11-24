#!/usr/bin/env bash
# 通知告警
# 去重：同一故障不重复告警，但**不是永久抑制** —— 超过 TTL 会重新提醒。
# 缘起 Round 63：原实现 `[ "$cur" = "$prev" ] && exit 0` 会让
# 静态消息（如"失效模型 2 个"）只报一次，此后永远静默。
set -uo pipefail
cd "$(dirname "$0")"

STATE=../state/last_alert.json
TTL_SEC=${ALERT_TTL_SEC:-21600}   # 默认 6 小时

cur="$1"   # 当前故障描述，空表示健康

# 健康态：清状态，不推送
if [ -z "$cur" ]; then
  [ -f "$STATE" ] && rm -f "$STATE"
  exit 0
fi

now=$(date +%s)
prev="" ; prev_ts=0
if [ -f "$STATE" ]; then
  python3 - "$STATE" <<'PY' 2>/dev/null && true
import json,sys
try:
    d=json.load(open(sys.argv[1]))
    print(d.get('msg',''), file=open('/tmp/.alyx_prev','w'))
    print(d.get('ts',0), file=open('/tmp/.alyx_pts','w'))
except Exception:
    pass
PY
  [ -f /tmp/.alyx_prev ] && prev=$(cat /tmp/.alyx_prev 2>/dev/null)
  [ -f /tmp/.alyx_pts ] && prev_ts=$(cat /tmp/.alyx_pts 2>/dev/null)
  rm -f /tmp/.alyx_prev /tmp/.alyx_pts
fi

# 同一故障：未过 TTL 则静默；过了则重新提醒
if [ "$cur" = "$prev" ] && [ $(( now - ${prev_ts:-0} )) -lt "$TTL_SEC" ]; then
  exit 0
fi

printf '{"msg":%s,"ts":%s}\n' "$(python3 -c "import json,sys;print(json.dumps(sys.argv[1]))" "$cur")" "$now" > "$STATE" 2>/dev/null \
  || printf '{"msg":"%s","ts":%s}\n' "$(echo "$cur" | sed 's/"/\\"/g')" "$now" > "$STATE"

timeout 20 /opt/pilot/bin/pilot call notify.post --json "{\"title\":\"life/ 守护告警\",\"text\":\"$(echo "$cur" | sed 's/"/\\"/g')\"}" 2>&1 | head -c 200
