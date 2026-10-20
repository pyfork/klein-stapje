#!/usr/bin/env bash
# senior-lead-Opus5.5-agent, 2026-10-20. Locked check for walking-skeleton
# slice 1 (specs/features/walking-skeleton/S-001.md, AC-1 to AC-14).
#
# Runs as an unprivileged user on a fresh Linux x86_64 machine: no root, no
# systemd manager. It brings its own Go and PostgreSQL, pinned by SHA-256,
# and starts the app on a socket passed as file descriptor 3 with
# LISTEN_FDS and LISTEN_PID set, the way systemd's socket unit hands it over.
# The deploy script runs against a scratch root with a stand-in for
# systemctl (the plan's "deploy script's test seams"); the real systemd run
# is recorded on the server in the build PR.
#
#   CHECK 1  the app: AC-1 to AC-8
#   CHECK 2  the deploy script: AC-9 to AC-13
#   CHECK 3  the unit files: AC-14
set -euo pipefail

GO_VERSION=1.27.3
GO_SHA256=65efbc80fdc1fa2cd2631cad5b481777a68e8725f34e89f50fc6ac714e379b40
PG_VERSION=18.6.0
PG_SHA256=008ee189eaa7ca2b58bd01dd950291e638b998392cf982297acd4779ec898ac1

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d)"
APP_PIDS=()

fail() { echo "FAIL: $*"; exit 1; }
ok() { echo "ok: $*"; }

pg_pids() { local pm; pm="$(head -n1 "$WORK/pgdata/postmaster.pid")"; echo "$pm $(pgrep -P "$pm" | tr '\n' ' ')"; }
cleanup() {
  local p
  for p in "${APP_PIDS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null || true; done
  [ -f "$WORK/fake/pid" ] && kill "$(cat "$WORK/fake/pid")" 2>/dev/null || true
  if [ -f "$WORK/pgdata/postmaster.pid" ]; then
    kill -CONT $(pg_pids) 2>/dev/null || true
    "$WORK/pg/bin/pg_ctl" -D "$WORK/pgdata" -m immediate stop >/dev/null 2>&1 || true
  fi
  rm -rf "$WORK" "$ROOT_DIR/dist"
}
trap cleanup EXIT

# ---------------------------------------------------------------- setup
[ "$(uname -s)-$(uname -m)" = "Linux-x86_64" ] || fail "needs Linux x86_64 (found $(uname -s)-$(uname -m))"
for t in curl python3 ss tar unzip xz sha256sum pgrep find; do
  command -v "$t" >/dev/null || fail "needs $t on PATH"
done

# activate.py <socket path> <command...>: binds the socket, puts it on fd 3,
# sets LISTEN_FDS=1 and LISTEN_PID, and execs the command in the same process
cat >"$WORK/activate.py" <<'PY'
import os, socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(sys.argv[1]); s.listen(64)
if s.fileno() != 3:
    os.dup2(s.fileno(), 3)
os.set_inheritable(3, True)
env = dict(os.environ, LISTEN_FDS="1", LISTEN_PID=str(os.getpid()))
os.execvpe(sys.argv[2], sys.argv[2:], env)
PY
export ACTIVATE="$WORK/activate.py"

curl -fsSL -o "$WORK/go.tgz" "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz"
echo "$GO_SHA256  $WORK/go.tgz" | sha256sum -c --quiet - || fail "Go download doesn't match its SHA-256"
tar -C "$WORK" -xzf "$WORK/go.tgz"
export PATH="$WORK/go/bin:$PATH" GOTOOLCHAIN=local GOFLAGS=-modcacherw \
  GOCACHE="$WORK/gocache" GOMODCACHE="$WORK/gomod" GOPATH="$WORK/gopath"

curl -fsSL -o "$WORK/pg.jar" \
  "https://repo1.maven.org/maven2/io/zonky/test/postgres/embedded-postgres-binaries-linux-amd64/${PG_VERSION}/embedded-postgres-binaries-linux-amd64-${PG_VERSION}.jar"
