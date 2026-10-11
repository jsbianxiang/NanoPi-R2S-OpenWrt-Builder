#!/bin/sh
# ============================================================================
# 99-custom.sh — OpenWrt 首次启动初始化
# 目标：FriendlyARM NanoPi R2S / RK3328
# 安装位置：/etc/uci-defaults/99-custom.sh
#
# 固定网络映射（与 R2S 官方 board.d 定义一致）：
#   eth0：板载 GMAC -> WAN
#   eth1：USB RTL8153 -> LAN
#   全新安装时 config_generate 会把 LAN 强制做成网桥：新建
#   `config device br-lan`（type=bridge、ports=eth1），并令 network.lan.device='br-lan'。
#
# 职责：
#   ① 旧参数名 -> 新参数名迁移：
#        第 4 节  = LuCI「网络」菜单**保存**路径的重命名（范围最窄、最贴近用户操作）；
#        第 10 节 = 非保存路径的迁移（页面弹窗 / 官方首启脚本），
#                  属冗余加固，可整节删除。
#   ② WAN/WAN6、LAN 管理地址、网络选项、DHCP/DNS、防火墙选项；
#   ③ 中国大陆优化（时区 / 国内 NTP）。
# 不放开 WAN 入站，不改写固件品牌，不注入第三方插件补丁。
#
# 写入原则：**只写与「不写时的生效值」不同的项**。凡是官方 conffile /
#   config_generate / 消费者的内置默认已经等于我们想要的值，一律不写
#   （第 5 / 6 / 7 节各有一段注释列明哪些属于这类等价项、依据是什么）。
#
# 执行约定：这是 uci-defaults 脚本，不应作为普通运行脚本单独执行。
# 标准启动流程会在全部默认脚本执行后统一 uci commit；本脚本不提前提交，
# 避免中途提交其他初始化脚本的暂存改动。
#
# 排序：本脚本名以 99- 开头，在 /etc/uci-defaults/ 里按 ASCII 字母序**最后**执行
#   （见 /etc/init.d/boot 的 uci_apply_defaults()：files="$(ls)"，逐个在子 shell 里
#   source，全部跑完才统一 commit，成功执行的脚本随即 rm -f）。
#   因此官方各包的迁移脚本（00_ / 11_ / 14_ / 15_ / 50_ 等）都排在本脚本之前。
#   每次刷机（含「保留配置」）rootfs 都会被整体替换，这些脚本会重新出现并再跑一遍，
#   所以第 10 节里对应官方脚本的那几项是冗余的（保留理由见该节开头）。
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

# 列出配置包 $1 中类型为 $2 的所有段名。
# 具名段返回 'lan' 这类名字，匿名段返回 '@interface[0]' 这类路径，两者都可
# 直接拼成 uci 路径使用。只用 uci 自身的输出，不依赖 lib/functions.sh 的
# config_load/config_foreach。
uci_section_names() {
    uci -q show "$1" 2>/dev/null | sed -n "s/^$1\.\([^=]*\)=$2\$/\1/p"
}

