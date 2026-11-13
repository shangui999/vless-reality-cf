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

- 一台 VPS（Debian/Ubuntu/CentOS/RHEL/Alma/Rocky/Fedora/Alpine 都行）
- root 权限
- 会复制粘贴命令

## 系统支持

| 发行版 | 包管理 | 服务管理 | 说明 |
|--------|--------|----------|------|
| Debian / Ubuntu | apt | systemd | 最常用 |
| CentOS / RHEL / Alma / Rocky / Fedora | dnf / yum | systemd | 检查 stream 模块与防火墙；SELinux 策略变更需确认 |
| Alpine | apk | OpenRC | 自动装 `bash` / `nginx-mod-stream` / `nginx-openrc` |

Xray 使用指定版本的官方 Linux 构建，替换前检查可执行性、版本和现有配置，不预设需要 `gcompat`。
CentOS 7 已停止维护，依赖软件源及 EPEL 的实际可用性；脚本不会绕过失效的软件源。CentOS 系列尚未完成实机验收。
SELinux Enforcing 时需要 `semanage`（现代系统安装 `policycoreutils-python-utils`，CentOS 7 为 `policycoreutils-python`）；监听与后端端口需要 `http_port_t`，Nginx 转发需要 `httpd_can_network_relay`。脚本会说明该布尔值影响所有 `httpd_t` 服务并请求确认，不关闭 SELinux、不覆盖其他服务的端口类型。

## NAT / 双栈说明

- 脚本比较 IPv4 默认出站路由的源地址与公网探测地址；不再因为回环、Docker 等私网网卡而误判 NAT。发现地址不一致时优先把 IPv6 链接写入 `join.txt`，IPv4 入站仍需自行配置 NAT 端口转发和安全组；若外部映射端口不同，需修改客户端链接端口。
- IPv6 为直连时会自动生成 `vless://...@[IPv6]:端口` 形式的链接。

## 安装

SSH 登录你的 VPS，复制这一行：

```bash
wget -O vless-reality-cf.sh https://raw.githubusercontent.com/shangui999/vless-reality-cf/master/vless-reality-cf.sh && chmod +x vless-reality-cf.sh && sudo ./vless-reality-cf.sh
```

默认节点名为 `VLESS-<连接IP>`：IPv4 使用完整公网地址，IPv6 使用完整 IPv6 地址。首次安装输出、二维码、保存的链接与后续 `--links` 保持一致；仅改变默认账号的客户端显示名称，不修改账号名、UUID 或 Reality 协议，手动添加的账号保留原有名称。

默认固定 Xray **26.11.9**，可显式指定其他发布版本（需存在对应架构的官方资源）：

```bash
sudo ./vless-reality-cf.sh --install --xray-version 26.11.9
sudo ./vless-reality-cf.sh --xray-version=v26.11.9 --install
```

重装保留已有用户（包括禁用状态）、密钥、端口和 SNI，并重启服务使指定版本生效。二进制替换前先验证，旧版保存在 `/usr/local/bin/xray.previous`；启动失败会返回错误，不代表已自动回滚。现有 Nginx 站点不会被自动删除，端口冲突需先自行处理。

删除或禁用全部账号后不会恢复默认账号；凭据变更应用失败时会尝试停止 Xray，防止旧凭据继续提供访问。以 `--links` 输出的当前启用用户链接为准，安装时的 `join.txt` 只是初次分享快照。

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

按提示选择配置；SELinux 策略变更需要显式确认。只有配置校验及两个服务启动成功后才会显示安装完成和 `vless://` 链接。修改端口/SNI 失败时会恢复原配置，并在已经操作服务的情况下尝试恢复原服务状态。

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
