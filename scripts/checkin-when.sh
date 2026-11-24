#!/usr/bin/env bash
# 计算签到的精确触发时刻（含实际配置的 jitter）
#
# 依据：dsh-providers-hub 的 checkinJitterOffsetMs 用 FNV-1a 哈希
#   seed = "<date>#<time>"，bucket = hash % (2*span+1)，offset = bucket - span
#   span = min(jitterMinutes, floor(gapToNextSlot/2))
# ⇒ 同一 (date,time) 的偏移恒定，可预知。
#
# ⚠️ jitter **从配置文件实时读取**，不硬编码 ——
#    Round 93 实际踩到：配置曾被重置为 0，硬编码 5 导致预测偏差 3 分钟。
#
# 用法: checkin-when.sh [日期 YYYY-MM-DD]
set -uo pipefail
cd "$(dirname "$0")"

_TMPJS=$(mktemp /tmp/cw.XXXXXX.js)
trap 'rm -f "$_TMPJS"' EXIT
cat > "$_TMPJS" <<'JS'
const fs = require('fs');
const BJ = 8 * 3600 * 1000;
const cfgPath = '/root/projects/.dsh/jet-hub/auto-checkin.json';
let cfg = {};
try { cfg = JSON.parse(fs.readFileSync(cfgPath, 'utf8')); } catch (e) {}
const times = (cfg.times && cfg.times.length) ? cfg.times : ['09:00', '21:00'];
let jitter = cfg.jitterMinutes;
if (typeof jitter !== 'number' || !isFinite(jitter)) jitter = 0;
const argDate = process.argv[2];
const now = new Date(Date.now() + BJ);
const date = argDate || now.toISOString().slice(0, 10);

function gapMin(a, b) {
  const [x, y] = a.split(':').map(Number);
  const [p, q] = b.split(':').map(Number);
  return (q - y) * 60 + (p - x);
}
function offset(date, time, jm, gapToNext) {
  const span = Math.min(jm, Math.max(0, Math.floor(gapToNext / 2)));
  if (span <= 0) return 0;
  const seed = date + '#' + time;
  let h = 2166136261;
  for (let i = 0; i < seed.length; i++) { h ^= seed.charCodeAt(i); h = Math.imul(h, 16777619); }
  return ((h >>> 0) % (span * 2 + 1)) - span;
}

console.log('=== 签到精确触发时刻（北京时区）===');
console.log('  日期:', date, ' jitter:', jitter, '分钟', jitter === 0 ? '(无偏移)' : '');
const nowMs = Date.now();
for (let i = 0; i < times.length; i++) {
  const t = times[i];
  const next = times[(i + 1) % times.length];
  const gap = (i + 1 < times.length) ? gapMin(t, next) : gapMin(t, next) + 24 * 60;
  const off = offset(date, t, jitter, gap);
  const base = new Date(date + 'T' + t + ':00+08:00').getTime();
  const real = base + off * 60000;
  const tag = real <= nowMs ? '✓已过' : '  待触发';
  const rel = ((real - nowMs) / 60000).toFixed(1);
  console.log('  ' + t + ' → 实际 ' + new Date(real + BJ).toISOString().slice(11, 19) +
              ' 偏移 ' + (off > 0 ? '+' : '') + off + '分' + tag +
              (real > nowMs ? '  (' + rel + ' 分钟后)' : ''));
}
JS
node "$_TMPJS" "${1:-}"
