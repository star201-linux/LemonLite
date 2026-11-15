// server/test/config_file.test.js
//
// config.yaml 的读写。
//
// 重点不是「能不能读一个值」，而是两条**一旦破了就很贵**的性质：
//   1. 面板保存不能抹掉注释 —— 这个文件本身就是部署文档；
//   2. 写坏的文件必须当场被发现 —— 配置写坏的后果是「下次启动起不来」，
//      而那时运维已经不知道是哪一次点击造成的了。

import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { after, describe, test } from 'node:test';
import { parse } from 'yaml';

import { CONFIG_DEFAULTS } from '../src/config.js';
import { getIn, readConfigFile, setIn, updateConfigFile } from '../src/lib/configfile.js';

const EXAMPLE = new URL('../config.example.yaml', import.meta.url).pathname;

const tmpRoot = mkdtempSync(join(tmpdir(), 'll-config-'));
after(() => rmSync(tmpRoot, { recursive: true, force: true }));

let seq = 0;
function tmpFile(text) {
  const path = join(tmpRoot, `c${seq++}.yaml`);
  if (text !== undefined) writeFileSync(path, text, 'utf8');
  return path;
}

/** 收集一个对象的所有叶子路径（`a.b.c`），数组不做展开 */
function leafPaths(obj, prefix = '') {
  const out = [];
  for (const [key, value] of Object.entries(obj)) {
    const path = prefix ? `${prefix}.${key}` : key;
    if (value && typeof value === 'object' && !Array.isArray(value)) {
      out.push(...leafPaths(value, path));
    } else {
      out.push(path);
    }
  }
  return out.sort();
}

describe('config.example.yaml', () => {
  test('能被解析，且顶层是对象', () => {
    const { exists, data, error } = readConfigFile(EXAMPLE);
    assert.equal(exists, true);
    assert.equal(error, undefined);
    assert.equal(typeof data, 'object');
  });

  test('键集合与代码里的默认值完全一致', () => {
    const example = readConfigFile(EXAMPLE).data;
    // 这个断言防的是「文档里写了、代码不认」以及反过来。
    // 少一个键 → 用户在配置文件里写的项被静默忽略，最难排查的一类问题。
    // 多一个键 → 用户以为自己配了，实际没生效。
    assert.deepEqual(leafPaths(example), leafPaths(CONFIG_DEFAULTS));
  });

  test('示例里的默认值与代码默认值相同', () => {
    const example = readConfigFile(EXAMPLE).data;
    for (const path of leafPaths(CONFIG_DEFAULTS)) {
      const fromFile = getIn(example, path);
      const fromCode = getIn(CONFIG_DEFAULTS, path);
      // 类型也要对得上：yaml 里写成 "3000" 会让配置一直用字符串
      assert.deepEqual(
        fromFile,
        fromCode,
        `${path}：example 是 ${JSON.stringify(fromFile)}，代码默认是 ${JSON.stringify(fromCode)}`,
      );
    }
  });
});

