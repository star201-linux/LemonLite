#!/usr/bin/env node
/*
 * LemonLite 内置 WebAssembly 模块校验脚本
 * ======================================
 * 用法：
 *   node tool/wasm/verify_wasm.mjs
 *
 * 做什么：
 *   1. 读取 assets/wasm/lemonlite.wasm；
 *   2. 断言它是合法 wasm、import 数量为 0，并用 WebAssembly.instantiate(bytes, {})
 *      直接实例化（不提供任何 host 函数）；
 *   3. 逐个断言导出函数的行为，打印 PASS / FAIL；
 *   4. 打印导出列表与 wasm 字节数；
 *   5. 只要有一个断言失败，就以非 0 退出码结束。
 *
 * 退出码：0 = 全部通过；1 = 有用例失败或加载失败。
 */

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';

const HERE = dirname(fileURLToPath(import.meta.url));
const WASM_PATH = resolve(HERE, '../../assets/wasm/lemonlite.wasm');

/* ---------------- 断言/计数基础设施 ---------------- */

let passed = 0;
let failed = 0;

/** 记录一条断言结果 */
function assertEq(name, actual, expected) {
  if (actual === expected) {
    passed++;
    console.log(`PASS  ${name}  =>  ${actual}`);
  } else {
    failed++;
    console.log(`FAIL  ${name}  =>  期望 ${expected}，实际 ${actual}`);
  }
}

/** 记录一条自定义真值断言 */
function assertTrue(name, ok, detail) {
  if (ok) {
    passed++;
    console.log(`PASS  ${name}${detail ? `  =>  ${detail}` : ''}`);
  } else {
    failed++;
    console.log(`FAIL  ${name}${detail ? `  =>  ${detail}` : ''}`);
  }
}

function fatal(msg) {
  console.error(`FATAL  ${msg}`);
  process.exit(1);
}

/* ---------------- 1. 读取字节 ---------------- */

let bytes;
try {
  bytes = readFileSync(WASM_PATH);
} catch (err) {
  fatal(`无法读取 ${WASM_PATH}：${err.message}（先执行 bash tool/wasm/build_wasm.sh）`);
}

console.log('='.repeat(66));
console.log('LemonLite wasm 校验');
console.log('='.repeat(66));
console.log(`文件：${WASM_PATH}`);
console.log(`字节数：${bytes.length}`);
console.log(`魔数：${bytes.subarray(0, 4).toString('hex')}`);
console.log('-'.repeat(66));

if (bytes.length === 0) fatal('wasm 文件为空');
if (bytes.subarray(0, 4).toString('hex') !== '0061736d') fatal('wasm 魔数不正确');

/* ---------------- 2. 编译 + 检查 import ---------------- */

let module;
try {
  module = new WebAssembly.Module(bytes);
} catch (err) {
  fatal(`WebAssembly.Module 编译失败：${err.message}`);
}

const imports = WebAssembly.Module.imports(module);
assertEq('WebAssembly.Module.imports(module).length', imports.length, 0);
if (imports.length !== 0) {
  console.log(`     （存在 import：${imports.map((i) => `${i.module}.${i.name}`).join(', ')}）`);
}

/* ---------------- 3. 实例化（不提供任何 host 函数）---------------- */

let instance;
try {
  // 只传空 imports 对象：模块内不能有任何 host 依赖。
  // 注意：第一个参数是 BufferSource 时，instantiate 返回 { module, instance }。
  const result = await WebAssembly.instantiate(bytes, {});
  instance = result.instance ?? result;
} catch (err) {
  fatal(`WebAssembly.instantiate(bytes, {}) 失败：${err.message}`);
}
const ex = instance.exports;

/* ---------------- 4. 导出存在性与签名 ---------------- */

const REQUIRED_EXPORTS = [
  'memory',
  'add',
  'sub',
  'mul',
  'fib',
  'sum_to',
  'gcd',
  'popcount',
  'clamp',
  'sum_bytes',
  'version',
];

for (const name of REQUIRED_EXPORTS) {
  assertTrue(`导出存在：${name}`, Object.prototype.hasOwnProperty.call(ex, name),
    typeof ex[name]);
}
if (failed > 0) {
  fatal('缺少必需导出，终止后续行为断言');
}

assertTrue('memory 是 WebAssembly.Memory', ex.memory instanceof WebAssembly.Memory);
assertTrue('memory 至少 1 页（>= 65536 字节）', ex.memory.buffer.byteLength >= 65536,
  `${ex.memory.buffer.byteLength} 字节 = ${ex.memory.buffer.byteLength / 65536} 页`);

for (const name of REQUIRED_EXPORTS) {
  if (name === 'memory') continue;
  assertTrue(`导出是函数：${name}`, typeof ex[name] === 'function');
}

/* ---------------- 5. 行为断言 ---------------- */

console.log('-'.repeat(66));
console.log('[基础算术] add / sub / mul');

assertEq('add(2, 3)', ex.add(2, 3), 5);
assertEq('add(-7, 7)', ex.add(-7, 7), 0);
assertEq('sub(10, 4)', ex.sub(10, 4), 6);
assertEq('sub(4, 10)', ex.sub(4, 10), -6);
assertEq('mul(6, 7)', ex.mul(6, 7), 42);
assertEq('mul(-6, 7)', ex.mul(-6, 7), -42);

console.log('-'.repeat(66));
console.log('[斐波那契] fib（迭代实现，负数返回 0）');

