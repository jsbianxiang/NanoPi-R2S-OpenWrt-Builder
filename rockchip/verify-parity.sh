#!/bin/bash
# ===========================================================================
# 验证「官方基线」是否与官方镜像逐包对齐 —— 容器内脚本
#
# 在 openwrt/imagebuilder 容器内运行（工作目录 /builder），由
# .github/workflows/verify-official-parity.yml 调用。
#
# 做法：只装 rockchip/build.sh 里的 OFFICIAL_BASELINE（默认 4 个包），
#   让 Image Builder 自动补上 DEFAULT_PACKAGES / 设备包 / kernel / 依赖闭包，
#   再导出 manifest 交给宿主机与官方 manifest 逐包比对。
#
# ⚠ 不注入任何第三方源 —— 官方基线全部来自 OpenWrt 官方源。
# ⚠ 用 `make manifest` 而不是 `make image`：两者共用同一套 BUILD_PACKAGES
#   组装逻辑（target/imagebuilder/files/Makefile:143/146），但前者不打镜像，
#   只列出会被装进去的包，因此快得多，适合做核对。
#
# 环境变量：
#   PROFILE   机型 profile（默认 friendlyarm_nanopi-r2s）
#   BASELINE  官方基线包列表（workflow 从 build.sh 提取后传入）
#   OUT       输出路径（默认 /builder/out/ours.manifest）
# ===========================================================================
set -euo pipefail

PROFILE="${PROFILE:-friendlyarm_nanopi-r2s}"
BASELINE="${BASELINE:-luci luci-ssl luci-app-attendedsysupgrade owut}"
OUT="${OUT:-/builder/out/ours.manifest}"

cd /builder
mkdir -p "$(dirname "$OUT")"

echo "PROFILE  = $PROFILE"
echo "BASELINE = $BASELINE"
echo

# 与官方 .manifest 同格式："<name> - <version>"
#   —— 官方 manifest 由 scripts/make-index-json.py --manifest 生成，该分支就是
#      `print(name, "-", version)`（scripts/make-index-json.py:96-98），格式完全一致。
#   两点已核实（避免踩坑）：
#   1) 不要加 STRIP_ABI=1：imagebuilder/files/Makefile:197 的
#      `--fields name,version,$(if $(STRIP_ABI),tags)` 只有在传了 STRIP_ABI 时才会
#      请求 tags 字段，make-index-json.py 才会剥掉 ABI 后缀。官方 manifest 是**保留**
#      后缀的（libmbedtls21 / libucode20230711），所以我们也必须保留，否则包名对不上。
#      （Makefile:63 那行 `make manifest STRIP_ABI=1` 只是 help 文本，不是默认值。）
#   2) STRIP_ABI 为空时该参数会变成 `name,version,`（尾逗号），看似会让 apk 报错；
#      实际不会 —— apk-tools 的 apk_blob_tokenize() 用 `while (iter->len == 0)` 跳过
#      空 token（apk-tools blob.c:210-220），尾逗号被安全忽略。
#
# 只取 stdout（不加 2>&1）：_call_manifest 里 package_reload/package_install 都已
#   `>/dev/null`，所以 stdout 里只有 manifest，stderr 里的报错不会混进来被 sed 误收。
#   若 make 失败，set -o pipefail 会让整条管道失败，脚本直接退出。
make manifest PROFILE="$PROFILE" PACKAGES="$BASELINE" | tee /tmp/manifest.raw

# 只保留包名并排序去重。
# 注意：容器是 Alpine（busybox sort），排序规则与宿主机的 GNU sort 可能不同，
#       所以这里只做去重，最终由宿主机重新 sort 后再比对。
sed -n 's/^\([^ ][^ ]*\) - .*/\1/p' /tmp/manifest.raw | sort -u > "$OUT"

COUNT=$(wc -l < "$OUT")
echo
echo "==== 共 $COUNT 个包，已写入 $OUT ===="
sed -n '1,5p' "$OUT"

# 兜底：产出为空说明 make manifest 没跑成，直接失败而不是让比对给出假结论
if [ "$COUNT" -eq 0 ]; then
    echo "ERROR: manifest 为空，make manifest 可能失败" >&2
    exit 1
fi
