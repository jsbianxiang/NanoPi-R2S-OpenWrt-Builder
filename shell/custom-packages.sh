#!/bin/bash
# =============================================================================
# custom-packages.sh —— 可选软件包开关
# -----------------------------------------------------------------------------
# 由 rockchip/build.sh 以 `source` 方式加载；本文件只做 $CUSTOM_PACKAGES 字符串
# 拼接，最终由 build.sh 传给 `make image PACKAGES="..."`。
#
# 用法：
#   1. 第三方插件（Clashoo）已默认启用，见「一」，一般无需改动。
#   2. OpenWrt 官方源软件：把短名填进「二」2.1 的 ENABLE_APPS（空格分隔）即可，
#      脚本会自动展开为 luci-app-<短名> + luci-i18n-<短名>-zh-cn（后者依赖前者，
#      两者会一起装上）。可用短名见「三」A 组（共 82 个，已逐一校验）。
#      例：ENABLE_APPS="filemanager sqm ttyd"
#   3. 仅第三方源（dllkids）提供的应用：把短名填进 2.2 的 THIRD_PARTY_APPS，
#      脚本只展开 luci-app-<短名>、**不加** i18n 包（该源没有语言包）。
#      可用短名见「三」B 组（共 46 个，已逐一校验）。
#   4. 少数包不是 luci-app-<短名> 形式（luci-proto-* / luci-mod-* / openclash /
#      passwall 等），在「二」2.3 里取消对应行注释即可。
#
# 注意事项：
#   1. 【第三方插件】必须先注入其对应的第三方源，否则 make image 会因找不到包
#      而失败。本分支已注入 dllkids（kenzok8）的 APK 源（默认只启用 Clashoo）；
#      自行加源方法见 README「如何自行增加第三方源」。
#      ⚠ OpenWrt 官方源**没有**代理类插件，也没有 ImmortalWrt 系应用
#      （argon / diskman / cpufreq 等），这些包全部依赖注入的第三方源。
#   2. 【代理类插件互斥】clashoo / nikki / openclash / passwall / ssr-plus
#      的配置互相冲突，只能启用其中一个。
#   3. 本分支不集成 store / istore，故不提供依赖 istore 的插件选项。
#   4. 硬路由 / 小闪存设备请酌情启用；包过多会导致固件过大或构建失败。
#   5. 「三」的短名已对 OpenWrt 25.12.5 官方源（aarch64_generic，
#      base/luci/packages/routing/telephony 共 9839 个包名）与 dllkids 第三方源
#      逐一校验。两处都不存在的 oled / 3cat / 3ginfo-lite / appfilter 已剔除，
#      避免「取消注释即构建失败」。
#   6. 【已内置中文的 app 包】argon-config / cpufreq / diskman 这三个 app 包
#      （版本 27.150.x，仅第三方源提供）**自带简体中文**，启用它们时**不能**再配
#      独立的 luci-i18n-<短名>-zh-cn，否则 apk 会因文件冲突报
#      "trying to overwrite ... owned by ..." 导致 make image 失败。
#      B 组短名展开本就不加 i18n 包，无需手工处理。
# =============================================================================

# =============================================================================
# 一、第三方插件（dllkids 源）
# -----------------------------------------------------------------------------
# rockchip/build.sh 注入的第三方源（25.12 / aarch64_generic）除 Clashoo 外，
# 还提供 luci-app-ssr-plus / passwall2 / nikki / openclash / mihomo 等，
# 需要时取消 1.2 的注释即可，无需另外加源。
#
# ⚠ 该源的第三方 LuCI 应用**没有**独立中文语言包（中文界面为包内原生），
#   所以不要给它们加 luci-i18n-xxx-zh-cn，否则 make image 会因找不到包而失败。
# =============================================================================
# 【当前已启用】Clashoo —— ⚠ 与 nikki 配置冲突，不可同时启用
CUSTOM_PACKAGES="$CUSTOM_PACKAGES clashoo luci-app-clashoo luci-i18n-clashoo-zh-cn"

# -----------------------------------------------------------------------------
# 1.2 其他第三方插件（可选；⚠ 代理类互斥，只能选一个）
# -----------------------------------------------------------------------------
# 下面每行的包都已逐一校验存在于 dllkids 第三方源，取消注释即启用。
# 第三方应用是中文原生，没有独立语言包，故都不带 luci-i18n-*-zh-cn。
#
# SSR-Plus —— mihomo 内核由 rockchip/build.sh 自动补进 PACKAGES，这里不用写
#CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-ssr-plus xray-core naiveproxy kmod-nft-tproxy kmod-nft-socket"
# PassWall2
#CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-passwall2 geoview xray-core sing-box hysteria kmod-nft-tproxy kmod-nft-socket"
# nikki（核心包名就叫 nikki）—— ⚠ 与 Clashoo 配置冲突，不可同时启用
#CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-nikki nikki kmod-tun kmod-inet-diag kmod-nft-tproxy kmod-nft-socket"
#
# OpenClash 不列在这里，它在「二」2.3（内核由 rockchip/build.sh 处理）。

# =============================================================================
# 二、可选软件包开关
# =============================================================================
# 2.1 OpenWrt 官方源短名开关：填进 ENABLE_APPS 即启用（空格分隔；留空 = 不装）
# -----------------------------------------------------------------------------
# 自动展开为 luci-app-<短名> + luci-i18n-<短名>-zh-cn。
# 可用短名见「三」A 组（官方源 82 个）。
ENABLE_APPS=""
# 示例：ENABLE_APPS="filemanager sqm ttyd"

