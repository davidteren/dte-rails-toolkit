# CLAUDE.md

See **[AGENTS.md](./AGENTS.md)**, **[README.md](./README.md)**, and **[STATUS.md](./STATUS.md)** for the
maintainer guide, catalog, and tracker.

Skills live under `skills/<name>/` (each a `SKILL.md` + `references/` + a runnable `scripts/` checker).
These are **deterministic** Rails checkers — flag failures-that-produce-no-error, exit non-zero on findings,
name their ceiling. The hard rule before committing a checker: **verify it both ways** — truthful on a real
app (no false positives; use `miela_app`) AND flags a synthetic break. False positives are the failure mode.
