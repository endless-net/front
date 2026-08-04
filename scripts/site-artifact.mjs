import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import {
  mkdir,
  readFile,
  readdir,
  rm,
  stat,
  writeFile,
} from "node:fs/promises";
import { gzipSync, gunzipSync } from "node:zlib";
import { dirname, isAbsolute, join, relative, resolve, sep } from "node:path";
import { pathToFileURL } from "node:url";

const blockSize = 512;
const producerRepository = "endless-net/front";
const producerWorkflow = ".github/workflows/ci.yml";
const publicationContract = "endlessnet-front/site-publication/v1";
const buildType = "https://endlessnet.ru/build-types/static-site-archive/v1";
const predicateType = "https://slsa.dev/provenance/v1";
const requiredFiles = ["404.html", "config.js", "index.html", "runtime-config.json"];
const shaPattern = /^[0-9a-f]{40}$/;
const digestPattern = /^sha256:[0-9a-f]{64}$/;

const sha256 = (content) => createHash("sha256").update(content).digest("hex");

function requireSHA(value, label) {
  assert.match(value, shaPattern, `${label} must be a full lowercase commit SHA`);
  assert.notEqual(value, "0".repeat(40), `${label} must not be the zero SHA`);
  return value;
}

function requirePositiveInteger(value, label) {
  const parsed = Number(value);
  assert.ok(Number.isSafeInteger(parsed) && parsed > 0, `${label} must be a positive integer`);
  return parsed;
}

function assertExactKeys(value, expected, label) {
  assert.ok(value && typeof value === "object" && !Array.isArray(value), `${label} must be an object`);
  assert.deepEqual(Object.keys(value).sort(), [...expected].sort(), `${label} keys`);
}

function assertSafeRelativePath(value, label) {
  assert.equal(typeof value, "string", `${label} must be a string`);
  assert.ok(value.length > 0, `${label} must not be empty`);
  assert.equal(value.includes("\\"), false, `${label} must use forward slashes`);
  assert.equal(value.includes("\0"), false, `${label} must not contain NUL`);
  assert.equal(isAbsolute(value), false, `${label} must be relative`);
  const segments = value.split("/");
  assert.ok(segments.every((segment) => segment && segment !== "." && segment !== ".."), `${label} must be normalized`);
}

async function collectFiles(root) {
  const records = [];

  async function walk(directory) {
    const entries = await readdir(directory, { withFileTypes: true });
    entries.sort((left, right) => left.name.localeCompare(right.name, "en"));
    for (const entry of entries) {
      const absolute = join(directory, entry.name);
      if (entry.isSymbolicLink()) {
        throw new Error(`site artifact source must not contain symlinks: ${absolute}`);
      }
      if (entry.isDirectory()) {
        await walk(absolute);
        continue;
      }
      if (!entry.isFile()) {
        throw new Error(`site artifact source contains a non-regular file: ${absolute}`);
      }
      const path = relative(root, absolute).split(sep).join("/");
      assertSafeRelativePath(path, "site file path");
      const content = await readFile(absolute);
      records.push({ path, size: content.length, sha256: sha256(content), content });
    }
  }

  await walk(root);
  records.sort((left, right) => left.path.localeCompare(right.path, "en"));
  for (const required of requiredFiles) {
    assert.ok(records.some(({ path }) => path === required), `site artifact is missing ${required}`);
  }
  return records;
}

function writeString(buffer, offset, length, value, label) {
  const encoded = Buffer.from(value, "utf8");
  assert.ok(encoded.length <= length, `${label} does not fit in the tar header`);
  encoded.copy(buffer, offset);
}

function writeOctal(buffer, offset, length, value, label) {
  const encoded = value.toString(8).padStart(length - 1, "0");
  assert.ok(encoded.length < length, `${label} does not fit in the tar header`);
  writeString(buffer, offset, length, `${encoded}\0`, label);
}

function tarHeader(path, size) {
  const header = Buffer.alloc(blockSize);
  writeString(header, 0, 100, path, "archive path");
  writeOctal(header, 100, 8, 0o644, "file mode");
  writeOctal(header, 108, 8, 0, "uid");
  writeOctal(header, 116, 8, 0, "gid");
  writeOctal(header, 124, 12, size, "file size");
  writeOctal(header, 136, 12, 0, "mtime");
  header.fill(0x20, 148, 156);
  header[156] = "0".charCodeAt(0);
  writeString(header, 257, 6, "ustar\0", "tar magic");
  writeString(header, 263, 2, "00", "tar version");
  const checksum = header.reduce((sum, byte) => sum + byte, 0);
  const encodedChecksum = checksum.toString(8).padStart(6, "0");
  writeString(header, 148, 8, `${encodedChecksum}\0 `, "tar checksum");
  return header;
}

