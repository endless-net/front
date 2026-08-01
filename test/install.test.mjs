import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { pathToFileURL } from "node:url";

const installer = await readFile("install.sh", "utf8");
const installationDocs = await readFile("docs/index.html", "utf8");
const canRunPOSIXShell = process.platform !== "win32";

test("installer defers all installation work until the complete script is parsed", () => {
  assert.match(installer, /\nmain\(\) \{/);
  assert.match(installer, /\nmain "\$@"\s*$/);

  if (!canRunPOSIXShell) {
    return;
  }
  const withoutMainCall = installer.replace(/\nmain "\$@"\s*$/, "\n");
  const result = spawnSync("sh", ["-s", "--", "--help"], {
    input: withoutMainCall,
    encoding: "utf8",
  });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout, "");
});

test("installer uses a secure temporary directory and pinned artifact hashes", () => {
  assert.match(installer, /mktemp -d/);
  assert.doesNotMatch(installer, /endlessnet-install\.\$\$/);
  assert.match(installer, /ENDLESSNET_ARTIFACT_SHA256/);
  assert.match(installer, /verify_sha256 "\$archive" "\$artifact_sha256"/);
  assert.match(installer, /must contain exactly one top-level \$name file/);
  assert.match(installer, /ENDLESSNET_GO_PACKAGE must use an immutable Go module version/);
});

test("installer exposes exact APT versions and a managed keyring package", () => {
  assert.match(installer, /--version VERSION/);
  assert.match(installer, /ENDLESSNET_VERSION/);
  assert.match(installer, /endlessnet-client=\$client_version|\$name=\$client_version/);
  assert.match(installer, /ENDLESSNET_APT_REPO:-https:\/\/apt\.endlessnet\.ru\/apt/);
  assert.match(installer, /ENDLESSNET_APT_KEY_URL:-https:\/\/apt\.endlessnet\.ru\/apt\/unng\.gpg/);
  assert.match(installer, /unng-archive-keyring/);
  assert.match(installer, /debian:12\|debian:13\|ubuntu:22\.04\|ubuntu:24\.04\|ubuntu:26\.04/);
  assert.match(installationDocs, /https:\/\/apt\.endlessnet\.ru\/apt\/unng\.gpg/);
  assert.match(installationDocs, /https:\/\/apt\.endlessnet\.ru\/apt stable main/);
  assert.match(installationDocs, /\/usr\/share\/keyrings\/unng-archive-keyring\.gpg/);
  assert.match(installationDocs, /apt install -y unng-archive-keyring endlessnet-client/);
  assert.match(installationDocs, /Debian 12\/13.*Ubuntu 22\.04\/24\.04\/26\.04 LTS/s);
});

test("download overrides fail before network access when no SHA-256 is pinned", () => {
  if (!canRunPOSIXShell) {
    return;
  }
  const result = spawnSync("sh", ["install.sh", "--no-start"], {
    encoding: "utf8",
    env: {
      ...process.env,
      ENDLESSNET_DOWNLOAD_URL: "https://example.invalid/endlessnet-client",
    },
  });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /ENDLESSNET_ARTIFACT_SHA256 is required/);
});

test("installer help documents version and integrity controls", () => {
  if (!canRunPOSIXShell) {
    return;
  }
  const result = spawnSync("sh", ["install.sh", "--help"], { encoding: "utf8" });
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /--version VERSION/);
  assert.match(result.stdout, /--sha256 HASH/);
});

test("installer has no enrollment or up execution path", () => {
  assert.doesNotMatch(installer, /service enroll/);
  assert.doesNotMatch(installer, /enroll_installed_client/);
  assert.doesNotMatch(installer, /client_up_args/);
  assert.doesNotMatch(installer, /ENDLESSNET_AUTO_UP/);
  assert.doesNotMatch(installer, /--join-token/);
});

test("installer tells the user how to start enrollment explicitly", () => {
  assert.match(installer, /To connect this device to EndlessNet, run:\n  endlessnet up/);
});

