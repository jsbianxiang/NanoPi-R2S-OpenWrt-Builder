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

> 「只跑一次」是相对**同一次 rootfs** 而言。每次刷机（含保留配置）rootfs 都会被整镜像覆盖，
> 这些脚本会重新出现并再跑一遍——推导见 §5.1。

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
| LuCI `view/firewall/zones.js` | 勾选 SYN-flood 时 `uci.unset('firewall', id, 'syn_flood')` + 写 `synflood_protect`（`zones.js:43-51`）；zone 的 `extra` 在写时删除（`zones.js:327-340`，**仅 fw3**：整块被 `if (!fw4)` 包住） |
| LuCI `view/system/system.js` | 改时区时**同时写** `zonename`（IANA）+ `timezone`（POSIX TZ 串）；NTP 开关是 `uci.set('system','ntp','enabled',0)` / **`uci.unset('system','ntp','enabled')`** —— 即「NTP 开」= 该项**不存在**（注意：这是**「系统」菜单**，不属「网络」菜单） |
| LuCI `view/network/routes.js` | 写静态路由时 `uci.unset('network', id, 'netmask')`（改用 CIDR 记法，`routes.js:75-78`） |
| LuCI `view/network/interfaces.js` | **`ifname` -> `device` / `ports` 迁移**：打开「网络 -> 接口」时检测并弹窗（`renderIfnameMigration()` / `renderBridgeMigration()`），点继续即执行重命名。**触发点是页面打开（`render()`），不是「保存」**（详见 §2.1） |
| LuCI `view/network/interfaces.js` | `ra_flags`、`dhcpv6_pd_preferred` 的清除规则在 `so.remove`（**删除按钮**）里，不在 `so.write`（保存）里。⚠ 删除 DHCP 段时 LuCI 把 `ra_flags` 写成**字面量 `'none'`**（该多选框的 `select_placeholder` 也是 `none`，所以 UI 上就显示 `none`）；odhcpd 的 `parse_ra_flags` 不认这个值、返回 -1，标志保持 0 ⇒ **M=O=0**，比「选项缺失」（只有 O 标志）更糟。§7 现在会把它覆写成官方默认的 M+O |
| `dnsmasq.init` | 单值 `option dhcp_option` 写法弃用：打 `Warning: the 'option $opt' syntax is deprecated, use 'list $opt'`（应用 `list dhcp_option`） |
| `luci-base` **postinst**（包安装期，非首启） | 若 `/etc/config/uhttpd` 存在且 `uhttpd.main.ucode_prefix` 不含 `/cgi-bin/luci`，则 `uci add_list uhttpd.main.ucode_prefix='/cgi-bin/luci=/usr/share/ucode/luci/uhttpd.uc'` + `service uhttpd reload` |

### 2.1 LuCI「网络 -> 接口」页的 ifname 迁移（点继续即执行）

`interfaces.js` 的判定条件与动作（`openwrt-25.12`）：

| 判定函数 | 条件 | 动作 |
| --- | --- | --- |
| `interfaceBridgeWithIfnameSections()` | `config interface`：`type=='bridge' && !ports && ifname` | `handleBridgeMigration()`：新建 `config device name='br-<段名>'`（`type=bridge`、`ports=<ifname>`，并复制 `mtu`/`macaddr`/`igmp_snooping`），接口清空 `type`/`ifname`/`mtu`/`macaddr`/`igmp_snooping`，改 `device='br-<段名>'` |
| `deviceWithIfnameSections()` | `config device`：`type=='bridge' && !ports && ifname` | `handleIfnameMigration()`：`ifname` 清空、`ports=<ifname>` |
| `interfaceWithIfnameSections()` | `config interface`：`!device && ifname` | `handleIfnameMigration()`：`ifname` 清空、`device=<ifname>` |

