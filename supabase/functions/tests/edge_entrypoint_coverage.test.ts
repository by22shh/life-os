import { assertEquals } from "https://deno.land/std@0.224.0/assert/assert_equals.ts";

Deno.test("edge local e2e references every function entrypoint", async () => {
  const functionsRoot = new URL("../", import.meta.url);
  const e2eSource = await Deno.readTextFile(
    new URL("./edge_local_e2e.ts", import.meta.url),
  );

  const allEntrypoints = await collectEntrypoints(functionsRoot);
  const coveredEntrypoints = Array.from(
    e2eSource.matchAll(/"\.\.\/([^"]+\/index\.ts)"/g),
    (match) => match[1],
  ).sort();

  const coveredSet = new Set(coveredEntrypoints);
  const allSet = new Set(allEntrypoints);

  const missing = allEntrypoints.filter((path) => !coveredSet.has(path));
  const stale = coveredEntrypoints.filter((path) => !allSet.has(path));

  assertEquals(missing, []);
  assertEquals(stale, []);
});

async function collectEntrypoints(root: URL): Promise<string[]> {
  const result: string[] = [];

  async function walk(dir: URL, prefix: string): Promise<void> {
    for await (const entry of Deno.readDir(dir)) {
      if (
        entry.name === "_shared" || entry.name === "tests" ||
        entry.name.startsWith(".")
      ) {
        continue;
      }

      if (entry.isDirectory) {
        await walk(new URL(`${entry.name}/`, dir), `${prefix}${entry.name}/`);
        continue;
      }

      if (entry.isFile && entry.name === "index.ts") {
        result.push(`${prefix}${entry.name}`);
      }
    }
  }

  await walk(root, "");
  return result.sort();
}
