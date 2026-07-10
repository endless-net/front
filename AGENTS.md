# Agents

This repository owns only the EndlessNet public static site.

- Runtime configuration is defined by `runtime-config.json` and the pinned
  schema under `contracts`.
- Generated Pages output is written to `dist` and must not be committed.
- Do not inspect, build or test the EndlessNet Go backend for site-only
  changes.

Required checks:

```sh
node --test
node scripts/build.mjs
```
