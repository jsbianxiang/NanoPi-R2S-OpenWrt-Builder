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

# ---- 中国大陆优化：BBR 拥塞控制 sysctl ----
# 官方 /etc/init.d/sysctl 依次加载 /etc/sysctl.d/*.conf 与 /etc/sysctl.conf；
# 该目录虽不参与 sysupgrade 备份，但本文件由固件自带，升级后依然存在。
# 内核 4.13+ 在无 fq 队列时 BBR 使用 TCP 内部 pacing 兜底，可直接启用；
# 如需最优配对，可自行安装 kmod-sched（含 sch_fq）后取消第二行注释。
mkdir -p "$BUILDER_DIR/files/etc/sysctl.d"
cat << 'EOF' > "$BUILDER_DIR/files/etc/sysctl.d/99-bbr.conf"
# BBR TCP congestion control (kmod-tcp-bbr is built into this firmware)
# net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
echo "---- files/etc/sysctl.d/99-bbr.conf ----"
cat "$BUILDER_DIR/files/etc/sysctl.d/99-bbr.conf"

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
# ⚠ 第三方源（dllkids）里的 app 包是中文原生的，**没有**独立语言包：
#   - luci-app-diskman / luci-app-cpufreq / luci-app-argon-config（27.150.x）
#     包内**自带简体中文**，若再显式安装同名的独立 i18n 包，apk 会因文件冲突报
#     ERROR: luci-i18n-xxx-zh-cn-...: trying to overwrite ... owned by luci-app-xxx-...
#     直接中断 make image（package_install 返回 Error 3）。故这三个只装 app 包。
#   - luci-theme-argon（27.246.x）为纯主题，无 i18n 包。
#   - luci-app-nikki 等其余第三方应用同理，不要加 luci-i18n-<名>-zh-cn。
# ✓ 下列 4 个包在官方 OpenWrt 源中不存在、但 dllkids 源里确有 apk
#   （已逐一核实：luci-theme-argon-27.246.x、luci-app-argon-config /
#   luci-app-cpufreq / luci-app-diskman-27.150.x）——
#   前提是 build.sh 注入了 dllkids 源（见下方注入逻辑）；
#   若将来移除该源注入，必须同步删除这 4 行，否则 make image 找不到包。
PACKAGES="$PACKAGES luci-app-diskman"
PACKAGES="$PACKAGES luci-app-cpufreq"
PACKAGES="$PACKAGES luci-theme-argon"
PACKAGES="$PACKAGES luci-app-argon-config"
PACKAGES="$PACKAGES luci-i18n-ttyd-zh-cn"
# 文件管理器（OpenWrt 官方源，含独立 i18n 包）
PACKAGES="$PACKAGES luci-i18n-filemanager-zh-cn"
# ---- 中国大陆优化：BBR TCP 拥塞控制 ----
# kmod-tcp-bbr 来自官方 kmods feed（25.12.5 rockchip/armv8 已核实存在），
# 模块自带 AutoProbe（/etc/modules.d/ 开机自动加载）；
# sysctl 开关由下方写入 files/etc/sysctl.d/99-bbr.conf。
PACKAGES="$PACKAGES kmod-tcp-bbr"
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
#   - r2s-seed.config 启用了 CONFIG_SIGNATURE_CHECK=y，
#     因此 apk 会校验源签名 —— 必须提供公钥，
#     否则安装时安装会报 "UNTRUSTED signature"。
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
    cp -f repositories files/etc/apk/repositories.d/distfeeds.list.official.bak
    sed 's#https://downloads.openwrt.org/releases/#https://mirrors.ustc.edu.cn/openwrt/releases/#g' \
        repositories > files/etc/apk/repositories.d/distfeeds.list
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

make image PROFILE=$PROFILE PACKAGES="$PACKAGES" FILES="$BUILDER_DIR/files" ROOTFS_PARTSIZE=$ROOTFS_PARTSIZE

if [ $? -ne 0 ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Error: Build failed!"
    exit 1
fi

echo "$(date '+%Y-%m-%d %H:%M:%S') - Build completed successfully."
