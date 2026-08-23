# EndlessNet public site

This repository owns the public marketing and documentation site source,
runtime configuration contract checks and the tested public Pages artifact.

Production deployment is owned by Infrastructure. This repository does not
grant Pages deployment permissions or mutate the production Pages environment.
Infrastructure must call `.github/workflows/pages.yml` as a reusable workflow,
consume its `public-pages` artifact, and perform the protected deployment from
the Infrastructure repository.

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
