# VLESS Reality + CF CDN

一键搭建科学上网，偷 Cloudflare CDN 域名做伪装，自带防薅羊毛。

## 这东西干嘛的？

在你的 VPS 上搭一个 VLESS Reality 代理，看起来像是在访问 Cloudflare 的正规网站，实际上是在翻墙。

**特点：**
- 偷 CF 域名伪装 — 流量看起来像正常访问 speed.cloudflare.com
- 防薅羊毛 — Nginx SNI 分流，别人拿你的 VPS 当免费代理？不存在的
- 多用户 — 给朋友家人开账号，每人独立 UUID
- 一键出链接 — 装完直接给 vless:// 链接，复制到手机就能用

## 你需要什么？

- 一台 VPS（推荐 Debian/Ubuntu，阿里云腾讯云 Vultr 都行）
- root 权限
- 会复制粘贴命令

## 安装

SSH 登录你的 VPS，复制这一行：

```bash
wget -O vless-reality-cf.sh https://raw.githubusercontent.com/shangui999/vless-reality-cf/master/vless-reality-cf.sh && chmod +x vless-reality-cf.sh && sudo ./vless-reality-cf.sh
```

然后跟着菜单走：

```
  选择监听端口
  1) 443 (推荐，伪装为标准 HTTPS)    <- 回车
  2) 38721 (随机高端口)
  c) 自定义端口
  请选择 [默认 1]:

  偷哪个 CF CDN 域名?
  1) speed.cloudflare.com  <- 推荐    <- 回车
  2) www.cloudflare.com  (CF官网)
  ...
  请选择 [默认 1]:
```

**一路回车就装完了。** 最后会给你一个 vless:// 开头的链接。

## 手机端怎么用？

### iOS (Shadowrocket / Stash)
1. 复制 vless:// 链接
2. 打开 App -> 点 + 号 -> 从剪贴板导入
3. 连上

### Android (v2rayNG / NekoBox)
1. 复制 vless:// 链接
2. 打开 App -> 右上角 + -> 从剪贴板导入
3. 连上

### Windows (v2rayN)
1. 复制 vless:// 链接
2. 服务器 -> 从剪贴板导入
3. 选节点 -> 设为活动服务器 -> 开系统代理

### macOS (V2ray U / Stash)
1. 复制 vless:// 链接
2. 导入配置
3. 连上

## 装完了，然后呢？

再运行脚本就能管理：

```bash
sudo ./vless-reality-cf.sh
```

菜单能做的事：

| 选项 | 干嘛的 |
|------|--------|
| 1 | 用户管理 -- 加人/删人/禁用 |
| 2 | 看所有分享链接 -- 发给别人用 |
| 3 | 改端口 |
| 4 | 换偷的域名 |
| 5 | 换密钥 -- 换了之后所有客户端都要更新 |
| 6 | SNI 校验 -- 检查域名还能不能偷 |
| 7 | 开 BBR -- 加速 |
| 8 | 看日志 |
| 9 | 重启服务 |
| r | 重新安装 |
| u | 完全卸载 |

## 加个朋友/家人的账号

```
sudo ./vless-reality-cf.sh
-> 选 1 (用户管理)
-> 选 2 (添加用户)
-> 输入名字: xiaoming
-> 输入邮箱: xiaoming
-> 选 5 (看分享链接)
-> 把 xiaoming 的 vless:// 链接发给他
```

## 常见问题

### Q: 连不上？
1. 检查 VPS 防火墙有没有开你选的端口（443 或其他）
2. 阿里云/腾讯云的安全组要放行对应端口
3. 跑一下 `sudo ./vless-reality-cf.sh` 选 9 重启服务

### Q: 端口被占了？
装的时候选 2（随机高端口）或 c（自定义），别用 443

### Q: 域名被墙了？
选 4 换一个域名偷

### Q: 怎么彻底删掉？
```bash
sudo ./vless-reality-cf.sh
-> 选 u (完全卸载)
```

### Q: VPS 流量会被别人偷吗？
不会。脚本自带 Nginx SNI 分流（参考 [XTLS#2360](https://github.com/XTLS/Xray-core/issues/2360)），
只有 SNI 匹配的流量才进 Xray，其他的一律黑洞丢弃。

## 架构

```
你的手机/电脑                    你的 VPS
    |                              |
    |  TLS 握手                    |
    |  SNI: speed.cloudflare.com   |
    +----------------------------->| Nginx (:443)
    |                              |   SNI 匹配?
    |                              |   YES -> Xray (:8443 本地)
    |                              |   NO  -> 黑洞 (断开)
    |                              |
    |  <-- CF 真证书返回            |
    |  代理流量开始传输...           |
    |                              |
```

## License

WTFPL -- You just DO WHAT THE FUCK YOU WANT TO.
