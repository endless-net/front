import { cp, mkdir, readdir, rm } from "node:fs/promises";
import { join } from "node:path";

const root = process.cwd();
const output = join(root, "dist");
const excluded = new Set([
  ".git",
  ".github",
  ".gitignore",
  "README.md",
  "contracts",
  "dist",
  "scripts",
  "test",
]);

await rm(output, { recursive: true, force: true });
await mkdir(output, { recursive: true });

for (const entry of await readdir(root, { withFileTypes: true })) {
  if (excluded.has(entry.name)) {
    continue;
  }
  await cp(join(root, entry.name), join(output, entry.name), {
    recursive: entry.isDirectory(),
  });
}
