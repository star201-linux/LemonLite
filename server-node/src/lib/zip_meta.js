
import { inflateRawSync } from 'node:zlib';

const EOCD_SIG = 0x06054b50;
const CEN_SIG = 0x02014b50;
const LOC_SIG = 0x04034b50;

/** 找出中央目录结束记录（EOCD）。从尾部往前找，最多扫 64KB（含注释上限）。 */
function findEocd(buf) {
  const min = Math.max(0, buf.length - 0xffff - 22);
  for (let i = buf.length - 22; i >= min; i--) {
    if (buf.readUInt32LE(i) === EOCD_SIG) return i;
  }
  return -1;
}

/**
 * 列出 zip 内所有条目（只读中央目录，速度与包大小无关）。
 * @returns {Map<string, {method:number, compressedSize:number, size:number, localOffset:number}>}
 */
export function listZipEntries(buf) {
  const entries = new Map();
  if (!Buffer.isBuffer(buf) || buf.length < 22) return entries;

  const eocd = findEocd(buf);
  if (eocd < 0) return entries;

  const count = buf.readUInt16LE(eocd + 10);
  let offset = buf.readUInt32LE(eocd + 16);

  for (let i = 0; i < count; i++) {
    if (offset + 46 > buf.length) break;
    if (buf.readUInt32LE(offset) !== CEN_SIG) break;

    const method = buf.readUInt16LE(offset + 10);
    const compressedSize = buf.readUInt32LE(offset + 20);
    const size = buf.readUInt32LE(offset + 24);
    const nameLen = buf.readUInt16LE(offset + 28);
    const extraLen = buf.readUInt16LE(offset + 30);
    const commentLen = buf.readUInt16LE(offset + 32);
    const localOffset = buf.readUInt32LE(offset + 42);

    if (offset + 46 + nameLen > buf.length) break;
    const name = buf.toString('utf8', offset + 46, offset + 46 + nameLen);
    entries.set(name, { method, compressedSize, size, localOffset });

    offset += 46 + nameLen + extraLen + commentLen;
  }
  return entries;
}

/** 读出一个条目的内容；读不到 / 不支持时返回 null。 */
export function readZipEntry(buf, entry) {
  if (!entry) return null;
  const { localOffset, method, compressedSize, size } = entry;
  if (localOffset + 30 > buf.length) return null;
  if (buf.readUInt32LE(localOffset) !== LOC_SIG) return null;

  const nameLen = buf.readUInt16LE(localOffset + 26);
  const extraLen = buf.readUInt16LE(localOffset + 28);
  const start = localOffset + 30 + nameLen + extraLen;
  const end = start + compressedSize;
  if (start > buf.length || end > buf.length) return null;

  const raw = buf.subarray(start, end);
  try {
    if (method === 0) return raw;
    if (method === 8) {
      const out = inflateRawSync(raw, { maxOutputLength: Math.max(size, 1024) });
      return out;
    }
  } catch {
    return null;
  }
  return null;
}

/** 在条目表里找 metadata.json（允许外面套一层目录，只认一级）。 */
function findMetadataEntry(entries) {
  if (entries.has('metadata.json')) return 'metadata.json';
  for (const name of entries.keys()) {
    const parts = name.split('/');
    if (parts.length === 2 && parts[1] === 'metadata.json' && parts[0]) {
      return name;
    }
  }
  return null;
}

/**
 * 从 zip 里读 metadata.json。
 *
 * @returns {{metadata: object|null, entry: string|null, entryExists: boolean, error: string|null}}
 *   metadata 为 null 表示包里没有这个文件（老包）或读不出来。
 */
export function readMiniappMetadata(buf) {
  const entries = listZipEntries(buf);
  if (entries.size === 0) {
    return { metadata: null, entry: null, entryExists: false, error: 'zip 结构读不出来' };
  }

  const name = findMetadataEntry(entries);
  if (!name) {
    return { metadata: null, entry: null, entryExists: false, error: null };
  }

  const raw = readZipEntry(buf, entries.get(name));
  if (!raw) {
    return { metadata: null, entry: name, entryExists: true, error: 'metadata.json 读取失败' };
  }

  let json;
  try {
    json = JSON.parse(raw.toString('utf8'));
  } catch {
    return { metadata: null, entry: name, entryExists: true, error: 'metadata.json 不是合法 JSON' };
  }
  if (!json || typeof json !== 'object' || Array.isArray(json)) {
    return { metadata: null, entry: name, entryExists: true, error: 'metadata.json 顶层必须是对象' };
  }

  const entry = String(json.entry || 'index.html').replace(/^\.?\//, '');
  const prefix = name === 'metadata.json' ? '' : name.slice(0, -'metadata.json'.length);
  const normalized = `${prefix}${entry}`.replace(/\\/g, '/');
  return {
    metadata: json,
    entry: normalized,
    entryExists: entries.has(normalized),
    error: null,
  };
}
