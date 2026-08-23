import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

test('Pages workflow is an Infrastructure-owned build handoff', async () => {
  const workflow = await readFile('.github/workflows/pages.yml', 'utf8');

  for (const marker of [
    'name: Build public Pages artifact',
    'workflow_call:',
    'node --test',
    'node scripts/build.mjs',
    'name: public-pages',
  ]) {
    assert.match(workflow, new RegExp(marker.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')));
  }

  assert.doesNotMatch(workflow, /pages:\s*write/);
  assert.doesNotMatch(workflow, /id-token:\s*write/);
  assert.doesNotMatch(workflow, /actions\/(?:configure-pages|deploy-pages)/);
  assert.doesNotMatch(workflow, /push:\s*\n\s+branches:/);
});
