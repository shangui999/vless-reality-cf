#!/bin/sh
#═══════════════════════════════════════════════════════════════════════════════
#  VLESS Reality + CF CDN 域名一键部署脚本 v1.1.0
#
#  功能: VLESS+Reality 偷 CF CDN 域名 + SNI 校验 + 用户管理
#  适配: Debian/Ubuntu/CentOS/RHEL/Alma/Rocky/Fedora/Alpine
#
#  基于: https://github.com/Zyx0rx/vless-all-in-one (v3.5.3)
#        精简为仅 VLESS Reality + CF 域名 + 用户管理
#═══════════════════════════════════════════════════════════════════════════════

# Alpine 只有 BusyBox ash 且默认不装 bash。用 /bin/sh 起头自举 bash 再重新执行自身，
# 避免 "bad interpreter: /bin/bash" 直接失败。这一段必须是 POSIX sh 语法。
if [ -z "${BASH_VERSION:-}" ] || shopt -oq posix 2>/dev/null; then
    if ! command -v bash >/dev/null 2>&1; then
        if command -v apk >/dev/null 2>&1; then
            apk add --no-cache bash >/dev/null 2>&1
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y bash >/dev/null 2>&1
        elif command -v yum >/dev/null 2>&1; then
            yum install -y bash >/dev/null 2>&1
        elif command -v apt-get >/dev/null 2>&1; then
            apt-get update -qq >/dev/null 2>&1
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq bash >/dev/null 2>&1
        fi
    fi
    if command -v bash >/dev/null 2>&1; then
        exec bash "$0" "$@"
    fi
    echo "本脚本依赖 bash，自动安装失败，请先手动安装 bash 再运行。" >&2
    exit 1
fi

# 不启用 set -e，交互式脚本中很多命令预期返回非零 (grep/curl/jq 等)
# set -euo pipefail

readonly VERSION="1.1.0"
readonly CFG="/etc/vless-reality-cf"
readonly DB_FILE="$CFG/db.json"
readonly XRAY_BIN="/usr/local/bin/xray"
readonly XRAY_CONFIG="$CFG/xray.json"
readonly XRAY_INTERNAL_PORT=8443
readonly NGINX_SNI_CONF="/etc/nginx/stream.conf.d/vless-reality-sni.conf"
readonly USERS_DIR="$CFG/users"

# 颜色
R='\e[31m'; G='\e[32m'; Y='\e[33m'; C='\e[36m'; W='\e[97m'; D='\e[2m'; NC='\e[0m'

# curl 超时
readonly CURL_TIMEOUT=10
readonly CURL_TIMEOUT_DOWNLOAD=60

# IP 缓存
_CACHED_IPV4=""
_CACHED_IPV6=""

#═══════════════════════════════════════════════════════════════════════════════
#  系统检测
#═══════════════════════════════════════════════════════════════════════════════

if [[ -f /etc/alpine-release ]]; then
    DISTRO="alpine"
elif [[ -f /etc/centos-release ]] || [[ -f /etc/almalinux-release ]] || \
     [[ -f /etc/rocky-release ]]   || [[ -f /etc/fedora-release ]] || \
     [[ -f /etc/redhat-release ]]; then
    DISTRO="centos"
elif grep -qi ubuntu /etc/os-release 2>/dev/null; then
    DISTRO="ubuntu"
elif grep -qi debian /etc/os-release 2>/dev/null; then
    DISTRO="debian"
else
    DISTRO="unknown"
fi

# 包管理器按实际存在的命令判断，不依赖发行版名字
if   command -v apk     >/dev/null 2>&1; then PKG_MGR="apk"
elif command -v dnf     >/dev/null 2>&1; then PKG_MGR="dnf"
elif command -v yum     >/dev/null 2>&1; then PKG_MGR="yum"
elif command -v apt-get >/dev/null 2>&1; then PKG_MGR="apt"
else PKG_MGR="unknown"; fi

# 服务管理器同理：openrc 与 systemd 都可能出现在非预期发行版上
if command -v rc-service >/dev/null 2>&1 && [[ -d /etc/runlevels ]]; then
    SVC_MGR="openrc"
elif command -v systemctl >/dev/null 2>&1; then
    SVC_MGR="systemd"
else
    SVC_MGR="unknown"
fi

check_root() { if [[ $EUID -ne 0 ]]; then _err "请使用 root 权限运行"; exit 1; fi; }
check_cmd()  { command -v "$1" &>/dev/null; }

#═══════════════════════════════════════════════════════════════════════════════
#  基础工具函数
#═══════════════════════════════════════════════════════════════════════════════

_line()  { echo -e "${D}─────────────────────────────────────────────${NC}"; }
_dline() { echo -e "${C}═══════════════════════════════════════════════${NC}"; }
_info()  { echo -e "  ${C}▸${NC} $1"; }
_ok()    { echo -e "  ${G}✓${NC} $1"; }
_err()   { echo -e "  ${R}✗${NC} $1"; }
_warn()  { echo -e "  ${Y}!${NC} $1"; }
_item()  { echo -e "  ${G}$1${NC}) $2"; }
_pause() { echo ""; read -rp "  按回车继续..."; }

_header() {
    clear 2>/dev/null || true; echo ""
    _dline
    echo -e "    ${W}VLESS Reality${NC} ${D}+${NC} ${C}CF CDN${NC}  ${D}v${VERSION}${NC}"
    echo -e "    ${D}偷域名 + SNI校验 + 用户管理${NC}"
    _dline
}

#═══════════════════════════════════════════════════════════════════════════════
#  网络工具
#═══════════════════════════════════════════════════════════════════════════════

# 判断是否为公网 IPv4（排除私网 / CGNAT / 环回 / 链路本地等）
_is_public_ipv4() {
    local ip="$1" o1 o2
    [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || return 1
    o1=${ip%%.*}
    o2=${ip#*.}; o2=${o2%%.*}
    (( o1 <= 255 && o2 <= 255 )) || return 1
    (( o1 == 10 )) && return 1                              # 10.0.0.0/8
    (( o1 == 172 && o2 >= 16 && o2 <= 31 )) && return 1     # 172.16.0.0/12
    (( o1 == 192 && o2 == 168 )) && return 1                # 192.168.0.0/16
    (( o1 == 100 && o2 >= 64 && o2 <= 127 )) && return 1    # 100.64.0.0/10 CGNAT
    (( o1 == 127 )) && return 1                             # 127.0.0.0/8 环回
    (( o1 == 169 && o2 == 254 )) && return 1                # 169.254.0.0/16 链路本地
    (( o1 == 0 || o1 == 255 )) && return 1
    return 0
}

# 判断是否为公网 IPv6（排除环回 ::1 / 未指定 :: / 链路本地 fe80 / ULA fc00::/7）
_is_public_ipv6() {
    local ip="${1,,}"
    [[ "$ip" == *:* ]] || return 1
    case "$ip" in
        ::1|::) return 1 ;;
        fe8*:*|fe9*:*|fea*:*|feb*:*) return 1 ;;   # fe80::/10 链路本地
        fc*:*|fd*:*) return 1 ;;                    # fc00::/7 ULA
    esac
    return 0
}

# 读取 Cloudflare trace 里的出口 IP（全球 CDN，抗封锁）；$1 = 4 或 6
_cf_trace_ip() {
    curl -"$1" -sf --connect-timeout 5 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null \
        | awk -F= '/^ip=/{print $2}' | tr -d '[:space:]'
}

get_ipv4() {
    [[ -n "$_CACHED_IPV4" ]] && { echo "$_CACHED_IPV4"; return; }
    local result="" cand u

    # 1. Cloudflare trace（首选，全球 CDN，最稳）
    cand=$(_cf_trace_ip 4)
    _is_public_ipv4 "$cand" && result="$cand"

    # 2. 外部 HTTP 回显服务（多源，任一可用即可）
    if [[ -z "$result" ]]; then
        for u in ip.sb ifconfig.me api.ipify.org icanhazip.com ipinfo.io/ip checkip.amazonaws.com ident.me; do
            cand=$(curl -4 -sf --connect-timeout 5 "$u" 2>/dev/null | tr -d '[:space:]')
            if _is_public_ipv4 "$cand"; then result="$cand"; break; fi
        done
    fi

    # 3. DNS 方式（不走 HTTP，更难被墙）
    if [[ -z "$result" ]] && check_cmd dig; then
        cand=$(dig -4 +short +time=3 +tries=1 myip.opendns.com @resolver1.opendns.com 2>/dev/null | tr -d '[:space:]')
        _is_public_ipv4 "$cand" || \
            cand=$(dig -4 +short +time=3 +tries=1 txt o-o.myaddr.l.google.com @ns1.google.com 2>/dev/null | tr -d '"[:space:]')
        _is_public_ipv4 "$cand" && result="$cand"
    fi

    # 4. 本机接口地址，仅当为公网地址时才采用（NAT 直挂公网场景）
    if [[ -z "$result" ]]; then
        for cand in $(hostname -I 2>/dev/null); do
            if _is_public_ipv4 "$cand"; then result="$cand"; break; fi
        done
    fi

    [[ -n "$result" ]] && _CACHED_IPV4="$result"
    echo "$result"
}

