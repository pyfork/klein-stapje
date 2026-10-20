#!/usr/bin/env bash
# senior-lead-Opus5.5-agent, 2026-10-20. Locked check for walking-skeleton
# slice 1 (specs/features/walking-skeleton/S-001.md, AC-1 to AC-11).
#
# Runs as an unprivileged user on a fresh Linux x86_64 machine: no root, no
# systemd manager. It brings its own Go and PostgreSQL, pinned by SHA-256,
# and starts the app on a socket passed as file descriptor 3 with
# LISTEN_FDS and LISTEN_PID set, the way systemd's socket unit hands it over. The deploy script runs against a scratch root with a stand-in
# for systemctl (see "The deploy script's test seams" in the plan); the real
# systemd run is recorded on the server in the build PR.
#
#   CHECK 1  the app: AC-1 to AC-6
#   CHECK 2  the deploy script: AC-7 to AC-10
#   CHECK 3  the unit files: AC-11
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

cleanup() {
  local p
  for p in "${APP_PIDS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null || true; done
  [ -f "$WORK/fake/pid" ] && kill "$(cat "$WORK/fake/pid")" 2>/dev/null || true
  [ -x "$WORK/pg/bin/pg_ctl" ] && [ -d "$WORK/pgdata" ] && \
    { [ -f "$WORK/pgdata/postmaster.pid" ] && kill -CONT $(pg_pids) 2>/dev/null || true; "$WORK/pg/bin/pg_ctl" -D "$WORK/pgdata" -m immediate stop >/dev/null 2>&1 || true; }
  rm -rf "$WORK" "$ROOT_DIR/dist"
}
trap cleanup EXIT

# ---------------------------------------------------------------- setup
[ "$(uname -s)-$(uname -m)" = "Linux-x86_64" ] || fail "needs Linux x86_64 (found $(uname -s)-$(uname -m))"
for t in curl python3 ss tar unzip xz sha256sum pgrep; do
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
pg_pids() { local pm; pm="$(head -n1 "$WORK/pgdata/postmaster.pid")"; echo "$pm $(pgrep -P "$pm" | tr '\n' ' ')"; }
pg_pause() { kill -STOP $(pg_pids); }
pg_resume() { kill -CONT $(pg_pids); }
pg_start
export DB_URL="host=$WORK/pgsock dbname=cvwriter user=cvwriter"

# Releases come from the project's own build script (AC-7)
[ -f "$ROOT_DIR/scripts/build-release.sh" ] || fail "scripts/build-release.sh doesn't exist"
build() { (cd "$ROOT_DIR" && bash scripts/build-release.sh "$1" >/dev/null) || fail "build-release.sh $1 failed"; \
          [ -f "$ROOT_DIR/dist/cvwriter-$1.tar.gz" ] || fail "build-release.sh $1 made no dist/cvwriter-$1.tar.gz"; \
          cp "$ROOT_DIR/dist/cvwriter-$1.tar.gz" "$WORK/"; }
build s001-a
build s001-b
mkdir -p "$WORK/a"
tar -C "$WORK/a" -xzf "$WORK/cvwriter-s001-a.tar.gz"
for f in cvwriter version systemd/cvwriter.socket systemd/cvwriter.service; do
  [ -e "$WORK/a/$f" ] || fail "the release archive holds no $f"
done
[ "$(cat "$WORK/a/version")" = "s001-a" ] || fail "the release's version file doesn't say s001-a"
BIN="$WORK/a/cvwriter"

