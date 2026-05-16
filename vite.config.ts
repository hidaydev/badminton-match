import { defineConfig, type Plugin } from 'vite'
import react from '@vitejs/plugin-react'
import tailwindcss from '@tailwindcss/vite'
import { writeFileSync } from 'fs'
import { join } from 'path'

const buildHash = Date.now().toString(36)

function versionPlugin(): Plugin {
  return {
    name: 'version-json',
    writeBundle(options) {
      const outDir = options.dir ?? 'dist'
      writeFileSync(join(outDir, 'version.json'), JSON.stringify({ hash: buildHash }))
    },
  }
}

export default defineConfig({
  plugins: [react(), tailwindcss(), versionPlugin()],
  define: {
    __BUILD_HASH__: JSON.stringify(buildHash),
  },
})
