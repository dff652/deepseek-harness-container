# DSH 容器化离线部署 SOP（ARM64）

> 状态：DSH `0.1.1-rc.2` 的本机原生 AMD64 与 x86/QEMU ARM64 候选已通过 runtime、原生模块、Caddy/HAProxy Compose 与离线包校验；隔离的本机 AMD64 测试实例已升级到 rc.2。GitHub 原生 rc.2、生产 ARM 断网验收、保留的 SBOM/provenance、漏洞处置、签名和镜像发布仍未完成，因此当前仍不是可直接投产的发布镜像。

本文记录 deepseek-harness-container 的目标交付边界：在一台没有外网、没有域名的 Linux ARM64 内网主机上，用 Docker Compose 启动 DSH 和 Caddy，并由内网客户端通过 HTTPS 访问。宿主机 systemd 安装是另一个产品和验收记录，不与本方案混用。

## 2026-08-24 rc.2 本机候选复验

本机生成了 `artifacts/candidate-amd64.8otTIG/` 和
`artifacts/candidate-arm64.F6XyUd/` 两个未发布候选。AMD64 DSH manifest/config
为 `sha256:3cea6dff…` / `sha256:783f744f…`，QEMU ARM64 为
`sha256:0c1fe2ec…` / `sha256:c3511761…`；两个目录中列出的全部
`SHA256SUMS` 成员均通过。两架构均通过禁网原生模块、loopback Web、只读
rootfs、UID 10001、request-image 状态目录和无 shell/package manager 检查。

Caddy 与隔离 HAProxy profile 的真实 DSH Compose 在 AMD64 和 QEMU ARM64
均通过。隔离的本机 AMD64 长期测试项目使用 8443，与宿主 systemd DSH 的
3080 并行；升级到 rc.2 后容器健康，可信 CA/IP-SAN TLS、临时随机凭据的
401/200 与 WebUI title、错误 Origin/Host/cross-site 以及容器无 3080 发布
均通过。测试后恢复原 bcrypt 哈希，临时明文未记录；宿主两个 3080 listener
及其 PID 保持不变。

QEMU 结果仍不能替代真实 ARM64 主机的内核、资源压力、冷启动、模型/MCP、
图像/Files API、权限 UI 和回滚验收。完整边界见
[rc.2 发布就绪记录](rc2-release-readiness.md)。

### 历史 rc.1 AMD64 证据

本机从提交 `ee7580d…` 重新构建了 AMD64 候选。生成的本地目录为
`artifacts/candidate-amd64.jsBlAF/`，其 `SHA256SUMS` 中 11 个成员全部通过；
DSH manifest 为 `sha256:a6099fa8…`、config 为 `sha256:ceb0c7b8…`，Caddy
AMD64 child 为 `sha256:98eb57d8…`。该目录是本机候选证据，不是已发布制品。

验证使用 `--no-build --pull never` 和仅绑定 `127.0.0.1:443` 的临时 Compose
项目，确认：

- DSH `0.1.1-rc.1`、Node `24.19.0` 和四个原生模块在禁网 runtime smoke
  中通过；
- 使用 Caddy 内部 CA 而非 `-k` 时，未认证为 401、认证为 200，错误 Origin
  和 cross-site 为 403，错误 Host 为 421；
- DSH 以 `10001:10001`、只读 rootfs、`cap_drop: ALL` 和
  `no-new-privileges` 运行，3080 未发布，批准的 workspace 可写；
- Caddy 单独重启、先停 Caddy 后重启 DSH、保留卷的整栈重建均通过，内部
  CA 和 workspace 数据保持不变。

不要执行 `docker compose restart dsh caddy` 并发重启。Caddy 使用
`network_mode: service:dsh` 共享 DSH 的网络命名空间，本机实测并发 restart
会产生 OCI runtime 命名空间竞态。维护时将二者视为一个耦合设备：网关单独
重启可直接执行；DSH 重启前先停 Caddy，再按依赖顺序 `up -d --wait`；升级、
回滚和冷启动验收优先使用保留卷的整栈 recreate。该 AMD64 结果不替代真实
ARM64 主机的断网、宿主重启、浏览器、模型和 MCP 验收。

