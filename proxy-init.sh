#!/usr/bin/env bash
# proxy-init.sh — 给没有外网的 Debian/Ubuntu 机器配好代理
# 支持 http / https / socks5 / socks5h；不写协议时按 http 处理
# 覆盖: shell 环境 / git / npm / pip / apt（可选 dockerd）
#
# 用法:
#   proxy-init.sh                        交互询问代理地址，直接回车用默认
#   proxy-init.sh --proxy socks5://1.2.3.4:7890
#   proxy-init.sh -H 192.168.1.10 -p 7890
#   proxy-init.sh --check                只测连通性，不改配置
#   proxy-init.sh --no-apt               不配置 apt
#   proxy-init.sh --docker               额外配置 dockerd（仅 http/https）
#   proxy-init.sh --uninstall            撤销本脚本做的全部改动
#
set -euo pipefail

DEFAULT_HOST="${PROXY_HOST:-127.0.0.1}"
DEFAULT_PORT="${PROXY_PORT:-7890}"
NO_PROXY_LIST="${PROXY_NO_PROXY:-localhost,127.0.0.1,::1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,.local,.lan,.internal}"

PROXY_INPUT="${PROXY_URL:-}"
HOST_OVERRIDE=""
PORT_OVERRIDE=""
EXPLICIT=0
DO_APT=1
DO_DOCKER=0
MODE=install

MARK_BEGIN=">>> proxy-init >>>"
MARK_END="<<< proxy-init <<<"
ENV_FILE=/etc/profile.d/90-proxy.sh

# 这台机器已经配过代理就沿用，免得 --check 无参数时去测 127.0.0.1
CONFIGURED_PROXY="$(sed -n 's/^PROXY_URL="\(.*\)"/\1/p' "$ENV_FILE" 2>/dev/null | head -1 || true)"

# 只在终端里上色；重定向到文件或设了 NO_COLOR 就保持纯文本，CLICOLOR_FORCE 可强制
if [ -n "${CLICOLOR_FORCE:-}" ] || { [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; }; then
  C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
  C_GREEN=; C_YELLOW=; C_RED=; C_DIM=; C_OFF=
fi
BASHRC=/etc/bash.bashrc
ENVIRONMENT=/etc/environment
APT_FILE=/etc/apt/apt.conf.d/95proxy
PIP_FILE=/etc/pip.conf

usage() {
  cat <<'EOF'
用法: proxy-init.sh [选项]

  不带参数            交互询问代理地址：已配过的沿用现有地址，否则默认 http://127.0.0.1:7890
  --proxy URL        指定代理；只写 IP 即可，协议默认 http、端口默认 7890
  -H, --host HOST    只改主机（沿用默认端口与 http）
  -p, --port PORT    只改端口
  --no-proxy LIST    覆盖默认的 NO_PROXY 列表
  --check            测各端点直连/代理连通性，并列出 shell/git/npm/pip/apt/docker 状态
  --no-apt           不配置 apt
  --docker           额外配置 dockerd（只支持 http/https 代理）
  --uninstall        撤销本脚本做的全部改动
EOF
}

have() { command -v "$1" >/dev/null 2>&1; }
info() { printf '  %s\n' "$*"; }

# 只清掉代理相关的环境变量，PATH/HOME 等保留（npm 可能装在 nvm 目录里）
run_clean() {
  env -u http_proxy -u https_proxy -u all_proxy \
      -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
      -u no_proxy -u NO_PROXY -u NODE_USE_ENV_PROXY "$@"
}

# 取 HTTP 状态码；000 时重试一次，避开偶发抖动
http_code() {
  local code
  code="$(curl -sS -m 5 -o /dev/null -w '%{http_code}' "$@" 2>/dev/null || true)"
  if [ "${code:-000}" = "000" ]; then
    code="$(curl -sS -m 5 -o /dev/null -w '%{http_code}' "$@" 2>/dev/null || true)"
  fi
  printf '%s' "${code:-000}"
}

# 000 红；2xx/3xx 和 401 绿（401 = 已经连上，只是没带 key）；403/404 黄
color_code() {
  case "$1" in
    000)           printf '%s%s%s' "$C_RED"    "$1" "$C_OFF" ;;
    2??|3??|401)   printf '%s%s%s' "$C_GREEN"  "$1" "$C_OFF" ;;
    *)             printf '%s%s%s' "$C_YELLOW" "$1" "$C_OFF" ;;
  esac
}

