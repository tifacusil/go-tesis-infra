#!/usr/bin/env node
'use strict';

// aggregate-results.js — resume las corridas de la escalera de un sistema.
//
// Cada corrida de Artillery deja UN valor por métrica. Con una sola corrida por
// nivel no hay forma de saber si la diferencia entre dos niveles (o entre dos
// sistemas) es real o es ruido de esa corrida en particular, que es lo que
// pasaba con la escalera original. run-all.sh corre REPEATS veces cada nivel y
// esto agrega las N: mediana, media, desvío e intervalo de confianza al 95%,
// como reporta el estudio metodológico base (El Fellah et al. 2026).
//
// Uso:
//   node load-tests/aggregate-results.js B
//   node load-tests/aggregate-results.js B --json
//
// Lee results/<SYSTEM>/vu-<nivel>-r<N>.json (y los vu-<nivel>.json viejos, sin
// sufijo de repetición, que cuentan como una sola corrida) más los
// .client-cpu.csv que deja run-all.sh.

const fs = require('fs');
const path = require('path');

// t de Student de dos colas al 95%, indexado por grados de libertad (n-1).
// Con 3 corridas el multiplicador es 4.303, no 1.96: el intervalo sale ancho
// a propósito, y ese ancho ES el resultado — dice cuánto NO se puede afirmar
// con 3 corridas.
const T95 = [NaN, 12.706, 4.303, 3.182, 2.776, 2.571, 2.447, 2.365, 2.306, 2.262];

function tValue(n) {
  const df = n - 1;
  if (df < 1) return NaN;
  return df < T95.length ? T95[df] : 1.96;
}

function median(xs) {
  const s = [...xs].sort((a, b) => a - b);
  const mid = s.length >> 1;
  return s.length % 2 ? s[mid] : (s[mid - 1] + s[mid]) / 2;
}

function stats(xs) {
  const values = xs.filter((x) => Number.isFinite(x));
  const n = values.length;
  if (n === 0) return null;
  const mean = values.reduce((a, b) => a + b, 0) / n;
  if (n === 1) return { n, mean, median: mean, sd: 0, ci: NaN };
  const variance = values.reduce((a, b) => a + (b - mean) ** 2, 0) / (n - 1);
  const sd = Math.sqrt(variance);
  return { n, mean, median: median(values), sd, ci: tValue(n) * (sd / Math.sqrt(n)) };
}

const EMPTY_CPU = { mean: NaN, max: NaN, nodeMean: NaN, nodeMax: NaN, pythonMean: NaN };

function readClientCpu(jsonPath) {
  const csv = jsonPath.replace(/\.json$/, '.client-cpu.csv');
  if (!fs.existsSync(csv)) return EMPTY_CPU;
  // unix_ts,cpu_percent[,node_percent,python_percent] — las corridas anteriores
  // al muestreo por proceso solo tienen la primera columna.
  const rows = fs
    .readFileSync(csv, 'utf8')
    .split('\n')
    .slice(1)
    .map((line) => line.split(',').map(Number))
    .filter((cols) => Number.isFinite(cols[1]));
  if (rows.length === 0) return EMPTY_CPU;
  const col = (i) => rows.map((c) => c[i]).filter((v) => Number.isFinite(v));
  const mean = (xs) => (xs.length ? xs.reduce((a, b) => a + b, 0) / xs.length : NaN);
  const max = (xs) => (xs.length ? Math.max(...xs) : NaN);
  const total = col(1);
  const node = col(2);
  return {
    mean: mean(total),
    max: max(total),
    nodeMean: mean(node),
    nodeMax: max(node),
    pythonMean: mean(col(3)),
  };
}