前两条与官方首启脚本 `11_network-migrate-bridges` 等价（该脚本不做 `mtu`/`macaddr`/`igmp_snooping` 的搬运）。
**第三条官方没有对应实现**——netifd 至今保留显式向后兼容
（`interface.c:53 IFACE_ATTR_IFNAME, /* Backward compatibility */`；
`interface.c:1091-1093 cur = tb[IFACE_ATTR_DEVICE]; if (!cur) cur = tb[IFACE_ATTR_IFNAME];`），
所以上游不需要迁移它，只有 LuCI 会提示改名。

> ⚠ 更正一处容易搞错的说法：LuCI **不会**写 `rpcd.@rpcd[0].socket` 或 `uhttpd.main.ubus_socket`。
> 整个 luci 树里 `ubus.sock` 一次都没出现（`grep -rn "ubus\.sock" luci/` 为空；`luci-app-acl` 只动 `rpcd` 段的 `read`/`write`），
> 25.12 也已没有 ACL 编辑页（`modules/luci-mod-admin-full` 只剩一个 Makefile）。
> 这两项纯属**官方首启脚本**的迁移，见 §1。

---

## 3. 本项目自己做的迁移（ImmortalWrt -> 官方 OpenWrt）

`99-custom.sh` 里分成两节，**按「是否属于 LuCI『网络』菜单保存路径」严格切分**：

- **第 4 节** = LuCI「网络」菜单点「保存并应用」时由 `o.write` 处理器产生的旧 -> 新重命名。
  范围最窄，直接对应「用户点一次保存」的结果。
- **第 10 节** = 非保存路径的迁移（页面弹窗 / 官方首启脚本 / 「系统」菜单），
  **属冗余加固，可整节删除**。

### 3.1 第 4 节：LuCI「网络」菜单**保存**路径（严格范围）

「网络」菜单成员（`luci-25.12` 的 `menu.d` JSON）：

| 归属 | 菜单项 |
| --- | --- |
| `luci-mod-network` | `admin/network/wireless`(15)、`switch`(20)、`network`(10，**接口**)、`routes`(30)、`dhcp`(40)、`dns`(45)、`diagnostics`(50) |
| `luci-app-firewall` | `admin/network/firewall`(60) -> `zones` / `forwards` / `rules` / `snats` / `ipsets` / `custom` |

> **防火墙也在「网络」菜单下**（order 60），所以它的保存路径同属本节范围。
> 该页 `depends.fs` 要求 `/sbin/fw3` 可执行；firewall4 用 `root/sbin/fw3 -> fw4`
> 这个**符号链接**满足它（`tar -tvzf` 可验；codeload 的包在 Windows 上会把符号链接
> 落成 0 字节普通文件，容易误判成「fw3 不存在、防火墙页不显示」）。

把「网络」菜单下**全部** `o.write` 处理器过了一遍，真正的旧 -> 新重命名只有三处：

| # | 迁移 | 源码位置 | 本脚本 | 说明 |
| --- | --- | --- | --- | --- |
| ① | `firewall.@defaults[0].syn_flood` -> `synflood_protect` | `firewall/zones.js:43-51` | **4.1 已实现** | 写新名 + 删旧别名。官方无首启脚本；fw4 只有运行期回退（`fw4.uc: if (defs.synflood_protect === null) defs.synflood_protect = defs.syn_flood; delete defs.syn_flood;`）。删旧名让 `uci show firewall` 输出唯一 |
| ② | `network.<route>.netmask` -> CIDR 合写进 `target` | `network/routes.js:61-78` | **有意不做** | `o.write` 确是保存路径；但 **netifd 仍显式解析 `netmask`**（`interface-ip.c:53 [ROUTE_MASK]="netmask"`、`:458 parse_netmask_string(...)`、`proto.c:47 OPT_NETMASK`），属**等价改写**而非功能迁移；且本项目不建静态路由，无对象可迁 |
| ③ | `firewall.<zone>.extra` -> `extra_src` / `extra_dest` | `firewall/zones.js:314-341` | **有意不做** | `o.write` 确是保存路径，但整块被 `if (!fw4) { ... }` 包住 —— **只有 fw3 才渲染「Extra iptables arguments」标签页**；本固件是 fw4（manifest `firewall4 2025.03.17~b6e51575-r2`），该页不存在，永不触发 |