function createArchive(files) {
  const chunks = [];
  for (const file of files) {
    const archivePath = `site/${file.path}`;
    assert.ok(Buffer.byteLength(archivePath, "utf8") <= 100, `archive path is longer than 100 bytes: ${archivePath}`);
    chunks.push(tarHeader(archivePath, file.content.length), file.content);
    const padding = (blockSize - (file.content.length % blockSize)) % blockSize;
    if (padding) {
      chunks.push(Buffer.alloc(padding));
    }
  }
  chunks.push(Buffer.alloc(blockSize * 2));
  return gzipSync(Buffer.concat(chunks), { level: 9, mtime: 0 });
}

function parseTarString(header, offset, length) {
  const field = header.subarray(offset, offset + length);
  const end = field.indexOf(0);
  return field.subarray(0, end === -1 ? field.length : end).toString("utf8");
}

function parseTarOctal(header, offset, length, label) {
  const value = parseTarString(header, offset, length).trim();
  assert.match(value, /^[0-7]+$/, `${label} must be octal`);
  return Number.parseInt(value, 8);
}

function parseArchive(archive) {
  const tar = gunzipSync(archive);
  assert.equal(tar.length % blockSize, 0, "tar length must be block aligned");
  const files = [];
  const seen = new Set();
  let offset = 0;
  let endBlocks = 0;

  while (offset < tar.length) {
    const header = tar.subarray(offset, offset + blockSize);
    assert.equal(header.length, blockSize, "tar header is truncated");
    offset += blockSize;
    if (header.every((byte) => byte === 0)) {
      endBlocks += 1;
      continue;
    }
    assert.equal(endBlocks, 0, "tar contains data after its end marker");
    assert.equal(parseTarString(header, 257, 6), "ustar", "tar format");
    const expectedChecksum = parseTarOctal(header, 148, 8, "tar checksum");
    const checksumHeader = Buffer.from(header);
    checksumHeader.fill(0x20, 148, 156);
    assert.equal(checksumHeader.reduce((sum, byte) => sum + byte, 0), expectedChecksum, "tar header checksum");
    const type = String.fromCharCode(header[156]);
    assert.ok(type === "0" || header[156] === 0, "archive may contain only regular files");
    const archivePath = parseTarString(header, 0, 100);
    assert.ok(archivePath.startsWith("site/"), "archive entry must use the site/ root");
    const path = archivePath.slice("site/".length);
    assertSafeRelativePath(path, "archive entry path");
    assert.equal(seen.has(path), false, `duplicate archive entry: ${path}`);
    seen.add(path);
    const size = parseTarOctal(header, 124, 12, "tar file size");
    assert.ok(Number.isSafeInteger(size) && size >= 0, "tar file size must be safe");
    assert.ok(offset + size <= tar.length, `archive entry is truncated: ${path}`);
    const content = tar.subarray(offset, offset + size);
    files.push({ path, size, sha256: sha256(content), content });
    offset += Math.ceil(size / blockSize) * blockSize;
  }

  assert.ok(endBlocks >= 2, "tar must end with two zero blocks");
  return files;
}

function provenanceFor({ archiveName, archiveSHA256, commit, workflowCommit, runId, runAttempt }) {
  return {
    _type: "https://in-toto.io/Statement/v1",
    subject: [{ name: archiveName, digest: { sha256: archiveSHA256 } }],
    predicateType,
    predicate: {
      buildDefinition: {
        buildType,
        externalParameters: { commit_sha: commit },
        internalParameters: {
          producer_repository: producerRepository,
          producer_workflow: producerWorkflow,
          producer_run_id: runId,
          producer_run_attempt: runAttempt,
          workflow_commit: workflowCommit,
        },
        resolvedDependencies: [{
          uri: `git+https://github.com/${producerRepository}`,
          digest: { gitCommit: commit },
        }],
      },
      runDetails: {
        builder: {
          id: `https://github.com/${producerRepository}/${producerWorkflow}@${workflowCommit}`,
        },
        metadata: {
          invocationId: `https://github.com/${producerRepository}/actions/runs/${runId}/attempts/${runAttempt}`,
        },
      },
    },
  };
}