echo "$PG_SHA256  $WORK/pg.jar" | sha256sum -c --quiet - || fail "PostgreSQL download doesn't match its SHA-256"
mkdir -p "$WORK/pg" "$WORK/pgsock"
(cd "$WORK/pg" && unzip -q "$WORK/pg.jar" && tar -xJf postgres-linux-x86_64.txz)
"$WORK/pg/bin/initdb" -D "$WORK/pgdata" -U cvwriter --auth=trust >/dev/null
echo "CREATE DATABASE cvwriter;" | "$WORK/pg/bin/postgres" --single -D "$WORK/pgdata" postgres >/dev/null
pg_start() {
  "$WORK/pg/bin/pg_ctl" -D "$WORK/pgdata" -l "$WORK/pg.log" -w \
    -o "-c listen_addresses='' -k $WORK/pgsock" start >/dev/null
}
pg_stop() { "$WORK/pg/bin/pg_ctl" -D "$WORK/pgdata" -m fast -w stop >/dev/null; }
pg_pause() { kill -STOP $(pg_pids); }
pg_resume() { kill -CONT $(pg_pids); }
pg_start
export DB_URL="host=$WORK/pgsock dbname=cvwriter user=cvwriter"

# Releases come from the project's own build script (AC-9)
[ -f "$ROOT_DIR/scripts/build-release.sh" ] || fail "scripts/build-release.sh doesn't exist"
build() {
  (cd "$ROOT_DIR" && bash scripts/build-release.sh "$1" >/dev/null) || fail "build-release.sh $1 failed"
  [ -f "$ROOT_DIR/dist/cvwriter-$1.tar.gz" ] || fail "build-release.sh $1 made no dist/cvwriter-$1.tar.gz"
  cp "$ROOT_DIR/dist/cvwriter-$1.tar.gz" "$WORK/"
}
V64="s001-$(printf 'v%.0s' $(seq 59))"   # 64 characters
build s001-a
build s001_b.2
build "$V64"
[ "${#V64}" = 64 ] || fail "setup: the 64-character version is ${#V64} characters"
mkdir -p "$WORK/a"
tar -C "$WORK/a" -xzf "$WORK/cvwriter-s001-a.tar.gz"
for f in cvwriter version systemd/cvwriter.socket systemd/cvwriter.service; do
  [ -e "$WORK/a/$f" ] || fail "the release archive holds no $f"
done
[ "$(cat "$WORK/a/version")" = "s001-a" ] || fail "the release's version file doesn't say s001-a"
BIN="$WORK/a/cvwriter"

# health <socket> [method] [path] -> "<status> <seconds>"; body in $WORK/body,
# headers in $WORK/headers
health() {
  curl -s --max-time 10 --unix-socket "$1" -D "$WORK/headers" -o "$WORK/body" \
    -w '%{http_code} %{time_total}\n' -X "${2:-GET}" "http://localhost${3:-/api/health}" || echo "000 99"
}
problem_only() { # <status>: application/problem+json with only type, title, status
  grep -qiE '^content-type: application/problem\+json' "$WORK/headers" || return 1
  python3 - "$WORK/body" "$1" <<'PY' || return 1
import json, sys
b = json.load(open(sys.argv[1]))
assert isinstance(b, dict) and set(b) == {"type", "title", "status"}, b
assert b["status"] == int(sys.argv[2]), b
PY
}
within() { python3 -c "import sys; sys.exit(0 if float('$1') <= float('$2') else 1)"; }
start_app() { # <socket> <log file> [INVOCATION_ID]: serve on a fresh socket
  rm -f "$1"
  if [ -n "${3:-}" ]; then
    INVOCATION_ID="$3" CVWRITER_DATABASE_URL="$DB_URL" python3 "$ACTIVATE" "$1" "$BIN" serve >"$2" 2>"$2.err" &
  else
    env -u INVOCATION_ID CVWRITER_DATABASE_URL="$DB_URL" python3 "$ACTIVATE" "$1" "$BIN" serve >"$2" 2>"$2.err" &
  fi
  APP_PIDS+=("$!")
  for _ in $(seq 50); do [ -S "$1" ] && return 0; sleep 0.1; done
  fail "the app's socket $1 didn't appear"
}

# ================================================================ CHECK 1
echo "CHECK 1: the app (AC-1 to AC-8)"
SOCK="$WORK/app.sock"
start_app "$SOCK" "$WORK/app1.log" inv-s001-check
APP=${APP_PIDS[-1]}

# AC-1
read -r code secs < <(health "$SOCK")
[ "$code" = 200 ] || fail "AC-1: GET /api/health gave $code, not 200"
[ "$(cat "$WORK/body")" = '{"status":"ok"}' ] || fail "AC-1: body was $(cat "$WORK/body")"
ok "AC-1 health 200 with exactly {\"status\":\"ok\"}"

