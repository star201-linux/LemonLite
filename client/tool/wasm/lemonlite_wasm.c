/*
 * LemonLite 内置 WebAssembly 模块（freestanding C 源码）
 * ====================================================
 *
 * 设计约束（务必保持）：
 *  1. 完全 freestanding：不使用 libc / crt / sysroot，编译时加 -nostdlib。
 *     一旦调用 libc 函数（memcpy、printf、malloc ...），链接结果里就会出现
 *     import，Node 侧必须额外提供 host 函数才能实例化；本模块要求
 *     `WebAssembly.instantiate(bytes, {})` 能直接成功，所以必须零 import。
 *  2. 所有导出都是 int32 / i32 语义（WebAssembly MVP 的 wasm32 基本类型），
 *     不涉及浮点、不涉及 64 位类型，方便 Dart / JS 两侧直接调用。
 *  3. 不返回指针、不做内存分配，导出内存仅用于 sum_bytes 读取字节。
 *
 * 编译方式见同目录 build_wasm.sh，产物为 assets/wasm/lemonlite.wasm。
 */

/* 导出宏：
 *  - export_name("xxx") 让 wasm 导出名与函数名严格一致（不依赖名字修饰）；
 *  - visibility("default") 保证 -O2 下不会被当作内部符号优化掉。
 * 构建脚本同时用 -Wl,--export=xxx 再次声明，双重保险。 */
#define LEMONLITE_EXPORT(name) \
    __attribute__((visibility("default"), export_name(name)))

/* wasm32 下每个内存页固定 64 KiB */
#define LEMONLITE_WASM_PAGE_SIZE 65536u

/* ============================================================
 * 整数版本号：20250101
 * 用途：宿主（Dart/JS）加载 wasm 后校验模块版本，避免加载到过期的产物。
 * ============================================================ */
LEMONLITE_EXPORT("version")
int version(void) {
    return 20250101;
}

/* ============================================================
 * 四则运算基础函数：add / sub / mul
 * 用途：给小程序脚本层提供最基础的算术语义，同时也是最快的冒烟测试点。
 * 说明：统一使用有符号 int32，溢出按 C 语言的实现定义行为，
 *       wasm32 / clang 下即为二进制补码回绕（wrap around）。
 * ============================================================ */
LEMONLITE_EXPORT("add")
int add(int a, int b) {
    return a + b; /* 参数与返回值都是 i32 */
}

LEMONLITE_EXPORT("sub")
int sub(int a, int b) {
    return a - b; /* 参数与返回值都是 i32 */
}

LEMONLITE_EXPORT("mul")
int mul(int a, int b) {
    return a * b; /* int32 乘法，溢出自回绕 */
}

/* ============================================================
 * fib(n)：迭代法求斐波那契数列第 n 项
 * 语义：
 *   n < 0        -> 返回 0（负数输入视为无效，直接给 0，绝不进入循环）
 *   n == 0       -> 0
 *   n == 1       -> 1
 *   n >= 2       -> f(n-1) + f(n-2)
 * 溢出：n > 46 时结果超出 int32，按二进制补码回绕（不做饱和处理）。
 * 复杂度：O(n) 迭代，空间 O(1)，不存在递归深度问题。
 * 注意：为了严格遵守“第 n 个斐波那契数”的定义，这里只做 n-1 次线性迭代，
 *       不会“提前返回”，因此循环次数 = max(n-1, 0)，对任意 int32 输入都必然
 *       终止（不存在死循环）；调用方应对超大 n 有意识（只是慢，不会挂死）。
 * ============================================================ */
LEMONLITE_EXPORT("fib")
int fib(int n) {
    if (n < 0) {
        return 0; /* 负数：按约定返回 0 */
    }
    if (n == 0) {
        return 0;
    }
    unsigned int a = 0u; /* f(0) */
    unsigned int b = 1u; /* f(1) */
    for (int i = 1; i < n; ++i) {
        unsigned int next = a + b; /* 无符号加法 = int32 回绕，避免有符号溢出 UB */
        a = b;
        b = next;
    }
    return (int)b; /* 以 int32 返回（可能已回绕） */
}

/* ============================================================
 * sum_to(n)：计算 1 + 2 + ... + n
 * 语义：n <= 0 返回 0；其余用 int32 累加（不使用 n*(n+1)/2 的闭式，
 *       以免中间乘法在有符号域溢出产生 UB），循环次数 = max(n, 0)。
 * ============================================================ */
LEMONLITE_EXPORT("sum_to")
int sum_to(int n) {
    if (n <= 0) {
        return 0;
    }
    int acc = 0;
    for (int i = 1; i <= n; ++i) {
        acc += i; /* int32 累加，溢出回绕 */
        if (i == n) {
            break; /* 防御性写法：避免 n == INT32_MAX 时 i++ 溢出的 UB */
        }
    }
    return acc;
}

