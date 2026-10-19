# ADR-003: One Go binary serves a JSON API to a React single-page app; the libraries and tools it is built with

<!-- prd-interviewer-Opus5.5-agent, 2026-10-19 -->

Status:   Accepted 2026-10-19
Door:     marked per choice in the Decision
Deciders: the owner

## Context
The brief chose Go with chi for the back end and React with TypeScript for the
front end, hosted on the shared server. The stack files leave these to an ADR:
- Go: module names, database access, the migration tool, the boundary check, and where traces and metrics are sent.
- React: the routing and data-fetching libraries, the Node and package-manager versions, and where the built files are served from.

PDF rendering also needs a choice. Each CV is a 2-page A4 PDF in the Manrope font with a real text layer (PRD). Its content is written by Claude from the ad's text, and the ad's text is untrusted: a pasted ad can carry instructions or markup aimed at whatever renders the CV.

The server is small and shared: 2 cores, 1.9 GB of memory with ~1.35 GB free, and other sites on it. It has an old Go (1.18) and a system Google Chrome, both owned by the box, not by this project. Load is one user, one request at a time (PRD).

What breaks if this is wrong:
- SQL bugs that only show at run time.
- Migrations that the app role can't run (ADR-002 splits the roles), or that break the binary still running.
- Untrusted ad text reaching a renderer that can make network requests or read files.
- A box update to Chrome or Go that breaks CV rendering.
- The app using memory the other sites need.
- No trace from the screen to the database, which the walking skeleton requires.

