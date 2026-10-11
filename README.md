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
- **WAN6：DHCPv6 客户端**，向光猫请求 IPv6 地址与 **PD 前缀**，
  供下游 LAN 分配 IPv6 使用。`reqaddress` / `reqprefix` **不显式写**——
  缺省时 odhcp6c 的行为与 `try` / `auto` 完全一致（依据见下文「等价项」表）。
- **LAN 侧 IPv6**：`delegate='0'`（不再向上游继续委派前缀）、
  `ip6assign='64'`、`ip6ifaceid='eui64'`，并**删除自动生成的 ULA 前缀**，
  避免 LAN 同时使用 ULA 与上游分配的全局前缀。
- **WAN 入站防火墙：采用 OpenWrt 官方默认策略（入站拒绝）**，
  不允许从 WAN 侧访问后台；刷机后请从 **LAN 口**访问。详见下文「WAN 入站防火墙」章节。
- **网口（R2S 本体）**：`eth0` 为 WAN（默认 DHCP），`eth1` 为 LAN，
  LAN 地址为工作流中填写的 `custom_router_ip`。对应关系见下节。
- **默认主题：Bootstrap**（`luci` 集合包自带）。
  ⚠ **不默认安装 Argon 主题**：dllkids 源的 argon 系（ImmortalWrt 生态编译）
  在官方 OpenWrt 25.12 的 LuCI 上实测会导致 web UI 无法进入
  （argon 包自带 uci-defaults 自动切换默认主题，渲染失败连登录页都挂）。
  仍想尝试见 `rockchip/build.sh` 中被注释的 argon 行与说明。
- **LuCI web 界面**：通过官方 `luci` 集合包显式安装（uhttpd + luci-base +
  luci-mod-admin-full + Bootstrap）。⚠ 官方 IB 默认包**不含** LuCI/uhttpd
  （ImmortalWrt 的 IB 默认带，官方不带）——只装 `luci-i18n-*` / `luci-app-*`
  会拉进 luci-base 但没有 web 服务器，设备上 `/etc/init.d/uhttpd` 都不存在。
- ⚠ **HTTPS：与官方固件存在差异（尚未补齐）**。官方 25.12.5 的构建配置里有
  `CONFIG_PACKAGE_luci-ssl=y`（见 `config.buildinfo`），所以官方固件自带
  uhttpd 自签证书并启用 HTTPS。而 `luci` 集合包本身只等于
  `luci-light + luci-app-package-manager`，**不含** `luci-ssl`：

  ```make
  # collections/luci/Makefile
  LUCI_DEPENDS:= +luci-light +luci-app-package-manager
  ```

  本仓库 `PACKAGES` 只写了 `luci`，因此**本固件 LuCI 只有 HTTP**。
  （uhttpd 的出厂 conffile 虽带 `list listen_https 0.0.0.0:443` 与
  `option cert /etc/uhttpd.crt`，但缺证书文件，uhttpd 会跳过 TLS 监听。）
  要补齐就在 `rockchip/build.sh` 的 `PACKAGES` 里加一行 `luci-ssl`
  —— 它会带上 `px5g-mbedtls`，首启自动生成自签证书。
- **LuCI 界面语言**：`luci.main.lang` 出厂为 `auto`（跟随浏览器语言），
  不是固定中文；中文浏览器会显示简体，要强制可写 `uci set luci.main.lang='zh_cn'`。
- **中国大陆优化**（官方默认面向全球，本项目做了以下本土化调整）：
  - **中文界面**：`luci-i18n-base-zh-cn` 预装（浏览器语言为中文时 LuCI 直接显示简体）；
  - **时区**：`Asia/Shanghai`（CST-8，官方默认 UTC）；
  - **NTP**：改为国内源（阿里 `ntp.aliyun.com` / `ntp1.aliyun.com`、
    腾讯 `time1.cloud.tencent.com`、`cn.pool.ntp.org`），替换官方 openwrt 池；
  - **TCP 拥塞控制：维持官方默认 cubic**（不预装 `kmod-tcp-bbr`，也不写 sysctl）。
    说明：安装 `kmod-tcp-bbr` 只提供模块，**不会自动启用**（官方内核
    `CONFIG_DEFAULT_TCP_CONG="cubic"`），需额外 sysctl 才生效；本项目保持官方默认。
    如需 BBR，设备端手动执行：
    `apk add kmod-tcp-bbr && echo 'net.ipv4.tcp_congestion_control = bbr' > /etc/sysctl.d/99-bbr.conf && /etc/init.d/sysctl restart`。
  - **Attended Sysupgrade 服务器保持官方默认**：`50-attendedsysupgrade`
    （`attendedsysupgrade-common` 包，随 `luci-app-attendedsysupgrade` 装上）
    写入 `attendedsysupgrade.server.url='https://sysupgrade.openwrt.org'`
    与 `client.auto_search='0'`。官方服务器在境外，国内使用较慢；
    本项目**不**擅自换成第三方 ASU 服务器（地址不匹配会导致在线升级失败）。
  - **设备端软件源：先备份官方，再切换中科大镜像**：`build.sh` 以 Image
    Builder 的官方 `repositories`（与设备端 distfeeds 同源，含 kmods 内核
    哈希路径）为蓝本，把官方原文备份到
    `/etc/apk/repositories.d/distfeeds.list.official.bak`（apk 不读取
    `.bak`，仅作回滚底稿），再把 `distfeeds.list` 里的
    `downloads.openwrt.org/releases/` 替换为
    `mirrors.ustc.edu.cn/openwrt/releases/`（目录结构与官方逐位一致，
    包与签名完全相同，仅下载通道不同）。dllkids 源在 `customfeeds.list`，
    不受影响；回滚只需把 `.bak` 覆盖回 `distfeeds.list`。
    ⚠ `distfeeds.list` 不是 conffile：sysupgrade 升级后会随 apk 包恢复为
    官方源，需重新替换（重新跑一次构建即可）。
