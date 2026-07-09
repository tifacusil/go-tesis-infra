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

const net = require('net');
const { buildGnssFrame, parseAck } = require('./dtu-frame');

const ACK_TIMEOUT_MS = 5000;
const CONNECT_TIMEOUT_MS = 5000;

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
        sendGnssFrame(target, rs.send, context, helpers, ee, callback);
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

function sendGnssFrame(target, spec, context, helpers, ee, callback) {
  const [host, portStr] = String(target).split(':');
  const port = Number(portStr);
  if (!host || !Number.isFinite(port)) {
    const err = new Error(`invalid target "${target}", expected "host:port"`);
    ee.emit('error', 'invalid_target');
    return callback(err, context);
  }

  let frame;
  try {
    frame = buildGnssFrame({
      msgId: null, // random 16 bytes; wire format does not assert UUID-v4 shape
      projectId: resolveField(spec, 'projectId', context, helpers, 'thesis_load_test'),
      sensorId: resolveField(spec, 'sensorId', context, helpers, () => `GNSS-${1 + Math.floor(Math.random() * 20)}`),
      timestampMs: Date.now(),
      samplingIntervalSeconds: Number(resolveField(spec, 'samplingIntervalSeconds', context, helpers, 3600)),
      displacementXMm: Number(resolveField(spec, 'displacementXMm', context, helpers, () => randomInRange(-5, 5))),
      displacementYMm: Number(resolveField(spec, 'displacementYMm', context, helpers, () => randomInRange(-5, 5))),
      displacementZMm: Number(resolveField(spec, 'displacementZMm', context, helpers, () => randomInRange(-2, 2))),
      displacementHorizontalMm: Number(resolveField(spec, 'displacementHorizontalMm', context, helpers, () => Math.abs(randomInRange(0, 15)))),
      cumulativeDisplacementMm: Number(resolveField(spec, 'cumulativeDisplacementMm', context, helpers, () => Math.abs(randomInRange(0, 2000)))),
      fixQuality: resolveField(spec, 'fixQuality', context, helpers, 'rtk_fixed'),
    });
  } catch (buildErr) {
    ee.emit('error', 'frame_build_failed');
    return callback(buildErr, context);
  }

  const socket = new net.Socket();
  let settled = false;
  const startedAt = Date.now();

  const finish = (err) => {
    if (settled) return;
    settled = true;
    socket.destroy();
    if (err) return callback(err, context);
    ee.emit('counter', 'dtu_tcp.frames_acked', 1);
    ee.emit('histogram', 'dtu_tcp.round_trip_ms', Date.now() - startedAt);
    return callback(null, context);
  };

  socket.setTimeout(CONNECT_TIMEOUT_MS);
  socket.once('timeout', () => {
    ee.emit('error', 'connect_or_ack_timeout');
    finish(new Error(`timeout connecting/waiting for ack from ${host}:${port}`));
  });
  socket.once('error', (err) => {
    ee.emit('error', err.code || 'socket_error');
    finish(err);
  });

  socket.connect(port, host, () => {
    socket.setTimeout(ACK_TIMEOUT_MS);
    socket.write(frame);
  });

  socket.once('data', (data) => {
    const ack = parseAck(data);
    if (ack.malformed) {
      ee.emit('error', 'malformed_ack');
      return finish(new Error(`malformed ack from ${host}:${port}: ${data.toString('hex')}`));
    }
    if (!ack.ok) {
      ee.emit('error', `frame_rejected_status_${ack.status}_code_${ack.code}`);
      return finish(new Error(`frame rejected: status=0x${ack.status.toString(16)} code=${ack.code}`));
    }
    return finish(null);
  });

  socket.once('close', () => {
    if (!settled) {
      ee.emit('error', 'connection_closed_no_ack');
      finish(new Error(`connection closed by ${host}:${port} before ack (malformed frame or sink failure)`));
    }
  });
}

function randomInRange(min, max) {
  return min + Math.random() * (max - min);
}

module.exports = DtuTcpEngine;
