// server/src/admin/settings.js
//
// 面板的「站点」页：几条影响**所有用户**的策略。
//
// 为什么单独一页而不是继续塞进「邮件」：邮件页的语义是「信从哪发出去」，
// 而这里的东西（注销冷静期、市场每页条数）跟邮件没有关系。
// 混在一起的结果是运维要找一个「市场分页」的设置得先想到去点「邮件」。
//
// 所有值都写回 config.yaml 并立即应用到内存，不需要重启（同 admin/mail.js）。

import { Router } from 'express';
import { join } from 'node:path';
import { config } from '../config.js';
import { sendOk, wrap } from '../lib/http.js';
import { updateConfigFile } from '../lib/configfile.js';
import { intIn } from './shared.js';

export const settingsRouter = Router();

const CONFIG_PATH = join(config.root, 'config.yaml');

function siteSnapshot() {
  return {
    // 客户端申请注销后的冷静期（天），0 = 立即删除
    deleteDelayDays: config.account.deleteDelayDays,
    // 到期账号的扫描间隔（分钟），0 = 只靠启动时与 npm run prune
    purgeIntervalMinutes: config.account.purgeIntervalMinutes,
    // 市场每页条数（客户端不传 limit 时用它）
    marketPageSize: config.market.defaultPageSize,
    // 客户端能请求的最大条数
    marketMaxPage: config.market.maxPageSize,
  };
}

settingsRouter.get('/api/site', (_req, res) => {
  sendOk(res, siteSnapshot());
});

settingsRouter.put(
  '/api/site',
  wrap(async (req, res) => {
    const body = req.body ?? {};

    const deleteDelayDays = intIn(
      body.deleteDelayDays,
      config.account.deleteDelayDays,
      0,
      365,
    );
    const purgeIntervalMinutes = intIn(
      body.purgeIntervalMinutes,
      config.account.purgeIntervalMinutes,
      0,
      24 * 60,
    );
    const marketMaxPage = intIn(body.marketMaxPage, config.market.maxPageSize, 5, 200);
    // 每页条数不能超过上限，否则「默认值」本身就会请求一个被夹掉的数，
    // 客户端 meta.limit 与实际条数对不上。
    // 超出时**夹住而不是报错**：面板保存后会把夹过的值回读出来，
    // 用户看到 5 就明白发生了什么；报错则要先改上限再改条数，两步都卡着。
    const marketPageSize = Math.min(
      marketMaxPage,
      intIn(body.marketPageSize, config.market.defaultPageSize, 5, 200),
    );

    // 写回 config.yaml（保留文件里的人工注释），再改内存里的 config。
    // 两件事都要做：只改内存 → 重启就回退；只改文件 → 本次运行还是旧值。
    updateConfigFile(CONFIG_PATH, {
      'account.deleteDelayDays': deleteDelayDays,
      'account.purgeIntervalMinutes': purgeIntervalMinutes,
      'market.defaultPageSize': marketPageSize,
      'market.maxPageSize': marketMaxPage,
    });

    // 立即生效
    config.account.deleteDelayDays = deleteDelayDays;
    config.account.purgeIntervalMinutes = purgeIntervalMinutes;
    config.market.defaultPageSize = marketPageSize;
    config.market.maxPageSize = marketMaxPage;

    sendOk(res, { saved: true, site: siteSnapshot() });
  }),
);
