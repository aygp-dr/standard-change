// core — node http, no dependencies. Reads PORT; emits x-build-sha (guard 5).
import { createServer } from 'node:http';
import { readFileSync, existsSync, statSync, readdirSync } from 'node:fs';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const meta = JSON.parse(readFileSync(join(here, '..', 'routes.json'), 'utf8'));
// OneUI is the shared UI surface (issue #10). Every app pins it, so a change
// there is a change to all of them -- the cost is named in
// docs/cross-cutting-coupling.org, not hidden.
import { page, loadEstate, esc, VERSION as ONEUI } from '../../../shared/oneui.js';
const ESTATE = loadEstate(join(here, '..', '..', '..', 'router', 'routes.json'), meta);
const SHA = process.env.BUILD_SHA || 'dev';
const PORT = Number(process.env.PORT || 0);
const BLOCK = process.env.BLOCK || '?';
// Loopback by default; set BIND=0.0.0.0 to reach a block from another host.
const BIND = process.env.BIND || '127.0.0.1';

// core is the router's default location (routes.json: fallthrough). Every
// path nobody else claims arrives here, so core -- not the router -- is what
// decides a path does not exist. That is the nginx shape
// (location / { proxy_pass core }), and it puts core on the path of every
// request in the estate: see docs/adr/0001-automatic-promotion.org.
const STATICS = join(here, 'statics');
const STATIC_PREFIX = '/statics/';
const TYPES = { '.css': 'text/css', '.txt': 'text/plain', '.json': 'application/json',
                '.svg': 'image/svg+xml', '.js': 'text/javascript' };

// try_files $uri =404, scoped to the statics directory. Resolve first, then
// check containment: a path is served only if it really lands inside STATICS,
// so ../ in the URL cannot walk out of it.
export function staticFile(path) {
  const rel = decodeURIComponent(path.split('?')[0])
    .replace(/^\/statics\//, '').replace(/^\//, '');
  if (!rel) return null;
  const file = join(STATICS, rel);
  if (!file.startsWith(STATICS + '/')) return null;
  if (!existsSync(file) || !statSync(file).isFile()) return null;
  return { file, type: TYPES[file.slice(file.lastIndexOf('.'))] || 'application/octet-stream' };
}

// Which paths core answers for -- everything else is a 404 core owns.
//
// /statics/ is declared in routes.json so the ROUTER knows where to send these,
// but under it the FILE decides, not the prefix. Matching on the prefix alone
// made /statics/anything return 200: the default-location failure mode in
// miniature, where being the app that catches everything turns into claiming
// everything. The e2e gate now asserts both halves.
export function owns(path) {
  const p = path.split('?')[0];
  if (p === STATIC_PREFIX) return true;                       // the index
  if (p.startsWith(STATIC_PREFIX)) return staticFile(p) !== null;
  if (meta.routes.some((r) => (r === '/' ? p === '/' : p.startsWith(r)))) return true;
  return staticFile(p) !== null;
}

// What the statics index reports. nginx autoindex, as data.
export function assets() {
  return readdirSync(STATICS).sort();
}

export function render(path) {
  const d = { app: meta.app, path, found: owns(path), block: BLOCK, sha: SHA, routes: meta.routes };
  if (path.split('?')[0] === STATIC_PREFIX) d.assets = assets();
  return d;
}

// An HTML view so the estate can be clicked through. JSON stays the contract
// the gates assert on; HTML is only served when the client asks for it.
export const BACKGROUND = '#e8f0ff';

export function renderHtml(path) {
  return page(render(path), ESTATE, BACKGROUND, owns(path) ? '' : `<h2>We can't find that page</h2><p>Nothing is published at <code>${esc(path)}</code> — the link may be out of date, or the item may have sold out. Try the <a href="/">home page</a>, your <a href="/cart">cart</a>, or <a href="/contact">contact us</a> and we will help you find it.</p>`);
}

// Only listen when run directly. Importing this module (as the unit tests do)
// must not bind a port, or the test process never exits.
const isMain = process.argv[1] &&
  import.meta.url === pathToFileURL(process.argv[1]).href;

if (isMain) createServer((req, res) => {
  const asset = staticFile(req.url);
  if (asset) {
    res.writeHead(200, { 'content-type': asset.type, 'x-build-sha': SHA,
                         'x-app': meta.app, 'x-block': BLOCK });
    return res.end(readFileSync(asset.file));
  }
  const d = render(req.url);
  const wantsHtml = /text\/html/.test(req.headers.accept || '');
  const body = wantsHtml ? renderHtml(req.url)
                         : JSON.stringify(d, null, 2);
  res.writeHead(d.found ? 200 : 404, {
    'content-type': wantsHtml ? 'text/html; charset=utf-8' : 'application/json',
    'x-build-sha': SHA,
    'x-app': meta.app,
    'x-block': BLOCK,
  });
  res.end(body);
}).listen(PORT, BIND, () => {
  console.log(`core listening on ${PORT} (block ${BLOCK}, sha ${SHA})`);
});
