#!/usr/bin/env bash
# grab.sh — OCI Always Free 实例自动抢注
# 从"实例配置"出发, 每轮扫所有可用域逐个发起 LaunchInstance,
# 容量不足自动等待下一轮(由 cron 驱动), 抢到后写 DONE 标记并推送通知。
#
# 踩坑固化(详见 README 常见问题):
#   1. 仅凭 --instance-configuration-id 启动会被 CLI 拒绝 → 显式构造完整请求体
#   2. 配置ID+覆盖字段的混合请求会被服务端 404 → 不再用 instance-configuration-id
#   3. A1(Ampere) 不支持 baseline 降频, 保留会 404 → 清洗 shape-config
set -u
umask 077

RUNTIME_DIR="${GRAB_RUNTIME_DIR:-$HOME/oci-grab}"
CONF="$RUNTIME_DIR/grab.conf"
LOG="$RUNTIME_DIR/grab.log"
DONE_MARK="$RUNTIME_DIR/DONE"
PENDING="$RUNTIME_DIR/notify-pending.txt"
REQ_FILE="$RUNTIME_DIR/launch.json"
OCI="${OCI_CLI_BIN:-$HOME/.oci-venv/bin/oci}"
OCI_CONFIG="${OCI_CONFIG_FILE:-$HOME/.oci/config}"
PROJECT_DIR="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"

# 屏蔽 CLI 权限/密钥格式警告, 避免污染 JSON 解析
export SUPPRESS_LABEL_WARNING=True
export OCI_CLI_SUPPRESS_FILE_PERMISSIONS_WARNING=True

log() { echo "[$(date '+%F %T')] $*" >> "$LOG"; }

# 并发锁: cron 周期重叠时后来的直接退出, 防止重复下单
exec 9>>"$RUNTIME_DIR/.lock"
flock -n 9 || exit 0

# shellcheck disable=SC1090
source "$CONF" || { log "错误: 读取 $CONF 失败"; exit 1; }
# shellcheck disable=SC1091
source "$PROJECT_DIR/lib/notify.sh"

# 通知: 先落 pending 文件, 立即尝试送达; 失败则留待下轮 cron 重试
notify() {
  printf '%s\n' "$1" > "$PENDING"
  deliver_pending
}
deliver_pending() {
  [ -f "$PENDING" ] || return 0
  if notify_send "$(cat "$PENDING")"; then
    rm -f "$PENDING"; log "通知已送达 (${NOTIFY_CHANNEL:-none})"
  else
    log "通知未送达, 下轮重试"
  fi
}

# 日志超 5MB 截断
[ -f "$LOG" ] && [ "$(stat -c%s "$LOG")" -gt 5242880 ] && : > "$LOG"

# 先补投上轮未送达的通知, 再检查是否已完成
deliver_pending
[ -f "$DONE_MARK" ] && exit 0

case "${OCI_USER_OCID:-}${OCI_TENANCY_OCID:-}${OCI_REGION:-}" in
  ""|*REPLACE_ME*|*REQUIRED*) log "等待配置: conf 必填项未填"; exit 0 ;;
esac
[ -x "$OCI" ] || { log "错误: 找不到 oci CLI ($OCI)"; exit 1; }

# 随机抖动, 打散请求节奏
sleep $((RANDOM % (JITTER + 1) + 2))

COMP="${COMPARTMENT_OCID:-$OCI_TENANCY_OCID}"
api() { "$OCI" --output json "$@" 2>&1; }

# ---- 1) 按名字找实例配置(先根隔间, 再一级子隔间) ----
COMPS="$COMP"
SUB=$(api iam compartment list --compartment-id "$OCI_TENANCY_OCID" \
      --access-level ACCESSIBLE --all)
