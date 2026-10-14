#!/bin/bash
# 构建期日志（注意：固件内的首启日志是 /etc/openwrt-builder/uci-defaults-log.txt，两者不是一回事）
source shell/custom-packages.sh
echo "第三方APK软件包: $CUSTOM_PACKAGES"
LOGFILE="/tmp/build.log"
echo "Starting build.sh at $(date)" >> $LOGFILE
# yml 传入的路由器型号 PROFILE
echo "Building for profile: $PROFILE"
# yml 传入的固件大小 ROOTFS_PARTSIZE
echo "Building for ROOTFS_PARTSIZE: $ROOTFS_PARTSIZE"

# 本脚本在官方 openwrt/imagebuilder 容器内运行，工作目录为 /builder。
BUILDER_DIR="/builder"
cd "$BUILDER_DIR" || exit 1

# ---------------------------------------------------------------------------
# 构建期注入目录：/etc/openwrt-builder/
#
# ⚠ 这些辅助文件**绝不能**放在 /etc/config/ 下。
#   已核实 libuci 源码（openwrt/uci，file.c）：
#     - uci_list_config_files() 用 glob("<confdir>/*", GLOB_MARK) **扫描整个目录**；
#     - get_filename() 只跳过「文件名含 `.`」的条目，源码注释原文：
#         "Filename with '.' are ignored and not parsed. Uci doesn't
#          permit config files with '.' in the name and cause parsing problems."
#       其余条目一律经 uci_validate_package() 后当作 uci 配置包解析
#       （校验只放行可打印 ASCII，`-` 也允许，挡不住 wan-settings 这种名字）。
#   ⇒ 无后缀、内容又是 key=value 的 wan-settings 会被当 uci 语法解析，
#     首行 `wan_proto=dhcp` 不匹配 package/config/option/list 任一关键字，
#     直接命中 file.c:553 的 uci_parse_error(ctx, "invalid command")。
#     现象就是**任何** uci 调用都打印：
#         uci: Parse error (invalid command) at line 1, byte 0
#     LuCI 的「软件包」页安装软件同样经由 uci，因此也报同一行错误。
#
#   约定：/etc/config/ 只放 uci 配置包；构建期辅助文件统一放
#         /etc/openwrt-builder/（无后缀不会被任何组件扫描）。
# ---------------------------------------------------------------------------
SETTINGS_DIR="$BUILDER_DIR/files/etc/openwrt-builder"
echo "Create $SETTINGS_DIR"
mkdir -p "$SETTINGS_DIR"

# DNS 留空时回落到网关（光猫一般自带 DNS 转发）
WAN_DNS="${WAN_DNS:-$WAN_GATEWAY}"
# WAN 接入方式：默认 dhcp（与 OpenWrt 官方默认一致），可选 static
WAN_PROTO="${WAN_PROTO:-dhcp}"

# 创建 WAN 配置文件（yml 传入 WAN_PROTO / WAN_IP / WAN_GATEWAY / WAN_DNS）
# 该文件随固件发布，供 99-custom.sh 首次启动时读取
cat << EOF > "$SETTINGS_DIR/wan-settings"
wan_proto=${WAN_PROTO}
wan_ip=${WAN_IP}
wan_gateway=${WAN_GATEWAY}
wan_dns=${WAN_DNS}
EOF

echo "cat wan-settings"
cat "$SETTINGS_DIR/wan-settings"

# ---- TCP 拥塞控制：维持官方默认 cubic（不启用 BBR）----
# 已核实：安装 kmod-tcp-bbr 只提供 tcp_bbr 模块（经 /etc/modules.d 自动加载），
# **并不会自动启用**——官方 25.12 内核（6.12）配置为 CONFIG_DEFAULT_TCP_CONG="cubic"。
# 本项目决定维持官方默认 cubic 不动，不预装 kmod-tcp-bbr、不写 sysctl。
# 如需 BBR，设备端手动执行：
#   apk add kmod-tcp-bbr
#   echo 'net.ipv4.tcp_congestion_control = bbr' > /etc/sysctl.d/99-bbr.conf
#   /etc/init.d/sysctl restart   # 或重启
# 内核 4.13+ 在无 fq 队列时 BBR 使用 TCP 内部 pacing 兜底；最优配对可另装 kmod-sched（含 sch_fq）。

if [ -z "$CUSTOM_PACKAGES" ]; then
  echo "⚪️ 未选择 任何第三方软件包"
fi
# 本分支不克隆任何第三方插件仓库（不集成 store / istore 商店）。
# 第三方包统一由下方注入的 dllkids（kenzok8）源提供。

# 输出调试信息
echo "$(date '+%Y-%m-%d %H:%M:%S') - 开始构建固件..."
echo "查看repositories信息——————"
cat repositories

