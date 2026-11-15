// server/src/lib/configfile.js
//
// 读写 config.yaml。
//
// 为什么要单独一个模块、而不是在 config.js 里 readFileSync 两行：
//
//   1. **读要用 `parse`，写要用 `Document`**。面板保存时如果直接
//      `stringify(对象)`，用户在 config.yaml 里写的全部注释会被抹掉 ——
//      而这个文件本身就是部署文档，那等于每次点一下「保存」就毁掉一份说明书。
//      `Document.setIn()` 只改目标那一个标量节点，其余节点的注释原样保留。
//
//   2. **写之前必须自校验**。配置文件写坏的后果是「下次启动直接起不来」，
//      比「保存失败」严重得多。所以先序列化成字符串、再解析回来、
//      确认目标值真的落进去了，最后才落盘。
//
//   3. 原子写（临时文件 + rename）。进程在写一半时被杀，留下的半截 YAML
//      可能语法合法但**少了一半配置** —— 那比启动失败更难排查。

import { existsSync, readFileSync, renameSync, unlinkSync, writeFileSync } from 'node:fs';
import { Document, parse, parseDocument } from 'yaml';

/**
 * 读一个 YAML 配置文件的顶层对象。
 *
 * @param {string} path
 * @returns {{exists: boolean, data: Record<string, any>, error?: string}}
 */
export function readConfigFile(path) {
  if (!existsSync(path)) return { exists: false, data: {} };
  const text = readFileSync(path, 'utf8');
  let data;
  try {
    data = parse(text);
  } catch (e) {
    return { exists: true, data: {}, error: String(e.message || e) };
  }
  if (data == null) return { exists: true, data: {} };
  if (typeof data !== 'object' || Array.isArray(data)) {
    return { exists: true, data: {}, error: '顶层必须是键值对（不是列表或标量）' };
  }
  return { exists: true, data };
}

/** 按点分路径取嵌套值 */
export function getIn(obj, path) {
  let cur = obj;
  for (const key of path.split('.')) {
    if (cur == null || typeof cur !== 'object') return undefined;
    cur = cur[key];
  }
  return cur;
}

/** 按点分路径设置嵌套值（中间层不存在就建） */
export function setIn(obj, path, value) {
  const keys = path.split('.');
  let cur = obj;
  for (let i = 0; i < keys.length - 1; i++) {
    const key = keys[i];
    if (cur[key] == null || typeof cur[key] !== 'object') cur[key] = {};
    cur = cur[key];
  }
  cur[keys[keys.length - 1]] = value;
  return obj;
}

/** 原子写：先落临时文件再 rename，失败退化成直接写 */
function writeAtomic(path, text) {
  const tmp = `${path}.tmp-${process.pid}`;
  try {
    writeFileSync(tmp, text, 'utf8');
    renameSync(tmp, path);
  } catch {
    // 某些文件系统（FUSE / 只读挂载的上级）不允许 rename，退化成直接写
    try {
      unlinkSync(tmp);
    } catch {
      /* ignore */
    }
    writeFileSync(path, text, 'utf8');
  }
}

/**
 * 把一个标量序列化成 YAML 文本（单行）。
 *
 * 用 `Document` 而不是自己拼引号：字符串里可能有冒号、井号、引号、中文，
 * 手写的引号规则迟早会在某个值上出错，而那种错误只会表现为
 * 「配置文件下次启动解析失败」——离出错的地方已经很远了。
 */
function formatScalar(value) {
  const text = new Document(value).toString({ lineWidth: 0 }).trimEnd();
  // 多行字符串会被序列化成 block scalar（`|` / `>`），插到行内会破坏缩进。
  // 面板只写短标量，真遇到换行就退回 JSON 的双引号转义（YAML 兼容）。
  if (text.includes('\n')) return JSON.stringify(value);
  return text;
}

