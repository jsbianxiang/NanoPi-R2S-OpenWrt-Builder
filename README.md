# NanoPi-R2S-OpenWrt-Builder

NanoPi R2S 专用：基于 GitHub Actions + **OpenWrt 官方 Image Builder** 的自动化固件构建工作流。
本项目**专用于 FriendlyARM NanoPi R2S**，基础系统为 **OpenWrt 官方 25.12.x（apk 包管理）**。

**⚠️ 重要声明**

> 本项目为个人独立维护的第三方项目（脚本），与 OpenWrt 官方没有关联。
> 固件由 OpenWrt 官方 Image Builder 工具打包生成；用户自行定制产生的任何问题，
> 均不代表 OpenWrt 官方固件的 bug。
> 为不给上游维护者增加额外负担，相关问题请勿在 OpenWrt 社区反馈。

---

## 目标机型

| 项目 | 值 |
| --- | --- |
| 机型 | FriendlyARM NanoPi R2S |
| 平台 | Rockchip RK3328（ARM64 / aarch64_generic） |
| Image Builder profile | `friendlyarm_nanopi-r2s` |
| 内核 | OpenWrt 官方原版内核（不做自定义内核） |

机型已固定在工作流的 `env.PROFILE` 中，**不再提供机型下拉选择**。

> 本仓库**只支持 OpenWrt 25.12.x（apk 包管理）**，
> 支持 25.12.0 ~ 25.12.5（当前系列最新为 25.12.5）。

---

## 本项目的设计取舍

本项目刻意保持精简，**明确不集成**以下内容：

| 项目 | 说明 |
| --- | --- |
| Docker | 不预装 Docker / Dockerman，`99-custom.sh` 中也没有 docker 防火墙逻辑 |
| store / istore 商店 | 不集成 `luci-app-store`，工作流中也没有相关开关 |
| 第三方插件仓库 | 不克隆任何第三方插件仓库（不依赖外部 run/apk 仓库） |
| PPPoE 拨号 | WAN 默认 **DHCP** 接入（与 OpenWrt 官方默认一致），也可选静态 IP，`99-custom.sh` 中已无任何 PPPoE 逻辑 |
| 多机型 / 多网口适配 | 不做。本项目专用于 R2S，网口映射（`eth0`=WAN / `eth1`=LAN）在 `99-custom.sh` 中**硬编码**，不再探测接口数量 |

第三方软件只注入 **dllkids（kenzok8）** 一个源（默认只启用 Clashoo），
由 `rockchip/build.sh` 在构建时注入，详见下文「预置软件与第三方源」。

> ⚠ 与 ImmortalWrt 不同，**OpenWrt 官方源没有代理类插件**，也没有
> ImmortalWrt 系应用（`luci-theme-argon` / `luci-app-argon-config` /
> `luci-app-diskman` / `luci-app-cpufreq` 等）。这些包全部来自注入的
> dllkids 第三方源——不注入该源，本项目的默认包列表将无法安装。

---

## 可用工作流

| 工作流文件 | 名称 | 包管理 | 说明 |
| --- | --- | --- | --- |
| `.github/workflows/build-rockchip-openwrt-25.12.x.yml` | Build R2S OpenWrt 25.12.x | apk | 构建固件，默认 `25.12.5` |
| `.github/workflows/clean-workflow.yml` | Cleanup Old Workflow Runs | — | 维护用：手动清理旧的 Actions 运行记录（默认只保留最近 1 天） |

### 工作流输入项

| 输入 | 必填 | 默认 | 说明 |
| --- | --- | --- | --- |
| `openwrt_version` | 否 | `25.12.5` | OpenWrt / Image Builder 版本（25.12.0 ~ 25.12.5） |
| `custom_router_ip` | 是 | `192.168.2.1` | LAN 管理地址，格式 `192.168.x.1` 或 `10.x.x.1` |
| `rootfs_partsize` | 是 | `1G` | 软件包空间大小（1G / 2G / 3G / 4G） |
| `wan_proto` | 是 | `dhcp` | WAN 接入方式（`dhcp` 官方默认 / `static` 静态 IP） |
| `wan_ip` | 否 | `192.168.1.2` | WAN 静态 IP（**仅 `wan_proto=static` 时生效**，须在上级光猫网段内） |
| `wan_gateway` | 否 | `192.168.1.1` | WAN 网关（**仅 `wan_proto=static` 时生效**，上级光猫地址） |
| `wan_dns` | 否 | `192.168.1.1` | WAN DNS（**仅 `wan_proto=static` 时生效**，留空则用网关；可用空格分隔填多个，如 `223.5.5.5 1.1.1.1`） |

