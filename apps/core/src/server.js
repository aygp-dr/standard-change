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
import { page, loadEstate, HOST, VERSION as ONEUI } from '../../../shared/oneui.js';
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

// `port` is the port this process is ACTUALLY answering on: the caller takes it
// off the accepted socket, not from PORT. shared/oneui.js derives the tier from
// it, and a tier derived from something the deployer exported would be the
// estate reporting what it was told (issue #15).

// A per-route panel, keyed by path with the query string stripped. The table
// holds STATIC strings ONLY: page() interpolates its `extra` argument raw
// (shared/oneui.js), so anything derived from a request must be escaped with
// esc() by whoever puts it here. Routes absent from the table render nothing.
export const PANELS = {
};

export function panel(path) {
  return PANELS[path.split('?')[0]] || '';
}

export function renderHtml(path, port) {
  const d = render(path);
  return page({ ...d, host: HOST, port }, ESTATE, BACKGROUND, panel(d.path));
}

// A DEDICATED HEALTH ROUTE, not a business route.
//
// Guard 5 fetches whatever routes.json calls `health` and requires 200. Every
// app used a real page for that, and it broke twice: pdp's /p/PING when pdp
// started validating SKUs (#24), and plp's /search?q=ping would break the
// moment search actually searches (#35). A health check pinned to a product
// feature fails whenever that feature gains an opinion.
//
// Under /__, which the router reserves for the estate's own endpoints, so it
// can never collide with a route an app declares. Deliberately NOT in
// routes.json's `routes` array: it is not part of the contract the estate
// offers, it does not appear in the nav, and no journey crosses it.
//
// It reports what this process knows about itself and nothing else. It does
// not check downstream apps -- an app that reports unhealthy because a SIBLING
// is down turns one outage into five, and makes convergence unmeasurable.
function healthDoc() {
  return { app: meta.app, status: 'ok', sha: SHA, block: BLOCK,
           pid: process.pid, uptime_s: Math.round(process.uptime()) };
}

// Only listen when run directly. Importing this module (as the unit tests do)
// must not bind a port, or the test process never exits.
const isMain = process.argv[1] &&
  import.meta.url === pathToFileURL(process.argv[1]).href;

if (isMain) createServer((req, res) => {
  if (req.url.split('?')[0] === `/__health/${meta.app}`) {
    res.writeHead(200, { 'content-type': 'application/json',
                         'cache-control': 'no-store', 'x-build-sha': SHA,
                         'x-app': meta.app, 'x-block': BLOCK });
    return res.end(JSON.stringify(healthDoc(), null, 2));
  }
  const asset = staticFile(req.url);
  if (asset) {
    res.writeHead(200, { 'content-type': asset.type, 'x-build-sha': SHA,
                         'x-app': meta.app, 'x-block': BLOCK });
    return res.end(readFileSync(asset.file));
  }
  const d = render(req.url);
  const wantsHtml = /text\/html/.test(req.headers.accept || '');
  const body = wantsHtml ? renderHtml(req.url, req.socket.localPort)
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

// noop 01 — a change with no behaviour, to walk the workflow.
