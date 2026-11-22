
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