### 3.2 第 10 节：非保存路径的迁移（冗余加固，可整节删除）

| # | 迁移 | 真实归属 | 本脚本所在节 | 为什么仍然写 |
| --- | --- | --- | --- | --- |
| 1 | `network.<if>.ifname` -> `device`（非 bridge、无 `device` 的 interface 段） | LuCI `interfaces.js`，但触发点是**页面打开**（`render()` -> `renderIfnameMigration()`），**不是保存** | 10.1 | 官方首启脚本**没有**实现（netifd 仍向后兼容 `ifname`：`interface.c:53`、`:1091-1093`）。保留配置升级 + 从不打开 LuCI 接口页时，旧 `option ifname 'eth1'` 会原样留下 |
| 2 | `rpcd.@rpcd[0].socket` 旧路径 -> 新路径 | 官方首启 `50-migrate-rpcd-ubus-sock` | 10.2 | 兜底。rpcd 是 LuCI 的后端，socket 写错时 LuCI 整个不可用 |
| 3 | `uhttpd.main.ubus_socket` 旧路径 -> 新路径 | 官方首启 `00_uhttpd_ubus` | 10.2 | 同上 |
| 4 | `uhttpd.main.ubus_prefix` 缺失则补 `/ubus` | 官方首启 `00_uhttpd_ubus` | 10.2 | **关键**：`uhttpd/main.c:636 if (conf.ubus_prefix && uh_plugin_init("uhttpd_ubus.so"))` —— 该值为空时 uhttpd-mod-ubus **根本不加载**，LuCI 的 `/ubus` RPC 端点不存在 |
| 5 | `dhcp.@dnsmasq[0].resolvfile` 旧路径 -> 新路径 | 官方首启 `50-dnsmasq-migrate-resolv-conf-auto.sh` | 10.3 | 兜底。旧值会让 dnsmasq 去读一个不存在的文件并 `touch` 出空文件当上游，**设备自身 DNS 全挂** |
| 6 | `/etc/config/wan-settings` -> `/etc/openwrt-builder/wan-settings` | 本项目 | 文件头 | 无后缀文件不能放 `/etc/config/`（libuci 会当配置包解析） |

> 原先的第 10.4 节（删除 `system.ntp.enabled`）已删除：它既不是「网络」菜单保存的产物，
> 又与「不写时的生效值」等价（sysntpd 缺省即「开」），且旧配置若有意设过 `enabled='0'`
> 时删除反而会越权打开 NTP。判据见 §3.5。

> 为什么 B 类（官方首启脚本）还要重复一次：每次刷机（含「保留配置」）rootfs 都会被整体替换，
> 官方脚本会重新出现并再跑一遍，所以它们在正常流程里是**冗余**的。重复的理由是
> ①各自只有几行且幂等；②这几项一旦是旧值，后果是 LuCI / DNS **整体不可用**，值得再钉一遍；
> ③上游将来删掉这些一次性脚本后仍有效。**不认同这个取舍就把 10.1 ~ 10.3 整节删掉。**

### 3.3 有意**不**在脚本里重复的官方迁移

这些同样会发生，但由上游脚本/运行期逻辑承担，重复只会增加维护面：

