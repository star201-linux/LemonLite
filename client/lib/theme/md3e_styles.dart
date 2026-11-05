// lib/theme/md3e_styles.dart
//
// 注入到每个小程序的 **MD3 Expressive 基础样式**。
//
// 为什么需要它：
//   小程序可以完全不写 CSS（一个只有 h1 / p / button 的 HTML）。
//   这时 WebView 会按浏览器默认样式渲染 —— 蓝紫色链接、灰色按钮、
//   16px 的旧式排版，和宿主明显的 MD3 界面完全不像同一个 App。
//   这份样式表给「没有自己写样式的原生元素」一套 MD3E 的外观：
//   大圆角、药丸按钮、层次分明的表面色、Expressive 的字重与字距。
//
// 为什么是元素选择器而不是 class：
//   页面作者没写 class。用 `button {}`、`input {}` 这种零/低优先级规则，
//   页面自己的 `.my-btn {}` / `body {}` 永远能覆盖它 —— 我们只做兜底。
//   真正的主题色仍然来自 `--md-*` 变量（由 ThemeInjector 注入），
//   所以浅色/深色/动态壁纸色都会自动跟随。
//
// 参考：Material 3 Expressive（m3.material.io）—— 形状层级、字重对比、
// 药丸按钮、容器色与表面色的搭配，都在下面这些规则里。

import 'dart:convert';

class Md3eStyles {
  const Md3eStyles._();

