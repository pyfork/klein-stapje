# ADR-003: One Go binary serves a JSON API to a React single-page app; the libraries and tools it is built with

<!-- prd-interviewer-Opus5.5-agent, 2026-10-19 -->

Status:   Proposed
Door:     one-way
Deciders: the owner

## Context
The brief chose Go with chi for the back end and React with TypeScript for the
front end, hosted on the shared server. The stack files leave these to an ADR:
- Go: module names, database access, the migration tool, the boundary check, and where traces and metrics are sent.
- React: the routing and data-fetching libraries, the Node and package-manager versions, and where the built files are served from.

PDF rendering also needs a choice: each CV is an A4 PDF in the Manrope font, made from HTML, with a real text layer (PRD).

The server is small and shared: 2 cores, 1.9 GB of memory with ~1.35 GB free, and other sites on it. It has an old Go (1.18) and a system Google Chrome, both owned by the box, not by this project. Load is one user, one request at a time (PRD).

What breaks if this is wrong: SQL bugs that only show at run time; migrations that the app role can't run (ADR-002 splits the roles); a box update to Chrome or Go that breaks CV rendering; no trace from the screen to the database, which the walking skeleton requires.

## Options considered
**A. Database access**
1. **pgx v5 with sqlc.** Queries are written as SQL files, and sqlc generates typed Go from them.
   + SQL is reviewed as SQL; a wrong column fails at generate time, not at run time.
   − A code-generation step in the build, and a check in CI that generated code is current.
2. **pgx v5 alone, with hand-written scanning.**
   + No generator.
   − Every query's columns and types are checked only by tests.

**B. Migrations**
1. **goose, with SQL files embedded in the binary, run as `cvwriter_owner` by a separate `migrate` command at deploy, never by the app at start-up.**
   + Plain SQL; works with ADR-002's two roles; up and down in one file.
   − Deploy has a step that runs before the app restarts.
2. **atlas, which works out migrations from a declared schema.**
   + Changes are planned from the target schema.
   − A heavier tool, and generated columns and triggers are where declarative tools are weakest.

**C. PDF rendering**
1. **chromedp drives this project's own pinned copy of `chrome-headless-shell`, kept in the project's folder on the server. One render at a time.**
   + Faithful HTML and CSS with Manrope, and a real text layer; a box-wide Chrome update can't break it.
   − ~150 MB of browser files to keep and update on purpose; ~200–300 MB of memory while a render runs.
2. **chromedp drives the box's system Google Chrome.**
   + Nothing extra to install.
   − Another tenant or an automatic update can change or remove it.
3. **A pure-Go PDF library.**
   + No browser at all.
   − The CV designs are HTML and CSS; redrawing them in a PDF library's own layout code is slow work and drifts from the designs.

**D. Where traces and metrics go**
1. **A hosted OpenTelemetry backend on a free tier (Grafana Cloud), sent over OTLP.**
   + Nothing runs on the shared box; one trace from screen to database is visible from day one.
   − An outside account to create, and a token in the server's environment. Spans carry route patterns, never ad text or personal data.
2. **Jaeger running on the server.**
   + Data stays on the box.
   − Another always-on service, ~100 MB or more, on a box with ~1.35 GB free and other tenants.

**E. Front-end libraries**
1. **React Router (library mode) for pages, and TanStack Query for loading and caching API data.**
   + Widely used and small; Query handles loading, errors and refetching, which the Search and CV-version screens need.
   − Two dependencies to keep up to date.
2. **No libraries: a hand-written router and `fetch` calls in components.**
   + No dependencies.
   − Loading, error and retry states written by hand on every screen.

## Decision
- **Shape:**
  - One Go binary serves the JSON API under `/cvwriter/api/`, plus the single-page app's `index.html`. It sits behind nginx.
  - Where the built JS and CSS are served from is decided in ADR-004.
  - Built in CI for linux/amd64; the box's own Go is never used.
- **Versions:**
  - Back end: Go 1.27, chi v5.
  - Front end: Node 24 LTS, pnpm 12, React 19, TypeScript in strict mode, Vite 8.
  - Exact versions live in `go.mod` and the pnpm lockfile.
- **Go modules:**
  - `ads`, `cvs`, `usage`, `account` (login, password and the API key), `claude` (the only caller of the Claude API, ADR-001) and `pdf`.
  - Each is used by the others only through its `api` package, enforced with depguard in golangci-lint.
- **A1: database access** is pgx v5 with sqlc. CI fails if the generated code is out of date.
- **B1: migrations:**
  - goose SQL files, embedded, run by `cvwriter migrate` as `cvwriter_owner` at deploy, before the restart.
  - The app connects as `cvwriter` only.
- **C1: PDF rendering:**
  - chromedp with a pinned `chrome-headless-shell` in the project's folder.
  - At most one render at a time; a second request waits.
  - Each render has its own deadline inside the 90 s budget for creating a CV.
  - The Manrope font is bundled with the app, never loaded from the internet at render time.
- **D1: telemetry:**
  - OTLP to a Grafana Cloud free-tier stack.
  - The endpoint and token come from the environment.
  - Span attributes never hold ad text, CV text, emails or keys; the log test covers this.
- **E1: front end:** React Router and TanStack Query, with no UI component library (brief).

## Consequences
+ One trace runs from the screen to the database, as the walking skeleton requires.
+ SQL mistakes fail at build time; migrations run with the owner role only.
+ CV rendering doesn't depend on anything the box's other tenants control.
− The pinned headless Chrome has to be updated on purpose, roughly monthly or on a security advisory.
− Deploy runs in order: migrate, then copy the binary, then restart.
− An outside telemetry account and its token have to be created and kept.
− Memory is tight. With one render at a time, peak use is ~350 MB on a box with ~1.35 GB free.

## Revisit when
- Memory available on the box drops below 500 MB at peak: move rendering out, or move hosts.
- More than one user creates CVs at the same time often enough that renders queue for over 10 s.
- The telemetry free tier's limits are reached, or its terms change.
- A security advisory for headless Chrome can't be applied within 7 days.
