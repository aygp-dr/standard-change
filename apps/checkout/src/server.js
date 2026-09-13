// checkout — node http, no dependencies. Reads PORT; emits x-build-sha (guard 5).
import { createServer } from 'node:http';
import { readFileSync } from 'node:fs';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const meta = JSON.parse(readFileSync(join(here, '..', 'routes.json'), 'utf8'));
// OneUI is the shared UI surface (issue #10). Every app pins it, so a change
// there is a change to all of them -- the cost is named in
// docs/cross-cutting-coupling.org, not hidden.
import { page, loadEstate, HOST, VERSION as ONEUI } from '../../../shared/oneui.js';
const ESTATE = loadEstate(join(here, '..', '..', '..', 'router', 'routes.json'), meta);
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
// Issue #8 -- the checkout surface renders pink.
export const BACKGROUND = '#ffd7e6';
// Static copy, so no esc(): nothing in it comes from the request.
export const ASSURANCE = '<p class=g style="margin:14px 0 6px">Your order is not charged until you confirm.</p>';

// `port` is the port this process is ACTUALLY answering on: the caller takes it
// off the accepted socket, not from PORT. shared/oneui.js derives the tier from
// it, and a tier derived from something the deployer exported would be the
// estate reporting what it was told (issue #15).
export function renderHtml(path, port) {
  return page({ ...render(path), host: HOST, port }, ESTATE, BACKGROUND, ASSURANCE);
}

// Only listen when run directly. Importing this module (as the unit tests do)
// must not bind a port, or the test process never exits.
const isMain = process.argv[1] &&
  import.meta.url === pathToFileURL(process.argv[1]).href;

if (isMain) createServer((req, res) => {
  const wantsHtml = /text\/html/.test(req.headers.accept || '');
  const body = wantsHtml ? renderHtml(req.url, req.socket.localPort)
                         : JSON.stringify(render(req.url), null, 2);
  res.writeHead(200, {
    'content-type': wantsHtml ? 'text/html; charset=utf-8' : 'application/json',
    'x-build-sha': SHA,
    'x-app': meta.app,
    'x-block': BLOCK,
  });
  res.end(body);
}).listen(PORT, BIND, () => {
  console.log(`checkout listening on ${PORT} (block ${BLOCK}, sha ${SHA})`);
});