  /// 注入用的 `<style>` 内容。
  ///
  /// 只使用元素选择器 / `:where()`（零优先级），不碰页面自己的 class/id。
  static const String css = r'''
/* LemonLite · MD3 Expressive base styles
 * 只在页面没有自己的样式时生效；任何页面 CSS 都能覆盖它。
 */
:root {
  /* 形状层级：Expressive 用更大的圆角表达层级 */
  --md3e-radius-xs: 8px;
  --md3e-radius-sm: 12px;
  --md3e-radius-md: 16px;
  --md3e-radius-lg: 24px;
  --md3e-radius-xl: 28px;
  --md3e-radius-full: 999px;

  /* 字体：Android 自带 Roboto；中文回落到 Noto Sans SC / 系统字体 */
  --md3e-font: "Roboto", "Noto Sans SC", "Noto Sans", "PingFang SC",
    system-ui, -apple-system, "Segoe UI", sans-serif;
  --md3e-font-mono: "Roboto Mono", "JetBrains Mono", ui-monospace,
    "SFMono-Regular", Menlo, Consolas, monospace;

  /* 动效：M3 的 emphasized / spring 曲线 */
  --md3e-ease-emphasized: cubic-bezier(0.05, 0.7, 0.1, 1);
  --md3e-ease-spring: cubic-bezier(0.2, 0, 0, 1);
  --md3e-duration-fast: 120ms;
  --md3e-duration: 220ms;
}

html {
  color-scheme: light dark;
  background: var(--md-surface, #fef7ff);
  -webkit-text-size-adjust: 100%;
}

html[data-md-brightness="dark"] {
  color-scheme: dark;
}

:where(body) {
  margin: 0;
  min-height: 100%;
  background: var(--md-surface, #fef7ff);
  color: var(--md-on-surface, #1d1b20);
  font: 400 16px/1.5 var(--md3e-font);
  -webkit-font-smoothing: antialiased;
  -moz-osx-font-smoothing: grayscale;
  text-rendering: optimizeLegibility;
  overflow-wrap: break-word;
}

/* ---------------------------------------------------------------- 排版 */

:where(h1, h2, h3, h4, h5, h6) {
  color: var(--md-on-surface, #1d1b20);
  font-family: var(--md3e-font);
  font-weight: 600;
  letter-spacing: -0.015em;
  margin: 0 0 0.5em;
  text-wrap: balance;
}

:where(h1) {
  font-size: clamp(2rem, 6.5vw, 2.75rem);
  line-height: 1.12;
  letter-spacing: -0.02em;
}

:where(h2) {
  font-size: clamp(1.5rem, 5vw, 2rem);
  line-height: 1.18;
}

:where(h3) {
  font-size: 1.5rem;
  line-height: 1.25;
}

:where(h4) {
  font-size: 1.25rem;
  line-height: 1.3;
}

:where(h5) {
  font-size: 1.125rem;
  line-height: 1.35;
}

:where(h6) {
  font-size: 1rem;
  line-height: 1.4;
  font-weight: 500;
}

:where(p) {
  margin: 0 0 1em;
}

:where(p, li, dd, dt, figcaption, label, legend) {
  font-size: 1rem;
  line-height: 1.55;
}

:where(small, .md3e-supporting-text) {
  font-size: 0.875rem;
  line-height: 1.45;
  color: var(--md-on-surface-variant, #49454f);
}

:where(strong, b) {
  font-weight: 600;
}

:where(ul, ol) {
  margin: 0 0 1em;
  padding-left: 1.5em;
}

:where(li) {
  margin: 0.25em 0;
}

:where(ul li)::marker,
:where(ol li)::marker {
  color: var(--md-primary, #6750a4);
}

:where(a) {
  color: var(--md-primary, #6750a4);
  text-decoration: underline;
  text-decoration-thickness: 1px;
  text-underline-offset: 0.18em;
  -webkit-tap-highlight-color: transparent;
}

:where(a:active) {
  opacity: 0.75;
}

:where(mark) {
  background: var(--md-tertiary-container, #ffd8e4);
  color: var(--md-on-tertiary-container, #31111d);
  border-radius: var(--md3e-radius-xs);
  padding: 0 0.15em;
}

:where(abbr[title]) {
  text-decoration: underline dotted;
  cursor: help;
}

/* ---------------------------------------------------------------- 按钮 */

:where(button, input[type="button"], input[type="submit"], input[type="reset"]) {
  appearance: none;
  -webkit-appearance: none;
  box-sizing: border-box;
  min-height: 40px;
  padding: 0 24px;
  border: 0;
  border-radius: var(--md3e-radius-full);
  background: var(--md-primary, #6750a4);
  color: var(--md-on-primary, #ffffff);
  font: 500 14px/20px var(--md3e-font);
  letter-spacing: 0.1px;
  cursor: pointer;
  touch-action: manipulation;
  -webkit-tap-highlight-color: transparent;
  box-shadow: 0 1px 2px rgba(0, 0, 0, 0.18);
  transition:
    transform var(--md3e-duration-fast) var(--md3e-ease-spring),
    box-shadow var(--md3e-duration) var(--md3e-ease-emphasized),
    background-color var(--md3e-duration) var(--md3e-ease-emphasized);
}

:where(button:active, input[type="button"]:active, input[type="submit"]:active, input[type="reset"]:active) {
  transform: scale(0.97);
}

:where(button:disabled, input[type="button"]:disabled, input[type="submit"]:disabled, input[type="reset"]:disabled) {
  opacity: 0.38;
  cursor: not-allowed;
  box-shadow: none;
  transform: none;
}

/* 文件选择按钮（伪元素不能放进 :where 列表里） */
::file-selector-button {
  appearance: none;
  -webkit-appearance: none;
  margin-right: 10px;
  padding: 8px 16px;
  border: 0;
  border-radius: var(--md3e-radius-full);
  background: var(--md-secondary-container, #e8def8);
  color: var(--md-on-secondary-container, #1d192b);
  font: 500 14px/20px var(--md3e-font);
  cursor: pointer;
}

/* 变体：在按钮上加 data-variant 即可（不影响未标记的默认 Filled 按钮） */
:where(button[data-variant="tonal"]) {
  background: var(--md-secondary-container, #e8def8);
  color: var(--md-on-secondary-container, #1d192b);
  box-shadow: none;
}

:where(button[data-variant="outlined"]) {
  background: transparent;
  color: var(--md-primary, #6750a4);
  border: 1px solid var(--md-outline, #79747e);
  box-shadow: none;
}

:where(button[data-variant="text"]) {
  background: transparent;
  color: var(--md-primary, #6750a4);
  padding: 0 12px;
  box-shadow: none;
}

:where(button[data-variant="danger"], button.danger) {
  background: var(--md-error, #b3261e);
  color: var(--md-on-error, #ffffff);
}

@media (hover: hover) {
  :where(button:hover, input[type="button"]:hover, input[type="submit"]:hover) {
    box-shadow: 0 2px 6px rgba(0, 0, 0, 0.22);
  }
}

/* ---------------------------------------------------------------- 表单 */

:where(input:not([type="checkbox"]):not([type="radio"]):not([type="range"]):not([type="file"]), textarea, select) {
  box-sizing: border-box;
  width: 100%;
  min-height: 56px;
  padding: 16px;
  border: 1px solid var(--md-outline, #79747e);
  border-radius: var(--md3e-radius-sm) var(--md3e-radius-sm) var(--md3e-radius-xs) var(--md3e-radius-xs);
  background: var(--md-surface-container-highest, #e6e0e9);
  color: var(--md-on-surface, #1d1b20);
  font: 400 16px/24px var(--md3e-font);
  transition:
    border-color var(--md3e-duration) var(--md3e-ease-emphasized),
    box-shadow var(--md3e-duration) var(--md3e-ease-emphasized);
}

:where(textarea) {
  min-height: 120px;
  resize: vertical;
}

input::placeholder,
textarea::placeholder {
  color: var(--md-on-surface-variant, #49454f);
  opacity: 1;
}

:where(input:focus-visible, textarea:focus-visible, select:focus-visible, button:focus-visible, a:focus-visible) {
  outline: 3px solid var(--md-primary, #6750a4);
  outline-offset: 2px;
}

:where(input[type="checkbox"], input[type="radio"]) {
  width: 18px;
  height: 18px;
  accent-color: var(--md-primary, #6750a4);
  vertical-align: -2px;
}

:where(input[type="range"], progress) {
  accent-color: var(--md-primary, #6750a4);
}

:where(label, legend) {
  font-weight: 500;
  color: var(--md-on-surface, #1d1b20);
}

:where(fieldset) {
  border: 1px solid var(--md-outline-variant, #cac4d0);
  border-radius: var(--md3e-radius-md);
  padding: 16px;
  margin: 0 0 16px;
}

/* -------------------------------------------------------------- 内容块 */

:where(hr) {
  border: 0;
  border-top: 1px solid var(--md-outline-variant, #cac4d0);
  margin: 24px 0;
}

:where(blockquote) {
  margin: 16px 0;
  padding: 12px 16px;
  border-left: 4px solid var(--md-primary, #6750a4);
  border-radius: 0 var(--md3e-radius-sm) var(--md3e-radius-sm) 0;
  background: var(--md-surface-container, #f3edf7);
  color: var(--md-on-surface-variant, #49454f);
}

:where(code, kbd, samp) {
  font-family: var(--md3e-font-mono);
  font-size: 0.9em;
  background: var(--md-surface-container-highest, #e6e0e9);
  color: var(--md-on-surface, #1d1b20);
  border-radius: var(--md3e-radius-xs);
  padding: 0.12em 0.4em;
}

:where(pre) {
  font-family: var(--md3e-font-mono);
  font-size: 0.875rem;
  line-height: 1.55;
  background: var(--md-surface-container-highest, #e6e0e9);
  color: var(--md-on-surface, #1d1b20);
  border-radius: var(--md3e-radius-md);
  padding: 16px;
  overflow: auto;
  margin: 0 0 1em;
}

:where(pre code) {
  background: transparent;
  padding: 0;
  border-radius: 0;
}

:where(table) {
  width: 100%;
  border-collapse: separate;
  border-spacing: 0;
  border: 1px solid var(--md-outline-variant, #cac4d0);
  border-radius: var(--md3e-radius-md);
  overflow: hidden;
  margin: 0 0 1em;
  font-size: 0.9375rem;
}

:where(th, td) {
  padding: 12px 16px;
  text-align: left;
  border-bottom: 1px solid var(--md-outline-variant, #cac4d0);
}

:where(th) {
  background: var(--md-surface-container-high, #ece6f0);
  color: var(--md-on-surface, #1d1b20);
  font-weight: 600;
}

:where(tr:last-child td) {
  border-bottom: 0;
}

:where(img, video, canvas, svg) {
  max-width: 100%;
  height: auto;
}

:where(img, video) {
  border-radius: var(--md3e-radius-md);
}

:where(figure) {
  margin: 0 0 1em;
}

:where(figcaption) {
  color: var(--md-on-surface-variant, #49454f);
  font-size: 0.875rem;
  margin-top: 8px;
  text-align: center;
}

:where(details) {
  background: var(--md-surface-container, #f3edf7);
  border-radius: var(--md3e-radius-md);
  padding: 12px 16px;
  margin: 0 0 1em;
}

:where(summary) {
  cursor: pointer;
  font-weight: 500;
  color: var(--md-on-surface, #1d1b20);
}

:where(dialog) {
  border: 0;
  border-radius: var(--md3e-radius-xl);
  padding: 24px;
  background: var(--md-surface-container-high, #ece6f0);
  color: var(--md-on-surface, #1d1b20);
  box-shadow: 0 8px 24px rgba(0, 0, 0, 0.24);
  max-width: min(560px, calc(100vw - 48px));
}

dialog::backdrop {
  background: rgba(0, 0, 0, 0.35);
}

/* M3E 常用组件类（可选用，页面不写 class 时会自然用上面的元素样式） */
.md3e-card {
  background: var(--md-surface-container, #f3edf7);
  color: var(--md-on-surface, #1d1b20);
  border-radius: var(--md3e-radius-lg);
  padding: 16px;
  margin: 0 0 12px;
}

.md3e-chip {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  min-height: 32px;
  padding: 0 12px;
  border-radius: var(--md3e-radius-xs);
  background: var(--md-surface-container-high, #ece6f0);
  color: var(--md-on-surface-variant, #49454f);
  font: 500 14px/20px var(--md3e-font);
}

.md3e-fab {
  position: fixed;
  right: 16px;
  bottom: calc(16px + env(safe-area-inset-bottom, 0px));
  width: 56px;
  height: 56px;
  border-radius: var(--md3e-radius-lg);
  background: var(--md-primary-container, #eaddff);
  color: var(--md-on-primary-container, #21005d);
  display: inline-flex;
  align-items: center;
  justify-content: center;
  box-shadow: 0 4px 12px rgba(0, 0, 0, 0.24);
}

/* 选中文字用主题色，而不是浏览器默认的蓝 */
::selection {
  background: var(--md-primary, #6750a4);
  color: var(--md-on-primary, #ffffff);
}

/* 系统开了「减少动态效果」时不要和用户对着干 */
@media (prefers-reduced-motion: reduce) {
  *,
  *::before,
  *::after {
    animation-duration: 0.01ms !important;
    animation-iteration-count: 1 !important;
    transition-duration: 0.01ms !important;
    scroll-behavior: auto !important;
  }
}
''';

