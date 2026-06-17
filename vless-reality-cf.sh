#!/bin/bash
#═══════════════════════════════════════════════════════════════════════════════
#  VLESS Reality + CF CDN 域名一键部署脚本 v1.0.0
#
#  功能: VLESS+Reality 偷 CF CDN 域名 + SNI 校验 + 用户管理
#  适配: Debian/Ubuntu/CentOS/Alpine
#
#  基于: https://github.com/Zyx0rx/vless-all-in-one (v3.5.3)
#        精简为仅 VLESS Reality + CF 域名 + 用户管理
#═══════════════════════════════════════════════════════════════════════════════

# 不启用 set -e，交互式脚本中很多命令预期返回非零 (grep/curl/jq 等)
# set -euo pipefail

readonly VERSION="1.0.0"
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
elif [[ -f /etc/centos-release ]] || [[ -f /etc/redhat-release ]]; then
    DISTRO="centos"
elif grep -qi ubuntu /etc/os-release 2>/dev/null; then
    DISTRO="ubuntu"
elif grep -qi debian /etc/os-release 2>/dev/null; then
    DISTRO="debian"
else
    DISTRO="unknown"
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

get_ipv4() {
    [[ -n "$_CACHED_IPV4" ]] && { echo "$_CACHED_IPV4"; return; }
    local result
    result=$(curl -4 -sf --connect-timeout 5 ip.sb 2>/dev/null || \
             curl -4 -sf --connect-timeout 5 ifconfig.me 2>/dev/null || true)
    [[ -n "$result" ]] && _CACHED_IPV4="$result"
    echo "$result"
}

get_ipv6() {
    [[ -n "$_CACHED_IPV6" ]] && { echo "$_CACHED_IPV6"; return; }
    local result
    result=$(curl -6 -sf --connect-timeout 5 ip.sb 2>/dev/null || \
             curl -6 -sf --connect-timeout 5 ifconfig.me 2>/dev/null || true)
    [[ -n "$result" ]] && _CACHED_IPV6="$result"
    echo "$result"
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
    tmp=$(mktemp) || return 1
    if jq "$@" "$DB_FILE" > "$tmp" 2>/dev/null; then
        mv "$tmp" "$DB_FILE"
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
#  服务管理
#═══════════════════════════════════════════════════════════════════════════════

svc() {
    local cmd="$1" name="$2"
    if [[ "$DISTRO" == "alpine" ]]; then
        rc-service "$name" "$cmd" 2>/dev/null
    else
        systemctl "$cmd" "$name" 2>/dev/null
    fi
}

create_xray_service() {
    if [[ "$DISTRO" == "alpine" ]]; then
        cat > /etc/init.d/vless-reality <<'EOF'
#!/sbin/openrc-run
name="vless-reality"
command="/usr/local/bin/xray"
command_args="run -c /etc/vless-reality-cf/xray.json"
command_background=true
pidfile="/run/vless-reality.pid"
depend() { need net; }
EOF
        chmod +x /etc/init.d/vless-reality
        rc-update add vless-reality default 2>/dev/null
    else
        cat > /etc/systemd/system/vless-reality.service <<'EOF'
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
        systemctl daemon-reload 2>/dev/null
        systemctl enable vless-reality 2>/dev/null
    fi
    _ok "服务已创建"
}

restart_xray() {
    svc restart vless-reality
    sleep 1
    if svc status vless-reality 2>/dev/null | grep -qi "running\|active"; then
        _ok "Xray 已重启"
    else
        _warn "Xray 重启后状态异常，请检查日志"
    fi
    # 同时重启 Nginx (SNI 分流)
    if check_cmd nginx; then
        restart_nginx
    fi
}

#═══════════════════════════════════════════════════════════════════════════════
#  依赖安装
#═══════════════════════════════════════════════════════════════════════════════

install_deps() {
    _info "安装基础依赖..."
    case "$DISTRO" in
        alpine)
            apk update -q 2>/dev/null
            apk add --no-cache curl jq openssl ca-certificates coreutils unzip >/dev/null 2>&1
            # gcompat 兼容层
            apk add --no-cache gcompat libc6-compat >/dev/null 2>&1
            ;;
        centos)
            yum install -y -q curl jq openssl ca-certificates coreutils unzip >/dev/null 2>&1
            ;;
        debian|ubuntu)
            apt-get update -qq >/dev/null 2>&1
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl jq openssl ca-certificates coreutils unzip >/dev/null 2>&1
            ;;
        *)
            _warn "未知发行版，请手动安装: curl jq openssl unzip"
            ;;
    esac
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

