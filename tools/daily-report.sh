#!/usr/bin/env bash
# daily-report.sh — 每日早报: 统计前一天抢机战况并推送
# cron 建议: UTC 0:00 = 北京时间 8:00
set -u
RUNTIME_DIR="${GRAB_RUNTIME_DIR:-$HOME/oci-grab}"
PROJECT_DIR="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
LOG="$RUNTIME_DIR/grab.log"

# shellcheck disable=SC1090
source "$RUNTIME_DIR/grab.conf" || exit 1
# shellcheck disable=SC1091
source "$PROJECT_DIR/lib/notify.sh"

YDAY=$(TZ="${REPORT_TZ:-CST-8}" date -d yesterday +%F)

ATTEMPTS=$(grep -c "^\[$YDAY.*无容量" "$LOG" 2>/dev/null) || ATTEMPTS=0
RATE=$(grep -c "^\[$YDAY.*触发限流" "$LOG" 2>/dev/null) || RATE=0
OTHER=$(grep -c "^\[$YDAY.*其他错误" "$LOG" 2>/dev/null) || OTHER=0
ROUNDS=$(grep -c "^\[$YDAY.*本轮扫完" "$LOG" 2>/dev/null) || ROUNDS=0

if [ -f "$RUNTIME_DIR/DONE" ]; then
  STATUS="🎉 已抢到! 不再需要等待
$(cat "$RUNTIME_DIR/DONE")"
elif [ "${ATTEMPTS:-0}" -eq 0 ] && [ "${ROUNDS:-0}" -eq 0 ]; then
  STATUS="⚠️ 昨天没有任何抢机记录 (机器是否关机? 日志是否被清理?)"
else
  STATUS="仍在蹲守容量, 自动抢注继续中"
fi

MSG="📰 OCI 抢机早报 · ${YDAY}
状态: ${STATUS}
━━━━━━━━━━
昨日抢注尝试: ${ATTEMPTS:-0} 次 (无容量)
限流: ${RATE:-0} 次 | 其他错误: ${OTHER:-0} 次
完成扫描轮次: ${ROUNDS:-0} 轮"

for i in 1 2 3; do
  if notify_send "$MSG"; then exit 0; fi
  sleep 10
done
echo "[$(date '+%F %T')] 早报发送失败" >> "$RUNTIME_DIR/report.log"
