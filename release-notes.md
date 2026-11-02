# WorkBuddy Manager v2.11.9 · Android Magisk/KernelSU 模块

把 [WorkBuddy Manager](https://github.com/ithtelab/workbuddy-manager) 的账号池管理控制台和 OpenAI 兼容反代网关完整搬到 Android 手机上。

> 模块内嵌 Alpine arm64、Python 3.12、Go 1.27 与全部 Python wheel：**刷入时不需要联网**，安装完成后即可在手机本地运行。

## 亮点

- **离线安装**：rootfs、依赖 wheel、上游 Go 源码和预编译二进制都在模块 zip 内。
- **保留官方更新能力**：面板自带「检查更新 / 一键更新」；上游变更会在设备上用随包 Go 工具链编译并重启，不依赖 Docker。
- **Magisk / KernelSU 通用**：标准模块格式，arm64，Android 8.0+。
- **数据持久化**：账号、密钥、SQLite、日志保存在 `/data/adb/workbuddy-manager`，卸载默认保留。
- **默认只监听本机**：管理端 `127.0.0.1:7864`，上游 `127.0.0.1:7863`。

## 安装

1. 下载 [`WorkBuddyManager-v2.11.9-arm64.zip`](https://github.com/LiuYiGL/workbuddy-manager-magisk/releases/download/v2.11.9/WorkBuddyManager-v2.11.9-arm64.zip)
2. 在 Magisk / KernelSU 中刷入
3. 重启手机
4. 手机浏览器打开 `http://127.0.0.1:7864/`
5. 初始管理员密码见安装日志，或 `/data/adb/workbuddy-manager/webui.txt`

> 安装完成后会尝试打开公告页 `https://uplcm.com/4/12176814`；部分 ROM 会拒绝 root 启动 Activity，失败不影响安装。

## 设备要求

| 项目 | 要求 |
|---|---|
| 架构 | arm64 / aarch64 |
| 系统 | Android 8.0+ |
| Root | Magisk 或 KernelSU |
| 空间 | 建议预留 1 GB |

## 已验证

- 设备：Xiaomi MI 8（LineageOS 22 / Android 15，Magisk 30.2）
- 模块安装、重启后 `service.sh` 自动启动、管理端 `7864`、上游 `7863` 正常
- 首页、`/api/healthz`、登录接口均返回 200
- Python 依赖（fastapi、uvicorn、httpx、pydantic、uvloop、httptools、websockets、PyYAML、watchfiles、psycopg 等）在设备上全部可导入
- 上游 `/healthz` 在无账号时返回 503，属于正常状态

## 更新与网络

- 面板一键更新需要联网（GitHub / PyPI / Go 模块）。
- 上游变更会在手机上编译，通常 1–5 分钟；更新器单步超时 30 分钟。
- 国内网络可在 `.env` 配置：`WB_GITHUB_MIRROR`、`WB_UPDATE_PROXY`、`PIP_INDEX_URL`、`WB_GOPROXY`。
- 只更新面板、不重建上游可设 `WB_SYNC_UPSTREAM=0`。

## 安全

- 管理端持有全部账号凭据，请使用强密码。
- 默认只监听 `127.0.0.1`；不要在没有 HTTPS/访问控制的情况下暴露到公网。
- 局域网访问：编辑 `/data/adb/workbuddy-manager/app/.env`，把 `WB_MANAGER_HOST` 改成 `0.0.0.0`，然后重启：

  ```bash
  sh /data/adb/workbuddy-manager/bin/wbm-ctl restart
  ```

- 常用命令：

  ```bash
  sh /data/adb/workbuddy-manager/bin/wbm-ctl status
  sh /data/adb/workbuddy-manager/bin/wbm-ctl logs 300 manager
  sh /data/adb/workbuddy-manager/bin/wbm-ctl restart
  ```

## 校验

- 文件：`WorkBuddyManager-v2.11.9-arm64.zip`
- 大小：138,567,290 bytes
- sha256：`b79950c7b9b4515bb889fd09885a09a1b3ba99313afb51ec3200b86fa5bee980`
- 源码提交：`4abe1a1`

## 说明

- 上游业务代码未修改；本模块只做 Android 运行时适配。
- 使用请遵守上游 README 的使用边界与免责声明。
- 上游项目：<https://github.com/ithtelab/workbuddy-manager>
- 问题反馈：<https://github.com/LiuYiGL/workbuddy-manager-magisk/issues>

---

如果这个模块帮到了你，欢迎给仓库点一个 Star。