# 定义所需安装的包列表 下列插件你都可以自行删减
# 注意：OpenWrt 官方源不含代理类插件，也不含 ImmortalWrt 系应用
#       （argon / diskman / cpufreq 等），这些包全部来自注入的第三方源。
#
# ===========================================================================
# PACKAGES 分三层，务必分清「哪些是官方、哪些是本项目加的」：
#   A. OFFICIAL_BASELINE  与官方镜像**逐包对齐**的基线（只有 4 个包）
#   B. LOCAL_ADDITIONS    本项目在基线之上的预置增量（全部官方源）
#   C. $CUSTOM_PACKAGES   第三方源增量（shell/custom-packages.sh，见下方）
#
# 构建期由 Image Builder **自动加入**、不能也不需要在此声明的部分：
#   - DEFAULT_PACKAGES（29 个，来自 include/target.mk + include/default-packages.mk）
#   - 本机型的 device_packages（kmod-usb-net-rtl8152，见 profiles.json）
#   - kernel
#   - 以上全部包的依赖闭包（约 96 个）
#   （IB 的 PACKAGES 是**追加**语义而非覆盖：target/imagebuilder/files/Makefile:43
#    注释 "include extra packages"；:143/:146 组包顺序 =
#    USER_PACKAGES + DEFAULT_PACKAGES + profile 包 + kernel）
# ⇒ **只写 A** 时，产出的包集合 == 官方镜像（target 级 manifest 128 包 + 设备包）。
# ===========================================================================

# ===========================================================================
# A. 官方基线：与官方 25.12.5 rockchip/armv8 镜像逐包对齐
# ===========================================================================
# 官方镜像 = IB 默认包 + 设备包 + **4 个显式选中**的额外包（就是下面这 4 个）。
# 依据：官方 openwrt-25.12.5-rockchip-armv8.manifest（128 包）**逐项溯源** ——
#   减去 DEFAULT_PACKAGES(29) 与设备包(1) 后剩 98 个，其中 **96 个**都能追到某个
#   包的依赖，只有这 4 个是「谁都不依赖」的显式选择：
#
#   luci                         config.buildinfo: CONFIG_PACKAGE_luci=y
#   luci-ssl                     同上（**不是** luci 的依赖，见下）
#   luci-app-attendedsysupgrade  Makefile: LUCI_DEFAULT:=y if (BUILDBOT && PACKAGE_luci)
#   owut                         Makefile: DEFAULT:=y if (BUILDBOT && !SMALL_FLASH)
#
# 那 96 个自动依赖的来源（记下来，免得以后重复排查）：
#   luci 栈 / rpcd(7) / ucode(10) / uhttpd(2)  ← luci-light / luci-base
#   libiwinfo*          ← luci-mod-status（LUCI_DEPENDS:=+libiwinfo +rpcd-mod-iwinfo）
#   nftables-json       ← firewall4（firewall4/Makefile:27）
#   libudebug           ← procd（procd/Makefile:43）/ netifd（netifd/Makefile:24）
#   px5g-mbedtls、libustream-mbedtls ← luci-ssl
#   attendedsysupgrade-common ← luci-app-attendedsysupgrade（也 ← owut）
#   getrandom           ← urandom-seed
#   procd-seccomp       ← base-files 的 USE_SECCOMP 条件依赖
#   其余 base 系统与库（busybox / procd / ubus / ubox / jshn / zlib / libgcc1 …）
#                       ← base-files（DEPENDS 见 package/base-files/Makefile:42-46）
#
# ⚠ 两个容易踩的坑：
#   1) 这个 manifest 是 **target 级**的，**不含任何设备 kmod**
#      （CONFIG_TARGET_MULTI_PROFILE=y ⇒ 与具体 profile 无关；
#        `grep -cE 'rtl8152|r8169|nvme'` = 0）。R2S 实机镜像 = 它 + kmod-usb-net-rtl8152。
#   2) 固件选择器网页上那个 "Installed Packages" 框**不是**对齐目标：它只列 32 项
#      （默认包 29 + 设备包 1 + luci + luci-app-attendedsysupgrade），而官方镜像
#      实际装了 128 个 —— 差的就是依赖闭包。要对齐请看 manifest。
#
# 为什么这 4 个都不能靠依赖自动带出：
#   - `luci` 集合只依赖 `luci-light + luci-app-package-manager`
#     （collections/luci/Makefile:14-16），**不含** luci-ssl；`luci-ssl` 是另一个
#     独立集合（collections/luci-ssl/Makefile:13-16），且全树没有任何包依赖它
#     （只有 luci-nginx 提供虚拟名 luci-ssl-nginx）。它本身是纯元包（目录里只有
#     Makefile），唯一实际作用是拉入 px5g-mbedtls —— 而 uhttpd 只在
#     /usr/sbin/px5g 或 /usr/bin/openssl 存在时才自动生成自签证书
#     （uhttpd.init:9,55-57,199-201），官方镜像**没有 openssl**（只有 mbedtls 系）
#     ⇒ 缺 px5g 就不会生成 /etc/uhttpd.crt，443 起不来，LuCI 只能走 HTTP。
#   - `owut` 与 attendedsysupgrade 的依赖方向是 owut → attendedsysupgrade-common，
#     **不是**反过来，所以 luci-app-attendedsysupgrade 永远带不出它；LuCI 的 ASU
#     页面也不调用 owut（只读 uci attendedsysupgrade.owut.rootfs_size），它是纯 CLI，
#     装它是为了 SSH 下能 `owut check` / `owut download` / `owut upgrade`。
OFFICIAL_BASELINE="luci luci-ssl luci-app-attendedsysupgrade owut"
# ===========================================================================
# B. 本项目增量：在官方基线之上追加（全部来自 OpenWrt 官方源）
#    把 LOCAL_ADDITIONS 清空即回到「纯官方固件」。
# ===========================================================================
# ⚠ 官方 OpenWrt 的 IB 默认包**不含 LuCI/uhttpd**（ImmortalWrt 的 IB 默认带，
#   官方不带——迁移差异，实机踩坑验证）。只装 luci-i18n-*/luci-app-* 会把
#   luci-base 拉进来但没有 web 服务器，设备上 /etc/init.d/uhttpd 都不存在，
#   web UI 完全无法访问。基线 A 里的 `luci` / `luci-ssl` 已带齐
#   uhttpd + luci-base + luci-mod-admin-full + luci-theme-bootstrap + rpcd 组件。
LOCAL_ADDITIONS=""
LOCAL_ADDITIONS="$LOCAL_ADDITIONS curl"
LOCAL_ADDITIONS="$LOCAL_ADDITIONS bind-tools"
LOCAL_ADDITIONS="$LOCAL_ADDITIONS ca-certificates"
LOCAL_ADDITIONS="$LOCAL_ADDITIONS openssh-sftp-server"
# ---- 中文语言包（官方 luci feed，均带独立 i18n 包，已逐一核实存在）----
LOCAL_ADDITIONS="$LOCAL_ADDITIONS luci-i18n-base-zh-cn"
LOCAL_ADDITIONS="$LOCAL_ADDITIONS luci-i18n-package-manager-zh-cn"
LOCAL_ADDITIONS="$LOCAL_ADDITIONS luci-i18n-firewall-zh-cn"
LOCAL_ADDITIONS="$LOCAL_ADDITIONS luci-i18n-attendedsysupgrade-zh-cn"

