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
import { page, loadEstate, esc, HOST, VERSION as ONEUI } from '../../../shared/oneui.js';
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
export const BACKGROUND = '#ffb3d1';

// `port` is the port this process is ACTUALLY answering on: the caller takes it
// off the accepted socket, not from PORT. shared/oneui.js derives the tier from
// it, and a tier derived from something the deployer exported would be the
// estate reporting what it was told (issue #15).
// The shipping address form.
//
// GET, submitting to itself, so the URL stays shareable and the gates can keep
// probing it -- a POST makes the filled form unlinkable and unprobeable, which
// is the same argument that keeps /search a GET.
//
// Every echoed value goes through esc(). These come off the wire and land in an
// attribute context (`value="..."`), where the `"` escape is what matters --
// issue #13 was a live reflected XSS in this repo via a value that reached the
// page unescaped, and an attribute is a shorter path out than a text node.
const SHIP = [
  ['name',    'Full name',    'text'],
  ['line1',   'Address line 1', 'text'],
  ['city',    'City',         'text'],
  ['postcode','Postcode / ZIP', 'text'],
];

export const DUE = '$42.00';  // static copy: no request value reaches it, so no esc()

export function shippingForm(q) {
  const field = ([n, label, type]) =>
    `<p><label>${esc(label)}<br><input name="${esc(n)}" type="${esc(type)}" ` +
    `value="${esc(q.get(n) || '')}" style="width:100%;max-width:22rem;padding:4px"></label></p>`;
  const filled = SHIP.every(([n]) => (q.get(n) || '').trim() !== '');
  return `<p>Your order comes to <b>${DUE}</b>, including delivery.</p>
<h2>Shipping address</h2>
<form method="get" action="/checkout">
${SHIP.map(field).join('\n')}
<p><button type="submit">Continue</button></p>
</form>` + (filled ? '<p><b>Ready to continue to payment.</b></p>' : '');
}

export const paymentPanel = (q) =>
  `<h2>Payment</h2><p>You are about to pay <b>${DUE}</b>. Nothing is charged until you confirm.</p>
<p><a href="/checkout?${esc(q)}">&larr; Back to shipping address</a></p>`;

export function renderHtml(path, port) {
  const q = new URL(path, 'http://x').searchParams;
  const extra = { '/checkout': shippingForm, '/checkout/payment': paymentPanel }[path.split('?')[0]]?.(q) ?? '';
  return page({ ...render(path), host: HOST, port }, ESTATE, BACKGROUND, extra);
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

// feat/checkout-tax-line: simulated change
