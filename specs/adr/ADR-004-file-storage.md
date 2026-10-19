# ADR-004: Files live in private Spaces buckets, written once and fetched by short-lived signed links; the app's JS and CSS are served by the binary behind the existing CDN

<!-- prd-interviewer-Opus5.5-agent, 2026-10-19 -->

Status:   Accepted 2026-10-19
Door:     two-way for asset serving; one-way for the object key layout and write-once rules
Deciders: the owner

## Context
The brief settled that files (CV PDFs and, in Feature 2, uploaded reference CVs) live in a private DigitalOcean Spaces bucket, are downloaded by short-lived signed links, and that a CDN is used only for the app's JS and CSS. The PRD requires that each PDF is written once and never changed, and that every Generate makes a new version.

Left open: how the binary and the CDN split the files (and so the CSP and the origin), how "written once" is enforced, how a download link works, how uploads arrive, the bucket's region and keys, and where backups go.

Facts that shape it (checked 2026-10-19):
- The site's domain already sits behind a Cloudflare proxy, so a CDN is in front of every response.
- Spaces keys can be limited to one bucket, but only as Read, or Read/Write/Delete: a key that can write can also delete. Keys are created only in the control panel.
- Spaces supports bucket versioning (enabled through the API). Object Lock appears unsupported. Conditional writes (`If-None-Match: *`) are unconfirmed.
- A Spaces CDN on a custom subdomain needs a certificate brought and renewed by hand unless DNS is hosted at DigitalOcean; it isn't.
- The server's clock is synchronised (chrony, NTP).

What breaks if this is wrong: a CV version silently overwritten or deleted; one user reading another's file; a signed link leaking through logs or telemetry; HTML and JS from different releases; a database lost with the server.

## Options considered
**1. Serving the built JS and CSS**
1. **Embedded in the Go binary, cached by the existing Cloudflare proxy.**
   + One deploy artifact, so the HTML and its assets can't drift; same origin, so the CSP is `'self'` with no CORS and no extra certificate.
   − A tab left open across a deploy can miss an old chunk.
2. **A public Spaces bucket with the Spaces CDN.**
   + Assets never touch the server.
   − A second bucket, a two-step deploy, the CDN origin in the CSP, CORS for module scripts, and a hand-renewed certificate for a custom subdomain.

**2. Enforcing "written once"**
1. **Four layers:** unique keys, add-only storage code, bucket versioning, a stored SHA-256 checked nightly.
   + A bug or a leaked key can't silently destroy a version: the old copy is recoverable and the nightly check notices.
   − Versioning is set up by API, and a nightly job has to run.
2. **Unique keys and add-only code only.**
   + Simpler.
   − An overwrite or delete would go unnoticed and be unrecoverable.

**3. Download links**
1. **The API checks ownership, then redirects to a signed link valid for 60 seconds.**
   + Only the owner gets a link, and a leaked link dies within a minute.
   − The browser must follow the redirect as a navigation, not a `fetch`.
2. **The same, with a 5–15 minute expiry.**
   + A link can be opened on another device.
   − A longer window if a link leaks; not needed.

**4. Uploads (Feature 2)**
1. **Through the Go server.**
   + The server needs the bytes to extract text anyway; limits and type checks happen in one place.
   − Upload bytes pass through the server (small files, one user).
2. **Straight from the browser to Spaces with a signed upload link.**
   + The server never carries the upload.
   − The server then downloads the file again to read it, and the bucket needs CORS.

**5. Key storage**
1. **A systemd credential file**, like the master key (ADR-001).
   + Not in the environment, not inherited by child processes.
   − One more credential to install at deploy.
2. **In `.env` with the other settings.**
   + Simpler.
   − Leaks through environment dumps and child processes; inconsistent with ADR-001.

**6. Off-box backups**
1. **Spaces only: file history by bucket versioning, and nightly database dumps to a separate Spaces bucket.**
   + No second provider or account; the dumps still leave the server, which runs at a different provider.
   − One provider and one account hold the files and every backup; a Spaces key can delete.
2. **AWS S3 with Object Lock as the backup target.**
   + Backups can't be deleted for a set period, even with the key.
   − A second account to keep; the server runs at the same provider.
3. **Cloudflare R2.**
   + A third, independent provider with a free tier.
   − Its locking was not confirmed to match Object Lock.