# health <socket> -> "<status> <seconds>" and the body in $WORK/body
health() {
  curl -s --max-time 10 --unix-socket "$1" -o "$WORK/body" -w '%{http_code} %{time_total}' \
    -X "${2:-GET}" "http://localhost${3:-/api/health}" || echo "000 99"
}
problem_only() { # <file> <status>: problem+json with only type, title, status
  python3 - "$1" "$2" <<'PY' || return 1
import json, sys
b = json.load(open(sys.argv[1]))
assert isinstance(b, dict) and set(b) == {"type", "title", "status"}, b
assert b["status"] == int(sys.argv[2]), b
PY
}
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
echo "CHECK 1: the app (AC-1 to AC-6)"
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
  read -r code secs < <(health "$SOCK" ${req% *} ${req#* })
  [ "$code" = 404 ] || fail "AC-3: $req gave $code, not 404"
  problem_only "$WORK/body" 404 || fail "AC-3: $req body isn't problem+json with only type, title, status"
done
ok "AC-3 GET /, GET /api/me, POST /api/health give 404 problem+json"

# AC-5: no TCP or UDP port
if ss -Htulnp 2>/dev/null | grep -q "pid=$APP,"; then fail "AC-5: the app opened a TCP or UDP port"; fi
ok "AC-5 no TCP or UDP port"

# AC-2: just under the 2 s limit -> 200
pg_pause; (sleep 1; pg_resume) & RESUMER=$!
read -r code secs < <(health "$SOCK")
wait "$RESUMER" || true
[ "$code" = 200 ] || fail "AC-2: a database answering after about 1 s gave $code, not 200"
ok "AC-2 database answering in about 1 s: 200"

# AC-2: past the limit (database hangs) -> 503 within 3 s
pg_pause
read -r code secs < <(health "$SOCK")
pg_resume
[ "$code" = 503 ] || fail "AC-2: a hung database gave $code, not 503"
python3 -c "import sys; sys.exit(0 if float('$secs') <= 3.0 else 1)" || fail "AC-2: a hung database took ${secs}s, over 3"
problem_only "$WORK/body" 503 || fail "AC-2: 503 body isn't problem+json with only type, title, status"
ok "AC-2 hung database: 503 in ${secs}s"

# AC-2: database stopped -> 503 within 3 s
pg_stop
read -r code secs < <(health "$SOCK")
[ "$code" = 503 ] || fail "AC-2: a stopped database gave $code, not 503"
python3 -c "import sys; sys.exit(0 if float('$secs') <= 3.0 else 1)" || fail "AC-2: a stopped database took ${secs}s, over 3"
problem_only "$WORK/body" 503 || fail "AC-2: 503 body isn't problem+json with only type, title, status"
pg_start
ok "AC-2 stopped database: 503 in ${secs}s"

# AC-6: log lines, with INVOCATION_ID set (this run) and unset (a second run)
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
check_log "$WORK/app1.log" inv-s001-check || fail "AC-6: a log line breaks the rule with INVOCATION_ID set (see above)"
SOCK2="$WORK/app2.sock"
start_app "$SOCK2" "$WORK/app2.log"
read -r code secs < <(health "$SOCK2")
check_log "$WORK/app2.log" "" || fail "AC-6: a log line breaks the rule with INVOCATION_ID unset (see above)"
ok "AC-6 JSON log lines, with and without invocation_id"

# AC-4: started wrongly
cli_error() { # <expected exit> <text the line must hold> -- <command...>
  local want="$1" text="$2"; shift 3
  local rc=0
  "$@" >"$WORK/cli.out" 2>"$WORK/cli.err" || rc=$?
  [ "$rc" = "$want" ] || fail "AC-4: '$*' exited $rc, not $want"
  [ ! -s "$WORK/cli.out" ] || fail "AC-4: '$*' wrote to standard output"
  local first; first="$(head -n1 "$WORK/cli.err")"
  case "$first" in "cvwriter: "*) ;; *) fail "AC-4: '$*' error line doesn't start with 'cvwriter: '";; esac
  [ "${#first}" -lt 80 ] || fail "AC-4: '$*' error line is ${#first} characters, not under 80"
  grep -qi -- "$text" <<<"$first" || fail "AC-4: '$*' error line doesn't name $text"
}
cli_error 2 "command" -- "$BIN" fly
grep -q fly "$WORK/cli.err" && fail "AC-4: the error echoes the command back (the pattern says never)"
[ "$(grep -c . "$WORK/cli.err")" -le 2 ] || fail "AC-4: an unknown command wrote more than an error line and a usage line"
rm -f "$WORK/cli.sock"
cli_error 1 "CVWRITER_DATABASE_URL" -- env -u CVWRITER_DATABASE_URL python3 "$ACTIVATE" "$WORK/cli.sock" "$BIN" serve
[ "$(grep -c . "$WORK/cli.err")" = 1 ] || fail "AC-4: a missing CVWRITER_DATABASE_URL wrote more than one line"
cli_error 1 "socket" -- env -u LISTEN_FDS -u LISTEN_PID CVWRITER_DATABASE_URL="$DB_URL" "$BIN" serve
[ "$(grep -c . "$WORK/cli.err")" = 1 ] || fail "AC-4: a missing socket wrote more than one line"
ok "AC-4 unknown command exit 2; missing CVWRITER_DATABASE_URL exit 1; missing socket exit 1"

