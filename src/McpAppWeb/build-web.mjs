import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import * as esbuild from 'esbuild';

const here = dirname(fileURLToPath(import.meta.url));
const distDir = resolve(here, 'dist');
mkdirSync(distDir, { recursive: true });

const css = readFileSync(resolve(here, 'src/styles.css'), 'utf8');
const result = await esbuild.build({
  entryPoints: [resolve(here, 'src/main.ts')],
  bundle: true,
  minify: true,
  format: 'iife',
  target: ['es2022'],
  write: false,
  legalComments: 'none',
});

const js = result.outputFiles[0].text.replace(/<\/script>/gi, '<\\/script>');
const safeCss = css.replace(/<\/style>/gi, '<\\/style>');

const html = `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>Antigravity Pilot</title>
  <style>${safeCss}</style>
</head>
<body>
  <div id="app"></div>
  <script>${js}</script>
</body>
</html>
`;

const outPath = resolve(distDir, 'dashboard.html');
writeFileSync(outPath, html, 'utf8');
console.log(`Built ${outPath} (${Buffer.byteLength(html, 'utf8')} bytes)`);
