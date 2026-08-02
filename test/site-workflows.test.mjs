import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

test("CI publishes one commit-addressed Front artifact only from main", async () => {
  const workflow = await readFile(".github/workflows/ci.yml", "utf8");
  assert.match(workflow, /name: Front CI and artifact publication/);
  assert.match(workflow, /pull_request:/);
  assert.match(workflow, /push:\s*\n\s*branches:\s*\n\s*- main/);
  assert.doesNotMatch(workflow, /workflow_dispatch:/);
  assert.match(workflow, /node --test/);
  assert.match(workflow, /node scripts\/build\.mjs/);
  assert.match(workflow, /node scripts\/site-artifact\.mjs create/);
  assert.match(workflow, /node scripts\/site-artifact\.mjs verify/);
  assert.match(workflow, /if: github\.event_name == 'push' && github\.ref == 'refs\/heads\/main'/);
  assert.match(workflow, /name: endlessnet-front-\$\{\{ github\.sha \}\}/);
  assert.match(workflow, /retention-days: 30/);
  assert.doesNotMatch(workflow, /\bsecrets:/);
});

test("Pages deploys only the verified artifact from the successful publication run", async () => {
  const workflow = await readFile(".github/workflows/pages.yml", "utf8");
  assert.match(workflow, /workflow_run:/);
  assert.match(workflow, /- Front CI and artifact publication/);
  assert.match(workflow, /workflow_run\.conclusion == 'success'/);
  assert.match(workflow, /workflow_run\.event == 'push'/);
  assert.match(workflow, /workflow_run\.head_branch == 'main'/);
  assert.match(workflow, /name: endlessnet-front-\$\{\{ github\.event\.workflow_run\.head_sha \}\}/);
  assert.match(workflow, /run-id: \$\{\{ github\.event\.workflow_run\.id \}\}/);
  assert.match(workflow, /node scripts\/site-artifact\.mjs verify/);
  assert.match(workflow, /--extract dist/);
  assert.doesNotMatch(workflow, /node scripts\/build\.mjs/);
  assert.doesNotMatch(workflow, /actions\/upload-artifact/);
  assert.doesNotMatch(workflow, /\bsecrets:/);

  const download = workflow.indexOf("actions/download-artifact");
  const verify = workflow.indexOf("node scripts/site-artifact.mjs verify");
  const pagesUpload = workflow.indexOf("actions/upload-pages-artifact");
  assert.ok(download !== -1 && download < verify && verify < pagesUpload, "download, verification and Pages upload order");
});

test("publication contract reserves deployment authority for Infrastructure", async () => {
  const contract = await readFile("contracts/site-publication-v1.md", "utf8");
  assert.match(contract, /endlessnet-front\/site-publication\/v1/);
  assert.match(contract, /no allowlisted Infrastructure target/);
  assert.match(contract, /pass only the upstream full\s+`commit_sha`/);
  assert.match(contract, /must not pass service, target, operation, artifact URL\/digest,/);
  assert.match(contract, /`completed\/success`/);
});