# ---------------------------------------------------------------------------
# 只装官方基线（用于与官方 manifest 做逐包比对）：
#     BUILD_OFFICIAL_ONLY=1 bash build.sh
# 会同时跳过 B 增量与 C 第三方包，产出「纯官方」包集合。
# ---------------------------------------------------------------------------
if [ "${BUILD_OFFICIAL_ONLY:-0}" = "1" ]; then
    echo "⚠ BUILD_OFFICIAL_ONLY=1：只装官方基线 A，跳过 B 增量与 C 第三方包"
    LOCAL_ADDITIONS=""
    CUSTOM_PACKAGES=""
fi

PACKAGES="$OFFICIAL_BASELINE $LOCAL_ADDITIONS"

# ===========================================================================
# C. 第三方增量：只装 $CUSTOM_PACKAGES（由 shell/custom-packages.sh 决定）
#    这些包**不在** OpenWrt 官方源里，必须靠下方注入的 dllkids 源。
#    清空 CUSTOM_PACKAGES（或用 BUILD_OFFICIAL_ONLY=1）即不装任何第三方包。
# ===========================================================================
# ⚠ 第三方源（dllkids）里的 app 包是中文原生的，**没有**独立语言包：
#   - luci-app-diskman / luci-app-cpufreq（27.150.x，默认不装，见下方注释行）
#     包内**自带简体中文**，若再显式安装同名的独立 i18n 包，apk 会因文件冲突报
#     ERROR: luci-i18n-xxx-zh-cn-...: trying to overwrite ... owned by luci-app-xxx-...
#     直接中断 make image（package_install 返回 Error 3）。启用时只装 app 包。
#   - luci-app-nikki 等其余第三方应用同理，不要加 luci-i18n-<名>-zh-cn。
# ⚠✗ 不默认安装 luci-theme-argon / luci-app-argon-config（实机已验证）：
#   dllkids 的 argon 是 ImmortalWrt 生态编译包，在官方 OpenWrt 25.12 的 LuCI 上
#   会导致 web UI 无法进入（argon 包自带 uci-defaults 自动把默认主题切成
#   argon，渲染失败则连登录页都挂）。默认走官方 Bootstrap 主题。
#   包级对照（2026-10-14 实测，已确认根因）：dllkids 的
#   luci-theme-argon-27.246.46668~5076a6f 与 ImmortalWrt 官方
#   luci-theme-argon-2.4.7-r20260824 的文件清单**完全一致**（同样 7 个 .ut 模板
#   + /etc/uci-defaults/30_luci-theme-argon），且该 uci-defaults **逐字节相同**
#   ⇒ 它确实是 ImmortalWrt 生态那一份，与官方 OpenWrt 的 LuCI 模板体系不匹配。
#   仍想尝试的话取消下两行注释，并在 99-custom.sh 里显式钉死
#   luci.main.mediaurlbase='/luci-static/bootstrap' 以便失败时可恢复。
#PACKAGES="$PACKAGES luci-theme-argon"
#PACKAGES="$PACKAGES luci-app-argon-config"
# ✓ 下列 2 个包在官方 OpenWrt 源中不存在、仅 dllkids 第三方源提供
#   （已核实：luci-app-diskman / luci-app-cpufreq-27.150.x）。
#   按本项目现行默认（PACKAGES 只放官方源软件），两行保持注释；
#   需要时取消注释启用——前提是 build.sh 注入了 dllkids 源（见下方注入逻辑）；
#   若将来移除该源注入，必须保持注释，否则 make image 找不到包。
#PACKAGES="$PACKAGES luci-app-diskman"
#PACKAGES="$PACKAGES luci-app-cpufreq"
# ttyd 网页终端 / 文件管理器（官方源，均带独立 i18n 包）默认不装；
# 需要时在 shell/custom-packages.sh 的 ENABLE_APPS 里填 ttyd / filemanager 启用
#（自动展开 luci-app-<短名> + luci-i18n-<短名>-zh-cn）。
# ---- TCP 拥塞控制：维持官方默认 cubic，不预装 kmod-tcp-bbr ----
# 原因与设备端手动启用 BBR 的方法见上方「TCP 拥塞控制」注释块。
# ---- C 合并：把第三方增量接到 PACKAGES 尾部 ----
PACKAGES="$PACKAGES $CUSTOM_PACKAGES"