## Options considered
**A. Database access**
1. **pgx v5 with sqlc.** Queries are written as SQL files, and sqlc generates typed Go from them.
   + SQL is reviewed as SQL; a wrong column fails at generate time, not at run time.
   − A code-generation step in the build, and a check in CI that generated code is current.
   − Weak at queries whose filters change per request (Feature 2's search).
2. **pgx v5 alone, with hand-written scanning.**
   + No generator.
   − Every query's columns and types are checked only by tests.

**B. Migrations**
1. **goose, with SQL files embedded in the binary, run as `cvwriter_owner` by a separate `migrate` command at deploy, never by the app at start-up.**
   + Plain SQL; works with ADR-002's two roles.
   − Deploy has a step that runs before the app restarts, so for a short time the previous binary runs on the new schema.
2. **atlas, which works out migrations from a declared schema.**
   + Changes are planned from the target schema.
   − A heavier tool, and generated columns and triggers are where declarative tools are weakest.

**C. PDF rendering**
1. **chromedp drives this project's own pinned copy of `chrome-headless-shell`.**
   + Faithful HTML and CSS.
   − A full browser handles content derived from untrusted text: it can make network requests and read files unless locked down.
   − Security updates roughly every 4 weeks, by hand; ~200–300 MB of memory per render.
2. **chromedp drives the box's system Google Chrome.**
   + Nothing extra to install.
   − Another tenant or an automatic update can change or remove it; the same exposure as C1.
3. **A pure-Go PDF library.**
   + No browser at all.
   − Layout written by hand in the library's own code; slow work that drifts from the designs.
4. **Typst renders a template from structured CV data.** Claude returns the CV as JSON; a pinned `typst` binary lays it out.
   + No JavaScript and no network; it reads files only under the folder it is given.
   + Model output is placed as text, never as markup, so a hostile ad has nothing to inject into.
   + The same JSON gives the Markdown file, so the MD and the PDF can't drift.
   + Small: well under 100 MB while rendering, about a second per CV; tagged PDF output with a real text layer.
   − Designs 1 and 2 are rebuilt as Typst templates, and fidelity is checked against the mocks.

**D. Where traces and metrics go**
1. **A hosted OpenTelemetry backend on a free tier (Grafana Cloud), sent over OTLP.**
   + Nothing runs on the shared box; one trace from screen to database is visible from day one.
   − An outside account to create, and a token in the server's environment.
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
- **Shape** (one-way door):
  - One Go binary serves the JSON API under `/cvwriter/api/`, plus the single-page app's `index.html`. It sits behind nginx.
  - Where the built JS and CSS are served from is decided in ADR-004.
  - Built in CI for linux/amd64 with `CGO_ENABLED=0`; the box's own Go is never used.
  - The systemd unit sets `MemoryMax=`, and the binary sets `GOMEMLIMIT`, so the app can't starve the other sites. Values are set from memory measured in the walking skeleton.
- **Versions:**
  - Back end: Go 1.27, chi v5.
  - Front end: Node 24 LTS, pnpm 12, React 19, TypeScript in strict mode, Vite 8.
  - Exact versions live in `go.mod` and the pnpm lockfile.
- **Go modules:**
  - `ads`, `cvs`, `usage`, `account` (login, password and the API key), `claude` (the only caller of the Claude API, ADR-001) and `pdf`.
  - Each module's insides sit in its own `internal/` folder, so the compiler stops other modules reaching past its `api` package.
  - depguard in golangci-lint holds the narrow rules: only `claude` imports the Anthropic SDK; only `pdf` runs the renderer.
- **A1: database access** (medium door): pgx v5 with sqlc. CI fails if the generated code is out of date. A query whose filters change per request (Feature 2's search) may be written by hand with pgx. Both kinds are tested against a real PostgreSQL 18.
- **B1: migrations** (medium door):
  - goose SQL files, embedded, run by `cvwriter migrate` as `cvwriter_owner` at deploy, before the restart. The app connects as `cvwriter` only.
  - Every migration works with the binary already running (add first, remove in a later release).
  - Production only rolls forward; down migrations are for development.
  - A database backup runs right before every `migrate`.
- **C4: PDF rendering** (medium door):
  - Claude returns the CV as JSON, checked in Go against a versioned schema. A Go template writes the `.md`; Typst writes the `.pdf`.
  - The `typst` binary is pinned by version and SHA-256 and shipped by deploy.
  - Each render runs with its own deadline inside the 90 s budget for creating a CV, in a fresh temporary folder given as its root, with system fonts ignored and the bundled Manrope only.
  - Model strings are placed as text; templates never evaluate model output as Typst code.
  - At most one render at a time; a second request waits within its own deadline.
  - The 2-page and ATS checks (PRD) read the rendered PDF.
  - **Spike in the walking skeleton:** design 1 in Typst, compared side by side with its mock; the text layer and PDF tagging checked.
  - **Fallback if the spike fails fidelity:** C1, with chromedp driving the pinned `chrome-headless-shell` in its own socket-activated systemd unit with `PrivateNetwork=yes`, every page request denied, the font embedded in the page, and its own `MemoryMax=`.
- **D1: telemetry** (two-way door; OTLP works with any backend):
  - OTLP to a Grafana Cloud free-tier stack. The endpoint and token come from the server's environment.
  - The browser sends its spans to the app's own `/cvwriter/api/telemetry`, which relays them; no telemetry token is ever in the browser.
  - The exporter batches and drops spans when its buffer is full, so an outage at the backend never slows a request.
  - Span attributes never hold ad text, CV text, emails or keys; the log test covers this.
- **E1: front end** (two-way door): React Router and TanStack Query, with no UI component library (brief).

## Consequences
+ One trace runs from the screen to the database, as the walking skeleton requires.
+ SQL mistakes fail at build time; migrations run with the owner role only, and never break the running binary.
+ No browser runs on the server: rendering makes no network requests, needs no monthly security updates, and uses little memory.
+ The MD and PDF of a version come from the same data.
− Designs 1 and 2 have to be rebuilt as Typst templates, and the spike may send us to the Chrome fallback.
− Claude's CV output has a JSON schema to keep versioned.
− Deploy runs in order: back up, migrate, copy the binary, restart.
− An outside telemetry account and its token have to be created and kept.

## Revisit when
- The walking-skeleton spike can't match design 1's mock in Typst: switch to the C1 fallback.
- Memory available on the box at peak drops below 500 MB: move hosts.
- More than one user creates CVs at the same time often enough that renders queue for over 10 s.
- The telemetry free tier's limits are reached, or its terms change.
