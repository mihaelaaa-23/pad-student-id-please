'use strict';

// The one logger of this service (CPR README, "Logging Convention"). Every line is a
// JSON object on stdout with timestamp, level, service, instanceId and message, plus
// requestId while a request is being handled.
//
// The request context lives in AsyncLocalStorage rather than in a child logger
// passed down by hand: the circuit breaker, the HTTP client and the store are shared
// by every request, and they still log the requestId of the request that called them.

const os = require('node:os');
const { AsyncLocalStorage } = require('node:async_hooks');
const pino = require('pino');

// Set per service: the exact Compose and Service Discovery name.
const SERVICE = 'applicant-service';
const LEVELS = ['DEBUG', 'INFO', 'WARN', 'ERROR'];

// <serviceName>-<hostname>: Docker sets the hostname to the short container id, so
// every replica logs, registers and answers X-Instance-Id under its own id.
const instanceId = process.env.INSTANCE_ID || `${SERVICE}-${os.hostname()}`;

const requestedLevel = (process.env.LOG_LEVEL || 'INFO').toUpperCase();
const level = LEVELS.includes(requestedLevel) ? requestedLevel : 'INFO';

const context = new AsyncLocalStorage();

// Lines go through a replaceable sink so tests can read them; in the service it is
// stdout, written synchronously, so nothing is lost when the process exits.
let sink = (line) => process.stdout.write(line);

const logger = pino(
  {
    level: level.toLowerCase(),
    messageKey: 'message',
    base: { service: SERVICE, instanceId },
    timestamp: () => `,"timestamp":"${new Date().toISOString()}"`,
    formatters: {
      level(label) {
        if (label === 'fatal') return { level: 'ERROR' };
        if (label === 'trace') return { level: 'DEBUG' };
        return { level: label.toUpperCase() };
      },
    },
    // A copy on every line: Pino merges each line's fields into the object mixin
    // returns, so returning the stored context itself would carry one line's fields
    // into every later line of the same request.
    mixin: () => ({ ...context.getStore() }),
  },
  { write: (line) => sink(line) },
);

if (level !== requestedLevel) {
  logger.warn({ logLevel: requestedLevel }, 'unknown LOG_LEVEL, using INFO');
}

/** Runs fn with ctx ({requestId, callerType?, playerId?}) on every line it logs. */
function runWithContext(ctx, fn) {
  return context.run(ctx, fn);
}

/** The context of the request being handled, or undefined outside a request. */
function currentContext() {
  return context.getStore();
}

/** Test helper: collects the lines written until restore() is called. */
function captureLogs() {
  const lines = [];
  const previous = sink;
  sink = (line) => lines.push(JSON.parse(line));
  return { lines, restore: () => { sink = previous; } };
}

module.exports = { logger, runWithContext, currentContext, captureLogs, SERVICE, instanceId, level };