get_ipv6() {
    [[ -n "$_CACHED_IPV6" ]] && { echo "$_CACHED_IPV6"; return; }
    local result="" cand u

    # 1. Cloudflare trace（首选，全球 CDN，最稳）
    cand=$(_cf_trace_ip 6)
    _is_public_ipv6 "$cand" && result="$cand"

    # 2. 外部 HTTP 回显服务
    if [[ -z "$result" ]]; then
        for u in ip.sb ifconfig.me api6.ipify.org icanhazip.com ident.me; do
            cand=$(curl -6 -sf --connect-timeout 5 "$u" 2>/dev/null | tr -d '[:space:]')
            if _is_public_ipv6 "$cand"; then result="$cand"; break; fi
        done
    fi

    # 3. 本机接口上的全球单播 IPv6（排除环回 ::1 / 链路本地 fe80 / ULA）
    if [[ -z "$result" ]]; then
        while read -r cand; do
            cand=${cand%%/*}
            if _is_public_ipv6 "$cand"; then result="$cand"; break; fi
        done < <(ip -6 addr show scope global 2>/dev/null | awk '/inet6/{print $2}')
    fi

    [[ -n "$result" ]] && _CACHED_IPV6="$result"
    echo "$result"
}

ipv4_is_nat() {
    local public_ip="$1" source_ip
    _is_public_ipv4 "$public_ip" || return 1
    source_ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<NF;i++) if ($i=="src") {print $(i+1); exit}}')
    [[ -n "$source_ip" && "$source_ip" != "$public_ip" ]]
}

urlencode() {
    local s="$1" i c o=""
    for ((i=0; i<${#s}; i++)); do
        c="${s:i:1}"
        case "$c" in
            [-_.~a-zA-Z0-9]) o+="$c" ;;
            *) printf -v c '%%%02x' "'$c"; o+="$c" ;;
        esac
    done
    echo "$o"
}

# 构造 vless:// 分享链接；IPv6 地址自动加 []
build_vless_link() {
    local uuid="$1" server="$2" port="$3" sni="$4" public_key="$5" short_id="$6" name="$7"
    if [[ "$server" == *":"* ]]; then
        server="[${server}]"
    fi
    local enc_name
    enc_name=$(urlencode "$name")
    echo "vless://${uuid}@${server}:${port}?encryption=none&security=reality&type=tcp&sni=${sni}&fp=chrome&pbk=${public_key}&sid=${short_id}&flow=xtls-rprx-vision#${enc_name}"
}

# 如果安装了 qrencode，输出二维码
show_qr() {
    local link="$1"
    if check_cmd qrencode; then
        echo ""
        _info "二维码 (手机扫描):"
        qrencode -t ANSIUTF8 "$link" 2>/dev/null || qrencode -t ANSI "$link" 2>/dev/null || true
    fi
}

#═══════════════════════════════════════════════════════════════════════════════
#  数据库 (JSON)
#═══════════════════════════════════════════════════════════════════════════════

init_db() {
    mkdir -p "$CFG" "$USERS_DIR" || return 1
    [[ -f "$DB_FILE" ]] && return 0
    local now
    now=$(date '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S')
    cat > "$DB_FILE" <<EOF
{
  "version": "${VERSION}",
  "port": 443,
  "sni": "",
  "dest": "",
  "private_key": "",
  "public_key": "",
  "short_id": "",
  "default_uuid": "",
  "users": {},
  "meta": {"created": "$now", "updated": "$now"}
}
EOF
}

_db_apply() {
    [[ -f "$DB_FILE" ]] || init_db || return 1
    local tmp
    tmp=$(mktemp "$CFG/.db.XXXXXX") || return 1
    if jq "$@" "$DB_FILE" > "$tmp"; then
        mv "$tmp" "$DB_FILE" || { rm -f "$tmp"; return 1; }
        return 0
    fi
    rm -f "$tmp"
    return 1
}

db_get_field() {
    [[ ! -f "$DB_FILE" ]] && return 1
    jq -r "$1 // empty" "$DB_FILE" 2>/dev/null
}

db_set_field() {
    _db_apply "$@"
}

#═══════════════════════════════════════════════════════════════════════════════
#  包管理 (apk / dnf / yum / apt)
#═══════════════════════════════════════════════════════════════════════════════

pkg_refresh() {
    case "$PKG_MGR" in
        apk) apk update -q >/dev/null 2>&1 ;;
        dnf) dnf makecache -q >/dev/null 2>&1 ;;
        yum) yum makecache -q >/dev/null 2>&1 ;;
        apt) apt-get update -qq >/dev/null 2>&1 ;;
    esac
}

pkg_install() {
    [[ $# -eq 0 ]] && return 0
    case "$PKG_MGR" in
        apk) apk add --no-cache "$@" >/dev/null 2>&1 ;;
        dnf) dnf install -y -q "$@" >/dev/null 2>&1 ;;
        yum) yum install -y -q "$@" >/dev/null 2>&1 ;;
        apt) DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@" >/dev/null 2>&1 ;;
        *) return 1 ;;
    esac
}

# 可选依赖逐个安装：某个包在仓库里不存在时不会拖垮整批
pkg_install_optional() {
    local p
    for p in "$@"; do
        pkg_install "$p" || true
    done
}

#═══════════════════════════════════════════════════════════════════════════════
#  服务管理 (openrc / systemd)
#═══════════════════════════════════════════════════════════════════════════════

svc() {
    local cmd="$1" name="$2"
    case "$SVC_MGR" in
        openrc)  rc-service "$name" "$cmd" 2>/dev/null ;;
        systemd) systemctl "$cmd" "$name" 2>/dev/null ;;
        *)       return 1 ;;
    esac
}

# 判断服务是否正在运行（rc-service status 退出码 / systemctl is-active）
is_service_active() {
    local name="$1"
    case "$SVC_MGR" in
        openrc)  rc-service "$name" status >/dev/null 2>&1 ;;
        systemd) systemctl is-active --quiet "$name" 2>/dev/null ;;
        *)       return 1 ;;
    esac
}

# openrc 的 restart 不能作用于未启动的服务，统一成 restart-or-start
svc_up() {
    local name="$1"
    if is_service_active "$name"; then
        svc restart "$name"
    else
        svc start "$name"
    fi
}

create_xray_service() {
    if [[ "$SVC_MGR" == "openrc" ]]; then
        # 有 supervise-daemon 就托管进程（崩溃自动拉起），否则退化为后台运行
        if command -v supervise-daemon >/dev/null 2>&1; then
            cat > /etc/init.d/vless-reality <<'EOF' || return 1
#!/sbin/openrc-run
name="vless-reality"
description="VLESS Reality CF Proxy"
command="/usr/local/bin/xray"
command_args="run -c /etc/vless-reality-cf/xray.json"
command_user="root"
supervisor="supervise-daemon"
respawn_delay=5
respawn_max=0
pidfile="/run/${RC_SVCNAME}.pid"
output_log="/var/log/vless-reality.log"
error_log="/var/log/vless-reality.log"

depend() {
    need net
    after firewall
}
EOF
        else
            cat > /etc/init.d/vless-reality <<'EOF' || return 1
#!/sbin/openrc-run
name="vless-reality"
description="VLESS Reality CF Proxy"
command="/usr/local/bin/xray"
command_args="run -c /etc/vless-reality-cf/xray.json"
command_user="root"
command_background="yes"
pidfile="/run/vless-reality.pid"
output_log="/var/log/vless-reality.log"
error_log="/var/log/vless-reality.log"

depend() {
    need net
    after firewall
}
EOF
        fi
        chmod +x /etc/init.d/vless-reality || return 1
        rc-update add vless-reality default || return 1
    elif [[ "$SVC_MGR" == "systemd" ]]; then
        cat > /etc/systemd/system/vless-reality.service <<'EOF' || return 1
[Unit]
Description=VLESS Reality CF Proxy
After=network.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/xray run -c /etc/vless-reality-cf/xray.json
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload || return 1
        systemctl enable vless-reality || return 1
    else
        _err "不支持的服务管理器: $SVC_MGR"
        return 1
    fi
    _ok "服务已创建"
}

restart_xray() {
    "$XRAY_BIN" run -test -c "$XRAY_CONFIG" || return 1
    svc_up vless-reality || { _err "Xray 启动或重启失败"; return 1; }
    sleep 1
    is_service_active vless-reality || { _err "Xray 重启后状态异常"; return 1; }
    _ok "Xray 已重启"
}

apply_xray_changes() {
    if generate_xray_config && restart_xray; then
        return 0
    fi
    # 撤销凭据失败时不能继续用旧配置提供访问。
    svc stop vless-reality || _err "停止 Xray 失败，请立即人工撤销访问"
    _err "配置未生效，已请求停止 Xray，请检查日志后重试"
    return 1
}

start_proxy_services() {
    nginx -t || return 1
    create_nginx_service || return 1
    create_xray_service || return 1
    restart_xray || { svc stop vless-reality; return 1; }
    restart_nginx || return 1
}

#═══════════════════════════════════════════════════════════════════════════════
#  依赖安装
#═══════════════════════════════════════════════════════════════════════════════

install_deps() {
    _info "安装基础依赖 (包管理器: $PKG_MGR)..."
    pkg_refresh || return 1

    local base="curl jq ca-certificates unzip"
    case "$PKG_MGR" in
        apk)
            pkg_install $base openssl coreutils iproute2 || return 1
            pkg_install_optional libqrencode-tools
            ;;
        dnf|yum)
            # CentOS 7 的 jq / qrencode / nginx 都在 EPEL
            pkg_install_optional epel-release
            pkg_install $base openssl coreutils iproute || return 1
            pkg_install_optional qrencode
            ;;
        apt)
            pkg_install $base openssl coreutils iproute2 || return 1
            pkg_install_optional qrencode
            ;;
        *)
            _warn "未知包管理器，请手动安装: curl jq openssl unzip"
            ;;
    esac

    local missing="" c
    for c in curl jq unzip openssl ip ss install timeout; do
        check_cmd "$c" || missing="$missing $c"
    done
    if [[ -n "$missing" ]]; then
        _warn "缺少关键依赖:$missing"
        return 1
    fi
    _ok "依赖安装完成"
}

#═══════════════════════════════════════════════════════════════════════════════
#  Nginx 安装 + SNI 分流 (防 CF CDN 流量被盗刷)
#
#  原理: https://github.com/XTLS/Xray-core/issues/2360
#  Reality dest 设为 CF CDN 域名时，非 Reality 流量会被转发到 CF Edge IP，
#  导致 VPS 变成免费 CF CDN 中转节点。
#  解决方案: Nginx stream 层 SNI 分流，只允许目标 SNI 的流量进入 Xray，
#  其他 SNI 直接黑洞，从根源阻断薅羊毛。
#═══════════════════════════════════════════════════════════════════════════════

# 查找 nginx stream 动态模块 .so
find_nginx_stream_module() {
    local p
    for p in /usr/lib/nginx/modules/ngx_stream_module.so \
             /usr/lib64/nginx/modules/ngx_stream_module.so \
             /usr/share/nginx/modules/ngx_stream_module.so \
             /etc/nginx/modules/ngx_stream_module.so; do
        if [[ -f "$p" ]]; then echo "$p"; return 0; fi
    done
    return 1
}

# stream 可用 = 静态编译，或动态编译且 .so 存在
nginx_has_stream() {
    local v
    v=$(nginx -V 2>&1) || return 1
    case "$v" in
        *--with-stream=dynamic*) find_nginx_stream_module >/dev/null 2>&1 ;;
        *--with-stream*)         return 0 ;;
        *)                       return 1 ;;
    esac
}

install_nginx() {
    if [[ "$SVC_MGR" == openrc && ! -x /etc/init.d/nginx ]]; then
        pkg_install nginx-openrc || return 1
    fi
    if check_cmd nginx && nginx_has_stream; then
        _ok "Nginx 已安装 (含 stream 模块)"
        return 0
    fi

    _info "安装 Nginx (含 stream 模块用于 SNI 分流)..."
    case "$PKG_MGR" in
        apk)
            pkg_install nginx nginx-mod-stream || return 1
            ;;
        dnf|yum)
            pkg_install nginx || return 1
            # RHEL8+/CentOS8+ AppStream 提供 nginx-mod-stream；CentOS7(EPEL) 为静态编译
            pkg_install_optional nginx-mod-stream
            ;;
        apt)
            pkg_install nginx libnginx-mod-stream || pkg_install nginx
            ;;
    esac

    if check_cmd nginx && nginx_has_stream; then
        _ok "Nginx 安装完成"
        return 0
    fi
    if check_cmd nginx; then
        _err "Nginx 缺少 stream 模块，SNI 分流无法工作"
        _warn "Alpine: apk add nginx-mod-stream  Debian: apt install libnginx-mod-stream"
        return 1
    fi
    _err "Nginx 安装失败"
    return 1
}

generate_nginx_sni_config() (
    local sni port backup existed=false success=false
    sni=$(db_get_field '.sni')
    port=$(db_get_field '.port')
    [[ "$sni" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*\.)+[a-zA-Z]{2,}$ ]] || { _err "SNI 格式无效"; return 1; }
    valid_port "$port" || { _err "监听端口无效"; return 1; }
    ensure_stream_module_loaded || return 1
    mkdir -p "$(dirname "$NGINX_SNI_CONF")" || return 1
    backup=$(mktemp "${NGINX_SNI_CONF}.XXXXXX") || return 1
    if [[ -f "$NGINX_SNI_CONF" ]]; then
        cp -p "$NGINX_SNI_CONF" "$backup" || { rm -f "$backup"; return 1; }
        existed=true
    fi
    trap 'if [[ "$success" != true ]]; then
        if [[ "$existed" == true ]]; then cat "$backup" > "$NGINX_SNI_CONF"; else rm -f "$NGINX_SNI_CONF"; fi
    fi; rm -f "$backup"' EXIT

    cat > "$NGINX_SNI_CONF" <<EOF
# VLESS Reality SNI 分流 - 防 CF CDN 流量被盗刷
# 只有 SNI 匹配 $sni 的流量才转发到 Xray (127.0.0.1:$XRAY_INTERNAL_PORT)
# 其他 SNI 一律黑洞，防止 VPS 被当作免费 CF CDN 中转
# 参考: https://github.com/XTLS/Xray-core/issues/2360

# SNI 映射表: 匹配目标域名 → Xray，其他 → 丢弃
map \$ssl_preread_server_name \$sni_backend {
    $sni              xray_backend;
    default           drop_backend;
}

# 后端定义
upstream xray_backend {
    server 127.0.0.1:$XRAY_INTERNAL_PORT;
}

# 黑洞后端 (连接直接关闭，不消耗流量)
upstream drop_backend {
    server 127.0.0.1:1;  # 无效地址，连接立即失败
}

# 监听 443 端口，SSL 预读 SNI，不终止 TLS
server {
    listen $port;
    listen [::]:$port;
    ssl_preread on;
    proxy_protocol off;
    proxy_pass \$sni_backend;

    # 超时设置
    proxy_timeout 300s;
    proxy_connect_timeout 5s;
}
EOF

    [[ $? -eq 0 ]] || return 1
    ensure_nginx_stream_include || return 1
    success=true
    _ok "Nginx SNI 分流配置已生成: $NGINX_SNI_CONF"
)

ensure_stream_module_loaded() {
    local dump build stream_module backup
    build=$(nginx -V 2>&1) || return 1
    [[ "$build" == *--with-stream=dynamic* ]] || return 0
    dump=$(nginx -T) || { _err "现有 Nginx 配置无效，请先修复"; return 1; }
    if printf '%s\n' "$dump" | grep -Eq '^[[:space:]]*load_module[[:space:]]+[^;#]*ngx_stream_module\.so'; then
        return 0
    fi
    stream_module=$(find_nginx_stream_module) || { _err "未找到 stream 模块"; return 1; }
    backup=$(mktemp /etc/nginx/.module-backup.XXXXXX) || return 1
    cp -p /etc/nginx/nginx.conf "$backup" || { rm -f "$backup"; return 1; }
    if ! { printf 'load_module "%s";\n' "$stream_module"; cat "$backup"; } > /etc/nginx/nginx.conf || ! nginx -t; then
        cat "$backup" > /etc/nginx/nginx.conf
        rm -f "$backup"
        return 1
    fi
    rm -f "$backup"
}

ensure_nginx_stream_include() {
    local dump f target="" lineno="" backup
    dump=$(nginx -T) || return 1
    if printf '%s\n' "$dump" | grep -Fxq "# configuration file $NGINX_SNI_CONF:"; then
        return 0
    fi

    # nginx -T 只列出实际加载的文件，不能扫描未被 include 的配置目录。
    while IFS= read -r f; do
        lineno=$(awk '
            {line=$0; sub(/#.*/, "", line)}
            line ~ /^[[:space:]]*stream[[:space:]]*\{/ {print NR; exit}
            line ~ /^[[:space:]]*stream[[:space:]]*$/ {pending=1; next}
            pending && line ~ /^[[:space:]]*\{/ {print NR; exit}
            line !~ /^[[:space:]]*$/ {pending=0}
        ' "$f") || return 1
        if [[ -n "$lineno" ]]; then target="$f"; break; fi
    done < <(printf '%s\n' "$dump" | sed -n 's/^# configuration file \(.*\):$/\1/p')

    [[ -n "$target" ]] || target=/etc/nginx/nginx.conf
    backup=$(mktemp /etc/nginx/.stream-backup.XXXXXX) || return 1
    cp -p "$target" "$backup" || { rm -f "$backup"; return 1; }
    if [[ -n "$lineno" ]]; then
        awk -v n="$lineno" 'NR==n {sub(/\{/, "{\n    include /etc/nginx/stream.conf.d/*.conf;\n")} {print}' \
            "$backup" > "$target" || { cat "$backup" > "$target"; rm -f "$backup"; return 1; }
    else
        printf '\nstream {\n    include /etc/nginx/stream.conf.d/*.conf;\n}\n' >> "$target" || {
            cat "$backup" > "$target"; rm -f "$backup"; return 1;
        }
    fi
    if ! dump=$(nginx -T) || ! printf '%s\n' "$dump" | grep -Fxq "# configuration file $NGINX_SNI_CONF:"; then
        cat "$backup" > "$target"
        rm -f "$backup"
        _err "Nginx 未正确加载 SNI 配置，已恢复修改的文件"
        return 1
    fi
    rm -f "$backup"
    _ok "Nginx 已加载 SNI 配置"
}

create_nginx_service() {
    case "$SVC_MGR" in
        openrc)  rc-update add nginx default 2>/dev/null ;;
        systemd) systemctl enable nginx ;;
        *) _err "不支持的服务管理器: $SVC_MGR"; return 1 ;;
    esac
}

