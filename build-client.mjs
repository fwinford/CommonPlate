// build-client.mjs
// Build script for client-side TypeScript

import * as esbuild from 'esbuild';
import { existsSync, mkdirSync } from 'fs';

const outdir = './public/js';

// Ensure output directory exists
if (!existsSync(outdir)) {
  mkdirSync(outdir, { recursive: true });
}

const isDev = process.env.NODE_ENV !== 'production';

// Build client scripts
await esbuild.build({
  entryPoints: [
    'src/client/home.ts',
    'src/client/new-request.ts',
    'src/client/fulfill.ts'
  ],
  bundle: true,
  outdir,
  format: 'esm',
  target: 'es2022',
  sourcemap: isDev, // Only generate sourcemaps in development
  minify: !isDev,
});

console.log(`Client scripts built successfully${isDev ? ' (with sourcemaps)' : ''}`);
