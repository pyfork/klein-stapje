# Shared patterns

<!-- kit-keeper-Opus5.5-agent, 2026-10-13. Template for specs/patterns.md,
     created by the scaffold (README-SCAFFOLD-NEW-PROJECT.md, Step 3). The UX
     designer owns it (docs/agents/ux-designer.md, "The shared pattern list"):
     one entry per pattern, written once; a slice's screen rules point at a
     pattern instead of restating it. Delete entries that don't apply to this
     project's stack; remove this comment once the first real entry lands. -->

PATTERN: Command-line error
RULE:    One line on standard error per problem: `<command>: ` then what
         happened, then what to do, under 80 characters. A usage line may
         follow. Nothing on standard output. Exit 2 for a usage error
         (wrong arguments), 1 for input that can't be used. Never echo the
         input back (it can be long or hold control bytes). No colour codes.
WHY:     Scripts capture standard output, so errors never mix with results;
         the exit code tells a caller which mistake was made.
USED BY: (the screens or commands that point here)
EXCEPTIONS: none
