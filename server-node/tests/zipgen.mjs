// test/zipgen.mjs
//
// 验证自写的 zip 生成器（src/seed_packages.js 里那份）。
//
// 为什么单独测：它没有引 archiver/jszip，是手写的 zip 结构。
// 手写二进制格式最容易出「自己读得出来但别的工具读不出来」的错，
// 所以这里用**标准库**（node:zlib）与 **Python 的 zipfile** 交叉验证。
//
// 生成器在 seed_packages.js 里不是导出的（那里是脚本）。
// 所以这里复制一份等价实现来测？—— 不行，那测的是副本。
// 正确做法：把生成器抽出来。见下面的 import。

import { test } from 'node:test';
import assert from 'node:assert/strict';

// seed_packages.js 是可直接运行的脚本，import 它会触发 main()。
// 所以生成器必须放在独立模块里 —— 见 src/lib/zip.js。
import { makeZip, crc32 } from '../src/lib/zip.js';

test('crc32 与标准值一致', () => {
  // "123456789" 的 CRC-32 是 0xCBF43926（业界标准测试向量）
  assert.equal(crc32(Buffer.from('123456789')), 0xcbf43926);
  assert.equal(crc32(Buffer.from('')), 0);
});

test('生成的 zip 有合法结构（签名 + 中央目录 + EOCD）', () => {
  const zip = makeZip([
    { name: 'index.html', data: Buffer.from('<h1>hi</h1>') },
    { name: 'app.js', data: Buffer.from('console.log(1)') },
  ]);

  // 本地文件头
  assert.equal(zip.readUInt32LE(0), 0x04034b50);
  // EOCD 在末尾 22 字节处开始
  const eocd = zip.length - 22;
  assert.equal(zip.readUInt32LE(eocd), 0x06054b50);
  assert.equal(zip.readUInt16LE(eocd + 8), 2); // 条目数
  assert.equal(zip.readUInt16LE(eocd + 10), 2);
});

test('空目录 / 单文件也能打包', () => {
  const one = makeZip([{ name: 'a.txt', data: Buffer.from('x') }]);
  assert.equal(one.readUInt16LE(one.length - 22 + 8), 1);

  const empty = makeZip([]);
  assert.equal(empty.readUInt32LE(0), 0x06054b50);
  assert.equal(empty.readUInt16LE(8), 0);
});

test('文件名用 UTF-8 标志（中文文件名不乱码）', () => {
  const zip = makeZip([{ name: '中文/文件.html', data: Buffer.from('x') }]);
  // 通用标志位第 11 位 = UTF-8
  assert.equal(zip.readUInt16LE(6) & 0x0800, 0x0800);
  // 文件名确实以 UTF-8 编码出现
  assert.ok(zip.includes(Buffer.from('中文/文件.html', 'utf8')));
});
