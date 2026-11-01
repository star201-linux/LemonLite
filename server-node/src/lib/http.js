// server/src/lib/http.js
//
// 统一的响应格式与错误处理。
//
// 契约（客户端与服务端只认这一份）：
//   成功：{ "ok": true,  "data": ... ,  "meta": { ... }? }
//   失败：{ "ok": false, "error": { "code": "xxx", "message": "人话" } }
//
// 为什么用 ok 而不是裸数据：
//   裸数据无法区分「成功返回 null」和「失败了」—— 客户端得靠 HTTP 状态码
//   猜，而状态码在代理/CDN 那一层经常被改写。显式 ok 字段最稳。

/** 业务错误：抛它，由 errorHandler 统一转成 JSON */
export class ApiError extends Error {
  constructor(status, code, message, detail) {
    super(message);
    this.status = status;
    this.code = code;
    this.detail = detail;
  }

  static badRequest(code, message, detail) {
    return new ApiError(400, code, message, detail);
  }
  static unauthorized(message = '请先登录') {
    return new ApiError(401, 'unauthorized', message);
  }
  static forbidden(code, message) {
    return new ApiError(403, code, message);
  }
  static notFound(message = '资源不存在') {
    return new ApiError(404, 'not_found', message);
  }
  static conflict(code, message) {
    return new ApiError(409, code, message);
  }
  static tooLarge(message) {
    return new ApiError(413, 'payload_too_large', message);
  }
  static unavailable(message) {
    return new ApiError(503, 'unavailable', message);
  }
}

export function sendOk(res, data, meta) {
  const body = { ok: true, data };
  if (meta !== undefined) body.meta = meta;
  res.json(body);
}

/** 包住 async handler，让 reject 能进 Express 的错误链 */
export function wrap(handler) {
  return (req, res, next) => {
    Promise.resolve(handler(req, res, next)).catch(next);
  };
}

/** 全局错误处理：所有异常都变成同一种 JSON */
export function errorHandler(err, req, res, _next) {
  if (err instanceof ApiError) {
    if (err.detail !== undefined) {
      return res.status(err.status).json({
        ok: false,
        error: { code: err.code, message: err.message, detail: err.detail },
      });
    }
    return res
      .status(err.status)
      .json({ ok: false, error: { code: err.code, message: err.message } });
  }

  // MySQL 的常见错误翻译成人话，避免把 SQL 细节泄露给客户端
  if (err?.code === 'ER_DUP_ENTRY') {
    return res.status(409).json({
      ok: false,
      error: { code: 'duplicate', message: '这条记录已存在' },
    });
  }
  if (err?.code === 'ER_ACCESS_DENIED_ERROR') {
    console.error('[db] 认证失败，检查 .env 里的 DB_USER / DB_PASSWORD');
    return res.status(503).json({
      ok: false,
      error: { code: 'db_auth', message: '服务暂时不可用' },
    });
  }
  // multer 的错误：文件太大 / 字段不合法
  if (err?.code === 'LIMIT_FILE_SIZE') {
    return res.status(413).json({
      ok: false,
      error: { code: 'file_too_large', message: '文件太大' },
    });
  }
  if (err?.code === 'LIMIT_UNEXPECTED_FILE') {
    return res.status(400).json({
      ok: false,
      error: { code: 'bad_field', message: '上传字段名不正确（应为 file）' },
    });
  }

  if (err?.code === 'ECONNREFUSED' || err?.code === 'PROTOCOL_CONNECTION_LOST') {
    console.error('[db] 连接断开', err.code);
    return res.status(503).json({
      ok: false,
      error: { code: 'db_down', message: '数据库暂时不可用，请稍后再试' },
    });
  }

  // 兜底：**总是**记完整堆栈（服务端），但只回一句话（客户端）
  console.error('[500]', err);
  return res.status(500).json({
    ok: false,
    error: { code: 'internal', message: '服务器内部错误' },
  });
}

/** 404 兜底（放在所有路由之后） */
export function notFoundHandler(req, res) {
  res.status(404).json({
    ok: false,
    error: { code: 'not_found', message: `没有这个接口：${req.method} ${req.path}` },
  });
}
