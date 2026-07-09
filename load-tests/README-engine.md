# Custom TCP engine — setup

Sensor ingestion in this system happens over raw TCP (binary DTU frames) to
`data-receiving:5000-5002`, **not** HTTP. Artillery's built-in `http` engine
cannot send these frames, so the scenarios in `scenarios/` use a custom engine:
`load-tests/artillery-engine-dtu-tcp/` (opens a raw TCP socket, builds the
binary frame — `SYNC_START | VER | TYPE | LEN | PAYLOAD | CRC | SYNC_END`,
per `go-data-receiving/internal/parsing/frame.go` — writes it, reads the 5-byte
ACK, reports success/failure to Artillery).

## Why this needs extra setup (read before your first run)

Artillery resolves a custom engine named `foo` via a bare
`require('artillery-engine-foo')` — **plain Node module resolution only**.
There is no way to point it at a local file/relative path directly from the
scenario YAML. Since this engine isn't published to npm (it's specific to
this repo's wire protocol), Node needs `NODE_PATH` set to `load-tests/` itself
so `require('artillery-engine-dtu-tcp')` resolves to
`load-tests/artillery-engine-dtu-tcp/index.js` — the directory name **must**
match the required module name exactly, which is why it's not just `engine/`.

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
```

If this fails with `Cannot find module`, `NODE_PATH` isn't set correctly or
you're not in `load-tests/`.