# ===========================================================================
# 代理类插件互斥 —— 构建期硬校验
# ---------------------------------------------------------------------------
# 本项目默认启用 Clashoo（见 shell/custom-packages.sh「一」）。若想换成
# dllkids（kenzok8）源里的其他代理（nikki / openclash / passwall(2) /
# ssr-plus / homeproxy / dae(d) / shadowsocks / redsocks / xray / v2raya …），
# **必须先停旧的再开新的**，不能双开。
#
# 为什么不能双开 —— 这些插件每一套都会**独自接管整个透明代理**：
#   - 各自写 nftables/iptables 的 REDIRECT / TPROXY 规则（链名与优先级不同，
#     互相覆盖后流量走向不确定）；
#   - 各自劫持 DNS（dnsmasq 的 server/ipset/nftset 与 53 端口占用）；
#   - 抢占同一批端口（7890-7895 / 9090 / 1080 / 53 …）；
#   - 各自注册 /etc/init.d 脚本与 UCI 配置包，LuCI 页面选项重名。
#   后果是规则打架、LuCI 配置错乱、DNS 解析冲突：轻则无法科学上网，
#   重则刷机后直接断网。而且这类问题往往刷完才暴露 —— 所以拦在构建期。
#
# 判定：$PACKAGES 里出现 ≥2 个「代理栈」即失败。
#   ⚠ 必须**整词**匹配，不能用 grep 子串，否则会误判：
#       luci-app-passwall2   是与 luci-app-passwall 不同的包；
#       luci-app-xray-status 是 luci-app-xray 的**配套状态页**（可共存，不算独立栈）；
#       luci-app-daed-next / luci-app-daede 与 luci-app-daed 也是不同包。
#     因此这里用 case 的 " $PACKAGES " 整词匹配，而不是 grep。
#
# 放行：确需同时安装（仅实验用途、不指望能上网）时设 ALLOW_PROXY_CONFLICT=1。
#
# —— 2026-10-12「联动审计」补充的 9 套（原表 18 套漏掉了它们）——
#   证据均可复现（包名/体积取自 dllkids 源目录列表，描述取自上游仓库）：
#     · luci-app-nekobox   —— Thaolga/openwrt-nekobox，自述 "Unlock the Web with
#                             Sing-box"；apk 10.0 MiB（内置 sing-box 内核，
#                             普通 LuCI 前端仅几十 KiB）
#     · luci-app-honk      —— QiuSimons/luci-app-honk，README 自述「基于 eBPF 的
#                             高性能透明代理引擎，dae 兼容」；apk 9.6 MiB
#     · luci-app-jederproxy—— ttimasdf/luci-app-jederproxy，自述 "LuCI interface
#                             and nftables/iptables generator for multiple proxy
#                             backends, supporting mihomo/clash"
#     · luci-app-xjay      —— rafmilecki/luci-app-xjay，自述 "Yet another
#                             xray-core luci app"
#     · luci-app-ss-redir  —— ss-redir 即 shadowsocks 的透明重定向组件；
#                             apk 仅 3.5 KiB（极简配置页，与已确认的
#                             luci-app-redsocks 2.5 KiB 同级）
#     · luci-app-mproxy / -miniproxy / -fchomo —— 按包名（proxy / homo=mihomo）
#                             与体积推断，置信度略低；若确认不是接管型，删行即可。
#     · luci-app-domain-proxy —— mukaiu/luci-app-domain-proxy，Makefile 里
#                             LUCI_TITLE:="Domain Proxy for redsocks."，README
#                             「配合 dnsmasq-full ipset redsocks 使用」⇒ 它是
#                             redsocks 的**另一种前端**（走 dnsmasq+ipset 做域名
#                             分流），与 luci-app-redsocks 共用同一个 redsocks
#                             守护进程。两个前端同装会生成两套 ipset/规则、
#                             两个 init 抢同一进程，故独立成一栈拦下。
#
#   ⚠ 维护提示：dllkids 源有 406 个 luci-app-*，黑名单不可能穷举（这也是本次
#     审计的起因）。所以本文件在校验之后还有一段「关键词启发式提示」兜底
#     （见下方 _PROXY_KW）。**新增/发现新栈时，请三处同步**：
#       1) 本表 _PROXY_STACKS
#       2) README「代理插件互斥」的对照表
#       3) shell/custom-packages.sh 文件头「注意事项 2」的清单
# ===========================================================================
_PROXY_STACKS="
clashoo|luci-app-clashoo clashoo
nikki|luci-app-nikki nikki
openclash|luci-app-openclash
passwall|luci-app-passwall
passwall2|luci-app-passwall2
ssr-plus|luci-app-ssr-plus
homeproxy|luci-app-homeproxy
dae|luci-app-dae dae
daed|luci-app-daed daed
daed-next|luci-app-daed-next
daede|luci-app-daede
shadowsocks|luci-app-shadowsocks
shadowsocks-libev|luci-app-shadowsocks-libev
shadowsocks-rust|luci-app-shadowsocks-rust
redsocks|luci-app-redsocks
redsocks2|luci-app-redsocks2
domain-proxy|luci-app-domain-proxy
xray|luci-app-xray
v2raya|v2raya
ss-redir|luci-app-ss-redir
nekobox|luci-app-nekobox
honk|luci-app-honk honk
jederproxy|luci-app-jederproxy
xjay|luci-app-xjay
mproxy|luci-app-mproxy
miniproxy|luci-app-miniproxy
fchomo|luci-app-fchomo
"
_PROXY_HIT=""
_PROXY_KNOWN=""          # 所有已知 marker 的并集，供下方启发式兜底排除
while IFS='|' read -r _stack _markers; do
    [ -n "$_stack" ] || continue
    for _m in $_markers; do
        _PROXY_KNOWN="$_PROXY_KNOWN $_m"
        case " $PACKAGES " in
            *" $_m "*) _PROXY_HIT="$_PROXY_HIT $_stack"; break ;;
        esac
    done