- **网络 / DHCP / 防火墙的调优**由 `99-custom.sh` 在首启写入，
  逐项说明见下文「首启初始化（`99-custom.sh`）」。
- **网页终端 / SSH 只监听局域网**：默认固件**不含** ttyd（需要时用
  `ENABLE_APPS` 加 `ttyd` 启用）与 filemanager；`dropbear` 监听 LAN 地址。
  若启用了 ttyd，它监听 `br-lan`——两者均保持上游默认，
  `99-custom.sh` **不**把它们放开到所有接口。
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
任何一步失败都会记录到 `/etc/openwrt-builder/uci-defaults-log.txt` 并中止，避免写出一半的坏配置。

> 这里的「一次性」是相对**同一次 rootfs** 而言：每次刷机（含「保留配置」）rootfs 都被整镜像
> `dd` 覆盖，`/etc/uci-defaults/` 里的脚本会全部重新出现并再跑一遍（推导见
> [`MIGRATIONS.md`](MIGRATIONS.md) §5.1）。所以本脚本也同时承担了「升级后修配置」的职责。

| 分类 | 项 | 说明 |
| --- | --- | --- |
| 网络 | WAN / WAN6 按工作流输入写入 | `dhcp` 或 `static`（CIDR 列表记法），WAN 固定 `eth0`；WAN6 为 DHCPv6 + `norelease='1'`（重启时不发 RELEASE，降低上级回收地址导致前缀变化的概率） |
| 网络 | LAN 地址改用 CIDR 列表记法 | `list ipaddr '192.168.2.1/24'` 取代 `ipaddr` + `netmask`，netifd 从前缀长度推掩码；LAN 固定 `eth1` |
| 网络 | LAN IPv6 规划 | `delegate='0'` + `ip6assign='64'` + `ip6ifaceid='eui64'` |
| 网络 | 删除 `network.globals.ula_prefix` | 去掉自动生成的 ULA 前缀，避免 LAN 双前缀 |
| DHCP | `dhcp.lan.dhcpv6='server'` / `ra='server'` | 显式钉死 LAN 侧 DHCPv6 与 RA。这两个选项由 **odhcpd** 读，而 odhcpd 内置默认是 `MODE_DISABLED`（`src/config.c:312-314`），**没有** dnsmasq 兜底 ⇒ 缺失就等于关掉 LAN 的 DHCPv6 与 RA |
| DHCP | `dhcp.@dnsmasq[0].cachesize` 缺失则补 `1000` | `dnsmasq.init:1028` 只是 `append_parm cachesize "--cache-size"`（无默认），缺失时用 dnsmasq 内置的 `150`；官方 conffile 是 `1000`。**只在缺失时补**，不覆盖用户自设值 |
| 防火墙 | `synflood_protect='1'` | 显式开启 SYN-flood 防护（官方 25.12 默认已是 1，写出以防上游变化） |
| 防火墙 | 删除遗留别名 `syn_flood` | 官方 conffile 写的是旧名 `syn_flood`；fw4 与 LuCI 都把 `syn_flood` 迁移到 `synflood_protect`，本项目同样只保留现代选项名（详见第 4.1 节） |
| 大陆优化 | 时区 `Asia/Shanghai`（CST-8） | 官方默认 UTC，改为北京时间 |
| 大陆优化 | NTP 改用国内服务器 | 阿里 `ntp.aliyun.com` / `ntp1.aliyun.com`、腾讯 `time1.cloud.tencent.com`、`cn.pool.ntp.org`，替换官方 openwrt 池 |

#### 脚本第 4 节：Web 界面「网络」菜单**保存**产生的旧参数名 → 新参数名迁移

这一节的范围严格限定为：在 LuCI 的**「网络」菜单**任一页面点「保存并应用」时，由该页面
option 的 `o.write` 处理器产生的重命名。**不含**「打开页面时的弹窗迁移」（见第 10 节）
和「官方首启脚本」——那两类虽然也会改名，但不是「保存」产生的。

「网络」菜单成员（对照 `luci-25.12` 的 `menu.d` JSON）：`luci-mod-network` 的
`network`(10，接口) / `wireless`(15) / `switch`(20) / `routes`(30) / `dhcp`(40) /
`dns`(45) / `diagnostics`(50)，以及 `luci-app-firewall` 的
**`admin/network/firewall`(60)** —— **防火墙也在「网络」菜单下**，它的保存路径同属本节范围。

把「网络」菜单下**全部** `o.write` 处理器过了一遍，真正的旧 → 新重命名只有三处：

| # | 迁移 | 源码位置 | 本项目 | 说明 |
| --- | --- | --- | --- | --- |
| ① | `firewall.@defaults[0].syn_flood` → `synflood_protect` | `firewall/zones.js:43-51` | **已实现（4.1）** | 写新名 + 删旧别名。官方无首启脚本；fw4 只有运行期回退（`fw4.uc`：`if (defs.synflood_protect === null) defs.synflood_protect = defs.syn_flood;` 然后 `delete defs.syn_flood;`）。删旧名让 `uci show firewall` 输出唯一 |
| ② | `network.<route>.netmask` → CIDR 合写进 `target` | `network/routes.js:61-78` | 有意不做 | `o.write` 确是保存路径，但 netifd **仍然解析** `netmask`（`interface-ip.c:53 ROUTE_MASK`、`:458 parse_netmask_string`、`proto.c:47 OPT_NETMASK`），属**等价改写**而非功能迁移；本项目不创建静态路由，没有对象可迁 |
| ③ | `firewall.<zone>.extra` → `extra_src` / `extra_dest` | `firewall/zones.js:314-341` | 有意不做 | `o.write` 确是保存路径，但整块被 `if (!fw4) { … }` 包住——**只有 fw3 才渲染「Extra iptables arguments」标签页**；本固件是 fw4（manifest：`firewall4 2025.03.17~b6e51575-r2`），该页不存在，永不触发 |

