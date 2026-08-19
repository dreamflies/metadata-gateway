# 元数据网关

供桌面端影视库使用的统一元数据网关。使用预构建镜像部署，**不需要下载源码，也不需要安装 Go 或任何编译工具**。

镜像：`ghcr.io/dreamflies/metadata-gateway`，提供 `linux/amd64` 和 `linux/arm64`，Intel/AMD 机器与 Apple Silicon、树莓派都能直接运行。

---

## 快速开始

### 1. 安装 Docker Desktop

下载 [Docker Desktop](https://www.docker.com/products/docker-desktop/) 并安装，**安装后必须先启动它**，后续命令都依赖它在后台运行。

- **Windows**：安装时保持勾选 `Use WSL 2 instead of Hyper-V`（默认已勾选），装完需重启电脑。
- **macOS**：按芯片选择版本——Apple 芯片（M 系列）选 Apple Silicon，Intel 机型选 Intel Chip。

验证安装（Windows 用 PowerShell，macOS 用终端）：

```bash
docker compose version
```

输出类似 `Docker Compose version v2.x.x` 即正常。

### 2. 下载配置文件

新建一个目录存放配置。**这个目录之后会保存刮削数据库，请放在不会误删的位置。**

<details open>
<summary><b>Windows（PowerShell）</b></summary>

```powershell
cd $HOME
mkdir metadata-gateway
cd metadata-gateway

curl.exe -O https://raw.githubusercontent.com/dreamflies/metadata-gateway/main/compose.release.yaml
curl.exe -O https://raw.githubusercontent.com/dreamflies/metadata-gateway/main/.env.example
curl.exe -O https://raw.githubusercontent.com/dreamflies/metadata-gateway/main/init.ps1

Rename-Item compose.release.yaml compose.yaml
Copy-Item .env.example .env
```

> 必须写 `curl.exe` 而不是 `curl`——PowerShell 里 `curl` 是另一个命令的别名，参数不通用。

</details>

<details open>
<summary><b>macOS（终端）</b></summary>

```bash
mkdir -p ~/metadata-gateway
cd ~/metadata-gateway

curl -O https://raw.githubusercontent.com/dreamflies/metadata-gateway/main/compose.release.yaml
curl -O https://raw.githubusercontent.com/dreamflies/metadata-gateway/main/.env.example
curl -O https://raw.githubusercontent.com/dreamflies/metadata-gateway/main/init.sh

mv compose.release.yaml compose.yaml
cp .env.example .env
chmod +x init.sh
```

</details>

### 3. 一键初始化

脚本会自动完成全部步骤：生成随机访问令牌、启动 Javinizer 并等待就绪、创建管理员账号、生成 API Token 写入配置、最后拉起全部服务。

**Windows：**

```powershell
.\init.ps1
```

若提示「禁止运行脚本」，改用（仅本次生效，不改系统设置）：

```powershell
powershell -ExecutionPolicy Bypass -File .\init.ps1
```

**macOS：**

```bash
./init.sh
```

首次运行需下载镜像，约 1–5 分钟。看到下面这行即成功：

```
==> 完成。网关地址 http://127.0.0.1:11503，GATEWAY_TOKEN 见 .env
```

> 脚本是**幂等**的。中途失败时修复问题后直接重新运行即可，已完成的步骤会自动跳过，不会重复创建账号或令牌。

自行指定管理员密码（可选，默认随机生成）：

```bash
# macOS
JAVINIZER_ADMIN_USER=admin JAVINIZER_ADMIN_PASSWORD=你的密码 ./init.sh
```

```powershell
# Windows
.\init.ps1 -AdminUser admin -AdminPassword '你的密码'
```

> Windows 上自定义密码请避免使用单引号 `'` 和反斜杠 `\`，脚本检测到会直接报错退出。

### 4. 连接桌面端

在桌面端打开 **设置 → 影视刮削 → 元数据网关**，展开后填写：

| 字段 | 填写内容 |
| --- | --- |
| **服务地址** | `http://127.0.0.1:11503` |
| **访问令牌** | `.env` 里 `GATEWAY_TOKEN=` 后面那串字符 |

点**保存**，右上角状态变成**「已连接」**即成功。

---

## 配置说明

初始化脚本会在 `.env` 中自动填好这些值：

| 变量 | 说明 |
| --- | --- |
| `GATEWAY_TOKEN` | 桌面端连接网关用的访问令牌，随机生成 |
| `JAVINIZER_TOKEN` | 网关调用 Javinizer 的内部令牌，自动生成，无需关心 |
| `JAVINIZER_ADMIN_PASSWORD` | Javinizer 管理后台密码，登录 <http://127.0.0.1:8765> 时使用 |

> ⚠️ `.env` 中全是凭据，**请勿分享、勿提交到任何代码仓库**。

可选变量：

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `GATEWAY_IMAGE` | `ghcr.io/dreamflies/metadata-gateway` | 改成自建镜像时使用 |
| `GATEWAY_TAG` | `latest` | 固定版本，例如 `v0.5.8` |
| `JAVINIZER_HOST_PORT` | `8765` | Javinizer 端口冲突时修改 |

### 启用欧美影片刮削（可选）

日本影片初始化后即可用。欧美影片需要额外的 StashDB 密钥——**这一步无法自动化**，因为注册需要邀请码。不看欧美片可跳过。

1. 打开 [StashDB](https://stashdb.org/) 注册登录。邀请码可从[官方接入指南](https://guidelines.stashdb.org/docs/faq_getting-started/stashdb/accessing-stashdb/)获取。
2. 点右上角用户名进入个人页面，复制 **API Key**。
3. 填入 `.env`：

```dotenv
STASH_BOX_API_KEY=粘贴你的密钥
```

4. 生效：`docker compose up -d`

### 使用代理

刮削需访问境外站点。容器**不会自动继承**系统代理，需显式配置。

先在 Clash 中开启 **Allow LAN**，确认 Mixed/HTTP 端口（常见为 `7897`），然后去掉 `.env` 中这三行的注释：

```dotenv
HTTP_PROXY=http://host.docker.internal:7897
HTTPS_PROXY=http://host.docker.internal:7897
NO_PROXY=localhost,127.0.0.1,javinizer,host.docker.internal
```

> `NO_PROXY` 这行**不能省**。它保证容器间的内部通信不走代理，漏掉会导致网关连不上 Javinizer，搜索报 `502`。

改完执行 `docker compose up -d` 生效。

Javinizer **自身的代理需单独配置**：登录 <http://127.0.0.1:8765>，在代理设置中新建 Clash 配置，再为需要的数据源启用。

---

## 日常操作

所有命令都需**先进入安装目录**再执行。

| 操作 | 命令 |
| --- | --- |
| 启动（改完配置也用这条生效） | `docker compose up -d` |
| 停止（数据保留） | `docker compose down` |
| 查看状态 | `docker compose ps` |
| 查看日志 | `docker compose logs -f` |
| 更新到最新版本 | `docker compose pull && docker compose up -d` |

容器配置了 `restart: unless-stopped`，只要 Docker Desktop 开机自启，网关就会自动恢复运行。

---

## 故障排查

### 端口被占用

报错含 `port is already allocated`。修改 `.env` 中的 Javinizer 端口：

```dotenv
JAVINIZER_HOST_PORT=18765
```

网关端口则改 `compose.yaml` 里 `"127.0.0.1:11503:11503"` **冒号左边**的数字，桌面端服务地址需同步修改。

### 桌面端一直显示「未检测」

- 确认 `docker compose ps` 中两个容器都是 `Up`
- 确认服务地址是 `http://127.0.0.1:11503`，无多余斜杠或空格
- 确认访问令牌与 `.env` 中 `GATEWAY_TOKEN` 完全一致（复制时容易漏字符或带空格）

也可以直接验证网关健康状态（把 `你的令牌` 换成实际值）：

```bash
curl -H "Authorization: Bearer 你的令牌" http://127.0.0.1:11503/v1/health
```

正常返回：

```json
{"ok":true,"providers":{"jav":true,"western":false}}
```

`western` 为 `false` 表示未配置 StashDB 密钥，不影响日本影片刮削。

### 搜索报 502

网关连不上 Javinizer。最常见原因是代理配置漏了 `NO_PROXY`（见上文）。其次检查 `docker compose ps` 中 javinizer 是否为 `(healthy)`——显示 `starting` 请再等半分钟，`unhealthy` 则用 `docker compose logs javinizer` 查看原因。

### 刮削结果为空

先确认 `/v1/health` 返回的 `jav` 为 `true`。若为 `true` 仍搜不到，通常是境外站点访问不通，参见「使用代理」。

### 彻底重来

清空所有数据从头开始（**不可恢复**）：

```powershell
# Windows
docker compose down
Remove-Item -Recurse -Force javinizer-data
Remove-Item .env
```

```bash
# macOS
docker compose down
rm -rf javinizer-data .env
```

然后从「下载配置文件」的复制 `.env` 步骤重新开始。

---

## 接口

```http
GET /v1/health
Authorization: Bearer <GATEWAY_TOKEN>
```

```http
POST /v1/search
Authorization: Bearer <GATEWAY_TOKEN>
Content-Type: application/json

{"profile":"jav","query":"IPX-535","code":"IPX-535"}
```

响应为 `{"candidates":[...]}`。匹配置信度低于 `0.90` 的候选不会自动入库，交由桌面端人工确认。

---

## 安全说明

网关只监听 `127.0.0.1`，不对局域网或公网开放。`.env` 中包含访问令牌与管理员密码，请勿分享或提交到代码仓库。
