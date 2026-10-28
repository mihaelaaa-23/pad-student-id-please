# Node.js reference modules (Lab 3)

Copies of the modules Applicant Service and Credential Service run in production, for the other Node services to take as they are. Each one implements a section of the Communication Contract in the main README; when the contract and these files disagree, the contract wins.

| File | Implements | Grade |
|---|---|---|
| `src/lib/logger.js` | Logging Convention: one Pino logger, JSON lines with `timestamp`, `level`, `service`, `instanceId`, `message`, and the request context (`requestId`, `callerType`, `playerId`) on every line through `AsyncLocalStorage` | 3 |
| `src/middleware/requestContext.js` | `X-Request-Id` kept or generated, `X-Instance-Id` on every response, `request received` / `request completed`, `/health` and `/status` at `DEBUG` | 3 |
| `src/lib/serviceRegistration.js` | Service Discovery: register after `listen`, heartbeat, register again on `404`, deregister on shutdown; `report` of a tripped instance with `BREAKER_MODE=remove` | 4, 5, 10 |
| `src/lib/circuitBreaker.js` | Circuit Breaker: 3 failures within `HTTP_TIMEOUT_MS × 3.5`, per instance with `X-Instance-Id`, per callee (closed → open → half_open) without | 7, 10 |
| `src/lib/load.js` | Critical load: the `load` object `/status` returns, `{inFlight, maxConcurrent, percent, critical}`, with `critical` from `LOAD_CRITICAL_PERCENT` of `MAX_CONCURRENT_TASKS` (the shape Moderation and Discord DMs also report) | 8 |

## Using them in a service

1. Copy the five files into the same paths of the service, and `npm install pino`.
2. `src/lib/logger.js`: set `SERVICE` to the service's exact Compose and Service Discovery name. Replace every `console.*` with `logger.info(fields, message)` / `logger.warn` / `logger.error` / `logger.debug`. Log an error with `{ error: err.message, stack: err.stack }`.
3. `src/app.js`: `app.use(requestContext)` first, before `express.json()`, so even a body that cannot be parsed is logged under its request id. In the error handler, set `res.locals.errorCode` so `request completed` carries the code.
4. `src/index.js`, after `require('dotenv').config()`:

   ```javascript
   const os = require('node:os');
   const { logger, SERVICE, instanceId } = require('./lib/logger');
   const { registrationFromEnv } = require('./lib/serviceRegistration');

   const registration = registrationFromEnv({ serviceName: SERVICE, instanceId, hostname: os.hostname(), port: PORT, log: logger });
   const server = app.listen(PORT, () => { if (registration) registration.start(); });
   process.on('SIGTERM', () => {
     // Docker kills the container 10 s after SIGTERM; exit on our own well before that,
     // even if deregistering or closing the server hangs.
     setTimeout(() => process.exit(1), 5000).unref();
     (registration ? registration.stop() : Promise.resolve()).finally(() => server.close(() => process.exit(0)));
   });
   ```

   Without `SERVICE_DISCOVERY_URL` it returns `null` and the service runs as in Lab 2.
5. Around every outgoing call, one breaker per callee:

   ```javascript
   const { CircuitBreaker } = require('../lib/circuitBreaker');
   const { logger, SERVICE, currentContext } = require('../lib/logger');
   const { breakerMode, instanceReporterFromEnv } = require('../lib/serviceRegistration');

   const mode = breakerMode();
   const breaker = new CircuitBreaker({
     targetService: 'university-record-service',
     timeoutMs: Number(process.env.HTTP_TIMEOUT_MS || 2000),
     log: (level, message, fields) => logger[level](fields, message),
     mode,
     onInstanceTrip: instanceReporterFromEnv({ reporter: SERVICE, log: logger, requestIdOf: () => currentContext()?.requestId }),
   });

   const result = await breaker.execute(() => callTheService());
   if (result.rejected) { /* answer 503 DEPENDENCY_UNAVAILABLE with Retry-After: result.retryAfterSeconds */ }
   ```

   The wrapped call must resolve, never throw, to `{status, body, error, instanceId, cancelled}`: `status` null when there was no answer, `instanceId` from the response's `X-Instance-Id`, `cancelled` true when the caller's own task timeout aborted it. Send `X-Timeout-Ms: <HTTP_TIMEOUT_MS>` on the call. Any `5xx` from the dependency, or no answer, is answered `503 DEPENDENCY_UNAVAILABLE`, never with mock data.

6. `/status` returns `load`, computed from the requests the concurrency limiter holds. Mount `/status` before the limiter, so health polls are not counted:

   ```javascript
   const { computeLoad, criticalPercentFromEnv } = require('./lib/load');
   const { logger, SERVICE } = require('./lib/logger');

   // The Lab 2 concurrency limiter; it must expose how many requests it holds.
   const limiter = concurrencyLimit({ maxConcurrentTasks });
   // limiter.inFlight() -> number
   // Read once at startup; a set but invalid value is logged at WARN.
   const criticalPercent = criticalPercentFromEnv(process.env.LOAD_CRITICAL_PERCENT, logger);
   app.get('/status', async (req, res) => {
     const time = new Date().toISOString();
     const load = computeLoad({ inFlight: limiter.inFlight(), maxConcurrent: maxConcurrentTasks, criticalPercent });
     try {
       await checkDatabase();   // your real check, with a timeout (a ping, SELECT 1, ...)
       res.json({ service: SERVICE, status: 'ok', database: 'up', time, load });
     } catch (err) {
       logger.error({ database: 'down', error: err.message }, 'database check failed');
       // The contract: 503 when the database is down, which Service Discovery counts as a failed poll.
       res.status(503).json({ service: SERVICE, status: 'degraded', database: 'down', time, load });
     }
   });
   app.use(limiter);
   ```

   Service Discovery reads only `load.critical`, and alerts when it changes. Log `WARN load is critical` / `INFO load is back to normal` on change only, since `/status` is polled every 5 s.

Applicant Service (`src/clients/httpClient.js`, `src/clients/universityRecordClient.js`, `src/controllers/statusController.js`) and Credential Service (`src/clients/applicantClient.js`) are complete examples of steps 3–6.

## Environment

| Variable | Default | Meaning |
|---|---|---|
| `LOG_LEVEL` | `INFO` | `DEBUG`, `INFO`, `WARN`, `ERROR` |
| `INSTANCE_ID` | `<service>-<hostname>` | Leave unset in compose: the hostname is the container id |
| `SERVICE_DISCOVERY_URL` | — | `http://service-discovery:3010`; unset means no registration |
| `SD_HEARTBEAT_MS` | `10000` | Heartbeat interval |
| `ADVERTISE_URL` | `http://<hostname>:<PORT>` | Only for a single instance outside compose |
| `SERVICE_TOKEN` | — | Sent on every Service Discovery write; never logged |
| `HTTP_TIMEOUT_MS` | `2000` | Outgoing call timeout; the breaker window is `× 3.5` |
| `BREAKER_MODE` | `log` | `remove` also reports a tripped instance to Service Discovery |
| `LOAD_CRITICAL_PERCENT` | `80` | Share of `MAX_CONCURRENT_TASKS` in flight from which `load.critical` is `true`; an integer from 1 to 100 |

## Tests

```bash
cd docs/reference/node
npm install
npm test
```

`test/` holds the breaker's state machine (injected clock), the Service Discovery client (fake timers and fetch, plus two tests over real HTTP) and the load rule. Copy them along with the modules: they run unchanged in a service with the same layout.
