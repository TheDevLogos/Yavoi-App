import {defineConfig} from 'vite';
import {resolve} from 'node:path';
export default defineConfig({build:{rollupOptions:{input:{landing:resolve(import.meta.dirname,'index.html'),portal:resolve(import.meta.dirname,'portal.html')}}}});
