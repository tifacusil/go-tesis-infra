'use strict';

// index.js — custom Artillery engine: raw TCP DTU binary-frame ingestion for
// go-data-receiving. Loaded by Artillery via bare `require('artillery-engine-dtu-tcp')`
// (Artillery's config.engines resolution is npm-package-name-only — see
// load-tests/README-engine.md for how NODE_PATH makes this local package resolve
// without publishing to npm).
//
// Contract (Artillery v2, confirmed against artilleryio/artillery packages/core):
//   - constructor(script, ee, helpers)
//   - createScenario(scenarioSpec, ee) -> function(context, callback)
//   - step(rs, ee) dispatches flow-step keys to engine-specific logic; unrecognized
//     keys must still return a (context, callback) => callback(null, context) no-op,
//     matching built-in engine behavior (Artillery does not warn on unknown steps).
//   - must ee.emit('started') when a VU scenario begins (pendingScenarios bookkeeping)
//   - ee.emit('counter', name, value) / ee.emit('error', code) feed Artillery's stats;
//     there is no dedicated success/response event for non-HTTP engines.
//
// Frame building/sending is delegated to dtu-emulator (Python sender at
// ../../dtu-emulator relative to this repo's checkout, or DTU_EMULATOR_PATH) —
// see README-engine.md.
//
// Every scenario file in scenarios/ has exactly ONE `send` step per VU flow —
// a VU here IS one frame, there's no sequence of sends within a VU to amortize
// interpreter startup over. So instead of spawning a `python -m sender fixture
// --count 1` process per `send` step (the original design — see git history),
// a small pool of long-lived `python -m sender stream` worker processes is
// spawned once per target (host:port) and kept alive for the whole Artillery
// run. Each worker holds one persistent TCP connection; `send` steps from many
// VUs are dispatched onto the pool round-robin as JSON lines over the worker's
// stdin, and results come back as JSON lines on stdout. This keeps "one
// persistent connection per pool slot" instead of "one process+connection per
// frame" while still exercising roughly as many concurrent connections as the
// scenario's peak arrival rate (see resolvePoolSize below).

const path = require('path');
const readline = require('readline');
const { spawn, spawnSync } = require('child_process');

// Every worker pipes its stderr to this process's stderr (see spawnWorker), so
// a pool of N workers registers N sets of pipe listeners on the one sink. Past
// 10 Node prints a MaxListenersExceededWarning per worker — pure noise at the
// pool sizes these load tests use (hundreds), and it drowns real warnings. The
// fan-in is intentional and bounded by the pool, so lift the cap on the sink.
process.stderr.setMaxListeners(0);

const ACK_TIMEOUT_MS = 5000;
const DEFAULT_PORT = 5000; // puerto TCP de data-receiving-1 (ver docker-compose.yml de tesis-infra)
const DEFAULT_SENSOR_TYPE = 'gnss';
const DEFAULT_POOL_SIZE = 50; // fallback when pool size can't be inferred — see resolvePoolSize
const DEFAULT_SENSOR_COUNT = 100; // ver "flota de sensores" más abajo

// Client-side ceiling on how long a `send` may sit queued + in flight on a
// worker before its VU is failed. The Python worker already bounds each
// network operation at ACK_TIMEOUT_MS, so in a healthy run this never fires;
// it exists so a wedged worker (or a backlog that outlives the run) can't
// leave VU callbacks pending forever — Artillery only exits once every VU
// has completed, so an unbounded wait here means a run that never ends.
const SEND_TIMEOUT_MS = (() => {
  const n = Number(process.env.DTU_ENGINE_SEND_TIMEOUT_MS);
  return Number.isFinite(n) && n > 0 ? Math.ceil(n) : 120000;
})();

const RESPAWN_DELAY_MS = 1000; // breather before replacing a dead worker, so a crash-on-start bug can't become a tight spawn storm

// Global respawn circuit breaker. When the whole pool is failing — the OS
// refusing to fork under memory pressure, or socket/handle exhaustion (WinError
// 8 / 10055) — every dead worker becomes a fresh spawn that dies the same way,
// and the respawns pile up faster than the OS reclaims the dead processes. A
// real run of this left >1000 orphaned Python processes behind and exhausted
// the client's kernel socket resources.
//
// A per-slot "quick death" counter does NOT catch it: under memory pressure a
// worker often lives several seconds before dying, so it never accumulates a
// streak and respawns forever. Instead, count respawns across ALL slots in a
// rolling window. Isolated flaky-worker respawns stay far under the limit; a
// pool that is cycling wholesale trips it. Once tripped, stop respawning for
// the rest of the run — the run is already invalid, and the priority is not
// making the machine worse.
const RESPAWN_WINDOW_MS = 20000;
const RESPAWN_WINDOW_MAX = 40; // ~2x a typical pool; a whole pool re-cycling exceeds this fast
const respawnTimestamps = [];
let respawnCircuitOpen = false;