normalize_proxy() {
  local u="$1"
  case "$u" in
    *://*) ;;
    *) u="http://$u" ;;
  esac
  u="${u%/}"
  # 只写了主机没写端口时补默认端口，这样交互里直接输一个 IP 就行
  if [[ "$u" =~ ^([A-Za-z0-9+.-]+)://([^/:]+)$ ]]; then
    u="$u:$DEFAULT_PORT"
  fi
  if [[ ! "$u" =~ ^([A-Za-z0-9+.-]+)://([^/:]+):([0-9]+)$ ]]; then
    echo "代理地址格式不对: $1" >&2
    echo "示例: 1.2.3.4、1.2.3.4:8080、http://1.2.3.4:7890、socks5://1.2.3.4:7890" >&2
    echo "不写协议按 http，不写端口按 $DEFAULT_PORT。" >&2
    exit 2
  fi
  SCHEME="$(printf '%s' "${BASH_REMATCH[1]}" | tr 'A-Z' 'a-z')"
  HOST="${BASH_REMATCH[2]}"
  PORT="${BASH_REMATCH[3]}"
  case "$SCHEME" in
    http|https|socks5|socks5h) ;;
    *) echo "不支持的协议: $SCHEME（支持 http / https / socks5 / socks5h）" >&2; exit 2 ;;
  esac
  PROXY_URL="$SCHEME://$HOST:$PORT"
}

# 删除文件中被 MARK 包围的块（幂等追加用）
strip_block() {
  local f="$1" tmp
  [ -f "$f" ] || return 0
  grep -qF "$MARK_BEGIN" "$f" || return 0
  tmp="$(mktemp)"
  awk -v b="$MARK_BEGIN" -v e="$MARK_END" '
    index($0,b){skip=1}
    !skip{print}
    index($0,e){skip=0}
  ' "$f" > "$tmp"
  cat "$tmp" > "$f"
  rm -f "$tmp"
}

render() {
  sed -e "s|__MARK_BEGIN__|$MARK_BEGIN|g" \
      -e "s|__MARK_END__|$MARK_END|g" \
      -e "s|__PROXY_URL__|$PROXY_URL|g" \
      -e "s|__NO_PROXY__|$NO_PROXY_LIST|g"
}

check_tcp() {
  echo "== 代理连通性: $PROXY_URL =="
  if timeout 5 bash -c "exec 3<>/dev/tcp/$HOST/$PORT" 2>/dev/null; then
    info "TCP $HOST:$PORT  ${C_GREEN}OK${C_OFF}"
  else
    info "TCP $HOST:$PORT  ${C_RED}不通${C_OFF}"
    return 1
  fi
}

check_proxy() {
  check_tcp || return 1
  echo
  check_endpoints
}

# 每个端点同时测直连和代理，一眼看出哪些真的需要代理
check_endpoints() {
  echo "== 端点连通性 =="
  printf '  %-30s %-7s %-7s %s\n' "endpoint" "direct" "proxy" "for"

  local dir; dir="$(mktemp -d)"
  local list="$dir/list"
  cat > "$list" <<'EOF'
api.anthropic.com|https://api.anthropic.com/v1/models|claude
claude.ai|https://claude.ai/|claude 登录
api.openai.com|https://api.openai.com/v1/models|codex
chatgpt.com|https://chatgpt.com/|codex 登录
auth.openai.com|https://auth.openai.com/|codex 登录
github.com|https://github.com|git
raw.githubusercontent.com|https://raw.githubusercontent.com/git/git/master/README.md|git 下载
registry.npmjs.org|https://registry.npmjs.org|npm
pypi.org|https://pypi.org/simple/|pip
files.pythonhosted.org|https://files.pythonhosted.org/|pip 下载（根路径 404 正常）
deb.debian.org|http://deb.debian.org/debian/|apt
security.debian.org|http://security.debian.org/debian-security/|apt
download.docker.com|https://download.docker.com/linux/|apt(docker)
registry-1.docker.io|https://registry-1.docker.io/v2/|docker pull
EOF

  local i=0 name url use d p
  while IFS='|' read -r name url use; do
    [ -n "$name" ] || continue
    i=$((i+1))
    (
      d="$(http_code --noproxy '*' "$url")"
      p="$(http_code -x "$PROXY_URL" "$url")"
      printf '%s|%s\n' "$d" "$p" > "$dir/$i"
      # 测完一个立刻打印一个，不攒到最后；状态码本身带颜色
      printf '  %-30s %s     %s     %s\n' "$name" "$(color_code "$d")" "$(color_code "$p")" "$use"
    ) &
  done < "$list"
  wait

  local need_proxy="" proxy_dead="" pair
  i=0
  while IFS='|' read -r name url use; do
    [ -n "$name" ] || continue
    i=$((i+1))
    pair="$(cat "$dir/$i" 2>/dev/null || echo '000|000')"
    IFS='|' read -r d p <<< "$pair"
    if [ "$p" = "000" ]; then
      proxy_dead="$proxy_dead $name"
    elif [ "$d" = "000" ] || { [ "$d" = "403" ] && [ "$p" != "403" ]; }; then
      need_proxy="$need_proxy $name"
    fi
  done < "$list"
  rm -rf "$dir"

  if [ -n "$C_GREEN" ]; then
    echo "  ${C_GREEN}绿${C_OFF}=通(2xx/3xx/401)  ${C_YELLOW}黄${C_OFF}=被拒或无内容(403/404)  ${C_RED}红${C_OFF}=连不上(000)"
  else
    echo "  401=已经连上只是没带 key；403/404=能连上但被拒，404 多为根路径没有索引；000=连不上"
  fi
  if [ -n "$need_proxy" ]; then echo "  ${C_YELLOW}直连不可用，需走代理:${C_OFF}$need_proxy"; fi
  if [ -n "$proxy_dead" ]; then echo "  ${C_RED}代理也不通:${C_OFF}$proxy_dead"; fi
}

# 从配置文件里取一个值，取不到就输出“未配置”
component_value() {
  local f="$1" expr="$2" v=""
  if [ -r "$f" ]; then
    v="$(sed -n "$expr" "$f" 2>/dev/null | head -1)"
  fi
  printf '%s' "${v:-未配置}"
}

status_line() { # 名称 当前值 [目标值]
  local name="$1" val="$2" target="${3:-}" mark=""
  if [ -n "$target" ] && [ "$val" = "$target" ]; then
    mark="  ${C_GREEN}✓${C_OFF}"
  fi
  printf '  %-40s %s%s\n' "$name" "$val" "$mark"
}

check_status() {
  echo "== 各组件状态（目标 $PROXY_URL）=="
  local v dinfo

  # 安装流程里当前 shell 还没重新加载，没设置就不显示这一行
  if [ -n "${HTTPS_PROXY:-}" ]; then
    status_line "current shell" "${HTTPS_PROXY}" "$PROXY_URL"
  fi
  status_line "shell(login) $ENV_FILE" \
    "$(component_value "$ENV_FILE" 's/^PROXY_URL="\(.*\)"/\1/p')" "$PROXY_URL"

  if [ -r "$BASHRC" ] && grep -qF "$MARK_BEGIN" "$BASHRC"; then
    status_line "shell(non-login) /etc/bash.bashrc" "已挂钩"
  else
    status_line "shell(non-login) /etc/bash.bashrc" "未挂钩"
  fi

  status_line "PAM ($ENVIRONMENT)" \
    "$(component_value "$ENVIRONMENT" 's/^http_proxy="\(.*\)"/\1/p')" "$PROXY_URL"

  if have git; then
    v="$(git config --system --get http.proxy 2>/dev/null || true)"
    status_line "git (system)" "${v:-未配置}" "$PROXY_URL"
  fi

  if have npm; then
    v="$(npm config get proxy 2>/dev/null || true)"
    [ "$v" = "null" ] && v="未配置"
    if [ "$IS_HTTP" = 0 ] && [ "$v" != "未配置" ]; then
      status_line "npm (user)" "$v（socks 不生效）"
    else
      status_line "npm (user)" "${v:-未配置}" "$PROXY_URL"
    fi
  fi

  status_line "pip ($PIP_FILE)" \
    "$(component_value "$PIP_FILE" 's/^proxy *= *//p')" "$PIP_PROXY"

  status_line "apt ($APT_FILE)" \
    "$(component_value "$APT_FILE" 's/^Acquire::https::Proxy "\(.*\)";/\1/p')" "$APT_PROXY"

  if [ -r /etc/docker/daemon.json ] && have python3; then
    v="$(python3 - <<'PY' 2>/dev/null
import json
try:
    with open("/etc/docker/daemon.json") as f:
        d = json.load(f)
    print(d.get("proxies", {}).get("https-proxy") or "未配置")
except Exception:
    print("解析失败")
PY
)"
  else
    v="未配置"
  fi
  if [ "$IS_HTTP" = 0 ] && [ "$v" != "未配置" ]; then
    status_line "docker(daemon.json)" "$v（socks 不生效）"
  else
    status_line "docker(daemon.json)" "${v:-未配置}" "$PROXY_URL"
  fi

  if [ -r /etc/systemd/system/docker.service.d/http-proxy.conf ]; then
    v="$(sed -n 's/.*HTTPS_PROXY=\([^ "]*\).*/\1/p' /etc/systemd/system/docker.service.d/http-proxy.conf | head -1)"
    status_line "docker(systemd drop-in)" "${v:-未配置}" "$PROXY_URL"
  fi

  # Docker CLI 用这个文件把代理注入到容器环境里（与 daemon 拉镜像无关）
  if have python3; then
    v="$(python3 - <<'PY' 2>/dev/null
