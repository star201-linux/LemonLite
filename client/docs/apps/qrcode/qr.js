/* ============================================================================
 * qr.js —— 一个自包含的 QR Code 编码器（Byte 模式 / 纠错等级 M）
 * ----------------------------------------------------------------------------
 * 为什么自己写而不是引 CDN 上的库？
 *   1) 小程序页面应当离线可用 —— 市场服务器可能挂在局域网或没有外网的机器上，
 *      引一个外部 <script> 就等于把「能不能用」押在别人的 CDN 上；
 *   2) 这个编码器只有 ~300 行，而且逻辑完全由 ISO/IEC 18004 定死，
 *      不存在「自己实现会跑偏」的问题（前提是表别抄错 —— 见下面的常量表注释）。
 *
 * 覆盖范围（刻意收窄，够用就行）：
 *   - 只做 Byte 模式（UTF-8 字节），不做 Numeric / Alphanumeric / Kanji 的优化。
 *     代价是纯数字内容会比专业库多占一点空间，收益是少一半代码和一半出错面。
 *   - 只做纠错等级 M（约 15% 冗余）。等级由 format info 的 2 个 bit 决定，
 *     要做 L/Q/H 只需改 EC_TABLE 与 EC_BITS 两个常量。
 *   - 版本 1~40 全支持（自动选最小可容纳的版本）。
 *
 * 末尾挂了 module.exports 的兼容分支，所以这个文件既能被 <script> 直接加载，
 * 也能在 node 里 require 出来做单元测试（本项目的做法就是拿它和参考实现逐位比对）。
 * ==========================================================================*/
