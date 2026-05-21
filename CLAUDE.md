# CLAUDE.md

Guidance for AI coding agents working in this repository.

## Repository

ArgoCD app-of-apps catalog. Helm charts grouped under `apps/`, `cicd/`, `config/`,
and `infra/`. Each chart pairs `values.yaml` with a strict `values.schema.json`
(`additionalProperties: false`) — every per-cluster knob is a value, not a patched
manifest.

## Branch naming

Prefix new branches with `feat/` or `fix/` (e.g. `fix/cilium-alpn-h2`). Do not use
other prefixes.

## Commits

Conventional Commits, scoped — e.g. `fix(cilium): ...`, `feat(machinery): ...`,
`chore(deps): ...`.

## Validating changes

CI (`.github/workflows/verify.yaml`) runs `helm template` + lint on each changed
chart, validates `values.yaml` against `values.schema.json`, and runs an ArgoCD
catalog verify. When adding a value, update `values.yaml`, `values.schema.json`,
and the chart README together.
