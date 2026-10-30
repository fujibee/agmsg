// Copy a build output directory into app-panes/<name>/web/ for an agmsg app add-on.
//   node scripts/agmsg-addon-copy.mjs <build-dir> <name>
// Replaces web/ entirely, refuses symbolic links, and keeps only plain files,
// because that is all the app installs.
import { cpSync, existsSync, lstatSync, readdirSync, rmSync } from "node:fs";
import { join, resolve } from "node:path";

const [buildDir, name] = process.argv.slice(2);
if (!buildDir || !name || !/^[a-z0-9][a-z0-9-]{0,63}$/.test(name)) {
  console.error("usage: node scripts/agmsg-addon-copy.mjs <build-dir> <name>");
  process.exit(2);
}
const src = resolve(buildDir);
const dest = resolve("app-panes", name, "web");
if (!existsSync(src)) {
  console.error(`no build output at ${src}; run your build first`);
  process.exit(1);
}
if (!existsSync(resolve("app-panes", name, "addon.conf"))) {
  console.error(`app-panes/${name}/addon.conf is missing; create it first (see the sample add-on)`);
  process.exit(1);
}

let count = 0;
(function walk(dir) {
  for (const entry of readdirSync(dir)) {
    const p = join(dir, entry);
    const st = lstatSync(p);
    if (st.isSymbolicLink()) {
      console.error(`refused: ${p} is a symbolic link; add-ons may contain only plain files`);
      process.exit(1);
    }
    if (st.isDirectory()) walk(p);
    else if (st.isFile()) count++;
  }
})(src);

rmSync(dest, { recursive: true, force: true });
cpSync(src, dest, { recursive: true });
console.log(`copied ${count} files to app-panes/${name}/web/ — commit them, then run \`node scripts/agmsg-addon-check.cjs\``);