# 仅当选项当前值**恰为**已知旧值时改成新值。
# 用于「旧参数名 -> 新参数名」：值不等说明用户已经改过（或已是新写法），
# 此时保持不动，避免覆盖用户自定义值。
uci_migrate_value() {
    if [ "$(uci -q get "$1")" = "$2" ]; then
        uci_do set "$1=$3"
        log "migrate: $1 '$2' -> '$3'"
    fi
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
require_uci_section 'dhcp.@dnsmasq[0]'
# 注意这里**不** require dhcp.wan：本脚本不往 dhcp.wan 写任何东西
# （官方 conffile 已带 `option ignore 1`，属等价项，见第 7 节），
# 硬性要求它存在只会平添一个无谓的失败点。
# 同理不 require dhcp.odhcpd——见下面时序说明。
# 时序说明（已对照官方 openwrt-25.12 源码核实）：
#   - 网络配置由 preinit 钩子 /lib/preinit/82_config_generate 在 uci-defaults
#     之前生成（含 /etc/board.json 与 network.globals.ula_prefix='auto'）；
#     注意 config_generate 开头是 `[ -s /etc/config/network -a -s /etc/config/system ]
#     && exit 0`，**已有配置时整体跳过**——所以保留配置升级时 /etc/config/network
#     沿用旧固件内容（含旧的 ifname 写法），这正是第 10.1 节存在的原因。
#   - uci-defaults 按文件名 ASCII 字母序执行，odhcpd 包的脚本安装名为
#     /etc/uci-defaults/15_odhcpd（源文件名才叫 odhcpd.defaults），**先于**
#     本脚本（99-*）运行，已创建 dhcp.odhcpd 段并写入 dhcp.lan 的
#     ra/dhcpv6/ra_slaac 等官方默认。
#   因此 dhcp.odhcpd 在本脚本运行时确实存在；这里仍不把它列为硬性前置条件——
#   若将来构建时移除 odhcpd，脚本应仍能完成其余网络配置。
require_uci_section 'firewall.@defaults[0]'

# ---------------------------------------------------------------------------
# 4. Web 界面「网络」菜单下**保存**产生的旧参数名 -> 新参数名迁移
#
# 范围严格限定为：用户在 LuCI 的「网络」菜单任一页面点「保存并应用」时，由该页面
# option 的 o.write 处理器产生的旧参数名 -> 新参数名重命名。**不掺入**
# 「打开页面时的弹窗迁移」（见 10.1）和「官方首启脚本」（见 10.2 / 10.3）。
#
# 「网络」菜单的成员（对照 luci-25.12 的 menu.d JSON 核实）：
#   modules/luci-mod-network/.../menu.d/luci-mod-network.json
#     admin/network/wireless(15)、switch(20)、network(10,「接口」)、
#     routes(30,「路由」)、dhcp(40)、dns(45)、diagnostics(50)
#   applications/luci-app-firewall/.../menu.d/luci-app-firewall.json
#     admin/network/firewall(60) → zones / forwards / rules / snats / ipsets / custom
#   ⇒ **防火墙也在「网络」菜单下**，它的保存路径同属本节范围。
#     （该页 depends.fs 要求 /sbin/fw3 可执行；firewall4 用 root/sbin/fw3 -> fw4
#      这个**符号链接**满足它——codeload 的 tar 包在 Windows 上会把符号链接落成
#      0 字节普通文件，容易误判成「fw3 不存在、防火墙页不显示」。）
#
# 把「网络」菜单下**全部** o.write 处理器过了一遍，真正的旧 -> 新重命名只有三处：
#   ① firewall.@defaults[0].syn_flood -> synflood_protect     zones.js:43-51
#   ② network.<route>.netmask         -> CIDR 合写进 target   routes.js:61-78
#   ③ firewall.<zone>.extra           -> extra_src/extra_dest zones.js:314-341
# ② 是等价改写、③ 在本固件上根本不渲染，都不需要动（原因见 4.2），
# 所以本节**只实现 ①**。
#
# 本节的操作都幂等：值已经是新写法时不动。
# ---------------------------------------------------------------------------

# --- 4.1 防火墙：syn_flood -> synflood_protect（唯一要实现的保存路径重命名） --
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
#   delete defs.syn_flood;              // <- fw4 自己就把这个别名删掉了
# 规则生成处：templates/ruleset.uc 用 fw4.default_option("synflood_protect")
# 决定是否产出 syn_flood 链与限速跳转规则（即官方默认本就开启，25/second + burst 50）。
#
# 因此做法是「写入现代选项名 + 删除遗留别名」，这也正是 LuCI 自己的行为——
# luci-app-firewall 的 view/firewall/zones.js:43-51（openwrt-25.12）：
#   o = s.option(form.Flag, 'synflood_protect', _('Enable SYN-flood protection'));
#   o.cfgvalue = ... uci.get(...,'synflood_protect') ?? uci.get(...,'syn_flood');
#   o.write    = ... uci.unset(...,'syn_flood'); uci.set(...,'synflood_protect', value);
# => LuCI 读的是 synflood_protect，所以我们置 1 后复选框正确显示为「已勾选」；
#    删除 syn_flood 只是让 uci show firewall 输出唯一化，不会削弱防护
#    （synflood_protect 已为 1，回退分支永不触发）。
#    注意 syn_flood **不是**死选项（fw4 与 LuCI 都识别它），删除属「迁移」而非「清理垃圾」。
# 顺序：先置新选项、再删旧别名——即使删除步骤异常，回退分支仍能兜住防护。
#
# 这里不修改 zone 的 input/forward/output 策略；WAN 入站继续使用官方默认拒绝策略。
# 流量卸载（flow_offloading / flow_offloading_hw）官方默认即关闭（fw4.uc 内置 "0"），
# 不再触碰——默认固件没有 TPROXY 透明代理插件，无冲突场景；日后若启用 passwall 等
# TPROXY 插件，也请勿在 LuCI 开启流量卸载（fast path 会绕过 netfilter 钩子）。
# 此前版本的 fullcone='0' 已移除：官方 firewall4 无此选项（ImmortalWrt 补丁），
# 写入只会在配置里留下无人识别的死选项。
uci_do set firewall.@defaults[0].synflood_protect='1'
uci_delete_optional 'firewall.@defaults[0].syn_flood'

# --- 4.2 有意**不**实现的保存路径迁移（附原因） -----------------------------
#
# ② 路由 netmask -> CIDR 合写进 target（routes.js:61-78）
#    o.cfgvalue 把旧式 `option netmask 255.255.255.0` 与 target 合成 CIDR 显示；
#    o.write 则是 `uci.set(target, formvalue); uci.unset(netmask)`——**确是保存路径**。
#    但 netifd 至今仍显式解析 netmask（interface-ip.c:53 [ROUTE_MASK]="netmask"，
#    interface-ip.c:458 route->mask = parse_netmask_string(...)；proto.c:47 OPT_NETMASK），
#    所以这是**等价改写**而非功能迁移；且本项目不创建静态路由，没有对象可迁。⇒ 不做。
#
# ③ zone extra -> extra_src / extra_dest（zones.js:314-341）
#    o.write 是 `uci.unset(extra); uci.set(extra_src|extra_dest, value)`——**确是保存路径**。
#    但整块被 `if (!fw4) { ... }` 包住：**只有 fw3 才渲染「Extra iptables arguments」
#    标签页**；本固件是 fw4（manifest: firewall4 2025.03.17~b6e51575-r2），该标签页
#    不存在，o.write 永无触发机会。⇒ 不做。
#
# 另外几处**看着像迁移、其实不是**的，一并记下以免日后误加：
#   - dhcp 静态租约的 name / dns（dhcp.js:941-949）：unset 在 `so.remove`（删除按钮）里；
#     `so.write`（保存）反而是 `uci.set(name)` + `uci.set(dns,'1')`。是删除动作，不是重命名。
#   - dhcp dnsrecord 的 hexdata（dns.js:474-482 hexencodesave）：保存时若「Raw Data」为空
#     则 `uci.unset(hexdata)`。是保存路径的**删除**，不是旧 -> 新重命名；本项目不建 dnsrecord。
#   - firewall 的 flow_offloading / flow_offloading_hw（zones.js:91-94）：`uci.set(..., null)`
#     即「写 null = 删除」，是同一选项名的存 / 删，不是重命名。
#   - firewall 的 zone 改名（zones.js:133-138 → firewall.renameZone()）与 zone 的 network
#     成员变更（zones.js:188 → addNetwork / deleteNetwork）：是用户主动改的**内容**，
#     不是参数名迁移。

# ---------------------------------------------------------------------------
# 5. WAN / WAN6
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
# 这里**不**显式写 reqaddress / reqprefix：两者都与「不写」完全等价。
#   - reqaddress 缺省时 odhcp6c 收不到 -N 参数，而它的内置默认就是 TRY
#     （odhcp6c src/config.c:85 `config_dhcp.ia_na_mode = IA_MODE_TRY;`；
#      显式 'try' 走的 config_set_request_addresses("try") 同样落在 IA_MODE_TRY）；
#   - reqprefix 缺省与 'auto' 在 proto 层被归一成同一个值
#     （odhcp6c/files/dhcpv6.sh:101
#      `[ -z "$reqprefix" -o "$reqprefix" = "auto" ] && reqprefix=0`
#      ⇒ 两者都发 `-P0`，最终都落到 IA_MODE_TRY）。
# norelease 则**不是**等价项，必须写：dhcpv6.sh:148
#   `[ "$norelease" = "1" ] && append opts "-k"`
# 只有显式 1 才会加 -k（重启/下线时不发 RELEASE，降低上级回收地址导致前缀变化的概率）。
uci_do set network.wan6.norelease='1'

# ---------------------------------------------------------------------------
# 6. LAN 地址与网络全局选项
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

# 删除自动生成的 ULA 前缀，避免 LAN 同时使用 ULA 与上游分配的 IPv6 前缀。
# （preinit 阶段 config_generate 写的是 ula_prefix='auto'，随后
#  /etc/uci-defaults/12_network-generate-ula 在首启时把它落成随机 fdxx::/48。）
#
# 这里不再「补 network.globals 段」、也不再写 packet_steering——两者都是等价项：
#   - network.globals 由 config_generate **无条件**创建
#     （`delete network.globals; set network.globals='globals';
#       set network.globals.dhcp_default_duid='auto'`），保留配置升级时它同样存在，
#     所以「段缺失就补」的分支永远不触发，是死代码；
#   - packet_steering 的唯一消费者 /etc/init.d/packet_steering 只在值为**字面量 '0'**
#     时关闭引导（packet-steering.uc: `case '0': disable = true;`）；选项缺失时传进去
#     的是空串，同样不命中该分支 ⇒「不写」与「写 1」行为完全一致。
#     （该 init 脚本由 netifd 包安装，`default_postinst` 会对包内所有 /etc/init.d/*
#      执行 rc.common enable，所以它确实在跑；rockchip 也没有像 mt7621 那样的
#      uci-defaults 去预设这个值。）
uci_delete_optional 'network.globals.ula_prefix'

log "iface map: lan=$(uci -q get network.lan.device) wan=$(uci -q get network.wan.device) wan6=$(uci -q get network.wan6.device)"

# ---------------------------------------------------------------------------
# 7. DHCP / DNS
# 时序说明（已对照官方 openwrt-25.12 源码核实）：uci-defaults 按文件名 ASCII
# 字母序执行，odhcpd 包的脚本安装名为 15_odhcpd，**先于**本脚本（99-*）运行，
# 已写入官方默认：dhcp.lan 的 dhcpv4/dhcpv6/ra = server（LAN 为静态地址时）、
# ra_slaac=1、ra_flags managed-config/other-config，以及 dhcp.odhcpd 段
# （maindhcp=0）。dnsmasq 行为由官方 conffile 决定。
# ⚠ 但 15_odhcpd 开头是 `if [ -n "$(uci -q get dhcp.odhcpd)" ]; then ... exit 0; fi`：
#   保留配置升级时 dhcp.odhcpd 已存在 ⇒ 它只做四个选项迁移就退出，**不补**上面那批
#   默认值（见 MIGRATIONS.md §5.2）。所以 dhcpv6 / ra / ra_flags 必须自己写一遍。
#
# 因此此前版本对等价默认值的「防御性删除/重写」已移除，其中：
#   - 删 dhcpv6 尤其有害：odhcpd 内置默认是 MODE_DISABLED，删掉 15_odhcpd 写入的
#     'server' 会直接关掉 LAN 的 DHCPv6 服务（IPv6 地址下发失效）；
#   - 删 ra_slaac / maindhcp 属空操作（odhcpd 内置默认 true / false，与官方一致）；
#   - ra_preference='medium'、dnsmasq 五项删除、dns_redirect 删除、wan 段
#     leasetime/start/limit 均为空操作或与 ignore='1' 下无意义，已移除。
#
# 本节的写法是「只写与官方默认**不同**的值」——凡是「不写也一样」的一律删掉：
#   - dhcp.wan.ignore：官方 dnsmasq conffile（dnsmasq/files/dhcp.conf）里就有
#     `config dhcp wan / option ignore 1`，不写也是 1；
#   - dhcp.lan.dhcpv4：它在本固件上**只有一个有效消费者**——dnsmasq。
#     dnsmasq.init:578 `config_get dhcpv4 "$cfg" dhcpv4`（无默认）+:602
#     `if [ "$dhcpv4" != "disabled" ]` ⇒ 缺失（空串）≠ disabled，DHCPv4 照常下发，
#     即「缺失 == server」。odhcpd 虽然也注册了 IFACE_ATTR_DHCPV4，但
#     src/config.c:1282 `iface->dhcpv4 = config.main_dhcpv4 ? mode : MODE_DISABLED;`
#     —— 官方 15_odhcpd 写的 maindhcp=0，odhcpd 的 DHCPv4 恒为 DISABLED，
#     这个选项对 odhcpd 完全没有影响。
# dhcpv6 / ra 则**必须**写：odhcpd 的内置默认是 MODE_DISABLED
# （odhcpd src/config.c:312-314 `iface->dhcpv4/dhcpv6/ra = MODE_DISABLED;`），
# 而这两个选项**没有** dnsmasq 兜底 ⇒ 缺失就等于关掉 LAN 的 DHCPv6 与 RA。
#
# ra_flags 同样**必须**写，而且理由与上面相反（它「不写 ≠ 官方值」）：
#   - odhcpd 的内置默认**只有 O 标志**（src/config.c:332
#     `iface->ra_flags = ND_RA_FLAG_OTHER;`），即「不写 == managed-config 缺失」；
#   - 该选项**一旦出现**，odhcpd 会先把值清零再解析（src/config.c:1508-1513
#     `iface->ra_flags = 0; parse_ra_flags(&iface->ra_flags, c)`），
#     所以写了就必须写全，写漏的项**不会**回退到内置默认；
#   - 官方 15_odhcpd 写的是 `managed-config` + `other-config`（M=1, O=1）。
# 缺 M 标志时客户端不会通过 DHCPv6 索取地址（只走 SLAAC），dhcpv6='server'
# 就形同虚设。另外 LuCI 的「RA 标识」是多选框、占位符是 "none"：该字段为空
# （或残留 LuCI 删段时写入的字面量 'none'，odhcpd 解析失败并清零）时，
# 连 O 标志都会丢。
# ---------------------------------------------------------------------------
# LAN 的 DHCPv6 / RA 显式钉死为 server，并补上官方默认的 M+O 标志
# （dhcpv4 不需要，见上）。
uci_do set dhcp.lan.dhcpv6='server'
uci_do set dhcp.lan.ra='server'
uci_do set dhcp.lan.ra_flags='managed-config' 'other-config'

# 补齐官方 dnsmasq conffile 的 DNS 缓存大小。
# dnsmasq.init 只有 `append_parm "$cfg" cachesize "--cache-size"`（dnsmasq.init:1028，
# 无第三参数＝无默认），选项缺失时用 dnsmasq 内置的 150；
# 官方 /etc/config/dhcp（dnsmasq/files/dhcp.conf:13）写的是 1000。
# 只在缺失时补，不覆盖用户自己设过的值。
if [ -z "$(uci -q get dhcp.@dnsmasq[0].cachesize)" ]; then
    uci_do set dhcp.@dnsmasq[0].cachesize='1000'
    log 'set: dhcp.@dnsmasq[0].cachesize=1000 (restore official conffile value)'
fi

# ---------------------------------------------------------------------------
# 8. 中国大陆优化：时区与 NTP
# 官方默认 UTC + 4 个 openwrt.pool.ntp.org（国内解析慢、可达性一般）。
# 改为北京时间（POSIX TZ 记法 CST-8）与国内 NTP 服务器。
#
# 双写 timezone + zonename 是**必要**的，不是冗余：官方 manifest 里没有任何
# zoneinfo-* 包，/usr/share/zoneinfo/Asia/Shanghai 不存在，而
# package/base-files/files/etc/init.d/system 的判定是：
#   echo "$timezone" > /tmp/TZ
#   [ -n "$zonename" ] && [ -f "/usr/share/zoneinfo/${zonename// /_}" ] \
#       && ln -sf "/usr/share/zoneinfo/${zonename// /_}" /tmp/localtime \
#       && rm -f /tmp/TZ
# ⇒ zoneinfo 缺失时 zonename 分支不执行，真正生效的是 POSIX 串 timezone；
#   一旦将来装了 zoneinfo-*，zonename 就精确生效。
# LuCI 的时区下拉同样**同时写**这两项（luci-mod-system view/system/system.js）。
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
# ttyd / dropbear 保持包默认的监听限制，不在本脚本中清空 interface 限制。
# （ttyd 出厂配置是 `option interface '@lan'`；dropbear 的出厂配置**没有**
#  Interface 项，因此监听所有地址，WAN 侧靠防火墙 zone wan 的 input REJECT 挡住。）
# 不包含设备专属静态 DHCP 租约、NTP 域名重写、Docker 规则或第三方插件补丁。
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# 10. 附录：**非** LuCI「网络」菜单保存路径的迁移（冗余加固，可整节删除）
#
# 以下各项**不是** LuCI「网络」菜单点保存产生的结果，列在这里只为兜底。它们分别
# 属于「打开页面时的弹窗迁移」和「官方首启脚本」，正常刷机流程下要么用户点一次
# LuCI 就自动完成，要么官方脚本已经做过。所以本节是冗余的；
# 若认为官方脚本足够可靠，可以把 10.1 ~ 10.3 整节删掉，不影响其他章节。
#
# 关于「保留配置刷机时官方脚本会不会再跑一次」——会：
#   - rockchip 的 platform_do_upgrade() 是 `dd` 整镜像到分区，**rootfs 被整体替换**，
#     因此新镜像里的 /etc/uci-defaults/* 全部重新出现；
#   - 配置由 platform_copy_config() 存成根目录下的 sysupgrade.tgz，
#     在 preinit 阶段被 /lib/preinit/80_mount_root 的 do_mount_root() 解包
#     （`[ -f /sysupgrade.tgz ] && tar xzf /sysupgrade.tgz`），早于 /etc/init.d/boot；
#   - 随后 uci_apply_defaults() 把 /etc/uci-defaults/ 里的脚本全跑一遍。
# ---------------------------------------------------------------------------

# --- 10.1 网络接口：ifname -> device（LuCI 打开「接口」页的弹窗迁移，非保存） --
#
# 官方 11_network-migrate-bridges 只迁移 **type=bridge** 的段：
#   - `config device type=bridge` 的 ifname -> ports；
#   - `config interface type=bridge` -> 新建 config device name='br-<if>'，
#     接口改 device='br-<if>'，删 type/ifname。
# 而**普通（非 bridge）** `config interface` 上的 `ifname` 官方**不迁移**——
# netifd 至今保留显式向后兼容：
#   interface.c:53   IFACE_ATTR_IFNAME, /* Backward compatibility */
#   interface.c:1091 cur = tb[IFACE_ATTR_DEVICE];
#                    if (!cur) cur = tb[IFACE_ATTR_IFNAME];
# LuCI 会在**打开页面时**迁移它（luci-mod-network .../view/network/interfaces.js）：
#   interfaceWithIfnameSections() = uci.sections('network','interface')
#                                     .filter(ns => !ns.device && ns.ifname)
#   render()  里 `else if (... || this.interfaceWithIfnameSections().length)
#                  return this.renderIfnameMigration();`
#   handleIfnameMigration()       = uci.callSet('network', ns['.name'],
#                                     { 'ifname': '', 'device': ns.ifname })
# ⇒ 弹窗由 render() 触发（**页面打开**，不是保存），点「Continue」才执行上面的重命名。
#   所以这不属于第 4 节的范围；写在这里是为了让「保留配置升级 + 从不打开 LuCI 接口页」
#   的情况下配置也保持干净。本节按同样条件、同样结果实现。
#
# 与 LuCI 的一处差异：LuCI 走 ubus 的 uci set API，把 ifname 写成**空字符串**
# （rpcd uci.c 的 rpc_uci_merge_set / rpc_uci_format_blob 把空串当普通值下发，
# 并不等于删除），于是会留下一个 `option ifname ''`。这里改成真正 delete，
# 有效配置完全相同，但不会残留空选项。
#
# 注意：`option ifname 'eth0 eth1'` 这种多值写法在非 bridge 段上本来就不被 netifd
# 支持（IFACE_ATTR_IFNAME 是单个字符串），迁移时按原值照搬（与 LuCI 一致），
# 不额外猜测用户意图。
_migrated_ifname=0
for _iface in $(uci_section_names network interface); do
    [ -n "$(uci -q get "network.$_iface.device")" ] && continue
    _old_ifname=$(uci -q get "network.$_iface.ifname")
    [ -n "$_old_ifname" ] || continue
    [ "$(uci -q get "network.$_iface.type")" = 'bridge' ] && continue

    uci_do set "network.$_iface.device=$_old_ifname"
    uci_delete_optional "network.$_iface.ifname"
    _migrated_ifname=$((_migrated_ifname + 1))
    log "migrate: network.$_iface ifname='$_old_ifname' -> device"
done
unset _iface _old_ifname

# 说明：迁移只保证「不再出现 ifname 写法」，不会把 LAN 重新造成网桥。
# 保留配置升级时若旧配置是 `config interface lan` + `ifname 'eth1'`，结果是
# device='eth1'（与 LuCI 弹窗迁移后的结果一致），而全新安装是 device='br-lan'
# 加一个 `config device br-lan`。R2S 只有 eth1 一个 LAN 口，两种写法等价；
# 本脚本不主动改建桥，避免动到用户自建的桥与端口。

# --- 10.2 ubus 路径：rpcd socket / uhttpd ubus_socket + ubus_prefix ---------
#
# 来源：官方首启脚本（不是 LuCI，整个 luci 树里 `ubus.sock` 一次都没出现——
#       `grep -rn "ubus\.sock" luci/` 为空；luci-app-acl 只改 rpcd 段的 read/write）。
# 背景：ubusd 的监听路径是**编译期常量**，不受任何 uci 配置影响：
#   ubus/CMakeLists.txt:17  SET(UBUS_UNIX_SOCKET "/var/run/ubus/ubus.sock")
#   procd/state.c           service_start_early("ubus", "/sbin/ubusd", ...)  // 无 -s 参数
# 而下面两项是**客户端**侧的路径，写错就连不上 ubusd：
#   - rpcd.init   procd_set_param command /sbin/rpcd ${socket:+-s "$socket"}
#   - uhttpd.init append_arg "$cfg" ubus_socket "-U"
# 旧固件里它们是 /var/run/ubus.sock（没有兼容符号链接），保留配置升级后
# rpcd 与 uhttpd 的 ubus 通道会整体失效（LuCI 打不开、点不动）。
#
# 官方迁移脚本（排在本脚本之前执行）：
#   rpcd/files/50-migrate-rpcd-ubus-sock.sh
#   uhttpd/files/ubus.default -> 安装为 /etc/uci-defaults/00_uhttpd_ubus
# 这里按同一判据重复一次（见本节开头的理由）。
uci_migrate_value 'rpcd.@rpcd[0].socket' \
    '/var/run/ubus.sock' '/var/run/ubus/ubus.sock'
uci_migrate_value 'uhttpd.main.ubus_socket' \
    '/var/run/ubus.sock' '/var/run/ubus/ubus.sock'

# uhttpd 的 ubus 前缀必须非空，否则 uhttpd-mod-ubus 插件**根本不会加载**：
#   uhttpd/main.c:636  if (conf.ubus_prefix && uh_plugin_init("uhttpd_ubus.so"))
#   uhttpd/uhttpd.init:153-155  append_arg "$cfg" ubus_prefix "-u"（值为空则不加参数）
# 出厂 conffile 里 ubus_prefix 是**注释掉**的（uhttpd.config:69），
# 官方 00_uhttpd_ubus 会在首启补写 '/ubus'。缺了它 LuCI 的 /ubus RPC 端点不存在，
# 整个 Web 界面都会报错——所以这里一并补齐（属「补官方默认」，不是重命名）。
# 先确认 uhttpd.main 段存在：若构建时不含 LuCI/uhttpd，本脚本其余部分仍应跑完。
if ! uci -q get uhttpd.main >/dev/null 2>&1; then
    log 'skip: uhttpd.main not present'
elif [ -z "$(uci -q get uhttpd.main.ubus_prefix)" ]; then
    uci_do set uhttpd.main.ubus_prefix='/ubus'
    log 'set: uhttpd.main.ubus_prefix=/ubus (uhttpd-mod-ubus requires it)'
fi

# --- 10.3 dnsmasq：resolvfile 旧路径 -> 新路径 ------------------------------
#
# 来源：官方首启脚本 dnsmasq/files/50-dnsmasq-migrate-resolv-conf-auto.sh（不是 LuCI）。
# 上游把上游 DNS 结果文件从 /tmp/resolv.conf.auto 搬到了
# /tmp/resolv.conf.d/resolv.conf.auto（/etc/init.d/boot 里会
# `mkdir -p /tmp/resolv.conf.d` 并把它软链到 /tmp/resolv.conf）。
# 旧值留在配置里会导致 dnsmasq 读一个不存在的文件：
#   dnsmasq.init:1109  config_get resolvfile "$cfg" resolvfile /tmp/resolv.conf.d/resolv.conf.auto
#   dnsmasq.init:1110  [ -n "$resolvfile" ] && [ ! -e "$resolvfile" ] && touch "$resolvfile"
# 即 dnsmasq 会 touch 出一个空文件当上游，结果**设备自身 DNS 全挂**。
uci_migrate_value 'dhcp.@dnsmasq[0].resolvfile' \
    '/tmp/resolv.conf.auto' '/tmp/resolv.conf.d/resolv.conf.auto'

# --- 10.4（已移除）system.ntp.enabled --------------------------------------
#
# 原先这里会 `uci -q delete system.ntp.enabled`，理由是 LuCI 的「系统 -> 时间同步」
# 开关在开启时把该项 unset。现在删掉这段，因为它是等价项、而且会越权：
#   - sysntpd 的默认就是开启：package/utils/busybox/files/sysntpd 的校验串是
#     `'enabled:bool:1'`（缺省 1），config_generate 也写 `set system.ntp.enabled='1'`
#     ⇒ 该选项**存在且为 1**、或**缺失**，行为都是「NTP 开」，删除它没有任何效果；
#   - 唯一会产生差异的情形是旧配置里被显式设成 `enabled='0'`（用户有意关掉 NTP），
#     此时删掉它反而会把 NTP 重新打开——那是用户的明确选择，不该由本脚本翻转。
# 第 8 节只负责替换 NTP 服务器列表，不负责改「开/关」。

log '99-custom.sh completed; UCI changes left staged for the uci-defaults runner'
exit 0