### 使用方法

1. 把本项目 fork 到你自己的账号（或克隆后推送到自己的仓库）。
2. 进入 **Actions**，选择需要的工作流 → **Run workflow**，填写上述输入。
3. 构建完成后，固件会作为 Release 资源（tag `Autobuild`，文件 `*.img.gz`）发布。

> **提示**：`workflow_dispatch` 类型的工作流，**其文件必须存在于仓库的默认分支上**，
> GitHub 才会在 Actions 页面显示 "Run workflow" 按钮（这是 GitHub 的硬性要求）。
> 本仓库的默认分支为 **`main`**，R2S 工作流就在 `main` 上，因此可直接触发。

---

## 固件默认属性（必读）

- 用户名 `root`，**无密码**。
- **WAN 接入方式：默认 DHCP**（与 OpenWrt 官方默认一致，不使用 PPPoE）。
  WAN 口接上级设备（光猫 / 主路由），地址由上级自动分配。
  如需固定地址，把工作流的 `wan_proto` 选为 `static`，再填写
  `wan_ip` / `wan_gateway` / `wan_dns`（默认 `192.168.1.2` / `192.168.1.1` / `192.168.1.1`）；
  此时请确保 `wan_ip` 与光猫处于同一网段（默认 `192.168.1.0/24`）且未被其他设备占用。
- **WAN6：DHCPv6 客户端**，向光猫请求 IPv6 地址与 **PD 前缀**（`reqprefix=auto`），
  供下游 LAN 分配 IPv6 使用。
- **LAN 侧 IPv6**：`delegate='0'`（不再向上游继续委派前缀）、
  `ip6assign='64'`、`ip6ifaceid='eui64'`，并**删除自动生成的 ULA 前缀**，
  避免 LAN 同时使用 ULA 与上游分配的全局前缀。
- **WAN 入站防火墙：采用 OpenWrt 官方默认策略（入站拒绝）**，
  不允许从 WAN 侧访问后台；刷机后请从 **LAN 口**访问。详见下文「WAN 入站防火墙」章节。
- **网口（R2S 本体）**：`eth0` 为 WAN（默认 DHCP），`eth1` 为 LAN，
  LAN 地址为工作流中填写的 `custom_router_ip`。对应关系见下节。
- **默认主题：Bootstrap**（OpenWrt 官方默认；如安装了 Argon 主题，
  可在 LuCI「系统 → 系统 → 语言和界面」里切换）。
- **网络 / DHCP / 防火墙的调优**由 `99-custom.sh` 在首启写入，
  逐项说明见下文「首启初始化（`99-custom.sh`）」。
- **网页终端 / SSH 只监听局域网**：`ttyd` 监听 `br-lan`、`dropbear` 监听 LAN 地址，
  均保持上游默认 —— `99-custom.sh` **不**把它们放开到所有接口。
- 上述行为全部由 `files/etc/uci-defaults/99-custom.sh` 定义，可按需修改。

### R2S 网口对应关系（重要）

本项目专用于 R2S，机型固定，`99-custom.sh` 中**不做任何接口探测**，网口映射是硬编码的，
与 OpenWrt 官方 `02_network` 的 `ucidef_set_interfaces_lan_wan 'eth1' 'eth0'` 一致：

| 内核接口 | 硬件 | 角色 | 外壳丝印 |
| --- | --- | --- | --- |
| `eth0` | 板载 GMAC（RK3328 原生，靠近 GPIO 排针） | **WAN** | WAN |
| `eth1` | USB3 RTL8153（靠近 USB 口） | **LAN** | LAN |

即 `kmod-usb-net-rtl8152` 是 **LAN 口**需要的驱动，**不是** WAN 口的 —— WAN 走的是板载
GMAC，由内核直接支持。

`br-lan` 桥及其端口、以及两个网口的 MAC 都由官方 `/bin/config_generate` 在首次启动时生成
（MAC 取自 `macaddr_generate_from_mmc_cid mmcblk0`，即由 **SD 卡 CID 派生**，
同一张卡固定不变；`LAN MAC = WAN MAC + 1`）。所以 MAC 是「本地管理地址」形式
（首字节的 bit1 置位，例如 `9E:E2:...`），这是官方设计，不是异常。

