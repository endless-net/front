# Front site publication contract v1

This repository owns the source, tests, build, immutable artifact layout and
publication workflow for the EndlessNet public static site.

## CI and publication identity

- Producer repository: `endless-net/front`.
- CI/publication workflow: `.github/workflows/ci.yml` on `main`.
- Source identity: the full lowercase 40-character Git commit SHA from the
  successful `push` run.
- Actions artifact name: `endlessnet-front-<commit_sha>`.
- Publication is successful only when the exact `main` workflow run completes
  with `success`; uploading the commit-addressed artifact is a required job
  step. Pull requests build and verify the same layout but do not publish it.
- Published Actions artifacts are retained for 30 days. A candidate must be
  deployed before its immutable artifact expires.

The workflow runs `node --test`, builds `dist` with
`node scripts/build.mjs`, creates the package, verifies it independently and
only then uploads it. The package is created by
`scripts/site-artifact.mjs`; production consumers must not rebuild source.

## Immutable package layout

The Actions artifact contains exactly four files:

```text
endlessnet-front-<commit_sha>.tar.gz
endlessnet-front-<commit_sha>.tar.gz.sha256
endlessnet-front-<commit_sha>.manifest.json
endlessnet-front-<commit_sha>.tar.gz.intoto.json
```

The gzip-compressed ustar archive is deterministic for a fixed site tree. It
contains sorted regular files under the single `site/` root, normalized to
mode `0644`, uid/gid `0`, and mtime `0`. Symlinks, special files, duplicate
paths, absolute paths and parent traversal are forbidden. The static site must
contain `404.html`, `config.js`, `index.html`, and `runtime-config.json`.

The SHA-256 sidecar binds the archive filename and bytes. The strict manifest
uses contract `endlessnet-front/site-publication/v1` and binds:

- producer repository, workflow, workflow commit, run ID and run attempt;
- exact source commit;
- Actions artifact name, archive name, archive SHA-256 and `site/` root;
- the sorted path, size and SHA-256 of every archived file;
- the in-toto provenance statement filename, SHA-256 and predicate type.

The in-toto/SLSA v1 provenance statement binds the archive digest to the exact
source commit and producer workflow invocation. The immutable GitHub Actions
artifact and the successful exact publication run are the trust boundary;
Infrastructure must rediscover and verify both from `commit_sha`.

The manifest intentionally contains no deployment target, host, inventory,
operation, deployment credential or artifact URL. Those are not Front-owned
fields.

## Publication consumer and rollout boundary

`.github/workflows/pages.yml` is currently the production publication
consumer. It starts only after a successful CI/publication run for a `main`
push, downloads the commit-addressed artifact from that exact run, verifies
the complete contract, extracts it and deploys the verified tree to GitHub
Pages.

GitHub Pages is the current production path, not proof of an Infrastructure
rollout. Front has no allowlisted Infrastructure target or approved reusable
workflow handoff in the current Infrastructure contract. Until both exist,
the repository must not invent a host/target or pin a mutable Infrastructure
ref.

Once Infrastructure supplies an allowlisted Front entrypoint and an approved
exact commit SHA, the Pages mutation job can be replaced by a whole-job
reusable-workflow caller. That caller may pass only the upstream full
`commit_sha`; it must not pass service, target, operation, artifact URL/digest,
inventory, secrets, or `secrets: inherit`. Basic rollout proof is the
Infrastructure mutating deploy job reaching `completed/success`.