assertEq('fib(0)', ex.fib(0), 0);
assertEq('fib(1)', ex.fib(1), 1);
assertEq('fib(2)', ex.fib(2), 1);
assertEq('fib(10)', ex.fib(10), 55);
assertEq('fib(20)', ex.fib(20), 6765);
assertEq('fib(46)', ex.fib(46), 1836311903);
assertEq('fib(47) 按 int32 回绕', ex.fib(47), -1323752223);
assertEq('fib(-3)', ex.fib(-3), 0);
assertEq('fib(-1000)', ex.fib(-1000), 0);

console.log('-'.repeat(66));
console.log('[累加] sum_to');

assertEq('sum_to(100)', ex.sum_to(100), 5050);
assertEq('sum_to(1)', ex.sum_to(1), 1);
assertEq('sum_to(0)', ex.sum_to(0), 0);
assertEq('sum_to(-5)', ex.sum_to(-5), 0);

console.log('-'.repeat(66));
console.log('[最大公约数] gcd（负数取绝对值）');

assertEq('gcd(48, 18)', ex.gcd(48, 18), 6);
assertEq('gcd(-48, 18)', ex.gcd(-48, 18), 6);
assertEq('gcd(48, -18)', ex.gcd(48, -18), 6);
assertEq('gcd(-48, -18)', ex.gcd(-48, -18), 6);
assertEq('gcd(0, 5)', ex.gcd(0, 5), 5);
assertEq('gcd(5, 0)', ex.gcd(5, 0), 5);
assertEq('gcd(0, 0)', ex.gcd(0, 0), 0);
assertEq('gcd(17, 5)', ex.gcd(17, 5), 1);

console.log('-'.repeat(66));
console.log('[位计数] popcount');

assertEq('popcount(0)', ex.popcount(0), 0);
assertEq('popcount(1)', ex.popcount(1), 1);
assertEq('popcount(0xF0F0)', ex.popcount(0xf0f0), 8);
assertEq('popcount(-1)', ex.popcount(-1), 32);
assertEq('popcount(0x7FFFFFFF)', ex.popcount(0x7fffffff), 31);

console.log('-'.repeat(66));
console.log('[区间限制] clamp');

assertEq('clamp(5, 1, 3)', ex.clamp(5, 1, 3), 3);
assertEq('clamp(0, 1, 3)', ex.clamp(0, 1, 3), 1);
assertEq('clamp(2, 0, 10)', ex.clamp(2, 0, 10), 2);
assertEq('clamp(2, 5, 1)（lo>hi 返回 lo）', ex.clamp(2, 5, 1), 5);
assertEq('clamp(-5, -3, 3)', ex.clamp(-5, -3, 3), -3);
assertEq('clamp(3, 3, 3)', ex.clamp(3, 3, 3), 3);

console.log('-'.repeat(66));
console.log('[版本] version');

assertEq('version()', ex.version(), 20250101);

console.log('-'.repeat(66));
console.log('[线性内存] sum_bytes');

const mem = new Uint8Array(ex.memory.buffer);
const memLen = mem.length;

// 用例 A：手动写入已知字节求和
const base = 1024;
const payload = [1, 2, 3, 4, 255];
mem.set(payload, base);
const expectedSum = payload.reduce((a, b) => a + b, 0); // 265
assertEq(`sum_bytes(${base}, ${payload.length})`, ex.sum_bytes(base, payload.length), expectedSum);

// 用例 B：从 0 开始读一段连续字节
mem.fill(0);
mem.fill(7, 0, 64);
assertEq('sum_bytes(0, 64)（64 个 7）', ex.sum_bytes(0, 64), 64 * 7);

// 用例 C：len <= 0 必须返回 0
assertEq('sum_bytes(0, 0)', ex.sum_bytes(0, 0), 0);
assertEq('sum_bytes(0, -10)', ex.sum_bytes(0, -10), 0);

// 用例 D：越界截断（不 trap），只统计内存内真实存在的字节
mem.fill(0);
mem[memLen - 2] = 10;
mem[memLen - 1] = 20;
assertEq(`sum_bytes(${memLen - 2}, 10) 越界截断`, ex.sum_bytes(memLen - 2, 10), 30);

// 用例 E：起点完全越界，返回 0 且不 trap
assertEq('sum_bytes(memLen, 4) 起点越界', ex.sum_bytes(memLen, 4), 0);
assertEq('sum_bytes(-1, -1) 非法参数', ex.sum_bytes(-1, -1), 0);

// 用例 F：跨整块内存求和的边界值（先清零，全 0 时应为 0）
mem.fill(0);
assertEq('sum_bytes(0, memLen)（当前全 0）', ex.sum_bytes(0, memLen), 0);

// 用例 F2：整块内存全填 1，求和应等于内存字节数（内存内只读，不会 trap）
mem.fill(1);
assertEq('sum_bytes(0, memLen)（全域填 1）', ex.sum_bytes(0, memLen), memLen);
mem.fill(0);

// 用例 G：ptr + len 发生 unsigned 回绕时也不能 trap
assertEq('sum_bytes(2147483647, 2147483647) 回绕防护', ex.sum_bytes(2147483647, 2147483647), 0);

/* ---------------- 6. 汇总 ---------------- */

console.log('='.repeat(66));
const exportNames = Object.keys(ex);
console.log(`wasm 字节数：${bytes.length}`);
console.log(`导入数量：${WebAssembly.Module.imports(module).length}`);
console.log(`导出列表（${exportNames.length} 个）：${exportNames.join(', ')}`);
console.log(`用例：PASS ${passed} / FAIL ${failed} / 共 ${passed + failed}`);
console.log('='.repeat(66));

if (failed > 0) {
  console.log('结果：校验未通过 ✗');
  process.exit(1);
}
console.log('结果：全部通过 ✓');
process.exit(0);
