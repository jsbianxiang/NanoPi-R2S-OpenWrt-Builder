# 迁移变化总清单（OpenWrt 25.12 / apk / NanoPi R2S）

本文件汇总**这台固件里所有会自动发生的「旧写法 → 新写法」迁移**，以及本项目自己做的迁移。
每条都给出源码出处，便于将来上游改动后重新核对。

**核对基准**（2026-10 拉取）：

| 来源 | 引用 |
| --- | --- |
| `openwrt/openwrt` | 分支 `openwrt-25.12`（`package/`、`target/linux/rockchip`、`include/target.mk`） |
| `openwrt/firewall4` | commit `b6e5157527d361f99ad52eaa6da273cb0f2dfd59` |
| `openwrt/odhcpd` | `master`（`files/odhcpd.defaults` 经主仓库 `package/network/services/odhcpd/Makefile` 安装） |
| `openwrt/netifd` | `master`（`config.c`） |
| `openwrt/luci` | 分支 `openwrt-25.12` |
| `openwrt/packages` | 分支 `openwrt-25.12`（`utils/attendedsysupgrade-common`） |
| 官方产物 | `25.12.5/targets/rockchip/armv8` 的 `*.manifest`（128 包）与 `config.buildinfo` |

---

## 0. 两个前置事实

### 0.1 官方镜像的包基线

`include/target.mk`：

```make
DEFAULT_PACKAGES:=\
	base-files ca-bundle dropbear fstools libc libgcc libustream-mbedtls \
	logd mtd netifd uci uclient-fetch urandom-seed urngd
DEFAULT_PACKAGES.router:=\
	dnsmasq firewall4 nftables kmod-nft-offload odhcp6c odhcpd-ipv6only \
	ppp ppp-mod-pppoe
# 非 small_flash 追加 procd-ujail
```

R2S（`DEVICE_TYPE=router`）再加上 `config.buildinfo` 里显式选中的：

```text
CONFIG_PACKAGE_luci=y
CONFIG_PACKAGE_luci-app-attendedsysupgrade=y
CONFIG_PACKAGE_luci-ssl=y          # ← 本仓库当前未装，见 §6.1
```

### 0.2 首启执行器

`package/base-files/files/etc/init.d/boot`：

```sh
uci_apply_defaults() {
	. /lib/functions/system.sh
	cd /etc/uci-defaults || return 0
	files="$(ls)"                 # ← ASCII 字母序（busybox ls 按 strcmp）
	[ -z "$files" ] && return 0
	applied=""
	for file in $files; do
		( . "./$(basename $file)" ) && applied="$applied $file"   # 子 shell 内 source
	done
	uci commit                    # ← 全部跑完才统一 commit
	sync
	rm -f $applied
}
```

注意三点：**子 shell 内 source**、**最后统一 commit**、**成功执行的脚本会被删除**（所以只跑一次）。

---

## 1. 首启 uci-defaults 迁移脚本（本固件实际存在的）

已用「包在 manifest 中」+「Makefile 的安装条件成立」双重交叉验证。排序为 `ls` 的 ASCII 序。

