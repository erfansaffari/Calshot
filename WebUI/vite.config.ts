import { defineConfig } from 'vite';
export default defineConfig({
  base: './',
  plugins: [{
    name: 'embedded-classic-script',
    transformIndexHtml: { order: 'post', handler: html => html.replace(/ type="module"/g, ' defer').replace(/ crossorigin/g, '') }
  }],
  build: { target: 'safari16', rollupOptions: { output: { format: 'iife', inlineDynamicImports: true, entryFileNames: 'assets/app.js' } } }
});
