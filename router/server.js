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
if (!BASE) throw new Error('BASE_PORT required');

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

function route(url) {
  const path = url.split('?')[0];
  return table.find((t) => (t.prefix === '/' ? path === '/' : path.startsWith(t.prefix)))
      || DEFAULT;
}

createServer((req, res) => {
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