// Records a respawn and reports whether it's allowed. Trips (and latches) the
// breaker when respawns in the last RESPAWN_WINDOW_MS exceed RESPAWN_WINDOW_MAX.
function respawnAllowed() {
  if (respawnCircuitOpen) return false;
  const now = Date.now();
  respawnTimestamps.push(now);
  while (respawnTimestamps.length && now - respawnTimestamps[0] > RESPAWN_WINDOW_MS) {
    respawnTimestamps.shift();
  }
  if (respawnTimestamps.length > RESPAWN_WINDOW_MAX) {
    respawnCircuitOpen = true;
    console.error(
      `[dtu-tcp] ${respawnTimestamps.length} worker respawns in ${RESPAWN_WINDOW_MS}ms — ` +
      `pool is thrashing (out of memory or sockets); stopping respawns. ` +
      `Reduce the pool size (POOL_PER_SHARD / DTU_ENGINE_POOL_SIZE).`
    );
    return false;
  }
  return true;
}

const DTU_EMULATOR_PATH = path.resolve(
  process.env.DTU_EMULATOR_PATH || path.join(__dirname, '..', '..', '..', 'dtu-emulator')
);
const DTU_EMULATOR_SRC = path.join(DTU_EMULATOR_PATH, 'src');

let cachedPythonBin = null;

function resolvePythonBin() {
  if (cachedPythonBin) return cachedPythonBin;
  const candidates = process.env.DTU_EMULATOR_PYTHON
    ? [process.env.DTU_EMULATOR_PYTHON]
    : ['python3', 'python', 'py'];
  for (const bin of candidates) {
    const probe = spawnSync(bin, ['--version'], { stdio: 'ignore' });
    if (!probe.error && probe.status === 0) {
      cachedPythonBin = bin;
      return bin;
    }
  }
  throw new Error(
    `no working Python interpreter found (tried: ${candidates.join(', ')}). Set DTU_EMULATOR_PYTHON.`
  );
}

// ---- persistent worker pool ---------------------------------------------

const pools = new Map(); // "host:port" -> Pool
const allWorkers = new Set();
let shuttingDown = false;

// A pending entry may be settled by exactly one of: its response line, a
// write error, worker death, or the SEND_TIMEOUT_MS timer. _settle makes
// whichever happens first win and the rest no-ops, so a late response can't
// double-resolve a VU callback.
function _settle(entry, err, value) {
  if (entry.settled) return;
  entry.settled = true;
  clearTimeout(entry.timer);
  if (err) entry.reject(err);
  else entry.resolve(value);
}

// Sizes the pool to the scenario's peak arrivalRate/rampTo (roughly: how many
// concurrent connections the old per-frame-spawn model would have opened at
// its busiest), so pipeline depth per worker stays near zero. Override with
// DTU_ENGINE_POOL_SIZE (e.g. required for vu-sustained-12h.yml, whose rate is
// a templated env var this can't introspect).
function resolvePoolSize(script) {
  const envOverride = process.env.DTU_ENGINE_POOL_SIZE;
  if (envOverride !== undefined) {
    const n = Number(envOverride);
    if (Number.isFinite(n) && n > 0) return Math.ceil(n);
  }
  const phases = (script.config && script.config.phases) || [];
  let peak = 0;
  for (const phase of phases) {
    for (const key of ['arrivalRate', 'rampTo']) {
      const n = Number(phase[key]);
      if (Number.isFinite(n)) peak = Math.max(peak, n);
    }
  }
  return peak > 0 ? Math.ceil(peak) : DEFAULT_POOL_SIZE;
}

