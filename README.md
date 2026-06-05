# xray-oneclick

一键生成并部署 Xray `VLESS Reality (N 入站) -> SOCKS (N 出站)` 的工具。

## 功能

- 直接粘贴多行 `host:port:user:pass`
- 自动生成 N 组 1:1 映射（入站与出站不串线）
- 自动生成 `UUID`、`shortId`、Reality key
- 自动校验配置并部署
- 自动输出一份通用 `vless://` 节点链接到终端
- 二维码压缩包内自动包含 `links.txt`（全部节点链接）
- 自动探测公网 IP
- 缺少 xray 时自动安装（优先本地 zip）

## 国家检测更准的方式

默认会先探测每个 SOCKS 的出口 IP，再用在线 Geo API 查询国家。节点很多时，在线 API 容易超时、限流或返回空值，所以会出现 `Unknown`。

更准、更稳定的方式是使用本地 MMDB 国家库：

```bash
python3 -m pip install maxminddb
COUNTRY_MMDB=/path/to/GeoLite2-Country.mmdb ./start_xray_oneclick.sh
```

也可以把 `GeoLite2-Country.mmdb` 或 `Country.mmdb` 放到项目目录、`/usr/share/GeoIP/`、`/usr/local/share/GeoIP/`、`/var/lib/GeoIP/` 或 `/opt/xray-oneclick/`，脚本会自动发现。

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

## GitHub 认证与推送（其他机器）

如果你要在其他机器 `git push` 到本仓库，需要先完成认证。推荐顺序如下：

1. `SSH`（推荐，长期免输密码）
2. `GitHub CLI 设备码登录`（你提到的 `https://github.com/login/device/select_account`）
3. `HTTPS + PAT`

### 方式1：SSH（推荐）

```bash
ssh-keygen -t ed25519 -C "your_email@example.com"
cat ~/.ssh/id_ed25519.pub
```

把公钥复制到 GitHub：
`Settings -> SSH and GPG keys -> New SSH key`

然后测试并切换仓库远程地址：

```bash
ssh -T git@github.com
cd /root/xray-oneclick
git remote set-url origin git@github.com:wellwellwelldonenow-spec/-vless-socks-.git
git push
```

### 方式2：GitHub CLI 设备码登录（无需手动输入 PAT）

先安装并登录：

```bash
gh auth login
```

按提示选择：
- `GitHub.com`
- `HTTPS`
- `Login with a web browser`

终端会给出一次性设备码，并引导你打开：
- `https://github.com/login/device`
- 或 `https://github.com/login/device/select_account`

完成授权后可验证：

```bash
gh auth status
cd /root/xray-oneclick
git push
```

### 方式3：HTTPS + PAT

把仓库 remote 设为 HTTPS：

```bash
cd /root/xray-oneclick
git remote set-url origin https://github.com/wellwellwelldonenow-spec/-vless-socks-.git
git push
```

推送时输入：
- Username: GitHub 用户名
- Password: PAT（不是 GitHub 登录密码）

卸载并全部清除：

```bash
xray-oneclick --uninstall
# 或
xray-oneclick-uninstall
```

## 环境变量

- `PUBLIC_HOST`：公网 IP 或域名（不填则自动探测）
- `COUNTRY_MMDB`：本地 MMDB 国家库路径（更准且避免在线 API 限流）
- `XRAY_BIN`：xray 可执行文件路径
- `DEPLOY_TARGET`：配置部署路径（默认 `/usr/local/etc/xray/config.json`）
- `RELOAD_CMD`：重载命令（默认 `systemctl reload xray`）
- `START_PORT`：入站起始端口（默认 `20000`）
- `AUTO_INSTALL_XRAY`：缺少 xray 时自动安装（默认 `1`）
- `XRAY_INSTALL_PATH`：自动安装目标（默认 `/root/xray`）
- `XRAY_LOCAL_ZIP`：本地 xray zip 路径（默认 `/root/Xray-linux-64.zip`）