### 与正在使用的宿主 systemd DSH 并行验证

宿主原生 DSH 的 `127.0.0.1:3080`（以及部署拥有的 LAN relay）与容器内
`127.0.0.1:3080` 位于不同 network namespace，本身不会端口冲突，也不得为了
测试容器而停止正在使用的宿主服务。只有宿主 HTTPS 监听端口已被占用，或需要
明确区分候选入口时，才把容器的外部 HTTPS 端口改为例如 8443；容器内部 Caddy
仍监听 443，容器 DSH 仍不发布 3080。

部署环境必须同时固定端口与完整外部 authority。以下仅使用文档保留地址：

```dotenv
DSH_LAN_IP=192.0.2.10
DSH_HTTPS_PORT=8443
DSH_EXTERNAL_AUTHORITY=192.0.2.10:8443
```

此时浏览器入口是 `https://192.0.2.10:8443/`。Host 必须精确包含 8443，浏览器
提供的 Origin 也必须精确为 `https://192.0.2.10:8443`；无端口或错误端口不能
同时加入允许列表。若使用默认 443，则 authority 只写裸 IP。2026-08-24 本机
AMD64 实测确认默认 443 与自定义 8443 均能返回认证后的 WebUI；8443 路径还通过
无认证 401、正确认证 200、错误 Origin 403、错误 Host 421、可信 IP-SAN TLS 和
容器 3080 未发布检查，宿主 systemd DSH 的进程、3080 listener 和 HTTP 200 在
测试前后保持不变。同步重建的本机离线候选位于
`artifacts/candidate-amd64.z2Tr4X/`，其 11 个 `SHA256SUMS` 成员全部通过；
`SHA256SUMS` 文件自身摘要为 `sha256:3acc5769…`。该目录仍是本机候选证据，
不是已发布制品。

## 1. 固定版本与证据边界

候选版本必须使用完整、可复现的版本元数据：

| 组件 | 固定候选版本 | 交付要求 |
| --- | --- | --- |
| DeepSeek Harness | @deepseek-ai/dsh@0.1.1-rc.2 | 对应上游标签 dsh-v0.1.1-rc.2 与提交 b150a551b8d465e31e418e1b2eaf5e79bbb7d28e；npm integrity 由锁文件独立固定，npm 元数据不提供与该提交的密码学绑定 |
| Node.js | 24.19.0 | Linux arm64 运行时；必须记录下载包 SHA-256 |
| pnpm | 11.7.0 | 仅用于构建/安装依赖，版本写入构建元数据 |
| Caddy | 2.11.4 | 镜像、二进制和基础镜像必须在最终 image-lock 中记录真实 digest |
| 平台 | linux/arm64 | 生产目标是 aarch64；本 SOP 假设 glibc 用户态 |

GitHub 标签页面的 zip/tar.gz 是源码快照，不是可运行安装包；npx @deepseek-ai/dsh web 是联网时的 CLI 获取方式，也没有固定依赖闭包。离线交付物应是已经审查的容器镜像和完整离线包，而不是把该命令写进生产启动脚本。

当前版本仍是候选版本。除非完成真实 ARM 主机的断网启动、浏览器、模型/MCP 调用、重启和安全负例验收，不得宣称 ARM 生产支持，也不得替换现有 systemd rc.6 基线。

### 构建方式的证据等级

- **原生 ARM64 构建（推荐）**：在与生产相同的 aarch64/glibc 主机或等价隔离构建机中安装原生依赖并执行 smoke test。它能直接暴露 node-pty、Koffi、Landlock 等原生模块问题，但仍不能替代生产主机验收。
- **x86 Buildx/QEMU 构建（候选）**：可以在 x86 构建 linux/arm64 镜像，例如 docker buildx build --platform linux/arm64。它证明的是构建上下文和镜像架构，不证明真实 ARM 上的内核、设备、原生模块、性能或重启行为；必须再到 ARM 主机完成全量验收。
- **仅检查 lock/store（不足）**：锁文件中出现 ARM64 包，或 QEMU 能启动容器，都不能单独形成生产支持结论。