// ---- flota de sensores ---------------------------------------------------
//
// La identidad del sensor salía del contract example que dtu-emulator carga,
// así que TODA la carga venía de un único sensor_id. Eso invalida dos cosas a
// la vez: la evaluación de umbral es stateful por sensor, así que un solo
// sensor colapsa cualquier sharding del consumidor sobre una sola partición
// (el worker pool de early-warning midió exactamente cero mejora), y pone el
// read-modify-write de toda la corrida sobre una única clave de Redis.
//
// Ahora la identidad la asigna el engine: reparte cada `send` entre
// DTU_SENSOR_COUNT sensores round-robin y le dice al emulador qué lectura de
// esa serie es. El emulador convierte (sensor_id, reading_index) en una
// lectura físicamente consistente — ver dtu-emulator/src/sender/field.py.
//
// El contador de lecturas vive acá y no en los workers a propósito: el engine
// es un único proceso Node, así que es el único punto que ve la corrida
// entera. Los workers quedan intercambiables y un respawn no pierde la serie.
//
// DTU_SENSOR_COUNT=0 restaura el corpus previo (un solo sensor, payload
// aleatorio por frame), para reproducir corridas viejas.
//
// DTU_SENSOR_BASE desplaza el rango de ids de este proceso. Existe para poder
// repartir una corrida entre varios procesos Artillery (cada uno un event loop
// propio, en su propio core) sin que dos de ellos toquen el mismo sensor: el
// contador de lecturas vive por proceso, así que dos procesos sobre el mismo
// sensor_id le asignarían el mismo reading_index — mismo timestamp, y el motor
// descarta el segundo (dt<=0). Con bases disjuntas (proceso k de N usa
// [k·count, (k+1)·count)) cada sensor lo escribe un solo proceso y su serie
// queda intacta. Ver load-tests/run-sharded.sh.
const SENSOR_BASE = (() => {
  const n = Number(process.env.DTU_SENSOR_BASE);
  return Number.isFinite(n) && n >= 0 ? Math.floor(n) : 0;
})();
const readingIndexBySensor = new Map();
let nextSensorSeq = 0;

function resolveSensorCount(spec, context, helpers) {
  const raw = spec.sensorCount !== undefined
    ? interpolate(spec.sensorCount, context, helpers)
    : process.env.DTU_SENSOR_COUNT;
  if (raw === undefined || raw === '') return DEFAULT_SENSOR_COUNT;
  const n = Number(raw);
  return Number.isFinite(n) && n >= 0 ? Math.floor(n) : DEFAULT_SENSOR_COUNT;
}

// Convención del paper: su estación GNSS de Shangtan es GXZM-DB03.
function sensorIdFor(index) {
  return `GXZM-DB${String(index).padStart(3, '0')}`;
}

function assignReading(sensorCount) {
  if (sensorCount <= 0) return null;
  const sensorId = sensorIdFor(SENSOR_BASE + (nextSensorSeq++ % sensorCount));
  const readingIndex = readingIndexBySensor.get(sensorId) || 0;
  readingIndexBySensor.set(sensorId, readingIndex + 1);
  return { sensorId, readingIndex };
}

function spawnWorker(host, port) {
  const pythonBin = resolvePythonBin();
  const args = [
    '-m', 'sender', 'stream',
    '--host', host,
    '--port', String(port),
    '--ack-timeout', String(ACK_TIMEOUT_MS / 1000),
    '--no-retry',
    '--log-level', 'INFO',
  ];
  const proc = spawn(pythonBin, args, {
    cwd: DTU_EMULATOR_PATH,
    env: { ...process.env, PYTHONPATH: DTU_EMULATOR_SRC },
    stdio: ['pipe', 'pipe', 'pipe'],
  });

  const worker = { proc, pending: [], closing: false };
  allWorkers.add(worker);

  proc.stdin.on('error', () => {}); // surfaced via write() callback instead
  proc.stdout.on('error', () => {});

  const rl = readline.createInterface({ input: proc.stdout, crlfDelay: Infinity });
  rl.on('line', (line) => {
    const entry = worker.pending.shift();
    if (!entry) return; // stray output (e.g. a log line), ignore
    try {
      _settle(entry, null, JSON.parse(line));
    } catch (parseErr) {
      _settle(entry, new Error(`unparseable stream worker response: ${line}`));
    }
  });

  proc.stderr.pipe(process.stderr);

  function onDown(reason) {
    if (worker.down) return; // 'error' and 'exit' can both fire for the same death
    worker.down = true;
    allWorkers.delete(worker);
    const err = new Error(`dtu-emulator stream worker for ${host}:${port} is down (${reason})`);
    for (const entry of worker.pending.splice(0)) _settle(entry, err);
    if (worker.closing || shuttingDown) return;
    if (!respawnAllowed()) return; // pool thrashing — see respawnAllowed
    console.error(`[dtu-tcp] ${err.message} — respawning in ${RESPAWN_DELAY_MS}ms`);
    // Deferred (and unref'd, so it can't hold the process open at shutdown):
    // an immediate respawn of a worker that dies on startup would loop as
    // fast as the OS can fork Python.
    setTimeout(() => {
      if (shuttingDown) return;
      const pool = pools.get(`${host}:${port}`);
      if (!pool) return;
      try {
        pool.replace(worker, spawnWorker(host, port));
      } catch (respawnErr) {
        console.error(`[dtu-tcp] failed to respawn worker for ${host}:${port}: ${respawnErr.message}`);
      }
    }, RESPAWN_DELAY_MS).unref();
  }

  proc.on('exit', (code, signal) => onDown(`exit code=${code} signal=${signal}`));
  proc.on('error', (spawnErr) => onDown(`spawn error: ${spawnErr.message}`));

  return worker;
}