test("direct downloads are installed only when their pinned SHA-256 matches", async () => {
  if (!canRunPOSIXShell) {
    return;
  }
  const root = await mkdtemp(join(tmpdir(), "endlessnet-installer-test-"));
  try {
    const artifact = join(root, "client");
    const installDir = join(root, "bin");
    const content = "#!/bin/sh\necho endlessnet-test-client\n";
    await writeFile(artifact, content, { mode: 0o755 });
    const sha256 = createHash("sha256").update(content).digest("hex");
    const baseEnv = {
      ...process.env,
      ENDLESSNET_INSTALL_DIR: installDir,
      ENDLESSNET_DOWNLOAD_URL: pathToFileURL(artifact).href,
    };

    const mismatch = spawnSync("sh", ["install.sh", "--no-start"], {
      encoding: "utf8",
      env: { ...baseEnv, ENDLESSNET_ARTIFACT_SHA256: "0".repeat(64) },
    });
    assert.notEqual(mismatch.status, 0);
    assert.match(mismatch.stderr, /SHA-256 mismatch/);

    const installed = spawnSync("sh", ["install.sh", "--no-start"], {
      encoding: "utf8",
      env: { ...baseEnv, ENDLESSNET_ARTIFACT_SHA256: sha256 },
    });
    assert.equal(installed.status, 0, installed.stderr);
    assert.equal(await readFile(join(installDir, "endlessnet-client"), "utf8"), content);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("normal installation starts the service without invoking the client", async () => {
  if (!canRunPOSIXShell) {
    return;
  }
  const result = spawnSync("sh", ["test/install-posix.test.sh"], { encoding: "utf8" });
  assert.equal(result.status, 0, result.stderr || result.stdout);
});

test("APT installs include the managed keyring and exact requested version", async (t) => {
  if (!canRunPOSIXShell) {
    return;
  }
  const osRelease = await readFile("/etc/os-release", "utf8");
  const id = osRelease.match(/^ID=(?:"([^"]+)"|([^\n]+))$/m)?.slice(1).find(Boolean);
  const version = osRelease.match(/^VERSION_ID=(?:"([^"]+)"|([^\n]+))$/m)?.slice(1).find(Boolean);
  if (!new Set(["debian:12", "debian:13", "ubuntu:22.04", "ubuntu:24.04", "ubuntu:26.04"]).has(`${id}:${version}`)) {
    t.skip(`host release ${id}:${version} is outside the supported installer matrix`);
    return;
  }

  const root = await mkdtemp(join(tmpdir(), "endlessnet-apt-installer-test-"));
  try {
    const commands = join(root, "commands");
    const aptLog = join(root, "apt.log");
    const keyring = join(root, "keyrings", "unng-archive-keyring.gpg");
    const sourceList = join(root, "sources", "unng.list");
    await writeFile(join(root, ".keep"), "");
    await mkdir(commands, { recursive: true });
    await writeFile(join(commands, "id"), "#!/bin/sh\necho 0\n", { mode: 0o755 });
    await writeFile(join(commands, "dpkg"), `#!/bin/sh
case "$1" in
  --print-architecture) echo ${process.arch === "arm64" ? "arm64" : "amd64"} ;;
  --validate-version) exit 0 ;;
  *) exit 1 ;;
esac
`, { mode: 0o755 });
    await writeFile(join(commands, "curl"), `#!/bin/sh
while [ "$#" -gt 0 ]; do
  if [ "$1" = "-o" ]; then
    printf 'test-keyring' > "$2"
    exit 0
  fi
  shift
done
exit 1
`, { mode: 0o755 });
    await writeFile(join(commands, "apt-get"), `#!/bin/sh
printf '%s\n' "$*" >> "$ENDLESSNET_TEST_APT_LOG"
`, { mode: 0o755 });

    const result = spawnSync("sh", ["install.sh", "--no-start", "--version", "1.2.3"], {
      encoding: "utf8",
      env: {
        ...process.env,
        PATH: `${commands}:${process.env.PATH}`,
        ENDLESSNET_APT_REPO: "https://apt.example.test/repository",
        ENDLESSNET_APT_KEY_URL: "https://apt.example.test/unng.gpg",
        ENDLESSNET_APT_KEYRING: keyring,
        ENDLESSNET_APT_SOURCE_LIST: sourceList,
        ENDLESSNET_TEST_APT_LOG: aptLog,
      },
    });
    assert.equal(result.status, 0, result.stderr);
    assert.match(await readFile(aptLog, "utf8"), /install -y wireguard-tools iproute2 unng-archive-keyring endlessnet-client=1\.2\.3/);
    const source = await readFile(sourceList, "utf8");
    assert.ok(source.includes(`signed-by=${keyring}`));
    assert.ok(source.includes("https://apt.example.test/repository"));
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});