install_nginx() {
    if check_cmd nginx; then
        # 检查是否有 stream 模块 (静态编译或动态模块 .so 文件存在)
        local has_stream=false
        if nginx -V 2>&1 | grep -q "with-stream\b\|with-stream=dynamic"; then
            # 如果是动态模块，检查 .so 文件是否存在
            if nginx -V 2>&1 | grep -q "stream=dynamic"; then
                for mod_path in /usr/lib/nginx/modules/ngx_stream_module.so \
                                /usr/share/nginx/modules/ngx_stream_module.so \
                                /etc/nginx/modules/ngx_stream_module.so; do
                    [[ -f "$mod_path" ]] && has_stream=true && break
                done
                # .so 不存在但 nginx 支持动态 stream → 需要安装包
                if [[ "$has_stream" == "false" ]]; then
                    _info "安装 Nginx stream 动态模块..."
                    case "$DISTRO" in
                        debian|ubuntu)
                            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq libnginx-mod-stream >/dev/null 2>&1
                            ;;
                        centos)
                            yum install -y -q nginx-mod-stream >/dev/null 2>&1
                            ;;
                    esac
                    # 再检查一次
                    for mod_path in /usr/lib/nginx/modules/ngx_stream_module.so \
                                    /usr/share/nginx/modules/ngx_stream_module.so \
                                    /etc/nginx/modules/ngx_stream_module.so; do
                        [[ -f "$mod_path" ]] && has_stream=true && break
                    done
                fi
            else
                # 静态编译的 stream
                has_stream=true
            fi
        fi

        if [[ "$has_stream" == "true" ]]; then
            _ok "Nginx 已安装 (含 stream 模块)"
            return 0
        else
            _warn "Nginx 已安装但无法获取 stream 模块，重新安装..."
        fi
    fi

    _info "安装 Nginx (含 stream 模块用于 SNI 分流)..."
    case "$DISTRO" in
        alpine)
            apk add --no-cache nginx nginx-stream >/dev/null 2>&1 || \
            apk add --no-cache nginx >/dev/null 2>&1
            ;;
        centos)
            yum install -y -q nginx nginx-mod-stream >/dev/null 2>&1 || \
            yum install -y -q nginx >/dev/null 2>&1
            ;;
        debian|ubuntu)
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nginx libnginx-mod-stream >/dev/null 2>&1 || \
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nginx >/dev/null 2>&1
            ;;
    esac

    if check_cmd nginx; then
        _ok "Nginx 安装完成"
    else
        _err "Nginx 安装失败"
        return 1
    fi
}

