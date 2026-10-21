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
- **Criteria:** AC-1, AC-2, AC-3, AC-4, AC-5, AC-6, AC-7, AC-8, AC-9, AC-10, AC-11, AC-12, AC-13, AC-14, AC-15
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
  memory, CPU and PostgreSQL cluster; read: the server's current state,
  read only (its systemd and PostgreSQL versions, PostgreSQL's local
  authentication, and the `cvwriter` unit and folder left from an earlier
  setup); the build PR reads it again and attaches the record before it
  changes anything. WATCH holds only if that read shows the earlier
  `cvwriter` unit disabled and not running, and nothing listening where
  the shared site's old `/cvwriter/` path would send traffic; if it shows
  otherwise, the build stops and the slice is re-planned; the architecture's Server units and
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
  `scripts/deploy.sh`), one outcome (the release runs only if healthy). The
  app's own code (the `serve` command, its health and not-found answers,
  its start-up errors and log line) is in this SHARED slice because neither
  half works alone: the units and the deploy script have nothing to run or
  health-check without it, and it can't run on the server without them.
  Estimated about 340 product-code lines: the `serve` command, the health
  and not-found handlers, the logger, `go.mod`, `.env.example`, two unit
  files, `scripts/build-release.sh` and `scripts/deploy.sh`. Split out of
  the first slice list because the whole first slice was estimated over the
  diff flag (brief, "Rough slice list").
- **Locked checks:** three `CHECK` groups in one script, no REGRESSION
  groups.
  - CHECK 1, the app (AC-1 to AC-8), on a real PostgreSQL 18.6: health 200
    with exactly `{"status":"ok"}`; a database that answers after about
    1.7 s gives 200, one that answers after about 2.5 s, hangs or is stopped gives
    503 within 3 s as `application/problem+json` with only `type`, `title`
    and `status`, naming no path, role, database or driver error; `GET /`, `GET /api/me` and `POST /api/health` give 404 the
    same way; no TCP or UDP port; every log line is JSON with `service` and
    `version`, with `invocation_id` when `INVOCATION_ID` is set and without
    it when not, and releases the deploy starts log their own version; an
    unknown command exits 2 without echoing it, a missing
    `CVWRITER_DATABASE_URL` or socket exits 1 naming it, each as a line
    under 80 characters on standard error.
  - CHECK 2, the deploy script (AC-9 to AC-13, AC-15): `s001-a`, `s001_b.2` and a
    64-character version deploy in turn and earlier folders stay; the
    earlier `s001-a`, deployed again, is unpacked afresh; a release healthy
    after about 9 s is kept and one healthy only after about 12 s is
    switched back, as is one that answers in time with 503, each with the
    earlier release's unit files installed again and healthy; on a fresh
    root, a first release healthy after about 9 s is kept, and one healthy
    only after about 12 s or answering 503 leaves the app and socket stopped
    and no `current`; the running version, an empty version, `.`,
    `..`, `../x`, `-a`, `a b`, `a;b`, `s001-é` and 65 characters are
    refused with nothing changed; a release archived with group- and
    world-writable files, deployed under umask 000 so a plain unpack would
    keep them, unpacks with neither.
  - CHECK 3, the unit files (AC-14): the socket's only listener, user,
    group and mode; the service's command, user, socket, restart, memory
    limits, database URL (no password, no environment file) and the five
    hardening settings.
  - Not provable without root, so recorded on the server in the build PR
    instead: that release files are owned by root (AC-13; unprivileged,
    `tar` can't keep another owner, so that case can't fail in CI), and the
    socket's real owner, group and mode, and the service's hardening, as
    systemd applies them (`stat`, `systemctl show`).
  LOCKED: acceptance/walking-skeleton/s001-runs-on-server.sh
- **Flags added:** none
- **Risks scanned:** 1 and 2 (the database hangs, answers late or is
  down: 503 within 3 s); 5, 6, 12 and 15 (a release version that is the
  running one, empty, or breaks the version rule: `.`, `..`, `../x`, a
  leading `-`, a space, `;`, a non-ASCII letter: refused); 14 (the 2-second
  database limit (about 1.7 s and 2.5 s), the 10-second wait for first and
  later releases (about 9 s and 12 s), and the 64-character version, each
  with a case on either side); 6 again (a version whose folder exists but
  isn't running is unpacked afresh); 22 (`/api/health`
  returns no data, the 503 names nothing, the unit holds no password, and
  nothing outside the server reaches the app); 23 (no records exist); 25
  (the `cvwriter` unit and folder left from an earlier setup predate
  ADR-005's subdomain and socket: the unit is replaced, a copy is kept for
  the undo, and the earlier environment file and any proxy location for the
  old path stay until the slices that replace them; the build PR records
  what was there); 26 (the database pool: a 2-second limit on each health
  ping, a connect time limit and at most 2 connections, set in code); 27
  (no callers yet: nothing reaches the app until slice 3).
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
    stack file's checks but golangci-lint, whose cut the brief gives.
- **Intermediate state:** intended, no flag. The app runs on the server,
  reachable only through its local socket: no nginx server block, no DNS
  record, no Access. Deploys are by hand. The database is still owned by
  the app's role, and the earlier setup's environment file stays, until the
  slice that adds the first table splits the roles. No alerts until slice 4.
- **Undo:** revert the PR. On the server: `systemctl disable --now
  cvwriter.socket cvwriter.service`, put back the earlier unit file (copied
  aside before the first deploy), `systemctl daemon-reload`; release folders
  can stay. Going back to the earlier release is AC-10, tested by CHECK 2.
  The server's cvwriter units are the non-live copy the undo runs on:
  nothing reaches them yet (no nginx, no DNS record). The full undo runs
  there before the slice is merged, and its output is attached to the build
  PR, with `systemctl --failed` before and after.

```text
Open questions:     none
```
