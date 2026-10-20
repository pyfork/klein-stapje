# ADR-006: Spaces keys can delete old versions and ignore conditional writes, so write-once rests on the app; the Typst spike moves to the CV-render slice

<!-- senior-lead-Opus5.5-agent, 2026-10-20 -->

Status:   Accepted 2026-10-20. Amends ADR-003 (C4, when the Typst spike runs) and ADR-004 (what the keys can do, and its first consequence).
Door:     two-way (both are about timing and checks; no stored data depends on them)
Deciders: the owner

## Context
ADR-003 and ADR-004 left three things for the walking skeleton to find out.
They were checked before its brief was written, because two of them could
change a decision:

- **Can a Spaces key be unable to delete old versions?** The threat model's
  T-37 relied on it. On 2026-10-20 a key limited to one throwaway bucket with
  Read/Write access, on a bucket with versioning on:
  - deleted an old version by its id: **allowed**;
  - suspended versioning: denied;
  - added a lifecycle rule that expires old versions: denied.

  Spaces offers only read, read/write and full access per bucket, so no key
  can write without being able to delete.
- **Does Spaces honour `If-None-Match: *`?** The same test overwrote an
  existing object with the header set: **not honoured**. A new object with the
  header was written normally.
- **Can Typst match the design 1 mock?** The mock doesn't exist yet, so the
  spike can't run in the skeleton.

## Options considered
For T-37:
1. **Stay on Spaces alone.** The app's key reaches only `cvwriter-files`, the
   backup job's key only `cvwriter-nightlybackups`, and the backup job runs as
   its own user. A locked second copy waits for ADR-004's trigger.
   + No new provider or account; the smallest working version.
   − Root on the server holds both keys and can delete old versions until the
   second copy exists.
2. **A nightly copy to a store that can lock objects** (Cloudflare R2 bucket
   locks, or Backblaze B2 Object Lock with a key that can't delete).
   + History survives a full compromise of the server.
   − One more store and key to run before anything personal needs it.

For the Typst spike:
1. **Keep it in the walking skeleton.** − It needs a mock that doesn't exist.
2. **Run it in the CV-render slice, after the design 1 mock is made.**
   + The skeleton stays thin. − The C1 fallback, if needed, is found later;
   no stored data depends on the renderer, so switching is still cheap.

## Decision
- **T-37: option 1**, the owner's choice for the smallest working version.
  The locked second copy (option 2) is added on ADR-004's existing trigger:
  the first CVs sent to employers, or a Spaces incident.
- **Write-once rests on the app, not on Spaces.** No put sends
  `If-None-Match`. The `storage` module has no overwrite or delete path, every
  object key holds an id that is never reused (ADR-004), and the nightly check
  compares every object with the SHA-256 and size in its insert-only row.
- **The Typst spike runs in the CV-render slice**, once the design 1 mock
  exists, with the same pass test and the same C1 fallback as ADR-003's C4.
  Memory is measured again there: `MemoryMax=` and `GOMEMLIMIT` from the
  skeleton are a baseline without rendering.

## Consequences
+ The walking skeleton needs no mock and no second provider.
+ The nightly fingerprint check stays the detector for a changed or missing file.
− ADR-004's "overwrites and deletes are recoverable" holds only for the app's
  own code paths. Someone holding a key can delete an old version, and the
  nightly check reports it but can't bring it back.
− The renderer's fidelity is unproven until the CV-render slice.

## Revisit when
- The first CVs are sent to employers, or Spaces has an incident: add the
  locked second copy (ADR-004).
- Spaces offers object lock, or keys that can write without deleting: test
  again, and use it.
- The Typst spike fails fidelity: switch to C1 (ADR-003).