done <<EOF
$_PROXY_STACKS
EOF
_PROXY_HIT="${_PROXY_HIT# }"
_PROXY_N=0
for _h in $_PROXY_HIT; do _PROXY_N=$((_PROXY_N + 1)); done

if [ "$_PROXY_N" -gt 1 ]; then
    {
        echo ""
        echo "=============================================================="
        echo "ERROR: 检测到 $_PROXY_N 套代理插件同时启用：$_PROXY_HIT"
        echo "--------------------------------------------------------------"
        echo "它们都会各自接管透明代理（防火墙规则 / DNS / TUN / 端口），"
        echo "双开会互相覆盖规则、LuCI 配置错乱、DNS 劫持冲突，"
        echo "轻则无法科学上网，重则刷机后直接断网。"
        echo ""
        echo "改法（shell/custom-packages.sh）—— 先停旧的，再开新的："
        echo "  1) 注释掉「一」里当前启用的那行（默认是 Clashoo）；"
        echo "  2) 取消你要用的那行注释；"
        echo "  3) 重跑构建。"
        echo ""
        echo "确需同时安装（仅实验用途、不指望能上网）："
        echo "  ALLOW_PROXY_CONFLICT=1 bash rockchip/build.sh"
        echo "=============================================================="
        echo ""
    } >&2
    if [ "${ALLOW_PROXY_CONFLICT:-0}" != "1" ]; then
        exit 1
    fi
    echo "⚠ ALLOW_PROXY_CONFLICT=1：已显式放行代理插件互斥，继续构建（风险自负）。" >&2
