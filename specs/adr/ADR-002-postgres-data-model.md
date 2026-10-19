# ADR-002: Postgres holds every record; the analysis is checked JSONB with indexed search columns

<!-- prd-interviewer-Opus5.5-agent, 2026-10-19 -->

Status:   Accepted 2026-10-19
Door:     one-way
Deciders: the owner

## Context
Every ad is stored in the same format: basics, ad content, ranked problems,
keywords, red flags, the raw ad, and later the Match section (PRD, journey 1).
Search covers title, company, keywords, problems and the full text, and in
Feature 2 it matches as you type. CV versions and usage rows are never changed
once written. There is one user now; every row carries `user_id` so that more
users later are a small change.

The server already runs PostgreSQL 18.6, with a `cvwriter` database owned by a
non-superuser `cvwriter` role. `pg_trgm` is available and is a trusted extension,
so the database owner can install it. Load is small: ~250 ads, ~500 CV versions
and ~750 usage rows a year (PRD load).

What breaks if this is wrong: each change to the analysis format turns into a
migration across many tables; search misses ads or gets slow; old CV versions
or spend records get edited.

## Options considered
1. **Postgres. The analysis is one JSONB column, checked in Go against a versioned schema and backed by a few `CHECK` constraints. The fields shown on lists, and a weighted `tsvector` search column with a GIN index, are generated from the JSON by the database.**
   + A new field in the analysis (Feature 2's Match) is a schema version bump, not a migration on many tables.
   + Lists and search read plain columns and indexes, never the inside of the JSON.
   + Uses the database and role that already exist.
   − The full JSON shape is enforced by Go code and tests; the database checks only the fields screens depend on.
2. **Postgres, fully split into tables (problems, keywords, requirements and match lines each in their own table).**
   + The database enforces every field; keywords can be queried across ads directly.
   − Every change to the analysis format is a migration across several tables; Feature 2 adds more.
   − Saving or showing one ad means writing or reading many tables, for 250 ads a year.
3. **SQLite with FTS5.**
   + A single file; strong built-in full-text search.
   − The brief chose Postgres, and Postgres is already set up on the server.
   − A second user or a second process means locking and moving data later.

## Decision
Option 1:
- **One database, `cvwriter`, on PostgreSQL 18. Two roles, neither a superuser:**
  - `cvwriter_owner` runs migrations and owns the schema and every table.
  - `cvwriter`, the app's role, gets only the privileges it needs on each table. It owns nothing, so grants actually limit it.
- **Every table has `user_id`,** a foreign key to `users`, and every query filters on it. Every index used for lookups starts with `user_id`.
- **Ids are `uuid` columns filled with `uuidv7()`.** That is built into Postgres 18; the ids sort by time and are not guessable in sequence.
- **`ads`:**
  - `raw_ad` is the text exactly as pasted, never changed.
  - `analysis` is JSONB, with an `analysis_schema_version` integer. Go checks the analysis against that version's schema before it is saved, and an analysis that fails the check is never stored.
  - `CHECK` constraints back up the fields screens depend on: `analysis_schema_version > 0`; `problems` is an array of 1 to 3 items; `keywords.top` is an array of exactly 3.
  - The fields shown on lists and pills (title, company, location, work mode, pay text, years required, the top-3 keywords) are `GENERATED ALWAYS AS (...) STORED` columns built from `analysis`, so they can't drift from it. The own label comes from the paste, so it is a plain column.
- **Search:**
  - A `search_vector` column, `GENERATED ALWAYS AS (...) STORED`, built with `setweight(...)` over `to_tsvector` and `jsonb_to_tsvector`, all of which are allowed in generated columns. It uses the `english` text-search configuration, because the first version takes English ads only (PRD). It is weighted:
    - A: title, company and own label
    - B: keywords and problems
    - C: ad content
    - D: the raw ad
  - A GIN index on that column.
  - Feature 2 adds `pg_trgm` GIN indexes on title, company and label, so partial words match as you type.
- **CV versions and usage rows are insert-only, with two guards:**
  - The app role `cvwriter` is granted only `SELECT` and `INSERT` on `cv_versions` and `claude_calls`.
  - A `BEFORE UPDATE OR DELETE` trigger on both tables raises an error, whoever runs the statement.
  - Tests prove an update and a delete are both refused.
- **Money** is stored as whole micro-dollars (`bigint`), never as floating point. The price used for each Claude call is stored on its usage row.
- **Times are `timestamptz`.** "Today" and "this week" (starting Monday) are worked out in the owner's configured timezone, which comes from the environment.
- **Schema changes are migrations kept in the repository** (project rules). The migration tool is chosen in ADR-003.

## Consequences
+ Feature 2's Match section and design 2 add fields to the analysis, not tables to the schema.
+ Search at 250 ads is an index lookup, well inside the 200 ms budget.
+ CV versions and spend records can't be edited by the app, even by a bug.
− Go owns the analysis schema: it needs a test per schema version and a way to read older versions.
− A second database role has to be created on the server, and every migration has to grant the app role exactly what it needs.
− Deleting an ad that has CV versions needs its own decision later (archive, not delete), because versions can't be deleted.
− The database needs a nightly backup. The master key from ADR-001 is backed up separately.

## Revisit when
- Search takes over 200 ms for 95% of searches, or ads pass 10,000.
- A second user is added: add row-level security on `user_id`.
- Three analysis schema versions are live at once: move the older ones forward with a data migration.
- The first non-English ad is to be stored: store a language per ad and pick the text-search configuration per ad, or switch to `simple` for every ad.