// Una corrida -> las métricas que interesan del ladder.
function readRun(file) {
  const { aggregate: a } = JSON.parse(fs.readFileSync(file, 'utf8'));
  const counters = a.counters || {};
  const rtt = a.summaries?.['dtu_tcp.round_trip_ms'] || {};
  // Ventana real de la corrida, no la declarada en el YAML: si Artillery se
  // quedó esperando VUs colgados al final, la declarada infla el throughput.
  const seconds = (a.lastCounterAt - a.firstCounterAt) / 1000;
  const created = counters['vusers.created'] || 0;
  const failed = counters['vusers.failed'] || 0;
  const acked = counters['dtu_tcp.frames_acked'] || 0;
  const cpu = readClientCpu(file);
  return {
    file: path.basename(file),
    seconds,
    acked,
    created,
    failed,
    throughput: seconds > 0 ? acked / seconds : NaN,
    errorRate: created > 0 ? failed / created : NaN,
    p50: rtt.p50,
    p90: rtt.p90,
    p95: rtt.p95,
    p99: rtt.p99,
    clientCpuMean: cpu.mean,
    clientCpuMax: cpu.max,
    clientNodeMean: cpu.nodeMean,
    clientNodeMax: cpu.nodeMax,
    clientPythonMean: cpu.pythonMean,
  };
}

function collect(resultsDir) {
  const byLevel = new Map();
  for (const name of fs.readdirSync(resultsDir).sort()) {
    const m = /^vu-(\d+)(?:-r(\d+))?\.json$/.exec(name);
    if (!m) continue;
    const level = m[1];
    if (!byLevel.has(level)) byLevel.set(level, []);
    byLevel.get(level).push(readRun(path.join(resultsDir, name)));
  }
  return byLevel;
}

const FIELDS = [
  ['throughput', 'fps sostenidos', 1],
  ['errorRate', 'tasa de error', 4],
  ['p50', 'RTT p50 (ms)', 1],
  ['p90', 'RTT p90 (ms)', 1],
  ['p95', 'RTT p95 (ms)', 1],
  ['p99', 'RTT p99 (ms)', 1],
  ['clientCpuMean', 'CPU cliente media (% de la máquina)', 1],
  ['clientCpuMax', 'CPU cliente max (% de la máquina)', 1],
  // Node es de un solo hilo: 100 = un core saturado. Es el número que decide
  // si la corrida midió el servidor o el generador de carga; el total de la
  // máquina no puede mostrarlo (un core de 16 son 6.25%).
  ['clientNodeMean', 'CPU engine Node media (% de 1 core)', 1],
  ['clientNodeMax', 'CPU engine Node max (% de 1 core)', 1],
  ['clientPythonMean', 'CPU pool Python media (% de 1 core)', 1],
];

function fmt(value, digits) {
  return Number.isFinite(value) ? value.toFixed(digits) : '—';
}

function main() {
  const [system, ...flags] = process.argv.slice(2);
  if (!system) {
    console.error('Uso: node aggregate-results.js <SYSTEM> [--json]');
    process.exit(2);
  }
  const resultsDir = path.join(__dirname, 'results', system);
  if (!fs.existsSync(resultsDir)) {
    console.error(`No existe ${resultsDir}`);
    process.exit(1);
  }

  const byLevel = collect(resultsDir);
  if (byLevel.size === 0) {
    console.error(`Sin resultados en ${resultsDir}`);
    process.exit(1);
  }

  const summary = {};
  for (const [level, runs] of byLevel) {
    summary[level] = { runs: runs.length, files: runs.map((r) => r.file) };
    for (const [key] of FIELDS) {
      summary[level][key] = stats(runs.map((r) => r[key]));
    }
  }

  if (flags.includes('--json')) {
    console.log(JSON.stringify(summary, null, 2));
    return;
  }

  console.log(`# Escalera — Sistema ${system}\n`);
  for (const [key, label, digits] of FIELDS) {
    console.log(`## ${label}\n`);
    console.log('| VU | corridas | mediana | media | sd | IC 95% |');
    console.log('|---|---|---|---|---|---|');
    for (const level of [...byLevel.keys()].sort((a, b) => Number(a) - Number(b))) {
      const s = summary[level][key];
      if (!s) {
        console.log(`| ${Number(level)} | ${summary[level].runs} | — | — | — | — |`);
        continue;
      }
      const ci = Number.isFinite(s.ci) ? `± ${fmt(s.ci, digits)}` : 'n=1, sin IC';
      console.log(
        `| ${Number(level)} | ${s.n} | ${fmt(s.median, digits)} | ${fmt(s.mean, digits)} | ${fmt(s.sd, digits)} | ${ci} |`
      );
    }
    console.log('');
  }
}

main();
