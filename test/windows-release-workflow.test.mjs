import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

test('Windows release workflow mirrors only verified immutable UI artifacts', async () => {
  const workflow = await readFile('.github/workflows/publish-windows-client.yml', 'utf8');

  for (const marker of [
    'types: [windows-client-ui-published]',
    'CLIENT_UI_RELEASE_TOKEN',
    'immutable MSI conflict',
    'downloads/v$VERSION',
    'downloads/EndlessNet.Client.msi',
    'provenance digest mismatch',
    'event_type:"windows-client-published"',
    'scenario:"installers"',
  ]) {
    assert.match(workflow, new RegExp(marker.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')));
  }
  assert.doesNotMatch(workflow, /workflow_dispatch:/);
});
