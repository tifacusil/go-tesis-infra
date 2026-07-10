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
// see README-engine.md. Each `send` step spawns one `python -m sender fixture
// --count 1` subprocess against the contract example for the requested sensor
// type and parses its ACK log line. This means measured round-trip latency
// includes Python interpreter startup, not just network + server time — an
// accepted tradeoff for reusing dtu-emulator's canonical, contract-validated
// frame encoding instead of re-deriving it in JS.

const path = require('path');
const { spawnSync, execFile } = require('child_process');

const ACK_TIMEOUT_MS = 5000;
const DEFAULT_PORT = 5000; // puerto TCP de data-receiving-1 (ver docker-compose.yml de tesis-infra)
const DEFAULT_SENSOR_TYPE = 'gnss';

const DTU_EMULATOR_PATH = path.resolve(
  process.env.DTU_EMULATOR_PATH || path.join(__dirname, '..', '..', '..', 'dtu-emulator')
);
const DTU_EMULATOR_SRC = path.join(DTU_EMULATOR_PATH, 'src');

const ACK_LOG_RE = /ack=(\S+) in ([\d.]+)ms/;

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

class DtuTcpEngine {
  constructor(script, ee, helpers) {
    this.script = script;
    this.helpers = helpers;
    this.target = script.config.target; // "host:port", e.g. "204.168.203.32:5000"
  }

  createScenario(scenarioSpec, ee) {
    const tasks = (scenarioSpec.flow || []).map((rs) => this.step(rs, ee));
    const target = this.target;

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
        sendViaEmulator(target, rs.send, context, helpers, ee, callback);
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

function sendViaEmulator(target, spec, context, helpers, ee, callback) {
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

  const args = [
    '-m', 'sender', 'fixture',
    '--file', contractFile,
    '--count', '1',
    '--rate', '0',
    '--host', host,
    '--port', String(port),
    '--ack-timeout', String(ACK_TIMEOUT_MS / 1000),
    '--no-retry', // fail-fast: backoff/reconnect would corrupt arrival-rate pacing under load
    '--log-level', 'INFO',
  ];
  const seed = resolveField(spec, 'seed', context, helpers, undefined);
  if (seed !== undefined) args.push('--seed', String(seed));
  const corrupt = resolveField(spec, 'corrupt', context, helpers, undefined);
  if (corrupt !== undefined) args.push('--corrupt', String(corrupt));

  let pythonBin;
  try {
    pythonBin = resolvePythonBin();
  } catch (resolveErr) {
    ee.emit('error', 'python_not_found');
    return callback(resolveErr, context);
  }

  const startedAt = Date.now();
  execFile(
    pythonBin,
    args,
    {
      cwd: DTU_EMULATOR_PATH,
      env: { ...process.env, PYTHONPATH: DTU_EMULATOR_SRC },
      timeout: ACK_TIMEOUT_MS + 5000,
      killSignal: 'SIGKILL',
    },
    (err, stdout, stderr) => {
      const wallClockMs = Date.now() - startedAt;
      const match = ACK_LOG_RE.exec(stderr) || ACK_LOG_RE.exec(stdout);

      if (!match) {
        ee.emit('error', err ? (err.killed ? 'emulator_timeout' : 'emulator_no_ack_line') : 'emulator_no_ack_line');
        return callback(
          new Error(`dtu-emulator produced no parseable ACK line (exit=${err ? err.code : 0}): ${stderr.slice(-500)}`),
          context
        );
      }

      const [, status, latencyStr] = match;
      const latencyMs = Number(latencyStr);

      if (status !== 'OK') {
        ee.emit('error', `frame_rejected_${status}`);
        return callback(new Error(`frame rejected by ${host}:${port}: ack=${status}`), context);
      }

      ee.emit('counter', 'dtu_tcp.frames_acked', 1);
      ee.emit('histogram', 'dtu_tcp.round_trip_ms', Number.isFinite(latencyMs) ? latencyMs : wallClockMs);
      return callback(null, context);
    }
  );
}

module.exports = DtuTcpEngine;
