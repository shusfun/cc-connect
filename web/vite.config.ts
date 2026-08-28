import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import path from 'path'

const apiProxyTarget = process.env.VITE_API_PROXY_TARGET || 'http://localhost:9820'

export default defineConfig({
  plugins: [react()],
  resolve: {
    alias: {
      '@': path.resolve(__dirname, './src'),
    },
  },
  server: {
    port: 9821,
    proxy: {
      '/api': {
        target: apiProxyTarget,
        changeOrigin: false,
        timeout: 45000,
      },
      '/bridge': {
        target: 'http://localhost:9810',
        changeOrigin: true,
        ws: true,
      },
    },
  },
})
