# xray-oneclick

一键生成并部署 Xray `VLESS Reality (N 入站) -> SOCKS (N 出站)` 的工具。

## 功能

- 直接粘贴多行 `host:port:user:pass`
- 自动生成 N 组 1:1 映射（入站与出站不串线）
- 自动生成 `UUID`、`shortId`、Reality key
- 自动校验配置并部署
- 自动输出 `v2rayN` / `Shadowrocket` 链接到终端
- 自动探测公网 IP
- 缺少 xray 时自动安装（优先本地 zip）

## 本机直接运行

```bash
./start_xray_oneclick.sh
```

粘贴 socks 列表后，用以下任意方式结束输入：

- 输入 `end` / `END` / `结束`
- 连续按两次回车
- `Ctrl+D`

## 新机器一键安装

先把本仓库推到 GitHub，然后执行：

```bash
curl -fsSL https://raw.githubusercontent.com/<你的用户名>/<你的仓库名>/main/install.sh | bash -s -- <你的用户名>/<你的仓库名>
```

安装后执行：

```bash
xray-oneclick
```

卸载并全部清除：

```bash
xray-oneclick --uninstall
# 或
xray-oneclick-uninstall
```

## 环境变量

- `PUBLIC_HOST`：公网 IP 或域名（不填则自动探测）
- `XRAY_BIN`：xray 可执行文件路径
- `DEPLOY_TARGET`：配置部署路径（默认 `/usr/local/etc/xray/config.json`）
- `RELOAD_CMD`：重载命令（默认 `systemctl reload xray`）
- `START_PORT`：入站起始端口（默认 `20000`）
- `AUTO_INSTALL_XRAY`：缺少 xray 时自动安装（默认 `1`）
- `XRAY_INSTALL_PATH`：自动安装目标（默认 `/root/xray`）
- `XRAY_LOCAL_ZIP`：本地 xray zip 路径（默认 `/root/Xray-linux-64.zip`）