if echo "$SUB" | grep -q '"data"'; then
  SUB_COMPS=$(printf '%s' "$SUB" | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit()
for c in d.get("data") or []:
    if c.get("lifecycle-state")=="ACTIVE": print(c["id"])')
  [ -n "$SUB_COMPS" ] && COMPS="$COMPS
$SUB_COMPS"
fi

IC_OCID=""
while IFS= read -r c; do
  [ -n "$c" ] || continue
  R=$(api compute-management instance-configuration list --compartment-id "$c" --all)
  HIT=$(printf '%s' "$R" | python3 -c '
import json,sys
name=sys.argv[1]
try: d=json.load(sys.stdin)
except Exception: sys.exit()
for x in d.get("data") or []:
    if x.get("display-name")==name: print(x["id"]); break' "$INSTANCE_CONFIG_NAME")
  if [ -n "$HIT" ]; then IC_OCID="$HIT"; COMP="$c"; break; fi
done <<EOF
$COMPS
EOF
[ -n "$IC_OCID" ] || { log "错误: 找不到实例配置 '$INSTANCE_CONFIG_NAME'"; exit 1; }
log "实例配置: $IC_OCID"

# ---- 2) 可用域列表 ----
ADS=$(api iam availability-domain list | python3 -c '
import json,sys
d=json.load(sys.stdin)
print("\n".join(x["name"] for x in d.get("data") or []))')
[ -n "$ADS" ] || { log "错误: 获取可用域失败"; exit 1; }

# ---- 3) 子网: 未指定则自动选第一个公共子网 ----
if [ -z "${SUBNET_OCID:-}" ]; then
  SUBNET_OCID=$(api network subnet list --compartment-id "$COMP" --all | python3 -c '
import json,sys
d=json.load(sys.stdin)
subs=d.get("data") or []
pub=[s["id"] for s in subs if not s.get("prohibit-public-ip-on-vnic", True)]
print(pub[0] if pub else (subs[0]["id"] if subs else ""))')
  if [ -n "$SUBNET_OCID" ]; then log "自动选择子网: $SUBNET_OCID"; else log "隔间内没有子网, 依赖实例配置自带网络"; fi
fi

# ---- 4) 由实例配置构造完整启动请求体 ----
DETAILS=$(api compute-management instance-configuration get --instance-configuration-id "$IC_OCID")
build_req() {
  printf '%s' "$DETAILS" | python3 -c '
import json,sys
d=json.load(sys.stdin)
ld=((d.get("data") or {}).get("instance-details") or {}).get("launch-details") or {}
ad,comp,name,subnet,outpath=sys.argv[1:6]
def clean(x):
    if isinstance(x,dict): return {k:clean(v) for k,v in x.items() if v is not None}
    if isinstance(x,list): return [clean(v) for v in x]
    return x
shape=ld.get("shape") or ""
sc=clean(ld.get("shape-config") or {})
if shape.startswith("VM.Standard.A1"): sc.pop("baseline-ocpu-utilization",None)  # A1 不支持降频
sd=clean(ld.get("source-details") or {})
req={"availabilityDomain":ad,"compartmentId":comp,"displayName":name,
     "shape":shape,
     "sourceDetails":{"sourceType":"image","imageId":sd.get("image-id")},
     "metadata":clean(ld.get("metadata")) or {}}
if sc: req["shapeConfig"]=sc
if subnet: req["subnetId"]=subnet
cv=clean(ld.get("create-vnic-details"))
if cv: req["createVnicDetails"]=cv
json.dump(req,open(outpath,"w"))
' "$1" "$COMP" "$DISPLAY_NAME" "${SUBNET_OCID:-}" "$REQ_FILE"
}

# ---- 5) 逐 AD 抢 ----
while IFS= read -r ad; do
  [ -n "$ad" ] || continue
  build_req "$ad" || { log "构造请求体失败"; sleep "$SLEEP_BETWEEN"; continue; }
  if [ "${DRY_RUN:-0}" = "1" ]; then
    log "[DRY_RUN] 跳过实际请求, 请求体见 $REQ_FILE"
    exit 0
  fi
  OUT=$("$OCI" compute instance launch --from-json "file://$REQ_FILE" 2>&1)
  rc=$?
  if [ $rc -eq 0 ]; then
    INST=$(printf '%s' "$OUT" | python3 -c '
import json,sys
try: print(json.load(sys.stdin).get("id",""))
except Exception: pass')
    printf 'instance-ocid: %s\navailability-domain: %s\ntime: %s\n' \
      "$INST" "$ad" "$(date '+%F %T')" > "$DONE_MARK"
    log "✅ 抢到了! 实例 $INST @ $ad"
    notify "OCI 抢机成功 ✅ $DISPLAY_NAME @ $ad
实例: $INST"
    exit 0
  fi
  case "$OUT" in
    *"Out of host capacity"*)
      log "[$ad] 无容量，继续等待"; sleep "$SLEEP_BETWEEN" ;;
    *"TooManyRequests"*|*"429"*)
      log "[$ad] 触发限流，放慢节奏"; sleep 120 ;;
    *"LimitExceeded"*|*"QuotaExceeded"*|*"Limit Exceeded"*)
      printf 'stopped: 已达配额上限(可能已经抢到过/手动建过)\ntime: %s\n' "$(date '+%F %T')" > "$DONE_MARK"
      log "⛔ 配额上限: $OUT"
      notify "OCI 抢机停止 ⛔ 已达配额上限(检查控制台是否已有实例)
$OUT"
      exit 0 ;;
    *"NotAuthenticated"*)
      printf 'stopped: API 密钥无效或被移除\ntime: %s\n' "$(date '+%F %T')" > "$DONE_MARK"
      log "⛔ 认证失败: $OUT"
      notify "OCI 抢机停止 ⛔ API 密钥无效(检查控制台 API Keys)
$OUT"
      exit 0 ;;
    *)
      log "[$ad] 其他错误: $OUT"; sleep "$SLEEP_BETWEEN" ;;
  esac
done <<EOF
$ADS
EOF
log "本轮扫完所有 AD，未抢到，等下一轮"
