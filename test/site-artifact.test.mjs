import assert from "node:assert/strict";
import { mkdtemp, readFile, rm, writeFile, mkdir } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import test from "node:test";
import { createSiteArtifact, verifySiteArtifact } from "../scripts/site-artifact.mjs";

const commit = "1".repeat(40);
const workflowCommit = "2".repeat(40);

async function fixture() {
  const root = await mkdtemp(join(tmpdir(), "front-site-artifact-"));
  const site = join(root, "site");
  await mkdir(join(site, "docs"), { recursive: true });
  await Promise.all([
    writeFile(join(site, "404.html"), "not found\n"),
    writeFile(join(site, "config.js"), "globalThis.config = {};\n"),
    writeFile(join(site, "index.html"), "<!doctype html>\n"),
    writeFile(join(site, "runtime-config.json"), "{}\n"),
    writeFile(join(site, "docs", "index.html"), "docs\n"),
  ]);
  return { root, site };
}

test("site artifact is deterministic and verifies before extraction", async (t) => {
  const { root, site } = await fixture();
  t.after(() => rm(root, { recursive: true, force: true }));
  const firstOutput = join(root, "artifact-1");
  const secondOutput = join(root, "artifact-2");
  const options = {
    source: site,
    commit,
    workflowCommit,
    runId: 123,
    runAttempt: 1,
  };
  const first = await createSiteArtifact({ ...options, output: firstOutput });
  const second = await createSiteArtifact({ ...options, output: secondOutput });

  assert.equal(first.artifactName, `endlessnet-front-${commit}`);
  assert.equal(first.archiveDigest, second.archiveDigest);
  assert.deepEqual(await readFile(first.archive), await readFile(second.archive));

  const extracted = join(root, "extracted");
  const verified = await verifySiteArtifact({ artifactDir: firstOutput, commit, extract: extracted });
  assert.equal(verified.manifest.contract, "endlessnet-front/site-publication/v1");
  assert.equal(await readFile(join(extracted, "docs", "index.html"), "utf8"), "docs\n");
});

test("site artifact verification rejects modified archive bytes", async (t) => {
  const { root, site } = await fixture();
  t.after(() => rm(root, { recursive: true, force: true }));
  const output = join(root, "artifact");
  const created = await createSiteArtifact({
    source: site,
    output,
    commit,
    workflowCommit,
    runId: 123,
    runAttempt: 1,
  });
  const archive = await readFile(created.archive);
  archive[Math.floor(archive.length / 2)] ^= 0xff;
  await writeFile(created.archive, archive);

  await assert.rejects(
    verifySiteArtifact({ artifactDir: output, commit }),
    /archive digest mismatch/,
  );
});

test("site artifact creation requires public site entrypoints", async (t) => {
  const { root, site } = await fixture();
  t.after(() => rm(root, { recursive: true, force: true }));
  await rm(join(site, "runtime-config.json"));

  await assert.rejects(
    createSiteArtifact({
      source: site,
      output: join(root, "artifact"),
      commit,
      workflowCommit,
      runId: 123,
      runAttempt: 1,
    }),
    /missing runtime-config\.json/,
  );
});