## 2. 目标拓扑

    内网客户端
        │  https://<部署时的内网 IP>:<批准的 HTTPS 端口>
        ▼
    Caddy（与 DSH 共享 network namespace，仅入口和认证）
        │  127.0.0.1:3080
        ▼
    DSH（固定非 root 用户、loopback 监听、只读根文件系统）
        ├── /workspace       经过批准的工作区挂载
        ├── /var/lib/dsh     DSH_HOME 持久卷
        └── provider/model   容器内 stdio 或受控内网 HTTP 端点

DSH 不直接发布 3080，也不使用 host network。Compose 中 Caddy 使用 network_mode: service:dsh，因此 Caddy 能访问 DSH 的容器 loopback；由于共享 network namespace，宿主的批准 HTTPS 端口到容器 443 的映射必须声明在拥有该 namespace 的 dsh 服务上，Caddy 服务本身不要再声明 ports。最终 Compose 必须由 docker compose config 解析，并由负例测试确认没有 3080、Docker socket、host network、privileged 或宽泛宿主挂载。

没有域名不是阻塞条件：Caddy 可以为部署时的内网 IP 使用 tls internal 签发内部证书，并用 `default_sni` 为不发送 SNI 的字面量 IP 客户端选择该证书。客户端必须导入并信任 Caddy 根 CA；根 CA 私钥只存放在目标机的受保护持久卷，不进入镜像或离线包。宿主 SSH 不能直接访问另一个 network namespace 内的容器 loopback。若只有单个管理员使用，可以用只发布到宿主 loopback 的、同 namespace 最小 relay 替代 Caddy，再通过 SSH 隧道访问；它仍是一个需要单独配置和验收的代理模式，不能靠普通 3080 端口映射直接连接 DSH。

## 3. 宿主机前置条件

在目标 ARM 主机执行只读检查，确认后再导入包：

    uname -m
    getconf GNU_LIBC_VERSION
    docker version
    docker compose version
    docker info

必须满足：

- uname -m 为 aarch64（不是 armv7l/32 位 ARM）；glibc 版本与构建验收环境兼容。若目标是 Alpine/musl，须另做 musl 构建和验收，不能复用本 SOP 的 glibc 包。
- Docker Engine、Compose plugin、containerd、cgroup/iptables 或等价网络能力已在断网环境正常工作；具体 Docker 版本由部署基线固定并记录，不在本文使用浮动版本。
- 宿主已预留镜像、容器日志、Caddy 数据卷、DSH_HOME 和工作区空间，且有稳定的静态内网 IP 或 DHCP 保留地址。真实 IP、路径、认证 hash 和模型凭据属于部署配置，不写入仓库；DSH 身份固定为 `10001:10001`，批准的工作区必须预先授予该身份。
- 目标机只允许客户端到部署批准的 HTTPS 端口（默认 443，隔离候选可用 8443），不允许客户端直达容器 3080；不配置路由器端口转发。
- 离线介质可以验证 SHA-256；生产管理员拥有导入镜像和启动 Compose 所需的最小 Docker 权限。

若采用 rootless Docker，必须先在相同 rootless 网络、端口权限和重启策略下单独验收；不能仅因为 rootless 更安全就假设 443、Caddy 内部 CA 持久化或冷启动行为等价。

### Docker/Compose 不是应用镜像的一部分

