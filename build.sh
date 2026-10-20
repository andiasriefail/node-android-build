#!/bin/bash
# ============================================================
# 编译 Node.js (Android, 自包含二进制)
#
# 方法参考:
#   - termux-packages/packages/nodejs (活跃维护, 当前 node 大版本)
#   - node 官方 android_configure.py (NDK 环境/GYP_DEFINES 设置)
# 产出可在普通 Android (无需 termux) 上直接运行的 node
#
# 用法:
#   ./build.sh                        # 最新 LTS, arm64
#   NODE_VERSION=24 ./build.sh        # 指定主版本线的最新版
#   NODE_VERSION=24.19.0 ./build.sh   # 指定完整版本
#   TARGET_ARCH=arm ./build.sh        # 指定架构 (arm64|arm|x64|ia32)
#
# 环境变量:
#   NODE_VERSION          lts(默认, 自动检测最新 LTS) / 主版本(如 24) / 完整版本(如 24.19.0)
#   TARGET_ARCH           目标架构: arm64|arm|x64|ia32 (默认 arm64)
#   ANDROID_SDK_VERSION   Android API 级别 (默认 24)
#   ANDROID_NDK_HOME      NDK 路径 (未设置时自动查找 Actions 预装 / 常见路径)
#   OUT_DIR               输出目录 (默认 ./out)
#   NODE_BUILD_BACKEND    ninja|make (默认 ninja)
#   NODE_STRIP            1=用 llvm-strip 精简 node 二进制 (默认 1: 应用内置, 体积优先)
#   NODE_WITH_NPM         1=内置 npm (默认 1; 0=--without-npm)
#   NODE_PKG_SUFFIX       asset 名后缀 (默认 -full: 含 npm + 精简 + smoke-test.js; 改配置时递增以避开 "已发布则跳过")
#   NODE_VERIFY           1=构建后用 llvm-readelf 校验架构/依赖库/页对齐 (默认 1)
# ============================================================
set -euo pipefail

REPO_DIR=$(cd "$(dirname "$0")" && pwd)
PATCHES="$REPO_DIR/patches"
OUT_DIR="${OUT_DIR:-$(pwd)/out}"
TARGET_ARCH="${TARGET_ARCH:-arm64}"
ANDROID_SDK_VERSION="${ANDROID_SDK_VERSION:-24}"
BACKEND="${NODE_BUILD_BACKEND:-ninja}"
STRIP="${NODE_STRIP:-1}"
WITH_NPM="${NODE_WITH_NPM:-1}"
PKG_SUFFIX="${NODE_PKG_SUFFIX--full}"
VERIFY="${NODE_VERIFY:-1}"

info() { echo "[*] $1"; }
warn() { echo "[!] $1"; }
die()  { echo "[Error] $1"; exit 1; }

# ---------- 解析版本 ----------
resolve_version() {
  local v="${NODE_VERSION:-24}"
  case "$v" in
    ""|lts|latest)
      curl -fsSL --max-time 30 "https://nodejs.org/dist/index.json" | python3 -c '
import json, sys
d = json.load(sys.stdin)
lts = [x for x in d if x.get("lts")]
print(lts[0]["version"].lstrip("v") if lts else d[0]["version"].lstrip("v"))'
      ;;
    *.*)
      echo "$v" | sed 's/^v//'
      ;;
    *)
      curl -fsSL --max-time 30 "https://nodejs.org/dist/index.json" | python3 -c "
import json, sys
d = json.load(sys.stdin)
m = [x for x in d if x['version'].startswith('v$v.')]
print(m[0]['version'].lstrip('v') if m else '')" | grep -q . || die "未找到 node $v 版本线"
      curl -fsSL --max-time 30 "https://nodejs.org/dist/index.json" | python3 -c "
import json, sys
d = json.load(sys.stdin)
m = [x for x in d if x['version'].startswith('v$v.')]
print(m[0]['version'].lstrip('v'))"
      ;;
  esac
}