所以第 4 节**只实现 ①**。

> 关于 `syn_flood`：官方 conffile 写的是旧名，LuCI 的复选框 `cfgvalue` 读
> `synflood_protect` 并以 `syn_flood` 兜底，`o.write` 则是「先 `unset syn_flood`、
> 再 `set synflood_protect`」。本项目照做：先置新选项、再删旧别名——即使删除步骤异常，
> fw4 的回退分支仍能兜住防护。`syn_flood` **不是**死选项（fw4 与 LuCI 都识别），
> 删除属「迁移」而非「清理垃圾」。

#### 等价项：判定为「不写也一样」而**不写**的选项

写入原则是「**只写与「不写时的生效值」不同的项**」。下面这些曾经写过、现已删除，
每一条都核过源码：

| 已不写的项 | 「不写时」的生效值 | 依据 |
| --- | --- | --- |
| `network.wan6.reqaddress='try'` | 同样是 `TRY` | 不写时 odhcp6c 收不到 `-N`，其内置默认就是 `IA_MODE_TRY`（odhcp6c `src/config.c:85`）；显式 `'try'` 走的 `config_set_request_addresses("try")` 也落在同一枚举值 |
| `network.wan6.reqprefix='auto'` | 同样是 `auto` | `odhcp6c/files/dhcpv6.sh:101` `[ -z "$reqprefix" -o "$reqprefix" = "auto" ] && reqprefix=0` —— 空值与 `auto` 在 proto 层被归一成同一个值，都发 `-P0` |
| `network.globals.packet_steering='1'` | 同样是**开启** | 唯一消费者 `/etc/init.d/packet_steering` 只在值为字面量 `'0'` 时关闭引导（`packet-steering.uc`: `case '0': disable = true;`）；选项缺失时传入空串，不命中该分支。（该 init 脚本由 netifd 包安装，`default_postinst` 会对包内所有 `/etc/init.d/*` 执行 `rc.common enable`，所以它确实在跑。） |
| 补 `network.globals` 段的 `if ! uci -q get …` 守卫 | 段总是存在 | `config_generate` 无条件写 `delete network.globals; set network.globals='globals'; set network.globals.dhcp_default_duid='auto'` ⇒ 分支永不触发，是死代码 |
| `dhcp.wan.ignore='1'` | 同样是 `1` | 官方 dnsmasq conffile `files/dhcp.conf` 里就有 `config dhcp wan` / `option ignore 1` |
| `dhcp.lan.dhcpv4='server'` | 同样是「下发 DHCPv4」 | 本固件上它只有一个有效消费者 **dnsmasq**：`dnsmasq.init:578` 无默认取值 + `:602` `if [ "$dhcpv4" != "disabled" ]` ⇒ 缺失（空串）≠ `disabled`，照常下发。odhcpd 虽也注册了该属性，但 `src/config.c:1282` `iface->dhcpv4 = config.main_dhcpv4 ? mode : MODE_DISABLED;`，而官方 `15_odhcpd` 写的 `maindhcp=0` ⇒ 对 odhcpd 恒无影响 |
| 删除 `system.ntp.enabled` | 同样是「NTP 开」 | sysntpd 的校验串是 `'enabled:bool:1'`（缺省 1），`config_generate` 也写 `set system.ntp.enabled='1'` ⇒ 存在为 1、或缺失，行为相同。唯一有差异的情形是旧配置被显式设成 `enabled='0'`（用户有意关掉 NTP），此时删除反而会**越权**把它打开——第 8 节只替换 NTP 服务器列表，不改开/关 |

**保留**的近似项及其不可省的理由：

| 保留项 | 为什么不能删 |
| --- | --- |
| `network.wan=interface`、`network.wan6=interface` | 不是值写入而是**前置条件**：libuci 的 `uci_set` 有断言 `UCI_ASSERT(ctx, ptr->s \|\| (!ptr->option && ptr->section))`（`list.c:690`），段不存在时 `uci set <段>.<选项>=…` 会直接报错。同理保留 `require_uci_section` 里真正会被写入的那几个段 |
| `network.wan6.norelease='1'` | 不写 ≠ 1：`dhcpv6.sh:148` `[ "$norelease" = "1" ] && append opts "-k"`，只有显式 1 才加 `-k` |
| `dhcp.lan.dhcpv6='server'`、`ra='server'` | odhcpd 内置默认是 `MODE_DISABLED`（`src/config.c:312-314`），且**没有** dnsmasq 兜底；保留配置升级时 `15_odhcpd` 走迁移分支直接 `exit 0`、不补默认（见 [`MIGRATIONS.md`](MIGRATIONS.md) §5.2） |
| `network.lan.delegate='0'`、`ip6assign='64'`、`ip6ifaceid='eui64'` | 三项都与默认不同：`delegate` 默认 true（`interface.c:1053` `blobmsg_get_bool_default(..., true)`）、`config_generate` 给 LAN 写的是 `ip6assign='60'`、`ip6ifaceid` 默认是固定 ID `::1`（`interface.c:1002-1004`） |
| `network.lan.proto='static'`、`network.wan.proto=…` | 决定工作流选定的 WAN 模式 / 让 LAN 的 `list ipaddr` 真正生效，不是「补默认」 |
| `dhcp.@dnsmasq[0].cachesize` | 条件写入（仅缺失时补），官方 conffile 与 dnsmasq 内置值不同（1000 vs 150） |

