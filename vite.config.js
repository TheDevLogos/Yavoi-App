import {defineConfig} from 'vite';
import {resolve} from 'node:path';
export default defineConfig({build:{rollupOptions:{input:{landing:resolve(import.meta.dirname,'index.html'),portal:resolve(import.meta.dirname,'portal.html'),privacy:resolve(import.meta.dirname,'privacidad.html'),terms:resolve(import.meta.dirname,'terminos.html')}}}});