class Pool {
  constructor(host, port, size) {
    this.host = host;
    this.port = port;
    this.workers = Array.from({ length: size }, () => spawnWorker(host, port));
    this.nextIndex = 0;
  }

  replace(deadWorker, freshWorker) {
    const idx = this.workers.indexOf(deadWorker);
    if (idx !== -1) this.workers[idx] = freshWorker;
  }

  send(request) {
    const worker = this.workers[this.nextIndex % this.workers.length];
    this.nextIndex += 1;
    const { host, port } = this;
    return new Promise((resolve, reject) => {
      const entry = { resolve, reject, settled: false, timer: null };
      // On timeout the entry stays in the worker's FIFO on purpose: its
      // response (if it ever arrives) must still consume this queue slot,
      // otherwise every later response would resolve the wrong VU. _settle's
      // guard turns that late consumption into a no-op.
      entry.timer = setTimeout(() => {
        _settle(entry, new Error(`no response from stream worker for ${host}:${port} within ${SEND_TIMEOUT_MS}ms (queued + in flight)`));
      }, SEND_TIMEOUT_MS);
      entry.timer.unref();
      worker.pending.push(entry);
      worker.proc.stdin.write(`${JSON.stringify(request)}\n`, (writeErr) => {
        if (!writeErr) return;
        // Write never reached the worker, so no response will come — safe to
        // drop the entry from the FIFO entirely.
        const idx = worker.pending.indexOf(entry);
        if (idx !== -1) worker.pending.splice(idx, 1);
        _settle(entry, writeErr);
      });
    });
  }
}

function getPool(host, port, size) {
  const key = `${host}:${port}`;
  let pool = pools.get(key);
  if (!pool) {
    pool = new Pool(host, port, size);
    pools.set(key, pool);
  }
  return pool;
}

function killAllWorkers() {
  shuttingDown = true;
  for (const worker of allWorkers) {
    worker.closing = true;
    try { worker.proc.stdin.end(); } catch (_) { /* already closed */ }
    try { worker.proc.kill(); } catch (_) { /* already dead */ }
  }
}

process.once('exit', killAllWorkers);
process.once('SIGINT', () => { killAllWorkers(); process.exit(130); });
process.once('SIGTERM', () => { killAllWorkers(); process.exit(143); });

// ---------------------------------------------------------------------------

class DtuTcpEngine {
  constructor(script, ee, helpers) {
    this.script = script;
    this.helpers = helpers;
    this.target = script.config.target; // "host:port", e.g. "204.168.203.32:5000"
    this.poolSize = resolvePoolSize(script);
  }

  createScenario(scenarioSpec, ee) {
    const tasks = (scenarioSpec.flow || []).map((rs) => this.step(rs, ee));

    return function scenario(initialContext, callback) {
      ee.emit('started');
      runWaterfall(tasks, initialContext, callback);
    };

    function runWaterfall(steps, context, done) {
      if (steps.length === 0) return done(null, context);
      const [head, ...rest] = steps;
      head(context, (err, nextContext) => {
        if (err) return done(err, nextContext || context);
        runWaterfall(rest, nextContext || context, done);
      });
    }
  }