| 迁移 | 承担者 |
| --- | --- |
| `config device type=bridge` 的 `ifname` -> `ports`；`config interface type=bridge` -> 新建 `br-<if>` | 首启 `11_network-migrate-bridges`（LuCI 也有等价弹窗，见 §2.1） |
| `network.<if>.release` -> `norelease`（取反） | 首启 `14_migrate-dhcp-release` |
| `dhcp.@dnsmasq[0].ipset` -> 独立 `config ipset` 段 | 首启 `50-dnsmasq-migrate-ipset.sh` |
| `dhcp.odhcpd` 的 `piofolder`/`legacy`/`hostsfile`/`leasefile` | 首启 `15_odhcpd` |
| `config interface` 静态地址的 `ipaddr`+`netmask` -> `list ipaddr 'x/y'` | 本脚本第 5/6 节已直接写 CIDR 并 `delete netmask` |

### 3.4 经核实**不是**迁移的项（易误判）

| 项 | 结论 |
| --- | --- |
| `network.<if>.sendclientid` | **是活选项**：`odhcp6c/files/dhcpv6.sh:15 proto_config_add_string 'sendclientid:or("auto","global","hardware")'`、`:122 case "$sendclientid"`。默认（未设）走 `auto|*` 分支，与显式 `auto` 等价，所以显式写属冗余，但**不是**要迁移的死选项 |
| `network.<if>.multipath` | 官方 netifd 源码里**完全没有**（MPTCP 是 ImmortalWrt 补丁），没有任何新名字可迁移 |
| `dhcp.lan.ra_preference` | odhcpd 认识它（`src/config.c:177 IFACE_ATTR_RA_PREFERENCE`），只是默认值与官方一致 |
| `dhcp.lan.ra_slaac` / `dhcp.odhcpd.maindhcp` | odhcpd 内置默认分别是 `true`（`config.c:333`）/ `false`（`config.c:38`），与官方写入值相同 |
| `dhcp.lan.dhcpv6` / `ra` | **是活选项，必须显式写**：由 odhcpd 读，odhcpd 内置默认是 `MODE_DISABLED`（`config.c:312-314`），缺失就等于关闭 LAN 的 DHCPv6/RA |
| `dhcp.lan.dhcpv4` | **活选项，但无需写**（已从脚本移除）：唯一有效消费者 dnsmasq 的 `dnsmasq.init:578`（无默认取值）+ `:602 if [ "$dhcpv4" != "disabled" ]` ⇒ 缺失（空串）≠ `disabled`，照常下发；odhcpd 侧该值被 `maindhcp=0` 门控（`config.c:1282`），恒不生效 |
| `dhcp.@dnsmasq[0].cachesize` | 活选项，`dnsmasq.init:1028 append_parm "$cfg" cachesize "--cache-size"`（无默认）=> 缺失时用 dnsmasq 内置 `150`，官方 conffile 是 `1000`。本脚本只在**缺失时**补回 |
| `dhcp` 静态租约的 `name` / `dns` | `dhcp.js:941-949`：`uci.unset` 在 `so.remove`（**删除按钮**）里；`so.write`（保存）反而是 `uci.set(name)` + `uci.set(dns,'1')`。是删除动作，不是重命名 |
| `dhcp` dnsrecord 的 `hexdata` | `dns.js:474-482 hexencodesave`：保存时若「Raw Data」为空则 `uci.unset(hexdata)`。是保存路径的**删除**，不是旧 -> 新重命名；本项目不建 dnsrecord |
| firewall `flow_offloading` / `flow_offloading_hw` | `zones.js:91-94`：`uci.set(..., null)` 即「写 null = 删除」，是同一选项名的存 / 删，不是重命名 |
| firewall zone 改名 / zone 的 `network` 成员变更 | `zones.js:133-138`（`firewall.renameZone()`）、`:188`（`addNetwork`/`deleteNetwork`）：是用户主动改的**内容**，不是参数名迁移 |
| `dhcp.odhcpd` 段本身缺失 | 由首启 `15_odhcpd` 创建（LAN 为静态地址时还会写 `dhcp.lan.dhcpv4/dhcpv6/ra='server'`、`ra_slaac=1`、`ra_flags`）。本脚本不把它列为硬性前置条件，但第 7 节会**显式钉死** `dhcpv6` / `ra` 那两个值（`dhcpv4` 与缺省等价，不写） |

