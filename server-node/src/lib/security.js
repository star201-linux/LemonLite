// server/src/lib/security.js
//
// 生产环境的几件小事，单独放一处：
//   * 安全响应头（不引 helmet：这点量不值得多一个依赖）
//   * 内存限流（单实例够用；多实例请换成 Redis 或交给网关）
//   * 请求 ID（排障时把一条日志和一条客户端报错对上）
//
// 限流刻意做成「按窗口计数」而不是令牌桶：实现小、行为可预测，
// 被限时能明确告诉客户端多久后重试（Retry-After）。

/**
 * 基础安全响应头。
 *
 * 不开 CSP：管理面板用的是内联脚本与内联样式，一刀切的 CSP 会把它打坏；
 * 真需要 CSP 时应该在反向代理层按路径分别配置。
 */
export function securityHeaders(req, res, next) {
  res.setHeader('X-Content-Type-Options', 'nosniff');
  res.setHeader('X-Frame-Options', 'SAMEORIGIN');
  res.setHeader('Referrer-Policy', 'no-referrer');
  res.setHeader('X-DNS-Prefetch-Control', 'off');
  res.setHeader('Permissions-Policy', 'camera=(), microphone=(), geolocation=()');
  // 图标要给原生客户端跨源取用，这里显式放开；其余资源同样不靠这个头防护
  res.setHeader('Cross-Origin-Resource-Policy', 'cross-origin');

  // HSTS 只在确实走 HTTPS 时下发：在 HTTP 上下发会被浏览器直接忽略，
  // 而在反代没配好时下发会把用户锁死在错误配置上。
  if (req.secure) {
    res.setHeader(
      'Strict-Transport-Security',
      'max-age=31536000; includeSubDomains',
    );
  }
  next();
}

/**
 * 每个响应带一个请求 ID。
 *
 * 客户端报错时把 ID 发过来，就能在日志里精确定位那一条 ——
 * 比「大概是十分钟前那次」有效得多。
 */
export function requestId(req, res, next) {
  const incoming = req.get('x-request-id');
  const id =
    incoming && incoming.length <= 64
      ? incoming
      : `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 10)}`;
  req.id = id;
  res.setHeader('X-Request-Id', id);
  next();
}

/**
 * 固定窗口限流。
 *
 * @param {object} options
 * @param {number} options.windowMs 窗口长度
 * @param {number} options.max 窗口内允许的请求数
 * @param {string} [options.message] 被限时的提示
 * @param {(req: import('express').Request) => string} [options.key] 计数维度
 */
export function rateLimit({ windowMs, max, message, key }) {
  /** @type {Map<string, {count: number, resetAt: number}>} */
  const buckets = new Map();

  // 定期清理过期 bucket，避免被大量一次性 IP 撑爆内存。
  // unref 让它不阻止进程退出（容器里 SIGTERM 时能正常关）。
  const sweeper = setInterval(() => {
    const now = Date.now();
    for (const [k, v] of buckets) {
      if (v.resetAt <= now) buckets.delete(k);
    }
  }, Math.max(windowMs, 60_000));
  if (typeof sweeper.unref === 'function') sweeper.unref();

  return function rateLimitMiddleware(req, res, next) {
    const bucketKey = key ? key(req) : req.ip || 'unknown';
    const now = Date.now();
    let bucket = buckets.get(bucketKey);
    if (!bucket || bucket.resetAt <= now) {
      bucket = { count: 0, resetAt: now + windowMs };
      buckets.set(bucketKey, bucket);
    }
    bucket.count += 1;

    if (bucket.count > max) {
      const retryAfter = Math.max(1, Math.ceil((bucket.resetAt - now) / 1000));
      res.setHeader('Retry-After', String(retryAfter));
      return res.status(429).json({
        ok: false,
        error: {
          code: 'rate_limited',
          message: message || '请求太频繁，请稍后再试',
          retryAfter,
        },
      });
    }
    next();
  };
}

/**
 * 启动时检查那些「能跑但危险」的配置，把话说在前面。
 *
 * 不抛错：这些不是启动失败的理由（本地开发经常就是这样），
 * 但生产环境看到这几行黄字应该立刻去改。
 */
export function describeInsecureConfig(config) {
  const warnings = [];
  if (!config.db.password) {
    warnings.push('DB_PASSWORD 为空：数据库账号没有密码，生产环境必须设置');
  }
  if (process.env.NODE_ENV === 'production') {
    if (!process.env.CORS_ORIGIN) {
      warnings.push('CORS_ORIGIN 未设置：生产环境建议限定来源，而不是放行全部');
    }
    if ((process.env.MAIL_DRIVER || '').toLowerCase() === 'console') {
      warnings.push('MAIL_DRIVER=console：验证码会打进日志，生产环境请换成真实通道');
    }
  }
  return warnings;
}
