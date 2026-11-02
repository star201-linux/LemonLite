#!/usr/bin/env bash
#
# LemonLite 内置 WebAssembly 模块构建脚本
# =======================================
# 用本机 clang（wasm32 target + wasm-ld）把 tool/wasm/lemonlite_wasm.c
# 编译成 assets/plugins/lemonlite-wasm/modules/lemonlite.wasm。
#
# 注意路径：wasm 已经不属于宿主核心，而是随包附带的**插件**包的一部分
# （manifest 见 assets/plugins/lemonlite-wasm/lemonlite.json）。
#
# 特点：
#   * freestanding：-nostdlib，不链接任何 libc，保证产物零 import
#     （Node 端可以用 WebAssembly.instantiate(bytes, {}) 直接实例化）；
#   * 可重复执行：每次覆盖生成同一个产物，输出目录自动创建；
#   * 沙箱友好：编译临时文件统一放到工作区内的 .tmpbuild 目录，
#     脚本退出时（含失败）自动清理，不在工作区留垃圾。
#
# 用法：
#   bash tool/wasm/build_wasm.sh
#   CLANG=/path/to/clang bash tool/wasm/build_wasm.sh   # 指定别的 clang
#
set -euo pipefail

# ---------- 路径推导（不写死绝对路径，可在任意位置重复执行）----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

SRC="${SCRIPT_DIR}/lemonlite_wasm.c"
OUT_DIR="${REPO_ROOT}/assets/plugins/lemonlite-wasm/modules"
OUT="${OUT_DIR}/lemonlite.wasm"

CLANG="${CLANG:-clang}"

# ---------- 临时目录：必须落在工作区内 ----------
# 本机 /tmp 是 tmpfs 且在工作区之外，沙箱下 clang 写临时文件会被拒绝，
# 因此显式把 TMPDIR 指向仓库内的 .tmpbuild。
export TMPDIR="${REPO_ROOT}/.tmpbuild"
mkdir -p "${TMPDIR}"
# 无论成功失败都清理临时目录
cleanup() { rm -rf "${TMPDIR}"; }
trap cleanup EXIT INT TERM

# ---------- 前置检查 ----------
if ! command -v "${CLANG}" >/dev/null 2>&1; then
    echo "[build_wasm] 错误：找不到 clang（可用 CLANG=/path/to/clang 指定）" >&2
    exit 1
fi
if [ ! -f "${SRC}" ]; then
    echo "[build_wasm] 错误：源文件不存在：${SRC}" >&2
    exit 1
fi

mkdir -p "${OUT_DIR}"

# ---------- 编译参数 ----------
# --target=wasm32          生成 wasm32 目标
# -O2                      优化级别
# -nostdlib -ffreestanding 完全 freestanding，禁止任何 libc 依赖
# -Wl,--no-entry           没有 _start，也不需要入口函数
# -Wl,--export=<name>      显式导出每个函数（与源码里的 export_name 属性双保险）
# -Wl,--export-memory      导出线性内存，符号名固定为 memory
# -Wl,--initial-memory     初始内存 2 页 = 128KiB（保证 >= 1 页 64KiB）
# -Wl,-z,stack-size        预留 16KiB 栈（本模块几乎不用栈，留够即可）
# -Wl,--max-memory         上限 16MiB，防止宿主 grow 到失控
# -Wl,--fatal-warnings     链接告警即失败，避免产物悄悄退化出 import
# -Wl,--allow-undefined 不允许，所以这里刻意不加；出现未定义符号会直接报错
BUILD_CMD=(
    "${CLANG}"
    --target=wasm32
    -O2
    -nostdlib
    -ffreestanding
    -Wl,--no-entry
    -Wl,--export=add
    -Wl,--export=sub
    -Wl,--export=mul
    -Wl,--export=fib
    -Wl,--export=sum_to
    -Wl,--export=gcd
    -Wl,--export=popcount
    -Wl,--export=clamp
    -Wl,--export=sum_bytes
    -Wl,--export=version
    -Wl,--export-memory
    -Wl,--initial-memory=131072
    -Wl,--max-memory=16777216
    -Wl,-z,stack-size=16384
    -Wl,--fatal-warnings
    -o "${OUT}"
    "${SRC}"
)

echo "[build_wasm] clang: $("${CLANG}" --version | head -n 1)"
echo "[build_wasm] TMPDIR=${TMPDIR}"
echo "[build_wasm] 编译命令："
printf '  %q' "${BUILD_CMD[@]}"
printf '\n'

"${BUILD_CMD[@]}"

# ---------- 产物自检 ----------
if [ ! -s "${OUT}" ]; then
    echo "[build_wasm] 错误：产物为空：${OUT}" >&2
    exit 1
fi

SIZE="$(wc -c < "${OUT}" | tr -d '[:space:]')"
# wasm 魔数：00 61 73 6d
MAGIC="$(head -c 4 "${OUT}" | od -An -tx1 | tr -d '[:space:]')"
if [ "${MAGIC}" != "0061736d" ]; then
    echo "[build_wasm] 错误：产物不是合法 wasm（魔数 ${MAGIC}）" >&2
    exit 1
fi

echo "[build_wasm] 成功：${OUT} (${SIZE} 字节)"
echo "[build_wasm] 下一步校验：node tool/wasm/verify_wasm.mjs"