  step(rs, ee) {
    const helpers = this.helpers;
    const target = this.target;
    const poolSize = this.poolSize;

    if (rs.think) {
      return helpers.createThink(rs, this.script.config?.defaults?.think || {});
    }

    if (rs.log) {
      return function log(context, callback) {
        return callback(null, context);
      };
    }

    if (rs.send) {
      return function send(context, callback) {
        sendViaPool(target, poolSize, rs.send, context, helpers, ee, callback);
      };
    }

    // Unrecognized step key — no-op, matching built-in engine behavior for
    // unknown flow entries (Artillery does not error on this).
    return function doNothing(context, callback) {
      return callback(null, context);
    };
  }
}

function interpolate(value, context, helpers) {
  if (typeof value !== 'string') return value;
  return helpers.template(value, context, true);
}

function resolveField(spec, key, context, helpers, fallback) {
  const raw = spec[key];
  if (raw === undefined) return typeof fallback === 'function' ? fallback() : fallback;
  return interpolate(raw, context, helpers);
}

// Contract example shipped with dtu-emulator for each sensor type — used as
// the fixture-mode source of truth for frame shape (dtu-emulator randomizes
// the payload itself; see run_fixture in modes/fixture_mode.py).
const SENSOR_CONTRACT_FILES = {
  gnss: 'gnss-shangtan.json',
  rainfall: 'rainfall-shangtan.json',
  strain: 'strain-shangtan.json',
  soil_pressure: 'soil-pressure-shangtan.json',
  deep_displacement: 'deep-displacement-lingzhan.json',
};

function sendViaPool(target, poolSize, spec, context, helpers, ee, callback) {
  // Tolerar TARGET_HOST=http://host:port o https://host:port por costumbre
  // (el resto del repo usaba ese formato antes de la migración a TCP) —
  // la ingesta real es TCP puro, sin esquema, pero fallar duro acá solo
  // porque alguien copió el viejo patrón de uso es un costo innecesario.
  const withoutScheme = String(target).replace(/^[a-z][a-z0-9+.-]*:\/\//i, '');
  const [host, portStr] = withoutScheme.split(':');
  const port = portStr === undefined ? DEFAULT_PORT : Number(portStr);
  if (!host || !Number.isFinite(port)) {
    const err = new Error(`invalid target "${target}", expected "host:port" (ingesta TCP, sin esquema http://) or "host" to use the default port ${DEFAULT_PORT}`);
    ee.emit('error', 'invalid_target');
    return callback(err, context);
  }

  const sensorType = resolveField(spec, 'sensorType', context, helpers, DEFAULT_SENSOR_TYPE);
  const contractFileName = resolveField(spec, 'contractFile', context, helpers, () => SENSOR_CONTRACT_FILES[sensorType]);
  if (!contractFileName) {
    ee.emit('error', 'unknown_sensor_type');
    return callback(new Error(`no contract example for sensorType "${sensorType}" — set spec.contractFile explicitly`), context);
  }
  const contractFile = path.join(DTU_EMULATOR_PATH, 'contracts', 'examples', contractFileName);

  const request = { file: contractFile };
  const reading = assignReading(resolveSensorCount(spec, context, helpers));
  if (reading) {
    request.sensor_id = reading.sensorId;
    request.reading_index = reading.readingIndex;
  }
  const seed = resolveField(spec, 'seed', context, helpers, undefined);
  if (seed !== undefined) request.seed = Number(seed);
  const corrupt = resolveField(spec, 'corrupt', context, helpers, undefined);
  if (corrupt !== undefined) request.corrupt = String(corrupt);

  let pool;
  try {
    pool = getPool(host, port, poolSize);
  } catch (poolErr) {
    ee.emit('error', 'python_not_found');
    return callback(poolErr, context);
  }

  const startedAt = Date.now();
  pool.send(request).then(
    (msg) => {
      if (msg.error) {
        ee.emit('error', 'emulator_error');
        return callback(new Error(`dtu-emulator stream worker error: ${msg.error}`), context);
      }
      if (msg.status !== 'OK') {
        ee.emit('error', `frame_rejected_${msg.status}`);
        return callback(new Error(`frame rejected by ${host}:${port}: ack=${msg.status}`), context);
      }
      ee.emit('counter', 'dtu_tcp.frames_acked', 1);
      const latencyMs = Number(msg.latency_ms);
      ee.emit('histogram', 'dtu_tcp.round_trip_ms', Number.isFinite(latencyMs) ? latencyMs : Date.now() - startedAt);
      return callback(null, context);
    },
    (dispatchErr) => {
      ee.emit('error', 'pool_dispatch_failed');
      return callback(dispatchErr, context);
    }
  );
}

module.exports = DtuTcpEngine;
