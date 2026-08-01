# Agents

## Git workflow

- Work on a short-lived branch and submit every change through a pull request
  targeting `main`. Do not push changes directly to `main`.
- Format every commit message according to Conventional Commits, for example
  `feat: ...`, `fix: ...`, `docs: ...`, or `chore: ...`.

## Repository boundary

- Work only within this repository.
- Before reading from or writing to any path outside this repository, request
  and receive the user's explicit permission.

This repository owns only the EndlessNet public static site.

- Runtime configuration is defined by `runtime-config.json` and the pinned
  schema under `contracts`.
- Generated Pages output is written to `dist` and must not be committed.
- Do not inspect, build or test the EndlessNet Go backend for site-only
  changes.
- Do not preserve obsolete site or installer behavior for backward
  compatibility. The current product contract takes precedence and superseded
  behavior must be removed rather than retained behind a fallback.
- `install.sh` only installs the client and starts its service. It must never
  create, resume, or complete enrollment; enrollment starts only after the user
  explicitly runs `endlessnet up`.

Required checks:

```sh
node --test
node scripts/build.mjs
```

The Windows release mirror uses `CLIENT_UI_RELEASE_TOKEN` with read-only
Contents access only to `unng-lab/endlessnet-client-ui`, and
`SYSTEM_TESTS_DISPATCH_TOKEN` with Contents write access only to
`unng-lab/endlessnet-system-tests`.