import json, os
try:
    with open(os.path.expanduser("~/.docker/config.json")) as f:
        p = json.load(f).get("proxies", {}).get("default", {})
    print(p.get("httpsProxy") or p.get("httpProxy") or "未配置")
except Exception:
    print("未配置")
PY
)"
    status_line "docker(client config)" "${v:-未配置}" "$PROXY_URL"
  fi

  if have docker; then
    if dinfo="$(timeout 6 docker info --format '{{.HTTPSProxy}}' 2>/dev/null)"; then
      status_line "dockerd(runtime)" "${dinfo:-未设置}" "$PROXY_URL"
    else
      status_line "dockerd(runtime)" "docker 未运行或不可用"
    fi
  fi

  if [ "$IS_HTTP" = 0 ]; then
    echo "  提示: npm 与 dockerd 不支持 socks 代理，pip 需要 PySocks。"
  fi
}

install_all() {
  echo "== 写入配置（代理 $PROXY_URL）=="
  if [ "$IS_HTTP" = 0 ]; then
    echo "  注意: socks 只有部分工具支持（curl / git / apt / Node 20+），npm 与 dockerd 不支持。"
  fi

  # 1. shell 环境：登录 shell
  local tpl
  tpl="$(cat <<'TPL'
# __MARK_BEGIN__ — 由 proxy-init.sh 生成，改配置请重跑该脚本
PROXY_URL="__PROXY_URL__"
export http_proxy="$PROXY_URL" https_proxy="$PROXY_URL" all_proxy="$PROXY_URL"
export HTTP_PROXY="$PROXY_URL" HTTPS_PROXY="$PROXY_URL" ALL_PROXY="$PROXY_URL"
export no_proxy="__NO_PROXY__" NO_PROXY="__NO_PROXY__"
# Node 24+ 的内置 fetch 默认不读代理环境变量，这个开关让它走代理
export NODE_USE_ENV_PROXY=1

# 临时开关（只影响当前 shell）
proxy-off() { unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY; echo "代理已关闭（仅当前 shell）"; }
proxy-on() {
  export http_proxy="$PROXY_URL" https_proxy="$PROXY_URL" all_proxy="$PROXY_URL"
  export HTTP_PROXY="$PROXY_URL" HTTPS_PROXY="$PROXY_URL" ALL_PROXY="$PROXY_URL"
  echo "代理已开启: $PROXY_URL"
}
# __MARK_END__
TPL
)"
  printf '%s\n' "$tpl" | render > "$ENV_FILE"
  chmod 644 "$ENV_FILE"
  info "$ENV_FILE"

  # 2. 非登录交互 shell（docker exec / su）
  tpl="$(cat <<'TPL'