### 首启初始化（`99-custom.sh`）

固件**首次启动**时由 `/etc/uci-defaults/99-custom.sh` 一次性写入下列配置
（执行后该脚本自动删除）。脚本采用「先读取并校验全部输入、再写 UCI」的顺序，
任何一步失败都会记录到 `/etc/config/uci-defaults-log.txt` 并中止，避免写出一半的坏配置。

| 分类 | 项 | 说明 |
| --- | --- | --- |
| 网络 | WAN / WAN6 按工作流输入写入 | `dhcp` 或 `static`（CIDR 列表记法），WAN 固定 `eth0`；WAN6 为 DHCPv6 + `norelease='1'`（重启时不发 RELEASE，降低上级回收地址导致前缀变化的概率） |
| 网络 | LAN 地址改用 CIDR 列表记法 | `list ipaddr '192.168.2.1/24'` 取代 `ipaddr` + `netmask`，netifd 从前缀长度推掩码；LAN 固定 `eth1` |
| 网络 | LAN IPv6 规划 | `delegate='0'` + `ip6assign='64'` + `ip6ifaceid='eui64'` |
| 网络 | 删除 `network.globals.ula_prefix` | 去掉自动生成的 ULA 前缀，避免 LAN 双前缀 |
| 网络 | `packet_steering='1'` | 数据包引导显式开启（与「未设」等价，写出来便于 `uci show` 比对） |
| 网络 | `lan/wan/wan6` 的 `multipath='off'` | 防御性显式默认值（全局 MPTCP 未启用时不生效） |
| DHCP | 删除 `dhcp.lan.ra_slaac` / `dhcp.lan.dhcpv6` | 防御性空操作：uci-defaults 按字母序执行，本脚本（`99-*`）先于 `odhcpd.defaults` 运行，这两项此刻尚不存在；随后 `odhcpd.defaults` 写入官方默认（`dhcpv6=server`、`ra=server`、`ra_slaac=1`），最终行为与官方完全一致 |
| DHCP | `dhcp.lan.ra_preference='medium'` | 等于 odhcpd 默认值 |
| DHCP | `dhcp.wan.ignore='1'` | **显式禁用 WAN 侧 DHCP 服务**（与官方默认一致；`leasetime`/`start`/`limit` 三项仅保留配置呈现） |
| DHCP | 删除 `dnsmasq` 的 `nonwildcard` / `boguspriv` / `filterwin2k` / `filter_aaaa` / `filter_a` | 均等于官方 `/etc/config/dhcp`（dnsmasq conffile）中的默认值 |
| DHCP | 删除 `odhcpd.maindhcp` | 防御性空操作：`dhcp.odhcpd` 段此刻尚不存在（由随后的 `odhcpd.defaults` 创建，`maindhcp=0`），最终与官方一致 |
| DHCP | 删除 `dnsmasq.dns_redirect` | 官方 OpenWrt **无此选项**，删除为空操作；仅当把配置带到 ImmortalWrt 等衍生发行版时才有意义（关闭 DNS 劫持） |
| 防火墙 | `synflood_protect='1'` | 显式开启 SYN-flood 防护（官方 25.12 默认已是 1，写出以防上游变化） |
| 防火墙 | `fullcone='0'` | **显式关闭** IPv4 fullcone NAT（本机 WAN 处于双 NAT，上游 symmetric NAT 会抵消 fullcone 收益） |
| 防火墙 | 删除 `flow_offloading` / `flow_offloading_hw` | **关闭流量卸载**。flow offload 会让首包之后的流量走 fast path 绕过 netfilter 钩子，与 TPROXY 透明代理类插件冲突 |

> **有意不写入的**：`ttyd` / `dropbear` 的监听范围。两个服务保持上游默认、只监听局域网。
> 详见「WAN 入站防火墙」一节。

---

## 预置软件与第三方源

### 官方源

使用 OpenWrt 官方 Image Builder 与官方软件源，因此：

- 官方软件源中的**全部 kmod** 都可直接安装（kmods 源由 Image Builder 自动纳入，
  其依赖精确的内核版本，官方内核天然匹配）。
- Clashoo / 代理插件依赖的 `kmod-tun`、`kmod-nft-tproxy`、`kmod-nft-socket`、
  `kmod-inet-diag` 等内核模块均由官方 kmods 源解析。