### 3.5 等价项：判定「不写也一样」而**不**写的选项

脚本的写入原则是「**只写与『不写时的生效值』不同的项**」。下表这些曾经写过、现已删除，
每条都核过源码；它们既不是迁移，也不该写：

| 已不写的项 | 「不写时」的生效值 | 依据 |
| --- | --- | --- |
| `network.wan6.reqaddress='try'` | 同样是 `TRY` | 不写时 odhcp6c 收不到 `-N`，其内置默认即 `IA_MODE_TRY`（odhcp6c `src/config.c:85`）；显式 `'try'` 走 `config_set_request_addresses("try")`，落在同一枚举值 |
| `network.wan6.reqprefix='auto'` | 同样是 `auto` | `odhcp6c/files/dhcpv6.sh:101` `[ -z "$reqprefix" -o "$reqprefix" = "auto" ] && reqprefix=0` —— 空值与 `auto` 在 proto 层归一成同一个值，都发 `-P0` |
| `network.globals.packet_steering='1'` | 同样是**开启** | 唯一消费者 `/etc/init.d/packet_steering` 只在值为字面量 `'0'` 时关闭引导（`packet-steering.uc`: `case '0': disable = true;`）；缺失时传入空串，不命中该分支。该 init 由 netifd 包安装，`default_postinst` 对包内所有 `/etc/init.d/*` 执行 `rc.common enable`，确实在跑 |
| 补 `network.globals` 段的 `if ! uci -q get …` 守卫 | 段总是存在 | `config_generate` 无条件写 `delete network.globals; set network.globals='globals'; set network.globals.dhcp_default_duid='auto'` ⇒ 分支永不触发，是死代码 |
| `dhcp.wan.ignore='1'` | 同样是 `1` | 官方 dnsmasq conffile `files/dhcp.conf` 里就有 `config dhcp wan` / `option ignore 1` |
| `dhcp.lan.dhcpv4='server'` | 同样是「下发 DHCPv4」 | 见 §3.4 该行（dnsmasq 把缺失当非 `disabled`；odhcpd 侧被 `maindhcp=0` 门控） |
| 删除 `system.ntp.enabled` | 同样是「NTP 开」 | sysntpd 校验串 `'enabled:bool:1'`（缺省 1），`config_generate` 也写 `enabled='1'` ⇒ 存在为 1 或缺失行为相同；旧配置若有意设 `enabled='0'`，删除反而**越权**打开 NTP |

**保留**的近似项（看似可删、实则不可）：

| 保留项 | 为什么不能删 |
| --- | --- |
| `network.wan=interface`、`network.wan6=interface` | 不是值写入而是**前置条件**：libuci `uci_set` 有断言 `UCI_ASSERT(ctx, ptr->s \|\| (!ptr->option && ptr->section))`（`list.c:690`），段不存在时 `uci set <段>.<选项>=…` 直接报错 |
| `network.wan6.norelease='1'` | 不写 ≠ 1：`dhcpv6.sh:148` `[ "$norelease" = "1" ] && append opts "-k"`，只有显式 1 才加 `-k` |
| `dhcp.lan.dhcpv6='server'`、`ra='server'` | odhcpd 内置默认 `MODE_DISABLED`（`config.c:312-314`），**没有** dnsmasq 兜底；保留配置升级时 `15_odhcpd` 走迁移分支 `exit 0`、不补默认 |
| `dhcp.lan.ra_flags='managed-config' 'other-config'` | **不写 ≠ 官方值**：odhcpd 内置默认只有 O 标志（`config.c:332` `iface->ra_flags = ND_RA_FLAG_OTHER;`），缺 M 标志客户端不会通过 DHCPv6 取地址；且该选项**一旦出现**即被清零后重新解析（`config.c:1508-1513`），写漏的项不回退到默认 ⇒ 必须写全 |
| `network.lan.delegate='0'`、`ip6assign='64'`、`ip6ifaceid='eui64'` | 三项都与默认不同：`delegate` 默认 true（`interface.c:1053`）、`config_generate` 给 LAN 写 `ip6assign='60'`、`ip6ifaceid` 默认固定 ID `::1`（`interface.c:1002-1004`） |
| `dhcp.@dnsmasq[0].cachesize` | 条件写入（仅缺失时补），官方 conffile `1000` ≠ dnsmasq 内置 `150` |

