#!/bin/sh
# ============================================================================
# 99-custom.sh — OpenWrt 首次启动初始化
# 目标：FriendlyARM NanoPi R2S / RK3328
# 安装位置：/etc/uci-defaults/99-custom.sh
#
# 固定网络映射（与 R2S 官方 board.d 定义一致）：
#   eth0：板载 GMAC -> WAN
#   eth1：USB RTL8153 -> LAN；br-lan 及其端口由 config_generate 创建
#
# 职责：WAN/WAN6、LAN 管理地址、网络选项、DHCP、防火墙选项，
#       以及中国大陆优化（时区 / 国内 NTP）。
# 不放开 WAN 入站，不改写固件品牌，不注入第三方插件补丁。
#
# 执行约定：这是 uci-defaults 脚本，不应作为普通运行脚本单独执行。
# 标准启动流程会在全部默认脚本执行后统一 uci commit；本脚本不提前提交，
# 避免中途提交其他初始化脚本的暂存改动。
# ============================================================================

# 固定 IFS，并关闭路径名展开，避免配置值中的 *、?、[] 被展开成文件名。
IFS=' 	
'
set -f
LC_ALL=C
export LC_ALL

# ---------------------------------------------------------------------------
# 构建期注入的辅助文件统一放在 /etc/openwrt-builder/。
#
# ⚠ 不要把任何**非 uci 配置包**的文件放进 /etc/config/：
#   libuci 会 glob 整个配置目录（file.c: uci_list_config_files() 用
#   glob("<confdir>/*", GLOB_MARK)），只跳过「文件名含 `.`」的条目
#   （file.c: get_filename()，源码注释原文 "Filename with '.' are ignored
#   and not parsed"），其余一律按 uci 语法解析。无后缀文件（如 wan-settings）
#   会被当成配置包解析，首行 `wan_proto=dhcp` 立刻命中 file.c:553 的
#   uci_parse_error(ctx, "invalid command")，于是**任何** uci 调用
#   （含 LuCI「软件包」页的安装动作）都会打印：
#       uci: Parse error (invalid command) at line 1, byte 0
#   本脚本自身的日志也遵循该约定，放在 /etc/openwrt-builder/ 下。
# ---------------------------------------------------------------------------
SETTINGS_DIR='/etc/openwrt-builder'
mkdir -p "$SETTINGS_DIR" 2>/dev/null || :

# 迁移兼容：旧版固件把 wan-settings 误放在 /etc/config/ 下（无后缀 → 被 uci
# 当作配置包解析）。保留配置升级到本版时该文件会被 sysupgrade 带过来，因此
# 这里在**任何 uci 调用之前**先删掉它，否则本脚本自身的 uci 调用也会刷出
# "Parse error (invalid command)"，并可能影响 require_uci_section 判定。
# （/etc/config/ 下旧版遗留的 custom_router_ip.txt、uci-defaults-log.txt 带 `.`
#  后缀，uci 的 get_filename() 会跳过，无害，故不动它们。）
rm -f /etc/config/wan-settings 2>/dev/null || :

LOGFILE="$SETTINGS_DIR/uci-defaults-log.txt"
CR=$(printf '\r')

log() {
    printf '%s\n' "$*" >> "$LOGFILE" 2>/dev/null || :
}

fail() {
    log "ERROR: $*"
    printf '99-custom.sh: ERROR: %s\n' "$*" >&2
    exit 1
}

uci_do() {
    uci "$@" || fail "UCI command failed: uci $*"
}

# 删除可选项：选项不存在时属于正常情况，不应中断初始化。
uci_delete_optional() {
    uci -q delete "$1" >/dev/null 2>&1 || :
}

trim() {
    TRIMMED=$(printf '%s' "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
}

# 校验标准点分十进制 IPv4；拒绝前导零，避免不同组件对八进制写法解释不一。
is_ipv4() {
    IPV4_CANDIDATE=$1
    case "$IPV4_CANDIDATE" in
        ''|*[!0-9.]*|.*|*.|*..*) return 1 ;;
    esac

    _saved_ifs=$IFS
    IFS='.'
    set -- $IPV4_CANDIDATE
    IFS=$_saved_ifs
    [ "$#" -eq 4 ] || return 1

    for _octet do
        case "$_octet" in
            0|[1-9]|[1-9][0-9]|1[0-9][0-9]|2[0-4][0-9]|25[0-5]) ;;
            *) return 1 ;;
        esac
    done
    return 0
}