generate_nginx_sni_config() {
    local sni port
    sni=$(db_get_field '.sni')
    port=$(db_get_field '.port')
    [[ -z "$sni" ]] && { _err "未设置 SNI"; return 1; }
    [[ -z "$port" ]] && port=443

    mkdir -p "$(dirname "$NGINX_SNI_CONF")"

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

    _ok "Nginx SNI 分流配置已生成: $NGINX_SNI_CONF"

    # 确保 nginx.conf 包含 stream block
    if ! grep -q "stream.conf.d" /etc/nginx/nginx.conf 2>/dev/null; then
        # 检查是否需要 load_module (动态模块)
        local need_load_module=false
        if nginx -V 2>&1 | grep -q "stream=dynamic"; then
            need_load_module=true
        fi
        # 检查动态模块文件是否存在
        local stream_module=""
        for mod_path in /usr/lib/nginx/modules/ngx_stream_module.so \
                        /usr/share/nginx/modules/ngx_stream_module.so \
                        /etc/nginx/modules/ngx_stream_module.so; do
            if [[ -f "$mod_path" ]]; then
                stream_module="$mod_path"
                break
            fi
        done

        # 在 nginx.conf 最前面加 load_module (如果需要，且没被 modules-enabled 加载)
        if [[ "$need_load_module" == "true" && -n "$stream_module" ]]; then
            local already_loaded=false
            # Debian 的 modules-enabled 机制会自动加载
            if ls /etc/nginx/modules-enabled/*stream* 2>/dev/null | grep -q .; then
                already_loaded=true
            fi
            # nginx.conf 里是否已有 load_module
            if grep -q "ngx_stream_module" /etc/nginx/nginx.conf 2>/dev/null; then
                already_loaded=true
            fi
            if [[ "$already_loaded" == "false" ]]; then
                sed -i "1i\\load_module ${stream_module};" /etc/nginx/nginx.conf
                _ok "已添加 load_module ngx_stream_module"
            fi
        fi

        # 在 nginx.conf 末尾追加 stream block (必须和 events/http 同级)
        # 不能插入到 http{} 或 events{} 内部，必须 append 到文件末尾
        if ! grep -q "stream.conf.d" /etc/nginx/nginx.conf 2>/dev/null; then
            cat >> /etc/nginx/nginx.conf <<'STREAMEOF'

# SNI stream 分流 (VLESS Reality)
stream {
    include /etc/nginx/stream.conf.d/*.conf;
}
STREAMEOF
            _ok "已在 nginx.conf 末尾添加 stream block"
        fi
    fi
}

create_nginx_service() {
    if [[ "$DISTRO" != "alpine" ]]; then
        systemctl enable nginx 2>/dev/null
    else
        rc-update add nginx default 2>/dev/null
    fi
}

restart_nginx() {
    # 先测试配置
    if nginx -t 2>&1 | grep -q "successful"; then
        svc restart nginx
        sleep 1
        if svc status nginx 2>/dev/null | grep -qi "running\|active"; then
            _ok "Nginx 已重启 (SNI 分流生效)"
        else
            _warn "Nginx 重启后状态异常"
        fi
    else
        _err "Nginx 配置测试失败:"
        nginx -t 2>&1 | tail -5
    fi
}

#═══════════════════════════════════════════════════════════════════════════════
#  Xray 核心安装
#═══════════════════════════════════════════════════════════════════════════════

install_xray() {
    if check_cmd xray; then
        local ver
        ver=$(xray version 2>/dev/null | head -n1 | awk '{print $2}')
        _ok "Xray 已安装: v${ver}"
        return 0
    fi

    _info "安装 Xray-core..."

    # 获取最新版本
    local version
    version=$(curl -fsSL --connect-timeout "$CURL_TIMEOUT" \
        "https://api.github.com/repos/XTLS/Xray-core/releases/latest" 2>/dev/null \
        | jq -r '.tag_name' 2>/dev/null)
    version="${version#v}"

    if [[ -z "$version" || "$version" == "null" ]]; then
        _err "无法获取 Xray 最新版本"
        return 1
    fi

    _info "最新版本: v${version}"

    # 架构检测
    local arch
    arch=$(uname -m)
    local xarch
    case "$arch" in
        x86_64|amd64)  xarch="64" ;;
        aarch64|arm64) xarch="arm64-v8a" ;;
        armv7l|armv6l) xarch="arm32-v7a" ;;
        *) _err "不支持的架构: $arch"; return 1 ;;
    esac

    local url="https://github.com/XTLS/Xray-core/releases/download/v${version}/Xray-linux-${xarch}.zip"
    local tmp
    tmp=$(mktemp -d)

    _info "下载: $url"
    if ! curl -fsSL --connect-timeout "$CURL_TIMEOUT_DOWNLOAD" -o "$tmp/xray.zip" "$url"; then
        rm -rf "$tmp"
        _err "下载失败"
        return 1
    fi

    unzip -oq "$tmp/xray.zip" -d "$tmp/" || { rm -rf "$tmp"; _err "解压失败"; return 1; }

    install -m 755 "$tmp/xray" "$XRAY_BIN"

    # 安装 geoip/geosite 数据文件
    mkdir -p /usr/local/share/xray
    cp "$tmp"/*.dat /usr/local/share/xray/ 2>/dev/null || true

    rm -rf "$tmp"
    _ok "Xray v${version} 安装完成"
}

#═══════════════════════════════════════════════════════════════════════════════
#  密钥生成
#═══════════════════════════════════════════════════════════════════════════════

gen_keys() {
    _info "生成 Reality 密钥对..."
    local keys
    keys=$("$XRAY_BIN" x25519 2>/dev/null)

    # 兼容新旧输出格式:
    #   旧版: "Private key: xxx" / "Public key: xxx"
    #   新版: "PrivateKey: xxx" / "Password (PublicKey): xxx"
    local private_key public_key
    private_key=$(echo "$keys" | grep -i "private" | head -1 | awk '{print $NF}')
    public_key=$(echo "$keys" | grep -i "public" | head -1 | awk '{print $NF}')

    if [[ -z "$private_key" || -z "$public_key" ]]; then
        _err "密钥生成失败 (xray x25519 输出异常)"
        _err "原始输出: $keys"
        return 1
    fi

    echo "$private_key" > "$CFG/private.key"
    echo "$public_key" > "$CFG/public.key"
    chmod 600 "$CFG/private.key"

    _ok "密钥对已生成"
    echo -e "  ${D}PrivateKey: ${private_key}${NC}"
    echo -e "  ${D}PublicKey:  ${public_key}${NC}"
}

gen_short_id() {
    local sid
    sid=$(head -c 8 /dev/urandom 2>/dev/null | od -A n -t x1 | tr -d ' \n' | head -c 16)
    if [[ -z "$sid" || ${#sid} -lt 16 ]]; then
        # Fallback: 用 /proc/sys/kernel/random/uuid 截取
        sid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null | tr -d '-' | head -c 16)
    fi
    if [[ -z "$sid" || ${#sid} -lt 16 ]]; then
        # 最终 fallback: python3 生成
        sid=$(python3 -c "import secrets; print(secrets.token_hex(8))" 2>/dev/null)
    fi
    echo "$sid"
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
# ⚠️ 此函数通过 echo 返回值 (域名)，所有 UI 输出必须走 stderr (>&2)
#   否则 sni=$(select_sni_domain) 会把菜单文字也捕获进 sni 变量
select_sni_domain() {
    echo "" >&2
    _line
    echo -e "  ${W}选择 Reality SNI 域名 (偷哪个域名)${NC}" >&2
    echo "" >&2
    echo -e "  ${D}选择原则:${NC}" >&2
    echo -e "  ${D}• 部署在 Cloudflare CDN 上的站点${NC}" >&2
    echo -e "  ${D}• 在大陆可访问 (避免被墙)${NC}" >&2
    echo -e "  ${D}• 支持 TLS 1.3${NC}" >&2
    echo -e "  ${D}• 不要太热门/敏感 (避免被重点关注)${NC}" >&2
    echo "" >&2
    _line

    local i=1
    for d in "${CF_CDN_DOMAINS[@]}"; do
        if [[ "$d" == "speed.cloudflare.com" ]]; then
            _item "$i" "$d  ${Y}← 推荐${NC}"
        elif [[ "$d" == "www.cloudflare.com" ]]; then
            _item "$i" "$d  ${D}(CF 官网)${NC}"
        elif [[ "$d" == "dash.cloudflare.com" ]]; then
            _item "$i" "$d  ${D}(CF 面板)${NC}"
        else
            _item "$i" "$d"
        fi
        ((i++))
    done
    _item "c" "自定义域名 (输入后自动校验)"
    _item "v" "对已选域名执行 SNI 校验"
    _item "0" "返回"
    _line

    local choice
    read -rp "  请选择 [默认 1: speed.cloudflare.com]: " choice >&2
    choice=${choice:-1}

    if [[ "$choice" == "c" || "$choice" == "C" ]]; then
        echo "" >&2
        local custom_domain
        read -rp "  输入自定义域名: " custom_domain >&2
        custom_domain=$(echo "$custom_domain" | xargs) # trim

        if [[ -z "$custom_domain" ]]; then
            _err "域名不能为空"
            return 1
        fi

        if [[ ! "$custom_domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*\.)+[a-zA-Z]{2,}$ ]]; then
            _err "无效的域名格式"
            return 1
        fi

        # 自动校验 (check_sni_validity 输出也走 stderr)
        check_sni_validity "$custom_domain" >&2 || true
        echo "" >&2
        echo -e "  ${Y}是否使用此域名? [Y/n]: ${NC}" >&2
        read -rp "  " confirm >&2
        if [[ "${confirm,,}" == "n" ]]; then
            return 1
        fi
        echo "$custom_domain"
        return 0
    elif [[ "$choice" == "v" || "$choice" == "V" ]]; then
        local current_sni
        current_sni=$(db_get_field '.sni')
        if [[ -z "$current_sni" ]]; then
            _warn "尚未设置 SNI 域名，请先选择一个"
            _pause
            return 1
        fi
        check_sni_validity "$current_sni" >&2
        _pause
        return 1
    elif [[ "$choice" == "0" ]]; then
        return 1
    elif [[ "$choice" =~ ^[0-9]+$ && "$choice" -ge 1 && "$choice" -le ${#CF_CDN_DOMAINS[@]} ]]; then
        local selected="${CF_CDN_DOMAINS[$((choice-1))]}"
        echo "" >&2
        _info "已选择: $selected"
        echo "" >&2
        echo -e "  ${Y}是否现在执行 SNI 校验? [Y/n]: ${NC}" >&2
        read -rp "  " do_check >&2
        if [[ "${do_check,,}" != "n" ]]; then
            check_sni_validity "$selected" >&2
        fi
        echo "$selected"
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
    # 从用户目录构建 clients JSON
    local clients="[]"
    if [[ -d "$USERS_DIR" ]]; then
        for user_file in "$USERS_DIR"/*.json; do
            [[ -f "$user_file" ]] || continue
            local enabled uuid email
            enabled=$(jq -r '.enabled // true' "$user_file")
            [[ "$enabled" != "true" ]] && continue

            uuid=$(jq -r '.uuid' "$user_file")
            email=$(jq -r '.email // "user"' "$user_file")

            [[ -z "$uuid" || "$uuid" == "null" ]] && continue

            clients=$(echo "$clients" | jq \
                --arg u "$uuid" \
                --arg e "$email" \
                '. += [{"id": $u, "email": $e, "flow": "xtls-rprx-vision"}]')
        done
    fi

    # 确保至少有一个默认用户
    if [[ "$clients" == "[]" ]]; then
        local default_uuid
        default_uuid=$(db_get_field '.default_uuid')
        [[ -z "$default_uuid" ]] && return 1
        clients=$(echo "[]" | jq --arg u "$default_uuid" \
            '. += [{"id": $u, "email": "default", "flow": "xtls-rprx-vision"}]')
    fi

    echo "$clients"
}

generate_xray_config() {
    local port sni private_key short_id dest
    port=$(db_get_field '.port')
    sni=$(db_get_field '.sni')
    private_key=$(cat "$CFG/private.key" 2>/dev/null || db_get_field '.private_key')
    short_id=$(db_get_field '.short_id')
    dest="${sni}:443"

    [[ -z "$port" ]] && { _err "未设置端口"; return 1; }
    [[ -z "$sni" ]] && { _err "未设置 SNI 域名"; return 1; }
    [[ -z "$private_key" ]] && { _err "未设置私钥"; return 1; }
    [[ -z "$short_id" ]] && { _err "未设置 shortId"; return 1; }

    local clients
    clients=$(build_clients_json)
    [[ -z "$clients" || "$clients" == "[]" ]] && { _err "无有效用户"; return 1; }

    local tmp
    tmp=$(mktemp)

    jq -n \
        --argjson internal_port "$XRAY_INTERNAL_PORT" \
        --argjson clients "$clients" \
        --arg sni "$sni" \
        --arg private_key "$private_key" \
        --arg short_id "$short_id" \
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
                    shortIds: [$short_id]
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
    }' > "$tmp"

    mv "$tmp" "$XRAY_CONFIG"
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
            local name email uuid enabled created quota
            name=$(basename "$user_file" .json)
            email=$(jq -r '.email // "user"' "$user_file")
            uuid=$(jq -r '.uuid' "$user_file")
            enabled=$(jq -r '.enabled // true' "$user_file")
            created=$(jq -r '.created // "N/A"' "$user_file")
            quota=$(jq -r '.quota_gb // 0' "$user_file")

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
            echo -e "     状态: $status_text | 配额: ${quota}GB | 创建: ${created}"
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

    local name email uuid quota_gb

    read -rp "  用户名 (英文，用于标识): " name
    name=$(echo "$name" | xargs | tr ' ' '-')
    if [[ -z "$name" ]]; then
        _err "用户名不能为空"
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

    read -rp "  流量配额 (GB, 0=不限): " quota_gb
    quota_gb=${quota_gb:-0}
    [[ ! "$quota_gb" =~ ^[0-9]+$ ]] && quota_gb=0

    local created
    created=$(date '+%Y-%m-%d %H:%M')

    # 用 jq 构建 JSON，防止用户输入特殊字符导致 JSON 注入
    jq -n \
        --arg email "$email" \
        --arg uuid "$uuid" \
        --argjson quota "$quota_gb" \
        --arg created "$created" \
        '{email: $email, uuid: $uuid, enabled: true, quota_gb: $quota, used_bytes: 0, created: $created}' \
        > "$USERS_DIR/${name}.json"

    _ok "用户 $name 已添加"
    echo -e "  ${D}UUID: $uuid${NC}"

    # 重新生成配置并重启
    if generate_xray_config 2>/dev/null; then
        restart_xray
    fi
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
        enabled=$(jq -r '.enabled // true' "$user_file")
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
    [[ "${confirm,,}" != "y" ]] && { _info "已取消"; return; }

    rm -f "$USERS_DIR/${target}.json"
    _ok "用户 $target 已删除"

    if generate_xray_config 2>/dev/null; then
        restart_xray
    fi
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
        enabled=$(jq -r '.enabled // true' "$user_file")
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
    current=$(jq -r '.enabled // true' "$user_file")

    local new_state
    if [[ "$current" == "true" ]]; then
        new_state="false"
        _warn "禁用用户: $target"
    else
        new_state="true"
        _ok "启用用户: $target"
    fi

    local tmp
    tmp=$(mktemp)
    jq --argjson e "$new_state" '.enabled = $e' "$user_file" > "$tmp"
    mv "$tmp" "$user_file"

    if generate_xray_config 2>/dev/null; then
        restart_xray
    fi
}

show_user_links() {
    _header
    echo -e "  ${W}用户分享链接${NC}"
    _line

    local port sni short_id public_key ipv4
    port=$(db_get_field '.port')
    sni=$(db_get_field '.sni')
    short_id=$(db_get_field '.short_id')
    public_key=$(cat "$CFG/public.key" 2>/dev/null || db_get_field '.public_key')
    ipv4=$(get_ipv4)

    if [[ -z "$ipv4" ]]; then
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
        enabled=$(jq -r '.enabled // true' "$user_file")

        [[ "$enabled" != "true" ]] && continue

        local link
        link="vless://${uuid}@${ipv4}:${port}?encryption=none&security=reality&type=tcp&sni=${sni}&fp=chrome&pbk=${public_key}&sid=${short_id}&flow=xtls-rprx-vision#${name}"

        echo -e "  ${W}${name}${NC} (${email})"
        echo -e "  ${G}${link}${NC}"
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
                e=$(jq -r '.enabled // true' "$f")
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

    # 1. 检测系统
    _info "系统: $DISTRO"
    local ipv4 ipv6
    ipv4=$(get_ipv4)
    ipv6=$(get_ipv6)
    echo -e "  IPv4: ${ipv4:-${R}无${NC}}"
    echo -e "  IPv6: ${ipv6:-${R}无${NC}}"
    [[ -z "$ipv4" && -z "$ipv6" ]] && { _err "无法获取公网 IP"; return 1; }
    echo ""

    # 2. 安装依赖
    install_deps

    # 3. 安装 Xray
    install_xray || { _err "Xray 安装失败"; return 1; }

    # 3.5 安装 Nginx (SNI 分流防薅)
    install_nginx || { _err "Nginx 安装失败"; return 1; }

    # 4. 生成密钥
    init_db
    gen_keys
    local private_key public_key
    private_key=$(cat "$CFG/private.key")
    public_key=$(cat "$CFG/public.key")
    echo ""

    # 5. 选择端口
    local port
    echo -e "  ${W}选择监听端口${NC}"
    _item "1" "443 (推荐，伪装为标准 HTTPS)"
    _item "2" "8443 (备选，避开 443 冲突)"
    _item "3" "10000 (高位端口，更隐蔽)"
    _item "c" "自定义端口"
    _line
    read -rp "  请选择 [默认 1]: " port_choice
    port_choice=${port_choice:-1}
    case "$port_choice" in
        1) port=443 ;;
        2) port=8443 ;;
        3) port=10000 ;;
        c|C)
            read -rp "  输入端口号 (1-65535): " port
            [[ ! "$port" =~ ^[0-9]+$ || "$port" -lt 1 || "$port" -gt 65535 ]] && {
                _warn "无效端口，使用默认 443"
                port=443
            }
            ;;
        *) port=443 ;;
    esac
    _info "端口: $port"
    echo ""

    # 6. 选择 SNI 域名
    echo -e "  ${W}选择 SNI 伪装域名 (偷 CF CDN 域名)${NC}"
    local sni=""
    while [[ -z "$sni" ]]; do
        sni=$(select_sni_domain) || true
    done
    _info "SNI: $sni"
    echo ""

    # 7. 生成 shortId
    local short_id
    short_id=$(gen_short_id)
    _info "ShortId: $short_id"

    # 8. 生成默认用户
    local default_uuid
    default_uuid=$(gen_uuid)
    _info "默认 UUID: $default_uuid"
    echo ""

    # 9. 保存配置到数据库
    db_set_field --arg port "$port" --arg sni "$sni" \
        --arg pk "$private_key" --arg pub "$public_key" \
        --arg sid "$short_id" --arg uuid "$default_uuid" \
        --arg dest "${sni}:443" \
        '.port=($port|tonumber) | .sni=$sni | .private_key=$pk | .public_key=$pub | .short_id=$sid | .default_uuid=$uuid | .dest=$dest'

    # 10. 创建默认用户文件
    mkdir -p "$USERS_DIR"
    local created
    created=$(date '+%Y-%m-%d %H:%M')
    cat > "$USERS_DIR/default.json" <<EOF
{
  "email": "default",
  "uuid": "$default_uuid",
  "enabled": true,
  "quota_gb": 0,
  "used_bytes": 0,
  "created": "$created"
}
EOF

    # 11. 生成 Xray 配置 (监听 127.0.0.1:8443)
    generate_xray_config || { _err "配置生成失败"; return 1; }

    # 11.5 生成 Nginx SNI 分流配置 (监听 0.0.0.0:443)
    generate_nginx_sni_config || { _err "Nginx SNI 配置生成失败"; return 1; }
    create_nginx_service

    # 12. 创建并启动服务
    create_xray_service
    svc start vless-reality
    sleep 1
    svc status vless-reality 2>/dev/null | grep -qi "running\|active" && \
        _ok "Xray 服务已启动" || _warn "Xray 启动异常"

    # 停止 Nginx 默认站点 (避免端口冲突)，启动 SNI 分流
    # 清理默认站点配置 (Debian/Ubuntu 的 default site 可能占用 80/443)
    rm -f /etc/nginx/sites-enabled/default 2>/dev/null
    rm -f /etc/nginx/conf.d/default.conf 2>/dev/null
    # 停掉可能占用端口的 nginx
    svc stop nginx 2>/dev/null
    sleep 1
    svc start nginx
    sleep 1
    svc status nginx 2>/dev/null | grep -qi "running\|active" && \
        _ok "Nginx SNI 分流已启动" || _warn "Nginx 启动异常"

    # 13. 显示结果
    echo ""
    _dline
    echo -e "  ${G}安装完成!${NC}"
    _dline
    echo ""
    echo -e "  ${W}架构: Nginx (SNI分流) → Xray (Reality)${NC}"
    echo -e "  ${D}• Nginx 监听 443，SNI 匹配 $sni → 转发 Xray${NC}"
    echo -e "  ${D}• 其他 SNI → 黑洞 (防 CF CDN 流量被盗刷)${NC}"
    echo -e "  ${D}• 参考: github.com/XTLS/Xray-core/issues/2360${NC}"
    echo ""
    echo -e "  ${W}连接信息:${NC}"
    echo -e "  服务器: $ipv4"
    echo -e "  端口:   $port"
    echo -e "  SNI:    $sni"
    echo -e "  加密:   none"
    echo -e "  传输:   tcp"
    echo -e "  Flow:   xtls-rprx-vision"
    echo ""
    echo -e "  ${W}分享链接:${NC}"
    local link
    link="vless://${default_uuid}@${ipv4}:${port}?encryption=none&security=reality&type=tcp&sni=${sni}&fp=chrome&pbk=${public_key}&sid=${short_id}&flow=xtls-rprx-vision#VLESS-Reality"
    echo -e "  ${G}${link}${NC}"
    echo ""

    # 保存 join 链接
    echo "$link" > "$CFG/join.txt"
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
    if svc status vless-reality 2>/dev/null | grep -qi "running\|active"; then
        xray_status="${G}运行中${NC}"
    fi

    # Nginx SNI 分流状态
    local nginx_status="${D}未安装${NC}"
    if check_cmd nginx; then
        if svc status nginx 2>/dev/null | grep -qi "running\|active"; then
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

    local port sni short_id private_key public_key default_uuid ipv4
    port=$(db_get_field '.port' 2>/dev/null)
    sni=$(db_get_field '.sni' 2>/dev/null)
    short_id=$(db_get_field '.short_id' 2>/dev/null)
    private_key=$(cat "$CFG/private.key" 2>/dev/null || true)
    public_key=$(cat "$CFG/public.key" 2>/dev/null || true)
    default_uuid=$(db_get_field '.default_uuid' 2>/dev/null)
    ipv4=$(get_ipv4)

    echo -e "  ${W}服务器:${NC}"
    echo -e "    IPv4:     $ipv4"
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

    # 分享链接
    if [[ -n "$port" && -n "$sni" && -n "$public_key" && -n "$short_id" && -n "$default_uuid" ]]; then
        echo -e "  ${W}分享链接:${NC}"
        local link
        link="vless://${default_uuid}@${ipv4}:${port}?encryption=none&security=reality&type=tcp&sni=${sni}&fp=chrome&pbk=${public_key}&sid=${short_id}&flow=xtls-rprx-vision#VLESS-Reality"
        echo -e "  ${G}${link}${NC}"
    fi
}

#═══════════════════════════════════════════════════════════════════════════════
#  修改配置
#═══════════════════════════════════════════════════════════════════════════════

change_port() {
    local current_port new_port
    current_port=$(db_get_field '.port' 2>/dev/null)
    echo -e "  当前端口: ${W}${current_port}${NC}"
    read -rp "  新端口 [443]: " new_port
    new_port=${new_port:-443}
    [[ ! "$new_port" =~ ^[0-9]+$ ]] && { _err "无效端口"; return; }

    db_set_field --arg p "$new_port" '.port=($p|tonumber)'
    _ok "端口已改为 $new_port"

    # 同时更新 Xray 和 Nginx SNI 配置 (Nginx 监听端口也需同步)
    if generate_xray_config 2>/dev/null; then
        generate_nginx_sni_config 2>/dev/null
        restart_xray
    fi
}

change_sni() {
    local current_sni
    current_sni=$(db_get_field '.sni' 2>/dev/null)
    echo -e "  当前 SNI: ${W}${current_sni}${NC}"
    echo ""

    local new_sni=""
    while [[ -z "$new_sni" ]]; do
        new_sni=$(select_sni_domain) || true
    done

    db_set_field --arg s "$new_sni" --arg d "${new_sni}:443" '.sni=$s | .dest=$d'
    _ok "SNI 已改为 $new_sni"

    if generate_xray_config 2>/dev/null; then
        restart_xray
    fi
}

rotate_keys() {
    echo -e "  ${Y}重新生成密钥对会使所有客户端连接失效!${NC}"
    read -rp "  确认? [y/N]: " confirm
    [[ "${confirm,,}" != "y" ]] && return

    gen_keys
    local pk pub
    pk=$(cat "$CFG/private.key")
    pub=$(cat "$CFG/public.key")
    db_set_field --arg pk "$pk" --arg pub "$pub" '.private_key=$pk | .public_key=$pub'
    _ok "密钥已更新"

    if generate_xray_config 2>/dev/null; then
        restart_xray
    fi
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
    [[ "${confirm,,}" != "y" ]] && return

    _info "停止服务..."
    svc stop vless-reality 2>/dev/null
    svc stop nginx 2>/dev/null

    _info "移除 Xray 服务..."
    if [[ "$DISTRO" == "alpine" ]]; then
        rc-update del vless-reality default 2>/dev/null
        rm -f /etc/init.d/vless-reality
    else
        systemctl disable vless-reality 2>/dev/null
        rm -f /etc/systemd/system/vless-reality.service
        systemctl daemon-reload 2>/dev/null
    fi

    _info "移除 Nginx SNI 分流配置..."
    rm -f "$NGINX_SNI_CONF"
    # 从 nginx.conf 中移除 stream block
    if [[ -f /etc/nginx/nginx.conf ]]; then
        sed -i '/# SNI stream 分流/,/^}/d' /etc/nginx/nginx.conf 2>/dev/null
        sed -i '/include.*stream\.conf\.d/d' /etc/nginx/nginx.conf 2>/dev/null
    fi

    _info "删除二进制..."
    rm -f "$XRAY_BIN"

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
    if [[ "$DISTRO" == "alpine" ]]; then
        cat /var/log/messages 2>/dev/null | grep -i "xray\|vless" | tail -50 || \
            _warn "无法读取日志"
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
                    restart_xray; _pause
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

case "${1:-}" in
    --install)
        check_root; init_db; do_install
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
        echo "  --install          直接安装 (非交互)"
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