/* ============================================================
 * gcd(a, b)：欧几里得算法求最大公约数
 * 语义：负数先取绝对值（用无符号取反实现，INT32_MIN 也不会 UB）；
 *       gcd(0, 0) 约定返回 0；gcd(0, x) 返回 |x|。
 * 返回：非负的 int32。
 * ============================================================ */
LEMONLITE_EXPORT("gcd")
int gcd(int a, int b) {
    /* 转成无符号再取绝对值：对 INT32_MIN 也安全 */
    unsigned int ua = (a < 0) ? (0u - (unsigned int)a) : (unsigned int)a;
    unsigned int ub = (b < 0) ? (0u - (unsigned int)b) : (unsigned int)b;
    while (ub != 0u) {
        unsigned int r = ua % ub; /* 欧几里得：辗转相除 */
        ua = ub;
        ub = r;
    }
    /* 结果一定 <= |max(a,b)|，不会超过 INT32_MAX，可安全转回 int */
    return (int)ua;
}

/* ============================================================
 * popcount(x)：统计 32 位二进制中 1 的个数（汉明重量）
 * 语义：把输入按无符号 32 位处理，所以 popcount(-1) == 32。
 * 实现：经典的 SWAR 并行位计数（5 步），无分支、无查表、无内存访问。
 * ============================================================ */
LEMONLITE_EXPORT("popcount")
int popcount(int x) {
    unsigned int v = (unsigned int)x;
    v = v - ((v >> 1) & 0x55555555u);                    /* 每 2 位一组统计 */
    v = (v & 0x33333333u) + ((v >> 2) & 0x33333333u);    /* 每 4 位一组统计 */
    v = (v + (v >> 4)) & 0x0F0F0F0Fu;                    /* 每 8 位一组统计 */
    v = (v * 0x01010101u) >> 24;                         /* 4 个字节求和到最高字节 */
    return (int)v; /* 取值 0..32 */
}

/* ============================================================
 * clamp(v, lo, hi)：把 v 限制在 [lo, hi] 区间
 * 语义：
 *   lo > hi（区间非法）-> 直接返回 lo（约定，不抛错、不交换）
 *   v < lo             -> lo
 *   v > hi             -> hi
 *   否则               -> v
 * ============================================================ */
LEMONLITE_EXPORT("clamp")
int clamp(int v, int lo, int hi) {
    if (lo > hi) {
        return lo; /* 区间非法：按约定返回下界 */
    }
    if (v < lo) {
        return lo;
    }
    if (v > hi) {
        return hi;
    }
    return v;
}

/* ============================================================
 * sum_bytes(ptr, len)：把导出内存 [ptr, ptr+len) 区间的字节逐字节相加
 * 用途：小程序运行时可以把数据写进 wasm 线性内存，再交给 wasm 做聚合计算；
 *       同时也是“导出内存可用”的端到端验证用例。
 * 安全（关键）：
 *   - 先用 __builtin_wasm_memory_size(0) 取当前内存页数，算出内存真实字节数；
 *   - 把 ptr / len 当作无符号 32 位处理，用 64 位累加，避免 ptr+len 回绕；
 *   - 区间按内存实际大小截断（end 取 min(ptr+len, 内存大小)），
 *     len <= 0 或 ptr 已越界时直接返回 0；
 *   - 因此永远不会越界读写，不会触发 wasm trap，也不会撑爆内存。
 * 返回值：字节和的 int32（1 页内存时最大 65536*255 = 16,711,680，不会溢出）。
 * ============================================================ */
LEMONLITE_EXPORT("sum_bytes")
int sum_bytes(int ptr, int len) {
    if (len <= 0) {
        return 0; /* 长度为 0 或负数：无事可做 */
    }

    /* 当前线性内存真实字节数（页数 * 64KiB），用 64 位避免乘法溢出 */
    unsigned long long mem_bytes =
        (unsigned long long)__builtin_wasm_memory_size(0) * LEMONLITE_WASM_PAGE_SIZE;
    if (mem_bytes == 0ull) {
        return 0; /* 理论上不会发生：模块至少 1 页 */
    }

    /* 把有符号 i32 视作无符号偏移；负数会变成很大的数，后续会被截断成空区间 */
    unsigned long long start = (unsigned int)ptr;
    unsigned long long length = (unsigned int)len;
    unsigned long long end = start + length;
    if (end > mem_bytes) {
        end = mem_bytes; /* 越界部分截断，不读越界 */
    }
    if (start >= end) {
        return 0; /* 起点已越界：返回 0，绝不 trap */
    }

    /* 直接以线性内存起始地址为基址逐字节读取（volatile 防止被优化掉） */
    volatile unsigned char *base = (volatile unsigned char *)0;
    int acc = 0;
    for (unsigned long long i = start; i < end; ++i) {
        acc += (int)base[i];
    }
    return acc;
}
