# proxy-init

给没有外网的 Debian / Ubuntu 机器一键配好代理，让终端里的 `claude`、`codex`、`npm`、`git`、`apt` 等能正常出网。

## 用法

```bash
sudo ./proxy-init.sh                          # 交互询问代理地址，回车用默认 127.0.0.1:7890
sudo ./proxy-init.sh --proxy 192.168.1.10     # 只写 IP，端口默认 7890
sudo ./proxy-init.sh --proxy socks5://192.168.1.10:1080
sudo ./proxy-init.sh -H 192.168.1.10 -p 8080  # 只改主机/端口
sudo ./proxy-init.sh --check                  # 测连通性 + 列出各组件当前状态
sudo ./proxy-init.sh --no-apt                 # 不动 apt
sudo ./proxy-init.sh --docker                 # 顺带配置 dockerd（仅 http/https）
sudo ./proxy-init.sh --uninstall              # 撤销全部改动
```

地址只写 IP 就行：不写协议按 `http`，不写端口按默认端口 `7890`。`192.168.1.10` 等价于 `http://192.168.1.10:7890`。

不带参数时，如果这台机器已经配过（`/etc/profile.d/90-proxy.sh` 里有 `PROXY_URL`），会沿用现有地址；从没配过才用默认的 `http://127.0.0.1:7890`。所以要测别的代理，直接 `--proxy 10.0.0.5` 或 `-H/-p` 覆盖。

安装完成后新开 shell 即生效；当前 shell 执行 `. /etc/profile.d/90-proxy.sh`。

`--check` 先测代理 TCP 连通性，再对所有相关端点同时做**直连 / 代理**两路探测，一眼看出哪些真的需要代理、哪些直连即可（8 秒左右）：

```
== 端点连通性 ==
  endpoint                       direct  proxy   for
  api.anthropic.com              403     401     claude
  api.openai.com                 000     401     codex
  registry-1.docker.io           000     401     docker pull
  ...
  直连不可用，需走代理: api.anthropic.com api.openai.com chatgpt.com registry-1.docker.io
```

覆盖 claude、codex、git、npm、pip、apt、docker 共 14 个端点。终端里会给状态码上色：

- **绿**（2xx / 3xx / 401）= 通。401 表示已经连到服务，只是没带 key。
- **黄**（403 / 404）= 能连上但被拒或无内容。`files.pythonhosted.org` 的 404 是正常的，CDN 根路径本来就没有索引。
- **红**（000）= 连不上。

设 `NO_COLOR=1` 可以关掉颜色；输出被重定向时自动不上色，`CLICOLOR_FORCE=1` 可强制上色。

之后逐项列出登录 shell、非登录 shell、PAM、git、npm、pip、apt、docker 的当前配置，与目标地址一致的会标 `✓`。docker 分四行：`daemon.json`、systemd drop-in、Docker CLI 的 `~/.docker/config.json`（决定容器里有没有代理变量）、以及 `docker info` 报告的运行时值（决定拉镜像走不走代理）。

## 协议支持

| 协议 | 说明 |
| --- | --- |
| `http://` | 默认，兼容性最好，所有工具都支持 |
| `https://` | 代理连接本身走 TLS |
| `socks5://` / `socks5h://` | curl、git、apt、Node 20+ 可用；npm 与 dockerd 不支持 |

选 socks 时脚本会自动降级：

- apt 写成 `socks5h://`（apt 只认这一种 socks 写法）
- npm、dockerd 跳过不配，并在输出里提示
- pip 照写，但需要系统里先装 PySocks，否则 pip 会报错

## 覆盖范围

| 位置 | 作用 |
| --- | --- |
| `/etc/profile.d/90-proxy.sh` | 登录 shell |
| `/etc/bash.bashrc` | `docker exec -it` 等非登录交互 shell |
| `/etc/environment` | PAM 会话（su / cron） |
| `git config --system` | `http.proxy` / `https.proxy` |
| `npm config --location=user` | `proxy` / `https-proxy` / `noproxy`（仅 http/https） |
| `/etc/pip.conf` | pip |
| `/etc/apt/apt.conf.d/95proxy` | apt |
| `/etc/docker/daemon.json` | 可选（`--docker`，仅 http/https） |

`NO_PROXY` 默认包含 `localhost,127.0.0.1,::1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,.local,.lan,.internal`，内网请求不走代理。

## 注意

- Node 24+ 的内置 `fetch` 默认不读代理环境变量，脚本会设置 `NODE_USE_ENV_PROXY=1`；Node 21+ 也支持 socks5（实验特性）。
- 除环境变量外，还给 git / npm / pip / apt 写了持久配置，所以非交互式调用（如 `ssh host npm install`）也能出网。
- 所有改动都是幂等的，重复执行只会覆盖脚本自己写入的标记块；`--uninstall` 可全部撤销。
- 脚本需要 root 权限运行。
