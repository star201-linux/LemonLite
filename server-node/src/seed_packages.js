// server/src/seed_packages.js
//
// 把仓库 docs/ 下的示例小程序打成本地 zip 包，并回填 apps 表的
// package_sha256 / package_bytes。
//
// 用法（在 server/ 下）：
//   npm run seed:packages
//
// 为什么需要它：0.6 起客户端只认「下载 zip 再打开」，所以演示数据
// 必须真的有包可下。手工打包 + 手工算哈希 + 手工改数据库
// 三件事都容易错，而这个脚本一次做完。
//
// 它做的事：
//   1. 从 ../docs/{demo,apps/<slug>}/ 读文件
//   2. 打成一个 zip（**不压缩目录层级**，入口固定在根 index.html）
//   3. 写到 packages/<appId>/<version>.zip
//   4. 算 SHA-256，UPDATE apps 的对应字段

import { createHash } from 'node:crypto';
import { readdir, readFile, mkdir, writeFile, stat } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { join, relative, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { config, readEnvFile } from './config.js';
import { makeZip } from './lib/zip.js';
import { execute, pool, query } from './db.js';

readEnvFile();

const ROOT = dirname(dirname(fileURLToPath(import.meta.url))); // → server/
const DOCS = join(ROOT, '..', 'docs');

/** 演示应用 → docs 里的源目录 */
const SEEDS = [
  { appId: 'lemonlite.demo', src: join(DOCS, 'demo'), version: '1.0.0' },
  { appId: 'todo.lite', src: join(DOCS, 'apps', 'todo'), version: '1.0.0' },
  { appId: 'weather.lite', src: join(DOCS, 'apps', 'weather'), version: '1.0.0' },
  { appId: 'pomodoro.lite', src: join(DOCS, 'apps', 'pomodoro'), version: '1.0.0' },
  { appId: 'markdown.lite', src: join(DOCS, 'apps', 'markdown'), version: '1.0.0' },
  { appId: 'qrcode.lite', src: join(DOCS, 'apps', 'qrcode'), version: '1.0.0' },
  { appId: 'palette.lite', src: join(DOCS, 'apps', 'palette'), version: '1.0.0' },
  { appId: 'minigame.2048', src: join(DOCS, 'apps', '2048'), version: '1.0.0' },
];

/** 递归列出目录下的文件（相对路径） */
async function walk(dir, base = dir) {
  const out = [];
  for (const entry of await readdir(dir, { withFileTypes: true })) {
    const full = join(dir, entry.name);
    if (entry.isDirectory()) {
      out.push(...(await walk(full, base)));
    } else if (entry.isFile()) {
      out.push({ full, rel: relative(base, full).replaceAll('\\', '/') });
    }
  }
  return out;
}

// ---------------------------------------------------------------- 主流程

async function main() {
  let built = 0;
  let skipped = 0;

  for (const seed of SEEDS) {
    if (!existsSync(seed.src)) {
      console.log(`  ! 跳过 ${seed.appId}：源目录不存在（${seed.src}）`);
      skipped++;
      continue;
    }

    // 入口必须在根：docs/apps/todo/index.html → 包内 index.html
    const files = await walk(seed.src);
    const hasIndex = files.some((f) => f.rel === 'index.html');
    if (!hasIndex) {
      console.log(`  ! 跳过 ${seed.appId}：源目录里没有 index.html`);
      skipped++;
      continue;
    }

    const entries = [];
    for (const f of files) {
      entries.push({ name: f.rel, data: await readFile(f.full) });
    }
    entries.sort((a, b) => a.name.localeCompare(b.name));

    const zip = makeZip(entries);
    const sha256 = createHash('sha256').update(zip).digest('hex');

    const dir = join(config.root, config.packages.dir, seed.appId);
    await mkdir(dir, { recursive: true });
    const file = join(dir, `${seed.version}.zip`);
    await writeFile(file, zip);

    // 回填数据库（没有这一行就跳过，不报错 —— 可能还没 init）
    const updated = await execute(
      `UPDATE apps
          SET package_url = ?, package_entry = 'index.html',
              package_sha256 = ?, package_bytes = ?
        WHERE id = ?`,
      [`packages/${seed.appId}/${seed.version}.zip`, sha256, zip.length, seed.appId],
    );

    const st = await stat(file);
    console.log(
      `  ✓ ${seed.appId} v${seed.version}` +
        `  ${entries.length} 个文件 / ${(st.size / 1024).toFixed(1)} KB` +
        `  sha=${sha256.slice(0, 12)}…` +
        (updated.affectedRows === 0 ? '（⚠ 数据库里没有这个 appId，包已生成）' : ''),
    );
    built++;
  }

  console.log('');
  console.log(`完成：生成 ${built} 个包${skipped > 0 ? `，跳过 ${skipped} 个` : ''}`);
  console.log(`目录：${join(config.root, config.packages.dir)}`);

  const rows = await query(
    'SELECT id, version, package_bytes, package_sha256 FROM apps WHERE package_url IS NOT NULL',
  );
  console.log(`数据库里已带包的条目：${rows.length} 个`);

  await pool.end();
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