- 官方源查询：<https://downloads.openwrt.org/releases/>（选对应版本 → `packages/aarch64_generic/`）。

### 第三方源：dllkids（kenzok8）

`rockchip/build.sh` 在 `make image` 之前注入 dllkids 的 APK 源与签名公钥：

```sh
DLLKIDS_FEED="https://down.dllkids.xyz/openwrt-feed/25.12/aarch64_generic/packages.adb"
DLLKIDS_KEY_URL="https://down.dllkids.xyz/openwrt-feed/keys/dllkids-feed.pub.pem"
```

> - `aarch64_generic` 必须与目标的 `ARCH_PACKAGES` 一致，否则 apk 会以架构不符拒绝。
> - 25.12 的配置启用了 `CONFIG_SIGNATURE_CHECK`，**必须**提供公钥，
>   否则安装时会报 `UNTRUSTED signature`。
> - Clashoo 与 nikki 配置冲突，**不要同时集成**。
> - **该源与公钥也会随固件发布**，因此设备端可直接 `apk update` / `apk add` /
>   `apk upgrade` 第三方系包。做法：`rockchip/build.sh` 除注入构建期用的
>   `repositories` / `keys/` 之外，还把源与公钥写进 `files/`，随固件落到
>   `/etc/apk/repositories.d/customfeeds.list` 与 `/etc/apk/keys/dllkids-feed.pub.pem`。
>   （`customfeeds.list` 是 `apk` 包为「用户自加第三方源」预留的 conffile，
>   上游默认就是三行注释占位；`CONFIG_SIGNATURE_CHECK=y`，设备端缺公钥会报
>   `UNTRUSTED signature`。）

### 预置软件包清单

默认包列表定义在 `rockchip/build.sh` 的 `PACKAGES` 变量中；
可选软件包定义在 `shell/custom-packages.sh`：

- **OpenWrt 官方源的软件**：把要装的**短名**填进 `ENABLE_APPS`（空格分隔），
  脚本会自动展开为 `luci-app-<短名>` + `luci-i18n-<短名>-zh-cn`。
  例：`ENABLE_APPS="filemanager sqm ttyd"`。A 组共 **82** 个可用短名（已逐一校验）。
- **仅第三方源提供的应用**：把短名填进 `THIRD_PARTY_APPS`，
  只展开 `luci-app-<短名>`、不加 i18n 包（该源无语言包）。B 组共 **47** 个可用短名。
- **例外**：`argon-config` / `cpufreq` / `diskman` 三个 app 包（第三方源，版本 `27.150.x`）
  **已内置简体中文**，不要给它们手工追加 `luci-i18n-<短名>-zh-cn` ——
  否则 apk 会因文件冲突报 `trying to overwrite ... owned by luci-app-...` 使
  `make image` 失败。
- 少数不是 `luci-app-<短名>` 形式的包（`luci-proto-*` / `luci-mod-*` /
  openclash / passwall 等），取消对应行注释即可。

第三方插件默认启用 Clashoo 一个。

### 如何自行增加第三方源

把源的 `packages.adb` **全路径**追加到 Image Builder 根目录的 `repositories` 文件，
并把签名公钥放进 `keys/` 目录。参考 `rockchip/build.sh` 中 dllkids 源的注入写法。

> 注意：`repositories` / `keys/` 是**构建期**注入，只让 `make image` 能找到并校验包。
> 若还希望**设备端**也能从该源安装，需像 dllkids 源那样额外把源与公钥写进 `files/`
> （见上一节说明）。

---

## 目录结构

```
.github/workflows/
  build-rockchip-openwrt-25.12.x.yml      # R2S 固件构建工作流
  clean-workflow.yml                      # 维护用：清理旧 Actions 运行记录
files/etc/uci-defaults/
  99-custom.sh                            # 首次启动初始化脚本（R2S 专用，网口映射硬编码）
rockchip/
  build.sh                                # 构建脚本 + dllkids 第三方源注入
  r2s-seed.config                         # Image Builder 配置（机型 + 签名校验）
shell/
  custom-packages.sh                      # 可选软件包开关（第三方插件默认 Clashoo）
README.md                                 # 本文件
PACKAGES.md                               # 软件包来源与启用方式说明
SUPPORT.md                                # 支持的机型列表
LICENSE                                   # 许可证
.gitattributes                            # 强制 LF 换行（shell 脚本必需）
```

