# Threat model: cvwriter

<!-- prd-interviewer-Opus5.5-agent, 2026-10-19. From docs/claude-pkg/TEMPLATE-THREAT-MODEL.md.
     Status: draft. Accepted threats decided: A-1 to A-5. Awaiting: A-6, A-7. -->

Last updated: 2026-10-19, first draft

## Assets
| Asset | Who may read it | Who may change it |
|---|---|---|
| Ads, analyses, CV versions, reference CVs (personal and career data) | The signed-in owner of the rows | The owner; CV versions and history are insert-only (ADR-002) |
| The user's Claude API key | The `claude` module, in memory, for one call (ADR-001) | The user, with the current password |
| The master key, file-storage keys, the database owner password, the backup encryption key | The systemd unit that loads each one | The server's root user |
| Session tokens and the password hash | Nobody: only hashes are stored | Sign-in, sign-out and password change |
| Claude spend (money) | The owner, in the Usage view | Every Claude call, under the user's alert and stop limits |
| CV PDFs and uploaded files | The owner, through a 60 s signed link (ADR-004) | Add-only: no overwrite or delete path |
| Nightly backups | The backup job and the restore test | The backup job; encrypted with `age` |
| Availability of the app and of the other sites on the shared server | Everyone | Memory and CPU limits on every unit |

## Trust boundaries
| # | Boundary | From | To | What crosses it |
|---|---|---|---|---|
| TB-1 | Browser to app (through Cloudflare Access and nginx) | Anyone on the internet; then the signed-in user | The app | The Access sign-in (email code, passkey) and its signed token; sign-in, pasted ads, uploads, settings, the session cookie, SSE progress, browser spans |
| TB-2 | App to Claude API | The app | Anthropic | Ad text and reference CV text out; model output in (untrusted) |
| TB-3 | App and browser to Spaces | The app (keys); the browser (signed links) | DigitalOcean | PDFs, uploaded files, encrypted dumps; signed download links |
| TB-4 | App and server to the telemetry backend | The app; the server's log shipper | Grafana Cloud | Route patterns, timings and counts; the server's SSH sign-in and sudo events; no personal data |
| TB-5 | The shared server | Other sites and their users on the same server | cvwriter's processes, files and database | Memory and CPU contention; anything a compromised neighbour reaches |

## Riskiest flows
1. **Sign-in and the session:** crosses TB-1.
2. **Entering and using the Claude API key:** crosses TB-1 and TB-2.
3. **Pasting an ad, through Claude, to a rendered CV:** untrusted text crosses TB-1 and TB-2 and reaches the renderer.
4. **Files: downloads, uploads and backups:** crosses TB-1 and TB-3.

## STRIDE, per flow