# AC-3: every other request
for req in "GET /" "GET /api/me" "POST /api/health"; do
  read -r code secs < <(health "$SOCK" "${req% *}" "${req#* }")
  [ "$code" = 404 ] || fail "AC-3: $req gave $code, not 404"
  problem_only 404 || fail "AC-3: $req isn't application/problem+json with only type, title, status"
done
ok "AC-3 GET /, GET /api/me, POST /api/health give 404 problem+json"

# AC-7: no TCP or UDP port
if ss -Htulnp 2>/dev/null | grep -q "pid=$APP,"; then fail "AC-7: the app opened a TCP or UDP port"; fi
ok "AC-7 no TCP or UDP port"

# AC-2: the database answers after about 1.7 s (just under the 2 s limit) -> 200
pg_pause; (sleep 1.7; pg_resume) & RESUMER=$!
read -r code secs < <(health "$SOCK")
wait "$RESUMER" || true
[ "$code" = 200 ] || fail "AC-2: a database answering after about 1.7 s gave $code, not 200"
ok "AC-2 database answering after about 1.7 s: 200"

# AC-2: the database answers after about 2.5 s (past the limit) -> 503 within 3 s
pg_pause; (sleep 2.5; pg_resume) & RESUMER=$!
read -r code secs < <(health "$SOCK")
wait "$RESUMER" || true
[ "$code" = 503 ] || fail "AC-2: a database answering after about 2.5 s gave $code, not 503"
within "$secs" 3.0 || fail "AC-2: a database answering after about 2.5 s took ${secs}s, over 3"
problem_only 503 || fail "AC-2: 503 isn't application/problem+json with only type, title, status"
ok "AC-2 database answering after about 2.5 s: 503 in ${secs}s"

# AC-2: the database hangs -> 503 within 3 s
pg_pause
read -r code secs < <(health "$SOCK")
pg_resume
[ "$code" = 503 ] || fail "AC-2: a hung database gave $code, not 503"
within "$secs" 3.0 || fail "AC-2: a hung database took ${secs}s, over 3"
problem_only 503 || fail "AC-2: 503 isn't application/problem+json with only type, title, status"
ok "AC-2 hung database: 503 in ${secs}s"

# AC-2: the database is stopped -> 503 within 3 s
pg_stop
read -r code secs < <(health "$SOCK")
[ "$code" = 503 ] || fail "AC-2: a stopped database gave $code, not 503"
within "$secs" 3.0 || fail "AC-2: a stopped database took ${secs}s, over 3"
problem_only 503 || fail "AC-2: 503 isn't application/problem+json with only type, title, status"
pg_start
ok "AC-2 stopped database: 503 in ${secs}s"

# AC-8: log lines, with INVOCATION_ID set (this run) and unset (a second run)
check_log() { # <log> <invocation id or empty>
  python3 - "$1" "$2" <<'PY' || return 1
import json, sys
lines = [l for l in open(sys.argv[1]).read().splitlines() if l.strip()]
assert lines, "no log lines"
for l in lines:
    o = json.loads(l)
    for k in ("time", "level", "msg"):
        assert k in o, (k, l)
    assert o.get("service") == "cvwriter", l
    assert o.get("version") == "s001-a", l
    if sys.argv[2]:
        assert o.get("invocation_id") == sys.argv[2], l
    else:
        assert "invocation_id" not in o, l
PY
}
check_log "$WORK/app1.log" inv-s001-check || fail "AC-8: a log line breaks the rule with INVOCATION_ID set (see above)"
SOCK2="$WORK/app2.sock"
start_app "$SOCK2" "$WORK/app2.log"
read -r code secs < <(health "$SOCK2")
check_log "$WORK/app2.log" "" || fail "AC-8: a log line breaks the rule with INVOCATION_ID unset (see above)"
ok "AC-8 JSON log lines, with and without invocation_id"

