# 软件包说明（NanoPi R2S 专用项目）

本项目**不克隆**任何第三方插件源码仓库（`run/` 方式），只以 APK 源的形式注入第三方源。
可安装的软件来自以下两类来源。

## 一、OpenWrt 官方源

所有 OpenWrt 官方软件包与**全部 kmod** 均可直接安装。
由于使用官方 Image Builder + 官方内核，官方 kmods 源的内核模块与固件内核版本天然匹配，
不会出现「kmod 装不上」的问题。

- 查询官方软件包：<https://downloads.openwrt.org/releases/>
  （选对应版本 → `packages/aarch64_generic/`，各 feed 下有 `index.json` 可检索）
- kmods 源由 Image Builder 自动纳入 `repositories`，无需手工配置

> ⚠️ **OpenWrt 官方源没有**：代理类插件（openclash / passwall / ssr-plus /
> nikki / clashoo / mihomo 等），以及 ImmortalWrt 系应用
> （`luci-theme-argon` / `luci-app-argon-config` / `luci-app-diskman` /
> `luci-app-cpufreq` 等）。这些包全部来自下方注入的第三方源。

## 二、第三方源：dllkids（kenzok8）

本项目只注入了一个第三方源 —— **dllkids**（作者 kenzok8），由 `rockchip/build.sh` 注入。

| 软件包 | 简介 | 来源 |
| --- | --- | --- |
| `clashoo` | 双内核代理（mihomo + sing-box） | [kenzok8](https://github.com/kenzok8) |
| `luci-app-clashoo` | Clashoo LuCI 前端 | [kenzok8](https://github.com/kenzok8) |
| `luci-i18n-clashoo-zh-cn` | Clashoo 简体中文语言包 | [kenzok8](https://github.com/kenzok8) |

- APK 源：`https://down.dllkids.xyz/openwrt-feed/25.12/aarch64_generic/packages.adb`
- 签名公钥：`https://down.dllkids.xyz/openwrt-feed/keys/dllkids-feed.pub.pem`

> 该源是完整的第三方源，除 Clashoo 外还提供 `mihomo`、`luci-app-ssr-plus`、
> `luci-app-passwall` / `passwall2`、`luci-app-nikki`、`sing-box`、`geoview`、
> 以及 ImmortalWrt 系应用（`luci-theme-argon` / `luci-app-argon-config` /
> `luci-app-diskman` / `luci-app-cpufreq` 等）。
> 本项目默认只启用 Clashoo；`rockchip/build.sh` 在检测到 `luci-app-ssr-plus` 时会
> 顺带加入该源的 `mihomo` 包作为内核（不再手动下载固定版本二进制）。
>
> ⚠️ 该源的第三方 LuCI 应用**没有**独立中文语言包（中文界面为包内原生），
> 启用它们时**不要**加 `luci-i18n-xxx-zh-cn`，否则 `make image` 会因找不到包而失败。
>
> ⚠️ Clashoo 与 **nikki** 配置冲突，不要同时集成。
> ⚠️ Clashoo 依赖的 kmod（`kmod-tun`、`kmod-nft-tproxy`、`kmod-nft-socket`、
> `kmod-inet-diag` 等）由 OpenWrt 官方 kmods 源解析，不由第三方源提供。

> ℹ️ **设备端也可以直接安装/升级第三方系包。**
> `rockchip/build.sh` 把该源与公钥写在两处：
> - **构建期**：源追加到 Image Builder 的 `repositories`、公钥放进 `keys/`
>   （apk 读取）。这两处**不会**进固件。
> - **随固件发布**：同时写进 `files/`，落到固件内的
>   `/etc/apk/repositories.d/customfeeds.list` 与 `/etc/apk/keys/dllkids-feed.pub.pem`。
>   （`customfeeds.list` 是 `apk` 包为「用户自加第三方源」预留的 conffile，
>   上游默认就是三行注释占位；本项目保留其原样并在末尾追加 dllkids 源。）
>
> 因此设备上可以直接 `apk update` / `apk add <包名>` / `apk upgrade`。
> 注意固件启用了 `CONFIG_SIGNATURE_CHECK`，公钥缺失会被判为 `UNTRUSTED signature`。

## 三、如何启用/新增软件

1. **官方源中的软件**：直接在 `rockchip/build.sh` 的 `PACKAGES` 变量里追加包名。
2. **可选软件包**：在 `shell/custom-packages.sh` 里按来源分两组填写：
   - OpenWrt 官方源：把短名填进 `ENABLE_APPS`
     （如 `ENABLE_APPS="filemanager sqm ttyd"`），脚本会自动展开为
     `luci-app-<短名>` + `luci-i18n-<短名>-zh-cn`；「三」A 组列出全部 82 个可用短名。
   - 仅第三方源（dllkids）：把短名填进 `THIRD_PARTY_APPS`，只展开 `luci-app-<短名>`
     （该源没有语言包，不加 i18n）；「三」B 组列出全部 46 个可用短名。
   少数非 `luci-app-*` 形式的包（`luci-proto-*` / `luci-mod-*` / openclash /
   passwall 等）取消 2.3 对应行注释即可。
   > ⚠️ **例外：已内置中文的 app 包。** `argon-config` / `cpufreq` / `diskman`
   > 这三个 app 包（仅第三方源提供，版本 `27.150.x`）**自带简体中文**
   > （内含 `usr/lib/lua/luci/i18n/*.zh-cn.lmo` 与 `etc/uci-defaults/luci-i18n-*`）。
   > 若再装同名的独立语言包 `luci-i18n-<短名>-zh-cn`，apk 会因
   > 文件冲突报 `ERROR: ... trying to overwrite ... owned by luci-app-...`，
   > 使 `make image` 以 `package_install Error 3` 失败。
   > B 组短名展开本就不加 i18n 包，无需手工处理。
3. **新增第三方源**：
   把源的 `packages.adb` 全路径追加到 `repositories`，公钥放入 `keys/`（构建期可用）；
   若还要让**设备端**能安装，再按 `rockchip/build.sh` 里 dllkids 源的写法，把源写进
   `files/etc/apk/repositories.d/customfeeds.list`（apk 包预留的第三方源 conffile），
   公钥写进 `files/etc/apk/keys/`。