  /// document-start 注入脚本：把上面的样式表插到 `<head>` 的最前面。
  ///
  /// 为什么先插到 head 的第一位而不是最后：
  ///   页面自己的 `<style>` 在 DOM 顺序上排在我们后面，同优先级时由它覆盖；
  ///   反过来（插到最后）反而会让「页面写了 body 颜色」被我们的兜底色盖住。
  ///
  /// document-start 时 `<head>` 可能还没被解析出来：这时退回
  /// `documentElement`，样式依旧会生效（style 元素放在 html 下也参与层叠）；
  /// 再兜底一个 DOMContentLoaded，防止极端 WebView 版本下样式元素丢失。
  static String buildInjectScript() =>
      '''
(function () {
  if (window.__LEMONLITE_MD3E__) { return; }
  window.__LEMONLITE_MD3E__ = true;
  var css = ${jsonEncode(css)};
  function inject() {
    if (document.getElementById('lemonlite-md3e')) { return true; }
    var target = document.head || document.documentElement;
    if (!target) { return false; }
    var style = document.createElement('style');
    style.id = 'lemonlite-md3e';
    style.setAttribute('data-lemonlite', 'md3e');
    style.textContent = css;
    target.insertBefore(style, target.firstChild);
    return true;
  }
  if (!inject()) {
    document.addEventListener('DOMContentLoaded', inject, { once: true });
  }
})();
''';
}
