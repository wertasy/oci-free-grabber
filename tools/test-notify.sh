#!/usr/bin/env bash
# test-notify.sh — 向已配置的通知渠道发送测试消息
set -u
RUNTIME_DIR="${GRAB_RUNTIME_DIR:-$HOME/oci-grab}"
PROJECT_DIR="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
# shellcheck disable=SC1090
source "$RUNTIME_DIR/grab.conf" || exit 1
# shellcheck disable=SC1091
source "$PROJECT_DIR/lib/notify.sh"

echo "渠道: ${NOTIFY_CHANNEL:-未配置}"
if notify_send "🔔 OCI grabber 通知测试 — 渠道 ${NOTIFY_CHANNEL:-none} 配置成功 ($(date '+%F %T'))"; then
  echo "测试消息已发送 ✔"
else
  echo "发送失败 ✘ 请检查 grab.conf 中 ${NOTIFY_CHANNEL:-NOTIFY_CHANNEL} 相关配置"
  exit 1
fi