(function (global) {
  'use strict';

  /* --------------------------------------------------------------------------
   * 1. 常量表
   * ------------------------------------------------------------------------*/

  /** 每个版本的总码字数（数据 + 纠错），索引 = 版本号，0 号占位不用。 */
  var TOTAL_CODEWORDS = [
    0,
    26, 44, 70, 100, 134, 172, 196, 242, 292, 346,
    404, 466, 532, 581, 655, 733, 815, 901, 991, 1085,
    1156, 1258, 1364, 1474, 1588, 1706, 1828, 1921, 2051, 2185,
    2323, 2465, 2611, 2761, 2876, 3034, 3196, 3362, 3532, 3706
  ];

  /**
   * 纠错等级 M 的表：[纠错码字总数, 分块数]。
   *
   * 这两列直接决定 Reed-Solomon 怎么切块。抄错的后果很隐蔽 ——
   * 图形照样生成，扫描器却可能读不出来，所以这份表是拿参考实现逐版本核对过的。
   */
  var EC_M = [
    null,
    [10, 1], [16, 1], [26, 1], [36, 2], [48, 2], [64, 4], [72, 4], [88, 4], [110, 5], [130, 5],
    [150, 5], [176, 8], [198, 9], [216, 9], [240, 10], [280, 10], [308, 11], [338, 13], [364, 14], [416, 16],
    [442, 17], [476, 17], [504, 18], [560, 20], [588, 21], [644, 23], [700, 25], [728, 26], [784, 28], [812, 29],
    [868, 31], [924, 33], [980, 35], [1036, 37], [1064, 38], [1120, 40], [1204, 43], [1260, 45], [1316, 47], [1372, 49]
  ];

  /** 纠错等级 M 在 format info 里的 2 bit 值（L=01 / M=00 / Q=11 / H=10）。 */
  var EC_BITS = 0;

  /** Byte 模式的模式指示符 = 0100。 */
  var MODE_BYTE = 4;

  /* BCH 生成多项式（规范里的定值，不是随手取的数） */
  var G15 = (1 << 10) | (1 << 8) | (1 << 5) | (1 << 4) | (1 << 2) | (1 << 1) | 1; // 0x537
  var G15_MASK = (1 << 14) | (1 << 12) | (1 << 10) | (1 << 4) | (1 << 1);        // 0x5412
  var G18 = (1 << 12) | (1 << 11) | (1 << 10) | (1 << 9) | (1 << 8) | (1 << 5) | (1 << 2) | 1; // 0x1F25

  /* --------------------------------------------------------------------------
   * 2. GF(256) 有限域 —— Reed-Solomon 的基础
   * ------------------------------------------------------------------------*/

  var EXP = new Uint8Array(512);
  var LOG = new Uint8Array(256);

  (function initGaloisField() {
    var x = 1;
    for (var i = 0; i < 255; i++) {
      EXP[i] = x;
      LOG[x] = i;
      x <<= 1;
      // 本原多项式 x^8 + x^4 + x^3 + x^2 + 1 = 0x11D
      if (x & 0x100) x ^= 0x11D;
    }
    for (var j = 255; j < 512; j++) EXP[j] = EXP[j - 255];
  })();

  function gfMul(a, b) {
    if (a === 0 || b === 0) return 0;
    return EXP[LOG[a] + LOG[b]];
  }

  /** 生成多项式 g(x) = ∏(x - α^i)，系数按「最高次在前」存放，g[0] 恒为 1。 */
  function generatorPoly(degree) {
    var g = [1];
    for (var i = 0; i < degree; i++) {
      var alpha = EXP[i];
      var next = new Array(g.length + 1);
      for (var k = 0; k < next.length; k++) next[k] = 0;
      for (var j = 0; j < g.length; j++) {
        next[j] ^= g[j];                 // 乘以 x
        next[j + 1] ^= gfMul(g[j], alpha); // 乘以 α^i
      }
      g = next;
    }
    return g;
  }

  /** 综合除法求余数：返回 data 的 degree 个纠错码字。 */
  function rsEncode(data, degree) {
    var g = generatorPoly(degree);
    var res = new Uint8Array(data.length + degree);
    res.set(data, 0);

    for (var i = 0; i < data.length; i++) {
      var coef = res[i];
      if (coef === 0) continue;
      for (var j = 0; j < g.length; j++) {
        res[i + j] ^= gfMul(g[j], coef);
      }
    }
    return res.subarray(data.length);
  }

  /* --------------------------------------------------------------------------
   * 3. 容量与版本选择
   * ------------------------------------------------------------------------*/

  function symbolSize(version) { return version * 4 + 17; }

  /** Byte 模式的字符计数指示符位数：版本 1~9 是 8 位，10 以上是 16 位。 */
  function charCountBits(version) { return version < 10 ? 8 : 16; }

  /** 该版本在 Byte 模式下最多能装多少字节。 */
  function byteCapacity(version) {
    var dataCodewords = TOTAL_CODEWORDS[version] - EC_M[version][0];
    var usableBits = dataCodewords * 8 - 4 - charCountBits(version);
    return Math.floor(usableBits / 8);
  }

  /** 能装下 len 个字节的最小版本；装不下返回 0。 */
  function pickVersion(len) {
    for (var v = 1; v <= 40; v++) {
      if (len <= byteCapacity(v)) return v;
    }
    return 0;
  }

  /* --------------------------------------------------------------------------
   * 4. UTF-8 编码（不依赖 TextEncoder，老 WebView 上也稳）
   * ------------------------------------------------------------------------*/

  function utf8Bytes(str) {
    if (typeof TextEncoder !== 'undefined') return new TextEncoder().encode(str);

    var out = [];
    for (var i = 0; i < str.length; i++) {
      var c = str.charCodeAt(i);

      // 代理对：合并成一个码点，否则 emoji 会被编成两个无效字符
      if (c >= 0xD800 && c <= 0xDBFF && i + 1 < str.length) {
        var c2 = str.charCodeAt(i + 1);
        if (c2 >= 0xDC00 && c2 <= 0xDFFF) {
          c = 0x10000 + ((c - 0xD800) << 10) + (c2 - 0xDC00);
          i++;
        }
      }

      if (c < 0x80) {
        out.push(c);
      } else if (c < 0x800) {
        out.push(0xC0 | (c >> 6), 0x80 | (c & 0x3F));
      } else if (c < 0x10000) {
        out.push(0xE0 | (c >> 12), 0x80 | ((c >> 6) & 0x3F), 0x80 | (c & 0x3F));
      } else {
        out.push(0xF0 | (c >> 18), 0x80 | ((c >> 12) & 0x3F),
                 0x80 | ((c >> 6) & 0x3F), 0x80 | (c & 0x3F));
      }
    }
    return new Uint8Array(out);
  }

  /* --------------------------------------------------------------------------
   * 5. 比特流
   * ------------------------------------------------------------------------*/

  function BitBuffer() { this.bits = []; }

  BitBuffer.prototype.put = function (value, length) {
    for (var i = length - 1; i >= 0; i--) {
      this.bits.push((value >>> i) & 1);
    }
  };

  /** 把比特流补成完整的数据码字（终止符 → 字节对齐 → 填充码字）。 */
  function buildDataCodewords(version, bytes) {
    var total = TOTAL_CODEWORDS[version];
    var ecTotal = EC_M[version][0];
    var dataBits = (total - ecTotal) * 8;

    var buf = new BitBuffer();
    buf.put(MODE_BYTE, 4);
    buf.put(bytes.length, charCountBits(version));
    for (var i = 0; i < bytes.length; i++) buf.put(bytes[i], 8);

    // 终止符：最多 4 个 0，装不下就只补到边界
    if (buf.bits.length + 4 <= dataBits) buf.put(0, 4);
    while (buf.bits.length % 8 !== 0) buf.bits.push(0);

    // 交替填充 0xEC / 0x11 直到填满数据区
    var remaining = (dataBits - buf.bits.length) / 8;
    for (var k = 0; k < remaining; k++) buf.put(k % 2 ? 0x11 : 0xEC, 8);

    var codewords = new Uint8Array(buf.bits.length / 8);
    for (var b = 0; b < codewords.length; b++) {
      var v = 0;
      for (var j = 0; j < 8; j++) v = (v << 1) | buf.bits[b * 8 + j];
      codewords[b] = v;
    }
    return codewords;
  }

  /** 分块 → 逐块 RS 编码 → 交错排列（规范的 interleave 规则）。 */
  function interleave(codewords, version) {
    var total = TOTAL_CODEWORDS[version];
    var ecTotal = EC_M[version][0];
    var numBlocks = EC_M[version][1];
    var dataTotal = total - ecTotal;

    var blocksInGroup2 = total % numBlocks;
    var blocksInGroup1 = numBlocks - blocksInGroup2;
    var totalPerBlock = Math.floor(total / numBlocks);
    var dataPerGroup1 = Math.floor(dataTotal / numBlocks);
    var dataPerGroup2 = dataPerGroup1 + 1;
    var ecPerBlock = totalPerBlock - dataPerGroup1;

    var dcData = [];
    var ecData = [];
    var offset = 0;
    var maxDataSize = 0;

    for (var b = 0; b < numBlocks; b++) {
      var size = b < blocksInGroup1 ? dataPerGroup1 : dataPerGroup2;
      var chunk = codewords.subarray(offset, offset + size);
      dcData.push(chunk);
      ecData.push(rsEncode(chunk, ecPerBlock));
      offset += size;
      if (size > maxDataSize) maxDataSize = size;
    }

    var out = new Uint8Array(total);
    var idx = 0;
    for (var i = 0; i < maxDataSize; i++) {
      for (var r = 0; r < numBlocks; r++) {
        if (i < dcData[r].length) out[idx++] = dcData[r][i];
      }
    }
    for (var e = 0; e < ecPerBlock; e++) {
      for (var r2 = 0; r2 < numBlocks; r2++) out[idx++] = ecData[r2][e];
    }
    return out;
  }

  /* --------------------------------------------------------------------------
   * 6. 矩阵
   * ------------------------------------------------------------------------*/

  function Matrix(size) {
    this.size = size;
    this.modules = new Uint8Array(size * size);
    this.reserved = new Uint8Array(size * size);
  }

  Matrix.prototype.set = function (row, col, dark, reserved) {
    var i = row * this.size + col;
    this.modules[i] = dark ? 1 : 0;
    if (reserved) this.reserved[i] = 1;
  };

  Matrix.prototype.get = function (row, col) { return this.modules[row * this.size + col]; };
  Matrix.prototype.isReserved = function (row, col) { return this.reserved[row * this.size + col] === 1; };
  Matrix.prototype.xor = function (row, col, v) {
    var i = row * this.size + col;
    this.modules[i] ^= v ? 1 : 0;
  };

  /** 三个角上的定位图形（7×7 回字），连同外侧 1 像素分隔带一起写进去。 */
  function setupFinderPattern(m, version) {
    var size = m.size;
    var corners = [[0, 0], [size - 7, 0], [0, size - 7]];

    for (var p = 0; p < corners.length; p++) {
      var row0 = corners[p][0];
      var col0 = corners[p][1];
      for (var r = -1; r <= 7; r++) {
        for (var c = -1; c <= 7; c++) {
          var row = row0 + r;
          var col = col0 + c;
          if (row < 0 || row >= size || col < 0 || col >= size) continue;

          var dark = (r >= 0 && r <= 6 && (c === 0 || c === 6)) ||
                     (c >= 0 && c <= 6 && (r === 0 || r === 6)) ||
                     (r >= 2 && r <= 4 && c >= 2 && c <= 4);
          m.set(row, col, dark, true);
        }
      }
    }
  }

  /** 定时图形：第 6 行 / 第 6 列的黑白交替，供扫描器定位模块栅格。 */
  function setupTimingPattern(m) {
    for (var r = 8; r < m.size - 8; r++) {
      var dark = r % 2 === 0;
      m.set(r, 6, dark, true);
      m.set(6, r, dark, true);
    }
  }

  /** 校正图形（版本 2 起才有）：5×5 的同心方块，位置由规范公式给出。 */
  function alignmentPositions(version) {
    if (version === 1) return [];

    var count = Math.floor(version / 7) + 2;
    var size = symbolSize(version);
    // 版本 32 的间距是规范里的特例，不能套公式
    var step = size === 145 ? 26 : Math.ceil((size - 13) / (2 * count - 2)) * 2;

    var pos = [size - 7];
    for (var i = 1; i < count - 1; i++) pos[i] = pos[i - 1] - step;
    pos.push(6);
    return pos.reverse();
  }

  function setupAlignmentPattern(m, version) {
    var pos = alignmentPositions(version);
    var n = pos.length;

    for (var i = 0; i < n; i++) {
      for (var j = 0; j < n; j++) {
        // 三个角已被定位图形占用，跳过
        if ((i === 0 && j === 0) || (i === 0 && j === n - 1) || (i === n - 1 && j === 0)) continue;

        var row0 = pos[i];
        var col0 = pos[j];
        for (var r = -2; r <= 2; r++) {
          for (var c = -2; c <= 2; c++) {
            var dark = r === -2 || r === 2 || c === -2 || c === 2 || (r === 0 && c === 0);
            m.set(row0 + r, col0 + c, dark, true);
          }
        }
      }
    }
  }

  /** 15 bit 的格式信息：(纠错等级 2 bit | 掩码 3 bit) 过 BCH(15,5)，再异或固定掩码。 */
  function formatInfoBits(mask) {
    var data = (EC_BITS << 3) | mask;
    var d = data << 10;

    while (bchDigit(d) - bchDigit(G15) >= 0) {
      d ^= G15 << (bchDigit(d) - bchDigit(G15));
    }
    return ((data << 10) | d) ^ G15_MASK;
  }

  /** 18 bit 的版本信息（版本 ≥ 7 才写）：版本号过 (18,6) Golay 码。 */
  function versionInfoBits(version) {
    var d = version << 12;
    while (bchDigit(d) - bchDigit(G18) >= 0) {
      d ^= G18 << (bchDigit(d) - bchDigit(G18));
    }
    return (version << 12) | d;
  }

  function bchDigit(value) {
    var digit = 0;
    while (value !== 0) { digit++; value >>>= 1; }
    return digit;
  }

  function setupFormatInfo(m, mask) {
    var size = m.size;
    var bits = formatInfoBits(mask);

    for (var i = 0; i < 15; i++) {
      var dark = ((bits >> i) & 1) === 1;

      // 左上角竖排
      if (i < 6) m.set(i, 8, dark, true);
      else if (i < 8) m.set(i + 1, 8, dark, true);
      else m.set(size - 15 + i, 8, dark, true);

      // 左上角横排 + 右上 / 左下
      if (i < 8) m.set(8, size - i - 1, dark, true);
      else if (i < 9) m.set(8, 15 - i, dark, true);
      else m.set(8, 15 - i - 1, dark, true);
    }

    // 固定的黑模块（规范强制为 1，扫描器靠它校正方向）
    m.set(size - 8, 8, 1, true);
  }

  function setupVersionInfo(m, version) {
    var size = m.size;
    var bits = versionInfoBits(version);

    for (var i = 0; i < 18; i++) {
      var row = Math.floor(i / 3);
      var col = (i % 3) + size - 11;
      var dark = ((bits >> i) & 1) === 1;
      m.set(row, col, dark, true);
      m.set(col, row, dark, true);
    }
  }

  /** 数据区排布：从右下角起，两列一组、蛇形上下走，跳过所有功能图形。 */
  function setupData(m, data) {
    var size = m.size;
    var inc = -1;
    var row = size - 1;
    var bitIndex = 7;
    var byteIndex = 0;

    for (var col = size - 1; col > 0; col -= 2) {
      if (col === 6) col--; // 第 6 列是定时图形，整列跳过

      for (;;) {
        for (var c = 0; c < 2; c++) {
          if (!m.isReserved(row, col - c)) {
            var dark = false;
            if (byteIndex < data.length) {
              dark = ((data[byteIndex] >>> bitIndex) & 1) === 1;
            }
            m.set(row, col - c, dark);
            bitIndex--;
            if (bitIndex === -1) { byteIndex++; bitIndex = 7; }
          }
        }

        row += inc;
        if (row < 0 || row >= size) { row -= inc; inc = -inc; break; }
      }
    }
  }

  /* --------------------------------------------------------------------------
   * 7. 掩码
   * ------------------------------------------------------------------------*/

  var MASKS = [
    function (i, j) { return (i + j) % 2 === 0; },
    function (i) { return i % 2 === 0; },
    function (i, j) { return j % 3 === 0; },
    function (i, j) { return (i + j) % 3 === 0; },
    function (i, j) { return (Math.floor(i / 2) + Math.floor(j / 3)) % 2 === 0; },
    function (i, j) { return (i * j) % 2 + (i * j) % 3 === 0; },
    function (i, j) { return ((i * j) % 2 + (i * j) % 3) % 2 === 0; },
    function (i, j) { return ((i * j) % 3 + (i + j) % 2) % 2 === 0; }
  ];

  function applyMask(m, mask) {
    for (var col = 0; col < m.size; col++) {
      for (var row = 0; row < m.size; row++) {
        if (m.isReserved(row, col)) continue;
        m.xor(row, col, MASKS[mask](row, col));
      }
    }
  }

  /** 规范定义的 4 条罚分规则，总和最小的掩码胜出。 */
  function penalty(m) {
    var size = m.size;
    var points = 0;
    var row, col, same, last, i;

    // 规则 1：同行/同列连续 5 个以上同色
    for (row = 0; row < size; row++) {
      same = 0; last = -1;
      for (col = 0; col < size; col++) {
        var v = m.get(row, col);
        if (v === last) { same++; }
        else { if (same >= 5) points += 3 + (same - 5); last = v; same = 1; }
      }
      if (same >= 5) points += 3 + (same - 5);

      same = 0; last = -1;
      for (col = 0; col < size; col++) {
        var v2 = m.get(col, row);
        if (v2 === last) { same++; }
        else { if (same >= 5) points += 3 + (same - 5); last = v2; same = 1; }
      }
      if (same >= 5) points += 3 + (same - 5);
    }

    // 规则 2：2×2 同色方块
    for (row = 0; row < size - 1; row++) {
      for (col = 0; col < size - 1; col++) {
        var sum = m.get(row, col) + m.get(row, col + 1) +
                  m.get(row + 1, col) + m.get(row + 1, col + 1);
        if (sum === 4 || sum === 0) points += 3;
      }
    }

    // 规则 3：出现 1:1:3:1:1 的类定位图形
    for (row = 0; row < size; row++) {
      var bitsCol = 0;
      var bitsRow = 0;
      for (col = 0; col < size; col++) {
        bitsCol = ((bitsCol << 1) & 0x7FF) | m.get(row, col);
        if (col >= 10 && (bitsCol === 0x5D0 || bitsCol === 0x05D)) points += 40;

        bitsRow = ((bitsRow << 1) & 0x7FF) | m.get(col, row);
        if (col >= 10 && (bitsRow === 0x5D0 || bitsRow === 0x05D)) points += 40;
      }
    }

    // 规则 4：黑色模块占比偏离 50% 的程度
    var dark = 0;
    for (i = 0; i < m.modules.length; i++) dark += m.modules[i];
    var ratio = (dark * 100) / m.modules.length;
    points += Math.abs(Math.ceil(ratio / 5) - 10) * 10;

    return points;
  }

  function pickMask(m) {
    var best = 0;
    var bestPenalty = Infinity;

    for (var p = 0; p < 8; p++) {
      setupFormatInfo(m, p);   // 先把格式信息占位，保证掩码不覆盖到它
      applyMask(m, p);
      var score = penalty(m);
      applyMask(m, p);         // 撤销，试下一个

      if (score < bestPenalty) { bestPenalty = score; best = p; }
    }
    return best;
  }

  /* --------------------------------------------------------------------------
   * 8. 对外接口
   * ------------------------------------------------------------------------*/

  /**
   * 把一段文本编码成 QR 矩阵。
   *
   * @param {string} text  要编码的内容（按 UTF-8 处理）
   * @param {object} [opts] { version } 指定版本（不传则自动选最小可容纳版本）
   * @return {{version:number, mask:number, size:number, modules:Uint8Array}}
   *          modules 是 size×size 的一维数组，1 = 黑，索引 = row * size + col
   */
  function encode(text, opts) {
    opts = opts || {};
    if (typeof text !== 'string' || text.length === 0) {
      throw new Error('内容不能为空');
    }

    var bytes = utf8Bytes(text);
    var version = opts.version || pickVersion(bytes.length);

    if (!version) {
      throw new Error('内容太长：最多 ' + byteCapacity(40) + ' 字节，当前 ' + bytes.length + ' 字节');
    }
    if (bytes.length > byteCapacity(version)) {
      throw new Error('版本 ' + version + ' 装不下 ' + bytes.length + ' 字节（上限 ' +
        byteCapacity(version) + '）');
    }

    var codewords = interleave(buildDataCodewords(version, bytes), version);

    var m = new Matrix(symbolSize(version));
    setupFinderPattern(m, version);
    setupTimingPattern(m);
    setupAlignmentPattern(m, version);
    setupFormatInfo(m, 0);          // 先占位，让掩码阶段知道这块是保留区
    if (version >= 7) setupVersionInfo(m, version);
    setupData(m, codewords);

    var mask = pickMask(m);
    applyMask(m, mask);
    setupFormatInfo(m, mask);       // 用最终掩码重写格式信息

    return { version: version, mask: mask, size: m.size, modules: m.modules };
  }

  var api = {
    encode: encode,
    byteCapacity: byteCapacity,
    maxBytes: function () { return byteCapacity(40); },
    symbolSize: symbolSize
  };

  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.LemonQR = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