/**
 * 更新 config.yaml 里的若干项，**保留注释、空行、缩进与键顺序**。
 *
 * 做法是「就地改那一段文本」，而不是 `doc.toString()` 整份重写：
 * 后者虽然能保住注释，但会把所有空行吃掉 —— 而这个文件里空行是分段的手段，
 * 一节七八个键挤在一起就没法读了。第一次保存之后文件就再也不是人写的样子。
 *
 * 所以：先用 `getIn(path, true)` 拿到目标标量节点的 `range`，
 * 只替换 range 覆盖的那几个字符。其余字节一个都不动。
 *
 * 只有「这个键压根不在文件里」时才退化到整份重新序列化 —— 那意味着
 * 用户手工删过键（或者从很旧的版本升级上来），此时格式已经不完整了，
 * 保它也没意义。
 *
 * @param {string} path                 config.yaml 的绝对路径
 * @param {Record<string, any>} patch   键是点分路径（`mail.smtp.host`），值是标量
 * @returns {{updated: string[], added: string[], reserialized: boolean}}
 */
export function updateConfigFile(path, patch) {
  const existed = existsSync(path);
  const text = existed ? readFileSync(path, 'utf8') : '';

  const doc = parseDocument(text);
  if (doc.errors.length > 0) {
    // 现有文件本身已经坏了：不要「顺手修一下」，那只会把错误越改越乱。
    throw new Error(`config.yaml 有语法错误，请先手工修正：${doc.errors[0].message}`);
  }

  const entries = Object.entries(patch);
  if (entries.length === 0) {
    return { updated: [], added: [], reserialized: false };
  }

  const edits = [];
  const missing = [];
  for (const [key, value] of entries) {
    // 第二个参数 keepScalar=true：要的是节点（带 range），不是它的值
    const node = doc.getIn(key.split('.'), true);
    if (!node || !Array.isArray(node.range)) {
      missing.push([key, value]);
      continue;
    }
    // range = [值起点, 值终点, 节点终点]；节点终点会带上行尾换行，不能用
    edits.push({ start: node.range[0], end: node.range[1], text: formatScalar(value) });
  }

  // 从后往前替换：前面的偏移量不会被后面的编辑影响
  edits.sort((a, b) => b.start - a.start);
  let out = text;
  for (const edit of edits) {
    out = out.slice(0, edit.start) + edit.text + out.slice(edit.end);
  }

  let reserialized = false;
  if (missing.length > 0) {
    reserialized = true;
    const rebuilt = parseDocument(out);
    for (const [key, value] of missing) {
      rebuilt.setIn(key.split('.'), value);
    }
    out = rebuilt.toString({ lineWidth: 0 });
  }

  // ---- 落盘前自校验 ----
  // 解析回来，确认每个值都真的写进去了。
  // 这一步能抓住「key 里带了奇怪字符」「值里有不可见控制字符」这类
  // 序列化器不会报错、但读回来对不上的情况。
  let back;
  try {
    back = parse(out);
  } catch (e) {
    throw new Error(`生成的 config.yaml 无法解析（未写入）：${e.message}`);
  }
  for (const [key, value] of entries) {
    const got = getIn(back, key);
    // 数字比字符串宽容：YAML 会把 587 读回 number，把 "587" 读回 string。
    // 对象/数组用 JSON 比较（面板只写标量，但别让实现留个洞）。
    const same =
      got === value ||
      (typeof value === 'number' && Number(got) === value) ||
      (typeof value === 'string' && String(got) === value) ||
      (typeof value === 'object' &&
        value !== null &&
        JSON.stringify(got) === JSON.stringify(value));
    if (!same) {
      throw new Error(
        `写入校验失败：${key} 期望 ${JSON.stringify(value)}，读回 ${JSON.stringify(got)}（未写入）`,
      );
    }
  }

  // 内容没变就别碰文件：面板上点一次「保存」不值得刷新一次 mtime
  if (out === text) {
    return { updated: entries.map(([k]) => k), added: [], reserialized };
  }

  writeAtomic(path, out.endsWith('\n') ? out : `${out}\n`);
  return {
    updated: entries.map(([k]) => k).filter((k) => !missing.some(([m]) => m === k)),
    added: missing.map(([k]) => k),
    reserialized,
  };
}
