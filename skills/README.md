# Skills

Portable skills a *different* repository installs to adopt patterns from
here. Not to be confused with `.claude/skills/` at this repo's root, which
operates *this* repo's already-wired pipeline (`release-start`,
`change-request`, and so on) — these are for repos that don't have any of
that yet.

- **[standard-change](standard-change/SKILL.md)** — bootstraps the
  label-driven deploy pattern's base level (three labels, no runner) into a
  repository that doesn't have it. Surveys the target repo's existing
  labels first and refuses to collide with a namespace it already owns.