# AC-4 to AC-6: started wrongly
cli_error() { # <AC> <expected exit> <text the first line must hold> -- <command...>
  local ac="$1" want="$2" text="$3"; shift 4
  local rc=0
  "$@" >"$WORK/cli.out" 2>"$WORK/cli.err" || rc=$?
  [ "$rc" = "$want" ] || fail "$ac: '$*' exited $rc, not $want"
  [ ! -s "$WORK/cli.out" ] || fail "$ac: '$*' wrote to standard output"
  local first; first="$(head -n1 "$WORK/cli.err")"
  case "$first" in "cvwriter: "*) ;; *) fail "$ac: '$*' error line doesn't start with 'cvwriter: '";; esac
  [ "${#first}" -lt 80 ] || fail "$ac: '$*' error line is ${#first} characters, not under 80"
  grep -qi -- "$text" <<<"$first" || fail "$ac: '$*' error line doesn't name $text"
}
cli_error AC-4 2 "" -- "$BIN" fly
if grep -q fly "$WORK/cli.err"; then fail "AC-4: the error echoes the command back"; fi
[ "$(grep -c . "$WORK/cli.err")" -le 2 ] || fail "AC-4: more than an error line and a usage line"
ok "AC-4 unknown command: exit 2"
rm -f "$WORK/cli.sock"
cli_error AC-5 1 "CVWRITER_DATABASE_URL" -- env -u CVWRITER_DATABASE_URL python3 "$ACTIVATE" "$WORK/cli.sock" "$BIN" serve
[ "$(grep -c . "$WORK/cli.err")" = 1 ] || fail "AC-5: more than one line on standard error"
ok "AC-5 missing CVWRITER_DATABASE_URL: exit 1"
cli_error AC-6 1 "socket" -- env -u LISTEN_FDS -u LISTEN_PID CVWRITER_DATABASE_URL="$DB_URL" "$BIN" serve
[ "$(grep -c . "$WORK/cli.err")" = 1 ] || fail "AC-6: more than one line on standard error"
ok "AC-6 missing socket: exit 1"

for p in "${APP_PIDS[@]}"; do kill "$p" 2>/dev/null || true; done
APP_PIDS=()
echo "CHECK 1 passed"

# ================================================================ CHECK 2
echo "CHECK 2: the deploy script (AC-9 to AC-13)"
[ -f "$ROOT_DIR/scripts/deploy.sh" ] || fail "scripts/deploy.sh doesn't exist"

# The stand-in for systemctl. It accepts only the calls the plan names and
# starts the app the way cvwriter.socket would: on CVWRITER_SOCKET, from
# CVWRITER_ROOT/current.
mkdir -p "$WORK/fake"
cat >"$WORK/fake/systemctl" <<'FAKE'
#!/usr/bin/env bash
set -u
D="$(dirname "$0")"
echo "$*" >>"$D/calls"
stop_app() { [ -f "$D/pid" ] && { kill "$(cat "$D/pid")" 2>/dev/null; rm -f "$D/pid"; }; rm -f "$CVWRITER_SOCKET"; }
case "$*" in
  "daemon-reload"|"enable --now cvwriter.socket") ;;
  "stop cvwriter.socket cvwriter.service") stop_app ;;
  "restart cvwriter.service")
    stop_app
    [ -x "$CVWRITER_ROOT/current/cvwriter" ] || exit 1
    CVWRITER_DATABASE_URL="$DB_URL" python3 "$ACTIVATE" "$CVWRITER_SOCKET" \
      "$CVWRITER_ROOT/current/cvwriter" serve >>"$D/app.log" 2>&1 </dev/null &
    echo $! >"$D/pid"
    for _ in $(seq 50); do [ -S "$CVWRITER_SOCKET" ] && exit 0; sleep 0.1; done
    exit 1 ;;
  *) echo "systemctl stand-in: call not in the plan: $*" >&2; exit 1 ;;
esac
FAKE
chmod +x "$WORK/fake/systemctl"

