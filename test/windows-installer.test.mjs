import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const installer = await readFile('install.ps1', 'utf8');

test('Windows installer provisions the pinned signed Wintun userspace driver', () => {
  assert.match(installer, /function Install-VerifiedWintun/);
  assert.match(installer, /wintun-\$version\.zip/);
  assert.match(installer, /07c256185d6ee3652e09fa55c0b673e2624b565e02c4b9091c79ca7d2f24ef51/);
  assert.match(installer, /Get-AuthenticodeSignature -LiteralPath \$target/);
  assert.match(installer, /Install-VerifiedWintun -ClientPath \$client/);
  assert.doesNotMatch(installer, /Resolve-WireGuardWindows|--wireguard-windows/);
});
