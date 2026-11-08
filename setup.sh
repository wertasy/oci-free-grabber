#!/usr/bin/env bash
# setup.sh — 一键安装/卸载 OCI grabber
# 用法:
#   ./setup.sh                      安装(依赖检查→OCI CLI→API Key→配置→cron)
#   ./setup.sh --uninstall          卸载 cron 任务(保留数据)
#   ./setup.sh --interval 5         抢注间隔分钟数(默认 2)
#   ./setup.sh --report-hour 0      早报 UTC 小时(默认 0 = 北京 8:00)
#   ./setup.sh --no-report          不注册每日早报
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
RUNTIME_DIR="${GRAB_RUNTIME_DIR:-$HOME/oci-grab}"
VENV_DIR="${OCI_VENV_DIR:-$HOME/.oci-venv}"
INTERVAL=2
REPORT_HOUR=0
ENABLE_REPORT=1

while [ $# -gt 0 ]; do
  case "$1" in
    --uninstall) UNINSTALL=1 ;;
    --interval) INTERVAL="$2"; shift ;;
    --report-hour) REPORT_HOUR="$2"; shift ;;
    --no-report) ENABLE_REPORT=0 ;;
    *) echo "未知参数: $1"; exit 1 ;;
  esac
  shift
done

CRON_GRAB="*/${INTERVAL} * * * * ${PROJECT_DIR}/bin/grab.sh >> ${RUNTIME_DIR}/cron.log 2>&1"
CRON_REPORT="0 ${REPORT_HOUR} * * * ${PROJECT_DIR}/tools/daily-report.sh >> ${RUNTIME_DIR}/cron.log 2>&1"

remove_cron_lines() {
  crontab -l 2>/dev/null | grep -vF "${RUNTIME_DIR}/grab.sh" | grep -vF "daily-report.sh" | { cat; } | crontab -
}

if [ "${UNINSTALL:-0}" = "1" ]; then
  remove_cron_lines
  echo "✔ 已移除 cron 任务(运行数据保留在 ${RUNTIME_DIR}, 如需彻底删除请手动 rm -rf)"
  exit 0
fi

echo "== 1/5 依赖检查 =="
MISSING=()
for cmd in python3 curl openssl flock; do command -v $cmd >/dev/null || MISSING+=($cmd); done
python3 -c "import venv" 2>/dev/null || MISSING+=("python3-venv")
if [ ${#MISSING[@]} -gt 0 ]; then
  echo "缺少: ${MISSING[*]}"
  if command -v apt-get >/dev/null && [ "$(id -u)" = "0" -o "$(command -v sudo)" ]; then
    sudo apt-get install -y python3-venv curl openssl cron util-linux
  else
    echo "请手动安装后重试"; exit 1
  fi
fi
command -v crontab >/dev/null || { echo "缺少 crontab (apt install cron)"; exit 1; }
systemctl is-active --quiet cron 2>/dev/null || sudo systemctl enable --now cron 2>/dev/null || true

echo "== 2/5 安装 OCI CLI (venv: ${VENV_DIR}) =="
if [ -x "${VENV_DIR}/bin/oci" ]; then
  echo "已安装, 跳过"
else
  python3 -m venv "$VENV_DIR"
  "${VENV_DIR}/bin/pip" install -q --upgrade pip
  "${VENV_DIR}/bin/pip" -q install oci-cli
fi

echo "== 3/5 生成 API Key =="
mkdir -p "$HOME/.oci" "$RUNTIME_DIR"
chmod 700 "$HOME/.oci"
if [ -f "$HOME/.oci/oci_api_key.pem" ]; then
  echo "密钥已存在, 跳过生成"
else
  openssl genrsa -out "$HOME/.oci/oci_api_key.pem" 2048
  openssl rsa -pubout -in "$HOME/.oci/oci_api_key.pem" -out "$HOME/.oci/oci_api_key_public.pem"
  chmod 600 "$HOME/.oci/oci_api_key.pem" "$HOME/.oci/oci_api_key_public.pem"
fi
FP=$(openssl rsa -in "$HOME/.oci/oci_api_key.pem" -pubout -outform DER | openssl md5 | awk '{print $2}')
if ! grep -q '^fingerprint=' "$HOME/.oci/config" 2>/dev/null; then
  cat > "$HOME/.oci/config" <<EOF2
[DEFAULT]
user=REPLACE_ME_USER_OCID
fingerprint=${FP}
tenancy=REPLACE_ME_TENANCY_OCID
region=REPLACE_ME_REGION
key_file=${HOME}/.oci/oci_api_key.pem
EOF2
  chmod 600 "$HOME/.oci/config"
fi
echo "──────────────────────────────────────────────"
echo "① 控制台 → 头像 → 我的个人资料 → API 密钥 → 添加 API 密钥 → 粘贴公钥:"
echo "   $(cat "$HOME/.oci/oci_api_key_public.pem" | tr -d '\n')"
echo "   指纹应为: $(echo "$FP" | sed 's/../&:/g;s/:$//')"
echo "② 三个值填入 ${RUNTIME_DIR}/grab.conf:"
echo "   user OCID(个人资料页顶部) / tenancy OCID(同页 Tenancy 链接) / region(控制台右上角)"
echo "──────────────────────────────────────────────"

echo "== 4/5 配置文件 =="
if [ -f "${RUNTIME_DIR}/grab.conf" ]; then
  echo "已存在 ${RUNTIME_DIR}/grab.conf, 保留不动"
else
  cp "${PROJECT_DIR}/conf/grab.conf.example" "${RUNTIME_DIR}/grab.conf"
  chmod 600 "${RUNTIME_DIR}/grab.conf"
  echo "已生成 ${RUNTIME_DIR}/grab.conf, 请填写必填项(含通知渠道)"
fi

echo "== 5/5 注册 cron =="
remove_cron_lines
{ crontab -l 2>/dev/null; echo "$CRON_GRAB"; } | crontab -
if [ "$ENABLE_REPORT" = "1" ]; then
  { crontab -l 2>/dev/null; echo "$CRON_REPORT"; } | crontab -
fi
crontab -l
echo "✔ 安装完成。填好 grab.conf 后任务自动开始工作; 抢到后通过所配渠道推送通知。"
