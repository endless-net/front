# Production Pages handoff

`front` is the producer of the public site source and its verified build. It
does not own the production Pages environment and must not deploy it.

The Infrastructure repository is the deployment owner. Its release workflow
must call this repository's `.github/workflows/pages.yml` reusable workflow,
wait for the `test-build` job, download the `public-pages` artifact, and run
the protected production deployment with Infrastructure-owned permissions and
environment approval.

The handoff boundary is the artifact produced by `node scripts/build.mjs`
after `node --test` succeeds. The artifact is built from the exact commit
selected by the Infrastructure workflow; production rollout remains coupled
to the Infrastructure release manifest rather than to a push in this
repository.

Changes to this workflow are input changes only. They must not add
`pages:write`, `id-token:write`, `actions/configure-pages`, or
`actions/deploy-pages` to this repository.
