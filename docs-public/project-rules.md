# Project rules

## Built with

- Back end: Go with chi. Stack file: `docs/rules/stacks/go-chi.md`.
- Front end: React and TypeScript on Vite. Stack file: `docs/rules/stacks/react-vite.md`.
- Database: PostgreSQL. No stack file; this project's own description is in this file.

## Shared rules

- The project has screens and a back end: every section of `docs/rules/` applies.

## Database

- PostgreSQL. The application uses its own non-superuser role.
- Schema changes are migrations kept in the repository.

## Tests

- How the full test suite runs: not decided yet.