| # | 安装名 | 来源包 | 迁移内容 |
| --- | --- | --- | --- |
| 1 | `00_uhttpd_ubus` | uhttpd | 补 `uhttpd.main.ubus_prefix='/ubus'`；若 `ubus_socket='/var/run/ubus.sock'`（旧路径）则改为 `/var/run/ubus/ubus.sock` |
| 2 | `10-fstab` | fstools | `/etc/config/fstab` 不存在时 `block detect` 生成（**生成**，非迁移） |
| 3 | `10_migrate-shadow` | base-files | `/etc/passwd` 里的 root 口令哈希搬进 `/etc/shadow`（仅当 passwd 有哈希而 shadow 没有） |
| 4 | `11_network-migrate-bridges` | base-files | `config device type=bridge` 的 `ifname` → `ports`；`config interface type=bridge` → 新建 `config device name='br-<iface>'`、接口改 `device='br-<iface>'`、删 `type`/`ifname` |
| 5 | `12_network-generate-ula` | base-files | `network.globals.ula_prefix` 为 `auto` 时落成随机 `fdxx:…:/48` |
| 6 | `14_migrate-dhcp-release` | netifd | `network.<if>.release` → `norelease`（**取反**：`norelease=$((!$release))`） |
| 7 | `14_network-generate-duid` | base-files | `network.globals.dhcp_default_duid` 为 `auto` 时生成 DUID-UUID（RFC 6355） |
| 8 | `15_migrate-time-zonename` | base-files | `system.@system[0].zonename` 里的**空格 → 下划线** |
| 9 | **`15_odhcpd`** | odhcpd-ipv6only | 若 `dhcp.odhcpd` **已存在** → 只跑迁移分支：`piofolder`→`piodir`、删 `legacy`、`hostsfile`→`hostsdir`、`leasefile=/tmp/hosts/odhcpd`→`/tmp/odhcpd.leases`；**不存在** → 写全套官方默认（`dhcp.odhcpd` 段 + `dhcp.lan` 的 `dhcpv4/dhcpv6/ra=server`、`ra_slaac=1`、`ra_flags`） |
| 10 | `30_uboot-envtools` | uboot-envtools | `/etc/config/ubootenv` 不存在则创建；仅 `xunlong,orangepi-r1-plus*` 板子额外写 `ubootenv` 配置（**R2S 不匹配**） |
| 11 | `50-attendedsysupgrade` | attendedsysupgrade-common（packages feed） | `/etc/config/attendedsysupgrade` 不存在则写官方默认（`server.url='https://sysupgrade.openwrt.org'`、`client.upgrade_packages=1`、`auto_search=0`、`advanced_mode=0`） |
| 12 | `50-dnsmasq-migrate-ipset.sh` | dnsmasq | `dhcp.@dnsmasq[0].ipset`（`/域/名` 记法）→ 拆成独立 `config ipset` 段（`list name` + `list domain`） |
| 13 | `50-dnsmasq-migrate-resolv-conf-auto.sh` | dnsmasq | `dhcp.@dnsmasq[0].resolvfile`：`/tmp/resolv.conf.auto` → `/tmp/resolv.conf.d/resolv.conf.auto` |
| 14 | `50-dropbear` | dropbear | `board.json` 的 `credentials.ssh_authorized_keys` → `/etc/dropbear/authorized_keys`，并把 `dropbear.@dropbear[-1]` 的 `PasswordAuth`/`RootPasswordAuth` 关掉（R2S 无 credentials → 空转） |
| 15 | `50-migrate-rpcd-ubus-sock.sh` | rpcd | `rpcd.@rpcd[0].socket`：`/var/run/ubus.sock` → `/var/run/ubus/ubus.sock` |
| 16 | `50-root-passwd` | base-files | `board.json` 的 `credentials.root_password_hash` / `root_password_plain` → 写 `/etc/shadow` / `passwd`（R2S 无 credentials → 空转，**所以出厂无密码**） |
| 17 | `95-luci-app-attendedsysupgrade-housekeeping` | luci-app-attendedsysupgrade | `luci.main.check_for_newer_firmwares` → `attendedsysupgrade.client.login_check_for_upgrades`，并删除旧项 |
| 18 | `99-custom.sh` | **本仓库** | 见 README「首启初始化」 |

> `15_odhcpd` 的**源文件**名是 `files/odhcpd.defaults`，安装名才是 `15_odhcpd`
> （`odhcpd-ipv6only/install = odhcpd/install`，两个 variant 装同一个脚本）。

### 1.1 不存在于本固件的迁移脚本（易误列）

| 脚本 | 为什么不存在 |
| --- | --- |
| `13_fix-group-user` | base-files `Makefile` 在 `ifneq ($(CONFIG_USE_APK),)` 分支里 **`rm -f` 掉了**；apk 构建里 `/usr/lib/opkg/info` 也不存在（脚本自身开头就会 `exit 0`） |
| `20_migrate-feeds` | 属 `opkg` 包；apk 固件不装 opkg（`/etc/opkg.conf` → `/etc/apk/repositories.d/distfeeds.list`） |
| `10-fstab` | **存在**（fstools 在基线里），列在此处只为提醒它不是「不存在」 |
| target 专属迁移（`04_led_migration`、`09_fix_crc`、`05_fix-compat-version` 等） | `target/linux/rockchip` 下**没有任何** `uci-defaults` 目录 |

---

## 2. 运行期（非首启）的兼容与迁移

这些不在 `/etc/uci-defaults/` 里，而是在**每次读取配置时**或**首次写入时**发生。