for p in "${APP_PIDS[@]}"; do kill "$p" 2>/dev/null || true; done
APP_PIDS=()
echo "CHECK 1 passed"

# ================================================================ CHECK 2
echo "CHECK 2: the deploy script (AC-7 to AC-10)"
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

new_root() { # a scratch server
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
snapshot() { (cd "$WORK/srv" && find root units -print0 | sort -z | xargs -0 ls -ld --time-style=+%s.%N; \
              readlink root/current || true; cat units/* 2>/dev/null | sha256sum) >"$1"; }

# Fixture releases made from s001-b: its binary behind a wrapper
fixture() { # <version> <wrapper body> : a release archive that runs the wrapper as cvwriter
  local d="$WORK/fx/$1"; rm -rf "$d"; mkdir -p "$d"
  tar -C "$d" -xzf "$WORK/cvwriter-s001-b.tar.gz"
  mv "$d/cvwriter" "$d/cvwriter.real"
  printf '#!/usr/bin/env bash\n%s\n' "$2" >"$d/cvwriter"; chmod +x "$d/cvwriter"
  printf '%s' "$1" >"$d/version"
  echo "# fixture $1" >>"$d/systemd/cvwriter.service"
  tar -C "$d" -czf "$WORK/cvwriter-$1.tar.gz" .
}
fixture s001-slow12 'sleep 12; exec "$(dirname "$0")/cvwriter.real" "$@"'
fixture s001-slow8 'sleep 8; exec "$(dirname "$0")/cvwriter.real" "$@"'
fixture s001-dead 'exit 1'

new_root

# AC-7: first release, then a second; earlier folders stay
deploy "$WORK/cvwriter-s001-a.tar.gz"
[ "$rc" = 0 ] || { cat "$WORK/deploy.out"; fail "AC-7: deploying s001-a exited $rc"; }
[ "$(running)" = s001-a ] || fail "AC-7: current doesn't point to s001-a"
units_of s001-a || fail "AC-7: the installed unit files aren't s001-a's"
read -r code secs < <(health "$CVWRITER_SOCKET")
[ "$code" = 200 ] || fail "AC-7: s001-a's health check gave $code"
[ "$(grep -c . "$WORK/deploy.out")" = 1 ] && grep -q s001-a "$WORK/deploy.out" || fail "AC-7: output isn't one line naming s001-a"
deploy "$WORK/cvwriter-s001-b.tar.gz"
[ "$rc" = 0 ] && [ "$(running)" = s001-b ] || fail "AC-7: deploying s001-b didn't switch to it (exit $rc)"
[ -d "$CVWRITER_ROOT/releases/s001-a" ] || fail "AC-7: s001-a's folder was removed"
ok "AC-7 s001-a then s001-b deployed; s001-a's folder kept"

# AC-7 at the limit: healthy after about 8 s -> kept
deploy "$WORK/cvwriter-s001-slow8.tar.gz"
[ "$rc" = 0 ] && [ "$(running)" = s001-slow8 ] || { cat "$WORK/deploy.out"; fail "AC-7: a release healthy after 8 s wasn't kept (exit $rc)"; }
ok "AC-7 release healthy after about 8 s kept"

# AC-8: just past the limit: healthy only after about 12 s -> switched back
deploy "$WORK/cvwriter-s001-slow12.tar.gz"
[ "$rc" = 1 ] || fail "AC-8: a release healthy only after 12 s exited $rc, not 1"
[ "$(running)" = s001-slow8 ] || fail "AC-8: current doesn't point back to s001-slow8"
units_of s001-slow8 || fail "AC-8: s001-slow8's unit files weren't installed again"
read -r code secs < <(health "$CVWRITER_SOCKET")
[ "$code" = 200 ] || fail "AC-8: after switching back, health gave $code"
[ "$(grep -c . "$WORK/deploy.out")" = 1 ] && grep -q s001-slow12 "$WORK/deploy.out" && grep -qi health "$WORK/deploy.out" \
  || fail "AC-8: output isn't one line naming s001-slow12 and the health check"
ok "AC-8 release healthy only after about 12 s switched back"

# AC-10: refused releases change nothing
bad_version() { # <archive name> <version text>: s001-b with another version file
  local d="$WORK/fx/$1"; rm -rf "$d"; mkdir -p "$d"
  tar -C "$d" -xzf "$WORK/cvwriter-s001-b.tar.gz"; printf '%s' "$2" >"$d/version"
  tar -C "$d" -czf "$WORK/cvwriter-$1.tar.gz" .
}
bad_version dotdot '../x'
bad_version empty ''
for a in s001-slow8 dotdot empty; do
  snapshot "$WORK/before"
  deploy "$WORK/cvwriter-$a.tar.gz"
  snapshot "$WORK/after"
  [ "$rc" = 1 ] || fail "AC-10: release $a exited $rc, not 1"
  [ "$(grep -c . "$WORK/deploy.out")" = 1 ] || fail "AC-10: release $a output isn't one line"
  cmp -s "$WORK/before" "$WORK/after" || fail "AC-10: release $a changed releases/, current or the unit files"
done
[ ! -e "$WORK/srv/x" ] && [ ! -e "$WORK/srv/root/x" ] || fail "AC-10: ../x wrote outside releases/"
ok "AC-10 running version, ../x and empty version refused, nothing changed"

# AC-9: the first release ever fails its health check
new_root
deploy "$WORK/cvwriter-s001-dead.tar.gz"
[ "$rc" = 1 ] || fail "AC-9: a first release that never answers exited $rc, not 1"
[ ! -e "$CVWRITER_ROOT/current" ] && [ ! -L "$CVWRITER_ROOT/current" ] || fail "AC-9: current still exists"
grep -qx "stop cvwriter.socket cvwriter.service" "$WORK/fake/calls" || fail "AC-9: the app and its socket weren't stopped"
[ "$(grep -c . "$WORK/deploy.out")" = 1 ] && grep -q s001-dead "$WORK/deploy.out" && grep -qi health "$WORK/deploy.out" \
  || fail "AC-9: output isn't one line naming s001-dead and the health check"
ok "AC-9 failing first release: app and socket stopped, no current"
"$WORK/fake/systemctl" stop cvwriter.socket cvwriter.service || true
echo "CHECK 2 passed"

# ================================================================ CHECK 3
echo "CHECK 3: the unit files (AC-11)"
python3 - "$WORK/a/systemd/cvwriter.socket" "$WORK/a/systemd/cvwriter.service" <<'PY' || fail "AC-11 (see above)"
import sys
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
env = " ".join(svc.get("Environment", []))
assert "GOMEMLIMIT=" in env, "GOMEMLIMIT is not set"
print("units ok")
PY
ok "AC-11 socket and service units"
echo "CHECK 3 passed"
echo "PASS: walking-skeleton slice 1"