VER=$(resolve_version)
info "Node 版本: $VER"

# ---------- 按大版本选补丁集 ----------
# patches/<大版本>/{termux,stubs}: 每个 node 大版本一套独立补丁 (24/26 已验证)
MAJOR="${VER%%.*}"
PATCH_DIR="$PATCHES/$MAJOR"
if [ ! -d "$PATCH_DIR" ]; then
  PATCH_DIR=$(ls -d "$PATCHES"/[0-9]* 2>/dev/null | sort -V | tail -n 1)
  [ -n "$PATCH_DIR" ] && [ -d "$PATCH_DIR" ] \
    || die "未找到任何补丁目录: 需要 $PATCHES/$MAJOR 或任意 patches/<大版本>"
  warn "node $MAJOR 没有专属补丁集, 回退使用 $(basename "$PATCH_DIR") 版 (可能部分失效, 见下方警告)"
fi
info "补丁集: $(basename "$PATCH_DIR") (node ${MAJOR}.x)"

# ---------- 架构 ----------
case "$TARGET_ARCH" in
  arm64|aarch64) DEST_CPU="arm64"; TOOLCHAIN_PREFIX="aarch64-linux-android";    HOST_M32="" ;;
  arm|armv7)     DEST_CPU="arm";   TOOLCHAIN_PREFIX="armv7a-linux-androideabi"; HOST_M32=" -m32" ;;
  x64|x86_64)    DEST_CPU="x64";   TOOLCHAIN_PREFIX="x86_64-linux-android";     HOST_M32="" ;;
  ia32|x86)      DEST_CPU="ia32";  TOOLCHAIN_PREFIX="i686-linux-android";       HOST_M32=" -m32" ;;
  *) die "不支持的架构: $TARGET_ARCH (arm64|arm|x64|ia32)" ;;
esac
info "目标架构: $DEST_CPU"

# 记录版本 (供 CI 生成 release tag; 跳过检查前写入)
mkdir -p "$OUT_DIR"
echo "$VER" > "$OUT_DIR/version.txt"

# ---------- CI: 该版本已发布过则跳过 ----------
# release 按大版本归档: node-android-<arch>-<major> (如 node-android-arm64-24),
# 每个版本一个 asset (node-android-<arch>-<version>.tar.xz), 历史全部保留
skip_if_released() {
  if [ -n "${GITHUB_REPOSITORY:-}" ]; then
    local major="${VER%%.*}"
    local tag="node-android-${DEST_CPU}-${major}"
    local asset="node-android-${DEST_CPU}-${VER}${PKG_SUFFIX}.tar.xz"
    if curl -fsSL --max-time 20 "https://api.github.com/repos/${GITHUB_REPOSITORY}/releases/tags/${tag}" 2>/dev/null \
      | grep -q "\"name\": \"${asset}\""; then
      info "$asset 已存在于 release $tag, 跳过构建"
      exit 0
    fi
  fi
}
skip_if_released

