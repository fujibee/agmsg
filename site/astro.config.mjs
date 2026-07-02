import { defineConfig } from 'astro/config';
import tailwindcss from '@tailwindcss/vite';

// Prototype site for agmsg.cc (#213). Source lives in site/; future CI builds
// this to the Pages artifact. Does not touch the live docs/.
export default defineConfig({
  site: 'https://agmsg.cc',
  vite: { plugins: [tailwindcss()] },
  // English stays unprefixed at "/" (existing URLs/SEO untouched); every other
  // locale is generated under its own "/xx/" prefix by src/pages/[lang]/*.astro.
  i18n: {
    defaultLocale: 'en',
    locales: ['en', 'ja', 'zh-CN', 'zh-TW', 'ko', 'es', 'fr', 'de', 'pt-BR'],
    routing: { prefixDefaultLocale: false },
  },
});