> 说明：`rockchip/build.sh` 在运行时还会生成 `files/etc/config/wan-settings`，
> 工作流会生成 `custom/custom_router_ip.txt`；这两者随固件发布，但**不属于仓库文件**。

---

## WAN 入站防火墙

本项目采用 **OpenWrt 官方默认防火墙策略**：

- 固件**不提供** `/etc/config/firewall`（完全继承 `firewall4` 包的默认配置）；
- `99-custom.sh` **不修改任何区域（zone）与通信规则的策略**，只做三项全局设置：
  ① `synflood_protect='1'`（官方默认已是 1，显式写出以防上游变化）；
  ② `fullcone='0'`（显式关闭 IPv4 fullcone，双 NAT 下无收益）；
  ③ 关闭流量卸载（删除 `flow_offloading` / `flow_offloading_hw`），
     避免与透明代理类插件的 TPROXY 冲突。

官方 `firewall4` 默认配置的关键部分
（`package/network/config/firewall/files/firewall.config`，OpenWrt 25.12.5 实测原文）：

```text
config defaults
	option synflood_protect	1
	option input		REJECT
	option output		ACCEPT
	option forward		REJECT

config zone
	option name		lan
	list   network		'lan'
	option input		ACCEPT
	option output		ACCEPT
	option forward		ACCEPT

config zone
	option name		wan
	list   network		'wan'
	list   network		'wan6'
	option input		REJECT
	option output		ACCEPT
	option forward		REJECT
	option masq		1
	option mtu_fix		1
```

即 **WAN 入站默认「拒绝」**，不允许从 WAN 侧访问路由器后台。

因此刷机后请把电脑接到 **LAN 口（`eth1`，靠近 USB 口）**，再访问 `custom_router_ip`
（默认 `192.168.2.1`）。

如确实需要临时从 WAN 侧访问后台：

> 网络 → 防火墙 → wan 的入站数据 → 选择「接受」→ 保存并应用

> ⚠️ 放开后，WAN 侧同网段设备（乃至公网 IPv6，因为 `wan6` 的地址是全球可路由的）
> 都能访问**无密码**的 root 后台。调试完请务必改回「拒绝」。

> 说明：`99-custom.sh` 中不让 ttyd / dropbear 监听**所有接口** ——
> 本项目只做局域网管理，这两个服务保持上游默认：
> ttyd 监听 `br-lan`（`option interface '@lan'`，init 会把 `@` 前缀解析成网络 `lan`
> 的设备），dropbear 监听 LAN 地址（`option Interface 'lan'`，init 会解析成
> LAN 的 IP 后以 `-p <地址>:22` 启动）。

---

## 🎉 鸣谢

感谢以下项目与作者提供的上游工作（本项目派生自
[wukongdaily/ImmortalWrt-ImageBuilder](https://github.com/wukongdaily/ImmortalWrt-ImageBuilder)，
后经 ImmortalWrt 分支独立维护，现适配为 OpenWrt 官方 25.12.x）：

<div align="left">

<a href="https://github.com/openwrt"><img src="https://avatars.githubusercontent.com/openwrt?v=4&s=80" width="80" height="80" alt="openwrt" /></a>
<a href="https://github.com/wukongdaily"><img src="https://avatars.githubusercontent.com/wukongdaily?v=4&s=80" width="80" height="80" alt="wukongdaily（悟空 / 上游）" /></a>
<a href="https://github.com/kenzok8"><img src="https://avatars.githubusercontent.com/kenzok8?v=4&s=80" width="80" height="80" alt="kenzok8（Clashoo / dllkids 源作者）" /></a>
<a href="https://github.com/sirpdboy"><img src="https://avatars.githubusercontent.com/sirpdboy?v=4&s=80" width="80" height="80" alt="sirpdboy" /></a>
<a href="https://github.com/sbwml"><img src="https://avatars.githubusercontent.com/sbwml?v=4&s=80" width="80" height="80" alt="sbwml" /></a>
<a href="https://github.com/eamonxg"><img src="https://avatars.githubusercontent.com/eamonxg?v=4&s=80" width="80" height="80" alt="eamonxg" /></a>
<a href="https://github.com/timsaya"><img src="https://avatars.githubusercontent.com/timsaya?v=4&s=80" width="80" height="80" alt="timsaya" /></a>

</div>
