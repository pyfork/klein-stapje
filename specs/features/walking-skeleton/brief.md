# Brief: walking skeleton (feature 0)

<!-- senior-lead-Opus5.5-agent, 2026-10-20. From docs/claude-pkg/TEMPLATE-BRIEF.md.
     Status: draft, awaiting the owner's approval (merging this PR).
     senior-lead-Opus5.5-agent, 2026-10-20, slice 1's plan: six slices; how the
     server checks a release; what every log line carries; when Go tests join CI. -->

## Who it's for
The one cvwriter user, signed in through Cloudflare Access, and every later
feature, which builds on what this one puts in place.

## The problem
Nothing is deployed yet. Every later feature needs a deploy path, sign-in in
front of the app, a database, telemetry, and the two build-failing tests
(route test, log test). None of them exist, and none has been tried on the
shared server behind Cloudflare.

## End goal
- The user signs in through Cloudflare Access (email code, then Touch ID),
  opens Settings, fills in the contact block (name, phone, email, address,
  links), saves it, reloads the page and sees it kept.
- Every merge to `main` deploys by itself, and the server pulls it: CI builds
  and signs the release; a timer on the server fetches it, checks it (T-42)
  and runs `scripts/deploy.sh`, in the architecture's order (back up, migrate,
  switch, restart, smoke test), switching back when the smoke test fails. CI
  holds no credential for the server.
