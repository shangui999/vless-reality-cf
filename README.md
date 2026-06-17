# VLESS Reality + CF CDN

VLESS Reality 偷 Cloudflare CDN 域名一键部署脚本，带 Nginx SNI 分流防流量盗刷。

## 功能

- VLESS+Reality (TCP) 偷 CF CDN 域名
- **Nginx SNI 分流** — 防止 VPS 变成免费 CF CDN 中转 ([#2360](https://github.com/XTLS/Xray-core/issues/2360))
- 内置 CF CDN 域名推荐列表
- SNI 校验（DNS → CF IP 段 → TLS 1.3 → 证书 → HTTP）
- 多用户管理（添加/删除/启用/禁用/独立 UUID）
- 分享链接生成（vless:// 格式）
- 支持 Debian/Ubuntu/CentOS/Alpine

## 架构

```
客户端 :443 ──▶ Nginx (SNI 分流)
                   │
                   ├── SNI = 目标域名 → Xray (127.0.0.1:8443) → 代理转发
                   │
                   └── SNI ≠ 目标域名 → 黑洞 (127.0.0.1:1) → 连接断开
```

Nginx 在 stream 层做 SSL preread，只有 SNI 匹配的流量才进入 Xray，
其他流量直接丢弃，防止 VPS 被当作免费 CF CDN 代理薅羊毛。

## 快速安装

```bash
wget -O vless-reality-cf.sh https://raw.githubusercontent.com/shangui999/vless-reality-cf/master/vless-reality-cf.sh
chmod +x vless-reality-cf.sh
sudo ./vless-reality-cf.sh
```

## 命令行用法

```bash
./vless-reality-cf.sh                    # 交互式菜单
./vless-reality-cf.sh --install          # 直接安装
./vless-reality-cf.sh --check-sni <域名>  # 校验域名
./vless-reality-cf.sh --status           # 查看状态
./vless-reality-cf.sh --links            # 查看分享链接
```

## SNI 域名选择建议

| 域名 | 说明 |
|------|------|
| `speed.cloudflare.com` | CF 官方测速站，推荐 |
| `www.cloudflare.com` | CF 官网 |
| `dash.cloudflare.com` | CF 控制面板 |
| `apps.apple.com` | Apple 子域 (CF CDN) |
| `developer.apple.com` | Apple 开发者 (CF CDN) |

选择原则：部署在 CF CDN + 大陆可访问 + TLS 1.3 + 不要太热门。

## 防薅羊毛说明

参考 [XTLS/Xray-core#2360](https://github.com/XTLS/Xray-core/issues/2360)：
当 Reality 的 dest 指向 CF CDN 域名时，非 Reality 流量会被转发到 CF Edge IP，
导致 VPS 变成免费 CF CDN 中转节点，被他人白嫖带宽翻墙。

本脚本通过 Nginx stream SNI 分流解决此问题：
- 只有 SNI 匹配目标域名的流量才转发到 Xray
- 其他 SNI 一律黑洞（连接立即断开）
- 从根源阻断流量盗刷