describe('updateConfigFile', () => {
  test('改值后注释与其它键原样保留', () => {
    const path = tmpFile(`# 顶部说明
http:
  # 端口注释
  port: 3000
  host: 0.0.0.0   # 行尾注释

mail:
  driver: console
`);
    updateConfigFile(path, { 'http.port': 8080 });

    const text = readFileSync(path, 'utf8');
    assert.match(text, /# 顶部说明/);
    assert.match(text, /# 端口注释/);
    assert.match(text, /# 行尾注释/);

    const data = parse(text);
    assert.equal(data.http.port, 8080);
    assert.equal(data.http.host, '0.0.0.0');
    assert.equal(data.mail.driver, 'console');
  });

  test('空行与缩进也原样保留（不只是注释）', () => {
    const source = 'a:\n  b: 1\n\n# 分隔\n\nc:\n  d: 2\n';
    const path = tmpFile(source);
    updateConfigFile(path, { 'a.b': 9 });
    // 逐字节比较：整份重新序列化会把空行吃掉，那样第一次保存之后
    // 这个文件就不再是人写的样子了（一节七八个键挤在一起没法读）
    assert.equal(readFileSync(path, 'utf8'), 'a:\n  b: 9\n\n# 分隔\n\nc:\n  d: 2\n');
  });

  test('值没变时不改写文件', () => {
    const path = tmpFile('a:\n  b: 1\n');
    const before = readFileSync(path, 'utf8');
    updateConfigFile(path, { 'a.b': 1 });
    assert.equal(readFileSync(path, 'utf8'), before);
  });

  test('键不在文件里时补进去（并标记 reserialized）', () => {
    const path = tmpFile('a:\n  b: 1\n');
    const result = updateConfigFile(path, { 'a.c': 2 });
    assert.deepEqual(result.added, ['a.c']);
    assert.equal(result.reserialized, true);
    assert.equal(parse(readFileSync(path, 'utf8')).a.c, 2);
    // 已有值不能被顺手清掉
    assert.equal(parse(readFileSync(path, 'utf8')).a.b, 1);
  });

  test('看起来像布尔的字符串会被加引号', () => {
    const path = tmpFile('admin:\n  setupToken: \"\"\n');
    updateConfigFile(path, { 'admin.setupToken': 'true' });
    // 不加引号的话，读回来会变成布尔 true —— 口令就成了 4 个字符
    assert.equal(parse(readFileSync(path, 'utf8')).admin.setupToken, 'true');
  });

  test('键不存在时新建，不覆盖已有的兄弟节点', () => {
    const path = tmpFile('a:\n  b: 1\n');
    updateConfigFile(path, { 'a.c': 2, 'x.y': 'z' });
    const data = parse(readFileSync(path, 'utf8'));
    assert.equal(data.a.b, 1);
    assert.equal(data.a.c, 2);
    assert.equal(data.x.y, 'z');
  });

  test('字符串里的冒号与井号不会把 YAML 写坏', () => {
    const path = tmpFile('mail:\n  from: ""\n');
    const tricky = 'no-reply@example.com # 不是注释: 也不是映射';
    updateConfigFile(path, { 'mail.from': tricky });
    assert.equal(parse(readFileSync(path, 'utf8')).mail.from, tricky);
  });

  test('布尔与数字写成真正的类型，不是字符串', () => {
    const path = tmpFile('mail:\n  smtp:\n    secure: false\n');
    updateConfigFile(path, { 'mail.smtp.secure': true, 'mail.smtp.port': 465 });
    const data = parse(readFileSync(path, 'utf8'));
    assert.equal(data.mail.smtp.secure, true);
    assert.equal(data.mail.smtp.port, 465);
    assert.equal(typeof data.mail.smtp.port, 'number');
  });

  test('原文件已损坏时抛错，且**不动**原文件', () => {
    const broken = 'a:\n  b: [1, 2\n'; // 少一个右括号
    const path = tmpFile(broken);
    assert.throws(() => updateConfigFile(path, { 'a.b': 1 }), /语法错误/);
    // 关键：不能「顺手修一下」把它改成半截合法的新内容
    assert.equal(readFileSync(path, 'utf8'), broken);
  });

  test('写不进去的值（对象塞进标量位）也能被落盘前校验挡住或正常写入', () => {
    const path = tmpFile('a:\n  b: 1\n');
    // 对象是合法的 YAML 值，应该能正常写进去而不是报错
    updateConfigFile(path, { 'a.c': { d: 1 } });
    assert.equal(parse(readFileSync(path, 'utf8')).a.c.d, 1);
  });

  test('空 patch 不写文件', () => {
    const path = tmpFile('a:\n  b: 1\n');
    const before = readFileSync(path, 'utf8');
    const result = updateConfigFile(path, {});
    assert.deepEqual(result.updated, []);
    assert.equal(readFileSync(path, 'utf8'), before);
  });
});

describe('readConfigFile', () => {
  test('文件不存在 → exists:false 且不抛错', () => {
    const result = readConfigFile(join(tmpRoot, 'nope.yaml'));
    assert.equal(result.exists, false);
    assert.deepEqual(result.data, {});
  });

  test('空文件当作空对象', () => {
    const path = tmpFile('');
    const result = readConfigFile(path);
    assert.equal(result.exists, true);
    assert.deepEqual(result.data, {});
  });

  test('顶层是列表时报错而不是硬塞进对象', () => {
    const path = tmpFile('- a\n- b\n');
    assert.match(readConfigFile(path).error, /键值对/);
  });
});

describe('getIn / setIn', () => {
  test('按点分路径取与设，中间层自动创建', () => {
    const obj = {};
    setIn(obj, 'a.b.c', 1);
    assert.deepEqual(obj, { a: { b: { c: 1 } } });
    assert.equal(getIn(obj, 'a.b.c'), 1);
    assert.equal(getIn(obj, 'a.x.y'), undefined);
  });
});