restart_nginx() {
    nginx -t || { _err "Nginx 配置校验失败，未重启服务"; return 1; }
    svc_up nginx || { _err "Nginx 启动或重启失败"; return 1; }
    sleep 1
    is_service_active nginx || { _err "Nginx 重启后状态异常"; return 1; }
    _ok "Nginx 已重启 (SNI 分流生效)"
}

valid_port() {
    [[ "$1" =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 && 10#$1 != XRAY_INTERNAL_PORT ))
}

configure_selinux_proxy() {
    check_cmd getenforce || return 0
    [[ "$(getenforce)" == "Enforcing" ]] || return 0
    local port="$1" ports relay confirm p
    local missing_ports=()
    if ! check_cmd semanage || ! check_cmd getsebool || ! check_cmd setsebool; then
        _err "SELinux Enforcing 需要 semanage/getsebool/setsebool；请安装 policycoreutils-python-utils（CentOS 7 为 policycoreutils-python）"
        return 1
    fi
    ports=$(semanage port -l) || return 1
    relay=$(getsebool httpd_can_network_relay) || return 1
    for p in "$port" "$XRAY_INTERNAL_PORT"; do
        if ! printf '%s\n' "$ports" | awk -v p="$p" '
            $1=="http_port_t" && $2=="tcp" {
                gsub(/,/, " ")
                for (i=3;i<=NF;i++) {
                    split($i,r,"-")
                    if (p==r[1] || (r[2]!="" && p>=r[1] && p<=r[2])) found=1
                }
            }
            END {exit !found}
        '; then
            missing_ports+=("$p")
        fi
    done
    if [[ ${#missing_ports[@]} -eq 0 && "$relay" == *"--> on" ]]; then return 0; fi

    _warn "需标记监听/后端端口为 http_port_t 并启用 httpd_can_network_relay；该布尔值影响所有 httpd_t 服务"
    read -rp "  是否允许上述 SELinux 策略变更？[y/N]: " confirm || return 1
    [[ "$confirm" == [yY] ]] || { _err "未授权 SELinux 策略变更，停止安装"; return 1; }
    for p in "${missing_ports[@]}"; do
        semanage port -a -t http_port_t -p tcp "$p" || {
            _err "SELinux 端口 $p 设置失败；不会覆盖其他服务已有的端口类型"
            return 1
        }
    done
    if [[ "$relay" != *"--> on" ]]; then
        setsebool -P httpd_can_network_relay on || return 1
    fi
}

open_firewall_port() {
    local port="$1"
    valid_port "$port" || { _err "无效端口（不能使用内部端口 $XRAY_INTERNAL_PORT）"; return 1; }
    configure_selinux_proxy "$port" || return 1
    if check_cmd firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then
        firewall-cmd --add-port="${port}/tcp" && \
            firewall-cmd --permanent --add-port="${port}/tcp" || return 1
    fi
    if check_cmd ufw && LC_ALL=C ufw status | grep -q "Status: active"; then
        ufw allow "${port}/tcp" || return 1
    fi
    return 0
}

#═══════════════════════════════════════════════════════════════════════════════
#  Xray 核心安装
#═══════════════════════════════════════════════════════════════════════════════

install_xray() (
    local version="$XRAY_VERSION" output ver arch xarch tmp data
    if [[ -x "$XRAY_BIN" ]] && output=$("$XRAY_BIN" version); then
        ver=$(printf '%s\n' "$output" | awk 'NR==1 {print $2}')
        if [[ "${ver#v}" == "$version" ]]; then
            _ok "Xray 已安装: v${version}"
            return 0
        fi
    fi

    arch=$(uname -m)
    case "$arch" in
        x86_64|amd64) xarch="64" ;;
        aarch64|arm64) xarch="arm64-v8a" ;;
        armv7l) xarch="arm32-v7a" ;;
        armv6l) xarch="arm32-v6" ;;
        *) _err "不支持的架构: $arch"; return 1 ;;
    esac

    mkdir -p "$(dirname "$XRAY_BIN")" || return 1
    tmp=$(mktemp -d "$(dirname "$XRAY_BIN")/.xray.XXXXXX") || return 1
    trap 'rm -rf "$tmp"' EXIT
    local url="https://github.com/XTLS/Xray-core/releases/download/v${version}/Xray-linux-${xarch}.zip"
    _info "下载 Xray v${version}"
    curl -fsSL --connect-timeout "$CURL_TIMEOUT" --max-time "$CURL_TIMEOUT_DOWNLOAD" \
        -o "$tmp/xray.zip" "$url" || { _err "Xray 下载失败"; return 1; }
    unzip -oq "$tmp/xray.zip" -d "$tmp" || return 1
    chmod 755 "$tmp/xray" || return 1
    output=$("$tmp/xray" version) || { _err "下载的 Xray 无法运行，旧版本未修改"; return 1; }
    ver=$(printf '%s\n' "$output" | awk 'NR==1 {print $2}')
    [[ "${ver#v}" == "$version" ]] || { _err "下载版本与指定版本不一致"; return 1; }

    mkdir -p /usr/local/share/xray || return 1
    for data in geoip.dat geosite.dat; do
        if [[ ! -f "/usr/local/share/xray/$data" && -f "$tmp/$data" ]]; then
            install -m 644 "$tmp/$data" "/usr/local/share/xray/$data" || return 1
        fi
    done
    if [[ -f "$XRAY_CONFIG" ]]; then
        XRAY_LOCATION_ASSET=/usr/local/share/xray "$tmp/xray" run -test -c "$XRAY_CONFIG" || {
            _err "指定版本无法加载现有配置，旧版本未修改"
            return 1
        }
    fi

    # 同文件系统原子替换，不覆盖正在执行的 inode；保留上一版本供恢复。
    if [[ -f "$XRAY_BIN" ]]; then
        cp -p "$XRAY_BIN" "$tmp/previous" && mv -f "$tmp/previous" "$XRAY_BIN.previous" || return 1
    fi
    mv -f "$tmp/xray" "$XRAY_BIN" || return 1
    if check_cmd restorecon && ! restorecon "$XRAY_BIN"; then
        [[ -f "$XRAY_BIN.previous" ]] && mv -f "$XRAY_BIN.previous" "$XRAY_BIN"
        _err "Xray 安全标签恢复失败"
        return 1
    fi
    _ok "Xray v${version} 已安装"
)

