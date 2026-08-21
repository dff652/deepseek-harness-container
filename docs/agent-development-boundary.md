# DSH Agent 开发与容器边界

## 目的与结论

本文定义容器化 DSH 部署中 Agent 的执行、文件、网络、凭据和构建权限。
它适用于生产运行时和受控开发运行时，不把容器当作可以随意绕过的障碍。

核心结论：Agent 默认在 DSH 容器内执行。需要访问宿主机、内网服务或构建
制品时，应授予一个可审计、可撤销、最小范围的能力，而不是让 Agent 直接
“穿透”到宿主机。

DSH Web 只监听容器内 `127.0.0.1:3080`。Caddy 与 DSH 共享网络命名空间，
Caddy 是唯一的 LAN 入口，只发布经过认证的 HTTPS 端口。DSH 的 3080 不发布
到宿主机或 LAN。

这是当前 rc.1 候选的部署边界，不代表 DeepSeek 官方提供了容器镜像。DSH、
Node、pnpm、Caddy、基础镜像、插件和 provider 必须由部署项目分别固定版本、
digest、架构和验收证据。

## 运行拓扑

```text
受管浏览器
    |
    | LAN_IP:443 / HTTPS / Caddy auth
    v
宿主 Docker published port
    |
    +-- Caddy sidecar
    |      `-- reverse_proxy 127.0.0.1:3080
    |
    `-- DSH container
           |-- dsh web -> 127.0.0.1:3080
           |-- DSH_HOME named volume
           |-- /workspace approved bind mount
           `-- approved model/MCP/database endpoints
