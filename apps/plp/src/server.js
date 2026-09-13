// plp — node http, no dependencies. Reads PORT; emits x-build-sha (guard 5).
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
export const BACKGROUND = '#e6f7ee';

export function renderHtml(path) {
  const d = render(path);
  return `<!doctype html><meta charset=utf-8><title>${d.app}</title>
<style>body{background:#e6f7ee;font:14px/1.6 system-ui;margin:0;padding:40px}
main{max-width:40rem}code{background:#fff;padding:2px 6px;border-radius:3px}
a{margin-right:10px;display:inline-block}h1{margin:0 0 4px}
.g{margin:2px 0;font-size:13px}.g b{display:inline-block;width:5.5rem;color:#555}</style>
<main><h1>${d.app}</h1>
<p>served by <b>${d.app}</b> · path <code>${d.path}</code> · build <code>${d.sha}</code> · block <code>${d.block}</code></p>
<p class=g style="color:#666;margin:14px 0 6px">every route, by the app that owns it — a link that changes the name above crossed to a sibling app:</p>
<div class=g><b>${d.app === "core" ? "▸ " : ""}core</b> <a href="/">/</a> <a href="/login">/login</a> <a href="/account">/account</a> <a href="/cart">/cart</a></div>
<div class=g><b>${d.app === "plp" ? "▸ " : ""}plp</b> <a href="/search">/search</a> <a href="/c/shoes">/c/shoes</a></div>
<div class=g><b>${d.app === "pdp" ? "▸ " : ""}pdp</b> <a href="/p/SKU1">/p/SKU1</a></div>
<div class=g><b>${d.app === "checkout" ? "▸ " : ""}checkout</b> <a href="/checkout">/checkout</a> <a href="/checkout/payment">/checkout/payment</a> <a href="/checkout/confirm">/checkout/confirm</a></div>
<div class=g><b>${d.app === "mock" ? "▸ " : ""}mock</b> <a href="/api/catalog">/api/catalog</a> <a href="/api/cart">/api/cart</a></div>
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
  console.log(`plp listening on ${PORT} (block ${BLOCK}, sha ${SHA})`);
});
