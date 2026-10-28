'use strict';

const crypto = require('node:crypto');
const { logger, runWithContext, instanceId } = require('../lib/logger');

// Every request gets an id (reused if the caller already sent one), and every line
// logged while it is handled carries that id, so one request can be followed across
// the Gateway and every service it reaches.

// Polled every few seconds by Compose and Service Discovery: logged at DEBUG so they
// do not bury real requests. A failed database check is still logged as an error.
const QUIET_PATHS = new Set(['/health', '/status']);

function completionLevel(status, quiet) {
  if (status >= 500) return 'error';
  if (status >= 400 && !quiet) return 'warn';
  return quiet ? 'debug' : 'info';
}

function requestContext(req, res, next) {
  req.requestId = req.get('X-Request-Id') || crypto.randomUUID();
  res.set('X-Request-Id', req.requestId);
  // The Gateway replaces it on forwarded responses; set here too so a direct call
  // (Service Discovery's health poll, a developer's curl) shows the replica as well.
  res.set('X-Instance-Id', instanceId);

  // Set by the Gateway from the authenticated token, never taken from the client.
  const ctx = { requestId: req.requestId };
  const callerType = req.get('X-Caller-Type');
  const playerId = req.get('X-Player-Id');
  if (callerType) ctx.callerType = callerType;
  if (playerId) ctx.playerId = playerId;

  const quiet = QUIET_PATHS.has(req.path);
  const startedAt = process.hrtime.bigint();
  const elapsedMs = () => Math.round(Number(process.hrtime.bigint() - startedAt) / 1e6);

  runWithContext(ctx, () => {
    logger[quiet ? 'debug' : 'info']({ method: req.method, path: req.path }, 'request received');

    // 'finish' and 'close' are emitted by the socket, outside this request's async
    // context, so the context is set again explicitly.
    res.on('finish', () => runWithContext(ctx, () => {
      const errorCode = res.locals.errorCode;
      logger[completionLevel(res.statusCode, quiet)]({
        method: req.method,
        path: req.path,
        status: res.statusCode,
        durationMs: elapsedMs(),
        ...(errorCode ? { error: errorCode } : {}),
      }, 'request completed');
    }));
    res.on('close', () => {
      if (res.writableFinished) return;
      runWithContext(ctx, () => {
        logger.warn(
          { method: req.method, path: req.path, durationMs: elapsedMs() },
          'client closed the connection before the response',
        );
      });
    });

    next();
  });
}

module.exports = { requestContext, QUIET_PATHS };