```

Compose 使用 `network_mode: service:dsh` 让 Caddy 进入 DSH 的网络命名空间。
宿主机的端口映射属于 `dsh` 服务，因为共享网络命名空间的 `caddy` 服务
不能再单独声明网络和端口。

Caddy 到 DSH 的上游连接应保持在 loopback。Caddy 必须先校验外部 `Host` 是
批准的 IP authority、拒绝 `Sec-Fetch-Site: cross-site`，并要求存在的
`Origin` 与外部 HTTPS authority 同源；Basic Auth 不能替代 DNS-rebinding 或
CSRF 防线。只有外部请求信任检查通过后，loopback adapter 才能把上游 `Host`
对齐到 `127.0.0.1:3080` 并移除已经验证的外部标记。不能先全局删除
`Origin`/`Sec-Fetch-Site` 再把所有请求伪装成 loopback。确需保留原始同源头
的插件端点应使用单独审查的路由和负例测试。Caddy 配置错误或 443 误发布时，
还必须有宿主防火墙和容器端口检查阻止直接访问 3080。

## 两种运行时

### Production runtime

生产镜像只包含固定的 DSH 运行闭包和生产确实需要的系统工具：

- Node、pnpm、DSH、插件和 provider 均来自锁定的版本与 digest；
- 原生依赖按目标架构构建并经过真实 ARM64 smoke test；
- 固定非 root UID/GID 运行；
- 根文件系统只读，`/tmp` 使用受限的临时文件系统；
- DSH_HOME、Caddy data/config 和工作区分别挂载；
- 不在镜像内写入模型密钥、Basic Auth 密码、provider home、SSH 私钥或
  客户端 CA 私钥；
- 不在运行镜像中放置编译缓存、Git checkout 或调试工具，除非它们是已审查
  的 Agent 能力。

生产镜像不应在启动时解析新的 npm 版本，也不应执行无约束的 `npx`。生产
启动必须能够在 registry 不可达时使用 `--no-build --pull never` 完成。

### Dev runtime

开发运行时可以增加编译器、调试器、测试工具和受控源代码挂载，但必须是
单独的镜像或 Compose profile：

- dev 镜像不得被生产 Compose 默认引用；
- dev workspace 可以读写，生产 workspace 必须按项目和变更单显式挂载；
- dev 镜像和 profile 仍固定 DSH/Node/插件版本；
- 从 dev 生成的 provider 或插件进入 production 前，必须重新打包、扫描、
  锁定 digest 并在干净 runtime 中安装验收；
- 不因为“开发方便”打开 host network、privileged、Docker socket 或宿主
  根目录挂载。

开发镜像的编译工具链不是生产权限的替代品。需要管理宿主 Docker 或发布
制品时，使用后文的受控 runner。

## 文件与工作区边界

### `/workspace` 是唯一默认的 Agent 项目边界

只把一个经批准的项目目录 bind mount 到容器 `/workspace`。挂载点、宿主
读写模式和项目用途由部署配置提供；本候选镜像的 DSH UID/GID 固定为
`10001:10001`，宿主仅对批准的工作区匹配该所有权。

验收必须证明：

1. Agent 可以在 `/workspace` 创建、修改和删除被批准的测试文件；
2. 工作区之外的相邻宿主目录没有写入；
3. 生产不需要写入时，使用只读挂载；
4. 不在运行时使用 root 修复宿主权限；部署前让工作区所有权匹配固定的
   `10001:10001`。

下列挂载一律禁止：

- 宿主 `/`、宿主 `/home` 或整个用户目录；
- Docker 数据目录、Docker socket 和 containerd socket；
- 包含其他项目、凭据或 Agent home 的父目录；
- 未审查的通用 `/tmp` 或可被多个不互信用户共享的工作区。

DSH_HOME 保存 profile、设置、凭据引用、会话和存储，应使用独立的持久卷，
不能和 `/workspace` 合并。Caddy 的 `/data`（包括本地 CA）和 `/config` 也
必须使用独立卷；只可向客户端导出根证书，不得导出 Caddy CA 私钥。

## 模型、MCP 与数据库网络

### 模型 API

离线环境的模型必须是内网可达的模型网关或推理服务。DSH 容器通过稳定的
内网 DNS/服务名或经过防火墙许可的固定 endpoint 访问它，不依赖公网 registry、
公共模型 API 或 DNS 临时解析。

模型 endpoint 必须满足：

- 使用 HTTPS 或受控的内网传输；
- API key 通过 DSH 凭据存储或 Compose secret 注入，不写镜像、Compose 和日志；
- 服务端只允许来自容器宿主或专用网络的连接；
- 模型、协议、超时和重试均为部署配置，不由 Agent 任意修改到外部地址。

### MCP provider

DSH 的 MCP 客户端通常按 provider 的 transport 启动或连接服务，不能假定
一个容器可以直接执行另一个容器中的二进制。

| provider 形态 | 正确边界 |
|---|---|
| stdio provider | 可执行文件和依赖必须在 DSH 镜像或只读制品卷内；profile 使用绝对路径和固定身份/home；启动参数采用 argv，不拼接 shell 字符串 |
| HTTP/SSE 或其他受支持的远端 adapter | provider 在独立容器或内网主机运行；DSH 通过认证 endpoint 连接；服务名、端口、证书和 token 均固定并可撤销 |
| 另一容器中的 stdio 二进制 | 不能直接写对方容器路径；应改为受支持的网络 adapter，或在经过审查的 DSH 镜像中打包一个固定版本的 provider/bridge |
| 主机上的 provider | 不直接依赖宿主绝对路径；迁移为镜像内 provider 或认证的内网服务 |

Provider 的 home、工作区、非人类身份和 token 属于 provider 部署，不应共享
DSH_HOME 或多个不互信用户的 volume。每个 Agent Mail 类 provider 使用独立的
非人类身份，不使用人类身份或通用系统账号。

### 数据库和其他内网服务

数据库、对象存储、工单或消息服务应采用服务级账号、最小权限和网络 allowlist。
Agent 只拿到完成当前项目所需的 schema/操作权限。连接失败、重连、超时和
凭据撤销都必须有可观察日志，但日志不能打印 token、密码、完整请求体或会话
内容。

Compose bridge 默认提供出站能力，但这不是网络策略。生产应在宿主防火墙、
网关或专用网络层限制目标集合；若环境绝对断网，可使用 `internal` 网络和同网
模型/provider 服务，或通过已审查的单向 egress proxy 提供极少数必要出口。

不要给通用 Web 工具开放任意 URL 作为“解决联网”的办法。能访问内网敏感地址
的 Web fetch 是 SSRF 能力，应关闭或经过目标 allowlist、DNS 解析和出站审计。

## `host.docker.internal` / host-gateway 例外

优先把依赖服务放入受控 Compose 网络或内网服务。只有某个服务暂时无法迁移、
且确实只运行在 Docker 宿主机上时，才允许使用 Linux 的 host-gateway 例外：

1. Compose 只为该 endpoint 添加 `host.docker.internal:host-gateway`；
2. DSH 只使用一个明确的宿主服务端口，不能扫描或访问宿主任意端口；
3. 宿主服务绑定受控地址并启用自己的认证和防火墙规则；
4. 记录该例外的 owner、用途、到期时间和回滚方式；
5. 验收拒绝未列入 allowlist 的宿主端口和文件能力。

host-gateway 只是路由，不提供认证，也不等于安全边界。不能以此替代
`network_mode: host`；不能通过 host-gateway 访问宿主 Docker API、systemd、
文件系统或管理面。

## GPU、串口和其他设备

设备访问是单独的高风险能力。默认不传递任何设备；需要时：

- 只声明精确的 `devices` 或 GPU runtime 资源；
- 使用与容器 UID/GID 兼容的设备权限和 cgroup 限制；
- 不使用 `privileged: true`、`SYS_ADMIN`、`NET_ADMIN` 或全量 GPU/USB 访问；
- 在真实 ARM64 目标机验证驱动、设备节点、资源上限和失败回收；
- 记录设备用途、owner、镜像版本和撤销操作。

设备通过容器后，Agent 可能影响宿主硬件或其他进程；因此设备能力不能因
“模型调用失败”临时扩大，也不能作为调试时默认开启的选项。

## Git 与凭据

Git 访问使用项目级、短期、最小权限凭据：

- 首选只读 HTTPS token 或部署专用 token，通过 Compose secret 或受控 secret
  文件注入；
- 必须使用 SSH 时，提供单独的项目 key 和固定 `known_hosts`，只挂载到
  `/run/secrets` 或等价只读路径；
- 不挂载整个宿主 `.ssh`、云凭据目录、密码管理器目录或 Agent 的主目录；
- 凭据不写入镜像层、Git remote URL、shell history、调试日志或 Agent 输出；
- 生产发布、推送和删除操作仍需独立审批，不能因为容器拥有 Git token 就自动
  获得发布权限。

只读 token 适合代码检出和依赖读取；需要 push 的场景使用单独的写入凭据、
短时有效期、分支/仓库 allowlist 和服务端审计。凭据失效后应能只替换 secret
或 provider，而不重建整个 runtime image。

## 构建与宿主操作

### Docker/OCI 构建

禁止将 `/var/run/docker.sock`、containerd socket 或宿主 Docker API 直接暴露
给 DSH。持有 Docker socket 的 Agent 可以创建特权容器、挂载宿主根目录，实际
等同宿主高权限。

Agent 需要构建镜像时，采用独立的 rootless BuildKit 或 CI runner：

```text
Agent 生成代码和结构化构建请求
    -> 人工/策略审批队列
    -> 认证、allowlist、资源受限的 rootless runner
    -> 构建日志、image digest、SBOM、签名和制品结果