# ---------- NDK ----------
find_ndk() {
  [ -n "${ANDROID_NDK_HOME:-}" ] && [ -d "$ANDROID_NDK_HOME" ] && { echo "$ANDROID_NDK_HOME"; return; }
  [ -n "${ANDROID_NDK_ROOT:-}" ] && [ -d "$ANDROID_NDK_ROOT" ] && { echo "$ANDROID_NDK_ROOT"; return; }
  [ -d /usr/local/lib/android/sdk/ndk ] && ls -d /usr/local/lib/android/sdk/ndk/* 2>/dev/null | sort -V | tail -n 1 && return
  [ -d "$HOME/Android/Sdk/ndk" ] && ls -d "$HOME/Android/Sdk/ndk"/* 2>/dev/null | sort -V | tail -n 1 && return
  echo ""
}
NDK=$(find_ndk)
[ -n "$NDK" ] || die "未找到 Android NDK, 请设置 ANDROID_NDK_HOME"
TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/linux-x86_64"
[ -d "$TOOLCHAIN" ] || die "NDK 缺少 llvm 工具链: $TOOLCHAIN"
info "NDK: $NDK"

# ---------- 下载源码 ----------
mkdir -p "$OUT_DIR"
SRC_DIR="$OUT_DIR/node-v${VER}"
if [ ! -d "$SRC_DIR" ]; then
  info "下载 node 源码 (v${VER}) ..."
  curl -fL --connect-timeout 10 --max-time 600 --retry 3 "https://nodejs.org/dist/v${VER}/node-v${VER}.tar.xz" \
    -o "$OUT_DIR/node-v${VER}.tar.xz"
  tar -xf "$OUT_DIR/node-v${VER}.tar.xz" -C "$OUT_DIR"
fi
cd "$SRC_DIR"

# ---------- 打补丁 ----------
info "应用补丁 ..."
# termux-packages (nodejs-lts 24.x / nodejs 26.x) 移植的 Android 修复
# (除 termux 专用项: @TERMUX_PREFIX@ 路径 / __TERMUX__ 守卫 / 测试用例)
# 24/26 两套补丁均实测可应用; 新版本个别失效时告警并靠下方 sed 兜底
for f in "$PATCH_DIR"/termux/*.patch; do
  if patch -f -p1 -t --dry-run < "$f" >/dev/null 2>&1; then
    # 未应用 -> 正式应用
    if patch -f -p1 -t --no-backup-if-mismatch < "$f" >/dev/null 2>&1; then
      info "  应用 $(basename "$f")"
    else
      warn "$(basename "$f") 应用失败"
    fi
  elif patch -f -p1 -t -R --dry-run < "$f" >/dev/null 2>&1; then
    # 反向测试成功 = 已应用过 (源码来自缓存), 跳过
    info "  已应用, 跳过 $(basename "$f")"
  else
    warn "$(basename "$f") 未生效 (新版本可能已修复/不再需要)"
  fi
done

# v8 trap-handler: Android 不支持 (termux patch 钉死 24.x 版本)
# sed 兜底: 无论 patch 是否生效, 强制全部禁用 (幂等, 仅影响 WASM 性能)
sed -i \
  -e 's/#define V8_TRAP_HANDLER_SUPPORTED true/#define V8_TRAP_HANDLER_SUPPORTED false/g' \
  -e 's|#define V8_TRAP_HANDLER_VIA_SIMULATOR|// #define V8_TRAP_HANDLER_VIA_SIMULATOR|' \
  deps/v8/src/trap-handler/trap-handler.h

# node.gyp: Android 需要 -latomic (termux 26.x 同款; 24.x 无副作用)
python3 -c "
s = open('node.gyp').read()
s = s.replace('OS==\"linux\" and clang==1', '(OS==\"linux\" or OS==\"android\") and clang==1')
open('node.gyp', 'w').write(s)
"
# node.gyp: 移除 arm64 分支保护参数 (旧 NDK clang 不支持)
sed -i '/-mbranch-protection=standard/d' node.gyp

# cctest 编译错误 (未声明 backtrace_symbols)
[ -f test/cctest/test_crypto_clienthello.cc ] && : > test/cctest/test_crypto_clienthello.cc || true

# 清理 patch 失败产生的 rejects
find . -name "*.rej" -delete 2>/dev/null || true

if [ "$BACKEND" = "ninja" ]; then
  command -v ninja >/dev/null 2>&1 || die "未找到 ninja, 请安装 (或 NODE_BUILD_BACKEND=make)"
fi

# ---------- host 工具链: 优先用 v8 DEPS 钉定的 LLVM (termux 同款), 失败回退 gcc ----------
setup_host_toolchain() {
  local obj llvm_dir
  obj=$(grep -oE 'Linux_x64/clang-llvmorg-[0-9a-z-]+\.tar\.xz' deps/v8/DEPS | head -n 1)
  llvm_dir="$OUT_DIR/llvm-project-build"
  if [ -n "$obj" ] && [ ! -x "$llvm_dir/bin/clang" ]; then
    info "下载 v8 钉定的 LLVM host 工具链 ($obj) ..."
    mkdir -p "$llvm_dir"
    if curl -fL --retry 3 --max-time 600 \
      "https://commondatastorage.googleapis.com/chromium-browser-clang/$obj" \
      -o "$OUT_DIR/llvm.tar.xz" && tar -xf "$OUT_DIR/llvm.tar.xz" -C "$llvm_dir"; then
      :
    else
      warn "LLVM 下载失败, 回退 gcc/g++ 作为 host 编译器"
      rm -rf "$llvm_dir"
    fi
  fi
  if [ -x "$llvm_dir/bin/clang" ]; then
    export CC_host="$llvm_dir/bin/clang${HOST_M32}"
    export CXX_host="$llvm_dir/bin/clang++${HOST_M32}"
    export LINK_host="$llvm_dir/bin/clang++${HOST_M32}"
    info "host 编译器: LLVM (v8 DEPS 钉定)"
  else
    export CC_host="gcc${HOST_M32}"
    export CXX_host="g++${HOST_M32}"
    info "host 编译器: gcc/g++"
  fi
}
setup_host_toolchain

# ---------- 环境 (同 node 官方 android_configure.py) ----------
export PATH="$PATH:$TOOLCHAIN/bin"
export CC="${TOOLCHAIN_PREFIX}${ANDROID_SDK_VERSION}-clang"
export CXX="${TOOLCHAIN_PREFIX}${ANDROID_SDK_VERSION}-clang++"
export GYP_DEFINES="\
  target_arch=${DEST_CPU} \
  v8_target_arch=${DEST_CPU} \
  android_target_arch=${DEST_CPU} \
  host_os=linux \
  OS=android \
  android_ndk_path=${NDK}"

# cpu-features.h: NDK r26+ 已移除, 用当前大版本补丁集里的 stub; API<28 需要 aligned_alloc 别名
CFLAGS=" -I${PATCH_DIR}/stubs"
if [ "$ANDROID_SDK_VERSION" -lt 28 ]; then
  CFLAGS+=" -Daligned_alloc=memalign"
fi
export CFLAGS

# Android 15+ (16 KB 页): 64 位可执行文件按 16 KB 对齐 (NDK r28+ 默认如此, 旧 NDK 显式指定; 32 位不需要)
case "$DEST_CPU" in
  arm64|x64) export LDFLAGS="${LDFLAGS:-} -Wl,-z,max-page-size=16384" ;;
esac

# ---------- 配置 & 编译 ----------
info "配置 ..."
CONFIGURE_ARGS=(
  --dest-cpu="$DEST_CPU"
  --dest-os=android
  --openssl-no-asm
  --cross-compiling
  --partly-static
  --with-intl=full-icu
  --prefix="$OUT_DIR/nodejs-v${VER}-android-${DEST_CPU}"
)
# npm: 默认内置 (应用把它和 node 一起打包, 用户无需下载; 运行方式 node <npm 目录>/bin/npm-cli.js)
[ "$WITH_NPM" = "1" ] || CONFIGURE_ARGS+=(--without-npm)
# armeabi-v7a 的 Android ABI 是 softfp (显式指定, 不依赖自动检测)
[ "$DEST_CPU" = "arm" ] && CONFIGURE_ARGS+=(--with-arm-float-abi=softfp)
# 大版本专属 configure 参数: patches/<大版本>/custom/configure-args (每行一个)
# 版本差异集中管理在补丁目录, build.sh 保持通用 (如 26 的 Temporal 禁用)
CONFIG_ARGS_FILE="$PATCH_DIR/custom/configure-args"
if [ -f "$CONFIG_ARGS_FILE" ]; then
  info "读取额外 configure 参数: ${CONFIG_ARGS_FILE#$REPO_DIR/}"
  while IFS= read -r arg; do
    case "$arg" in
      ""|\#*) continue ;;  # 跳过空行和注释
    esac
    CONFIGURE_ARGS+=("$arg")
  done < "$CONFIG_ARGS_FILE"
fi
if [ "$BACKEND" = "ninja" ]; then
  CONFIGURE_ARGS+=(--ninja)
fi
./configure "${CONFIGURE_ARGS[@]}"

info "编译中 (可能需要 1-2 小时) ..."
if [ "$BACKEND" = "ninja" ]; then
  ninja -C out/Release -j"$(nproc)"
else
  make -j"$(nproc)"
fi

# ---------- 安装 & 打包 ----------
info "安装到 $OUT_DIR/nodejs-v${VER}-android-${DEST_CPU}"
python3 tools/install.py install --dest-dir="" --prefix="$OUT_DIR/nodejs-v${VER}-android-${DEST_CPU}" --build-dir "out/Release/"

if [ "$STRIP" = "1" ]; then
  info "精简二进制 ..."
  "${TOOLCHAIN}/bin/llvm-strip" "$OUT_DIR/nodejs-v${VER}-android-${DEST_CPU}/bin/node"
fi

# ---------- 校验: 架构 / 依赖库 / 页对齐 ----------
# CI runner 无法运行 Android 二进制, 所以用 readelf 静态检查 "能不能在手机上加载"
# 运行级检查由 scripts/smoke-test.js 在手机上完成 (随包发布)
verify_elf() {
  local bin="$1" readelf="$TOOLCHAIN/bin/llvm-readelf" machine want bad=0 lib
  case "$DEST_CPU" in
    arm64) want="AArch64" ;;
    arm)   want="ARM" ;;
    x64)   want="X86-64" ;;
    ia32)  want="Intel 80386" ;;
  esac
  machine=$("$readelf" -h "$bin" | sed -n 's/^ *Machine: *//p')
  case "$machine" in *"$want"*) info "ELF 架构: $machine" ;; *) warn "架构不符: 期望 $want, 实际 $machine"; bad=1 ;; esac
  # 只允许 Android 系统自带的稳定库 (libc++_shared.so / libatomic.so 等不在手机上, 会导致无法启动)
  for lib in $("$readelf" -d "$bin" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p'); do
    case "$lib" in
      libc.so|libm.so|libdl.so|liblog.so|libstdc++.so|libz.so|libandroid.so) info "  依赖: $lib" ;;
      *) warn "  不允许的依赖库: $lib (手机上不存在, node 将无法启动)"; bad=1 ;;
    esac
  done
  case "$DEST_CPU" in
    arm64|x64)
      if "$readelf" -lW "$bin" | awk '$1=="LOAD"{print $NF}' | grep -qvE '^0x(4000|10000|20000)$'; then
        warn "LOAD 段对齐不是 16 KB: Android 15+ 的 16 KB 页面设备可能拒绝加载"; bad=1
      fi ;;
  esac
  return $bad
}
if [ "$VERIFY" = "1" ]; then
  verify_elf "$OUT_DIR/nodejs-v${VER}-android-${DEST_CPU}/bin/node" || die "ELF 校验失败 (见上方 [!] 警告)"
fi

# 手机上的冒烟测试 (Studio Mobile 或 adb 里运行: node smoke-test.js)
cp "$REPO_DIR/scripts/smoke-test.js" "$OUT_DIR/nodejs-v${VER}-android-${DEST_CPU}/smoke-test.js"

info "打包 ..."
tar -C "$OUT_DIR" -cJf "$OUT_DIR/node-android-${DEST_CPU}-${VER}${PKG_SUFFIX}.tar.xz" \
  "nodejs-v${VER}-android-${DEST_CPU}"

echo
info "完成: $OUT_DIR/node-android-${DEST_CPU}-${VER}${PKG_SUFFIX}.tar.xz"
ls -lh "$OUT_DIR/node-android-${DEST_CPU}-${VER}${PKG_SUFFIX}.tar.xz"