else
    echo "✅ 代理插件互斥检查通过：启用 ${_PROXY_N} 套（${_PROXY_HIT:-无}）"
fi

# ---------------------------------------------------------------------------
# 兜底：关键词启发式提示（只提示，不阻断构建）
# ---------------------------------------------------------------------------
# 黑名单挡不住「源里新冒出来的代理前端」——dllkids 有 406 个 luci-app-*，
# 靠人工维护 _PROXY_STACKS 必然滞后（本次审计就发现漏了 8 套）。所以再扫一遍
# 已选包：凡 luci-app-* 命中代理关键词、又不在已知表里的，提示一下，由人判断
# 要不要补进 _PROXY_STACKS。刻意不 exit 1，避免误伤非代理包。
_PROXY_KW="clash mihomo homo nikki passwall ssr shadowsocks redsocks xray xjay
v2ray dae homeproxy hysteria trojan brook naive singbox sing-box nekobox honk proxy"
# 白名单：命中关键词但**已知不属于接管型**的包，与 README「不算冲突」名单对应。
# 三类：状态页（xray-status）/ 服务端（*-server）/ DNS 与过滤层（dnsproxy、
# dnscrypt-proxy2、ikoolproxy、haproxy-tcp）—— 免得兜底提示自相矛盾、喊狼来了。
_PROXY_OK="luci-app-xray-status
luci-app-ssrserver-python luci-app-ssr-mudb-server luci-app-v2ray-server
luci-app-dnscrypt-proxy2 luci-app-dnsproxy luci-app-ikoolproxy luci-app-haproxy-tcp"
_PROXY_SUS=""
for _p in $PACKAGES; do
    case "$_p" in luci-app-*) ;; *) continue ;; esac
    case " $_PROXY_KNOWN " in *" $_p "*) continue ;; esac
    # 白名单用 for 逐项比对，不用 case 整串匹配：_PROXY_OK 是多行变量，
    # case 的 *" $_p "* 需要前导空格，遇到换行会漏判（实测踩过）。
    _skip=""
    for _o in $_PROXY_OK; do
        [ "$_o" = "$_p" ] && { _skip=1; break; }
    done
    [ -n "$_skip" ] && continue
    for _k in $_PROXY_KW; do
        case "$_p" in *"$_k"*) _PROXY_SUS="$_PROXY_SUS $_p"; break ;; esac
    done
done
if [ -n "$_PROXY_SUS" ]; then
    {
        echo ""
        echo "⚠ 提示：以下包名疑似代理类，但不在已知互斥表（_PROXY_STACKS）里："
        echo "   $_PROXY_SUS"
        echo "   若它确实是「透明代理接管型」插件，请补进 rockchip/build.sh 的"
        echo "   _PROXY_STACKS，并同步 README「代理插件互斥」表与"
        echo "   shell/custom-packages.sh 文件头「注意事项 2」的清单。"
        echo ""
    } >&2
fi

unset _PROXY_STACKS _PROXY_HIT _PROXY_N _PROXY_KNOWN _stack _markers _m _h
unset _PROXY_KW _PROXY_OK _PROXY_SUS _p _k _skip _o

# 构建镜像
echo "$(date '+%Y-%m-%d %H:%M:%S') - Building image with the following packages:"
echo "$PACKAGES"

# =========================================================
# 可选内核：OpenClash / SSR-Plus
# =========================================================
# 仅在 $PACKAGES 里出现对应插件时才处理，未启用则整段跳过。
#
# ⚠ 25.12 注意事项：
#   - OpenWrt 官方源**不提供**任何代理类插件；luci-app-openclash /
#     luci-app-ssr-plus / passwall2 / nikki 全部来自注入的 dllkids 第三方源。
#   - 内核优先用第三方源里的 apk 包（如 mihomo），能随源自动更新，
#     不必手动下载并固定某个旧版本二进制。
#   - 只有 OpenClash 的 meta 内核（clash_meta）源里没有，仍需单独下载。
#   - 代理插件依赖的 kmod（kmod-tun / kmod-nft-tproxy 等）由 OpenWrt 官方
#     kmods 源解析，与官方内核版本天然匹配。
# =========================================================