## Decision
- **Assets (1.1, two-way door):**
  - Vite's hashed build output is embedded in the binary and served under `/cvwriter/assets/` with `Cache-Control: public, max-age=31536000, immutable`; `index.html` is `no-cache`.
  - Cloudflare caches the assets; a cache rule bypasses `/cvwriter/api/*`, and every API response sends `Cache-Control: no-store`.
  - CSP: `script-src 'self'`; no third-party origins for scripts or styles.
  - When a lazy-loaded chunk fails to load after a deploy, the app reloads once.
- **Buckets and keys (5.1):**
  - Two private buckets in the Spaces region nearest the server: `cvwriter-files` and `cvwriter-nightlybackups`. Versioning is on for both, and older versions are kept.
  - The app's key is limited to `cvwriter-files`; the backup job's key is limited to `cvwriter-nightlybackups`. Neither key can reach the other bucket.
  - Both keys are systemd credentials (`LoadCredential=`), never in `.env`. They are rotated yearly, and at once on a leak (steps in the threat model).
- **Object keys (one-way door):**
  - CV PDFs: `cv/{user_id}/{version_id}.pdf`.
  - Reference CVs: `refcv/{user_id}/{id}.{ext}`.
  - Ids are never reused (ADR-002).
- **Written once (2.1):**
  - The storage module exposes only "put a new object" and "sign a download link"; no code path overwrites or deletes.
  - Each `cv_versions` row stores the PDF's SHA-256 and size (the row is insert-only, ADR-002). A nightly job checks every object against them and alerts on a mismatch or a missing object.
  - The walking skeleton tests whether Spaces honours `If-None-Match: *`; if it does, every put uses it.
- **Downloads (3.1):**
  - Download is a plain link to `/cvwriter/api/cv-versions/{id}/download`, never a `fetch`.
  - The lookup uses both the id and the signed-in user (`WHERE id = $1 AND user_id = $2`). No match, or an invalid id, returns 404. A 401 on this route redirects to login with a return path.
  - The response is a `302` to a signed GET link valid for 60 s, with `Cache-Control: no-store`.
  - The link sets `Content-Disposition: attachment` with a safe file name: accents stripped (Unicode NFD), every run outside `A–Z a–z 0–9` replaced by `-`, at most 80 characters, falling back to `cv-v{n}`.
  - Signed links are never stored, logged, or recorded in spans; HTTP instrumentation records no response headers.
- **Uploads (4.1):**
  - Through the server: at most 5 MB per file and 20 files per upload; type checked from the file's contents (PDF, DOCX or MD only).
  - The original goes to `cvwriter-files`; the extracted text goes to Postgres.
  - The extraction tool is chosen in Feature 2's spec.
- **Backups (6.1):**
  - Nightly database dumps go to `cvwriter-nightlybackups`. Files rely on versioning in `cvwriter-files`.
  - Schedule and restore test: `specs/architecture.md`.
  - Accepted risk: one provider and one account hold the files and every backup.
- **Checks:**
  - CI fails any query on a user-owned table without `user_id` in its WHERE.
  - CI tests against a local S3-compatible store: a fresh link returns 200 with the expected `Content-Disposition`; an expired one is refused; another user's id returns 404.
  - The log test runs a download, success and error paths, and fails if `X-Amz-Signature` appears in any log line or span.
  - A post-deploy smoke test signs a link to a fixed canary object in the real bucket and expects 200 with the expected file name.
  - A Playwright test clicks Download and checks that a file is saved under the expected name.

## Consequences
+ One deploy artifact for the app; no CORS and no second origin in the CSP.
+ A CV version can't be silently lost: overwrites and deletes are recoverable and detected nightly.
+ Only the owner of a file gets a link to it, and a leaked link is dead within a minute.
+ The database leaves the server every night.
− Versioning is enabled by API when each bucket is created.
− A nightly job (dump plus fingerprint check) has to run and alert.
− Keys are rotated by hand in the control panel.
− Files and backups share one provider and one account.

## Revisit when
- The first CVs are sent to employers, or Spaces has an incident that affects these buckets: add an independent backup target (option 6.2 or 6.3).
- A second user joins: enforce `user_id` with PostgreSQL row-level security as well as the CI check.
- Spaces adds Object Lock or write-only keys: use them.
- The nightly check ever finds a mismatch.
