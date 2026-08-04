# EndlessNet public site

This repository owns the public marketing and documentation site source,
runtime configuration contract checks, immutable site artifact publication and
the current GitHub Pages deployment.

- Static site source is stored at the repository root.
- `runtime-config.json` is the deployment configuration source.
- `config.js` is the compatibility adapter loaded by the current static pages.
- `contracts/` contains the pinned runtime configuration schema.
- `contracts/site-publication-v1.md` defines the Front-owned immutable artifact
  and publication contract.
- `.github/workflows/ci.yml` tests, builds, verifies and publishes the exact
  commit-addressed site artifact from `main`.
- `.github/workflows/pages.yml` consumes that verified artifact for the current
  GitHub Pages production path.
- Generated installers under `downloads/` are release artifacts, not backend
  source dependencies.

Run the contract checks with:

```sh
node --test
```
