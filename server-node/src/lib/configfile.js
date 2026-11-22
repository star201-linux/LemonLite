
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

function formatScalar(value) {
  const text = new Document(value).toString({ lineWidth: 0 }).trimEnd();
  // 多行字符串会被序列化成 block scalar（`|` / `>`），插到行内会破坏缩进。
  // 面板只写短标量，真遇到换行就退回 JSON 的双引号转义（YAML 兼容）。
  if (text.includes('\n')) return JSON.stringify(value);
  return text;
}

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