export async function createSiteArtifact({
  source,
  output,
  commit,
  workflowCommit,
  runId,
  runAttempt,
}) {
  commit = requireSHA(commit, "source commit");
  workflowCommit = requireSHA(workflowCommit, "workflow commit");
  runId = requirePositiveInteger(runId, "producer run ID");
  runAttempt = requirePositiveInteger(runAttempt, "producer run attempt");
  source = resolve(source);
  output = resolve(output);
  assert.ok((await stat(source)).isDirectory(), "site artifact source must be a directory");
  const files = await collectFiles(source);
  const artifactName = `endlessnet-front-${commit}`;
  const archiveName = `${artifactName}.tar.gz`;
  const manifestName = `${artifactName}.manifest.json`;
  const provenanceName = `${archiveName}.intoto.json`;
  const checksumName = `${archiveName}.sha256`;
  const archive = createArchive(files);
  const archiveSHA256 = sha256(archive);
  const provenance = provenanceFor({
    archiveName,
    archiveSHA256,
    commit,
    workflowCommit,
    runId,
    runAttempt,
  });
  const provenanceContent = `${JSON.stringify(provenance, null, 2)}\n`;
  const manifest = {
    schema_version: 1,
    contract: publicationContract,
    producer: {
      repository: producerRepository,
      workflow: producerWorkflow,
      workflow_commit: workflowCommit,
      run_id: runId,
      run_attempt: runAttempt,
    },
    source: { commit },
    artifact: {
      name: artifactName,
      archive: archiveName,
      digest: `sha256:${archiveSHA256}`,
      media_type: "application/gzip",
      root: "site/",
      files: files.map(({ path, size, sha256 }) => ({ path, size, sha256 })),
    },
    provenance: {
      statement: provenanceName,
      digest: `sha256:${sha256(provenanceContent)}`,
      predicate_type: predicateType,
    },
  };

  await rm(output, { recursive: true, force: true });
  await mkdir(output, { recursive: true });
  await Promise.all([
    writeFile(join(output, archiveName), archive),
    writeFile(join(output, checksumName), `${archiveSHA256}  ${archiveName}\n`),
    writeFile(join(output, manifestName), `${JSON.stringify(manifest, null, 2)}\n`),
    writeFile(join(output, provenanceName), provenanceContent),
  ]);

  return {
    artifactName,
    archive: join(output, archiveName),
    archiveDigest: `sha256:${archiveSHA256}`,
    checksum: join(output, checksumName),
    manifest: join(output, manifestName),
    provenance: join(output, provenanceName),
  };
}

function verifyManifest(manifest, commit) {
  assertExactKeys(manifest, ["schema_version", "contract", "producer", "source", "artifact", "provenance"], "manifest");
  assert.equal(manifest.schema_version, 1, "manifest schema version");
  assert.equal(manifest.contract, publicationContract, "manifest contract");
  assertExactKeys(manifest.producer, ["repository", "workflow", "workflow_commit", "run_id", "run_attempt"], "manifest producer");
  assert.equal(manifest.producer.repository, producerRepository, "producer repository");
  assert.equal(manifest.producer.workflow, producerWorkflow, "producer workflow");
  requireSHA(manifest.producer.workflow_commit, "manifest workflow commit");
  requirePositiveInteger(manifest.producer.run_id, "manifest run ID");
  requirePositiveInteger(manifest.producer.run_attempt, "manifest run attempt");
  assertExactKeys(manifest.source, ["commit"], "manifest source");
  assert.equal(manifest.source.commit, commit, "manifest source commit");
  assertExactKeys(manifest.artifact, ["name", "archive", "digest", "media_type", "root", "files"], "manifest artifact");
  assert.equal(manifest.artifact.name, `endlessnet-front-${commit}`, "artifact name");
  assert.equal(manifest.artifact.archive, `${manifest.artifact.name}.tar.gz`, "archive name");
  assert.match(manifest.artifact.digest, digestPattern, "archive digest");
  assert.equal(manifest.artifact.media_type, "application/gzip", "archive media type");
  assert.equal(manifest.artifact.root, "site/", "archive root");
  assert.ok(Array.isArray(manifest.artifact.files) && manifest.artifact.files.length > 0, "manifest files");
  assertExactKeys(manifest.provenance, ["statement", "digest", "predicate_type"], "manifest provenance");
  assert.equal(manifest.provenance.statement, `${manifest.artifact.archive}.intoto.json`, "provenance statement name");
  assert.match(manifest.provenance.digest, digestPattern, "provenance digest");
  assert.equal(manifest.provenance.predicate_type, predicateType, "provenance predicate type");
}

function verifyProvenance(provenance, manifest) {
  assertExactKeys(provenance, ["_type", "subject", "predicateType", "predicate"], "provenance");
  assert.equal(provenance._type, "https://in-toto.io/Statement/v1", "provenance statement type");
  assert.equal(provenance.predicateType, predicateType, "provenance predicate type");
  assert.deepEqual(provenance.subject, [{
    name: manifest.artifact.archive,
    digest: { sha256: manifest.artifact.digest.slice("sha256:".length) },
  }], "provenance subject");
  const definition = provenance.predicate?.buildDefinition;
  assert.equal(definition?.buildType, buildType, "provenance build type");
  assert.deepEqual(definition?.externalParameters, { commit_sha: manifest.source.commit }, "provenance external parameters");
  assert.deepEqual(definition?.resolvedDependencies, [{
    uri: `git+https://github.com/${producerRepository}`,
    digest: { gitCommit: manifest.source.commit },
  }], "provenance source dependency");
  assert.deepEqual(definition?.internalParameters, {
    producer_repository: producerRepository,
    producer_workflow: producerWorkflow,
    producer_run_id: manifest.producer.run_id,
    producer_run_attempt: manifest.producer.run_attempt,
    workflow_commit: manifest.producer.workflow_commit,
  }, "provenance producer identity");
}