# __MARK_BEGIN__ — 让 docker exec、非登录交互 shell 也拿到代理
if [ -r /etc/profile.d/90-proxy.sh ]; then
  . /etc/profile.d/90-proxy.sh
fi
# __MARK_END__
TPL
)"
  strip_block "$BASHRC"
  printf '%s\n' "$tpl" | render >> "$BASHRC"
  info "$BASHRC"

  # 3. PAM 会话环境（su / cron 之类）
  tpl="$(cat <<'TPL'
# __MARK_BEGIN__
http_proxy="__PROXY_URL__"
https_proxy="__PROXY_URL__"
all_proxy="__PROXY_URL__"
HTTP_PROXY="__PROXY_URL__"
HTTPS_PROXY="__PROXY_URL__"
ALL_PROXY="__PROXY_URL__"
no_proxy="__NO_PROXY__"
NO_PROXY="__NO_PROXY__"
NODE_USE_ENV_PROXY="1"
# __MARK_END__
TPL
)"
  strip_block "$ENVIRONMENT"
  printf '%s\n' "$tpl" | render >> "$ENVIRONMENT"
  info "$ENVIRONMENT"

  # 4. git（系统级，所有用户；libcurl 支持 socks5）
  if have git; then
    git config --system --replace-all http.proxy "$PROXY_URL"
    git config --system --replace-all https.proxy "$PROXY_URL"
    info "git config --system http(s).proxy"
  fi

  # 5. npm（只支持 http/https 代理）
  if have npm; then
    if [ "$IS_HTTP" = 1 ]; then
      npm config set proxy "$PROXY_URL" --location=user >/dev/null 2>&1 || true
      npm config set https-proxy "$PROXY_URL" --location=user >/dev/null 2>&1 || true
      npm config set noproxy "$NO_PROXY_LIST" --location=user >/dev/null 2>&1 || true
      info "npm config (proxy/https-proxy/noproxy)"
    else
      info "npm 不认 socks 代理，跳过"
    fi
  fi

  # 6. pip（socks 需要先装 PySocks）
  if [ ! -f "$PIP_FILE" ]; then
    printf '[global]\nproxy = %s\n' "$PIP_PROXY" > "$PIP_FILE"
    info "$PIP_FILE"
    if [ "$IS_HTTP" = 0 ]; then
      info "pip 走 socks 需要先安装 PySocks，否则会报错"
    fi
  else
    info "$PIP_FILE 已存在，跳过（需要时手动加 proxy = $PIP_PROXY）"
  fi

  # 7. apt（socks 要写成 socks5h）
  if [ "$DO_APT" = 1 ]; then
    cat > "$APT_FILE" <<EOF
