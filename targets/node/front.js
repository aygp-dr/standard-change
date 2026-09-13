// front.js -- the production address. Proxies to whichever colour is live.
//
// Blue (:9210) and green (:9220) are replicas; neither is "production". This
// is. Without it there is no single address to switch and therefore no atomic
// moment to switch at, which is why the earlier run deployed a verified build
// to blue and could not honestly call it a cutover.
//
// The live colour is read from disk on EVERY request, not cached at startup.
// targets/bastille/front/switch.sh reported the colour by reading its config
// file while nginx served the other one -- a self-report that disagreed with
// the running system. Reading per request costs a stat and makes that class of
// lie impossible: what this file says is what the next request gets.
import { createServer, request } from 'node:http';
import { readFileSync } from 'node:fs';

const STATE = new URL('./live', import.meta.url).pathname;
const PORT = Number(process.env.FRONT_PORT || 9230);
const COLOURS = { blue: 9210, green: 9220 };

function live() {
  const c = readFileSync(STATE, 'utf8').trim();
  if (!(c in COLOURS)) throw new Error(`unknown colour in ${STATE}: ${c}`);
  return c;
}

createServer((req, res) => {
  let colour, port;
  try { colour = live(); port = COLOURS[colour]; }
  catch (e) {
    res.writeHead(503, { 'content-type': 'application/json' });
    return res.end(JSON.stringify({ error: 'no live colour', detail: e.message }));
  }
  const up = request({ host: '127.0.0.1', port, path: req.url, method: req.method,
                       headers: { ...req.headers, host: `127.0.0.1:${port}` } }, (r) => {
    res.writeHead(r.statusCode, { ...r.headers, 'x-colour': colour });
    r.pipe(res);
  });
  up.on('error', (e) => {
    res.writeHead(502, { 'content-type': 'application/json', 'x-colour': colour });
    res.end(JSON.stringify({ error: 'live colour is down', colour, port, detail: e.code }));
  });
  req.pipe(up);
}).listen(PORT, '0.0.0.0', () => console.log(`front :${PORT} -> reads ${STATE} per request`));