```

runner 的接口接受结构化参数和 argv，不接受未经审查的 shell 字符串。runner
必须：

- 使用专用低权限账号和隔离工作区；
- 只允许批准的仓库、基础镜像、平台和输出 registry；
- 限制 CPU、内存、磁盘、并发、网络和执行时间；
- 清理构建工作区和临时凭据；
- 记录请求人、commit、digest、日志摘要、SBOM 和签名；
- 支持停止、撤销 token 和回滚到上一个已验收 digest。

不要开放无 TLS 的通用 Docker API `2375`，也不要把“远程宿主命令执行”包装
成一个没有 allowlist 的 MCP 工具。

### 宿主 systemd、防火墙和 Docker 管理

这些是 L4 运维能力，默认由人工或独立受控执行器完成。Agent 可以生成变更
草案、测试报告和回滚步骤，但不能直接修改宿主 unit、防火墙、Docker daemon、
Caddy CA 或卷数据。

## 能力分级

| 级别 | 能力 | 推荐接口 | 默认状态 |
|---|---|---|---|
| L0 | 聊天、会话、内网模型调用 | DSH Web + 已固定模型 endpoint | 开启 |
| L1 | 编辑、编译、测试项目 | 单个 `/workspace` 挂载 + dev runtime | 仅开发实例 |
| L2 | Git、MCP、数据库和其他内网服务 | 项目凭据、认证 adapter、网络 allowlist | 按项目审批 |
| L3 | GPU、串口、特殊设备或 OCI 构建 | 精确设备声明或独立 rootless runner | 默认关闭 |
| L4 | Docker daemon、宿主 root、systemd、防火墙、任意宿主文件 | 人工或独立高审计运维系统 | 禁止直通 |

能力只能逐级申请，不能用 L3/L4 权限修复 L0-L2 的配置问题。每次升级都应
记录范围、owner、有效期、验证结果和回滚方式。

## 必须拒绝的负例

以下做法不属于“开箱即用”，而是扩大了未审计的宿主风险：

- DSH 使用 `--host 0.0.0.0`，或直接发布容器 `3080`；
- Caddy 未认证、未使用 HTTPS，或把认证后的入口暴露到公网；
- `network_mode: host`；
- `privileged: true`、`SYS_ADMIN`、`NET_ADMIN` 或全量设备；
- 挂载 Docker socket、宿主 `/`、宿主 `/home`、Docker 数据目录或整个 `.ssh`；
- 把 DSH_HOME、workspace、provider home 和多用户凭据放进同一个共享 volume；
- 在运行时使用 `npx`、`latest`、浮动 tag 或无锁依赖解析；
- 让 Agent 任意修改模型 URL、MCP URL、DNS、代理或防火墙；
- 通过 host-gateway 访问宿主 Docker/systemd 管理面；
- 用完整 GitHub/云平台管理员 token 解决普通 clone/push；
- 把 Agent 生成的 shell 字符串原样交给宿主 runner；
- 用“浏览器点击继续”代替 Caddy 根 CA 信任部署；
- 多个不互信用户共享同一 DSH profile、凭据和工作区。

## 验收与回滚

### 配置和暴露面

1. `docker compose config` 和 Caddy `validate` 均通过。
2. 在 registry 不可达的环境执行 `docker compose up --no-build --pull never`，
   启动日志无下载、构建或浮动版本解析。
3. `docker inspect` 证明 DSH 非 root、根文件系统只读、能力已裁剪、无
   privileged、无 host network、无 socket 和宽泛宿主挂载。
4. 宿主只监听批准的 `LAN_IP:443`；宿主和 Docker published ports 中不存在
   3080。
5. 未认证 HTTPS 返回 401，认证后页面 2xx；客户端导入 Caddy 根 CA 后无证书
   错误；即使认证有效，错误 Host、恶意/不匹配 Origin、显式 cross-site
   Fetch Metadata 和直接 3080 请求仍失败。

### Agent 与 provider

1. DSH Web、Models/settings、会话、真实模型调用和真实 MCP tool call 通过。
2. `/workspace` 的正向写入通过，工作区外相邻目录零写入。
3. stdio provider 的版本、绝对路径、身份、home 和子进程回收通过。
4. 远端 adapter 的 token、TLS、服务 allowlist、失败和重连通过。
5. 模型、MCP、数据库以外的地址不可达，或有明确的受控 egress 记录。
6. host-gateway 例外只到批准端口；未批准的宿主端口和管理面不可达。
7. Git token/SSH key 不出现在 image layer、日志、进程列表和 Agent 输出中。
8. GPU/设备和 rootless runner 的资源、审计、停止和撤销通过。

### 生命周期

1. DSH 或 Caddy 单独重建后，共享网络命名空间和依赖顺序仍然正确。
2. 主机重启、Docker 重启、容器重启后 DSH_HOME、workspace 和 Caddy data
   仍保持预期；没有残留 provider 子进程。
3. 备份当前 image digest、Compose、Caddy 配置和应用卷后，再进行升级。
4. 回滚同时恢复 DSH 镜像 digest、插件/provider 闭包和匹配的 DSH_HOME；
   不能只降级可执行文件而保留未知的新 home schema。
5. 回滚后重新执行 401/认证 200、模型、MCP、workspace 和冷启动验收。

## 上游依据

- [DSH rc.1 Web startup source](https://raw.githubusercontent.com/deepseek-ai/deepseek-harness/dsh-v0.1.1-rc.1/packages/bundle/web-app/src/startup.ts)
- [DSH rc.1 Web server source](https://raw.githubusercontent.com/deepseek-ai/deepseek-harness/dsh-v0.1.1-rc.1/packages/host/webserver/src/index.ts)
- [DSH rc.1 API request trust fence](https://raw.githubusercontent.com/deepseek-ai/deepseek-harness/dsh-v0.1.1-rc.1/packages/client/connection/src/api-request-trust.ts)
- [DSH rc.1 connection and loopback policy](https://raw.githubusercontent.com/deepseek-ai/deepseek-harness/dsh-v0.1.1-rc.1/packages/client/connection/src/index.ts)
- [Docker Compose network namespaces](https://docs.docker.com/compose/how-tos/networking/#change-the-network-mode)
- [Docker multi-platform builds](https://docs.docker.com/build/building/multi-platform/)
- [Caddy local HTTPS](https://caddyserver.com/docs/automatic-https#local-https)
- [Caddy reverse proxy header controls](https://caddyserver.com/docs/caddyfile/directives/reverse_proxy)
- [Community container implementation](https://github.com/runzhliu/deepseek-harness-docker)
