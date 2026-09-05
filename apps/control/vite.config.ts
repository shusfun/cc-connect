import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import tailwindcss from '@tailwindcss/vite';
export default defineConfig({ plugins: [react(), tailwindcss()], build: { outDir: '../../relay/public/app', emptyOutDir: true }, server: { proxy: { '/v1': 'http://127.0.0.1:9820' } } });
