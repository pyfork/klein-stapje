# Plan: walking-skeleton

<!-- senior-lead-Opus5.5-agent, 2026-10-20. Grows by one slice per slice-plan PR. -->

- **Brief:** specs/features/walking-skeleton/brief.md (with its Shape)
- **Shared standards:** the JSON log line, built in slice 1; the sign-in
  check on every route, slice 3; traces, metrics and alerts, slice 4; field
  errors and the loading state on save, slice 5 (brief, "Shared standards
  still missing")
- **Flags:** none

## Owed
- None: this is the feature's first slice.

## Slice 1
- **Slice brief:** specs/features/walking-skeleton/S-001.md
- **Statement:** When the owner deploys a release by hand, the server runs it only if its health check passes
- **Criteria:** AC-1, AC-2, AC-3, AC-4, AC-5, AC-6, AC-7, AC-8, AC-9, AC-10, AC-11
- **Risk class:** SHARED. No feature in this repository relies on the
  shared pieces yet, and no tests exist yet. On the server, the other sites
  share systemd, the PostgreSQL 18 cluster and the memory. This slice adds
  units of its own, connects as its own role and changes no shared
  configuration: no nginx file, no PostgreSQL setting, no package. The build
  PR records `systemctl --failed` and the server's available memory before
  and after the first deploy.
- **Depth:** WATCH; undo: easy, because nothing is stored, nothing outside
  the server reaches the app (no nginx, no DNS record), and the undo is two
  `systemctl` commands and the earlier unit file put back; spread: large,
  because the units run on a server shared with other sites, which share its
  memory, CPU and PostgreSQL cluster; read: the server's current state, read
  only on 2026-10-20 (its systemd and PostgreSQL versions, PostgreSQL's local
  peer authentication, and the `cvwriter` unit and folder left from an
  earlier setup, which is disabled; the build PR attaches this read before it
  changes anything), the architecture's Server units and
  Deploy order, threat model T-34, T-36 and T-41, ADR-003, the go-chi stack
  file's production checks, and the Command-line error pattern.
- **Threat model:** unchanged, because this slice builds T-36 (a unix
  socket only nginx's group can open, no TCP port) and the sandboxed units
  of T-34 as written, adds no route but the public `/api/health`, and
  deploys by hand, which is T-41's path.
- **Why here:** first. The deploy path (slice 2) needs a running app to
  switch to and back from, and sign-in (slice 3) can only be tried once the
  app runs on the server.
- **Why this size:** one statement, one trigger (the owner runs
  `scripts/deploy.sh`), one outcome (the release runs only if healthy).
  Estimated about 330 product-code lines: the `serve` command, the health
  and not-found handlers, the logger, `go.mod`, `.env.example`, two unit
  files, `scripts/build-release.sh` and `scripts/deploy.sh`. Split out of
  the first slice list because the whole first slice was estimated over the
  diff flag (brief, "Rough slice list").
- **Locked checks:** three `CHECK` groups in one script, no REGRESSION
  groups.
  - CHECK 1, the app (AC-1 to AC-6), on a real PostgreSQL 18.6: health 200
    with exactly `{"status":"ok"}`; a database that answers after about 1 s
    gives 200, one that hangs or is stopped gives 503 problem+json within
    3 s; `GET /`, `GET /api/me` and `POST /api/health` give 404
    problem+json; no TCP or UDP port; every log line is JSON with
    `service` and `version`, with `invocation_id` when `INVOCATION_ID` is
    set and without it when not; an unknown command exits 2 without echoing
    it, a missing `CVWRITER_DATABASE_URL` or socket exits 1 naming it, each
    as one line under 80 characters on standard error.
  - CHECK 2, the deploy script (AC-7 to AC-10): two good releases deploy in
    turn and the first one's folder stays; a release healthy after about
    8 s is kept, one healthy only after about 12 s is switched back, with
    the earlier release's unit files installed again and healthy; a first
    release that never answers leaves the app and socket stopped and no
    `current`; the running version, `../x` and an empty version are
    refused with nothing changed.
  - CHECK 3, the unit files (AC-11): the socket's only listener, user,
    group and mode; the service's command, user, socket, restart, memory
    limits and the five hardening settings.
  LOCKED: acceptance/walking-skeleton/s001-runs-on-server.sh
- **Flags added:** none
- **Risks scanned:** 1 and 2 (the database hangs or is down: 503 within
  3 s); 5, 6 and 12 (a release version that is the running one, empty, or
  holds `../`: refused); 14 (the 2-second database limit and the 10-second
  deploy wait, each with a case on either side); 22 (`/api/health` returns
  no data, the 503 names nothing, and nothing outside the server reaches
  the app); 23 (no records exist); 25 (the unit and folder left from an
  earlier setup predate ADR-005's subdomain and socket: the unit is
  replaced, a copy is kept for the undo, and its environment file and the
  shared site's `/cvwriter/` location stay until the slices that replace
  them); 26 (the database pool: a 2-second limit on each health ping, a
  connect time limit and at most 2 connections, set in code); 27 (no
  callers yet: the shared site's `/cvwriter/` location already points at a
  port nothing listens on, and still will).
- **Budget touched:** A-3's memory trigger (free memory at peak under
  500 MB). The build PR records the server's available memory before and
  after the first deploy. `MemoryMax=256M` and `GOMEMLIMIT=200MiB` are
  starting values until slice 6 measures them.
- **Watch in production:** the server's available memory after each deploy,
  and the `cvwriter` service's restart count (`NRestarts`) staying at 0.
- **Decisions:**
  - The app takes its socket from systemd with Go's standard library (file
    descriptor 3, `LISTEN_FDS`, `LISTEN_PID`), not `coreos/go-systemd`:
    about 15 lines against a new dependency.
  - The app signs in to PostgreSQL over the local socket with peer
    authentication, not a password credential: nothing secret to store.
  - Every other route and method answers 404, not 405: nothing else exists
    until slice 3's route test lists the routes.
  - The deploy script's test seams. The CI check runs as a user with no
    root and no systemd manager, so `scripts/deploy.sh` reads four
    variables whose defaults are the server's values: `CVWRITER_ROOT`
    (`/sites/cvwriter`), `CVWRITER_UNIT_DIR` (`/etc/systemd/system`),
    `CVWRITER_SOCKET` (`/run/cvwriter.sock`) and `SYSTEMCTL` (`systemctl`).
    It calls systemctl only as `daemon-reload`, `enable --now
    cvwriter.socket`, `restart cvwriter.service` and `stop cvwriter.socket
    cvwriter.service`; the check's stand-in accepts nothing else. The
    option not taken: a container running systemd, which needs root on the
    runner. The real systemd run is recorded on the server in the build PR.
  - The release archive: `scripts/build-release.sh <version>` writes
    `dist/cvwriter-<version>.tar.gz` holding `cvwriter`, `version`,
    `systemd/cvwriter.socket` and `systemd/cvwriter.service`. By hand, the
    version names the commit; slice 2's CI uses its run number.
  - The limits the spec left open: 2 s for the database to answer the
    health check, 3 s for the answer, 10 s for a new release to become
    healthy. Old release folders stay until slice 2 adds pruning.
  - Go tests join CI (brief, Out of scope): when the build PR opens, the
    owner sets `GUARD_TEST_COMMAND` to
    `test -z "$(gofmt -l .)" && go vet ./... && go test -race ./...`, the
    stack file's checks without golangci-lint, which joins with its config
    after the skeleton.
- **Intermediate state:** intended, no flag. The app runs on the server,
  reachable only through its local socket: no nginx server block, no DNS
  record, no Access. Deploys are by hand. The database is still owned by
  the app's role, and the earlier setup's environment file stays, until the
  slice that adds the first table splits the roles. No alerts until slice 4.
- **Undo:** revert the PR. On the server: `systemctl disable --now
  cvwriter.socket cvwriter.service`, put back the earlier unit file (copied
  aside before the first deploy), `systemctl daemon-reload`; release folders
  can stay. Going back to the earlier release is AC-8, tested by CHECK 2.
  The full undo is run on the server before anything depends on cvwriter
  there (nothing reaches it yet), and its output is attached to the build
  PR, with `systemctl --failed` before and after.

```text
Open questions:     none
```
