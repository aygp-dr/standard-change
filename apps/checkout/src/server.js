// checkout — node http, no dependencies. Reads PORT; emits x-build-sha (guard 5).
import { createServer } from 'node:http';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const meta = JSON.parse(readFileSync(join(here, '..', 'routes.json'), 'utf8'));
const SHA = process.env.BUILD_SHA || 'dev';
const PORT = Number(process.env.PORT || 0);
const BLOCK = process.env.BLOCK || '?';

export function render(path) {
  return { app: meta.app, path, block: BLOCK, sha: SHA, routes: meta.routes };
}

createServer((req, res) => {
  const body = JSON.stringify(render(req.url), null, 2);
  res.writeHead(200, {
    'content-type': 'application/json',
    'x-build-sha': SHA,
    'x-app': meta.app,
    'x-block': BLOCK,
  });
  res.end(body);
}).listen(PORT, '127.0.0.1', () => {
  console.log(`checkout listening on ${PORT} (block ${BLOCK}, sha ${SHA})`);
});