# -----------------------------------------------------------------------------
# 2.2 仅第三方源（dllkids）短名开关：填进 THIRD_PARTY_APPS 即启用
# -----------------------------------------------------------------------------
# 自动展开为 luci-app-<短名>（⚠ 不加 i18n 包，该源没有语言包）。
# 可用短名见「三」B 组（第三方源 46 个）。
# 注意：argon-config / cpufreq / diskman 的 app 包**自带简体中文**，
#       千万不要再手工追加 luci-i18n-<短名>-zh-cn（详见文件头注意事项 6）。
THIRD_PARTY_APPS=""
# 示例：THIRD_PARTY_APPS="zerotier rclone netdata"

for _app in $ENABLE_APPS; do
    CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-$_app luci-i18n-$_app-zh-cn"
done
for _app in $THIRD_PARTY_APPS; do
    CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-$_app"
done
unset _app

# -----------------------------------------------------------------------------
# 2.3 需写全名的包（不是 luci-app-<短名> 形式，或需额外依赖）
# -----------------------------------------------------------------------------
# 网络协议
#CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-proto-wireguard"
#CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-proto-minieap luci-i18n-minieap-zh-cn"
# 面板（luci-mod-*）
#CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-mod-battstatus luci-i18n-battstatus-zh-cn"
#CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-mod-dashboard luci-i18n-dashboard-zh-cn"
#CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-mod-dsl luci-i18n-dsl-zh-cn"
# 代理（⚠ 与 Clashoo 互斥，只能选一个；包本体来自 dllkids 第三方源）
#CUSTOM_PACKAGES="$CUSTOM_PACKAGES geoview xray-core sing-box hysteria luci-i18n-passwall-zh-cn"
#CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-openclash luci-compat kmod-tun kmod-inet-diag kmod-nft-tproxy bash curl ip-full unzip"

# =============================================================================
# 三、可用短名清单（已对 OpenWrt 25.12.5 官方源与 dllkids 第三方源逐一校验）
# =============================================================================

# -----------------------------------------------------------------------------
# A 组：OpenWrt 官方源（填进 2.1 的 ENABLE_APPS，自动带简体中文语言包）
# -----------------------------------------------------------------------------
# --- 代理 / VPN / DNS 分流 ---
#   openvpn                   v2raya                    tinyproxy                 privoxy                   tor
#   ocserv                    smartdns                  nextdns                   unbound                   https-dns-proxy
#   adblock                   adblock-fast              pbr
#
# --- 内网穿透 / DDNS / 远程访问 ---
#   frpc                      frps                      ddns                      xfrpc                     natmap
#   tailscale-community       cloudflared               sshtunnel                 rustdesk-server           eoip
#
# --- 文件 / 存储 / 下载 ---
#   filemanager               filebrowser               openlist                  samba4                    ksmbd
#   minidlna                  aria2                     transmission              ser2net                   hd-idle
#
# --- 媒体 / IPTV ---
#   udpxy                     dump1090
#
# --- 网络管理 / 监控 / 无线 ---
#   mwan3                     sqm                       qos                       nlbwmon                   vnstat2
#   statistics                usteer                    dawn                      watchcat                  lldpd
#   bmx7                      olsr                      olsr-services             olsr-viz                  wifischedule
#   banip                     bcp38                     irqbalance                dcwapd                    advanced-reboot
#   attendedsysupgrade
#
# --- 网络唤醒 / 服务发现 ---
#   wol                       upnp
#
# --- 认证 / 校园网 / 拨号 ---
#   rp-pppoe-server           coovachilli               openwisp                  omcproxy
#
# --- 系统工具 / 服务 ---
#   ttyd                      commands                  uhttpd                    lxc                       email
#   nut                       p910nd                    clamav                    crowdsec-firewall-bouncer fwknopd
#   keepalived                snmpd                     mosquitto                 pagekitec                 acl
#   acme                      example                   xinetd                    travelmate                squid
#
# -----------------------------------------------------------------------------
# B 组：仅第三方源 dllkids 提供（填进 2.2 的 THIRD_PARTY_APPS，不带 i18n 包）
# -----------------------------------------------------------------------------
# --- 代理 / VPN / DNS 分流 ---
#   homeproxy                 passwall                  dae                       microsocks                softethervpn
#   ipsec-vpnd                gost
#
# --- 内网穿透 / DDNS / 远程访问 ---
#   zerotier                  ddns-go                   ngrokc                    nps                       n2n
#   wechatpush
#
# --- 文件 / 存储 / 下载 ---
#   filebrowser-go            nfs                       cifs-mount                qbittorrent               amule
#   syncthing                 rclone                    vsftpd                    usb-printer               ps3netsrv
#   diskman ★包内自带简体中文（勿再手工加 i18n 包）
#
# --- 媒体 / IPTV ---
#   msd_lite                  spotifyd                  airplay2                  music-remote-center       oscam
#
# --- 网络管理 / 监控 ---
#   netdata                   arpbind                   eqos                      cpulimit                  ramfree
#   autoreboot                timewol
#
# --- 认证 / 校园网 / 拨号 ---
#   cd8021x                   sysuh3c                   ua2f                      bitsrunlogin-go           pppoe-relay
#   pppoe-server
#
# --- 系统工具 / 服务 ---
#   sms-tool-js               modemband                 vlmcsd                    xlnetacc
#
# -----------------------------------------------------------------------------
# 已移除（官方源与 dllkids 第三方源均不存在对应 luci-app，启用即构建失败）：
#   oled / 3cat / 3ginfo-lite / appfilter
# -----------------------------------------------------------------------------
