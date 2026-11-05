// test/packages_dto.test.js
//
// 包 / 图标地址的纯函数测试。
//
// 这几行看起来「怎么写都对」，但它们决定的是客户端能不能下载到东西：
//   * 相对包路径必须走 `/api/market/<id>/package`，而不是假想的静态目录；
//   * 图标既可能是完整 URL，也可能是 `icons/<id>.png`，都要补成绝对地址；
//   * 图标上传只认真正的图片字节，不能信扩展名。
// 都是纯函数，不需要数据库。

import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  absoluteAssetUrl,
  packageDownloadUrl,
} from '../src/lib/package_store.js';
import { detectImage } from '../src/lib/icon_store.js';

const ORIGIN = 'https://ll.example.com';

test('相对包路径走下载接口，不指向不存在的静态路径', () => {
  const url = packageDownloadUrl(
    { id: 'todo.lite', version: '1.2.0', package_url: 'packages/todo.lite/1.2.0.zip' },
    ORIGIN,
  );
  assert.equal(
    url,
    'https://ll.example.com/api/market/todo.lite/package?version=1.2.0',
  );
});

test('完整包地址原样返回（包在 CDN 上）', () => {
  const url = packageDownloadUrl(
    { id: 'a', version: '1', package_url: 'https://cdn.example.com/a/1.zip' },
    ORIGIN,
  );
  assert.equal(url, 'https://cdn.example.com/a/1.zip');
});

test('没有上架包时地址为空', () => {
  assert.equal(packageDownloadUrl({ id: 'a', version: '1', package_url: null }), '');
});

test('图标：相对路径补成绝对地址', () => {
  assert.equal(
    absoluteAssetUrl('icons/a.png', ORIGIN),
    'https://ll.example.com/icons/a.png',
  );
  assert.equal(
    absoluteAssetUrl('/static/a.png', ORIGIN),
    'https://ll.example.com/static/a.png',
  );
  assert.equal(
    absoluteAssetUrl('https://cdn.example.com/a.png', ORIGIN),
    'https://cdn.example.com/a.png',
  );
  assert.equal(absoluteAssetUrl('', ORIGIN), '');
});

const PNG = Buffer.from([
  0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 0,
]);
const JPEG = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0, 0, 0, 0, 0, 0, 0, 0]);
const GIF = Buffer.from('GIF89a00000000', 'ascii');
const WEBP = Buffer.concat([
  Buffer.from('RIFF', 'ascii'),
  Buffer.from([0x20, 0, 0, 0]),
  Buffer.from('WEBP', 'ascii'),
]);

test('图标上传只认图片 magic（认得出 PNG / JPEG / GIF / WebP）', () => {
  assert.equal(detectImage(PNG)?.ext, 'png');
  assert.equal(detectImage(JPEG)?.ext, 'jpg');
  assert.equal(detectImage(GIF)?.ext, 'gif');
  assert.equal(detectImage(WEBP)?.ext, 'webp');
});

test('改名成 .png 的 HTML 不会被当成图片', () => {
  assert.equal(detectImage(Buffer.from('<!doctype html><html>')), null);
  assert.equal(detectImage(Buffer.alloc(0)), null);
});
