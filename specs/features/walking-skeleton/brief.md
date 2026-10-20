# Brief: walking skeleton (feature 0)

<!-- senior-lead-Opus5.5-agent, 2026-10-20. From docs/claude-pkg/TEMPLATE-BRIEF.md.
     Status: draft, awaiting the owner's approval (merging this PR). -->

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
  - Every log line is JSON and carries `trace_id` and `span_id`.
  - One save of the contact block shows in Grafana Cloud as one trace, from
    the browser's fetch through the chi route to the SQL statement.
  - Rate, errors and duration are recorded per route pattern.
  - The route test lists every route and fails if one has no non-owner test;
    `/api/health` is listed as public, with its reason.
  - The log test fails if a log line or span holds an email, a token or a
    signed URL. The contact block's email and phone pass through the tested
    paths, so the test has something real to catch.
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
  before every migration, and there are no files to fingerprint yet; revisit
  before go-live.
- The progress stream's check against Cloudflare's 100-second limit: safe
  because the skeleton has no progress stream, and the fix is known (a
  heartbeat well under nginx's and Cloudflare's idle limits, and buffering
  off); revisit as acceptance criteria in the Generate slice.
- The Typst fidelity spike: safe because the design 1 mock doesn't exist yet;
  revisit in the CV-render slice (ADR-006).
- A locked second copy of files and backups (T-37): safe for the smallest
  working version, the owner's choice, with the risk stated in A-3; revisit on
  ADR-004's trigger (first CVs sent to employers, or a Spaces incident).
- The real `GUARD_TEST_COMMAND`, the secret scanner, the dependency audit,
  code scanning, the API-contract drift check and the planted-bug check: safe
  because each follows the skeleton in its own PR (start-here step 2b); revisit
  when the skeleton is merged.

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
1. Signed in on the real server
2. Contact block
3. Storage and numbers

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
  deploying; CI holds no credential for the server. Checking the build record
  without a GitHub sign-in is slice 1's first test.

### Key choices
| The choice | The option not taken | Why |
|---|---|---|
| The contact block is the one feature | A status page (version and database time) | Same cost; it is kept, it writes and reads real data, and its email and phone give the log test something to catch |
| The user is identified by the Access token's email | A session cookie | Sessions arrive with password sign-in, before go-live |
| Password sign-in waits until before go-live | Build it now | Access already guards the one user with an email code and a passkey |
| The skeleton stays on Spaces alone | A locked second copy now | The owner's choice for the smallest working version; ADR-004's trigger brings it in |
| The Typst spike moves to the CV-render slice | Keep it in the skeleton | The design 1 mock doesn't exist yet (ADR-006) |
| The progress-stream check becomes acceptance criteria in the Generate slice | A spike now | The fix is known, and the skeleton has no stream to test |
| The server pulls its deploys and checks the signed build (T-42) | CI pushes over SSH with a deploy-only key | The server is shared (A-3): a CI secret that reaches it would widen TB-5; with pull, CI holds none |

### Risky slices
| Slice | Class (DATA, ACCESS or SHARED) | The assumption it tests | What changes if it is wrong |
|---|---|---|---|
| 1. Signed in on the real server | ACCESS, SHARED | Access plus the token check keep everyone else out, new units on the shared server don't disturb the other sites, and the server can deploy itself from a checked build | Sign-in (A-5, T-39, T-40), the server units or the deploy path (T-42) change before anything personal is stored |
| 2. Contact block | DATA | Personal data can be saved and traced without reaching a log or a span | The logging and tracing set-up changes before ads arrive |
| 3. Storage and numbers | SHARED | The deploy can prove storage works, and the app fits in the server's free memory | The storage set-up, or the hosting choice (A-3's memory trigger) |

### Shared standards still missing
- The sign-in check on every route: built in slice 1.
- Showing a problem+json error next to the field it names, and a loading
  state on save: built in slice 2.