### 1. Sign-in and the session
| # | Threat | STRIDE | Answer | Where |
|---|---|---|---|---|
| T-1 | Password guessing or credential stuffing | Spoofing | Rule: the sign-in form sits behind Access (T-39); growing delays per account and per client IP, never a lock; argon2id | Architecture, Sign-in; throttle test |
| T-2 | A stolen database or backup is used to sign in | Spoofing | Rule: only token hashes and argon2id hashes are stored | Architecture, Sign-in; schema test |
| T-3 | Session fixation, or a cookie planted by a sibling site | Tampering | Rule: a new token at every sign-in; `__Host-` cookie on its own subdomain | ADR-005; cookie test |
| T-4 | A request forged from another site uses the cookie | Tampering | Rule: SameSite=Strict, JSON-only API, `Origin` checked on every change | Architecture, Sign-in; CSRF test |
| T-5 | "I didn't do that": no record of who changed what | Repudiation | Accepted, see A-6 | — |
| T-6 | A sign-in reply reveals whether an email has an account | Information disclosure | Test: the same error and timing for an unknown email | Sign-in test |
| T-7 | A login flood exhausts the shared server's memory | Denial of service | Rule: at most 2 password hashes at a time; nginx and app rate limits; `MemoryMax=` | Architecture, Sign-in and Server units |
| T-8 | An unattended signed-in browser changes the password or key | Elevation of privilege | Rule: the current password for both; a new password ends other sessions | Architecture, Sign-in; settings test |
| T-39 | A stolen or guessed password alone signs in | Spoofing | Rule: Cloudflare Access in front of the whole subdomain: an email code sent only to the owner's address, then a passkey (Touch ID on the owner's laptop) | Architecture, Sign-in and One-time setup |
| T-40 | A request sent straight to the server, not through Cloudflare, skips Access | Spoofing | Rule: the server block accepts only Cloudflare's address ranges, and the app checks Access's signed token on every request except `/api/health` (signature, issuer, audience, expiry, and the email equal to the account's) | Architecture, Sign-in; token test |

### 2. Entering and using the Claude API key
| # | Threat | STRIDE | Answer | Where |
|---|---|---|---|---|
| T-9 | A fake or someone else's key is saved | Spoofing | Rule: saved only after a successful test call | ADR-001 |
| T-10 | A ciphertext is moved to another user's row | Tampering | Rule: AES-256-GCM with `user_id` as associated data, so decryption fails | ADR-001; crypto test |
| T-11 | Spend can't be traced to a call | Repudiation | Rule: one insert-only usage row per call | ADR-001, ADR-002 |
| T-12 | The key leaks through a response, URL, log, span or browser storage | Information disclosure | Test: the log test with a key pattern; the key never leaves the server; only the last 4 characters shown | ADR-001; log test |
| T-13 | A database dump or backup exposes the key | Information disclosure | Rule: the key is encrypted at rest and the dump is encrypted again with `age` | ADR-001; architecture, Backups |
| T-14 | Root on the server reads both the master key and the database | Information disclosure | Accepted, see A-1 | — |
| T-15 | Runaway calls spend the user's money | Denial of service | Rule: the alert and stop limits checked before each call; a spend limit on the key itself | ADR-001; spend test |
| T-16 | Code other than `claude` decrypts the key | Elevation of privilege | Test: depguard allows `DecryptKey` only in `claude` | ADR-003 |

### 3. Pasting an ad, through Claude, to a rendered CV
| # | Threat | STRIDE | Answer | Where |
|---|---|---|---|---|
| T-17 | An ad poses as instructions to Claude (prompt injection) and steers the analysis or CV | Spoofing | Rule: the model has no tools; output is schema-checked JSON; the user reviews before sending. Residual accepted, see A-4 | ADR-001 |
| T-18 | Model output carries markup or code into the PDF | Tampering | Rule: Typst places strings as text, `eval` banned (CI check); no network, root-only file access | ADR-003; golden-file test |
| T-19 | Model output carries script into the app's pages | Tampering | Rule: React escapes by default; no raw HTML from model output; CSP `script-src 'self'` | ADR-003, ADR-004; lint rule |
| T-20 | Which model wrote a CV can't be shown | Repudiation | Rule: the answering model is stored per call and shown in Usage | ADR-001 |
| T-21 | Ad and CV text leave for the model provider | Information disclosure | Accepted, see A-7 | — |
| T-22 | Ad or CV text lands in logs or spans | Information disclosure | Test: the log test; spans hold route patterns only | ADR-003 |
| T-23 | Huge pastes or repeated Generates exhaust memory or money | Denial of service | Rule: a size limit on pastes; one job per ad at a time; render deadline and `MemoryMax=`; spend stop | Architecture; job test |
| T-24 | A crafted ad makes the renderer read files or reach the network | Elevation of privilege | Rule: Typst runs with a fresh temporary root, no network access, system fonts ignored | ADR-003 |

### 4. Files: downloads, uploads and backups
| # | Threat | STRIDE | Answer | Where |
|---|---|---|---|---|
| T-25 | A user fetches another user's file by changing the id | Information disclosure | Test: ownership in the query; 404 for others' ids | ADR-004; download test |
| T-26 | A file name from ad text injects into the download header | Tampering | Test: the safe-name function against hostile inputs | ADR-004 |
| T-27 | A CV version is overwritten or deleted | Tampering | Rule: add-only storage code, unique keys, bucket versioning, nightly SHA-256 check | ADR-004 |
| T-28 | A signed link is reused or shared | Information disclosure | Rule: 60 s expiry; never stored, logged or recorded in spans | ADR-004; log test |
| T-29 | An uploaded file is not what it claims, or is a zip bomb | Tampering | Rule: type checked from contents; 5 MB and 20 files per upload; extraction limits set in Feature 2's spec | ADR-004 |
| T-30 | A leaked storage key reads or deletes files or backups | Information disclosure | Rule: one key per bucket; dumps encrypted; versioning keeps deleted copies; key rotation runbook. Residual accepted, see A-2 | ADR-004; Runbooks |
| T-31 | Backups exist but don't restore | Denial of service | Test: the monthly automated restore test, with an alert | Architecture, Backups |
| T-32 | The app reads the cloud metadata service | Elevation of privilege | Rule: token-only metadata access on the server; `IPAddressDeny=` on every unit | Architecture, Server units |

### Across flows: the shared server and the repository
| # | Threat | STRIDE | Answer | Where |
|---|---|---|---|---|
| T-33 | Another site on the shared host's origin reads cvwriter's data | Information disclosure | Rule: its own subdomain | ADR-005 |
| T-34 | A compromised neighbour on the shared server becomes root and reaches cvwriter | Elevation of privilege | Rule, before go-live: no service on the server runs as an account that can use sudo, and every account with full sudo is a named admin account in use; cvwriter's units are sandboxed. Residual accepted, see A-3 | Architecture, Server units and One-time setup |
| T-35 | Real ads, real CVs or the private test set are committed to the public repository | Information disclosure | Rule: content rules; a pre-push check; the test set lives only on the server | Content rules |
| T-36 | A local process skips nginx, calls the app directly and fakes the client IP, defeating the per-IP sign-in delays | Spoofing | Rule: no TCP port; the app listens on a unix socket that only nginx's user can open | Architecture, Server units; socket permission test |
| T-37 | Root on the server deletes every backup and every old file version | Tampering | Rule: the server's storage keys can't delete object versions; checked in the walking skeleton, with a fallback recorded if Spaces can't do it | Architecture, One-time setup |
| T-38 | A server compromise goes unnoticed | Repudiation | Rule: SSH sign-ins and sudo events are shipped off the server, with an alert on either by an account other than the admin account | Architecture, Telemetry |

## Accepted
- **A-1** (T-14): the master key and the database share one server, so root access reads both; the encryption protects dumps and backups only. Accepted (the owner's decision), because there is one server and one user. A cloud key service was considered and deferred: the server has no cloud identity, so it would hold that service's credential too, and root could still decrypt through it; it adds logging and revocation, not prevention. Revisit when there are two app servers or a second user: move the master key to a key service.
- **A-2** (T-30): files and every backup sit with one provider, in one account. Accepted (the owner's choice). Revisit when the first CVs are sent to employers, or on a Spaces incident.
- **A-3** (T-34): cvwriter shares a server with other sites, and stays there (the owner's decision). Root on that server reaches cvwriter's data and keys, and nothing on the server can stop it. Accepted, with conditions that narrow the ways to root (T-34), limit what root can take or destroy (T-15's spend limit on the key, T-37) and make a compromise visible off the server (T-38). Revisit when free memory at peak drops under 500 MB, another tenant is affected, or a second user joins.
- **A-4** (T-17): prompt injection can still bend a CV's wording. Accepted (the owner's decision), because the model has no tools, its output is checked, and the user reads every CV before sending it. Revisit if the model is ever given tools or a CV is sent without review.
- **A-5** (T-39): one second-factor device. Sign-in needs an email code and a passkey through Access (T-39, T-40), then the app's password, but only one passkey is enrolled, so a lost laptop means a reset in the Cloudflare dashboard (runbook below). The email code alone can be phished; the passkey can't. Accepted (the owner's decision): a backup passkey is deferred. Revisit when a second device is at hand (enrol it), or a second user joins (passkeys in the app).
- **A-6** (T-5): no audit log of who changed what. Accepted, because there is one user and the history that matters is insert-only. Revisit when a second user joins.
- **A-7** (T-21): ad and reference CV text are sent to the model provider under the user's own key and that provider's data terms. Accepted, because the product needs it. Revisit if the provider's data retention terms change.

## Runbooks
**A Claude API key leaks**
1. Revoke the key in the Anthropic Console.
2. Create a new key with a spend limit, and save it in Settings (it's checked with a test call).
3. Compare the Console's usage with the Usage view to spot calls cvwriter didn't make.

**A storage key leaks**
1. Delete the key in the DigitalOcean control panel, create a replacement for the same bucket, install it as the unit's credential, and restart the unit.
2. List object versions for deletes or overwrites; restore from versions where needed.
3. The nightly fingerprint check confirms every CV version still matches.

**The master key or the server is compromised**
1. Take the app offline.
2. Read the off-server SSH and sudo log (T-38) to find the way in and when it started.
3. Generate a new master key; re-encrypt the stored API key under the new `key_version`.
4. Revoke and replace the Claude key, both storage keys, the database passwords and the backup encryption key.
5. Restore onto a clean server from the latest dump if needed, using the offline key copy.
6. Delete every session, so everyone signs in again.

**Locked out of Access, or the laptop is lost**
1. In the Cloudflare dashboard, delete the lost passkey under the user's MFA devices.
2. Sign in to the Access App Launcher with an email code and register a passkey on the device in hand.
3. If the laptop was lost: remove its SSH key from the server (through the hosting provider's web console if needed), set a new app password with `cvwriter set-password`, and delete every session.

**A backup fails, or the restore test fails**
1. The alert names the step. Run the backup job by hand and read its log.
2. Don't deploy until a dump has been verified by a restore.