#### 脚本第 10 节：非「保存路径」的迁移（冗余加固，可整节删除）

这些**不是** LuCI「网络」菜单保存产生的结果，列在脚本里只为兜底；把 10.1 ~ 10.3
整节删掉不影响其他章节。

| # | 迁移 | 真实归属 | 节 | 依据 |
| --- | --- | --- | --- | --- |
| 1 | `network.<if>.ifname` → `device`（非 bridge、且无 `device` 的接口段） | LuCI **打开页面时**的弹窗（`render()` → `renderIfnameMigration()`），**不是保存** | 10.1 | LuCI `…/view/network/interfaces.js`。**官方首启脚本没有实现**——netifd 至今保留显式向后兼容（`interface.c:53 IFACE_ATTR_IFNAME, /* Backward compatibility */`、`:1091-1093`），所以只有 LuCI 会提示改名 |
| 2 | `rpcd.@rpcd[0].socket`：`/var/run/ubus.sock` → `/var/run/ubus/ubus.sock` | 官方首启脚本 | 10.2 | `rpcd/files/50-migrate-rpcd-ubus-sock.sh` |
| 3 | `uhttpd.main.ubus_socket`：同上 | 官方首启脚本 | 10.2 | `uhttpd/files/ubus.default`（安装为 `00_uhttpd_ubus`） |
| 4 | `uhttpd.main.ubus_prefix` 缺失则补 `/ubus` | 官方首启脚本 | 10.2 | 同上。**关键项**：`uhttpd/main.c:636 if (conf.ubus_prefix && uh_plugin_init("uhttpd_ubus.so"))` —— 该值为空时 uhttpd-mod-ubus **根本不加载**，LuCI 的 `/ubus` RPC 端点不存在 |
| 5 | `dhcp.@dnsmasq[0].resolvfile`：`/tmp/resolv.conf.auto` → `/tmp/resolv.conf.d/resolv.conf.auto` | 官方首启脚本 | 10.3 | `dnsmasq/files/50-dnsmasq-migrate-resolv-conf-auto.sh`。旧值会让 dnsmasq 读一个不存在的文件并 `touch` 出空文件当上游，**设备自身 DNS 全挂** |

> 原先的第 10.4 节（删除 `system.ntp.enabled`）已删除，理由见上面「等价项」表。

> **为什么官方首启脚本做过的事还要重复一次？** 每次刷机（含「保留配置」）rootfs 都会被
> 整镜像 `dd` 覆盖，官方这些一次性脚本会重新出现并再跑一遍（推导见
> [`MIGRATIONS.md`](MIGRATIONS.md) §5.1），所以它们在正常流程里是冗余的。保留的理由：
> ① 各自只有几行且幂等；② 这几项一旦是旧值，后果是 **LuCI / DNS 整体不可用**，
> 值得在本项目自己的脚本里再钉一遍；③ 上游将来删掉这些一次性脚本后仍然有效。
> **不认同这个取舍就把 10.1 ~ 10.3 整节删掉。**

> 与 LuCI 的一处**有意差异**：LuCI 走 ubus 的 `uci set` API 把 `ifname` 写成**空字符串**
> （rpcd `uci.c` 的 `rpc_uci_merge_set` 把空串当普通值下发，不等于删除），于是会留下
> `option ifname ''`。本脚本改成真正 `delete`：有效配置完全相同，但不会残留空选项。
> 其余由上游承担的迁移（桥 `ifname`→`ports`、`release`→`norelease`、dnsmasq `ipset`→段、
> odhcpd 的 `piofolder`/`hostsfile` 等）也不重复，清单见
> [`MIGRATIONS.md`](MIGRATIONS.md) §3.3。

> **TCP 拥塞控制**不在首启脚本里：本项目维持官方默认 cubic，不预装
> `kmod-tcp-bbr`；设备端手动启用 BBR 的方法见上文「中国大陆优化」一节。