`docker save` 得到的 DSH/Caddy tar 不包含 Docker Engine、containerd、Buildx
或 Compose plugin。生产 ARM 主机若还没有容器运行时，必须先按它的发行版、
版本和 aarch64 架构制作一份独立的宿主 bootstrap 包：在同版本联网暂存机从
Docker 官方软件源下载固定的 Engine、CLI、containerd、Buildx、Compose
plugin 及完整 deb/rpm 依赖，保存仓库签名、包校验和和安装顺序，再在隔离的
同发行版 ARM 主机做一次断网安装与重启验收。不要把在线 convenience script
或发行版不匹配的一组包写成通用离线安装命令。

宿主 bootstrap 和本应用 bundle 是两个制品、两组回滚记录。前者先证明
daemon、cgroup、存储和防火墙冷启动正常，后者才执行下面的镜像导入；应用
容器内不会再启动一个 Docker daemon，也不会挂载宿主 Docker socket。

## 4. 联网隔离构建与交付物

构建应在单独的联网准备区完成，生产凭据和生产工作区不得进入该环境。当前 Dockerfile 以固定 Node ARM64 子清单、DSH/pnpm 锁文件和构建脚本白名单联网执行 `pnpm fetch`，再从已取得的完整 store 离线安装；生产目标机不执行包下载。provider 制品也必须在构建区按版本和 digest 准备。若使用 x86/QEMU，构建产物必须标为候选，并在交付清单中保留构建平台和 QEMU 说明。

最终离线包建议采用以下布局；文件名中的版本必须是实际版本，不得改成 latest：

    dsh-container-bundle-<release-id>/
    ├── compose.yaml
    ├── Caddyfile
    ├── .env.example                 # 仅变量名和说明，不含秘密
    ├── images/
    │   ├── dsh-0.1.1-rc.2-arm64.tar
    │   └── caddy-2.11.4-arm64.tar
    ├── image-lock.json              # 真实 image ID/digest、平台、构建来源
    ├── sbom/
    │   ├── dsh.spdx.json
    │   └── caddy.spdx.json
    ├── provenance/
    │   ├── dsh.intoto.jsonl
    │   └── caddy.intoto.jsonl
    ├── SHA256SUMS
    └── RELEASE-MANIFEST.json        # 版本、构建时间、工具版本、验收记录索引

image-lock.json 在发布前必须包含真实的 DSH/Node/pnpm/Caddy/base-image/provider 版本和 digest、linux/arm64 平台、构建来源及 image ID。设计阶段可以只有 schema 或待办项，但不能把未解析的 digest 占位符、秘密或生产 IP 当成可发布内容。SBOM 和 provenance 应来自实际镜像；没有实际构建就没有可声称的 SBOM/provenance。

镜像要点：

- DSH、Node、pnpm、Caddy 和基础镜像版本全部固定；基础镜像不能使用浮动 tag，最终构建输入必须对应审查过的 digest。
- 构建时使用提交的 lockfile 和完整离线依赖 store；不要在 Dockerfile 中调用未固定的 npx、npm install 或隐式网络下载。
- DSH 以固定非 root `10001:10001` 启动，Caddy 长期进程以 `1000:1000` 启动，根文件系统只读；网络关闭的一次性初始化服务仅用 `CHOWN` 准备 Caddy 的两个应用子目录。仅挂载批准的工作区、DSH_HOME、Caddy data/config 和必要 provider 状态卷。
- 不把模型 API key、Basic Auth hash、SSH key、Caddy 私钥、客户端 CA 信任或任何生产 .env 烘焙进层、Compose、测试或 SBOM。
- stdio provider 若随 DSH 使用，必须在镜像中以精确版本交付；HTTP provider 只能通过受认证、允许列表明确的内网端点访问。provider 的业务代码和数据模型仍归其所属项目，不复制到本仓库。

