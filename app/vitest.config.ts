import { defineConfig } from "vitest/config";

// Separate from vite.config.ts (which is tuned for Tauri dev/build — fixed
// port, ignored src-tauri watch, TAURI_DEV_HOST). Tests here are plain TS
// logic (paneTree.ts) with no DOM/React dependency, so no jsdom environment
// or react plugin is needed.
export default defineConfig({
  test: {
    include: ["src/**/*.test.ts"],
  },
});
