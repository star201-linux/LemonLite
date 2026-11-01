/* ============================================================================
 * color.js —— 配色实验室的纯计算层（无 DOM 依赖，可在 node 里直接单测）
 * ----------------------------------------------------------------------------
 * 关于「Material 3 色调板」这件事，先把话说清楚：
 *
 *   真正的 M3 色调板（tonal palette）是在 **HCT** 色彩空间里生成的 ——
 *   HCT = CAM16 的色相/彩度 + CIELAB 的 L*（作为 tone）。tone 40 之所以是
 *   那个蓝，是因为它满足 L* = 40，而这需要求解 CAM16 的正/反向变换。
 *
 *   这个文件没有实现 CAM16。它做的是**折中**：
 *     - tone 的语义按规范来 —— 它就是 CIELAB 的 L*，先换算成相对亮度 Y；
 *     - 再二分反解 HSL 的 lightness，让生成色的实际相对亮度等于这个 Y。
 *   也就是说，「这一档有多亮」是准的（因为按亮度定义求解），只有「色相/彩度
 *   怎么随 tone 变化」是近似的（真正的 M3 会在 HCT 里保持 chroma）。
 *
 *   一个直观的对比：早期版本直接把 tone 当 HSL lightness，结果 #00696d 的
 *   primary（tone 40）上放白字只有 2.38:1，不达标。改成按 L* 求解后是 6.4:1。
 *   ——「看起来像 M3」和「按 M3 的定义算」是两回事，这里选后者。
 *
 *   仍然不是规范值：别拿它去和 Material Theme Builder 对答案。
 * ==========================================================================*/