> **首启执行顺序**（已对照官方 `openwrt-25.12` 源码逐项核实；完整迁移清单见
> [`MIGRATIONS.md`](MIGRATIONS.md)）：
>
> 1. **preinit 阶段**：`/lib/preinit/82_config_generate` 生成 `/etc/board.json`
>    与 `/etc/config/network`（其中 `network.globals.ula_prefix='auto'`）；
> 2. `/etc/init.d/boot` 的 `uci_apply_defaults()` 按文件名 **ASCII 字母序**执行
>    `/etc/uci-defaults/`（`files="$(ls)"`，子 shell 内 source，最后统一 `uci commit`，
>    成功执行的脚本随即被删除）：
>    `00_uhttpd_ubus` → `10-fstab` → `10_migrate-shadow` → `11_network-migrate-bridges`
>    → `12_network-generate-ula`（把 `auto` 落成随机 ULA 前缀）→ `14_migrate-dhcp-release`
>    → `14_network-generate-duid` → `15_migrate-time-zonename` → **`15_odhcpd`**
>    （创建 `dhcp.odhcpd`，写入 `dhcp.lan` 的 `dhcpv4/dhcpv6/ra=server`、
>    `ra_slaac=1`、`ra_flags`）→ `30_uboot-envtools` → `50-attendedsysupgrade`
>    （写 `/etc/config/attendedsysupgrade`）→ `50-dnsmasq-migrate-ipset.sh`
>    → `50-dnsmasq-migrate-resolv-conf-auto.sh` → `50-dropbear`
>    → `50-migrate-rpcd-ubus-sock.sh` → `50-root-passwd`
>    → `95-luci-app-attendedsysupgrade-housekeeping` → **`99-custom.sh`（本仓库）**。
>
> ⚠ 注意 `15_odhcpd` 排在 `99-custom.sh` **之前**（odhcpd 的**源文件**名叫
> `odhcpd.defaults`，**安装名**才是 `15_odhcpd`）——本脚本运行时
> `dhcp.odhcpd` 与 `dhcp.lan` 的 IPv6 选项**都已存在**。
>
> ⚠ **`13_fix-group-user` 不在这个列表里**：base-files 的 Makefile 在
> `ifneq ($(CONFIG_USE_APK),)` 分支中把它 `rm -f` 掉了（apk 固件里
> `/usr/lib/opkg/info` 也不存在，脚本自身开头就会 `exit 0`）。`20_migrate-feeds`
> 同理不适用（属 opkg 包）。详见 [`MIGRATIONS.md`](MIGRATIONS.md) §1.1。
>
> ⚠ 若选择「保留配置」刷机，`15_odhcpd` **不是完全空转**：`dhcp.odhcpd` 已存在时它会
> 执行 odhcpd 自己的四个选项迁移（`piofolder`→`piodir`、删 `legacy`、
> `hostsfile`→`hostsdir`、`leasefile` 旧值）后 `exit 0`，但**官方默认值不会被补回**。
> 详见 [`MIGRATIONS.md`](MIGRATIONS.md) §5。

> **已移除的无效/有害项**（此前版本存在，经与官方 v25.12.5 源码核对后清理）：
> `multipath='off'`（官方 netifd 无此选项，MPTCP 属 ImmortalWrt 补丁）、
> `fullcone='0'`（官方 firewall4 无此选项）、`dns_redirect` 删除（官方无此选项）、
> `ra_slaac` / `odhcpd.maindhcp` 的防御性删除（空操作：odhcpd 内置默认分别为
> `true` / `false`，与 `15_odhcpd` 写入的官方值一致）、
> **`dhcpv6` 的防御性删除（有害，必须移除）**：odhcpd 内置默认是 `MODE_DISABLED`，
> 删掉 `15_odhcpd` 先写入的 `'server'` 会**关掉 LAN 的 DHCPv6 服务**，
> 使下游设备拿不到 IPv6 地址、
> `ra_preference='medium'`（与 odhcpd 默认等价）与 dnsmasq 五项删除
> （`nonwildcard` / `boguspriv` 默认 1、`filterwin2k` / `filter_aaaa` / `filter_a`
> 默认 0，与官方 conffile 完全相同，属空操作）、
> wan 段的 `leasetime` / `start` / `limit`（`ignore='1'` 下 WAN 侧本就没有 DHCP 服务）。
> 现在改为**显式写出**其中两个值（`dhcp.lan.dhcpv6='server'` / `ra='server'`，与
> `15_odhcpd` 写入的官方默认相同）——不是为了改行为，而是让「官方默认」不再依赖
> `15_odhcpd` 是否被跳过：保留配置升级时它会走迁移分支、不补默认，选项缺失就会真的
> 关掉 DHCPv6 / RA。`dhcpv4` 则**不再写**：本固件上它只对 dnsmasq 有效，而 dnsmasq 把
> 「缺失」当作「照常下发」，与 `'server'` 等价（依据见上文「等价项」表）。

> **另需与上表区分**：`firewall.@defaults[0].syn_flood` 的删除**不属于**「无效/有害项」。
> `syn_flood` 是 firewall4 与 LuCI 都识别、且**都会主动迁移**的遗留别名
> （见下文「WAN 入站防火墙」一节的选项名说明），删它是为了让配置语义唯一，
> 而不是因为它无人读取。其余所有「上游自带的迁移」汇总在
> [`MIGRATIONS.md`](MIGRATIONS.md)。

> **有意不写入的**：`ttyd` / `dropbear` 的监听范围。两个服务保持上游默认。
> 其中 ttyd 的出厂配置是 `option interface '@lan'`（init 把 `@` 前缀解析成网络 `lan`
> 的设备，即 `br-lan`）；**dropbear 的出厂配置没有 `Interface` 选项**
> （`dropbear.init` 的 `uci_load_validate` 也没给默认值），因此它监听**所有地址**
> （`0.0.0.0:22` + `[::]:22`），WAN 侧靠防火墙 `wan` zone 的 `input REJECT` 挡住。
> 若想让 SSH 也只绑 LAN，需自己加 `uci set dropbear.@dropbear[0].Interface='lan'`。
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
- **例外**：`cpufreq` / `diskman` 两个 app 包（第三方源，版本 `27.150.x`，
  **默认不装**，取消 `rockchip/build.sh` 中对应行注释即可启用）
  **已内置简体中文**，启用时不要手工追加 `luci-i18n-<短名>-zh-cn` ——
  否则 apk 会因文件冲突报 `trying to overwrite ... owned by luci-app-...` 使
  `make image` 失败。（可选项 `argon-config` 同样内置中文、同样适用此规则。）
- 少数不是 `luci-app-<短名>` 形式的包（`luci-proto-*` / `luci-mod-*` /
  openclash）：在 2.3 取消对应行注释即可；passwall 用「三」B 组短名启用。

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
shell/
  custom-packages.sh                      # 可选软件包开关（第三方插件默认 Clashoo）
