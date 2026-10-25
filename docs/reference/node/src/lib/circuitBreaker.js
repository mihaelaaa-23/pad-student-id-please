'use strict';

// Circuit breaker for calls to one other service (Communication Contract, "Circuit
// Breaker"; Lab 3, grades 7 and 10). Reference implementation for the Node services.
//
// Calls go through the Gateway, so before a call the caller cannot know which
// instance will answer; it only learns it from the X-Instance-Id of the response.
// Failures are therefore counted in two places:
//   - per instance (response carries X-Instance-Id): at the threshold the instance is
//     logged and handed to onInstanceTrip (grade 10: report it to Service Discovery).
//     Calls are never blocked for it, so one broken replica does not block the others.
//   - per callee (no X-Instance-Id: the Gateway did not answer, or had no instance):
//     the classic closed -> open -> half_open -> closed breaker.
//
// The clock and the logger are injected, so the state machine is tested without
// waiting and without a real logger.

const THRESHOLD = 3;
const WINDOW_FACTOR = 3.5;

// Decided by error.code before the status: the status alone cannot tell a broken
// instance (502 BAD_GATEWAY) from a configuration error further down
// (502 DEPENDENCY_REFUSED), or a busy instance from a broken dependency (both 503).
// Every other 5xx counts, whatever its code; no 4xx counts.
const IGNORED_CODES = new Set([
  'DEPENDENCY_REFUSED', // configuration error further down the chain
  'CONCURRENCY_LIMIT_REACHED', // busy, not broken: removing it would load the others more
  'DEPENDENCY_UNAVAILABLE', // the callee is fine, its own dependency is not
  'WS_NEGOTIATION_DISABLED',
]);

/**
 * Classifies the result of one call, as returned by httpClient.getJson:
 * {status, body, error, instanceId, cancelled}.
 * @returns {{counted: boolean, ignored?: boolean, reason?: string}}
 */
function classify(result) {
  // Our own task timeout cancelled the call: the callee did nothing wrong.
  if (result.cancelled) return { counted: false, ignored: true };
  if (result.status === null || result.status === undefined) {
    return { counted: true, reason: result.error || 'no response' };
  }
  const code = result.body?.error?.code;
  if (code && IGNORED_CODES.has(code)) return { counted: false };
  if (result.status >= 500) {
    return { counted: true, reason: `${result.status}${code ? ` ${code}` : ''}` };
  }
  return { counted: false };
}

class CircuitBreaker {
  /**
   * @param {object} options
   * @param {string} options.targetService  callee, e.g. 'university-record-service'
   * @param {number} options.timeoutMs      HTTP_TIMEOUT_MS of the wrapped call
   * @param {(level: string, message: string, fields: object) => void} options.log
   * @param {() => number} [options.now]    milliseconds, Date.now by default
   * @param {(instance: {targetService: string, targetInstanceId: string, failures: number, windowMs: number}) => void}
   *        [options.onInstanceTrip]        called when an instance reaches the threshold
   * @param {string} [options.mode]         'log' or 'remove', only logged
   */
  constructor({ targetService, timeoutMs, log, now = Date.now, onInstanceTrip, mode = 'log', threshold = THRESHOLD }) {
    if (!Number.isFinite(timeoutMs) || timeoutMs <= 0) throw new Error('timeoutMs must be a positive number');
    this.targetService = targetService;
    // Three timeouts in a row must fit in one window: HTTP_TIMEOUT_MS x 3.5.
    this.windowMs = Math.round(timeoutMs * WINDOW_FACTOR);
    this.timeoutMs = timeoutMs;
    this.threshold = threshold;
    this.log = log;
    this.now = now;
    this.onInstanceTrip = onInstanceTrip;
    this.mode = mode;

    this.state = 'closed';
    this.openedAt = null;
    this.trialInFlight = false;
    this.calleeFailures = [];
    this.instanceFailures = new Map();
  }

