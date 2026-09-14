// Bare-metal router. Stands in for nginx, which is not installed on FreeBSD
// hydra (spec.org, Known blockers). Same contract: prefix -> owning app's port,
// driven by router/routes.json, so what runs at :10010 is what staging runs.
import { createServer, request } from 'node:http';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const apps = JSON.parse(readFileSync(join(here, 'routes.json'), 'utf8'));
const BASE = Number(process.env.BASE_PORT);
const BLOCK = process.env.BLOCK || '?';
const BIND = process.env.BIND || '127.0.0.1';
const SHA = process.env.BUILD_SHA || 'dev';
if (!BASE) throw new Error('BASE_PORT required');

// The estate reports its own route table (issue #14).
//
// gates/e2e.sh pointed its REQUESTS at whatever ROUTER_URL named and took its
// EXPECTATIONS from router/routes.json in the tree the script happened to live
// in. Same estate, same command, opposite verdict depending on the caller's
// working directory -- 24 checks and staging:e2e-failed from one tree, 27 and
// staging:e2e from another, against one deployed build. That instance was
// wrong in the safe direction, which was luck: a tree declaring FEWER routes
// than the build reports green because it did not know to look.
//
// So the build publishes what it is actually routing on, and the gate checks
// that claim rather than its own. A build that claims a route it does not
// serve now fails the ownership loop, which is the right place to find out.
//
// /__estate is RESERVED: gates/lint-app.mjs refuses an app route under /__,
// so this can never shadow something an app owns.
const MANIFEST = '/__estate.json';

// longest-prefix wins, so /checkout/payment beats /checkout and / is last
const table = apps.flatMap((a) =>
  a.routes.map((r) => ({ prefix: r.replace(/\/:.*$/, '/').replace(/:.*/, ''), app: a.app, port: BASE + a.port_offset }))
).sort((x, y) => y.prefix.length - x.prefix.length);

// The default location. nginx's `location / { proxy_pass http://core; }`:
// a path no app claims is not a router-level 404, it goes to whichever app
// declares fallthrough and that app decides. Declared in routes.json, not
// named here, so the router never hardcodes which app is core.
const fb = apps.find((a) => a.fallthrough);
const DEFAULT = fb && { prefix: '/', app: fb.app, port: BASE + fb.port_offset };

// /__ is reserved for the estate's own endpoints. /__health/<app> reaches that
// app directly, so guard 5 can ask each one "are you up" without going through
// a business route that may later gain an opinion (#24, #35).
//
// Routed here rather than declared in routes.json on purpose: it is not part of
// the contract the estate offers, so it does not appear in the nav, no journey
// crosses it, and an app cannot accidentally claim it.
const HEALTH = /^\/__health\/([a-z0-9-]+)$/;

function route(url) {
  const h = HEALTH.exec(url.split('?')[0]);
  if (h) {
    const a = apps.find((x) => x.app === h[1]);
    return a ? { prefix: url, app: a.app, port: BASE + a.port_offset } : undefined;
  }
  const path = url.split('?')[0];
  return table.find((t) => (t.prefix === '/' ? path === '/' : path.startsWith(t.prefix)))
      || DEFAULT;
}

createServer((req, res) => {
  if (req.url.split('?')[0] === MANIFEST) {
    // What this build claims to own. Not a copy of anyone's expectations:
    // it is the very array this process routes on, read once at start.
    const body = JSON.stringify({ sha: SHA, block: BLOCK, base_port: BASE,
                                  served_by: 'router', routes: apps }, null, 2);
    res.writeHead(200, { 'content-type': 'application/json', 'x-build-sha': SHA,
                         'x-router-block': BLOCK, 'x-routed-to': 'router' });
    return res.end(body);
  }
  const hit = route(req.url);
  if (!hit) {
    res.writeHead(404, { 'content-type': 'application/json', 'x-block': BLOCK });
    return res.end(JSON.stringify({ error: 'no route', path: req.url, block: BLOCK }));
  }
  // Forward the request headers. Without this the router silently strips
  // Accept, so an app that content-negotiates works when probed directly and
  // not through the router -- which is how it would have reached staging.
  const up = request({ host: '127.0.0.1', port: hit.port, path: req.url,
                       method: req.method, headers: { ...req.headers, host: `127.0.0.1:${hit.port}` } },
    (r) => {
      res.writeHead(r.statusCode, { ...r.headers, 'x-router-block': BLOCK, 'x-routed-to': hit.app });
      r.pipe(res);
    });
  up.on('error', (e) => {
    res.writeHead(502, { 'content-type': 'application/json', 'x-block': BLOCK });
    res.end(JSON.stringify({ error: 'upstream down', app: hit.app, port: hit.port, detail: e.code }));
  });
  req.pipe(up);
}).listen(BASE, BIND, () => {
  console.log(`router block ${BLOCK} on ${BASE} -> ${table.map((t) => `${t.prefix}=${t.port}`).join(' ')}`);
});
