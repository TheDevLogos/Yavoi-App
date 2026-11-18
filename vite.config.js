import { defineConfig } from 'vite';
import { resolve } from 'node:path';
import { driverReleasePlugin } from './scripts/driver-release-transform.mjs';

const driverBuild = process.env.VITE_YAVOI_APP_TARGET === 'driver';
const root = import.meta.dirname;

export default defineConfig({
  plugins: driverBuild ? [driverReleasePlugin()] : [],
  build: {
    rollupOptions: {
      input: driverBuild
        ? {
            portal: resolve(root, 'portal.html'),
            privacy: resolve(root, 'privacidad.html'),
            terms: resolve(root, 'terminos.html'),
            accountDeletion: resolve(root, 'eliminar-cuenta.html'),
          }
        : {
            landing: resolve(root, 'index.html'),
            portal: resolve(root, 'portal.html'),
            privacy: resolve(root, 'privacidad.html'),
            terms: resolve(root, 'terminos.html'),
            accountDeletion: resolve(root, 'eliminar-cuenta.html'),
          },
    },
  },
});