- The production checks hold (start-here step 2b; the go-chi and react-vite
  stack files):
  - `GET /api/health` returns 200 when the process is up and the database
    answers, and returns no data.
  - Every log line is JSON and carries `service`, `version` and, when
    systemd runs the process, `invocation_id` (systemd's `INVOCATION_ID`).
    A line written inside a request or a job run (`migrate`, `backup`) also
    carries `trace_id` and `span_id` from a real span: each job run starts a
    trace of its own and flushes its spans, with a time limit, before it exits.
    Lines from before tracing starts carry no trace fields.
  - One save of the contact block shows in Grafana Cloud as one trace, from
    the browser's fetch through the chi route to the SQL statement.
  - Rate, errors and duration are recorded per route pattern.
  - The route test lists every route and fails if one has no non-owner test;
    `/api/health` is listed as public, with its reason.
  - The log test fails if a log line or span holds an email, a token, a
    signed URL, or any planted contact-block value (name, phone, address,
    links). The contact block's email and phone pass through the tested
    paths, so the test has something real to catch. It catches only what the
    tests run: the planted contact-block values, on every tested path. A path
    no test reaches isn't covered.
  - The app refuses, with 401, any request without a valid Access token whose
    email equals the account's (T-40), except `/api/health`.
  - The CI time is written down: push to verdict, and the `locked-checks` job
    on its own.
- The memory used by the running app is measured, and `MemoryMax=` and
  `GOMEMLIMIT` are set from it, as a baseline (ADR-006 has it measured again
  when PDF rendering arrives).
- Both Spaces buckets exist, with versioning on and one key per bucket, and
  the deploy's smoke test fetches the canary object through a signed link.

## Out of scope
- Job ads, their analysis, Claude calls and the API key: safe because the
  skeleton stores only the contact block, which holds no ad data and is never
  sent to Claude (A-7); revisit at feature 1's first slice, which is go-live.
- In-app password sign-in (`sessions`, `login_attempts`, `security_events`):
  safe because Access, with an email code and a passkey, already guards the
  whole subdomain for the one user, and the skeleton holds only the contact
  block; revisit before go-live, since A-5 counts the app's password as part
  of sign-in.
- Shipping SSH sign-ins and sudo events off the server (T-38), and the
  server-wide sudo rule in T-34: safe because until go-live the server holds
  only the contact block, the same details every CV carries, so a neighbour's
  compromise, noticed or not, reaches nothing beyond what an employer already
  sees; and cvwriter's own units are sandboxed under their own user from the
  first deploy; revisit before go-live (threat model, "Go-live").
- The nightly backup timer, the monthly restore test and the nightly
  fingerprint check: safe because the deploy already backs up the database
  before every migration, and there are no files to fingerprint yet; a dump
  that has never been restored is safe to rely on for now because it holds
  only the contact block, which the owner can type in again in a minute;
  revisit before go-live.
- The progress stream's check against Cloudflare's 100-second limit: safe
  because the skeleton has no progress stream, and the fix is known (a
  heartbeat well under nginx's and Cloudflare's idle limits, and buffering
  off); revisit as acceptance criteria in the Generate slice.
- The Typst fidelity spike: safe because the design 1 mock doesn't exist yet;
  revisit in the CV-render slice (ADR-006).
- A locked second copy of files and backups (T-37): safe for the smallest
  working version, the owner's choice, with the risk stated in A-3; revisit on
  ADR-004's trigger (first CVs sent to employers, or a Spaces incident).
- Per-hostname Authenticated Origin Pulls (nginx turns away other Cloudflare
  customers' traffic by certificate): safe because the app already rejects
  any request without a valid Access token for the account's email (T-40),
  so another Cloudflare site reaching nginx gets only a 401; Cloudflare's
  default certificate is shared by every customer and wouldn't help; revisit
  if a review or test finds a way past the token check, or a second user
  joins.
- The full `GUARD_TEST_COMMAND` (the web tests added), the secret scanner,
  the dependency audit, code scanning, the API-contract drift check and the
  planted-bug check: safe because each follows the skeleton in its own PR
  (start-here step 2b), and the Go checks already run in CI: the owner sets
  `GUARD_TEST_COMMAND` to
  `test -z "$(gofmt -l .)" && go vet ./... && go test -race ./...` when
  slice 1's build PR opens, with the first Go code; revisit when the skeleton
  is merged.
- golangci-lint in `GUARD_TEST_COMMAND`: safe because `gofmt` and `go vet`
  run from the first Go code, and the project has no linter config yet to
  run it with; revisit when the skeleton is merged, in the same PR that adds
  the dependency audit and code scanning.

## Limits it must respect
- ADR-002: `users` with uuidv7 ids; every user-owned query filters on
  `user_id`.
- ADR-003: one Go binary run as `serve`, `migrate` and `backup`; pgx v5 with
  sqlc; goose migrations run as `cvwriter_owner` at deploy; OTLP to Grafana
  Cloud; `MemoryMax=` and `GOMEMLIMIT`.
- ADR-004: two private buckets, one key each, systemd credentials; signed
  links never logged or recorded in spans; the canary smoke test.
- ADR-005: its own subdomain, nginx accepting Cloudflare's ranges only.
- ADR-006: the Typst spike's new place.
- Threat model: T-34 (cvwriter's own units), T-36 (unix socket only), T-39 and
  T-40 (Access in front, token checked), T-41 (deploys only through
  `scripts/deploy.sh`), T-42 (the server pulls and checks its deploys).
- PRD budgets: 99% uptime with automatic restart; WCAG 2.2 AA for the Settings
  screen, checked in the browser tests.

## Anything to match
None. The Settings form is plain; the design 1 mock is for the PDF (ADR-006).

## Rough slice list
Riskiest first. What each slice holds is settled in its own plan.
1. Runs on the server
2. Deploys itself
3. Signed in
4. Telemetry
5. Contact block
6. Storage and numbers

Changed in slice 1's plan, from three slices. The first slice, "Signed in on
the real server", held sign-in (ACCESS), new units on the shared server and
the pull deploy (SHARED), and was estimated over the diff flag: each
always-risky change now has a slice of its own. The app runs on the server
before it deploys itself, because the deploy path needs a running app to
switch to and back from. Sign-in comes third, because it can only be tried
once the app runs on the server; until then the app answers nothing but
`/api/health`, on a local socket, and the subdomain has no DNS record
(architecture, one-time setup step 5). Telemetry (traces, metrics, the deploy
alert) is a shared standard, so it is its own slice, before the contact block,
whose save must show as one trace.

## Open questions
None.

## Shape

### Entities and invariants
| Entity | Invariants (what must always be true) |
|---|---|
| User (`users`) | One row, created by `cvwriter create-user` on the server. Its email equals the Access token's `email` claim, compared case-insensitively. The contact block (name, phone, email, address, links) belongs to this row only; it is never written to a log or a span, and never sent to Claude (A-7). Columns for later features arrive in later migrations. |

### API sketch
| Endpoint or command | Input | Output | Who may call |
|---|---|---|---|
| `GET /api/health` | — | 200 `{"status":"ok"}` when the process is up and the database answers; 503 otherwise | Anyone (Access bypass app; no data) |
| `GET /api/me` | — | `{"email": ...}` | The signed-in user |
| `GET /api/settings/contact` | — | The contact block; empty fields when unset | The signed-in user |
| `PUT /api/settings/contact` | The whole contact block, JSON | 200 with the saved block; 422 problem+json naming the bad field | The signed-in user; `Origin` checked |
| `POST /api/telemetry` | Browser spans | 204 | The signed-in user; size and rate limits (ADR-003) |
| `cvwriter serve` / `migrate` / `backup` | — | — | systemd units, each with its own credentials |
| `cvwriter create-user --email` | The account's email | The `users` row | Root on the server, once |

"The signed-in user" means a request with a valid Access token whose email
equals the account's. Anything else gets 401 with no body data.

### States
None.

### Expected load
| What | Number | Where the number came from | Budget it touches |
|---|---|---|---|
| Users | 1 | PRD, Load | — |
| Requests per second | < 1 | PRD, Load | Uptime 99% |
| Contact block saves | ≤ 10 a year | Estimate: one block, edited when contact details change | — |
| Deploys | ≤ 10 a day | Estimate: one per merge to `main` | None; CI time is a baseline to measure, not a budget |

### Trust boundaries crossed
- Browser → Cloudflare → nginx → app (TB-1): Access token checked by the app
  on every request but `/api/health`.
- App → Spaces (TB-3): the canary object only; signed links never logged.
- App → Grafana Cloud (TB-4): spans and metrics carry no personal data; the
  contact block stays out of them.
- Other sites on the server (TB-5): the app has its own user, no TCP port,
  and sandboxed units.
- CI → server (TB-6): an unprivileged user fetches the release; a root-owned
  unit checks its SHA-256, its signed build record (this repository's deploy
  workflow, `main`) and its run number (newer, never failed before) before
  deploying; CI holds no credential for the server. The signed build record is
  GitHub's own signed workflow token (Key choices). Checking it without a
  GitHub sign-in is slice 2's first test.

### Key choices
| The choice | The option not taken | Why |
|---|---|---|
| The contact block is the one feature | A status page (version and database time) | Same cost; it is kept, it writes and reads real data, and its email and phone give the log test something to catch |
| The user is identified by the Access token's email | A session cookie | Sessions arrive with password sign-in, before go-live |
| Password sign-in waits until before go-live | Build it now | Access already guards the one user with an email code and a passkey |
| The skeleton stays on Spaces alone | A locked second copy now | The owner's choice for the smallest working version; ADR-004's trigger brings it in |
| The Typst spike moves to the CV-render slice | Keep it in the skeleton | The design 1 mock doesn't exist yet (ADR-006) |
| The progress-stream check becomes acceptance criteria in the Generate slice | A spike now | The fix is known, and the skeleton has no stream to test |
| The server checks a release against GitHub's signed workflow token (an OIDC token whose audience carries the release's SHA-256), with Go's standard library | The Sigstore Go library; the cosign tool run as root; a signing key held in CI; the owner signing each release by hand | No new dependency and no secret anywhere, and deploys stay automatic. The token names the repository by its id, the workflow file, the branch and the run number, all signed by GitHub. It is checked after it expires, which is safe because it carries the release's SHA-256, so it can only ever vouch for that one build, and replay is stopped by the run number and the failed list. Its known weak points are answered in slice 2's plan (T-42) |
| Sign-in (Access, nginx's Cloudflare-only rule, the token check) arrives in slice 3, before any route but `/api/health` exists and before the subdomain's DNS record | All of it from the first deploy | Slices 1 and 2 serve only `/api/health`, which is public by design, on a local socket with no DNS record, so nothing is reachable that sign-in would guard; each always-risky change keeps a slice of its own |
| Every log line carries `service`, `version` and systemd's invocation id; lines inside a request or a job run also carry real trace ids | Trace ids on request lines only, and an app-made run id elsewhere | Job runs show in Grafana as traces like requests do, and the server's journal already indexes systemd's invocation id |
| The server pulls its deploys and checks the signed build (T-42) | CI pushes over SSH with a deploy-only key | The server is shared (A-3): a CI secret that reaches it would widen TB-5; with pull, CI holds none |

### Risky slices
| Slice | Class (DATA, ACCESS or SHARED) | The assumption it tests | What changes if it is wrong |
|---|---|---|---|
| 1. Runs on the server | SHARED | New sandboxed units run the app on the shared server without disturbing the other sites, and a release that fails its health check is switched back | The units, their limits or the deploy script change before the server deploys by itself |
| 2. Deploys itself | ACCESS | The server can check, with no GitHub sign-in and no CI secret, that a release came from this repository's deploy workflow on `main` and is newer than the one running | The deploy path (T-42) changes before anything personal is stored |
| 3. Signed in | ACCESS | Access plus the token check keep everyone else out | Sign-in (A-5, T-39, T-40) changes before anything personal is stored |
| 4. Telemetry | SHARED | Traces, metrics and the deploy alert reach Grafana Cloud with no personal data and no token in the root-run units | The telemetry set-up changes before personal data arrives |
| 5. Contact block | DATA | Personal data can be saved and traced without reaching a log or a span | The logging and tracing set-up changes before ads arrive |
| 6. Storage and numbers | SHARED | The deploy can prove storage works, and the app fits in the server's free memory | The storage set-up, or the hosting choice (A-3's memory trigger) |

### Shared standards still missing
- The log line (JSON, with `service`, `version` and `invocation_id`): built
  in slice 1; its trace fields arrive with tracing in slice 4.
- The sign-in check on every route: built in slice 3.
- Traces, metrics and alerts: built in slice 4.
- Showing a problem+json error next to the field it names, and a loading
  state on save: built in slice 5.
