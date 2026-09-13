// mock — node http, no dependencies. Reads PORT; emits x-build-sha (guard 5).
import { createServer } from 'node:http';
import { readFileSync } from 'node:fs';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const meta = JSON.parse(readFileSync(join(here, '..', 'routes.json'), 'utf8'));
const SHA = process.env.BUILD_SHA || 'dev';
const PORT = Number(process.env.PORT || 0);
const BLOCK = process.env.BLOCK || '?';
// Loopback by default; set BIND=0.0.0.0 to reach a block from another host.
const BIND = process.env.BIND || '127.0.0.1';

export function render(path) {
  return { app: meta.app, path, block: BLOCK, sha: SHA, routes: meta.routes };
}

// An HTML view so the estate can be clicked through. JSON stays the contract
// the gates assert on; HTML is only served when the client asks for it.
export const BACKGROUND = '#efeaf7';

export function renderHtml(path) {
  const d = render(path);
  return `<!doctype html><meta charset=utf-8><title>${d.app}</title>
<style>body{background:#efeaf7;font:14px/1.6 system-ui;margin:0;padding:40px}
main{max-width:40rem}code{background:#fff;padding:2px 6px;border-radius:3px}
nav a{margin-right:14px;display:inline-block}h1{margin:0 0 4px}</style>
<main><h1>${d.app}</h1>
<p>path <code>${d.path}</code> · build <code>${d.sha}</code> · block <code>${d.block}</code></p>
<nav><a href="/">core</a><a href="/search">plp</a><a href="/p/SKU1">pdp</a>
<a href="/cart">cart</a><a href="/checkout">checkout</a><a href="/api/catalog">api</a></nav>
</main>`;
}

// Only listen when run directly. Importing this module (as the unit tests do)
// must not bind a port, or the test process never exits.
const isMain = process.argv[1] &&
  import.meta.url === pathToFileURL(process.argv[1]).href;

if (isMain) createServer((req, res) => {
  const wantsHtml = /text\/html/.test(req.headers.accept || '');
  const body = wantsHtml ? renderHtml(req.url)
                         : JSON.stringify(render(req.url), null, 2);
  res.writeHead(200, {
    'content-type': wantsHtml ? 'text/html; charset=utf-8' : 'application/json',
    'x-build-sha': SHA,
    'x-app': meta.app,
    'x-block': BLOCK,
  });
  res.end(body);
}).listen(PORT, BIND, () => {
  console.log(`mock listening on ${PORT} (block ${BLOCK}, sha ${SHA})`);
});
