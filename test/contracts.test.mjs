import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import test from "node:test";

const readJSON = async (path) => JSON.parse(await readFile(path, "utf8"));

test("pinned contract checksums match the producer release", async () => {
  const lock = await readJSON("contracts/contracts.lock.json");
  assert.equal(lock.contract_version, "3.0.0");
  for (const [name, expected] of Object.entries(lock.files)) {
    const content = (await readFile(`contracts/${name}`, "utf8")).replace(/\r\n/g, "\n");
    const actual = createHash("sha256").update(content).digest("hex");
    assert.equal(actual, expected, `${name} checksum`);
  }
});

test("runtime configuration satisfies the pinned frontend schema", async () => {
  const schema = await readJSON("contracts/frontend-runtime-config.schema.json");
  const config = await readJSON("runtime-config.json");

  assert.equal(schema.$schema, "https://json-schema.org/draft/2020-12/schema");
  assert.equal(schema.additionalProperties, false);

  const allowed = new Set(Object.keys(schema.properties));
  for (const key of Object.keys(config)) {
    assert.ok(allowed.has(key), `unknown runtime configuration property: ${key}`);
  }
  for (const required of schema.required) {
    assert.ok(Object.hasOwn(config, required), `missing runtime configuration property: ${required}`);
  }
  assert.equal(config.schema_version, schema.properties.schema_version.const);
  for (const key of ["control_plane_url", "site_url", "admin_url"]) {
    const value = new URL(config[key]);
    assert.equal(value.protocol, "https:", `${key} must use HTTPS`);
  }

  const generatedAdapter = await readFile("config.js", "utf8");
  assert.match(generatedAdapter, new RegExp(`ENDLESSNET_CONTROL_PLANE_URL\\s*=\\s*${JSON.stringify(config.control_plane_url)}`));
  assert.match(generatedAdapter, new RegExp(`ENDLESSNET_MANAGEMENT_API_BASE_PATH\\s*=\\s*${JSON.stringify(config.management_api_base_path)}`));
  assert.match(generatedAdapter, new RegExp(`ENDLESSNET_ADMIN_URL\\s*=\\s*${JSON.stringify(config.admin_url)}`));
  assert.match(generatedAdapter, new RegExp(`ENDLESSNET_SITE_ROOT\\s*=\\s*${JSON.stringify(config.site_url)}`));
});

test("published HTML loads the validated configuration adapter", async () => {
  for (const path of ["index.html", "docs/index.html"]) {
    const html = await readFile(path, "utf8");
    assert.match(html, /config\.js/);
  }
});