# 检查 IPv4/CIDR，并写入 NORMALIZED_CIDR。未带前缀时使用调用方指定的默认值。
normalize_ipv4_cidr() {
    _normal_value=$1
    _normal_default_prefix=$2

    case "$_normal_value" in
        */*)
            _normal_ip=${_normal_value%%/*}
            _normal_prefix=${_normal_value#*/}
            case "$_normal_prefix" in */*) return 1 ;; esac
            ;;
        *)
            _normal_ip=$_normal_value
            _normal_prefix=$_normal_default_prefix
            ;;
    esac

    is_ipv4 "$_normal_ip" || return 1
    case "$_normal_prefix" in
        [1-9]|1[0-9]|2[0-9]|3[0-2]) ;;
        *) return 1 ;;
    esac

    NORMALIZED_CIDR="$_normal_ip/$_normal_prefix"
    return 0
}

# DNS 支持 IPv4 和普通 IPv6 字面地址（不含 zone ID 或嵌入式 IPv4 尾段）。
is_ipv6_dns_literal() {
    printf '%s\n' "$1" | awk '
        function count_groups(s, a, n, i) {
            if (s == "") return 0
            n = split(s, a, ":")
            for (i = 1; i <= n; i++) {
                if (length(a[i]) < 1 || length(a[i]) > 4 || a[i] !~ /^[[:xdigit:]]+$/)
                    return -1
            }
            return n
        }
        {
            if ($0 == "" || $0 !~ /^[[:xdigit:]:]+$/) exit 1
            pos = index($0, "::")
            if (pos) {
                left = substr($0, 1, pos - 1)
                right = substr($0, pos + 2)
                if (index(right, "::")) exit 1
                nl = count_groups(left, la)
                nr = count_groups(right, ra)
                if (nl < 0 || nr < 0 || nl + nr >= 8) exit 1
            } else {
                if ($0 ~ /^:/ || $0 ~ /:$/) exit 1
                n = count_groups($0, a)
                if (n != 8) exit 1
            }
        }
    '
}

is_dns_address() {
    case "$1" in
        *:*) is_ipv6_dns_literal "$1" ;;
        *)   is_ipv4 "$1" ;;
    esac
}

require_uci_section() {
    uci -q get "$1" >/dev/null 2>&1 || fail "required UCI section missing: $1"
}

log "Starting 99-custom.sh at $(date)"

# ---------------------------------------------------------------------------
# 1. 读取构建阶段生成的 WAN 参数
# 文件格式为 key=value；只解析数据，不 source，避免把配置内容当 Shell 代码执行。
# 位置：/etc/openwrt-builder/wan-settings（构建期由 rockchip/build.sh 写入）
# ---------------------------------------------------------------------------
SETTINGS_FILE="$SETTINGS_DIR/wan-settings"
wan_proto=''
wan_ip=''
wan_gateway=''
wan_dns=''

if [ -f "$SETTINGS_FILE" ]; then
    [ -r "$SETTINGS_FILE" ] || fail "cannot read $SETTINGS_FILE"

    while IFS= read -r _line || [ -n "$_line" ]; do
        _line=${_line%"$CR"}
        trim "$_line"
        _line=$TRIMMED
        case "$_line" in
            ''|'#'*) continue ;;
            *=*)
                _key=${_line%%=*}
                _value=${_line#*=}
                trim "$_key"; _key=$TRIMMED
                trim "$_value"; _value=$TRIMMED
                ;;
            *)
                log "WARN: ignoring malformed WAN settings line"
                continue
                ;;
        esac

        case "$_key" in
            wan_proto)   wan_proto=$_value ;;
            wan_ip)      wan_ip=$_value ;;
            wan_gateway) wan_gateway=$_value ;;
            wan_dns)     wan_dns=$_value ;;
            *)           : ;; # 忽略其他键，允许将来扩展配置文件
        esac
    done < "$SETTINGS_FILE"
else
    log 'WAN settings file not found; using built-in defaults'
fi

wan_proto=${wan_proto:-dhcp}
wan_ip=${wan_ip:-192.168.1.2}
wan_gateway=${wan_gateway:-192.168.1.1}
wan_dns=${wan_dns:-$wan_gateway}

case "$wan_proto" in
    dhcp|static) ;;
    *) fail 'wan_proto must be dhcp or static' ;;
esac

# 先读取并验证全部地址，再执行任何 UCI 修改，避免坏输入先清除旧 LAN 地址。
if [ "$wan_proto" = 'static' ]; then
    normalize_ipv4_cidr "$wan_ip" 24 || fail 'invalid WAN IPv4 address/CIDR in wan-settings'
    WAN_IP_CIDR=$NORMALIZED_CIDR
    is_ipv4 "$wan_gateway" || fail 'invalid WAN IPv4 gateway in wan-settings'

    _dns_count=0
    for _dns in $wan_dns; do
        is_dns_address "$_dns" || fail 'invalid DNS address in wan-settings'
        _dns_count=$((_dns_count + 1))
    done
    [ "$_dns_count" -gt 0 ] || fail 'no DNS servers configured for static WAN'
fi

# ---------------------------------------------------------------------------
# 2. LAN 管理地址
# custom_router_ip.txt：读取首个非空行；支持空白、CRLF 和带/前缀的 CIDR。
# 位置：/etc/openwrt-builder/custom_router_ip.txt（工作流生成 custom/ 后随固件注入）
# ---------------------------------------------------------------------------
CUSTOM_IP='192.168.2.1'
IP_VALUE_FILE="$SETTINGS_DIR/custom_router_ip.txt"

if [ -f "$IP_VALUE_FILE" ]; then
    [ -r "$IP_VALUE_FILE" ] || fail "cannot read $IP_VALUE_FILE"
    while IFS= read -r _line || [ -n "$_line" ]; do
        _line=${_line%"$CR"}
        trim "$_line"
        _line=$TRIMMED
        [ -n "$_line" ] || continue
        CUSTOM_IP=$_line
        break
    done < "$IP_VALUE_FILE"
fi

normalize_ipv4_cidr "$CUSTOM_IP" 24 || fail 'invalid LAN IPv4 address/CIDR in custom_router_ip.txt'
LAN_IP_CIDR=$NORMALIZED_CIDR

if [ "$wan_proto" = 'static' ]; then
    log "WAN mode: static; ip=$WAN_IP_CIDR gateway=$wan_gateway dns=$wan_dns"
else
    log 'WAN mode: DHCP'
fi
log "LAN management address: $LAN_IP_CIDR"

# ---------------------------------------------------------------------------
# 3. 写入前置条件检查
# 引用带 @ 和 [n] 的 UCI 路径时一律加引号，避免 Shell 路径名展开。
# ---------------------------------------------------------------------------
command -v uci >/dev/null 2>&1 || fail 'uci command not found'
require_uci_section 'network.lan'
require_uci_section 'dhcp.lan'
require_uci_section 'dhcp.wan'
require_uci_section 'dhcp.@dnsmasq[0]'
# 时序说明（已对照官方 openwrt-25.12 源码核实）：
#   - 网络配置由 preinit 钩子 /lib/preinit/82_config_generate 在 uci-defaults
#     之前生成（含 /etc/board.json 与 network.globals.ula_prefix='auto'）；
#   - uci-defaults 按文件名 ASCII 字母序执行，odhcpd 包的脚本安装名为
#     /etc/uci-defaults/15_odhcpd（源文件名才叫 odhcpd.defaults），**先于**
#     本脚本（99-*）运行，已创建 dhcp.odhcpd 段并写入 dhcp.lan 的
#     ra/dhcpv6/ra_slaac 等官方默认。
#   因此 dhcp.odhcpd 在本脚本运行时确实存在；这里仍不把它列为硬性前置条件——
#   若将来构建时移除 odhcpd，脚本应仍能完成其余网络配置。
require_uci_section 'firewall.@defaults[0]'

# ---------------------------------------------------------------------------
# 4. WAN / WAN6
# R2S 固定由 eth0 接 WAN。静态 WAN 使用 CIDR 列表记法；DHCP 模式清理残留静态项。
# ---------------------------------------------------------------------------
uci_do set network.wan=interface
uci_do set network.wan.device='eth0'

case "$wan_proto" in
    static)
        uci_do set network.wan.proto='static'
        uci_delete_optional 'network.wan.netmask'
        uci_delete_optional 'network.wan.ipaddr'
        uci_do add_list "network.wan.ipaddr=$WAN_IP_CIDR"
        uci_do set "network.wan.gateway=$wan_gateway"

        uci_delete_optional 'network.wan.dns'
        for _dns in $wan_dns; do
            uci_do add_list "network.wan.dns=$_dns"
        done
        ;;
    dhcp)
        uci_do set network.wan.proto='dhcp'
        for _opt in ipaddr netmask gateway dns; do
            uci_delete_optional "network.wan.$_opt"
        done
        ;;
esac

uci_do set network.wan6=interface
uci_do set network.wan6.device='eth0'
uci_do set network.wan6.proto='dhcpv6'
uci_do set network.wan6.reqaddress='try'
uci_do set network.wan6.reqprefix='auto'
uci_do set network.wan6.norelease='1'

# ---------------------------------------------------------------------------
# 5. LAN 地址与网络全局选项
# 不重建 br-lan，也不改动官方生成的桥设备、端口或 MAC 地址。
# ---------------------------------------------------------------------------
uci_do set network.lan.proto='static'
uci_delete_optional 'network.lan.netmask'
uci_delete_optional 'network.lan.ipaddr'
uci_do add_list "network.lan.ipaddr=$LAN_IP_CIDR"

# 按当前规划配置 LAN IPv6：关闭该接口的前缀继续委派，申请 /64，接口 ID 使用 EUI-64。
uci_do set network.lan.delegate='0'
uci_do set network.lan.ip6assign='64'
uci_do set network.lan.ip6ifaceid='eui64'

if ! uci -q get network.globals >/dev/null 2>&1; then
    uci_do set network.globals=globals
fi
# 删除自动生成的 ULA 前缀，避免 LAN 同时使用 ULA 与上游分配的 IPv6 前缀。
uci_delete_optional 'network.globals.ula_prefix'
uci_do set network.globals.packet_steering='1'

log "iface map: lan=$(uci -q get network.lan.device) wan=$(uci -q get network.wan.device) wan6=$(uci -q get network.wan6.device)"

# ---------------------------------------------------------------------------
# 6. DHCP / DNS
# 时序说明（已对照官方 openwrt-25.12 源码核实）：uci-defaults 按文件名 ASCII
# 字母序执行，odhcpd 包的脚本安装名为 15_odhcpd，**先于**本脚本（99-*）运行，
# 已写入官方默认：dhcp.lan 的 dhcpv4/dhcpv6/ra = server（LAN 为静态地址时）、
# ra_slaac=1、ra_flags managed-config/other-config，以及 dhcp.odhcpd 段
# （maindhcp=0）。dnsmasq 行为由官方 conffile 决定。官方默认即所需行为。
# 因此此前版本对等价默认值的「防御性删除/重写」已移除，其中：
#   - 删 dhcpv6 尤其有害：odhcpd 内置默认是 MODE_DISABLED，删掉 15_odhcpd 写入的
#     'server' 会直接关掉 LAN 的 DHCPv6 服务（IPv6 地址下发失效）；
#   - 删 ra_slaac / maindhcp 属空操作（odhcpd 内置默认 true / false，与官方一致）；
#   - ra_preference='medium'、dnsmasq 五项删除、dns_redirect 删除、wan 段
#     leasetime/start/limit 均为空操作或与 ignore='1' 下无意义，已移除。
# 仅保留一项：把 WAN 侧 DHCP 服务显式钉死为禁用（官方 conffile 本就 ignore=1）。
# ---------------------------------------------------------------------------
uci_do set dhcp.wan.ignore='1'

# ---------------------------------------------------------------------------
# 7. 防火墙
# 不修改 zone 的 input/forward/output 策略；WAN 入站继续使用官方默认拒绝策略。
#
# 官方 conffile（firewall4 仓库 root/etc/config/firewall）写的是**遗留选项名**
# `option syn_flood 1`；而 firewall4 实际读取的是 `synflood_protect`，并有回退
# （fw4.uc parse_defaults，25.12 所用 commit b6e5157）：
#   syn_flood:          [ "bool" ],
#   synflood_protect:   [ "bool" ],
#   synflood_rate:      [ "limit", "25/second" ],
#   synflood_burst:     [ "int", "50" ],
#   ...
#   if (defs.synflood_protect === null)
#       defs.synflood_protect = defs.syn_flood;
#   delete defs.syn_flood;              // ← fw4 自己就把这个别名删掉了
# 规则生成处：templates/ruleset.uc 用 fw4.default_option("synflood_protect")
# 决定是否产出 syn_flood 链与限速跳转规则（即官方默认本就开启，25/second + burst 50）。
#
# 因此做法是「写入现代选项名 + 删除遗留别名」，这也正是 LuCI 自己的行为
# （luci-app-firewall 的 view/firewall/zones.js，openwrt-25.12）：
#   o = s.option(form.Flag, 'synflood_protect', _('Enable SYN-flood protection'));
#   o.cfgvalue = ... uci.get(...,'synflood_protect') ?? uci.get(...,'syn_flood');
#   o.write    = ... uci.unset(...,'syn_flood'); uci.set(...,'synflood_protect', value);
# ⇒ LuCI 读的是 synflood_protect，所以我们置 1 后复选框正确显示为「已勾选」；
#   删除 syn_flood 只是让 uci show firewall 输出唯一化，不会削弱防护
#   （synflood_protect 已为 1，回退分支永不触发）。
#   注意 syn_flood **不是**死选项（fw4 与 LuCI 都识别它），删除属「迁移」而非「清理垃圾」。
# 顺序：先置新选项、再删旧别名——即使删除步骤异常，回退分支仍能兜住防护。
#
# 流量卸载（flow_offloading / flow_offloading_hw）官方默认即关闭（fw4.uc 内置 "0"），
# 不再触碰——默认固件没有 TPROXY 透明代理插件，无冲突场景；日后若启用 passwall 等
# TPROXY 插件，也请勿在 LuCI 开启流量卸载（fast path 会绕过 netfilter 钩子）。
# 此前版本的 fullcone='0' 已移除：官方 firewall4 无此选项（ImmortalWrt 补丁），
# 写入只会在配置里留下无人识别的死选项。
# ---------------------------------------------------------------------------
uci_do set firewall.@defaults[0].synflood_protect='1'
uci_delete_optional 'firewall.@defaults[0].syn_flood'

# ---------------------------------------------------------------------------
# 8. 中国大陆优化：时区与 NTP
# 官方默认 UTC + 4 个 openwrt.pool.ntp.org（国内解析慢、可达性一般）。
# 改为北京时间（POSIX TZ 记法 CST-8）与国内 NTP 服务器。
# ---------------------------------------------------------------------------
require_uci_section 'system.@system[0]'
uci_do set system.@system[0].timezone='CST-8'
uci_do set system.@system[0].zonename='Asia/Shanghai'

require_uci_section 'system.ntp'
uci_delete_optional 'system.ntp.server'
for _ntp in ntp.aliyun.com ntp1.aliyun.com time1.cloud.tencent.com cn.pool.ntp.org; do
    uci_do add_list "system.ntp.server=$_ntp"
done
unset _ntp

# ---------------------------------------------------------------------------
# 9. 可选设置（默认不执行）
# 如需默认使用 Bootstrap，取消下一行注释；无需手动 uci commit。
# uci_do set luci.main.mediaurlbase='/luci-static/bootstrap'
#
# ttyd / dropbear 保持包默认的 LAN 监听限制，不在本脚本中清空 interface 限制。
# 不包含设备专属静态 DHCP 租约、NTP 域名重写、Docker 规则或第三方插件补丁。
# ---------------------------------------------------------------------------

log '99-custom.sh completed; UCI changes left staged for the uci-defaults runner'
exit 0
