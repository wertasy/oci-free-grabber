#!/usr/bin/env bash
# notify.sh — 可配置通知模块
# 由 grab.conf 的 NOTIFY_CHANNEL 决定渠道, notify_send 统一入口:
#   notify_send "消息文本"  → 成功返回 0
# 渠道与所需配置:
#   telegram  TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID        (BotFather 建 bot, chat_id 用 @userinfobot 查)
#   ntfy      NTFY_TOPIC_URL  [NTFY_TOKEN]               (https://ntfy.sh/<你的主题>)
#   bark      BARK_URL                                    (iOS Bark App 的推送 URL)
#   serverchan SERVERCHAN_SENDKEY                         (sc.ftqq.com 的 SendKey, 微信推送)
#   webhook   WEBHOOK_URL                                 (POST {"text": "..."})
#   none      不发送

notify_send() {
  local msg="$1"
  case "${NOTIFY_CHANNEL:-none}" in
    telegram)
      [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ] || return 1
      curl -sS -m 15 "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
           --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
           --data-urlencode "text=${msg}" | grep -q '"ok":true'
      ;;
    ntfy)
      [ -n "${NTFY_TOPIC_URL:-}" ] || return 1
      local auth=(); [ -n "${NTFY_TOKEN:-}" ] && auth=(-H "Authorization: Bearer ${NTFY_TOKEN}")
      curl -sS -m 15 "${auth[@]}" --data-binary "$msg" "$NTFY_TOPIC_URL" >/dev/null
      ;;
    bark)
      [ -n "${BARK_URL:-}" ] || return 1
      curl -sS -m 15 "$BARK_URL/$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))' "$msg")" >/dev/null
      ;;
    serverchan)
      [ -n "${SERVERCHAN_SENDKEY:-}" ] || return 1
      curl -sS -m 15 "https://sctapi.ftqq.com/${SERVERCHAN_SENDKEY}.send" \
           --data-urlencode "title=OCI 抢机通知" \
           --data-urlencode "desp=${msg}" | grep -q '"code":0'
      ;;
    webhook)
      [ -n "${WEBHOOK_URL:-}" ] || return 1
      curl -sS -m 15 -H 'Content-Type: application/json' \
           -d "$(python3 -c 'import json,sys;print(json.dumps({"text":sys.argv[1]}))' "$msg")" \
           "$WEBHOOK_URL" >/dev/null
      ;;
    none|"") return 1 ;;
    *) echo "未知 NOTIFY_CHANNEL: $NOTIFY_CHANNEL" >&2; return 1 ;;
  esac
}