README.md                                 # 本文件
PACKAGES.md                               # 软件包来源与启用方式说明
MIGRATIONS.md                             # 迁移变化总清单（首启/运行期/上游别名，含源码出处）
SUPPORT.md                                # 支持的机型列表
LICENSE                                   # 许可证
.gitattributes                            # 强制 LF 换行（shell 脚本必需）
.gitignore                                # 忽略构建期产物（files/etc/openwrt-builder、custom 等）
```

> 说明：`rockchip/build.sh` 在运行时还会生成 `files/etc/openwrt-builder/wan-settings`、
> `files/etc/apk/repositories.d/` 下的
> `customfeeds.list` / `distfeeds.list` / `distfeeds.list.official.bak` 与
> `files/etc/apk/keys/` 下的公钥；工作流会生成 `custom/custom_router_ip.txt`。
> 以上均随固件发布，但**不属于仓库文件**（已在 `.gitignore` 中忽略）。

### 构建期辅助文件为什么放在 `/etc/openwrt-builder/`

**`/etc/config/` 里只能放 uci 配置包**，这是本项目的一条硬约束，原因是 libuci 的
目录扫描规则（源：`openwrt/uci` 仓库 `file.c`）：

- `uci_list_config_files()` 用 `glob("<confdir>/*", GLOB_MARK)` **扫描整个目录**，
  并不按扩展名过滤；
- `get_filename()` 只跳过「文件名**含 `.`**」的条目，源码注释原文：

  ```c
  /*
   * Filename with '.' are ignored and not parsed. Uci doesn't
   * permit config files with '.' in the name and cause parsing
   * problems.
   */
  ```

- 其余条目经 `uci_validate_package()` 校验（只放行可打印 ASCII，`-` 也允许，
  挡不住 `wan-settings` 这种名字）后，**一律按 uci 语法解析**。

因此一个无后缀、内容又是 `key=value` 的文件（例如旧版的
`/etc/config/wan-settings`）会被当成配置包解析：首行 `wan_proto=dhcp` 不匹配
`package` / `config` / `option` / `list` 任一关键字，直接命中 `file.c:553` 的
`uci_parse_error(ctx, "invalid command")`。现象是**任何** uci 调用都打印：

```text
uci: Parse error (invalid command) at line 1, byte 0
```

LuCI 的「软件包」页安装/卸载软件同样经由 uci，所以那里也会看到同一行错误。

> 结论：构建期注入的辅助文件（`wan-settings`、`custom_router_ip.txt`、
> `uci-defaults-log.txt`）统一放 `/etc/openwrt-builder/`，与 `/etc/config/` 彻底分开。
> 工作流中 `custom/` 也因此挂载到 `/builder/files/etc/openwrt-builder/`
> 而非 `/builder/files/etc/config/`。

> 若你的设备是在**修复前**刷的固件，`/etc/config/wan-settings` 会残留并持续报错。
> 该文件只在首启时被读取一次，直接删掉即可：
>
> ```sh
> rm -f /etc/config/wan-settings
> ```
>
> 新版固件已把该文件移到 `/etc/openwrt-builder/`；并且 `99-custom.sh` 会在首启
> **任何 uci 调用之前**顺手 `rm -f /etc/config/wan-settings`，因此**保留配置
> 升级**到新版后该问题会自动消失（无需手动处理）。


---

## WAN 入站防火墙

本项目采用 **OpenWrt 官方默认防火墙策略**：

- 固件**不提供** `/etc/config/firewall`（完全继承 `firewall4` 包的默认配置）；
- `99-custom.sh` **不修改任何区域（zone）与通信规则的策略**，只做两项全局设置：
  `synflood_protect='1'`（官方默认已是 1，显式写出以防上游变化），并删除官方
  conffile 里的遗留别名 `syn_flood`（脚本第 4.1 节，属「迁移」而非「清理垃圾」）。
  流量卸载（`flow_offloading` / `flow_offloading_hw`）官方默认即关闭，不做改动；
  官方 firewall4 没有 fullcone 选项，此前版本的 `fullcone='0'` 已移除。
  注意：日后若启用 passwall 等 TPROXY 透明代理插件，请**不要**在 LuCI 里开启
  流量卸载——flow offload 会让首包之后的流量走 fast path 绕过 netfilter 钩子。

官方 `firewall4` 默认配置的关键部分
（源：`openwrt/firewall4` 仓库 `root/etc/config/firewall`，25.12 所用版本
`b6e5157527d361f99ad52eaa6da273cb0f2dfd59` 原文；`firewall4` 的源码由
`package/network/config/firewall4/Makefile` 以 git 方式拉取，不在主仓库里）：

```text
config defaults
	option syn_flood	1
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
	option forward		DROP
	option masq		1
	option mtu_fix		1