#═══════════════════════════════════════════════════════════════════════════════
#  密钥生成
#═══════════════════════════════════════════════════════════════════════════════

gen_keys() {
    _info "生成 Reality 密钥对..."
    local keys
    keys=$("$XRAY_BIN" x25519) || return 1

    # 兼容新旧输出格式:
    #   旧版: "Private key: xxx" / "Public key: xxx"
    #   新版: "PrivateKey: xxx" / "Password (PublicKey): xxx"
    local private_key public_key
    private_key=$(echo "$keys" | grep -i "private" | head -1 | awk '{print $NF}')
    public_key=$(echo "$keys" | grep -i "public" | head -1 | awk '{print $NF}')

    if [[ -z "$private_key" || -z "$public_key" ]]; then
        _err "密钥生成失败 (xray x25519 输出异常)"
        return 1
    fi

    (umask 077; printf '%s\n' "$private_key" > "$CFG/private.key") || return 1
    printf '%s\n' "$public_key" > "$CFG/public.key" || return 1
    chmod 600 "$CFG/private.key" || return 1
    _ok "密钥对已生成（私钥不输出到终端）"
}

gen_short_id() {
    local sid
    sid=$(head -c 8 /dev/urandom 2>/dev/null | od -A n -t x1 | tr -d ' \n' | head -c 16)
    if [[ -z "$sid" || ${#sid} -lt 16 ]]; then
        sid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null | tr -d '-' | head -c 16)
    fi
    if [[ -z "$sid" || ${#sid} -lt 16 ]]; then
        sid=$(python3 -c "import secrets; print(secrets.token_hex(8))" 2>/dev/null)
    fi
    echo "$sid"
}

# 生成多个 shortId (空格分隔)
gen_short_ids() {
    local count="${1:-4}"
    local ids=""
    for ((i=0; i<count; i++)); do
        local sid
        sid=$(gen_short_id)
        [[ -n "$sid" ]] && ids="${ids}${ids:+ }${sid}"
    done
    echo "$ids"
}

# 生成随机邮箱 (8位随机字母数字)
gen_random_email() {
    local chars="abcdefghijklmnopqrstuvwxyz0123456789"
    local name=""
    for ((i=0; i<8; i++)); do
        name+="${chars:RANDOM%${#chars}:1}"
    done
    echo "$name"
}

# 生成随机高端口 (10000-65535, 避开已占用)
gen_random_port() {
    local port attempts=0
    while ((attempts < 20)); do
        port=$((RANDOM % 55536 + 10000))
        # 检查端口是否被占用
        if ! ss -tlnp 2>/dev/null | grep -q ":${port} "; then
            echo "$port"
            return 0
        fi
        ((attempts++))
    done
    # fallback: 用固定值
    echo "10443"
}

gen_uuid() {
    if check_cmd xray; then
        "$XRAY_BIN" uuid 2>/dev/null
    else
        cat /proc/sys/kernel/random/uuid 2>/dev/null || python3 -c "import uuid; print(uuid.uuid4())" 2>/dev/null
    fi
}

#═══════════════════════════════════════════════════════════════════════════════
#  CF CDN 域名推荐 + SNI 校验
#═══════════════════════════════════════════════════════════════════════════════

# 推荐的 CF CDN 域名列表
# 选择原则：
#   1. 部署在 Cloudflare CDN 上 (IP 是 CF 的 CDN IP)
#   2. 在大陆可访问
#   3. 支持 TLS 1.3
#   4. 不是太热门/敏感的域名
readonly CF_CDN_DOMAINS=(
    # --- Cloudflare 自家服务 ---
    "speed.cloudflare.com"
    "www.cloudflare.com"
    "dash.cloudflare.com"
    "one.one.one.one"
    # --- Apple (CF CDN 子域名) ---
    "apps.apple.com"
    "developer.apple.com"
    "support.apple.com"
    "store.apple.com"
    "music.apple.com"
    "tv.apple.com"
    "maps.apple.com"
    # --- 知名站点 (CF CDN) ---
    "www.digitalocean.com"
    "www.heroku.com"
    "codepen.io"
    "www.shopify.com"
    "www.discord.com"
    "cdn.discordapp.com"
    # --- CF Pages 通用站点 ---
    "workers.cloudflare.com"
    "pages.cloudflare.com"
)

# 验证域名是否部署在 CF CDN 上
check_cf_cdn() {
    local domain="$1"
    local dns_ip=""

    # 获取域名 DNS 解析的 IP
    if check_cmd dig; then
        dns_ip=$(dig +short "$domain" @1.1.1.1 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -1)
    fi
    if [[ -z "$dns_ip" ]] && check_cmd nslookup; then
        dns_ip=$(nslookup "$domain" 1.1.1.1 2>/dev/null | awk '/^Address:/{print $2}' | grep -v "1.1.1.1" | head -1)
    fi
    if [[ -z "$dns_ip" ]]; then
        dns_ip=$(getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | head -1)
    fi

    if [[ -z "$dns_ip" ]]; then
        _warn "无法解析域名 DNS IP"
        return 1
    fi

    # 检查 IP 是否属于 Cloudflare CDN 段
    # CF CDN IP 段 (主要): 104.16.0.0/12, 172.64.0.0/13, 162.158.0.0/15,
    #                       198.41.128.0/17, 108.162.192.0/18, 173.245.48.0/20
    local is_cf=false

    # 简单的前两段匹配
    local ip_prefix
    ip_prefix=$(echo "$dns_ip" | cut -d. -f1,2)
    local ip_oct1 ip_oct2 ip_oct3
    ip_oct1=$(echo "$dns_ip" | cut -d. -f1)
    ip_oct2=$(echo "$dns_ip" | cut -d. -f2)
    ip_oct3=$(echo "$dns_ip" | cut -d. -f3)

    # 104.16.0.0/12 -> 104.16.x.x ~ 104.31.x.x
    [[ "$ip_oct1" == "104" && "$ip_oct2" -ge 16 && "$ip_oct2" -le 31 ]] && is_cf=true
    # 172.64.0.0/13 -> 172.64.x.x ~ 172.71.x.x
    [[ "$ip_oct1" == "172" && "$ip_oct2" -ge 64 && "$ip_oct2" -le 71 ]] && is_cf=true
    # 162.158.0.0/15 -> 162.158.x.x ~ 162.159.x.x
    [[ "$ip_oct1" == "162" && "$ip_oct2" -ge 158 && "$ip_oct2" -le 159 ]] && is_cf=true
    # 198.41.128.0/17
    [[ "$ip_oct1" == "198" && "$ip_oct2" == "41" ]] && is_cf=true
    # 108.162.192.0/18
    [[ "$ip_oct1" == "108" && "$ip_oct2" == "162" ]] && is_cf=true
    # 173.245.48.0/20
    [[ "$ip_oct1" == "173" && "$ip_oct2" == "245" ]] && is_cf=true
    # 141.101.64.0/18
    [[ "$ip_oct1" == "141" && "$ip_oct2" == "101" ]] && is_cf=true
    # 190.93.240.0/20
    [[ "$ip_oct1" == "190" && "$ip_oct2" == "93" ]] && is_cf=true
    # 188.114.96.0/20
    [[ "$ip_oct1" == "188" && "$ip_oct2" == "114" ]] && is_cf=true
    # 197.234.240.0/22
    [[ "$ip_oct1" == "197" && "$ip_oct2" == "234" ]] && is_cf=true
    # 131.0.72.0/22
    [[ "$ip_oct1" == "131" && "$ip_oct2" == "0" ]] && is_cf=true

    if [[ "$is_cf" == "true" ]]; then
        _ok "域名 $domain 解析到 CF CDN IP: $dns_ip"
        return 0
    else
        _warn "域名 $domain 解析到非 CF CDN IP: $dns_ip"
        return 1
    fi
}

# SNI 校验：验证域名的 TLS 证书是否有效，以及是否支持 TLS 1.3
check_sni_validity() {
    local domain="$1"
    local port="${2:-443}"

    _info "SNI 校验: $domain:$port"

    # 1. 检查 DNS 解析
    _info "检查 DNS 解析..."
    if check_cf_cdn "$domain"; then
        _ok "DNS: 域名在 CF CDN 上"
    else
        _warn "DNS: 域名可能不在 CF CDN 上 (但仍可使用)"
    fi

    # 2. TLS 连接测试 - 获取证书信息
    _info "检查 TLS 证书..."
    local cert_info
    cert_info=$(echo | openssl s_client -connect "$domain:$port" \
        -servername "$domain" \
        -tls1_3 2>/dev/null)

    if [[ -z "$cert_info" ]]; then
        # 回退到不指定 TLS 版本
        cert_info=$(echo | openssl s_client -connect "$domain:$port" \
            -servername "$domain" 2>/dev/null)
    fi

    if [[ -z "$cert_info" ]]; then
        _err "无法建立 TLS 连接"
        return 1
    fi

    # 3. 检查是否支持 TLS 1.3
    local tls_version
    tls_version=$(echo "$cert_info" | grep "Protocol  :" | awk '{print $3}')
    if [[ "$tls_version" == "TLSv1.3" ]]; then
        _ok "TLS 版本: TLSv1.3 ✓ (Reality 必需)"
    elif [[ -n "$tls_version" ]]; then
        _warn "TLS 版本: $tls_version (建议 TLSv1.3)"
    else
        _warn "无法确定 TLS 版本"
    fi

    # 4. 检查证书 Subject / CN
    local subject issuer
    subject=$(echo "$cert_info" | openssl x509 -noout -subject 2>/dev/null | sed 's/subject=//')
    issuer=$(echo "$cert_info" | openssl x509 -noout -issuer 2>/dev/null | sed 's/issuer=//')
    _info "证书 Subject: $subject"
    _info "证书 Issuer:  $issuer"

    # 5. 检查证书有效期
    local not_after
    not_after=$(echo "$cert_info" | openssl x509 -noout -enddate 2>/dev/null | sed 's/notAfter=//')
    if [[ -n "$not_after" ]]; then
        _info "证书有效期至: $not_after"
    fi

    # 6. 检查证书是否覆盖目标域名
    local cn_match=false
    local san_match=false
    cn_match=$(echo "$cert_info" | openssl x509 -noout -subject 2>/dev/null | grep -c "$domain" || true)
    san_match=$(echo "$cert_info" | openssl x509 -noout -ext subjectAltName 2>/dev/null | grep -c "$domain" || true)

    if [[ "$cn_match" -gt 0 || "$san_match" -gt 0 ]]; then
        _ok "证书覆盖域名 $domain ✓"
    else
        _warn "证书可能不直接覆盖 $domain (通配符证书)"
    fi

    # 7. 检查 HTTP 响应 (确保站点在线)
    _info "检查 HTTP 响应..."
    local http_code
    http_code=$(curl -sf -o /dev/null -w "%{http_code}" \
        --connect-timeout "$CURL_TIMEOUT" \
        "https://$domain/" 2>/dev/null || echo "000")

    if [[ "$http_code" =~ ^[23] ]]; then
        _ok "HTTP 状态: $http_code ✓"
    elif [[ "$http_code" == "000" ]]; then
        _warn "HTTP 请求超时或被拒绝 (站点可能限制地区)"
    else
        _warn "HTTP 状态: $http_code"
    fi

    echo ""
    _ok "SNI 校验完成: $domain 可用于 Reality 伪装"
    return 0
}

# 选择 SNI 域名的交互菜单
# 结果通过全局变量 SELECTED_SNI 返回
SELECTED_SNI=""

select_sni_domain() {
    SELECTED_SNI=""
    _line
    echo -e "  ${W}偷哪个 CF CDN 域名?${NC}"
    echo ""
    local i=1
    for d in "${CF_CDN_DOMAINS[@]}"; do
        case "$d" in
            speed.cloudflare.com)  _item "$i" "$d  ${Y}← 推荐${NC}" ;;
            www.cloudflare.com)    _item "$i" "$d  ${D}(CF官网)${NC}" ;;
            dash.cloudflare.com)   _item "$i" "$d  ${D}(CF面板)${NC}" ;;
            *)                     _item "$i" "$d" ;;
        esac
        ((i++))
    done
    _item "c" "自定义域名"
    _line

    local choice
    read -rp "  请选择 [默认 1]: " choice
    choice=${choice:-1}

    if [[ "$choice" == "c" || "$choice" == "C" ]]; then
        read -rp "  输入域名: " custom_domain
        custom_domain=$(echo "$custom_domain" | xargs)
        [[ -z "$custom_domain" ]] && { _err "不能为空"; return 1; }
        [[ ! "$custom_domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*\.)+[a-zA-Z]{2,}$ ]] && { _err "格式无效"; return 1; }
        SELECTED_SNI="$custom_domain"
        return 0
    elif [[ "$choice" =~ ^[0-9]+$ && "$choice" -ge 1 && "$choice" -le ${#CF_CDN_DOMAINS[@]} ]]; then
        SELECTED_SNI="${CF_CDN_DOMAINS[$((choice-1))]}"
        return 0
    else
        _err "无效选择"
        return 1
    fi
}

#═══════════════════════════════════════════════════════════════════════════════
#  Xray 配置生成
#═══════════════════════════════════════════════════════════════════════════════

build_clients_json() {
    local user_file files=()
    for user_file in "$USERS_DIR"/*.json; do
        [[ -f "$user_file" ]] && files+=("$user_file")
    done
    if [[ ${#files[@]} -eq 0 ]]; then printf '[]\n'; return 0; fi
    jq -s '
        map(select((if has("enabled") then .enabled else true end) == true)) |
        map(if (.uuid | type) != "string" or .uuid == "" then error("用户缺少 UUID")
            else {id: .uuid, email: (.email // "user"), flow: "xtls-rprx-vision"} end)
    ' "${files[@]}"
}

generate_xray_config() {
    local port sni private_key short_ids dest
    port=$(db_get_field '.port')
    sni=$(db_get_field '.sni')
    private_key=$(cat "$CFG/private.key" 2>/dev/null || db_get_field '.private_key')
    short_ids=$(db_get_field '.short_ids')
    # 兼容旧版: 如果 short_ids 不存在，回退到 short_id
    if [[ -z "$short_ids" ]]; then
        short_ids=$(db_get_field '.short_id')
    fi
    dest="${sni}:443"

    [[ -z "$port" ]] && { _err "未设置端口"; return 1; }
    [[ -z "$sni" ]] && { _err "未设置 SNI 域名"; return 1; }
    [[ -z "$private_key" ]] && { _err "未设置私钥"; return 1; }
    [[ -z "$short_ids" ]] && { _err "未设置 shortId"; return 1; }

    # 将空格分隔的 shortIds 转为 JSON 数组
    local short_ids_json
    short_ids_json=$(echo "$short_ids" | tr ' ' '\n' | jq -R . | jq -s .)

    local clients
    clients=$(build_clients_json) || return 1
    [[ -z "$clients" ]] && { _err "无法读取用户配置"; return 1; }

    # Xray 的外部加载器即使指定格式，也会检查文件扩展名。
    local tmp_dir tmp
    tmp_dir=$(mktemp -d "$CFG/.xray.XXXXXX") || return 1
    tmp="$tmp_dir/config.json"

    jq -n \
        --argjson internal_port "$XRAY_INTERNAL_PORT" \
        --argjson clients "$clients" \
        --arg sni "$sni" \
        --arg private_key "$private_key" \
        --argjson short_ids "$short_ids_json" \
        --arg dest "$dest" \
    '{
        log: {loglevel: "warning"},
        inbounds: [{
            port: $internal_port,
            listen: "127.0.0.1",
            protocol: "vless",
            settings: {
                clients: $clients,
                decryption: "none"
            },
            streamSettings: {
                network: "tcp",
                security: "reality",
                realitySettings: {
                    show: false,
                    dest: $dest,
                    xver: 0,
                    serverNames: [$sni],
                    privateKey: $private_key,
                    shortIds: $short_ids
                }
            },
            sniffing: {enabled: true, destOverride: ["http","tls"]},
            tag: "vless-reality-in"
        }],
        outbounds: [
            {protocol: "freedom", tag: "direct"},
            {protocol: "blackhole", tag: "block"}
        ],
        routing: {
            domainStrategy: "IPIfNonMatch",
            rules: [
                {type: "field", ip: ["geoip:private"], outboundTag: "block"}
            ]
        }
    }' > "$tmp" || { rm -f "$tmp"; rmdir "$tmp_dir"; return 1; }
    chmod 600 "$tmp" || { rm -f "$tmp"; rmdir "$tmp_dir"; return 1; }

    if ! "$XRAY_BIN" run -test -format json -c "$tmp"; then
        rm -f "$tmp"
        rmdir "$tmp_dir"
        _err "Xray 配置校验失败，原配置未修改"
        return 1
    fi
    mv -f "$tmp" "$XRAY_CONFIG" || { rm -f "$tmp"; rmdir "$tmp_dir"; return 1; }
    rmdir "$tmp_dir" || return 1
    _ok "Xray 配置已生成: $XRAY_CONFIG"
}

#═══════════════════════════════════════════════════════════════════════════════
#  用户管理
#═══════════════════════════════════════════════════════════════════════════════

list_users() {
    _header
    echo -e "  ${W}用户列表${NC}"
    _line

    local count=0
    if [[ -d "$USERS_DIR" ]]; then
        for user_file in "$USERS_DIR"/*.json; do
            [[ -f "$user_file" ]] || continue
            local name email uuid enabled created
            name=$(basename "$user_file" .json)
            email=$(jq -r '.email // "user"' "$user_file")
            uuid=$(jq -r '.uuid' "$user_file")
            enabled=$(jq -r 'if has("enabled") then .enabled else true end' "$user_file")
            created=$(jq -r '.created // "N/A"' "$user_file")

            local status_icon status_text
            if [[ "$enabled" == "true" ]]; then
                status_icon="${G}●${NC}"
                status_text="启用"
            else
                status_icon="${R}●${NC}"
                status_text="禁用"
            fi

            echo -e "  $status_icon ${W}${name}${NC}  (${email})"
            echo -e "     UUID: ${D}${uuid:0:8}...${uuid: -8}${NC}"
            echo -e "     状态: $status_text | 创建: ${created}"
            _line
            ((count++))
        done
    fi

    if [[ "$count" -eq 0 ]]; then
        echo -e "  ${D}暂无用户${NC}"
    else
        echo -e "  ${D}共 ${count} 个用户${NC}"
    fi
}

add_user() {
    _header
    echo -e "  ${W}添加用户${NC}"
    _line

    local name email uuid

    read -rp "  用户名 (英文，用于标识): " name
    name=$(echo "$name" | xargs | tr ' ' '-')
    if [[ ! "$name" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$ ]]; then
        _err "用户名需为 1-64 位字母、数字、下划线或连字符，以字母或数字开头"
        return 1
    fi
    if [[ -f "$USERS_DIR/${name}.json" ]]; then
        _err "用户 $name 已存在"
        return 1
    fi

    read -rp "  邮箱 (用于客户端显示): " email
    email=$(echo "$email" | xargs)
    [[ -z "$email" ]] && email="$name"

    uuid=$(gen_uuid)
    if [[ -z "$uuid" ]]; then
        _err "UUID 生成失败"
        return 1
    fi

    local created
    created=$(date '+%Y-%m-%d %H:%M')

    # 用 jq 构建 JSON，防止用户输入特殊字符导致 JSON 注入
    jq -n \
        --arg email "$email" \
        --arg uuid "$uuid" \
        --arg created "$created" \
        '{email: $email, uuid: $uuid, enabled: true, created: $created}' \
        > "$USERS_DIR/${name}.json" || return 1

    _ok "用户 $name 已添加"
    echo -e "  ${D}UUID: $uuid${NC}"

    # 重新生成配置并重启
    apply_xray_changes || return 1
}

delete_user() {
    _header
    echo -e "  ${W}删除用户${NC}"
    _line

    if [[ ! -d "$USERS_DIR" ]] || [[ -z "$(ls -A "$USERS_DIR"/*.json 2>/dev/null)" ]]; then
        _warn "暂无用户"
        return
    fi

    # 列出用户
    local i=1
    local user_names=()
    for user_file in "$USERS_DIR"/*.json; do
        [[ -f "$user_file" ]] || continue
        local name email enabled
        name=$(basename "$user_file" .json)
        email=$(jq -r '.email // "user"' "$user_file")
        enabled=$(jq -r 'if has("enabled") then .enabled else true end' "$user_file")
        user_names+=("$name")

        local status
        [[ "$enabled" == "true" ]] && status="${G}启用${NC}" || status="${R}禁用${NC}"
        _item "$i" "$name ($email) [$status]"
        ((i++))
    done
    _item "0" "取消"
    _line

    read -rp "  选择要删除的用户: " choice
    [[ "$choice" == "0" ]] && return
    [[ ! "$choice" =~ ^[0-9]+$ ]] && { _err "无效选择"; return; }
    ((choice < 1 || choice > ${#user_names[@]})) && { _err "无效选择"; return; }

    local target="${user_names[$((choice-1))]}"
    echo -e "  ${R}确认删除用户: $target ? [y/N]:${NC}"
    read -rp "  " confirm
    [[ "$confirm" != [yY] ]] && { _info "已取消"; return; }

    rm -f "$USERS_DIR/${target}.json" || return 1
    _ok "用户 $target 已删除"

    apply_xray_changes || return 1
}

toggle_user() {
    _header
    echo -e "  ${W}启用/禁用用户${NC}"
    _line

    if [[ ! -d "$USERS_DIR" ]] || [[ -z "$(ls -A "$USERS_DIR"/*.json 2>/dev/null)" ]]; then
        _warn "暂无用户"
        return
    fi

    local i=1
    local user_names=()
    for user_file in "$USERS_DIR"/*.json; do
        [[ -f "$user_file" ]] || continue
        local name email enabled
        name=$(basename "$user_file" .json)
        email=$(jq -r '.email // "user"' "$user_file")
        enabled=$(jq -r 'if has("enabled") then .enabled else true end' "$user_file")
        user_names+=("$name")

        local status
        [[ "$enabled" == "true" ]] && status="${G}启用${NC}" || status="${R}禁用${NC}"
        _item "$i" "$name ($email) [$status]"
        ((i++))
    done
    _item "0" "取消"
    _line

    read -rp "  选择要切换的用户: " choice
    [[ "$choice" == "0" ]] && return
    [[ ! "$choice" =~ ^[0-9]+$ ]] && { _err "无效选择"; return; }
    ((choice < 1 || choice > ${#user_names[@]})) && { _err "无效选择"; return; }

    local target="${user_names[$((choice-1))]}"
    local user_file="$USERS_DIR/${target}.json"
    local current
    current=$(jq -r 'if has("enabled") then .enabled else true end' "$user_file")

    local new_state
    if [[ "$current" == "true" ]]; then
        new_state="false"
        _warn "禁用用户: $target"
    else
        new_state="true"
        _ok "启用用户: $target"
    fi

    local tmp
    tmp=$(mktemp "$USERS_DIR/.user.XXXXXX") || return 1
    jq --argjson e "$new_state" '.enabled = $e' "$user_file" > "$tmp" && \
        mv "$tmp" "$user_file" || { rm -f "$tmp"; return 1; }

    apply_xray_changes || return 1
}

show_user_links() {
    _header
    echo -e "  ${W}用户分享链接${NC}"
    _line

    local port sni short_id public_key ipv4 ipv6 default_uuid
    port=$(db_get_field '.port')
    sni=$(db_get_field '.sni')
    short_id=$(db_get_field '.short_id')
    default_uuid=$(db_get_field '.default_uuid')
    public_key=$(cat "$CFG/public.key" 2>/dev/null || db_get_field '.public_key')
    ipv4=$(get_ipv4)
    ipv6=$(get_ipv6)

    if [[ -z "$ipv4" && -z "$ipv6" ]]; then
        _warn "无法获取公网 IP，使用占位符"
        ipv4="YOUR_SERVER_IP"
    fi

    if [[ ! -d "$USERS_DIR" ]] || [[ -z "$(ls -A "$USERS_DIR"/*.json 2>/dev/null)" ]]; then
        _warn "暂无用户"
        return
    fi

    for user_file in "$USERS_DIR"/*.json; do
        [[ -f "$user_file" ]] || continue
        local name email uuid enabled
        name=$(basename "$user_file" .json)
        email=$(jq -r '.email // "user"' "$user_file")
        uuid=$(jq -r '.uuid' "$user_file")
        enabled=$(jq -r 'if has("enabled") then .enabled else true end' "$user_file")

        [[ "$enabled" != "true" ]] && continue

        echo -e "  ${W}${name}${NC} (${email})"

        if [[ -n "$ipv4" ]]; then
            local link4 name4="$name"
            [[ "$uuid" == "$default_uuid" ]] && name4="VLESS-${ipv4}"
            link4=$(build_vless_link "$uuid" "$ipv4" "$port" "$sni" "$public_key" "$short_id" "$name4")
            echo -e "  ${G}IPv4: ${link4}${NC}"
            show_qr "$link4"
        fi

        if [[ -n "$ipv6" ]]; then
            local link6 name6="$name"
            [[ "$uuid" == "$default_uuid" ]] && name6="VLESS-${ipv6}"
            link6=$(build_vless_link "$uuid" "$ipv6" "$port" "$sni" "$public_key" "$short_id" "$name6")
            echo -e "  ${G}IPv6: ${link6}${NC}"
            show_qr "$link6"
        fi

        echo ""
    done
}

# 用户管理主菜单
manage_users() {
    while true; do
        _header
        echo -e "  ${W}用户管理${NC}"
        _line

        # 统计
        local total=0 enabled_count=0
        if [[ -d "$USERS_DIR" ]]; then
            for f in "$USERS_DIR"/*.json; do
                [[ -f "$f" ]] || continue
                ((total++))
                local e
                e=$(jq -r 'if has("enabled") then .enabled else true end' "$f")
                [[ "$e" == "true" ]] && ((enabled_count++))
            done
        fi
        echo -e "  ${D}共 $total 个用户, $enabled_count 个启用${NC}"
        _line

        _item "1" "查看用户列表"
        _item "2" "添加用户"
        _item "3" "删除用户"
        _item "4" "启用/禁用用户"
        _item "5" "查看分享链接"
        _item "0" "返回"
        _line

        read -rp "  请选择: " choice
        case $choice in
            1) list_users; _pause ;;
            2) add_user; _pause ;;
            3) delete_user; _pause ;;
            4) toggle_user; _pause ;;
            5) show_user_links; _pause ;;
            0) return ;;
            *) _err "无效选择"; _pause ;;
        esac
    done
}

#═══════════════════════════════════════════════════════════════════════════════
#  安装向导
#═══════════════════════════════════════════════════════════════════════════════

do_install() {
    _header
    echo -e "  ${W}VLESS Reality 安装向导${NC}"
    _line

    _info "系统: $DISTRO (包管理器: $PKG_MGR, 服务: $SVC_MGR)"
    case "$PKG_MGR" in apk|dnf|yum|apt) ;; *) _err "不支持的包管理器"; return 1 ;; esac
    case "$SVC_MGR" in openrc|systemd) ;; *) _err "不支持的服务管理器"; return 1 ;; esac
    install_deps || { _err "依赖安装失败，请检查软件源"; return 1; }
    install_nginx || { _err "Nginx 安装失败"; return 1; }
    install_xray || { _err "Xray 安装失败"; return 1; }
    init_db || return 1

    if [[ -f "$XRAY_CONFIG" ]] || jq -e '
        (.sni | type == "string" and length > 0) and
        ((.short_ids // .short_id) | type == "string" and length > 0) and
        (.private_key | type == "string" and length > 0) and
        (.public_key | type == "string" and length > 0) and
        (.port | type == "number")
    ' "$DB_FILE" >/dev/null; then
        _info "保留现有账号、密钥、端口和 SNI，应用指定版本并重启服务"
        local existing_port
        existing_port=$(db_get_field '.port') || return 1
        open_firewall_port "$existing_port" || return 1
        generate_xray_config || return 1
        generate_nginx_sni_config || return 1
        start_proxy_services || { _err "重装未完成，请检查服务日志"; return 1; }
        _ok "重装完成，现有凭据未重置"
        return 0
    fi

    local ipv4 ipv6 ipv4_nat=false
    ipv4=$(get_ipv4)
    ipv6=$(get_ipv6)
    echo -e "  IPv4: ${ipv4:-${R}无${NC}}"
    echo -e "  IPv6: ${ipv6:-${R}无${NC}}"
    [[ -z "$ipv4" && -z "$ipv6" ]] && { _err "无法获取公网 IP"; return 1; }
    if [[ -n "$ipv4" ]] && ipv4_is_nat "$ipv4"; then
        ipv4_nat=true
        echo -e "  ${Y}提示:${NC} 本机 IPv4 是 NAT 内网地址，公网 ${W}${ipv4}${NC} 需要在 NAT/安全组做端口转发才能入站"
        [[ -n "$ipv6" ]] && echo -e "  ${Y}提示:${NC} IPv6 为直连，推荐优先使用 IPv6 链接"
    fi
    echo ""

    # 5. 选择端口
    local port
    echo -e "  ${W}选择监听端口${NC}"
    local random_high_port
    random_high_port=$(gen_random_port)
    _item "1" "443 (推荐，伪装为标准 HTTPS)"
    _item "2" "${random_high_port} (随机高端口)"
    _item "c" "自定义端口"
    _line
    read -rp "  请选择 [默认 1]: " port_choice
    port_choice=${port_choice:-1}
    case "$port_choice" in
        1) port=443 ;;
        2) port=$random_high_port ;;
        c|C)
            read -rp "  输入端口号 (1-65535): " port
            valid_port "$port" || { _err "无效端口或与 Xray 内部端口冲突"; return 1; }
            port=$((10#$port))
            ;;
        *) port=443 ;;
    esac
    _info "端口: $port"
    open_firewall_port "$port" || return 1
    echo ""

    # 6. 选择 SNI 域名
    local sni=""
    while [[ -z "$sni" ]]; do
        if select_sni_domain; then
            sni="$SELECTED_SNI"
        fi
    done
    _info "SNI: $sni"
    echo ""

    # 7. 生成 shortIds (4 个, 客户端任选一个)
    local short_ids
    short_ids=$(gen_short_ids 4)
    local first_short_id
    first_short_id=$(echo "$short_ids" | awk '{print $1}')
    _info "ShortIds: $short_ids"

    # 8. 生成默认用户
    local default_uuid default_email
    default_uuid=$(gen_uuid)
    default_email=$(gen_random_email)
    _info "默认 UUID: $default_uuid"
    echo ""

    if [[ -s "$CFG/private.key" && -s "$CFG/public.key" ]]; then
        _info "复用未完成安装留下的密钥对"
    elif [[ -e "$CFG/private.key" || -e "$CFG/public.key" ]]; then
        _err "已有密钥文件不完整，请恢复密钥备份后重试；不会覆盖现有密钥"
        return 1
    else
        gen_keys || return 1
    fi
    local private_key public_key
    private_key=$(cat "$CFG/private.key") || return 1
    public_key=$(cat "$CFG/public.key") || return 1
    [[ -n "$default_uuid" && -n "$short_ids" ]] || return 1

    # 9. 保存配置到数据库
    db_set_field --arg port "$port" --arg sni "$sni" \
        --arg pk "$private_key" --arg pub "$public_key" \
        --arg sids "$short_ids" --arg sid "$first_short_id" \
        --arg uuid "$default_uuid" --arg email "$default_email" \
        --arg dest "${sni}:443" \
        '.port=($port|tonumber) | .sni=$sni | .private_key=$pk | .public_key=$pub | .short_ids=$sids | .short_id=$sid | .default_uuid=$uuid | .default_email=$email | .dest=$dest' || return 1

    # 10. 创建默认用户文件
    mkdir -p "$USERS_DIR" || return 1
    local created
    created=$(date '+%Y-%m-%d %H:%M')
    jq -n \
        --arg email "$default_email" \
        --arg uuid "$default_uuid" \
        --arg created "$created" \
        '{email: $email, uuid: $uuid, enabled: true, created: $created}' \
        > "$USERS_DIR/${default_email}.json" || return 1

    # 11. 生成 Xray 配置 (监听 127.0.0.1:8443)
    generate_xray_config || { _err "配置生成失败"; return 1; }

    # 11.5 生成 Nginx SNI 分流配置 (监听 0.0.0.0:443)
    generate_nginx_sni_config || { _err "Nginx SNI 配置生成失败"; return 1; }
    start_proxy_services || { _err "安装未完成，请检查服务日志和端口占用"; return 1; }

    echo ""
    _dline
    echo -e "  ${G}安装完成!${NC}"
    _dline
    echo ""
    echo -e "  ${W}架构: Nginx (SNI分流) → Xray (Reality)${NC}"
    echo -e "  ${D}• Nginx 监听 $port，SNI 匹配 $sni → 转发 Xray${NC}"
    echo -e "  ${D}• Xray 监听 127.0.0.1:$XRAY_INTERNAL_PORT (仅本地)${NC}"
    echo -e "  ${D}• 其他 SNI → 黑洞 (防 CF CDN 流量被盗刷)${NC}"
    echo ""
    echo -e "  ${W}连接信息:${NC}"
    echo -e "  IPv4:   ${ipv4:-${D}无${NC}}$([[ "$ipv4_nat" == "true" ]] && echo -e "  ${Y}(NAT，需端口转发)${NC}")"
    [[ -n "$ipv6" ]] && echo -e "  IPv6:   $ipv6${D} (直连)${NC}"
    echo -e "  端口:   $port"
    echo -e "  SNI:    $sni"
    echo -e "  加密:   none"
    echo -e "  传输:   tcp"
    echo -e "  Flow:   xtls-rprx-vision"
    echo ""
    echo -e "  ${W}分享链接:${NC}"

    local link4 link6
    if [[ -n "$ipv4" ]]; then
        link4=$(build_vless_link "$default_uuid" "$ipv4" "$port" "$sni" "$public_key" "$first_short_id" "VLESS-${ipv4}")
        echo -e "  ${G}IPv4: ${link4}${NC}"
        show_qr "$link4"
    fi
    if [[ -n "$ipv6" ]]; then
        link6=$(build_vless_link "$default_uuid" "$ipv6" "$port" "$sni" "$public_key" "$first_short_id" "VLESS-${ipv6}")
        echo -e "  ${G}IPv6: ${link6}${NC}"
        show_qr "$link6"
    fi
    echo ""

    # 保存 join 链接：IPv4 走 NAT 时优先 IPv6 直连
    if [[ "$ipv4_nat" == "true" && -n "$link6" ]]; then
        echo "$link6" > "$CFG/join.txt"
    else
        echo "${link4:-$link6}" > "$CFG/join.txt"
    fi
}

#═══════════════════════════════════════════════════════════════════════════════
#  查看状态
#═══════════════════════════════════════════════════════════════════════════════

show_status() {
    local port sni short_id public_key ipv4
    port=$(db_get_field '.port' 2>/dev/null)
    sni=$(db_get_field '.sni' 2>/dev/null)
    short_id=$(db_get_field '.short_id' 2>/dev/null)
    public_key=$(cat "$CFG/public.key" 2>/dev/null || true)
    ipv4=$(get_ipv4)

    # Xray 服务状态
    local xray_status="${R}未运行${NC}"
    if is_service_active vless-reality; then
        xray_status="${G}运行中${NC}"
    fi

    # Nginx SNI 分流状态
    local nginx_status="${D}未安装${NC}"
    if check_cmd nginx; then
        if is_service_active nginx; then
            nginx_status="${G}运行中${NC} ${D}(SNI分流)${NC}"
        else
            nginx_status="${R}未运行${NC}"
        fi
    fi

    # Xray 版本
    local xray_ver="未安装"
    if check_cmd xray; then
        xray_ver=$(xray version 2>/dev/null | head -n1 | awk '{print $2}')
    fi

    echo -e "  Xray:     $xray_status ${D}v${xray_ver}${NC}"
    echo -e "  Nginx:    $nginx_status"
    [[ -n "$port" ]] && echo -e "  端口:     $port"
    [[ -n "$sni" ]]  && echo -e "  SNI:      $sni"
    [[ -n "$ipv4" ]] && echo -e "  IPv4:     $ipv4"
}

show_full_info() {
    _header
    echo -e "  ${W}详细配置信息${NC}"
    _line

    local port sni short_id private_key public_key default_uuid ipv4 ipv6
    port=$(db_get_field '.port' 2>/dev/null)
    sni=$(db_get_field '.sni' 2>/dev/null)
    short_id=$(db_get_field '.short_id' 2>/dev/null)
    private_key=$(cat "$CFG/private.key" 2>/dev/null || true)
    public_key=$(cat "$CFG/public.key" 2>/dev/null || true)
    default_uuid=$(db_get_field '.default_uuid' 2>/dev/null)
    ipv4=$(get_ipv4)
    ipv6=$(get_ipv6)

    echo -e "  ${W}服务器:${NC}"
    echo -e "    IPv4:     ${ipv4:-${D}无${NC}}"
    echo -e "    IPv6:     ${ipv6:-${D}无${NC}}"
    echo -e "    端口:     $port"
    echo ""
    echo -e "  ${W}Reality 配置:${NC}"
    echo -e "    SNI:      $sni"
    echo -e "    ShortId:  $short_id"
    echo -e "    PrivateKey: ${D}${private_key:0:20}...${NC}"
    echo -e "    PublicKey:  ${D}${public_key:0:20}...${NC}"
    echo ""

    # 用户统计
    local total=0
    if [[ -d "$USERS_DIR" ]]; then
        for f in "$USERS_DIR"/*.json; do
            [[ -f "$f" ]] && ((total++))
        done
    fi
    echo -e "  ${W}用户: ${total} 个${NC}"
    echo ""

    echo -e "  ${D}使用 --links 查看当前启用用户的分享链接${NC}"
}

#═══════════════════════════════════════════════════════════════════════════════
#  修改配置
#═══════════════════════════════════════════════════════════════════════════════

apply_proxy_settings() (
    local backup success=false xray_touched=false nginx_touched=false
    local xray_was_active=false nginx_was_active=false
    backup=$(mktemp -d "$CFG/.settings.XXXXXX") || return 1
    cp -p "$DB_FILE" "$backup/db" && cp -p "$XRAY_CONFIG" "$backup/xray" && \
        cp -p "$NGINX_SNI_CONF" "$backup/nginx" || { rm -rf "$backup"; return 1; }
    is_service_active vless-reality && xray_was_active=true
    is_service_active nginx && nginx_was_active=true
    trap '
        if [[ "$success" != true ]]; then
            if cat "$backup/db" > "$DB_FILE" && cat "$backup/xray" > "$XRAY_CONFIG" &&
                cat "$backup/nginx" > "$NGINX_SNI_CONF"; then
                if [[ "$xray_touched" == true ]]; then
                    if [[ "$xray_was_active" == true ]]; then restart_xray; else svc stop vless-reality; fi || _err "Xray 旧服务恢复失败"
                fi
                if [[ "$nginx_touched" == true ]]; then
                    if [[ "$nginx_was_active" == true ]]; then restart_nginx; else svc stop nginx; fi || _err "Nginx 旧服务恢复失败"
                fi
                _err "配置变更失败，已恢复原配置；请确认服务状态"
            else
                _err "配置恢复失败，备份保留在 $backup"
                exit 1
            fi
        fi
        rm -rf "$backup"
    ' EXIT
    db_set_field "$@" || return 1
    generate_xray_config || return 1
    generate_nginx_sni_config || return 1
    xray_touched=true
    restart_xray || return 1
    nginx_touched=true
    restart_nginx || return 1
    success=true
)

change_port() {
    local current_port new_port
    current_port=$(db_get_field '.port' 2>/dev/null)
    echo -e "  当前端口: ${W}${current_port}${NC}"
    read -rp "  新端口 [443]: " new_port
    new_port=${new_port:-443}
    valid_port "$new_port" || { _err "无效端口或与 Xray 内部端口冲突"; return 1; }
    new_port=$((10#$new_port))
    open_firewall_port "$new_port" || return 1
    apply_proxy_settings --argjson p "$new_port" '.port=$p' || return 1
    _ok "端口已改为 $new_port"
}

change_sni() {
    local current_sni
    current_sni=$(db_get_field '.sni' 2>/dev/null)
    echo -e "  当前 SNI: ${W}${current_sni}${NC}"
    echo ""

    local new_sni=""
    while [[ -z "$new_sni" ]]; do
        if select_sni_domain; then
            new_sni="$SELECTED_SNI"
        fi
    done

    apply_proxy_settings --arg s "$new_sni" --arg d "${new_sni}:443" '.sni=$s | .dest=$d' || return 1
    _ok "SNI 已改为 $new_sni"
}

rotate_keys() {
    echo -e "  ${Y}重新生成密钥对会使所有客户端连接失效!${NC}"
    read -rp "  确认? [y/N]: " confirm
    [[ "$confirm" != [yY] ]] && return

    gen_keys || return 1
    local pk pub
    pk=$(cat "$CFG/private.key") || return 1
    pub=$(cat "$CFG/public.key") || return 1
    db_set_field --arg pk "$pk" --arg pub "$pub" '.private_key=$pk | .public_key=$pub' || return 1
    _ok "密钥已更新"

    apply_xray_changes || return 1
    echo -e "  ${W}新 PublicKey: ${G}${pub}${NC}"
    echo -e "  ${Y}请更新所有客户端的 PublicKey${NC}"
}

#═══════════════════════════════════════════════════════════════════════════════
#  卸载
#═══════════════════════════════════════════════════════════════════════════════

do_uninstall() {
    echo -e "  ${R}即将完全卸载 VLESS Reality CF${NC}"
    echo -e "  ${Y}将删除: Xray 配置、用户数据、Nginx SNI 配置、服务${NC}"
    read -rp "  确认卸载? [y/N]: " confirm
    [[ "$confirm" != [yY] ]] && return

    _info "停止服务..."
    svc stop vless-reality 2>/dev/null
    svc stop nginx 2>/dev/null

    _info "移除 Xray 服务..."
    if [[ "$SVC_MGR" == "openrc" ]]; then
        rc-update del vless-reality default 2>/dev/null
        rm -f /etc/init.d/vless-reality
    else
        systemctl disable vless-reality 2>/dev/null
        rm -f /etc/systemd/system/vless-reality.service
        systemctl daemon-reload 2>/dev/null
    fi

    _info "移除 Nginx SNI 分流配置..."
    rm -f "$NGINX_SNI_CONF"
    # 从 nginx.conf 中移除追加的 stream block，以及各家族配置里注入的 include
    if [[ -f /etc/nginx/nginx.conf ]]; then
        sed -i '/# SNI stream 分流/,/^}/d' /etc/nginx/nginx.conf 2>/dev/null
        sed -i '/include.*stream\.conf\.d/d' /etc/nginx/nginx.conf 2>/dev/null
    fi
    if [[ -f /etc/nginx/conf.d/stream.conf ]]; then
        sed -i '/include.*stream\.conf\.d/d' /etc/nginx/conf.d/stream.conf 2>/dev/null
    fi

    _info "删除二进制..."
    rm -f "$XRAY_BIN"
    rm -f /var/log/vless-reality.log

    _info "删除配置目录..."
    rm -rf "$CFG"

    _ok "卸载完成"
    _warn "Xray 已删除，Nginx 保留 (可能还有其他用途)"
}

#═══════════════════════════════════════════════════════════════════════════════
#  查看日志
#═══════════════════════════════════════════════════════════════════════════════

show_logs() {
    echo -e "  ${W}最近 50 行日志:${NC}"
    _line
    if [[ "$SVC_MGR" == "openrc" ]]; then
        if [[ -f /var/log/vless-reality.log ]]; then
            tail -50 /var/log/vless-reality.log 2>/dev/null || _warn "无法读取日志"
        else
            _warn "日志文件不存在: /var/log/vless-reality.log"
        fi
    else
        journalctl -u vless-reality -n 50 --no-pager 2>/dev/null || \
            _warn "无法读取日志"
    fi
}

#═══════════════════════════════════════════════════════════════════════════════
#  BBR 优化
#═══════════════════════════════════════════════════════════════════════════════

enable_bbr() {
    _info "检查 BBR 状态..."

    local current_cc
    current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")

    if [[ "$current_cc" == "bbr" ]]; then
        _ok "BBR 已启用"
        return
    fi

    _info "启用 BBR..."

    # Alpine 等精简系统可能没自动加载模块
    modprobe tcp_bbr >/dev/null 2>&1 || true
    modprobe sch_fq >/dev/null 2>&1 || true

    # 幂等写入：先删除旧的 BBR 配置行，再追加
    if [[ -f /etc/sysctl.conf ]]; then
        sed -i '/^net\.core\.default_qdisc=fq$/d' /etc/sysctl.conf 2>/dev/null
        sed -i '/^net\.ipv4\.tcp_congestion_control=bbr$/d' /etc/sysctl.conf 2>/dev/null
        sed -i '/^# BBR$/d' /etc/sysctl.conf 2>/dev/null
    fi

    cat >> /etc/sysctl.conf <<'EOF'
# BBR
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
    sysctl -p >/dev/null 2>&1

    current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
    if [[ "$current_cc" == "bbr" ]]; then
        _ok "BBR 已启用"
    else
        _warn "BBR 启用失败 (当前: $current_cc)，可能需要更新内核"
    fi
}

#═══════════════════════════════════════════════════════════════════════════════
#  主菜单
#═══════════════════════════════════════════════════════════════════════════════

main_menu() {
    check_root
    init_db

    while true; do
        _header

        if [[ -f "$XRAY_CONFIG" ]]; then
            show_status
            echo ""
            _line
            _item "1" "用户管理"
            _item "2" "查看所有分享链接"
            _item "3" "修改端口"
            _item "4" "修改 SNI 域名"
            _item "5" "重新生成密钥"
            _item "6" "SNI 校验 (验证域名可用性)"
            _item "7" "启用 BBR"
            _item "8" "查看日志"
            _item "9" "重启服务"
            _item "r" "重新安装"
            _item "u" "完全卸载"
        else
            echo -e "  ${D}尚未安装${NC}"
            echo ""
            _line
            _item "1" "安装 VLESS Reality"
        fi
        _item "0" "退出"
        _line

        read -rp "  请选择: " choice
        case $choice in
            1)
                if [[ -f "$XRAY_CONFIG" ]]; then
                    manage_users
                else
                    do_install; _pause
                fi
                ;;
            2) [[ -f "$XRAY_CONFIG" ]] && { show_user_links; _pause; } || { _err "请先安装"; _pause; } ;;
            3) [[ -f "$XRAY_CONFIG" ]] && { change_port; _pause; } || { _err "请先安装"; _pause; } ;;
            4) [[ -f "$XRAY_CONFIG" ]] && { change_sni; _pause; } || { _err "请先安装"; _pause; } ;;
            5) [[ -f "$XRAY_CONFIG" ]] && { rotate_keys; _pause; } || { _err "请先安装"; _pause; } ;;
            6)
                local sni
                sni=$(db_get_field '.sni' 2>/dev/null)
                if [[ -n "$sni" ]]; then
                    check_sni_validity "$sni"
                else
                    _warn "未设置 SNI，请先安装或手动输入域名校验"
                    read -rp "  输入域名: " manual_domain
                    [[ -n "$manual_domain" ]] && check_sni_validity "$manual_domain"
                fi
                _pause
                ;;
            7) enable_bbr; _pause ;;
            8) [[ -f "$XRAY_CONFIG" ]] && { show_logs; _pause; } || { _err "请先安装"; _pause; } ;;
            9)
                if [[ -f "$XRAY_CONFIG" ]]; then
                    start_proxy_services; _pause
                else
                    _err "请先安装"; _pause
                fi
                ;;
            r|R) do_install; _pause ;;
            u|U) [[ -f "$XRAY_CONFIG" ]] && { do_uninstall; _pause; } || { _err "未安装"; _pause; } ;;
            0) exit 0 ;;
            *) _err "无效选择"; _pause ;;
        esac
    done
}

#═══════════════════════════════════════════════════════════════════════════════
#  命令行参数
#═══════════════════════════════════════════════════════════════════════════════

XRAY_VERSION="26.11.9"
cli_args=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --xray-version)
            if [[ $# -lt 2 || -z "$2" || "$2" == --* ]]; then
                _err "--xray-version 需要版本号，例如 26.11.9"
                exit 1
            fi
            XRAY_VERSION="$2"
            shift 2
            ;;
        --xray-version=*)
            XRAY_VERSION="${1#*=}"
            shift
            ;;
        *)
            cli_args+=("$1")
            shift
            ;;
    esac
done
set -- "${cli_args[@]}"
XRAY_VERSION="${XRAY_VERSION#v}"
if [[ ! "$XRAY_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    _err "无效 Xray 版本号: $XRAY_VERSION（示例: 26.11.9）"
    exit 1
fi
readonly XRAY_VERSION

case "${1:-}" in
    --install)
        check_root; do_install
        ;;
    --uninstall)
        check_root; do_uninstall
        ;;
    --status)
        check_root; init_db; show_full_info
        ;;
    --links)
        check_root; init_db; show_user_links
        ;;
    --check-sni)
        shift
        domain="${1:-}"
        if [[ -z "$domain" ]]; then
            echo "用法: $0 --check-sni <domain>"
            exit 1
        fi
        check_sni_validity "$domain"
        ;;
    --help|-h)
        echo "用法: $0 [选项]"
        echo ""
        echo "选项:"
        echo "  --install          进入安装向导（重装保留账号和密钥）"
        echo "  --xray-version <版本> 指定 Xray 版本 (默认固定 26.11.9，可带 v 前缀)"
        echo "  --uninstall        完全卸载"
        echo "  --status           显示配置状态"
        echo "  --links            显示分享链接"
        echo "  --check-sni <域名> 校验域名是否可用于 Reality"
        echo "  --help, -h         显示帮助"
        echo ""
        echo "无参数时启动交互式菜单"
        ;;
    *)
        main_menu
        ;;
esac
