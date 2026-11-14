// test/zip_meta.test.js
//
// 上传时的 zip 检查：id 必须与应用一致、入口必须真的存在。
//
// 这些断言守的是「上传那一刻就失败」这条线 —— 一旦漏掉，错误会推迟到
// 用户点「打开」时才暴露，而那时用户已经不知道去找谁了。
//
// 测试里自己拼 zip（stored + deflate 各一份），不依赖外部 zip 命令，
// CI 上也不需要装额外工具。

import test from 'node:test';
import assert from 'node:assert/strict';
import { deflateRawSync } from 'node:zlib';

import { listZipEntries, readMiniappMetadata } from '../src/lib/zip_meta.js';

/** 造一个最小 zip：entries = { name: Buffer|string }，method 0 或 8 */
function makeZip(entries, method = 0) {
  const locals = [];
  const centrals = [];
  let offset = 0;

  for (const [name, raw] of Object.entries(entries)) {
    const data = Buffer.isBuffer(raw) ? raw : Buffer.from(raw, 'utf8');
    const body = method === 8 ? deflateRawSync(data) : data;
    const nameBuf = Buffer.from(name, 'utf8');

    const local = Buffer.alloc(30 + nameBuf.length);
    local.writeUInt32LE(0x04034b50, 0);
    local.writeUInt16LE(20, 4);
    local.writeUInt16LE(0, 6);
    local.writeUInt16LE(method, 8);
    local.writeUInt16LE(0, 10);
    local.writeUInt16LE(0, 12);
    local.writeUInt32LE(0, 14); // crc32：读取方不校验
    local.writeUInt32LE(body.length, 18);
    local.writeUInt32LE(data.length, 22);
    local.writeUInt16LE(nameBuf.length, 26);
    local.writeUInt16LE(0, 28);
    nameBuf.copy(local, 30);

    const central = Buffer.alloc(46 + nameBuf.length);
    central.writeUInt32LE(0x02014b50, 0);
    central.writeUInt16LE(20, 4);
    central.writeUInt16LE(20, 6);
    central.writeUInt16LE(0, 8);
    central.writeUInt16LE(method, 10);
    central.writeUInt16LE(0, 12);
    central.writeUInt16LE(0, 14);
    central.writeUInt32LE(0, 16);
    central.writeUInt32LE(body.length, 20);
    central.writeUInt32LE(data.length, 24);
    central.writeUInt16LE(nameBuf.length, 28);
    central.writeUInt32LE(offset, 42);
    nameBuf.copy(central, 46);

    locals.push(local, body);
    centrals.push(central);
    offset += local.length + body.length;
  }

  const centralBuf = Buffer.concat(centrals);
  const eocd = Buffer.alloc(22);
  eocd.writeUInt32LE(0x06054b50, 0);
  eocd.writeUInt16LE(centrals.length, 8);
  eocd.writeUInt16LE(centrals.length, 10);
  eocd.writeUInt32LE(centralBuf.length, 12);
  eocd.writeUInt32LE(offset, 16);

  return Buffer.concat([...locals, centralBuf, eocd]);
}

const META = JSON.stringify({
  id: 'com.example.notes',
  name: '记事本',
  version: '1.0.0',
  entry: 'index.html',
});

test('stored：读出 metadata.json 且入口存在', () => {
  const zip = makeZip({ 'metadata.json': META, 'index.html': '<h1>x</h1>' }, 0);
  const result = readMiniappMetadata(zip);

  assert.deepEqual(result.metadata, JSON.parse(META));
  assert.equal(result.entry, 'index.html');
  assert.equal(result.entryExists, true);
  assert.equal(result.error, null);
});

test('deflate：同样能读（zip 工具默认压缩方式）', () => {
  const zip = makeZip({ 'metadata.json': META, 'index.html': '<h1>x</h1>' }, 8);
  const result = readMiniappMetadata(zip);
  assert.equal(result.metadata.name, '记事本');
  assert.equal(result.entryExists, true);
});

test('外层套一层目录也能找到（入口按同层解析）', () => {
  const zip = makeZip({
    'myapp/metadata.json': META,
    'myapp/index.html': '<h1>x</h1>',
  });
  const result = readMiniappMetadata(zip);
  assert.equal(result.entry, 'myapp/index.html');
  assert.equal(result.entryExists, true);
});

test('入口不存在时 entryExists = false（上传要因此被拒）', () => {
  const zip = makeZip({ 'metadata.json': META });
  const result = readMiniappMetadata(zip);
  assert.equal(result.entryExists, false);
});

test('没有 metadata.json 的老包：不报错，交给服务端信息兜底', () => {
  const zip = makeZip({ 'index.html': '<h1>x</h1>' });
  const result = readMiniappMetadata(zip);
  assert.equal(result.metadata, null);
  assert.equal(result.error, null);
});

test('metadata.json 不是 JSON：报错（上传要因此被拒）', () => {
  const zip = makeZip({ 'metadata.json': '{ nope', 'index.html': 'x' });
  const result = readMiniappMetadata(zip);
  assert.equal(result.metadata, null);
  assert.match(result.error, /JSON/);
});

test('截断的 zip 不会抛异常，只是读不出条目', () => {
  const zip = makeZip({ 'a.txt': 'x' }).subarray(0, 10);
  assert.equal(listZipEntries(zip).size, 0);
  assert.equal(readMiniappMetadata(zip).metadata, null);
});