// $MARK_BEGIN
Acquire::http::Proxy "$APT_PROXY";
Acquire::https::Proxy "$APT_PROXY";
// $MARK_END
EOF
    info "$APT_FILE"
  fi

  # 8. dockerd（只支持 http/https）
  if [ "$DO_DOCKER" = 1 ]; then
    if [ "$IS_HTTP" = 1 ] && have python3; then
      python3 - "$PROXY_URL" "$NO_PROXY_LIST" <<'PY'
import json, os, shutil, sys
url, noproxy = sys.argv[1], sys.argv[2]
p = "/etc/docker/daemon.json"
data = {}
if os.path.exists(p):
    with open(p) as f:
        data = json.load(f)
    shutil.copy2(p, p + ".bak-proxy-init")
data.setdefault("proxies", {})
data["proxies"].update({"http-proxy": url, "https-proxy": url, "no-proxy": noproxy})
with open(p, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY
      info "/etc/docker/daemon.json（重启生效: systemctl restart docker）"
    else
      info "dockerd 只支持 http/https 代理，跳过"
    fi
  fi
}

uninstall_all() {
  echo "== 撤销配置 =="
  rm -f "$ENV_FILE" "$APT_FILE"
  info "已删除 $ENV_FILE、$APT_FILE"
  if [ -f "$PIP_FILE" ] && grep -qF "$MARK_BEGIN" "$PIP_FILE"; then
    rm -f "$PIP_FILE"
    info "已删除 $PIP_FILE"
  fi
  strip_block "$BASHRC"
  strip_block "$ENVIRONMENT"
  info "已清理 $BASHRC、$ENVIRONMENT 中的块"
  if have git; then
    git config --system --unset-all http.proxy 2>/dev/null || true
    git config --system --unset-all https.proxy 2>/dev/null || true
    info "已清除 git 系统级代理"
  fi
  if have npm; then
    npm config delete proxy --location=user >/dev/null 2>&1 || true
    npm config delete https-proxy --location=user >/dev/null 2>&1 || true
    npm config delete noproxy --location=user >/dev/null 2>&1 || true
    info "已清除 npm 代理配置"
  fi
  if have python3 && [ -f /etc/docker/daemon.json ]; then
    python3 - <<'PY'
import json
p = "/etc/docker/daemon.json"
try:
    with open(p) as f:
        data = json.load(f)
except Exception:
    raise SystemExit(0)
if isinstance(data.get("proxies"), dict):
    data.pop("proxies")
    with open(p, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    print("  已移除 /etc/docker/daemon.json 的 proxies（需重启 docker）")
PY
  fi
  echo "  新开 shell 后生效；当前 shell 可用: unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY"
}

self_test() {
  echo "== 实连测试（各工具用各自的持久配置，不靠当前 shell 环境）=="
  local code tmp r

  # curl 只认环境变量，这里验证登录 shell 的 profile.d 真的被读到了
  code="$(run_clean bash -lc 'curl -sS -m 12 -o /dev/null -w "%{http_code}" https://api.anthropic.com/v1/models' 2>/dev/null || true)"
  printf '  %-30s %s\n' "curl (登录 shell env) → anthropic" "$(color_code "${code:-000}")"

  # git / npm / pip 走各自的配置文件，与 shell 环境无关
  if have git; then
    if run_clean git ls-remote --exit-code https://github.com/git/git.git HEAD >/dev/null 2>&1; then
      r="${C_GREEN}ok${C_OFF}"
    else
      r="${C_RED}失败${C_OFF}"
    fi
    printf '  %-30s %s\n' "git ls-remote → github" "$r"
  fi

  if have npm; then
    if run_clean npm ping --loglevel=silent >/dev/null 2>&1; then
      r="${C_GREEN}ok${C_OFF}"
    else
      r="${C_RED}失败${C_OFF}"
    fi
    printf '  %-30s %s\n' "npm ping → registry" "$r"
  fi

  if have python3 && run_clean python3 -m pip --version >/dev/null 2>&1; then
    tmp="$(mktemp -d)"
    if run_clean python3 -m pip download --no-deps --dest "$tmp" -q pip >/dev/null 2>&1; then
      r="${C_GREEN}ok${C_OFF}"
    else
      r="${C_RED}失败${C_OFF}"
    fi
    rm -rf "$tmp"
    printf '  %-30s %s\n' "pip download → pypi" "$r"
  else
    printf '  %-30s %s\n' "pip download → pypi" "${C_YELLOW}pip 未安装，跳过${C_OFF}"
  fi

  # apt / dockerd 的代理在它们自己的进程里生效，实连代价大，配置见上一节
  printf '  %-30s %s\n' "apt-get update" "${C_DIM}未实连，代理配置见上${C_OFF}"
  if have docker; then
    printf '  %-30s %s\n' "docker pull" "${C_DIM}未实连，改了 daemon.json 需重启 docker${C_OFF}"
  fi
}

while [ $# -gt 0 ]; do
  case "$1" in
    --proxy)     PROXY_INPUT="$2"; EXPLICIT=1; shift 2 ;;
    -H|--host)   HOST_OVERRIDE="$2"; EXPLICIT=1; shift 2 ;;
    -p|--port)   PORT_OVERRIDE="$2"; EXPLICIT=1; shift 2 ;;
    --no-proxy)  NO_PROXY_LIST="$2"; shift 2 ;;
    --no-apt)    DO_APT=0; shift ;;
    --docker)    DO_DOCKER=1; shift ;;
    --check)     MODE=check; shift ;;
    --uninstall) MODE=uninstall; shift ;;
    -h|--help)   usage; exit 0 ;;
    *) echo "未知参数: $1（-h 看用法）" >&2; exit 2 ;;
  esac