| 位置 | 迁移 |
| --- | --- |
| `netifd` `config.c: config_fixup_bridge_ports()` | 源码注释原文 *"translate deprecated configs / Old configs used `ifname` option for specifying bridge ports"*：`config device`（或 `type=bridge` 的接口）在没有 `ports` 时把 `ifname` **`uci_rename` 成 `ports`**，并落盘 |
| `firewall4` `fw4.uc: parse_defaults()` | `syn_flood` → `synflood_protect`（`if (defs.synflood_protect === null) defs.synflood_protect = defs.syn_flood;` 然后 `delete defs.syn_flood`） |
| `firewall4` `fw4.uc` `DEPRECATED` 标记 | `rule` / `redirect` 段的 `_name`：接受但忽略，`warn_section` 打 `is deprecated by fw4` |
| `firewall4` `fw4.uc` `UNSUPPORTED` 标记 | `defaults`：`custom_chains`、`disable_ipv6`；`zone`：`extra`、`extra_src`、`extra_dest`、`custom_chains`；`rule`：`extra`、`monthdays` —— 全部打 `is not supported by fw4` 后丢弃（fw3 遗留） |
| LuCI `view/firewall/zones.js` | 勾选 SYN-flood 时 `uci.unset('firewall', id, 'syn_flood')` + 写 `synflood_protect`；zone 的 `extra` 在写时删除 |
| LuCI `view/system/system.js` | 改时区时**同时写** `zonename`（IANA）+ `timezone`（POSIX TZ 串）；NTP 开关用 `uci.set/unset system.ntp.enabled` 而不是恒写 |
| LuCI `view/network/routes.js` | 写静态路由时 `uci.unset('network', id, 'netmask')`（改用 CIDR 记法） |
| LuCI `view/network/interfaces.js` | `ra_flags`、`dhcpv6_pd_preferred` 的写入/清除规则 |
| `dnsmasq.init` | 单值 `option dhcp_option` 写法弃用：打 `Warning: the 'option $opt' syntax is deprecated, use 'list $opt'`（应用 `list dhcp_option`） |
| `luci-base` **postinst**（包安装期，非首启） | 若 `/etc/config/uhttpd` 存在且 `uhttpd.main.ucode_prefix` 不含 `/cgi-bin/luci`，则 `uci add_list uhttpd.main.ucode_prefix='/cgi-bin/luci=/usr/share/ucode/luci/uhttpd.uc'` + `service uhttpd reload` |

---

## 3. 本项目自己做的迁移（ImmortalWrt → 官方 OpenWrt）

| 项 | 说明 | 位置 |
| --- | --- | --- |
| `multipath` / `sendclientid` / `ra_preference` | ImmortalWrt 时期残留的死选项 | README「从旧固件保留配置刷机的遗留项」 |
| `dhcp.lan.dhcpv6` / `ra_slaac` / dnsmasq 五项 | 旧脚本误删的官方默认 | 同上 |
| `fullcone` / `dns_redirect` / wan 段 `leasetime,start,limit` | 旧脚本写入的无识别选项 | 同上 |
| **`firewall.@defaults[0].syn_flood` → `synflood_protect`** | 与 fw4 / LuCI 行为对齐（写新名 + 删旧别名，先写后删） | `99-custom.sh` 第 7 节 |
| **`/etc/config/wan-settings` → `/etc/openwrt-builder/wan-settings`** | 无后缀文件不能放 `/etc/config/`（libuci 会当配置包解析） | `build.sh` / `99-custom.sh` / workflow |

---

## 4. apk 时代的迁移（工具链层面）

| 旧 | 新 | 备注 |
| --- | --- | --- |
| `opkg` + `/etc/opkg/distfeeds.conf` | `apk` + `/etc/apk/repositories.d/distfeeds.list` | `20_migrate-feeds` 随 opkg 一起消失 |
| `/etc/opkg/keys/*` | `/etc/apk/keys/*` | ⚠ `attendedsysupgrade-common` **仍然**往 `/etc/opkg/keys/8a11255d14aef6c8` 装一个 opkg 公钥（apk 下无用残留） |
| `/etc/config/…` conffile 语义 | 同 | LuCI 的 `luci.extern.flash_keep` 里仍列着 `/etc/opkg.conf`（同样是残留） |

---

## 5. 保留配置刷机（`sysupgrade` 默认 keep settings）时的行为

`/etc/config` 会被旧固件覆盖，因此各脚本的**前置判断**决定它是否真的动手：