  /**
   * Runs fn unless the breaker is open. fn returns a getJson-shaped result.
   * @returns {Promise<object>} fn's result, or {rejected: true, retryAfterSeconds}
   */
  async execute(fn) {
    const permit = this.acquire();
    if (!permit.allowed) return { rejected: true, retryAfterSeconds: permit.retryAfterSeconds };
    let result;
    try {
      result = await fn();
    } catch (err) {
      result = { status: null, body: null, error: err.message, instanceId: null, cancelled: false };
      this.record(result, permit.trial);
      throw err;
    }
    this.record(result, permit.trial);
    return result;
  }

  acquire() {
    if (this.state === 'open' && this.now() - this.openedAt >= this.windowMs) {
      this.transition('half_open');
    }
    if (this.state === 'closed') return { allowed: true, trial: false };
    if (this.state === 'half_open' && !this.trialInFlight) {
      this.trialInFlight = true;
      return { allowed: true, trial: true };
    }
    // open, or half_open with its one trial call still running
    const retryAfterSeconds = this.state === 'open'
      ? Math.max(1, Math.ceil((this.openedAt + this.windowMs - this.now()) / 1000))
      : Math.max(1, Math.ceil(this.timeoutMs / 1000));
    this.log('warn', 'call rejected by circuit breaker', {
      targetService: this.targetService,
      state: this.state,
      retryAfterSeconds,
    });
    return { allowed: false, retryAfterSeconds };
  }

  record(result, trial) {
    const outcome = classify(result);
    if (trial) this.trialInFlight = false;
    if (outcome.ignored) return;

    if (!outcome.counted) {
      // Any answer that is not a failure means the callee is reachable again.
      if (trial) this.close();
      return;
    }

    const now = this.now();
    const instanceId = result.instanceId || null;
    if (instanceId) {
      // The Gateway reached an instance, so the callee as a whole is reachable: a
      // trial call ends here even though this instance answered with a failure.
      if (trial) this.close();
      this.recordInstanceFailure(instanceId, outcome.reason, now);
      return;
    }

    this.calleeFailures = this.calleeFailures.filter((t) => now - t < this.windowMs);
    this.calleeFailures.push(now);
    this.log('warn', 'outgoing call failed', {
      targetService: this.targetService,
      reason: outcome.reason,
      failures: this.calleeFailures.length,
      windowMs: this.windowMs,
    });
    if (trial || (this.state === 'closed' && this.calleeFailures.length >= this.threshold)) {
      this.open();
    }
  }

  recordInstanceFailure(instanceId, reason, now) {
    // Drop instances whose failures have all left the window, so the map does not
    // grow with every replica that ever failed once.
    for (const [id, times] of this.instanceFailures) {
      if (times.every((t) => now - t >= this.windowMs)) this.instanceFailures.delete(id);
    }
    const times = (this.instanceFailures.get(instanceId) || []).filter((t) => now - t < this.windowMs);
    times.push(now);
    this.log('warn', 'outgoing call failed', {
      targetService: this.targetService,
      targetInstanceId: instanceId,
      reason,
      failures: times.length,
      windowMs: this.windowMs,
    });
    if (times.length < this.threshold) {
      this.instanceFailures.set(instanceId, times);
      return;
    }
    // Start again from zero: a still-failing instance can be reported again later.
    this.instanceFailures.delete(instanceId);
    const tripped = {
      targetService: this.targetService,
      targetInstanceId: instanceId,
      failures: times.length,
      windowMs: this.windowMs,
    };
    this.log('warn', 'instance failure threshold reached', { ...tripped, mode: this.mode });
    if (this.onInstanceTrip) this.onInstanceTrip(tripped);
  }

  open() {
    this.openedAt = this.now();
    this.transition('open');
  }

  close() {
    this.calleeFailures = [];
    this.openedAt = null;
    if (this.state !== 'closed') this.transition('closed');
  }

  transition(state) {
    const previousState = this.state;
    if (previousState === state) return;
    this.state = state;
    this.log(state === 'open' ? 'warn' : 'info', 'circuit breaker state changed', {
      targetService: this.targetService,
      previousState,
      state,
      failures: this.calleeFailures.length,
      windowMs: this.windowMs,
    });
  }
}

module.exports = { CircuitBreaker, classify, THRESHOLD, WINDOW_FACTOR };