export async function verifySiteArtifact({ artifactDir, commit, extract }) {
  commit = requireSHA(commit, "source commit");
  artifactDir = resolve(artifactDir);
  const artifactName = `endlessnet-front-${commit}`;
  const archiveName = `${artifactName}.tar.gz`;
  const manifestName = `${artifactName}.manifest.json`;
  const provenanceName = `${archiveName}.intoto.json`;
  const checksumName = `${archiveName}.sha256`;
  const actualNames = (await readdir(artifactDir)).sort();
  assert.deepEqual(actualNames, [archiveName, checksumName, manifestName, provenanceName].sort(), "artifact package files");

  const archive = await readFile(join(artifactDir, archiveName));
  const checksum = await readFile(join(artifactDir, checksumName), "utf8");
  const manifest = JSON.parse(await readFile(join(artifactDir, manifestName), "utf8"));
  const provenanceContent = await readFile(join(artifactDir, provenanceName), "utf8");
  const provenance = JSON.parse(provenanceContent);
  verifyManifest(manifest, commit);
  const archiveSHA256 = sha256(archive);
  assert.equal(manifest.artifact.digest, `sha256:${archiveSHA256}`, "archive digest mismatch");
  assert.equal(checksum, `${archiveSHA256}  ${archiveName}\n`, "archive checksum sidecar");
  assert.equal(manifest.provenance.digest, `sha256:${sha256(provenanceContent)}`, "provenance digest mismatch");
  verifyProvenance(provenance, manifest);

  const archivedFiles = parseArchive(archive);
  const recordedFiles = manifest.artifact.files;
  assert.deepEqual(archivedFiles.map(({ path, size, sha256 }) => ({ path, size, sha256 })), recordedFiles, "archive content manifest");
  for (const required of requiredFiles) {
    assert.ok(archivedFiles.some(({ path }) => path === required), `archive is missing ${required}`);
  }

  if (extract) {
    const extractionRoot = resolve(extract);
    await rm(extractionRoot, { recursive: true, force: true });
    await mkdir(extractionRoot, { recursive: true });
    for (const file of archivedFiles) {
      const destination = resolve(extractionRoot, ...file.path.split("/"));
      assert.ok(destination.startsWith(`${extractionRoot}${sep}`), `archive path escapes extraction root: ${file.path}`);
      await mkdir(dirname(destination), { recursive: true });
      await writeFile(destination, file.content, { mode: 0o644 });
    }
  }

  return { artifactName, manifest };
}

function parseArguments(argv) {
  const values = {};
  for (let index = 0; index < argv.length; index += 2) {
    const key = argv[index];
    const value = argv[index + 1];
    assert.ok(key?.startsWith("--") && value !== undefined, `invalid argument list near ${key ?? "end"}`);
    values[key.slice(2)] = value;
  }
  return values;
}

async function appendGitHubOutputs(values) {
  if (!process.env.GITHUB_OUTPUT) {
    return;
  }
  const content = Object.entries(values).map(([key, value]) => `${key}=${value}\n`).join("");
  const previous = await readFile(process.env.GITHUB_OUTPUT, "utf8").catch(() => "");
  await writeFile(process.env.GITHUB_OUTPUT, `${previous}${content}`);
}

async function main() {
  const [command, ...argv] = process.argv.slice(2);
  const args = parseArguments(argv);
  if (command === "create") {
    const result = await createSiteArtifact({
      source: args.source,
      output: args.output,
      commit: args.commit,
      workflowCommit: args["workflow-commit"],
      runId: args["run-id"],
      runAttempt: args["run-attempt"],
    });
    await appendGitHubOutputs({
      artifact_name: result.artifactName,
      archive: result.archive,
      archive_digest: result.archiveDigest,
      checksum: result.checksum,
      manifest: result.manifest,
      provenance: result.provenance,
    });
    return;
  }
  if (command === "verify") {
    await verifySiteArtifact({
      artifactDir: args["artifact-dir"],
      commit: args.commit,
      extract: args.extract,
    });
    return;
  }
  throw new Error("usage: site-artifact.mjs <create|verify> [options]");
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  await main();
}
