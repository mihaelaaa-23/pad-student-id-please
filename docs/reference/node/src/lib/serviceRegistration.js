'use strict';

// Registration with Service Discovery (Communication Contract, "Service Discovery";
// Lab 3, grades 4 and 5). Reference implementation for the Node services.
//
//   start()  registers once the HTTP server listens, retrying with backoff while
//            Service Discovery is not reachable, then sends a heartbeat every
//            heartbeatMs. A heartbeat answered 404 (Service Discovery restarted and
//            lost its in-memory registry) registers again.
//   stop()   deregisters, best effort, with a short timeout, so `docker compose stop`
//            and scaling down remove the instance at once instead of after eviction.
//
// Service Discovery is called directly, not through the Gateway: the Gateway itself
// needs Service Discovery to find anything. Timers and fetch are injected so tests
// run without waiting.

const TARGET_SERVICE = 'service-discovery';

// A 401 or 422 is a configuration error (wrong token, bad url): retrying cannot fix
// it, so it is logged at ERROR and the instance stops trying.
const PERMANENT = new Set([400, 401, 403, 422]);

function createRegistration({
  sdUrl,
  serviceName,
  instanceId,
  url,
  statusPath = '/status',
  token = () => process.env.SERVICE_TOKEN,
  heartbeatMs = 10000,
  requestTimeoutMs = 2000,
  deregisterTimeoutMs = 1000,
  retryBaseMs = 1000,
  retryMaxMs = 30000,
  log,
  fetchFn = fetch,
  timers = { setTimeout, clearTimeout },
}) {
  const base = sdUrl.replace(/\/+$/, '');
  const instancePath = `/services/${encodeURIComponent(serviceName)}/instances/${encodeURIComponent(instanceId)}`;
  // serviceName and instanceId are this instance's own: already on every line as
  // service and instanceId, so they are not repeated.
  const target = { targetService: TARGET_SERVICE };

  let timer = null;
  let stopped = false;
  let registered = false;
  let attempt = 0;

  function schedule(fn, ms) {
    timers.clearTimeout(timer);
    timer = timers.setTimeout(fn, ms);
    // A pending heartbeat must not keep the process alive on shutdown.
    if (timer && typeof timer.unref === 'function') timer.unref();
  }

  /** @returns {Promise<{status: number|null, error: string|null}>} never throws */
  async function call(method, path, body, timeoutMs) {
    const secret = token();
    try {
      const response = await fetchFn(`${base}${path}`, {
        method,
        headers: {
          Accept: 'application/json',
          ...(body ? { 'Content-Type': 'application/json' } : {}),
          // The token is sent, never logged.
          ...(secret ? { Authorization: `Bearer ${secret}` } : {}),
        },
        body: body ? JSON.stringify(body) : undefined,
        signal: AbortSignal.timeout(timeoutMs),
      });
      return { status: response.status, error: null };
    } catch (err) {
      const reason = err.name === 'TimeoutError' || err.name === 'AbortError'
        ? `timeout after ${timeoutMs}ms`
        : err.cause?.code || err.message;
      return { status: null, error: reason };
    }
  }

  async function register() {
    if (stopped) return;
    const result = await call('POST', '/services/register', { serviceName, instanceId, url, statusPath }, requestTimeoutMs);
    if (stopped) return;

    if (result.status === 200 || result.status === 201) {
      registered = true;
      attempt = 0;
      log.info({ ...target, url, status: result.status }, 'registered with service discovery');
      schedule(heartbeat, heartbeatMs);
      return;
    }
    if (PERMANENT.has(result.status)) {
      log.error(
        { ...target, url, status: result.status },
        'service discovery rejected the registration, not retrying: check SERVICE_TOKEN and the url',
      );
      return;
    }

    // Not reachable yet, or a 5xx: retry with exponential backoff and keep serving.
    attempt += 1;
    const retryInMs = Math.min(retryBaseMs * 2 ** (attempt - 1), retryMaxMs);
    log.warn({
      ...target,
      status: result.status,
      error: result.error || `service discovery answered ${result.status}`,
      retryAttempt: attempt,
      retryInMs,
    }, 'registration with service discovery failed, retrying');
    schedule(register, retryInMs);
  }

  async function heartbeat() {
    if (stopped) return;
    const result = await call('PUT', `${instancePath}/heartbeat`, null, requestTimeoutMs);
    if (stopped) return;

    if (result.status === 200) {
      // Every few seconds from every instance: DEBUG, like the health polls.
      log.debug({ ...target }, 'heartbeat sent');
      schedule(heartbeat, heartbeatMs);
      return;
    }
    if (result.status === 404) {
      registered = false;
      log.warn({ ...target }, 'service discovery does not know this instance, registering again');
      await register();
      return;
    }
    if (PERMANENT.has(result.status)) {
      log.error({ ...target, status: result.status }, 'service discovery rejected the heartbeat: check SERVICE_TOKEN');
    } else {
      log.warn({
        ...target,
        status: result.status,
        error: result.error || `service discovery answered ${result.status}`,
      }, 'heartbeat failed');
    }
    // Keep trying: one missed heartbeat is not a reason to leave the registry, and
    // eviction only happens after several.
    schedule(heartbeat, heartbeatMs);
  }

  return {
    start() {
      log.info({ ...target, sdUrl: base, url, heartbeatMs }, 'registering with service discovery');
      return register();
    },

    async stop() {
      stopped = true;
      timers.clearTimeout(timer);
      if (!registered) return;
      const result = await call('DELETE', instancePath, null, deregisterTimeoutMs);
      if (result.status === 204 || result.status === 404) {
        log.info({ ...target, status: result.status }, 'deregistered from service discovery');
      } else {
        // Best effort: if this is lost, eviction removes the instance later.
        log.warn({
          ...target,
          status: result.status,
          error: result.error || `service discovery answered ${result.status}`,
        }, 'deregistration from service discovery failed');
      }
    },

    isRegistered: () => registered,
  };
}

