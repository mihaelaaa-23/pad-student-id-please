'use strict';

// The gRPC server of a service (Lab 4, grade 8): the RPCs other services call through the
// Message Broker, and `events.v1.EventSink/Deliver` for the topics it subscribes to.
//
// Every handler is wrapped with what the REST stack does around an Express route:
//   - the request context from metadata (x-request-id, x-caller-type), so every line the
//     handler logs carries the requestId, and the same id can be followed across hops;
//   - `grpc request received` / `grpc request completed` with method, grpcCode, durationMs;
//   - the concurrency limit (RESOURCE_EXHAUSTED + CONCURRENCY_LIMIT_REACHED, like the 503);
//   - a task timeout (DEADLINE_EXCEEDED + TASK_TIMEOUT, like the 504), never longer than
//     what is left of the caller's deadline;
//   - x-instance-id in the trailing metadata of every answer, like X-Instance-Id over HTTP.
//
// No token check here: the Broker checks the service token and does not forward
// `authorization` (contract, "Metadata"), and the gRPC port is not published to the host.

const crypto = require('node:crypto');
const grpc = require('@grpc/grpc-js');
const { logger, runWithContext, instanceId } = require('../lib/logger');
const { grpcError, statusName } = require('./errors');

const { status } = grpc;

function first(metadata, key) {
  const values = metadata.get(key);
  return values.length ? String(values[0]) : undefined;
}

function completionLevel(code) {
  if (code === status.OK) return 'info';
  if ([status.NOT_FOUND, status.INVALID_ARGUMENT, status.ALREADY_EXISTS, status.FAILED_PRECONDITION].includes(code)) return 'warn';
  return 'error';
}

/** Milliseconds left until the caller's deadline, or Infinity when it set none. */
function remainingMs(call, now = Date.now()) {
  const deadline = call.getDeadline();
  if (deadline instanceof Date) return deadline.getTime() - now;
  return Number.isFinite(deadline) ? deadline - now : Infinity;
}

/**
 * Wraps `handler(request, { metadata, signal })`, an async function that returns the
 * response message or throws `grpcError(code, message)`. Any other error is answered
 * INTERNAL with a generic message and logged with its stack.
 */
function wrapUnary(method, handler, { taskTimeoutMs, limiter, log = logger }) {
  return (call, callback) => {
    const requestId = first(call.metadata, 'x-request-id') || crypto.randomUUID();
    const ctx = { requestId };
    const callerType = first(call.metadata, 'x-caller-type');
    if (callerType) ctx.callerType = callerType;

    runWithContext(ctx, () => {
      const startedAt = process.hrtime.bigint();
      let answered = false;
      let release = null;
      let timer = null;
      const controller = new AbortController();

      const answer = (err, response) => {
        if (answered) return;
        answered = true;
        clearTimeout(timer);
        if (release) release();
        const trailer = new grpc.Metadata();
        trailer.set('x-instance-id', instanceId);
        const code = err ? err.code : status.OK;
        log[completionLevel(code)]({
          method,
          grpcCode: statusName(code),
          durationMs: Math.round(Number(process.hrtime.bigint() - startedAt) / 1e6),
          ...(err ? { error: err.teamCode } : {}),
        }, 'grpc request completed');
        if (err) {
          const metadata = err.metadata || new grpc.Metadata();
          metadata.merge(trailer);
          callback({ code: err.code, details: err.details || err.message, metadata });
        } else {
          callback(null, response, trailer);
        }
      };

      log.info({ method }, 'grpc request received');

      if (limiter && !limiter.tryAcquire()) {
        answer(grpcError('CONCURRENCY_LIMIT_REACHED', 'Too many requests in progress, retry shortly'));
        return;
      }
      if (limiter) release = () => limiter.release();

      // The task timeout, cut to what the caller can still wait for: past its deadline
      // nobody reads the answer.
      const budget = Math.min(taskTimeoutMs ?? Infinity, remainingMs(call));
      if (budget <= 0) {
        answer(grpcError('TASK_TIMEOUT', 'The caller\'s deadline had already passed'));
        return;
      }
      if (Number.isFinite(budget)) {
        timer = setTimeout(() => {
          controller.abort();
          answer(grpcError('TASK_TIMEOUT', `Not done within ${Math.round(budget)} ms`));
        }, budget);
        timer.unref();
      }
      // The caller went away (its deadline fired or it cancelled): stop the work too.
      call.on('cancelled', () => controller.abort());

      Promise.resolve()
        .then(() => handler(call.request, { metadata: call.metadata, signal: controller.signal }))
        .then((response) => answer(null, response))
        .catch((err) => {
          if (err && err.teamCode) {
            answer(err);
            return;
          }
          log.error({ method, error: err && err.message, stack: err && err.stack }, 'grpc handler failed');
          answer(grpcError('INTERNAL_ERROR', 'Internal error'));
        });
    });
  };
}

/**
 * services: [{ service: <Ctor>.service, handlers: { GetApplicant: async (req, ctx) => ... } }]
 * A method without a handler answers UNIMPLEMENTED (grpc-js default).
 */
function createGrpcServer({ port, services, taskTimeoutMs, limiter, log = logger, host = '0.0.0.0' }) {
  const server = new grpc.Server();
  for (const { service, handlers } of services) {
    const wrapped = {};
    for (const [name, definition] of Object.entries(service)) {
      const handler = handlers[name] || handlers[definition.originalName];
      if (handler) wrapped[name] = wrapUnary(definition.path, handler, { taskTimeoutMs, limiter, log });
    }
    server.addService(service, wrapped);
  }

  return {
    server,
    /** Binds and starts; resolves with the bound port (useful with port 0 in tests). */
    start() {
      return new Promise((resolve, reject) => {
        server.bindAsync(`${host}:${port}`, grpc.ServerCredentials.createInsecure(), (err, boundPort) => {
          if (err) return reject(err);
          log.info({ grpcPort: boundPort }, 'grpc server listening');
          return resolve(boundPort);
        });
      });
    },
    /** Lets running calls finish, then forces the shutdown after graceMs. */
    stop(graceMs = 3000) {
      return new Promise((resolve) => {
        const force = setTimeout(() => { server.forceShutdown(); resolve(); }, graceMs);
        force.unref();
        server.tryShutdown(() => { clearTimeout(force); resolve(); });
      });
    },
  };
}

/** A limiter for a service without one: at most max calls at once. */
function createLimiter(max) {
  let inFlight = 0;
  return {
    tryAcquire() { if (inFlight >= max) return false; inFlight += 1; return true; },
    release() { inFlight = Math.max(0, inFlight - 1); },
    inFlight: () => inFlight,
  };
}

module.exports = { createGrpcServer, createLimiter, wrapUnary };