```

> **关于 SYN flood 选项名（`syn_flood` → `synflood_protect`）**：
> 默认配置文件里写的是**遗留名** `syn_flood`，而 firewall4 实际读取的是
> `synflood_protect`。`root/usr/share/ucode/fw4.uc` 的 `defaults` 表里两个名字
> **都声明了**，随后做一次归一化并**主动删掉旧名**：
>
> ```ucode
> syn_flood:          [ "bool" ],
> synflood_protect:   [ "bool" ],
> synflood_rate:      [ "limit", "25/second" ],
> synflood_burst:     [ "int", "50" ],
> ...
> if (defs.synflood_protect === null)
>     defs.synflood_protect = defs.syn_flood;
> delete defs.syn_flood;
> ```
>
> 规则生成在 `templates/ruleset.uc`，用 `fw4.default_option("synflood_protect")`
> 决定是否产出 `syn_flood` 链与限速跳转规则 —— 因此官方默认**已开启**防护
> （`synflood_rate` 默认 `25/second`、`synflood_burst` 默认 `50`）。
>
> LuCI 也是同一套逻辑（`luci-app-firewall` 的 `view/firewall/zones.js`，
> 分支 `openwrt-25.12`）：
>
> ```js
> o = s.option(form.Flag, 'synflood_protect', _('Enable SYN-flood protection'));
> o.cfgvalue = function(section_id) {                 // 读：优先新名，回退旧名
>     const val = uci.get('firewall', section_id, 'synflood_protect');
>     return (val != null) ? val : uci.get('firewall', section_id, 'syn_flood');
> };
> o.write = function(section_id, value) {             // 写：删旧名、写新名
>     uci.unset('firewall', section_id, 'syn_flood');
>     uci.set('firewall', section_id, 'synflood_protect', value);
> };
> ```
>
> 所以本项目做的事和 LuCI 一致：**写 `synflood_protect='1'` + 删 `syn_flood`**。
> 两个后果都是期望的：
>
> 1. LuCI「常规设置 → 启用 SYN-flood 防护」复选框读的是 `synflood_protect`，
>    因此正确显示为**已勾选**；
> 2. `uci show firewall` 里不再同时出现新旧两个名字，语义唯一。
>
> ⚠️ `syn_flood` **不是死选项**（fw4 与 LuCI 都识别它），删它是「迁移」而不是
> 「清理垃圾」——若将来有人把 `synflood_protect` 删掉，回退链也随之消失，防护会关。
> `99-custom.sh` 里因此**先置新选项、再删旧别名**，即使删除步骤异常，回退分支仍能兜住。

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

## 从旧固件（ImmortalWrt 时期）保留配置刷机的遗留项

**刷机时若选择「保留配置」（sysupgrade 默认行为 / LuCI 勾选 keep settings），
`/etc/config` 会沿用旧固件的文件**，于是会出现三类现象（已在实机 `uci show` 中确认）：

**① 旧配置留下的死选项（官方 netifd / odhcpd 不识别或本就等价）**

| 遗留项 | 说明 |
| --- | --- |
| `network.lan.multipath` / `network.wan.multipath` / `network.wan6.multipath` | ImmortalWrt 的 MPTCP 补丁选项，**官方 netifd 源码中不存在**（已核实），写入后无人读取 |
| `network.wan.sendclientid` / `network.wan6.sendclientid` | 选项**确实存在**于官方 netifd（`proto_config_add_string sendclientid`），但未设置时会走 `case "$sendclientid" in ... auto\|*)` 分支，行为与 `auto` **完全等价**——显式写属冗余 |
| `dhcp.lan.ra_preference='medium'` | 与 odhcpd 默认值相同，纯属旧配置残留 |

**② 官方默认值丢失（比死选项更需要处理）**

旧版脚本（ImmortalWrt 时期）曾执行 `uci delete dhcp.lan.dhcpv6`、`uci delete dhcp.lan.ra_slaac`；
而 `15_odhcpd` 只在 `dhcp.odhcpd` 段**不存在**时才写入官方默认（它开头就有
`[ -n "$(uci -q get dhcp.odhcpd)" ] && ... exit 0`）。保留配置刷机时 `dhcp.odhcpd`
已存在 → `15_odhcpd` 直接跳过 → 被删掉的官方默认**不会恢复**：

- `dhcp.lan.dhcpv6` 缺失 → odhcpd 内置默认是 `MODE_DISABLED` → **LAN 的 DHCPv6 服务实际是关闭的**；
- `dhcp.lan.ra_slaac` 缺失 → odhcpd 内置默认 `true`，SLAAC 仍工作（所以 IPv6 地址一般还能拿到）；
- `dhcp.@dnsmasq[0]` 也少了几项官方 conffile 的值（`boguspriv` / `filterwin2k` /
  `nonegcache` / `cachesize` / `resolvfile` / `nonwildcard` / `filter_aaaa` / `filter_a`）——
  其中多数与 init 脚本内置默认等价，**只有 `cachesize` 有差异**（官方 conffile `1000`，
  未设时为 dnsmasq 内置的 `150`）。

**③ 旧选项名（有对应的新写法）**

| 遗留写法 | 新写法 | 谁负责迁移 |
| --- | --- | --- |
| `firewall.@defaults[0].syn_flood` | `synflood_protect` | `99-custom.sh` **第 4.1 节**（唯一的 LuCI「网络」菜单**保存**路径重命名；fw4 有运行期回退，LuCI 保存时也会改） |
| `network.<if>.ifname`（非 bridge 段、无 `device`） | `device` | `99-custom.sh` 第 10.1 节（LuCI **打开页面时**弹窗提示改名；官方首启脚本**不**处理） |
| `config interface type=bridge` + `ifname`；`config device type=bridge` + `ifname` | `config device br-<if>` + `device` / `ports` | 官方首启 `11_network-migrate-bridges`（LuCI 也有等价弹窗） |
| `network.<if>.release` | `norelease`（**取反**） | 官方首启 `14_migrate-dhcp-release` |
| `dhcp.@dnsmasq[0].ipset` | 独立 `config ipset` 段 | 官方首启 `50-dnsmasq-migrate-ipset.sh` |
| `rpcd.@rpcd[0].socket` / `uhttpd.main.ubus_socket` = `/var/run/ubus.sock` | `/var/run/ubus/ubus.sock` | 官方首启脚本 + `99-custom.sh` 第 10.2 节 |
| `dhcp.@dnsmasq[0].resolvfile` = `/tmp/resolv.conf.auto` | `/tmp/resolv.conf.d/resolv.conf.auto` | 官方首启脚本 + `99-custom.sh` 第 10.3 节 |
| `network.<route>.netmask` = 掩码 | `target` 用 CIDR | LuCI `routes.js`（本项目**有意不做**：netifd 仍解析 `netmask`，属等价改写；且本项目不建静态路由） |
| `firewall.<zone>.extra` | `extra_src` / `extra_dest` | LuCI `zones.js`（**仅 fw3**：整块被 `if (!fw4)` 包住，本固件 fw4 上不渲染，永不触发） |

> 完整清单（含每条判据、以及经核实**不是**迁移的项）见
> [`MIGRATIONS.md`](MIGRATIONS.md) §2 / §3。
>
> **`system.ntp.enabled` 已从本表移除**：sysntpd 的缺省就是「开」，`config_generate`
> 也写 `enabled='1'`，删与不删行为相同；而旧配置里若用户**有意**设过 `enabled='0'`，
> 删除反而会把 NTP 越权打开。它既不是「网络」菜单保存产生的重命名，也属等价项，
> 故不再迁移（依据见上文「等价项」表）。

### 处理办法

**最省事：直接重刷一次（保留配置也可以）。** 每次刷机 rootfs 都会被整镜像覆盖，
`/etc/uci-defaults/` 全部重新执行，于是：

- 官方脚本会自动迁移 ③ 里的桥 / `release` / `ipset` / ubus 路径 / `resolvfile` 几项；
- `99-custom.sh` 第 4.1 节会补上官方没覆盖的 `syn_flood` → `synflood_protect`，
  第 10 节会补上 `ifname` → `device`；
- `99-custom.sh` 第 7 节会**无条件重写** `dhcp.lan.dhcpv6='server'` / `ra='server'`，
  并在 `cachesize` 缺失时补回官方值 `1000` —— 也就是把 ② 自动修好。

**若不想重刷**，推荐先手工清一次（`/etc/config` 直接沿用旧固件是这些现象的根因；
全新配置能让 `15_odhcpd` 写入完整官方默认，再由 `99-custom.sh` 在其上叠加本项目设置）。

**替代：在设备上手动清理 + 补齐**（SSH 执行，改完即生效）：

```sh
# ① 清理 ImmortalWrt 时期的死选项
uci -q delete network.lan.multipath
uci -q delete network.wan.multipath
uci -q delete network.wan6.multipath
uci -q delete network.wan.sendclientid
uci -q delete network.wan6.sendclientid
uci -q delete dhcp.lan.ra_preference

