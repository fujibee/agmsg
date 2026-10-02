import { defineConfig } from 'astro/config';
import tailwindcss from '@tailwindcss/vite';
import { fileURLToPath } from 'node:url';

// Prototype site for agmsg.cc (#213). Source lives in site/; future CI builds
// this to the Pages artifact. Does not touch the live docs/.

// astro.config.mjs is loaded directly by Node (not bundled by Astro's prerender
// step), so import.meta.url here reliably points at site/ regardless of the
// process's invocation cwd. Injected as a build-time constant so components
// (e.g. Home.astro's agent-types gallery) can resolve paths outside src/
// without depending on process.cwd() or a bundler-relocated import.meta.url.
const projectRoot = fileURLToPath(new URL('.', import.meta.url));

export default defineConfig({
  site: 'https://agmsg.cc',
  vite: {
    plugins: [tailwindcss()],
    define: { __PROJECT_ROOT__: JSON.stringify(projectRoot) },
  },
  // English stays unprefixed at "/" (existing URLs/SEO untouched); every other
  // locale is generated under its own "/xx/" prefix by src/pages/[lang]/*.astro.
  i18n: {
    defaultLocale: 'en',
    locales: ['en', 'ja', 'zh-CN', 'zh-TW', 'ko', 'es', 'fr', 'de', 'pt-BR'],
    routing: { prefixDefaultLocale: false },
  },
});