new_root() { # a fresh scratch server; stops any app the last one left running
  if [ -n "${CVWRITER_SOCKET:-}" ]; then "$WORK/fake/systemctl" stop cvwriter.socket cvwriter.service || true; fi
  rm -rf "$WORK/srv" "$WORK/fake/calls" "$WORK/fake/pid"
  mkdir -p "$WORK/srv/root" "$WORK/srv/units" "$WORK/srv/run"
  export CVWRITER_ROOT="$WORK/srv/root" CVWRITER_UNIT_DIR="$WORK/srv/units" \
         CVWRITER_SOCKET="$WORK/srv/run/cvwriter.sock" SYSTEMCTL="$WORK/fake/systemctl"
}
deploy() { # <archive> -> exit code in $rc, output in $WORK/deploy.out
  rc=0; bash "$ROOT_DIR/scripts/deploy.sh" "$1" >"$WORK/deploy.out" 2>&1 || rc=$?
}
running() { readlink "$CVWRITER_ROOT/current" 2>/dev/null | sed 's#.*/##'; }
units_of() { # <version>: installed units equal that release's
  cmp -s "$CVWRITER_UNIT_DIR/cvwriter.service" "$CVWRITER_ROOT/releases/$1/systemd/cvwriter.service" &&
  cmp -s "$CVWRITER_UNIT_DIR/cvwriter.socket" "$CVWRITER_ROOT/releases/$1/systemd/cvwriter.socket"
}
one_line_naming() { # <text>...: deploy output is one line holding each text
  [ "$(grep -c . "$WORK/deploy.out")" = 1 ] || return 1
  local t; for t in "$@"; do grep -qiF -- "$t" "$WORK/deploy.out" || return 1; done
}
snapshot() { (cd "$WORK/srv" && find root units -print0 | sort -z | xargs -0 ls -ld --time-style=+%s.%N; \
              readlink root/current || true; cat units/* 2>/dev/null | sha256sum) >"$1"; }

# Fixture releases made from s001_b.2: its binary behind a wrapper
fixture() { # <version> <wrapper body>
  local d="$WORK/fx/$1"; rm -rf "$d"; mkdir -p "$d"
  tar -C "$d" -xzf "$WORK/cvwriter-s001_b.2.tar.gz"
  mv "$d/cvwriter" "$d/cvwriter.real"
  printf '#!/usr/bin/env bash\n%s\n' "$2" >"$d/cvwriter"; chmod +x "$d/cvwriter"
  printf '%s' "$1" >"$d/version"
  echo "# fixture $1" >>"$d/systemd/cvwriter.service"
  tar -C "$d" -czf "$WORK/cvwriter-$1.tar.gz" .
}
fixture s001-slow12 'sleep 12; exec "$(dirname "$0")/cvwriter.real" "$@"'
fixture s001-slow9 'sleep 9; exec "$(dirname "$0")/cvwriter.real" "$@"'
bad_version() { # <archive name> <version text>: s001_b.2 with another version file
  local d="$WORK/fx/bad-$1"; rm -rf "$d"; mkdir -p "$d"
  tar -C "$d" -xzf "$WORK/cvwriter-s001_b.2.tar.gz"; printf '%s' "$2" >"$d/version"
  tar -C "$d" -czf "$WORK/cvwriter-bad-$1.tar.gz" .
}
bad_version empty ''
bad_version dot '.'
bad_version dotdot '..'
bad_version updir '../x'
bad_version dash '-a'
bad_version space 'a b'
bad_version semicolon 'a;b'
bad_version accent 's001-é'
bad_version long "${V64}v"
# A release whose files are writable by group and others, owned by another
# user in the archive
d="$WORK/fx/s001-perm"; rm -rf "$d"; mkdir -p "$d"
tar -C "$d" -xzf "$WORK/cvwriter-s001_b.2.tar.gz"; printf 's001-perm' >"$d/version"
chmod -R a+w "$d"
tar -C "$d" --owner=4242 --group=4242 -czf "$WORK/cvwriter-s001-perm.tar.gz" .

new_root

# AC-9: first release, then later ones; earlier folders stay
deploy "$WORK/cvwriter-s001-a.tar.gz"
[ "$rc" = 0 ] || { cat "$WORK/deploy.out"; fail "AC-9: deploying s001-a exited $rc"; }
[ "$(running)" = s001-a ] || fail "AC-9: current doesn't point to s001-a"
units_of s001-a || fail "AC-9: the installed unit files aren't s001-a's"
read -r code secs < <(health "$CVWRITER_SOCKET")
[ "$code" = 200 ] || fail "AC-9: s001-a's health check gave $code"
one_line_naming s001-a || fail "AC-9: output isn't one line naming s001-a"
deploy "$WORK/cvwriter-s001_b.2.tar.gz"
[ "$rc" = 0 ] && [ "$(running)" = s001_b.2 ] || fail "AC-9/AC-12: s001_b.2 wasn't deployed (exit $rc)"
deploy "$WORK/cvwriter-$V64.tar.gz"
[ "$rc" = 0 ] && [ "$(running)" = "$V64" ] || fail "AC-9/AC-12: the 64-character version wasn't deployed (exit $rc)"
[ -d "$CVWRITER_ROOT/releases/s001-a" ] && [ -d "$CVWRITER_ROOT/releases/s001_b.2" ] || fail "AC-9: an earlier release's folder was removed"
ok "AC-9 s001-a, s001_b.2 and a 64-character version deployed in turn; earlier folders kept"

# AC-9: an earlier version whose folder exists, not running, is unpacked again
chmod u+w "$CVWRITER_ROOT/releases/s001-a" && touch "$CVWRITER_ROOT/releases/s001-a/stale-marker" \
  || fail "setup: couldn't mark s001-a's folder"
deploy "$WORK/cvwriter-s001-a.tar.gz"
[ "$rc" = 0 ] && [ "$(running)" = s001-a ] || fail "AC-9: deploying the earlier s001-a again failed (exit $rc)"
[ ! -e "$CVWRITER_ROOT/releases/s001-a/stale-marker" ] || fail "AC-9: s001-a's folder wasn't unpacked afresh"
units_of s001-a || fail "AC-9: the installed unit files aren't s001-a's after deploying it again"
one_line_naming s001-a || fail "AC-9: output isn't one line naming s001-a"
ok "AC-9 earlier version deployed again, its folder unpacked afresh"

# AC-13: modes and owner come from the deploy, not the archive. The deploy
# runs under umask 000, so a plain unpack would keep the archive's modes
umask_was="$(umask)"; umask 000
deploy "$WORK/cvwriter-s001-perm.tar.gz"
umask "$umask_was"
[ "$rc" = 0 ] && [ "$(running)" = s001-perm ] || fail "AC-13: s001-perm wasn't deployed (exit $rc)"
[ -z "$(find "$CVWRITER_ROOT/releases/s001-perm" -perm /022 -print -quit)" ] \
  || fail "AC-13: a file under releases/s001-perm is writable by group or others"
[ -z "$(find "$CVWRITER_ROOT/releases/s001-perm" ! -user "$(id -u)" -print -quit)" ] \
  || fail "AC-13: a file under releases/s001-perm keeps the archive's owner"
ok "AC-13 group- and world-writable files unpacked without those rights, owned by the deploying user"

# AC-9 at the limit: healthy after about 9 s -> kept
deploy "$WORK/cvwriter-s001-slow9.tar.gz"
[ "$rc" = 0 ] && [ "$(running)" = s001-slow9 ] || { cat "$WORK/deploy.out"; fail "AC-9: a release healthy after 9 s wasn't kept (exit $rc)"; }
ok "AC-9 release healthy after about 9 s kept"

# AC-8 for releases the deploy started: each line names the release's version
python3 - "$WORK/fake/app.log" "$V64" <<'PY' || fail "AC-8: a deployed release's log lines don't carry its own version (see above)"
import json, sys
seen = set()
for l in open(sys.argv[1]).read().splitlines():
    if l.strip().startswith("{"):
        o = json.loads(l)
        seen.add(o.get("version"))
assert {"s001_b.2", sys.argv[2]} <= seen, seen
assert seen <= {"s001-a", "s001_b.2", sys.argv[2]}, seen
PY
ok "AC-8 deployed releases log their own versions"

# AC-10: just past the limit: healthy only after about 12 s -> switched back
deploy "$WORK/cvwriter-s001-slow12.tar.gz"
[ "$rc" = 1 ] || fail "AC-10: a release healthy only after 12 s exited $rc, not 1"
[ "$(running)" = s001-slow9 ] || fail "AC-10: current doesn't point back to s001-slow9"
units_of s001-slow9 || fail "AC-10: s001-slow9's unit files weren't installed again"
read -r code secs < <(health "$CVWRITER_SOCKET")
[ "$code" = 200 ] || fail "AC-10: after switching back, health gave $code"
one_line_naming s001-slow12 health || fail "AC-10: output isn't one line naming s001-slow12 and the health check"
ok "AC-10 release healthy only after about 12 s switched back"

# AC-12: refused versions change nothing; the running version is refused too
for a in "$WORK/cvwriter-s001-slow9.tar.gz" "$WORK"/cvwriter-bad-*.tar.gz; do
  snapshot "$WORK/before"
  deploy "$a"
  snapshot "$WORK/after"
  [ "$rc" = 1 ] || fail "AC-12: $(basename "$a") exited $rc, not 1"
  [ "$(grep -c . "$WORK/deploy.out")" = 1 ] || fail "AC-12: $(basename "$a") output isn't one line"
  cmp -s "$WORK/before" "$WORK/after" || fail "AC-12: $(basename "$a") changed releases/, current or the unit files"
done
[ ! -e "$WORK/srv/x" ] && [ ! -e "$WORK/srv/root/x" ] || fail "AC-12: ../x wrote outside releases/"
ok "AC-12 running version, empty, ., .., ../x, -a, 'a b', 'a;b', s001-é and 65 characters refused, nothing changed"

# AC-11 and AC-9 for a first release: just under the limit -> kept
new_root
deploy "$WORK/cvwriter-s001-slow9.tar.gz"
[ "$rc" = 0 ] && [ "$(running)" = s001-slow9 ] || fail "AC-9: a first release healthy after 9 s wasn't kept (exit $rc)"
ok "AC-9 first release healthy after about 9 s kept"

# AC-11: a first release just past the limit -> app and socket stopped, no current
new_root
deploy "$WORK/cvwriter-s001-slow12.tar.gz"
[ "$rc" = 1 ] || fail "AC-11: a first release healthy only after 12 s exited $rc, not 1"
[ ! -e "$CVWRITER_ROOT/current" ] && [ ! -L "$CVWRITER_ROOT/current" ] || fail "AC-11: current still exists"
grep -qx "stop cvwriter.socket cvwriter.service" "$WORK/fake/calls" || fail "AC-11: the app and its socket weren't stopped"
[ ! -f "$WORK/fake/pid" ] || fail "AC-11: the app is still running"
one_line_naming s001-slow12 health || fail "AC-11: output isn't one line naming s001-slow12 and the health check"
ok "AC-11 first release healthy only after about 12 s: app and socket stopped, no current"
new_root
echo "CHECK 2 passed"

# ================================================================ CHECK 3
echo "CHECK 3: the unit files (AC-14)"
python3 - "$WORK/a/systemd/cvwriter.socket" "$WORK/a/systemd/cvwriter.service" <<'PY' || fail "AC-14 (see above)"
import shlex, sys
def read(p):
    kv = {}
    for raw in open(p):
        l = raw.strip()
        if not l or l[0] in "#;[":
            continue
        k, _, v = l.partition("=")
        kv.setdefault(k.strip(), []).append(v.strip())
    return kv
sock, svc = read(sys.argv[1]), read(sys.argv[2])
listens = {k: v for k, v in sock.items() if k.startswith("Listen")}
assert listens == {"ListenStream": ["/run/cvwriter.sock"]}, ("socket listens", listens)
for k, v in (("SocketUser", "cvwriter"), ("SocketGroup", "www-data"), ("SocketMode", "0660")):
    assert sock.get(k) == [v], (k, sock.get(k))
for k, v in (("ExecStart", "/sites/cvwriter/current/cvwriter serve"), ("User", "cvwriter"),
             ("Requires", "cvwriter.socket"), ("Restart", "on-failure"),
             ("NoNewPrivileges", "yes"), ("ProtectSystem", "strict"), ("ProtectHome", "yes"),
             ("PrivateTmp", "yes"), ("IPAddressDeny", "169.254.169.254")):
    assert svc.get(k) == [v], (k, svc.get(k))
assert svc.get("MemoryMax", [""])[-1], "MemoryMax is not set"
env = {}
for line in svc.get("Environment", []):
    for word in shlex.split(line):
        name, _, value = word.partition("=")
        env[name] = value
assert env.get("GOMEMLIMIT"), "GOMEMLIMIT is not set"
assert env.get("CVWRITER_DATABASE_URL") == "postgres:///cvwriter?host=/var/run/postgresql&user=cvwriter", \
    ("CVWRITER_DATABASE_URL", env.get("CVWRITER_DATABASE_URL"))
assert "EnvironmentFile" not in svc, "the service reads an environment file"
whole = open(sys.argv[2]).read().lower()
assert "password" not in whole, "the service unit mentions a password"
print("units ok")
PY
ok "AC-14 socket and service units"
echo "CHECK 3 passed"
echo "PASS: walking-skeleton slice 1"
