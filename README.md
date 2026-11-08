# oci-free-grabber

OCI（Oracle Cloud）Always Free 实例自动抢注工具。针对创建免费实例时常见的
`500 InternalError — Out of host capacity` 错误，用 cron 驱动的循环自动重试，
抢到后通过 Telegram / ntfy / Bark / Server酱 / Webhook 推送通知。

## 工作原理

```
cron(每2分钟) → grab.sh
                 ├─ 从你的「实例配置」读取 形状/镜像/SSH公钥/VNIC 设置
                 ├─ 构造完整 LaunchInstance 请求体(--from-json)
                 ├─ 逐可用域尝试启动
                 │    ├─ Out of host capacity → 等待下一轮
                 │    ├─ 429 限流 → 自动放慢
                 │    ├─ 配额/密钥错误 → 推送并停止
                 │    └─ 成功 → 写 DONE + 推送通知 + 自停(防重复建机)
                 └─ 通知失败自动重试(pending 文件机制)
```

## 特性

- **基于实例配置**：完全复用你在控制台保存的配置（形状、镜像、SSH 公钥、网络）
- **多可用域轮询**：每轮自动扫区域内全部 AD
- **通知可配置**：Telegram / ntfy / Bark / Server酱 / 通用 Webhook / 关闭
- **通知可靠**：pending 文件 + 每轮自动重投，网络抖动不丢通知
- **每日早报**（可选）：固定时间推送前一天战况统计
- **防重复下单**：flock 并发锁 + 抢到即自停
- **防限流**：随机抖动 + 错误分类退避
- **DRY_RUN**：只构造请求不真正发起，调试安全

## 快速开始

### 0. 前置要求

- 一台持续在线的 Linux 机器（VPS/NAS/家里服务器均可）+ sudo 权限
- python3（≥3.9，含 venv）、curl、openssl、cron、flock
- OCI 账号（免费试用或 Always Free 均可）

### 1. 安装

```bash
git clone https://github.com/<you>/oci-free-grabber.git
cd oci-free-grabber
./setup.sh                # 默认: 抢注间隔 2 分钟, 早报北京 8:00
```

`setup.sh` 会自动：装 OCI CLI（独立 venv）、生成 API 密钥对、生成配置文件、注册 cron。

### 2. 准备 API Key（控制台操作）

setup.sh 会打印你的**公钥**和**指纹**，照做：

1. OCI 控制台右上角头像 → **我的个人资料 / User Settings** → **API 密钥** → **添加 API 密钥** → 选「粘贴公钥」，粘贴 setup.sh 打印的公钥
2. 核对控制台显示的指纹与 setup.sh 打印的一致
3. 从控制台收集三个值：**user OCID**（个人资料页顶部）、**tenancy OCID**（同页 Tenancy 链接）、**region**（控制台右上角，如 `ap-tokyo-1`）

### 3. 填配置

编辑 `~/oci-grab/grab.conf`：

```ini
OCI_USER_OCID=ocid1.user.oc1...
OCI_TENANCY_OCID=ocid1.tenancy.oc1...
OCI_REGION=ap-tokyo-1
INSTANCE_CONFIG_NAME=your-config-name    # 控制台「保存为实例配置」的名字
NOTIFY_CHANNEL=telegram
TELEGRAM_BOT_TOKEN=123456:ABC-xxx        # @BotFather 创建
TELEGRAM_CHAT_ID=123456789               # 向 @userinfobot 转发任意消息可查
```

### 4. 测试与验证

```bash
~/oci-free-grabber/tools/test-notify.sh   # 测试通知渠道
~/oci-free-grabber/tools/daily-report.sh  # 手动发一份战况报告
GRAB_RUNTIME_DIR=~/oci-grab DRY_RUN=1 ~/oci-free-grabber/bin/grab.sh  # 只构造请求不发起
tail -f ~/oci-grab/grab.log               # 观察抢注过程
```

填好配置后 cron 任务即自动开始工作，无需其他操作。

## 配置参考

| 变量 | 必填 | 说明 |
|---|---|---|
| `OCI_USER_OCID` / `OCI_TENANCY_OCID` / `OCI_REGION` | ✅ | 控制台获取 |
| `COMPARTMENT_OCID` | | 留空 = 根隔间 |
| `SUBNET_OCID` | | 留空 = 自动选第一个公共子网 |
| `INSTANCE_CONFIG_NAME` | ✅ | 控制台保存的实例配置名 |
| `DISPLAY_NAME` | | 抢到后实例显示名 |
| `NOTIFY_CHANNEL` | | telegram / ntfy / bark / serverchan / webhook / none |
| `TELEGRAM_BOT_TOKEN` / `TELEGRAM_CHAT_ID` | telegram 渠道 | @BotFather + @userinfobot |
| `NTFY_TOPIC_URL` / `NTFY_TOKEN` | ntfy 渠道 | 如 `https://ntfy.sh/你的随机主题` |
| `BARK_URL` | bark 渠道 | iOS Bark 推送 URL |
| `SERVERCHAN_SENDKEY` | serverchan 渠道 | Server酱 SendKey（微信） |
| `WEBHOOK_URL` | webhook 渠道 | POST `{"text":"..."}` |
| `SLEEP_BETWEEN` / `JITTER` | | 同轮 AD 间隔 / 启动随机抖动（秒） |
| `DRY_RUN` | | `1` = 只构造请求不发起 |
| `REPORT_TZ` | | 早报时区，默认 `CST-8`（UTC+8） |

## setup.sh 选项

```bash
./setup.sh --interval 5        # 抢注间隔改为 5 分钟(默认 2)
./setup.sh --no-report         # 不注册每日早报
./setup.sh --report-hour 16    # 早报 UTC 时间改为 16 点
./setup.sh --uninstall         # 移除 cron 任务(数据保留)
```

## 常见问题（实战踩坑）

**Q: `Must specify --source-details or --image-id`**
仅凭 `--instance-configuration-id` 启动会被 CLI 客户端拒绝。本工具的做法是读取配置内容后
构造完整请求体（`--from-json`）显式提交。

**Q: `404 NotAuthorizedOrNotFound`，但所有资源都真实存在**
两个已知诱因，工具均已内置规避：
1. 保存的实例配置里 shape-config 带 `baseline-ocpu-utilization: BASELINE_1_1` ——
   A1(Ampere) 不支持 baseline 降频，服务端直接 404；
2. 「配置 ID + 覆盖字段」的混合请求会被服务端拒绝 —— 改为纯显式字段。

**Q: `429 TooManyRequests`**
连续高频尝试触发的用户级限流，工具自动放慢（同轮间隔 120 秒），下一轮自愈。

**Q: 一直 `Out of host capacity`？**
这就是抢注的意义 —— 免费 A1 容量紧俏（热门区可能蹲数天到数周）。本工具持续自动重试，
抢到即推送并自停。

**Q: 会不会重复创建实例、产生费用？**
不会。抢到即写 `DONE` 标记并停止工作；进程间有 flock 并发锁；Always Free 用量内不产生费用。

**Q: 通知会丢吗？**
通知先写入 pending 文件再投递，失败则每轮自动重投，机器在线就不会丢。

## 安全

- API 私钥保存在本机 `~/.oci/`（权限 600），仅签名 API 请求使用
- `grab.conf` 含 bot token 等敏感信息，权限 600 且已被 `.gitignore` 排除
- 仓库内只有模板文件，无任何真实凭据

## 卸载

```bash
./setup.sh --uninstall       # 移除 cron
rm -rf ~/oci-grab ~/.oci-venv ~/.oci   # 彻底清理(含 API 私钥, 慎用)
```

## License

MIT