(function (global) {
  'use strict';

  function clamp(v, min, max) { return v < min ? min : (v > max ? max : v); }

  /* ------------------------------- 基础转换 ------------------------------- */

  function normalizeHex(hex) {
    var s = String(hex).trim().replace(/^#/, '');
    if (/^[0-9a-fA-F]{3}$/.test(s)) {
      s = s[0] + s[0] + s[1] + s[1] + s[2] + s[2];
    }
    if (!/^[0-9a-fA-F]{6}$/.test(s)) return null;
    return '#' + s.toLowerCase();
  }

  function hexToRgb(hex) {
    var h = normalizeHex(hex);
    if (!h) return null;
    return {
      r: parseInt(h.slice(1, 3), 16),
      g: parseInt(h.slice(3, 5), 16),
      b: parseInt(h.slice(5, 7), 16)
    };
  }

  function rgbToHex(r, g, b) {
    function part(v) {
      var s = clamp(Math.round(v), 0, 255).toString(16);
      return s.length === 1 ? '0' + s : s;
    }
    return '#' + part(r) + part(g) + part(b);
  }

  function rgbToHsl(r, g, b) {
    r /= 255; g /= 255; b /= 255;
    var max = Math.max(r, g, b);
    var min = Math.min(r, g, b);
    var l = (max + min) / 2;
    var h = 0;
    var s = 0;

    if (max !== min) {
      var d = max - min;
      s = l > 0.5 ? d / (2 - max - min) : d / (max + min);
      if (max === r) h = ((g - b) / d + (g < b ? 6 : 0));
      else if (max === g) h = (b - r) / d + 2;
      else h = (r - g) / d + 4;
      h /= 6;
    }
    return { h: h, s: s, l: l };
  }

  function hslToRgb(h, s, l) {
    h = ((h % 1) + 1) % 1;
    s = clamp(s, 0, 1);
    l = clamp(l, 0, 1);

    if (s === 0) {
      var v = Math.round(l * 255);
      return { r: v, g: v, b: v };
    }

    var q = l < 0.5 ? l * (1 + s) : l + s - l * s;
    var p = 2 * l - q;

    function hue(t) {
      if (t < 0) t += 1;
      if (t > 1) t -= 1;
      if (t < 1 / 6) return p + (q - p) * 6 * t;
      if (t < 1 / 2) return q;
      if (t < 2 / 3) return p + (q - p) * (2 / 3 - t) * 6;
      return p;
    }

    return {
      r: Math.round(hue(h + 1 / 3) * 255),
      g: Math.round(hue(h) * 255),
      b: Math.round(hue(h - 1 / 3) * 255)
    };
  }

  /* ------------------------------- 对比度 ------------------------------- */

  function relativeLuminance(rgb) {
    function channel(v) {
      v /= 255;
      return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4);
    }
    return 0.2126 * channel(rgb.r) + 0.7152 * channel(rgb.g) + 0.0722 * channel(rgb.b);
  }

  /** WCAG 对比度，1 ~ 21。 */
  function contrastRatio(hexA, hexB) {
    var a = hexToRgb(hexA);
    var b = hexToRgb(hexB);
    if (!a || !b) return 0;
    var la = relativeLuminance(a);
    var lb = relativeLuminance(b);
    var hi = Math.max(la, lb);
    var lo = Math.min(la, lb);
    return (hi + 0.05) / (lo + 0.05);
  }

  /** 在这块颜色上该用黑字还是白字 —— 取对比度更高的那个。 */
  function bestOn(hex) {
    return contrastRatio(hex, '#ffffff') >= contrastRatio(hex, '#000000') ? '#ffffff' : '#000000';
  }

  /* ------------------------------- 色调板 ------------------------------- */

  /** 色调刻度，和 M3 常用的那几档对齐。 */
  var TONES = [0, 10, 20, 30, 40, 50, 60, 70, 80, 90, 95, 99, 100];

  /**
   * CIELAB 的 L* → 相对亮度 Y（D65 标准白）。
   * 这就是 M3 里 tone 的定义 —— tone 40 意味着 L* = 40。
   */
  function luminanceForTone(tone) {
    return tone > 8
      ? Math.pow((tone + 16) / 116, 3)
      : tone / 903.3;
  }

  /**
   * 在固定色相/饱和度下，二分找出让相对亮度等于目标 Y 的 HSL lightness。
   *
   * 为什么要二分而不是套公式：HSL lightness 和相对亮度不是线性关系，
   * 而且关系随色相变化（同样是 L=0.5，黄色比蓝色亮得多）。30 次迭代足够
   * 收敛到 1e-6 以内，比推导一个解析解省事得多。
   */
  function lightnessForTone(h, s, tone) {
    var target = luminanceForTone(tone);
    var lo = 0;
    var hi = 1;

    for (var i = 0; i < 30; i++) {
      var mid = (lo + hi) / 2;
      if (relativeLuminance(hslToRgb(h, s, mid)) < target) lo = mid;
      else hi = mid;
    }
    return (lo + hi) / 2;
  }

  /**
   * 生成色调板。
   * @param {string} seed 种子色 #rrggbb
   * @param {number[]} [tones] 自定义刻度
   * @return {Array<{tone:number, hex:string, on:string}>}
   */
  function tonalRamp(seed, tones) {
    var rgb = hexToRgb(seed);
    if (!rgb) return [];

    var hsl = rgbToHsl(rgb.r, rgb.g, rgb.b);
    var list = tones || TONES;

    return list.map(function (tone) {
      // 两端收饱和度：tone 0 是纯黑、tone 100 是纯白，中间的色相才立得住。
      // 0.55 这个系数是调出来的 —— 太大色板会发灰，太小高色调会脏。
      var s = hsl.s * (1 - Math.abs(tone - 50) / 50 * 0.55);
      var out = hslToRgb(hsl.h, s, lightnessForTone(hsl.h, s, tone));
      var hex = rgbToHex(out.r, out.g, out.b);
      return { tone: tone, hex: hex, on: bestOn(hex) };
    });
  }

  /**
   * 从种子色拼一套「够用」的 MD3 风格配色角色。
   *
   * 同样是近似：真实的 M3 会用固定 tone + 色相微调（primary 的色相会被
   * 旋转到 tone 40 下最接近的色相）来保证对比度达标。这里直接按 tone 取，
   * 对比度可能达不到 WCAG AA —— 页面上会把实际对比度算出来标给你看。
   */
  function schemeFromSeed(seed) {
    var ramp = tonalRamp(seed);
    var byTone = {};
    ramp.forEach(function (item) { byTone[item.tone] = item.hex; });

    return {
      primary: byTone[40],
      onPrimary: byTone[100],
      primaryContainer: byTone[90],
      onPrimaryContainer: byTone[10],
      secondaryContainer: byTone[90],
      onSecondaryContainer: byTone[10],
      surface: byTone[99],
      onSurface: byTone[10],
      surfaceContainer: byTone[95],
      outline: byTone[50]
    };
  }

  /** 把配色角色拼成可直接粘贴的 CSS 变量文本。 */
  function toCssVariables(seed) {
    var scheme = schemeFromSeed(seed);
    var lines = Object.keys(scheme).map(function (role) {
      var kebab = role.replace(/[A-Z]/g, function (m) { return '-' + m.toLowerCase(); });
      return '  --md-' + kebab + ': ' + scheme[role] + ';';
    });
    return '/* 由配色实验室从种子色 ' + normalizeHex(seed) + ' 生成（HSL 近似，非规范 M3 色调板） */\n' +
      ':root {\n' + lines.join('\n') + '\n}';
  }

  var api = {
    normalizeHex: normalizeHex,
    hexToRgb: hexToRgb,
    rgbToHex: rgbToHex,
    rgbToHsl: rgbToHsl,
    hslToRgb: hslToRgb,
    contrastRatio: contrastRatio,
    bestOn: bestOn,
    luminanceForTone: luminanceForTone,
    lightnessForTone: lightnessForTone,
    tonalRamp: tonalRamp,
    schemeFromSeed: schemeFromSeed,
    toCssVariables: toCssVariables,
    TONES: TONES
  };

  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.LemonColor = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
