# ADR-001: Only the server calls the Claude API, with the owner's key encrypted at rest

<!-- prd-interviewer-Opus5.5-agent, 2026-10-19 -->

Status:   Accepted 2026-10-19
Door:     one-way
Deciders: the owner

## Context
Ad analysis and CV writing are done by the Claude API (PRD: journeys 1 and 2).
Each call is billed to the owner's own API key, so a leaked key means someone
else spends the owner's money until the key is revoked. The key must be entered and
replaced from Settings (shown masked, e.g. `sk-ant-…a1b2`, with Replace and
Delete), and checked with a small test call when saved. Spend is capped by the app
(an alert at $20 a month, no new calls at $50; PRD budgets), so every call has to
go through one place that can count it.

The server runs systemd 249 with no TPM. That gives `LoadCredential=` (systemd
247 and later) but not `LoadCredentialEncrypted=` (250 and later).

What breaks if this is wrong: the key leaks through the browser, logs or a
database dump, or spend can't be counted and capped.

## Options considered
1. **The server calls Claude. The key is stored in Postgres encrypted with AES-256-GCM; the master key comes from a root-only file passed in by systemd `LoadCredential=`.**
   + The key never reaches the browser, and a database dump or backup without the master key reveals nothing.
   + The key can be set and replaced from Settings, and the design is ready for one key per user later (every row already has a `user_id`).
   + Every call goes through one Go function, so spend is counted and capped in one place.
   − A master key file has to be created, kept and backed up outside git and outside the database. Losing it means entering the API key again; nothing else is lost.
   − About a day of extra work: encrypt/decrypt code, a key-version column, and tests.
2. **The server calls Claude. The key sits in the service's `.env` file (mode 0600).**
   + Simplest: no encryption code and no master key.
   − The key can't be set or replaced from Settings (the brief requires this); changing it means SSH access and a restart.
   − The key is in plain text on disk. Anyone who can read the service's files, or a copy of them, has it.
   − No route to one key per user.
3. **The browser calls Claude directly, with the key held in the browser.**
   + No server code for calls.
   − The key is in the browser and in every request. That breaks the brief's security rules, and the app can't count or cap spend.

## Decision
Option 1:
- **Only the Go server calls the Claude API.** The key never appears in a response body, URL, cookie, browser storage, log line or file storage. Settings shows only the last 4 characters.
- **The key is stored in Postgres encrypted with AES-256-GCM:** a fresh random 12-byte nonce for each encryption, the row's `user_id` as associated data, and a `key_version` column so the master key can be rotated.
- **The master key** is 32 random bytes in a root-only file (mode 0400) outside the repository. The unit passes it in with `LoadCredential=`, and the app reads it from `$CREDENTIALS_DIRECTORY`. The app refuses to start if it is missing or the wrong length.
- **Decrypted only for the call that needs it,** held in memory for that request, never cached between requests.
- **On save, the key is checked with a minimal test call.** An invalid key is rejected and not stored.
- **Logs:** a scrubber removes anything that looks like a key (`sk-ant-` and the text after it), and Claude error messages are reduced to a status and a short reason before they are logged or shown. The log test (engineering rules section 14) includes a key pattern.
- **Model: Claude Opus 5.5 (`claude-opus-5-5`) at effort `medium`.** This is the owner's choice. Thinking can't be turned off on this model. The model name and effort are constants in code, not settings.
- **How calls are made:**
  - The analysis call asks for JSON that matches a schema (structured outputs). The reply is checked before it is saved.
  - The CV call is streamed, so the screen can show progress.
  - Timeouts follow the PRD budgets: 30 s for analysis, 90 s for a CV including the PDF. Each budget is a single deadline on the request's context, and it covers the SDK's own retries, so retrying can never stretch a call past its budget.
  - Server-side refusal fallback is on (`fallbacks: "default"`). A refusal that still stops the call is shown as an error, and nothing is saved.
- **Every call writes one usage row:** what it was for, the model that actually answered, input / output / cached token counts, the price at the time of the call, the cost, how long it took and whether it succeeded. Before each call the app checks the month's spend against the $50 stop. The Usage view shows which model answered each call, so a reply from the fallback model is visible.
- **Changing the model, effort or prompt:**
  - The test set is the last 10 real ads whose CVs were kept (not flagged "Not good").
  - Before a change goes live, those ads are run through it, and the new problem #1, 2-page check and ATS keyword check are compared with the kept versions.
  - The test set is stored privately on the server, never in git, because the ads are real.
  - Invented test ads are not used: they wouldn't look like the ads actually pasted.

## Consequences
+ A leaked database dump or backup doesn't leak the key.
+ Spend is counted and capped in one place; the Usage view reads the same rows.
+ Moving to one key per user later only changes who owns each row.
− The master key file has to be created on the server and backed up somewhere other than the database backups. Losing it means entering the API key again.
− Rotating the master key means decrypting and re-encrypting each stored key; `key_version` makes this one migration.
− Opus 5.5 costs about twice what Sonnet 5.5 would (PRD load: ~$7 a month expected).

## Revisit when
- A second user is added: look at a managed key service instead of a local file.
- The server reaches systemd 250 or later, or has a TPM: switch to `LoadCredentialEncrypted=`.
- The average cost per CV goes over $0.25 for two weeks in a row (PRD measure): look at the effort level or the model.
- Opus 5.5 gets a retirement date: choose the replacement using the test set.
- In a week, more than 5% of analyses take over 30 s, or more than 5% of CVs take over 90 s (PRD speed budgets): look at the effort level or the model.
- More than 5% of a month's calls are answered by the fallback model: look at why requests are being declined.
- More than 20% of a month's CVs are flagged "Not good" (PRD measure): look at the prompt, the effort level or the model, checking each change with the test set.
