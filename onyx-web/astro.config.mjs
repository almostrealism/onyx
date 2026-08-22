// @ts-check
import { defineConfig } from 'astro/config';
import tailwindcss from '@tailwindcss/vite';

export default defineConfig({
  trailingSlash: 'never',
  vite: {
    plugins: [tailwindcss()],
    server: {
      host: '0.0.0.0',
      port: 4322,
      allowedHosts: ['mac-studio'],
    },
  },
  server: { host: '0.0.0.0', port: 4322 },
});