| 脚本 | 保留配置时的行为 |
| --- | --- |
| `15_odhcpd` | `dhcp.odhcpd` 已存在 → **不是完全空转**：执行 §1 表中第 9 行的四个 odhcpd 选项迁移后 `exit 0`；官方默认值**不会**被补回 |
| `50-attendedsysupgrade` | `/etc/config/attendedsysupgrade` 已存在 → `return 0`，**完全跳过** |
| `30_uboot-envtools` | `/etc/config/ubootenv` 已存在 → `exit 0` |
| `10-fstab` | `/etc/config/fstab` 已存在 → **不**重新 `block detect` |
| `12_network-generate-ula` | `ula_prefix != auto` 就退出；若旧配置里是真实前缀则保持不动 |
| `14_network-generate-duid` | `dhcp_default_duid != auto` 就退出 |
| `00_uhttpd_ubus` / `50-migrate-rpcd-ubus-sock.sh` / `50-dnsmasq-migrate-*` | 只在值**恰为旧值**时才改 → 全新固件上是 no-op，从老版本升上来才生效 |
| `11_network-migrate-bridges` / `14_migrate-dhcp-release` | 只在存在 `type=bridge`+`ifname` / `release` 这类遗留写法时才动 |

> 结论：**保留配置刷机时，`15_odhcpd` 不会补回官方默认**（这正是 README 建议「不要保留配置」的原因）；
> 但 `11_network-migrate-bridges`、`14_migrate-dhcp-release` 会**自动**把网络侧的遗留写法迁移掉。

---

## 6. 顺带发现的偏差（非迁移，但建议处理）

### 6.1 官方固件含 `luci-ssl`，本仓库未装

`config.buildinfo` 里 `CONFIG_PACKAGE_luci-ssl=y`；`luci` 集合包本身只等于
`luci-light + luci-app-package-manager`，**不含** `luci-ssl`：

```make
# collections/luci/Makefile
LUCI_DEPENDS:= +luci-light +luci-app-package-manager
# collections/luci-light/Makefile
LUCI_DEPENDS:= +IPV6:luci-proto-ipv6 +luci-app-firewall +luci-mod-admin-full \
	+luci-proto-ppp +luci-theme-bootstrap +rpcd-mod-rrdns +uhttpd +uhttpd-mod-ubus
```

`uhttpd` 的出厂配置**默认就带** `list listen_https 0.0.0.0:443` + `option cert /etc/uhttpd.crt`
（`config cert defaults` 段提供自签参数）。装 `luci-ssl`（→ `px5g-mbedtls`）后首次启动才会
生成自签证书并启用 HTTPS。本仓库 `PACKAGES` 只有 `luci`，因此**当前固件 LuCI 只有 HTTP**，
且 `listen_https` 因缺证书而不生效（uhttpd 会跳过 TLS 监听）。

### 6.2 `zonename` 在官方固件里实际不生效

manifest 里**没有任何 `zoneinfo-*` 包**，所以 `/usr/share/zoneinfo/Asia/Shanghai` 不存在；
而 `package/base-files/files/etc/init.d/system` 的判定是：

```sh
echo "$timezone" > /tmp/TZ
[ -n "$zonename" ] && [ -f "/usr/share/zoneinfo/${zonename// /_}" ] \
	&& ln -sf "/usr/share/zoneinfo/${zonename// /_}" /tmp/localtime \
	&& rm -f /tmp/TZ
```

⇒ zoneinfo 缺失时 **`zonename` 分支不执行**，真正生效的是 POSIX 串 `timezone`（经 `/etc/TZ → /tmp/TZ`）。
LuCI 的时区下拉用的是它自带的 `luci.zoneinfo` ucode 表（`luci-base/ucode/zoneinfo.uc`），
**不依赖** `/usr/share/zoneinfo`，但它保存时会**同时写** `zonename` + `timezone`。

⇒ 本项目 `99-custom.sh` 双写 `timezone='CST-8'` + `zonename='Asia/Shanghai'` 是**必要**的，不是冗余：
前者在无 zoneinfo 时兜底，后者在装了 zoneinfo 时精确生效。

### 6.3 dropbear 出厂配置没有 `Interface`

`package/network/services/dropbear/files/dropbear.config` 只有 `enable` / `PasswordAuth` /
`RootPasswordAuth` / `Port`，**没有** `Interface`；`dropbear.init` 的
`uci_load_validate` 也没给它默认值（`'Interface:string'` 无第三参数）。因此 dropbear
**监听所有地址**（`0.0.0.0:22` + `[::]:22`），WAN 侧靠防火墙 zone `wan` 的 `input REJECT` 挡住。
（旧版 README 写的「dropbear 监听 LAN 地址」是错的。）

### 6.4 `luci.main.lang` 出厂为 `auto`

`luci-base/root/etc/config/luci` 是 `option lang auto` —— 跟随浏览器语言，不是固定中文。
装了 `luci-i18n-base-zh-cn` 后中文浏览器会显示中文；要强制中文需另写 `luci.main.lang='zh_cn'`。