# ② 补回官方默认（旧脚本曾误删 dhcpv6 / ra_slaac；重刷后由 99-custom.sh 第 7 节自动完成）
#    注：dhcpv4 旧脚本从未删过，且 dnsmasq 视「缺失」为「照常下发」，故无需补写
uci set dhcp.lan.dhcpv6='server'
uci set dhcp.lan.ra='server'
uci set dhcp.lan.ra_slaac='1'
uci -q delete dhcp.lan.ra_flags
uci add_list dhcp.lan.ra_flags='managed-config'
uci add_list dhcp.lan.ra_flags='other-config'

# ③ 恢复官方 dnsmasq 缓存大小（重刷后由 99-custom.sh 第 7 节自动补齐）
uci set dhcp.@dnsmasq[0].cachesize='1000'

# ④ 迁移旧选项名（重刷后由 99-custom.sh 第 4 / 10 节 + 官方首启脚本自动完成）
#    —— 非 bridge 接口的 ifname → device
for s in $(uci show network | sed -n 's/^network\.\([^=]*\)=interface$/\1/p'); do
	[ -z "$(uci -q get "network.$s.device")" ] || continue
	i="$(uci -q get "network.$s.ifname")"; [ -n "$i" ] || continue
	[ "$(uci -q get "network.$s.type")" = bridge ] && continue
	uci set "network.$s.device=$i"; uci -q delete "network.$s.ifname"
done
#    —— 防火墙遗留别名
uci -q delete firewall.@defaults[0].syn_flood
uci set firewall.@defaults[0].synflood_protect='1'
#    —— ubus 路径（写错会让 LuCI / DNS 整体不可用）
[ "$(uci -q get rpcd.@rpcd[0].socket)" = /var/run/ubus.sock ] &&
	uci set rpcd.@rpcd[0].socket='/var/run/ubus/ubus.sock'
[ "$(uci -q get uhttpd.main.ubus_socket)" = /var/run/ubus.sock ] &&
	uci set uhttpd.main.ubus_socket='/var/run/ubus/ubus.sock'
[ -n "$(uci -q get uhttpd.main.ubus_prefix)" ] ||
	uci set uhttpd.main.ubus_prefix='/ubus'
[ "$(uci -q get dhcp.@dnsmasq[0].resolvfile)" = /tmp/resolv.conf.auto ] &&
	uci set dhcp.@dnsmasq[0].resolvfile='/tmp/resolv.conf.d/resolv.conf.auto'

# ⑤ 删除旧版本误放在 /etc/config/ 下的构建期辅助文件
#    （无后缀 → uci 会把它当 uci 配置包解析，导致 uci / LuCI 软件包页报
#      "Parse error (invalid command) at line 1, byte 0"；
#      新版固件已改到 /etc/openwrt-builder/，且 99-custom.sh 首启会自动清掉它，
#      这里只是给「已经刷了旧固件、暂不重刷」的设备手动补一刀）
rm -f /etc/config/wan-settings

uci commit
/etc/init.d/odhcpd restart
/etc/init.d/dnsmasq restart
/etc/init.d/rpcd restart
/etc/init.d/uhttpd restart
```

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