---

## 4. apk 时代的迁移（工具链层面）

| 旧 | 新 | 备注 |
| --- | --- | --- |
| `opkg` + `/etc/opkg/distfeeds.conf` | `apk` + `/etc/apk/repositories.d/distfeeds.list` | `20_migrate-feeds` 随 opkg 一起消失 |
| `/etc/opkg/keys/*` | `/etc/apk/keys/*` | ⚠ `attendedsysupgrade-common` **仍然**往 `/etc/opkg/keys/8a11255d14aef6c8` 装一个 opkg 公钥（apk 下无用残留） |
| `/etc/config/…` conffile 语义 | 同 | LuCI 的 `luci.extern.flash_keep` 里仍列着 `/etc/opkg.conf`（同样是残留） |

---

## 5. 保留配置刷机（`sysupgrade` 默认 keep settings）时的行为

### 5.1 先看清刷机到底做了什么

R2S 属 rockchip 的 SD/eMMC 引导，`target/linux/rockchip/armv8/base-files/lib/upgrade/platform.sh`：

```sh
platform_do_upgrade() { ... get_image "$@" | dd of="/dev/$partdev" ... }   # 整分区 dd
platform_copy_config() { ... cp -af "$UPGRADE_BACKUP" "/mnt/$BACKUP_FILE" ... }
```

即 **rootfs 分区被整镜像覆盖**，配置单独存成根目录下的 `sysupgrade.tgz`
（`lib/upgrade/common.sh:3 export BACKUP_FILE=sysupgrade.tgz  # file extracted by preinit`），
在 preinit 阶段被 `lib/preinit/80_mount_root` 的 `do_mount_root()` 解包：

```sh
[ -f /sysupgrade.tgz -o -f /tmp/sysupgrade.tar ] && {
	echo "- config restore -"
	cd /
	[ -f /sysupgrade.tgz ] && tar xzf /sysupgrade.tgz
	...
}
```

（`/etc/init.d/done` 里再 `rm -f /sysupgrade.tgz`。）

⇒ 结论一：**每次刷机（含保留配置）`/etc/uci-defaults/` 里的脚本都会重新出现并再跑一遍**，
不存在「脚本被 `rm -f` 后就再也不跑」的问题。所以本脚本第 10 节的 B 类项纯属冗余加固，
第 4 节（LuCI 保存路径会做、官方无脚本）才是真正新增的能力。

⇒ 结论二：配置恢复发生在 `/etc/init.d/boot` **之前**，所以 `99-custom.sh` 看到的
永远是「新镜像的 uci-defaults + 恢复回来的 `/etc/config`」这个组合。

### 5.2 各脚本在保留配置时的前置判断

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
| `99-custom.sh`（本仓库） | 无条件重写它负责的项；第 4 / 10 节的迁移按值判断。见 §3 表 |

> 结论：**保留配置刷机时 `15_odhcpd` 不会补回官方默认**（这正是 README 建议「不要保留配置」的原因）；
> `11_network-migrate-bridges`、`14_migrate-dhcp-release` 会自动迁移网络侧的遗留写法；
> 而官方没覆盖的 `ifname`（非 bridge 段）由 `99-custom.sh` 第 10.1 节补上；
> `syn_flood` 由第 4.1 节补上。

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