done

if [ -z "$PROXY_INPUT" ]; then
  if [ -n "$HOST_OVERRIDE" ] || [ -n "$PORT_OVERRIDE" ]; then
    PROXY_INPUT="http://${HOST_OVERRIDE:-$DEFAULT_HOST}:${PORT_OVERRIDE:-$DEFAULT_PORT}"
  else
    PROXY_INPUT="${CONFIGURED_PROXY:-http://${DEFAULT_HOST}:${DEFAULT_PORT}}"
  fi
fi

if [ "$MODE" = install ]; then
  if [ "$EXPLICIT" = 0 ] && [ -t 0 ]; then
    printf '代理地址 [%s]: ' "$PROXY_INPUT"
    read -r answer || true
    if [ -n "${answer:-}" ]; then
      PROXY_INPUT="$answer"
    fi
  elif [ "$EXPLICIT" = 0 ]; then
    printf '未指定代理地址，使用默认: %s\n' "$PROXY_INPUT"
  fi
fi

normalize_proxy "$PROXY_INPUT"

APT_PROXY="$PROXY_URL"
if [ "$SCHEME" = socks5 ]; then
  APT_PROXY="socks5h://$HOST:$PORT"
fi
PIP_PROXY="$APT_PROXY"
IS_HTTP=0
case "$SCHEME" in
  http|https) IS_HTTP=1 ;;
esac

case "$MODE" in
  check)
    # 代理不通也要继续测下去，否则 set -e 会直接退出
    check_proxy || true
    echo
    check_status
    ;;
  uninstall)
    [ "$(id -u)" -eq 0 ] || { echo "需要 root" >&2; exit 1; }
    uninstall_all
    ;;
  install)
    [ "$(id -u)" -eq 0 ] || { echo "需要 root" >&2; exit 1; }
    check_proxy || { echo "代理不通，未做任何修改" >&2; exit 1; }
    echo
    install_all
    echo
    check_status
    echo
    self_test
    echo
    echo "完成。新开 shell 即生效；当前 shell 执行: . /etc/profile.d/90-proxy.sh"
    ;;
esac
