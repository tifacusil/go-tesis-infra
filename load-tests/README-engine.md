# Custom TCP engine — setup

Sensor ingestion in this system happens over raw TCP (binary DTU frames) to
`data-receiving:5000-5002`, **not** HTTP. Artillery's built-in `http` engine
cannot send these frames, so the scenarios in `scenarios/` use a custom engine:
`load-tests/artillery-engine-dtu-tcp/` (Artillery's config/phases/reporting),
which delegates actual frame building + TCP send/ACK to
[`dtu-emulator`](../../dtu-emulator) (Python sender) — see below.

## Architecture

Each `send` flow step spawns one subprocess:

```
python -m sender fixture --file <contract-example.json> --count 1 --rate 0 \
  --host <host> --port <port> --no-retry --ack-timeout <n>
```

against the contract example for `spec.sensorType` (default `gnss`), then
parses dtu-emulator's `ack=<STATUS> in <N>ms` log line to report
success/failure and latency back to Artillery.

**Why shell out instead of building frames in JS:** dtu-emulator is the
canonical, contract-validated frame encoder (`src/sender/frame.py`,
`envelope.py`, `payloads.py`, synced from the Tarea 0 contracts repo via
`tools/sync_contracts.sh`). Reusing it means load-test traffic can never drift
from the real wire format. The previous engine (`dtu-frame.js`, now removed)
duplicated this encoding by hand and only supported `gnss`.

**Tradeoff:** measured `dtu_tcp.round_trip_ms` includes Python interpreter
startup for each request, not just network + server ACK time. At high VU
counts (100/400) this also means that many concurrent `python` processes
spawning per second — expect higher CPU overhead on the machine running
Artillery than the old pure-JS engine had.

### `send` flow step fields

| Field | Default | Description |
|---|---|---|
| `sensorType` | `gnss` | One of `gnss`, `rainfall`, `strain`, `soil_pressure`, `deep_displacement` — selects the contract example under `dtu-emulator/contracts/examples/`. |
| `contractFile` | (mapped from `sensorType`) | Override to point at a different contract example filename. |
| `seed` | none | Forwarded to `--seed` for reproducible payloads. |
| `corrupt` | none | Forwarded to `--corrupt` (`crc`, `sync_start`, `sync_end`, `length`, `version`, `type`, `schema`, `random`) to test C#-side error handling. |

Per-field payload overrides (e.g. the old `projectId`/`fixQuality`) are **not**
supported — dtu-emulator's fixture mode randomizes payload fields itself and
sources `project_id`/`sensor_id`/`sampling_interval_seconds` from the contract
example file's own top-level fields. To change those, edit or add a contract
example under `dtu-emulator/contracts/examples/`, or point `contractFile` at
a different one.

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
(`../../dtu-emulator` relative to `artillery-engine-dtu-tcp/index.js`, i.e.
`go-tesis-infra/../dtu-emulator`). Override with `DTU_EMULATOR_PATH` if your
checkout lives elsewhere:

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
PYTHONPATH="$DTU_EMULATOR_PATH/src" ${DTU_EMULATOR_PYTHON:-py} -m sender fixture --help
```

If the first fails with `Cannot find module`, `NODE_PATH` isn't set correctly
or you're not in `load-tests/`. If the second fails with `ModuleNotFoundError:
No module named 'sender'`, `DTU_EMULATOR_PATH` is wrong or dtu-emulator hasn't
been cloned as a sibling directory.
