#!/bin/bash
# 构建期日志（注意：固件内的首启日志是 /etc/config/uci-defaults-log.txt，两者不是一回事）
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

echo "Create wan-settings"
mkdir -p "$BUILDER_DIR/files/etc/config"

# DNS 留空时回落到网关（光猫一般自带 DNS 转发）
WAN_DNS="${WAN_DNS:-$WAN_GATEWAY}"
# WAN 接入方式：默认 dhcp（与 OpenWrt 官方默认一致），可选 static
WAN_PROTO="${WAN_PROTO:-dhcp}"

# 创建 WAN 配置文件（yml 传入 WAN_PROTO / WAN_IP / WAN_GATEWAY / WAN_DNS）
# 该文件随固件发布，供 99-custom.sh 首次启动时读取
cat << EOF > "$BUILDER_DIR/files/etc/config/wan-settings"
wan_proto=${WAN_PROTO}
wan_ip=${WAN_IP}
wan_gateway=${WAN_GATEWAY}
wan_dns=${WAN_DNS}
EOF

echo "cat wan-settings"
cat "$BUILDER_DIR/files/etc/config/wan-settings"

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
PACKAGES=""
# ---- LuCI web 界面（关键！）----
# ⚠ 官方 OpenWrt 的 Image Builder 默认包（DEFAULT_PACKAGES）**不含 LuCI/uhttpd**
#   （ImmortalWrt 的 IB 默认带，官方不带——迁移差异，实机踩坑验证）。
#   只装 luci-i18n-*/luci-app-* 会把 luci-base 拉进来但没有 web 服务器，
#   设备上 /etc/init.d/uhttpd 都不存在，web UI 完全无法访问。
# `luci` 集合包（官方 luci feed）会带齐：uhttpd + luci-base +
#   luci-mod-admin-full + luci-theme-bootstrap + rpcd 组件。
# `luci-app-attendedsysupgrade`：官方 release 固件同样默认带上（见下方中文包一节，
#   它与 luci-i18n-attendedsysupgrade-zh-cn 一起列出）。
# ✔ 已核对官方 25.12.5 rockchip/armv8 manifest（openwrt-25.12.5-rockchip-armv8.manifest，
#   共 128 包）：官方固件 = IB 默认包 + `luci` + `luci-app-attendedsysupgrade`，
#   其余 luci-light/luci-ssl/uhttpd/rpcd-mod-* 均为这两个元包的自动依赖。
#   ⇒ 官方 Installed Packages 基线 = `luci`（下一行）+ `luci-app-attendedsysupgrade`
#     （见下方中文包一节），基线之外的行都是本项目的增量。
PACKAGES="$PACKAGES luci"
PACKAGES="$PACKAGES curl"
PACKAGES="$PACKAGES bind-tools"
PACKAGES="$PACKAGES ca-certificates"
PACKAGES="$PACKAGES openssh-sftp-server"
# ---- 中文语言包 ----
# 以下包来自 OpenWrt 官方源（luci feed），均有配套的 luci-i18n-*-zh-cn：
# LuCI 主界面简体中文（luci-i18n-base-zh-cn，官方 luci feed）
PACKAGES="$PACKAGES luci-i18n-base-zh-cn"
PACKAGES="$PACKAGES luci-i18n-package-manager-zh-cn"
PACKAGES="$PACKAGES luci-i18n-firewall-zh-cn"
# 官方基线第 2 包（见上方说明）+ 其简体中文语言包（官方 luci feed，已核实存在）
PACKAGES="$PACKAGES luci-app-attendedsysupgrade"
PACKAGES="$PACKAGES luci-i18n-attendedsysupgrade-zh-cn"

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
# ======== shell/custom-packages.sh =======
# 合并 OpenWrt 官方源以外的第三方插件
PACKAGES="$PACKAGES $CUSTOM_PACKAGES"

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