# ---------- OpenClash：只补 meta 内核 + GeoIP/GeoSite ----------
if echo "$PACKAGES" | grep -q "luci-app-openclash"; then
    echo "✅ 已选择 luci-app-openclash，下载 meta 内核与 GeoIP/GeoSite"

    mkdir -p files/etc/openclash/core
    # meta 内核：只用 OpenClash 官方 core 分支
    # （aarch64_generic → clash-linux-arm64.tar.gz）。
    # 由 OpenClash 自身分发、与之最匹配，含 Smart 策略组支持。
    META_URL="https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-arm64.tar.gz"
    META_BIN="files/etc/openclash/core/clash_meta"

    if ! wget -qO- "$META_URL" | tar xOvz > "$META_BIN" 2>/dev/null || [ ! -s "$META_BIN" ]; then
        echo "ERROR: OpenClash meta 内核下载失败：$META_URL" >&2
        exit 1
    fi
    chmod +x "$META_BIN"

    # GeoIP / GeoSite（meta 内核使用）
    if ! wget -q https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat \
            -O files/etc/openclash/GeoIP.dat \
       || ! wget -q https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat \
            -O files/etc/openclash/GeoSite.dat; then
        echo "ERROR: GeoIP/GeoSite 下载失败" >&2
        exit 1
    fi

    ls -lh "$META_BIN" files/etc/openclash/GeoIP.dat files/etc/openclash/GeoSite.dat
else
    echo "⚪️ 未选择 luci-app-openclash"
fi

# ---------- SSR-Plus：内核改用源内 mihomo apk，不手动下二进制 ----------
if echo "$PACKAGES" | grep -q "luci-app-ssr-plus"; then
    echo "✅ 已选择 luci-app-ssr-plus，内核使用源内 mihomo 包"
    # mihomo 由注入的第三方源以 apk 形式提供，
    # 随源更新、可被 apk 正常升级/卸载，比手动 wget 二进制可靠。
    if ! echo " $PACKAGES " | grep -q " mihomo "; then
        PACKAGES="$PACKAGES mihomo"
    fi
else
    echo "⚪️ 未选择 luci-app-ssr-plus"
fi

# =========================================================
# 注入 dllkids（kenzok8）第三方 APK 源
# =========================================================
#
# 官方 Image Builder 的 repositories 只包含 OpenWrt 官方源，
# 不含 dllkids。这里在 make image 之前把它的 APK 源与签名公钥
# 注入 Image Builder 根目录（/builder）。
#
# 重要：
#   - OpenWrt 官方源不含代理类插件与 ImmortalWrt 系应用，
#     第三方包全部依赖本源；不注入则 make image 会因找不到包而失败。
#   - 官方 Image Builder 预置 .config 已启用 CONFIG_SIGNATURE_CHECK=y
#     （Config-build.in 中 SIGNATURE_CHECK 默认 y），
#     因此 apk 会校验源签名 —— 必须提供公钥，
#     否则安装时会报 "UNTRUSTED signature"。
#
# 说明：
#   - 内核为官方原版，第三方包依赖的 kmod
#     (kmod-tun / kmod-nft-tproxy 等) 由官方 kmods 源解析；
#   - 第三方包本体为纯用户态，不受内核 ABI 影响。
# =========================================================

DLLKIDS_FEED="https://down.dllkids.xyz/openwrt-feed/25.12/aarch64_generic/packages.adb"
DLLKIDS_KEY_URL="https://down.dllkids.xyz/openwrt-feed/keys/dllkids-feed.pub.pem"

echo "==> 注入 dllkids（kenzok8）APK 源..."

grep -qxF "$DLLKIDS_FEED" repositories 2>/dev/null || echo "$DLLKIDS_FEED" >> repositories

mkdir -p keys
if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$DLLKIDS_KEY_URL" -o keys/dllkids-feed.pub.pem
elif command -v wget >/dev/null 2>&1; then
    wget -q -O keys/dllkids-feed.pub.pem "$DLLKIDS_KEY_URL"
else
    echo "ERROR: 缺少 curl/wget，无法下载 dllkids 签名公钥" >&2
    exit 1
fi

echo "---- repositories ----"
cat repositories
echo "---- keys ----"
ls -l keys

# =========================================================
# 让固件也带上该源与公钥，使设备端可以直接 apk add / apk upgrade 第三方系包
# =========================================================
# 上面注入的 repositories / keys 只用于【构建期】：Image Builder 不会把它们
# 拷贝进固件根文件系统（固件的源列表来自官方预编译的 base-files）。
# 所以这里显式写入 files/，随 make image 的 FILES= 一起进入固件。
#
#   /etc/apk/repositories.d/customfeeds.list   第三方源地址
#   /etc/apk/keys/dllkids-feed.pub.pem         公钥（CONFIG_SIGNATURE_CHECK=y，缺它会被拒签）
#
# customfeeds.list 是 apk 包为「用户自加第三方源」预留的 conffile，
# 上游默认内容就是三行注释占位（package/system/apk/files/customfeeds.list）。
# 这里原样保留那三行，并在末尾追加本项目的源 —— 与手工添加的做法一致。
# =========================================================
mkdir -p files/etc/apk/repositories.d files/etc/apk/keys

