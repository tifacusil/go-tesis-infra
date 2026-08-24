# Custom TCP engine — setup

Sensor ingestion in this system happens over raw TCP (binary DTU frames) to
`data-receiving:5000-5002`, **not** HTTP. Artillery's built-in `http` engine
cannot send these frames, so the scenarios in `scenarios/` use a custom engine:
`load-tests/artillery-engine-dtu-tcp/` (Artillery's config/phases/reporting),
which delegates actual frame building + TCP send/ACK to
[`dtu-emulator`](../../dtu-emulator) (Python sender) — see below.

## Architecture

Every scenario in `scenarios/` has exactly **one** `send` step per VU flow —
a VU here IS one frame, there's no sequence of sends within a VU to amortize
anything over. So instead of spawning a fresh Python process per `send` step
(the original design — paid ~224ms interpreter startup on every single
frame), the engine keeps a small pool of long-lived worker subprocesses alive
for the whole Artillery run:

```
python -m sender stream --host <host> --port <port> --no-retry --ack-timeout <n>
```

Each worker holds **one persistent TCP connection** and reads frame-send
requests as JSON lines from stdin, writing one JSON-line ACK result per
request to stdout — see `stream_mode.py` in dtu-emulator for the protocol.
`send` steps from many VUs are dispatched onto the pool round-robin; each
worker processes its queued requests strictly in order (write request line →
read response line) over its one connection, so responses always match the
request that produced them without needing request IDs.

If a worker process dies unexpectedly (crash, connection reset the transport
couldn't recover from with `--no-retry`), the engine detects the exit, fails
any requests that were in flight on that worker, and transparently respawns
it after a 1s breather (so a crash-on-start bug can't become a tight spawn
storm) — logged to stderr as `[dtu-tcp] ... is down (...) — respawning`. All
pool workers are killed on process exit / SIGINT / SIGTERM so a run never
leaves orphaned Python processes or open connections behind.

Every dispatched `send` also carries a client-side timeout
(`DTU_ENGINE_SEND_TIMEOUT_MS`, default 120000): if a request sits queued +
in flight on a worker longer than that, its VU fails with
`pool_dispatch_failed` instead of waiting forever. The Python worker already
bounds each network operation at 5s, so this never fires in a healthy run —
it exists because Artillery only exits once every VU has completed, and a
single wedged worker without this ceiling would leave the run (e.g. the 12h
endurance one) hanging indefinitely after its phases finish.

**Why shell out instead of building frames in JS:** dtu-emulator is the
canonical, contract-validated frame encoder (`src/sender/frame.py`,
`envelope.py`, `payloads.py`, synced from the Tarea 0 contracts repo via
`tools/sync_contracts.sh`). Reusing it means load-test traffic can never drift
from the real wire format. The previous engine (`dtu-frame.js`, now removed)
duplicated this encoding by hand and only supported `gnss`.

### Pool size

The pool defaults to the scenario's peak `arrivalRate`/`rampTo` (read from
`config.phases`), so the number of concurrent persistent connections roughly
matches the busiest moment of the scenario — e.g. `vu-100.yml` gets a
100-worker pool, `vu-400.yml` gets 400. Override explicitly with:

```bash
export DTU_ENGINE_POOL_SIZE=50
```

**Both numbers are totals for the whole `artillery run`, not per worker
thread.** Artillery splits a local run across `os.cpus().length - 1` worker
threads, and this engine is loaded once per thread — so a pool size taken at
face value in every thread is multiplied by the core count. Two things keep
that from happening:

- The phase-derived default needs no correction: Artillery hands each thread a
  script whose phases are *already divided* (15 threads at 100 req/s → each
  thread reads a peak of 7).
- `DTU_ENGINE_POOL_SIZE` **is** divided by the engine, using the `totalWorkers`
  Artillery stamps on each phase.

Templating is not an obstacle to either: `{{ $processEnvironment.SUSTAINED_RATE }}`
is resolved *before* the script is split, so each thread sees a plain number.
The earlier claim that `vu-sustained-12h.yml` *required* the override because
the engine "can't read the template" was wrong — the override is kept there
only to state the intended total explicitly.

If no override is set and no numeric peak can be found anywhere in
`config.phases`, the engine falls back to 50 per thread and logs nothing.

> Sizing this wrong is not a client-side detail. At `DTU_ENGINE_POOL_SIZE=100`
> undivided, a 16-core laptop opened 1500 connections instead of 100 and
> overran nginx's stream ceiling on Sistema A (`768 worker_connections are not
> enough while connecting to upstream`) 60s into the 12h ramp, with every
> data-receiving instance healthy. The connection budget of the target is part
> of the experiment.

**Tradeoff:** measured `dtu_tcp.round_trip_ms` still includes one Python
`stream` worker between the wire and the JSON response, but each worker now
serves many frames over one connection instead of one process per frame — the
per-frame interpreter-startup cost is gone. A smaller pool than peak VU
concurrency (e.g. via `DTU_ENGINE_POOL_SIZE` set low deliberately) means
multiple VUs' frames funnel through the same TCP connection sequentially,
which no longer maps 1:1 to "N simultaneous sensors" — keep the default
peak-rate sizing unless you have a specific reason to shrink it.

### `send` flow step fields

| Field | Default | Description |
|---|---|---|
| `sensorType` | `gnss` | One of `gnss`, `rainfall`, `strain`, `soil_pressure`, `deep_displacement` — selects the contract example under `dtu-emulator/contracts/examples/`. |
| `contractFile` | (mapped from `sensorType`) | Override to point at a different contract example filename. |
| `seed` | none | Forwarded to `--seed` for reproducible payloads. |
| `corrupt` | none | Forwarded to `--corrupt` (`crc`, `sync_start`, `sync_end`, `length`, `version`, `type`, `schema`, `random`) to test C#-side error handling. |
| `sensorCount` | `DTU_SENSOR_COUNT`, else `100` | Size of the sensor fleet the run is spread over — see below. |

Per-field payload overrides (e.g. the old `projectId`/`fixQuality`) are **not**
supported — dtu-emulator randomizes payload fields itself and sources
`project_id`/`sampling_interval_seconds` from the contract example file's own
top-level fields. To change those, edit or add a contract example under
`dtu-emulator/contracts/examples/`, or point `contractFile` at a different one.

### Sensor fleet

`sensor_id` used to come from the contract example too, so an entire run came
from one sensor. That breaks the measurement in two independent ways:

- Threshold evaluation is stateful **per sensor**, so per-sensor identity is the
  natural shard key for the early-warning consumer. One `sensor_id` collapses
  every worker onto one shard — the sensor-sharded pool added in
  `go-early-warning` measured exactly zero improvement — and funnels the whole
  run's read-modify-write traffic through a single Redis key.
- One sensor at 400 fps is ~1.4 million times the per-sensor sampling rate of
  the system being replicated (Bai et al. 2020 sample hourly), which is what
  made the pre-fix corpus produce a `red` alert on ~5% of messages.

The engine now owns fleet identity: each `send` is assigned a sensor from a
fleet of `sensorCount` round-robin, and carries the index of that sensor's
reading in the series. dtu-emulator turns `(sensor_id, reading_index)` into a
physically consistent reading — monotonic cumulative displacement, hourly
timestamps, deformation speeds in mm/day (see `dtu-emulator/src/sender/field.py`
and its README section). Reading counters live in the engine because it is the
one process that sees the whole run; the workers stay interchangeable and a
respawn does not lose a series.

```bash
export DTU_SENSOR_COUNT=100   # default
export DTU_SENSOR_COUNT=0     # pre-fix corpus: one sensor, random payload per frame
export DTU_SENSOR_BASE=34     # shift this process's id range (see below)
```

Keep `sensorCount` ≥ the number of early-warning consumer workers, or the
sharding has nothing to spread. Raising it toward the paper's 3,233 sensors is
the fleet-scale sweep; note that at low arrival rates a large fleet means most
frames are a sensor's *first* reading, which has no baseline to evaluate
against and therefore never alerts.

### Splitting a run across machines (`DTU_SENSOR_BASE`)

`DTU_SENSOR_BASE` shifts this process's sensor-id range. The reading counter
lives per process, so two processes on the same `sensor_id` would hand it the
same `reading_index` — same timestamp, and the engine drops the duplicate
(`dt<=0`). With disjoint bases (process *k* of *N* uses `[k·count, (k+1)·count)`)
each sensor is written by exactly one process and its series stays intact.

**This does not raise the throughput ceiling on a single machine — don't use it
for that.** `run-sharded.sh` was written believing the ceiling was Node's
single-threaded event loop, but Artillery v2 already runs scenarios in worker
threads across cores (measured: one `artillery run` reached `node_max` 432%).
Adding processes adds no CPU; it only multiplies the Python pool, which is the
real client-side limit — dtu-emulator opens one OS process per connection, and
on Windows that exhausts kernel socket resources (`WinError 8`/`10055`) before
the server is stressed. See `docs/ladder-b-2026-07-22.md` §5. To actually raise
the client ceiling, rewrite the generator as a single async process, or generate
from Linux.

Where it *is* useful: driving one load level from **several client machines** at
once, each with its own `DTU_SENSOR_BASE` and fleet range, so the sensor series
stay consistent across the whole run.

```bash
# On machine A: sensores [0,50)   ·   on machine B: DTU_SENSOR_BASE=50, [50,100)
TARGET_HOST=178.105.104.95:5000 RATE=150 SHARDS=1 FLEET=50 ./load-tests/run-sharded.sh
node load-tests/aggregate-sharded.js B/sharded   # throughput is the SUM of shards
```

`POOL_PER_SHARD` caps the Python connections per process; it defaults to
`ceil(rate·0.4)` (roughly `rate·RTT`), because one connection per frame/s spawns
hundreds of OS processes and thrashes the client.

## One-time / per-shell setup

Every script that runs `artillery run` (`run-all.sh`, `run-all-burst.sh`,
`run-endurance.sh`) already exports `NODE_PATH` before invoking `artillery` —
you don't need to set it by hand for a normal run through those scripts.

If you run `artillery run` directly (bypassing the wrapper scripts, e.g. for
a one-off manual test), set it yourself first:

```bash
cd tesis-infra/load-tests
export NODE_PATH="$(pwd)"
artillery run scenarios/vu-001.yml
```

Git Bash/MINGW64 note: `NODE_PATH` is read once at Node process startup, so it
must be exported in the same shell session before `artillery` runs — exporting
it in a different terminal or after Artillery has already started has no effect.

### dtu-emulator location and Python

The engine looks for `dtu-emulator` as a sibling of this repo's checkout
(`../../../dtu-emulator` relative to `artillery-engine-dtu-tcp/index.js`, i.e.
one level above `tesis-infra/` — `tesis-infra/../dtu-emulator`). If your clone
of `dtu-emulator` lives anywhere else (e.g. a different parent folder, like
`Documents/Github/dtu-emulator` vs. `tesis-infra`'s own parent), the default
will NOT find it and every `send` step will fail — override with
`DTU_EMULATOR_PATH`:

```bash
export DTU_EMULATOR_PATH=/path/to/dtu-emulator
```

No `pip install` is required — the engine runs `python -m sender` with
`PYTHONPATH` pointed at `dtu-emulator/src` directly. It does need a working
Python 3.10+ interpreter on `PATH`; it tries `python3`, `python`, then `py` (the
Windows launcher) in that order, or set `DTU_EMULATOR_PYTHON` to force one:

```bash
export DTU_EMULATOR_PYTHON=py   # or python3, or a full path
```

If dtu-emulator's dependencies (`jsonschema`) aren't installed anywhere on
that interpreter's path, fixture mode still works — the schema sanity check
is best-effort and only logs a warning on failure.

`run-all.sh`, `run-all-burst.sh`, and `run-endurance.sh` all validate
`DTU_EMULATOR_PATH` resolution + a working Python interpreter **before**
starting Artillery (`lib/check-dtu-emulator.sh`) — a misconfigured path fails
fast with a clear message instead of silently failing every request mid-run.
This matters most for `run-endurance.sh`: without the upfront check, a wrong
path would only surface after the full 12h run, with the entire dataset
useless (every `send` step would have failed).

## Target format changed

Scenarios using this engine set `config.target: "<host>:<port>"` (e.g.
`204.168.203.32:5000`) — ingestion is TCP, not HTTP, so `TARGET_HOST` should
be exported as bare `host:port` (or just `host`, defaults to port `5000`).

For convenience, `TARGET_HOST=http://204.168.203.32` or
`https://204.168.203.32:5000` also work — the engine strips a leading
`http(s)://` if present, since that was the pattern used before the TCP
migration and is easy to type out of habit. It's still not a real HTTP
request under the hood; the scheme is just ignored.

## Verifying the engine works before a real run

```bash
cd tesis-infra/load-tests
node -e "require('./artillery-engine-dtu-tcp')" && echo "engine loads OK"

# and confirm dtu-emulator itself is reachable/importable:
PYTHONPATH="$DTU_EMULATOR_PATH/src" ${DTU_EMULATOR_PYTHON:-py} -m sender stream --help
```

If the first fails with `Cannot find module`, `NODE_PATH` isn't set correctly
or you're not in `load-tests/`. If the second fails with `ModuleNotFoundError:
No module named 'sender'`, `DTU_EMULATOR_PATH` is wrong or dtu-emulator hasn't
been cloned as a sibling directory.
