#!/usr/bin/env node
'use strict';

// aggregate-sharded.js — suma los shards de una corrida de run-sharded.sh.
//
// run-sharded.sh reparte un nivel de carga entre N procesos artillery para que
// el generador (Node, de un solo hilo) no sea el techo. Cada proceso deja su
// propio JSON; el throughput real es la SUMA de los shards, no el de uno.
//
// Uso:
//   node load-tests/aggregate-sharded.js B/sharded
//   node load-tests/aggregate-sharded.js B/sharded --json

const fs = require('fs');
const path = require('path');

function readShard(file) {
  const { aggregate: a } = JSON.parse(fs.readFileSync(file, 'utf8'));
  const c = a.counters || {};
  const seconds = (a.lastCounterAt - a.firstCounterAt) / 1000;
  const acked = c['dtu_tcp.frames_acked'] || 0;
  const created = c['vusers.created'] || 0;
  const failed = c['vusers.failed'] || 0;
  const errors = {};
  for (const [k, v] of Object.entries(c)) {
    if (k.startsWith('errors.')) errors[k.slice('errors.'.length)] = v;
  }
  const rtt = a.summaries?.['dtu_tcp.round_trip_ms'] || {};
  return { file: path.basename(file), seconds, acked, created, failed, errors, rtt };
}

function readClientCpu(dir, stem) {
  const csv = path.join(dir, `${stem}.client-cpu.csv`);
  if (!fs.existsSync(csv)) return null;
  const rows = fs
    .readFileSync(csv, 'utf8')
    .split('\n')
    .slice(1)
    .map((l) => l.split(',').map(Number))
    .filter((c) => Number.isFinite(c[1]));
  if (rows.length === 0) return null;
  const col = (i) => rows.map((r) => r[i]).filter(Number.isFinite);
  const mean = (xs) => (xs.length ? xs.reduce((a, b) => a + b, 0) / xs.length : NaN);
  const max = (xs) => (xs.length ? Math.max(...xs) : NaN);
  return {
    totalMean: mean(col(1)), totalMax: max(col(1)),
    nodeMean: mean(col(2)), nodeMax: max(col(2)),
    pythonMean: mean(col(3)), pythonMax: max(col(3)),
  };
}

// Agrupa por prefijo rate<R>-s<N> (todo lo previo a "-shard").
function collect(dir) {
  const runs = new Map();
  for (const name of fs.readdirSync(dir).sort()) {
    const m = /^(.*)-shard\d+\.json$/.exec(name);
    if (!m) continue;
    const stem = m[1];
    if (!runs.has(stem)) runs.set(stem, []);
    runs.get(stem).push(readShard(path.join(dir, name)));
  }
  return runs;
}

function summarize(stem, shards, dir) {
  const acked = shards.reduce((a, s) => a + s.acked, 0);
  const created = shards.reduce((a, s) => a + s.created, 0);
  const failed = shards.reduce((a, s) => a + s.failed, 0);
  // Ventana global: del primer contador al último de cualquier shard.
  const seconds = Math.max(...shards.map((s) => s.seconds));
  const throughput = seconds > 0 ? acked / seconds : NaN;
  const errorRate = created > 0 ? failed / created : NaN;
  const errors = {};
  for (const s of shards) {
    for (const [k, v] of Object.entries(s.errors)) errors[k] = (errors[k] || 0) + v;
  }
  // RTT: el peor p99 entre shards (no se pueden promediar percentiles).
  const worstP99 = Math.max(...shards.map((s) => s.rtt.p99 || 0));
  const cpu = readClientCpu(dir, stem);
  return { stem, shardCount: shards.length, seconds, acked, created, failed,
    throughput, errorRate, errors, worstP99, cpu };
}

function main() {
  const [rel, ...flags] = process.argv.slice(2);
  if (!rel) {
    console.error('Uso: node aggregate-sharded.js <SYSTEM>/<LABEL> [--json]');
    process.exit(2);
  }
  const dir = path.join(__dirname, 'results', rel);
  if (!fs.existsSync(dir)) {
    console.error(`No existe ${dir}`);
    process.exit(1);
  }
  const runs = [...collect(dir).entries()]
    .map(([stem, shards]) => summarize(stem, shards, dir))
    .sort((a, b) => a.acked - b.acked);
  if (runs.length === 0) {
    console.error(`Sin shards en ${dir}`);
    process.exit(1);
  }

  if (flags.includes('--json')) {
    console.log(JSON.stringify(runs, null, 2));
    return;
  }

  console.log(`# Corridas sharded — ${rel}\n`);
  console.log('| corrida | shards | fps totales | error | p99 peor (ms) | node max | máquina max |');
  console.log('|---|---|---|---|---|---|---|');
  for (const r of runs) {
    const node = r.cpu ? `${r.cpu.nodeMax.toFixed(0)}%` : '—';
    const mach = r.cpu ? `${r.cpu.totalMax.toFixed(0)}%` : '—';
    console.log(
      `| ${r.stem} | ${r.shardCount} | ${r.throughput.toFixed(1)} | ` +
      `${(r.errorRate * 100).toFixed(1)}% | ${r.worstP99.toFixed(0)} | ${node} | ${mach} |`
    );
  }
  console.log('');
  for (const r of runs) {
    if (Object.keys(r.errors).length) {
      console.log(`${r.stem}: ${Object.entries(r.errors).map(([k, v]) => `${k}=${v}`).join('  ')}`);
    }
  }
}

main();
