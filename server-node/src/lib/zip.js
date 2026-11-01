// server/src/lib/zip.js
//
// 极简 zip 生成器（只写、不读）。
//
// 为什么自己写而不是引 archiver / jszip：
//   我们只需要「把一堆内存里的 buffer 塞进一个合法 zip」。
//   archiver 要流式接口 + 一堆依赖；jszip 也是。手写 zip 的写入端
//   不到 120 行，而读取端（解压）在客户端由 Dart 的 archive 包负责 ——
//   服务端不需要解压任何一个包。
//
// 格式依据：PKWARE APPNOTE。只写最必要的三个结构：
//   本地文件头 (0x04034b50) → 文件数据 → 中央目录 (0x02014b50) → EOCD (0x06054b50)
//
// 刻意没用到的特性（都合法地省略了）：
//   * 数据描述符（我们写之前就知道 crc 与大小，不需要流式）
//   * ZIP64（包上限 20MB，远不到 4GB）
//   * 加密 / 压缩之外的算法（只用 stored 与 deflate）

import { deflateRawSync } from 'node:zlib';

const CRC_TABLE = (() => {
  const table = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) {
      c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    }
    table[n] = c >>> 0;
  }
  return table;
})();

/** CRC-32（zip 用的那个多项式） */
export function crc32(buf) {
  let crc = 0xffffffff;
  for (let i = 0; i < buf.length; i++) {
    crc = CRC_TABLE[(crc ^ buf[i]) & 0xff] ^ (crc >>> 8);
  }
  return (crc ^ 0xffffffff) >>> 0;
}

/** MS-DOS 时间/日期（zip 的老格式） */
function dosDateTime(date = new Date()) {
  const time =
    (date.getHours() << 11) | (date.getMinutes() << 5) | (date.getSeconds() >> 1);
  const day =
    ((date.getFullYear() - 1980) << 9) |
    ((date.getMonth() + 1) << 5) |
    date.getDate();
  return { time, day };
}

/**
 * 生成 zip。
 *
 * @param {{name: string, data: Buffer}[]} entries 文件列表（name 用正斜杠）
 * @param {{compress?: boolean}} [options] compress=false 全部 stored（调试时有用）
 * @returns {Buffer}
 */
export function makeZip(entries, { compress = true } = {}) {
  const { time, day } = dosDateTime();
  const locals = [];
  const centrals = [];
  let offset = 0;

  for (const { name, data } of entries) {
    const nameBuf = Buffer.from(name, 'utf8');
    const crc = crc32(data);

    // 小文件压缩后经常更大 —— 那就存原样，这是 zip 允许的
    const deflated = compress ? deflateRawSync(data, { level: 9 }) : data;
    const useDeflate = compress && deflated.length < data.length;
    const body = useDeflate ? deflated : data;
    const method = useDeflate ? 8 : 0;

    const local = Buffer.alloc(30);
    local.writeUInt32LE(0x04034b50, 0); // 本地文件头签名
    local.writeUInt16LE(20, 4); // 解压所需版本 2.0
    local.writeUInt16LE(0x0800, 6); // 通用标志：文件名是 UTF-8
    local.writeUInt16LE(method, 8); // 压缩方法
    local.writeUInt16LE(time, 10);
    local.writeUInt16LE(day, 12);
    local.writeUInt32LE(crc, 14);
    local.writeUInt32LE(body.length, 18); // 压缩后大小
    local.writeUInt32LE(data.length, 22); // 原始大小
    local.writeUInt16LE(nameBuf.length, 26);
    local.writeUInt16LE(0, 28); // extra 长度

    locals.push(local, nameBuf, body);

    const central = Buffer.alloc(46);
    central.writeUInt32LE(0x02014b50, 0); // 中央目录头签名
    central.writeUInt16LE(20, 4); // 创建版本
    central.writeUInt16LE(20, 6); // 解压所需版本
    central.writeUInt16LE(0x0800, 8);
    central.writeUInt16LE(method, 10);
    central.writeUInt16LE(time, 12);
    central.writeUInt16LE(day, 14);
    central.writeUInt32LE(crc, 16);
    central.writeUInt32LE(body.length, 20);
    central.writeUInt32LE(data.length, 24);
    central.writeUInt16LE(nameBuf.length, 28);
    central.writeUInt16LE(0, 30); // extra
    central.writeUInt16LE(0, 32); // 注释
    central.writeUInt16LE(0, 34); // 起始磁盘
    central.writeUInt16LE(0, 36); // 内部属性
    central.writeUInt32LE(0, 38); // 外部属性
    central.writeUInt32LE(offset, 42); // 本地头偏移

    centrals.push(central, nameBuf);
    offset += local.length + nameBuf.length + body.length;
  }

  const centralBuf = Buffer.concat(centrals);

  const end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50, 0); // EOCD 签名
  end.writeUInt16LE(0, 4); // 本磁盘编号
  end.writeUInt16LE(0, 6); // 中央目录起始磁盘
  end.writeUInt16LE(entries.length, 8); // 本磁盘条目数
  end.writeUInt16LE(entries.length, 10); // 总条目数
  end.writeUInt32LE(centralBuf.length, 12);
  end.writeUInt32LE(offset, 16); // 中央目录偏移
  end.writeUInt16LE(0, 20); // 注释长度

  return Buffer.concat([...locals, centralBuf, end]);
}

