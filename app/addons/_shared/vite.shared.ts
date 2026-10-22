import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { defineConfig, type Plugin, type UserConfig } from "vite";

const here = dirname(fileURLToPath(import.meta.url));
const kit = resolve(here, "../../addon-kit/agmsg-addon.js");

/**
 * Shared build setup. Output goes to app-panes/<name>/web/ with relative URLs
 * (the pane is served from a per-pane origin, not from /). The CSP forbids inline
 * scripts, eval and blob workers, so the build is plain ES modules in files, with
 * no inline module preload polyfill.
 */
/**
 * The pane is a sandboxed frame with an opaque origin. A module script is always
 * fetched with CORS, which would need the pane server to send CORS headers; a
 * classic script and a plain stylesheet do not. So build one IIFE bundle and load
 * it with <script defer>, without type="module" or crossorigin.
 */
const classicScript: Plugin = {
  name: "agmsg-classic-script",
  enforce: "post",
  transformIndexHtml: {
    order: "post",
    handler(html, ctx) {
      if (!ctx.bundle) return html; // dev server keeps modules
      return html
        .replace(/<script type="module" crossorigin /g, "<script defer ")
        .replace(/<link rel="stylesheet" crossorigin /g, '<link rel="stylesheet" ');
    },
  },
};

export function makeConfig(root: string, name: string, extra: UserConfig = {}) {
  return defineConfig({
    root,
    base: "./",
    plugins: [classicScript],
    resolve: {
      alias: {
        "agmsg-addon-kit": kit,
      },
    },
    server: { fs: { allow: [resolve(root, ".."), resolve(root, "../../addon-kit")] } },
    build: {
      outDir: resolve(root, `app-panes/${name}/web`),
      emptyOutDir: true,
      target: "es2020",
      modulePreload: { polyfill: false },
      assetsInlineLimit: 0,
      sourcemap: false,
      cssCodeSplit: false,
      rollupOptions: { output: { format: "iife", inlineDynamicImports: true } },
    },
    ...extra,
  });
}