cat > files/etc/apk/repositories.d/customfeeds.list <<EOF
# add your custom package feeds here
#
# http://www.example.com/path/to/files/packages.adb
$DLLKIDS_FEED
EOF

cp -f keys/dllkids-feed.pub.pem files/etc/apk/keys/dllkids-feed.pub.pem

# =========================================================
# 中国大陆优化：设备端官方源「先备份，后切换中科大镜像」
# =========================================================
# 固件内 /etc/apk/repositories.d/distfeeds.list（apk 包生成，指向
# downloads.openwrt.org）国内直连慢。Image Builder 根目录的官方
# repositories 文件与设备端 distfeeds.list 同源同 URL 集——含 kmods
# 的内核版本哈希路径，以它为蓝本生成最可靠：
#   1. 官方原文备份 → /etc/apk/repositories.d/distfeeds.list.official.bak
#      （.bak 后缀不会被 apk 当作源读取，仅作回滚底稿）；
#   2. downloads.openwrt.org/releases/ → mirrors.ustc.edu.cn/openwrt/releases/
#      覆盖写入 distfeeds.list。USTC 镜像与官方目录逐位一致、签名相同，
#      仅下载通道不同；dllkids 源在 customfeeds.list，不受影响。
# 注意：distfeeds.list 不是 conffile，sysupgrade 升级后会随 apk 包恢复为
# 官方源（备份文件同样会被清掉），届时需重新替换——本脚本重跑构建即可。
if [ -f repositories ]; then
    # 只取官方行：此时 repositories 已被追加过 dllkids 源（见上方注入逻辑），
    # 而 dllkids 源已单独写在 customfeeds.list——若不过滤，设备端会重复声明
    # 同一第三方源，且「官方备份」也不再纯官方。
    grep -E '^https://downloads\.openwrt\.org/' repositories \
        > files/etc/apk/repositories.d/distfeeds.list.official.bak
    sed 's#https://downloads\.openwrt\.org/releases/#https://mirrors.ustc.edu.cn/openwrt/releases/#g' \
        files/etc/apk/repositories.d/distfeeds.list.official.bak \
        > files/etc/apk/repositories.d/distfeeds.list
    echo "---- 设备端官方源备份（distfeeds.list.official.bak）----"
    cat files/etc/apk/repositories.d/distfeeds.list.official.bak
    echo "---- 设备端 distfeeds.list（已切换中科大镜像）----"
    cat files/etc/apk/repositories.d/distfeeds.list
else
    echo "⚠️ 未找到 Image Builder 的 repositories 文件，设备端源保持官方默认" >&2
fi

echo "---- 随固件发布的第三方源 ----"
cat files/etc/apk/repositories.d/customfeeds.list
echo "---- 随固件发布的公钥 ----"
ls -l files/etc/apk/keys/

# =========================================================
# 去重：本文件默认列表与 shell/custom-packages.sh 的启用项
# 可能出现同名包（例如手动在两处都启用了同一插件）。
# 官方 Image Builder 的 FormatPackages 宏不去重，会把重复名原样传给
# `apk add`——apk 对重复包名幂等（solver 合并，不会报错），但这里仍
# 去重一次，让 make image 的安装清单干净、日志可读，不依赖 apk 的宽容行为。
# 注意：`$PACKAGES` 不加引号是有意的（按空白分词；包名不含空格）。
# =========================================================
PACKAGES=$(printf '%s\n' $PACKAGES | awk '!seen[$0]++' | paste -sd ' ' -)
echo "去重后待安装包数: $(echo $PACKAGES | wc -w)"

# 保险：确保 apk 签名校验开启。官方预置 .config 默认已为 y；此处幂等补齐，
# 防止将来镜像变化导致 dllkids 包被 --allow-untrusted 静默放过未验签。
grep -q '^CONFIG_SIGNATURE_CHECK=y' .config || echo 'CONFIG_SIGNATURE_CHECK=y' >> .config

make image PROFILE=$PROFILE PACKAGES="$PACKAGES" FILES="$BUILDER_DIR/files" ROOTFS_PARTSIZE=$ROOTFS_PARTSIZE

if [ $? -ne 0 ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Error: Build failed!"
    exit 1
fi

echo "$(date '+%Y-%m-%d %H:%M:%S') - Build completed successfully."