/**
 * Builds the registration from the environment, or returns null when
 * SERVICE_DISCOVERY_URL is unset (the service then runs as in Lab 2, on its own).
 */
function registrationFromEnv({ serviceName, instanceId, hostname, port, log, env = process.env }) {
  if (!env.SERVICE_DISCOVERY_URL) return null;
  // http://<container hostname>:<port>: unique per replica and resolvable inside the
  // compose network. ADVERTISE_URL is only for a single instance run outside compose.
  const url = env.ADVERTISE_URL || `http://${hostname}:${port}`;
  const heartbeat = Number(env.SD_HEARTBEAT_MS);
  return createRegistration({
    sdUrl: env.SERVICE_DISCOVERY_URL,
    serviceName,
    instanceId,
    url,
    heartbeatMs: Number.isInteger(heartbeat) && heartbeat > 0 ? heartbeat : 10000,
    log,
  });
}

/** BREAKER_MODE: 'log' (grade 7, the default) or 'remove' (grade 10). */
function breakerMode(env = process.env) {
  return (env.BREAKER_MODE || 'log').toLowerCase() === 'remove' ? 'remove' : 'log';
}

/**
 * Grade 10: reports an instance whose circuit breaker tripped, so Service Discovery
 * takes it out of rotation (POST .../report, Communication Contract). Never throws:
 * a report that fails is logged, and the breaker keeps counting, so a still-failing
 * instance is reported again on its next trip.
 * @returns {Promise<number|null>} the status Service Discovery answered
 */
async function reportInstance({
  sdUrl, reporter, targetService, targetInstanceId, reason, log, requestId,
  token = () => process.env.SERVICE_TOKEN, timeoutMs = 2000, fetchFn = fetch,
}) {
  const target = { targetService, targetInstanceId };
  if (!sdUrl) {
    log.warn({ ...target, reason: 'SERVICE_DISCOVERY_URL is not set' }, 'instance could not be reported to service discovery');
    return null;
  }
  const secret = token();
  const path = `/services/${encodeURIComponent(targetService)}/instances/${encodeURIComponent(targetInstanceId)}/report`;
  try {
    const response = await fetchFn(`${sdUrl.replace(/\/+$/, '')}${path}`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        // The request that saw the failure: Service Discovery logs the report under it.
        ...(requestId ? { 'X-Request-Id': requestId } : {}),
        ...(secret ? { Authorization: `Bearer ${secret}` } : {}),
      },
      body: JSON.stringify({ reporter, reason }),
      signal: AbortSignal.timeout(timeoutMs),
    });
    if (response.status === 202) {
      log.info({ ...target, status: response.status }, 'instance reported to service discovery');
    } else {
      log.warn({ ...target, status: response.status }, 'instance could not be reported to service discovery');
    }
    return response.status;
  } catch (err) {
    const error = err.name === 'TimeoutError' ? `timeout after ${timeoutMs}ms` : err.cause?.code || err.message;
    log.warn({ ...target, status: null, error }, 'instance could not be reported to service discovery');
    return null;
  }
}

/**
 * The breaker's onInstanceTrip for this service: in 'remove' mode it reports the
 * tripped instance to Service Discovery, in 'log' mode there is none (the breaker
 * already logs the trip).
 */
function instanceReporterFromEnv({ reporter, log, env = process.env, fetchFn = fetch, requestIdOf = () => undefined }) {
  if (breakerMode(env) !== 'remove') return undefined;
  return (trip) => {
    // Not awaited: reporting must not delay the request that saw the failure.
    reportInstance({
      sdUrl: env.SERVICE_DISCOVERY_URL,
      reporter,
      targetService: trip.targetService,
      targetInstanceId: trip.targetInstanceId,
      reason: `${trip.failures} failures within the breaker window of ${trip.windowMs} ms`,
      log,
      fetchFn,
      requestId: requestIdOf(),
    });
  };
}

module.exports = {
  createRegistration, registrationFromEnv, breakerMode, reportInstance, instanceReporterFromEnv, TARGET_SERVICE,
};
