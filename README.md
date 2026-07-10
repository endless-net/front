# EndlessNet public site

This repository owns the public marketing and documentation site source,
runtime configuration contract checks and GitHub Pages deployment.

- Static site source is stored at the repository root.
- `runtime-config.json` is the deployment configuration source.
- `config.js` is the compatibility adapter loaded by the current static pages.
- `contracts/` contains the pinned runtime configuration schema.
- Generated installers under `downloads/` are release artifacts, not backend
  source dependencies.

Run the contract checks with:

```sh
node --test
```