构建者在实际生成镜像后执行类似以下命令；命令中的镜像引用必须替换成已经解析并写入 image-lock.json 的真实引用，本文没有声称这些命令已经执行：

    # 原生 ARM64：在 ARM 构建机执行
    docker build --platform linux/arm64 --tag <已锁定的-dsh-image-ref> .

    # x86/QEMU：仅生成候选
    docker buildx build --platform linux/arm64 --tag <已锁定的-dsh-image-ref> --load .

    # 生成离线传输包（仅针对 image-lock 中已经验收的镜像）
    docker save <dsh-image-ref> -o images/dsh-0.1.1-rc.2-arm64.tar
    CADDY_REF='caddy:2.11.4@sha256:1172d4213087d3fc30bafc7ff2c2896180eb0c41ff7f75f315568fb36cabdcba'
    CADDY_ARCHIVE_TAG='caddy:dsh-offline-2.11.4-arm64-1172d4213087'
    scripts/save-pinned-image.sh "$CADDY_REF" linux/arm64 \
      "$CADDY_ARCHIVE_TAG" images/caddy-2.11.4-arm64.tar
    sha256sum images/*.tar compose.yaml Caddyfile image-lock.json > SHA256SUMS

禁止直接对 `name:tag@child-digest` 执行 `docker save`：这种归档可能写出
`RepoTags:null`，在全新断网 daemon 上 `docker load` 后没有稳定的 Compose
名称。仓库 helper 先把已核验 child 指向同一 repository 下的专用“架构 +
digest 前缀”标签，并断言唯一 RepoTag。containerd store 还能保留并核验 child
manifest/subject；classic store 则以源 config digest、归档 SHA 和平台形成离线
身份。目标机一律使用专用标签，而不是假设 registry digest 会被 `docker load`
恢复。[Docker 官方文档](https://docs.docker.com/reference/cli/docker/image/save/)
也只承诺 `docker image save` 保存指定标签/版本。专用标签
存在且 ID 相同可复用，存在但 ID 不同则失败。

docker save 不保存卷、凭据、Caddy 内部 CA 私钥或 DSH 工作区。所有这些状态必须按部署策略在目标机初始化或由受控备份恢复。

## 5. 目标机导入与离线启动

以下流程假定离线包已通过介质放到目标机的受控目录；BUNDLE_DIR 只代表管理员已经检查过的具体目录，不能为空或指向宽泛路径。

    export BUNDLE_DIR=/srv/offline/dsh-container-bundle-<release-id>
    test -d "$BUNDLE_DIR"
    test -f "$BUNDLE_DIR/SHA256SUMS"
    cd "$BUNDLE_DIR"
    sha256sum --check SHA256SUMS

    docker load --input images/dsh-0.1.1-rc.2-arm64.tar
    docker load --input images/caddy-2.11.4-arm64.tar
    docker image inspect <dsh-image-ref> --format '{{.Os}}/{{.Architecture}} {{.Id}}'
    docker image inspect 'caddy:dsh-offline-2.11.4-arm64-1172d4213087' \
      --format '{{.Os}}/{{.Architecture}} {{.Id}}'

镜像 inspect 必须显示 linux/arm64；classic store 的 Caddy ID 应为锁定 config
`sha256:6b08c1b9…`，containerd store 可显示锁定 child manifest
`sha256:1172d421…`。环境文件中的 `CADDY_IMAGE` 必须使用包内
`.env.example` 给出的专用标签。校验失败、架构不符、镜像缺层、标签或锁文件
不一致时停止，不要尝试联网拉取或重新解析依赖。

将部署拥有的变量写入目标机受保护的环境文件（不提交仓库、不放进离线包）；至少包括实际监听 IP、项目名、工作区路径、认证 hash 的注入方式及模型/provider 端点。不要用环境变量覆盖固定容器身份；应把批准的工作区准备为 `10001:10001` 可写。然后先只解析 Compose：

    docker compose --env-file /etc/dsh/production.env -f compose.yaml config

解析结果必须确认：

- 对外只发布环境文件批准的 HTTPS 端口到容器 443；没有 3080:3080 或其他 DSH 端口映射。
- `DSH_EXTERNAL_AUTHORITY` 与 IP/端口精确一致：默认 443 使用裸 IP，非默认端口使用 `IP:port`。
- Caddy 与 DSH 使用 network_mode: service:dsh（或同等已验收的共享 namespace）；Caddy 负责容器内 443，DSH 仍只绑定容器 loopback 127.0.0.1:3080。
- 没有 network_mode: host、privileged: true、Docker socket、host /、/home、/root 挂载或 SYS_ADMIN/NET_ADMIN。
- 运行用户、只读根文件系统、工作区和持久卷与部署清单一致。

确认无误且目标机已断网或无法访问 registry 后，使用明确的离线参数：

    docker compose --env-file /etc/dsh/production.env -f compose.yaml \
      up -d --no-build --pull never
    docker compose --env-file /etc/dsh/production.env -f compose.yaml ps

禁止为了“修复”启动失败而去掉 --no-build/--pull never、改用 latest、临时挂 Docker socket 或开放宿主网络。首先收集 docker compose logs --no-color、容器 inspect、卷和权限信息，再回到构建或配置验收环节。

## 6. Caddy、内网访问与证书

多客户端访问时，Caddy 是唯一 LAN 入口，Caddy 与 DSH 共享网络 namespace。实际 Caddyfile 由构建/部署文件提供，必须包含以下安全性质：

- 使用部署时的内网 IP 和 tls internal；不写公共域名、公共 DNS 或自动申请公网证书。
- 使用部署时注入的 Basic Auth hash 或等价的已审查认证层；明文密码不进文件、镜像或日志。
- Caddy 用批准 IP 的站点路由接收合法 Host，并用独立 HTTPS catch-all 对其他 Host 返回 421；在批准路由中拒绝显式 Sec-Fetch-Site: cross-site，并要求出现的 Origin 与外部 HTTPS authority 完全同源；Basic Auth 不能替代这组 DNS-rebinding/CSRF 防线。
- 只有上述外部请求信任检查通过后，loopback adapter 才可把上游 Host 改为 127.0.0.1:3080，并移除已验证的外部 Origin/Fetch-Metadata 头。不得用全局删除请求头来绕过检查；确需原始同源头的插件路由必须单独配置和测试。
- Caddy data/config 持久化，根 CA 私钥只在目标机受限目录；根证书通过受控介质分发到客户端信任库。
- 宿主防火墙只允许管理的 LAN CIDR 到批准的 HTTPS 端口；从另一台内网设备验证容器没有发布 3080。与候选并行运行的宿主原生 DSH/relay 必须作为另一条已知入口单独记录，不能误算成容器端口。

客户端首次访问 `https://<实际内网 IP>[:非默认端口]/` 时，必须先确认导入的是该部署生成的根 CA，不能通过忽略证书错误来绕过验收。

单管理员的替代 profile 必须先在 DSH network namespace 中运行一个经过审查的 relay，将其非 loopback 监听端口只发布到宿主 `127.0.0.1`，再让 SSH local-forward 指向该宿主端口。它不需要 Caddy 的 PKI/Basic Auth 功能，但仍需要 relay、容器安全负例和 SSH 验收。不得把宿主 `127.0.0.1:3080` 直接等同于容器 `127.0.0.1:3080`。多客户端 Caddy 模式和单管理员 relay 模式的 Compose、端口与验收记录必须分开保存。

## 7. Agent 开发与外部连通边界

Agent 开发不需要让 DSH 容器暴露到互联网，也不应让 Agent 获得宿主 Docker 权限。按 provider 类型处理：

1. **容器内 stdio provider**：随固定版本镜像交付，在容器内启动；仅给它批准的工作区和状态目录。provider 的失败、重连、超时和清理必须有测试。
2. **内网 HTTP provider/model**：通过 Compose 内部网络或明确的内网地址访问，使用认证、超时、TLS/证书和 allowlist；不要为了方便把 provider 绑定到 0.0.0.0。
3. **确需外部服务的开发阶段**：在独立开发环境通过受控、可审计、允许列表的出口或代理访问；生产 air-gap 不提供该出口。将所需 provider/model 制品和凭据策略转为离线交付后，再在断网目标机验收。

开发镜像可以带编译器、Git、测试工具，但应与生产运行镜像区分，并通过显式 Compose profile 或独立项目启动。工作区只读/读写权限、挂载路径和可写范围要有测试：允许目标目录内写入，邻接目录零写入；不得挂宿主根目录、宿主 home、通用 SSH 私钥或 Docker socket。任何需要宿主构建/安装的动作交给独立、认证、allowlist、审计的 runner，runner 接受参数数组而不是任意 shell 字符串。

## 8. 验收门槛

发布到生产前，主代理或指定验收人必须从离线包和实际目标机取得证据，不能只采信构建者口头结论：

### 构建与包完整性

- [ ] DSH、Node、pnpm、Caddy、基础镜像和 provider 版本与锁文件一致；没有浮动 tag、分支或未解析 digest。
- [ ] 镜像均为 linux/arm64；image-lock.json、SBOM、provenance、SHA-256 与实际文件一致。
- [ ] 包内不含秘密、生产 IP、Caddy 私钥、凭据或宿主机私有路径。
- [ ] x86/QEMU 若参与构建，仅记录为候选证据，未被当作 ARM 生产验收。

### 断网运行与安全边界

- [ ] 断开 DNS/registry/外网后，docker load、Compose 解析和 up -d --no-build --pull never 成功。
- [ ] 冷启动/宿主重启后，DSH 和 Caddy 自动恢复；没有依赖人工联网拉层。
- [ ] 容器只发布预期的 HTTPS 端口；容器 3080 不发布。若宿主原生 DSH 正在并行使用 3080，其进程、listener、访问策略和后续切换决定另行记录。
- [ ] 未认证请求得到 401；导入正确根 CA 的授权客户端得到 HTTPS 200；错误/未信任证书不被忽略。
- [ ] 即使携带有效 Basic Auth，恶意/不匹配 Origin、Sec-Fetch-Site: cross-site 和未批准 Host 仍在任何 loopback 头重写前被拒绝。
- [ ] Compose 安全负例确认无 Docker socket、privileged、host network、宽泛宿主挂载和危险 capability。

### 功能与回归

- [ ] 浏览器能够打开 DSH，设置/会话/工作区操作正常。
- [ ] 使用实际内网模型完成一次受控 prompt；使用实际 MCP/provider 完成一次工具调用。
- [ ] 验证工作区内允许写入、邻接目录零写入；provider 失败、重连和清理符合预期。
- [ ] 保存日志、docker inspect、Compose config、端口检查、模型/MCP 结果和重启时间线作为验收记录。

任一门槛失败，状态保持“候选/未发布”，不得以增加权限、开放端口、连接外网或忽略 TLS 的方式掩盖问题。

## 9. 回滚与生命周期

每个已验收版本都必须保留其镜像 tar、image-lock.json、SBOM、provenance、SHA-256、Compose/Caddyfile 和验收记录。升级前先在隔离环境验证新包，并保留当前运行版本和卷备份。

回滚时：

1. 停止当前项目并保存日志、容器 inspect、健康状态和失败时间线；不删除 DSH_HOME、工作区、Caddy data/config 或模型/provider 状态卷。
2. 校验并 docker load 上一个已验收版本的镜像 tar。
3. 选择旧版本对应的、已审查的环境和 Compose 引用，执行 docker compose ... up -d --no-build --pull never。
4. 重新执行 443/3080 负例、证书/认证、浏览器、模型/MCP 和冷启动关键检查。

镜像导入、签名/发布、注册表推送、生产部署和回滚都是独立的授权转换。当前已有通过本机验收的 AMD64/QEMU ARM64 候选，以及下载复核通过的 GitHub 原生 AMD64/ARM64 候选和 classic-store clean-load 证据。项目已有实际 Dockerfile、Compose、Caddyfile 和候选包，但还缺生产 ARM 验收、完整 SBOM/provenance/签名和正式发布包验证，因此仍不应把新项目称为“开箱即用”发布物。
