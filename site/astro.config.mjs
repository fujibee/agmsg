import { defineConfig } from 'astro/config';
import tailwindcss from '@tailwindcss/vite';

// Prototype site for agmsg.cc (#213). Source lives in site/; future CI builds
// this to the Pages artifact. Does not touch the live docs/.
export default defineConfig({
  site: 'https://agmsg.cc',
  vite: { plugins: [tailwindcss()] },
});
