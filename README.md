# VLESS Reality + CF CDN

VLESS Reality 偷 Cloudflare CDN 域名一键部署脚本。

## 功能

- VLESS+Reality (TCP) 偷 CF CDN 域名
- 内置 CF CDN 域名推荐列表
- SNI 校验（DNS → CF IP 段 → TLS 1.3 → 证书 → HTTP）
- 多用户管理（添加/删除/启用/禁用/独立 UUID）
- 分享链接生成（vless:// 格式）
- 支持 Debian/Ubuntu/CentOS/Alpine

## 快速安装

```bash
wget -O vless-reality-cf.sh https://raw.githubusercontent.com/shangui999/vless-reality-cf/main/vless-reality-cf.sh
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
