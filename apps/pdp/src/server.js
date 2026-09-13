// pdp — node http, no dependencies. Reads PORT; emits x-build-sha (guard 5).
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

// ---- the catalogue ----------------------------------------------------------
//
// WHERE THE PRODUCT DATA COMES FROM, and why it is a file next to the app
// rather than a call to external/mock's /api/catalog (issue #17 argued for the
// call; this is the dissent, stated here so the next reader does not have to
// reconstruct it from the diff):
//
//   1. external/ is explicitly OUTSIDE what this pipeline deploys --
//      router/generate.sh says so and gates/production-first.sh was amended so
//      external stand-ins need no production deployment. Product data fetched
//      from there is page content that no gate gated and no rollback rolls
//      back, while `deployed:production-pdp-N` on the head SHA claims the page
//      was verified at that build. The label would be false.
//   2. pdp's health path is a product page, and guard 5 (gates/health.sh)
//      requires 200 on it. An honest 503 when the catalogue is unreachable
//      therefore means: mock goes down -> pdp is UNHEALTHY -> a correct pdp
//      build is blocked or rolled back because a stand-in for somebody else's
//      service is down. Modelling that failure is worth something; wiring it
//      into the promotion decision is not.
//   3. render() would have to become async. Every app in the estate exports a
//      synchronous render(path); gates/lint-app.mjs checks for it and every
//      contract test calls it directly. Forking that contract for one app, in
//      a repo whose product is the uniformity of the pipeline, costs more than
//      the realism buys.
//   4. The cross-app agreement assertion -- the part issue #17 calls the most
//      valuable -- is STATIC against a file (tests/unit/estate.test.js runs in
//      `gmake test`, before anything is deployed) and can only be a runtime
//      check against a service, i.e. after the deploy it was supposed to stop.
//
// What the call WOULD have bought is not lost: the unavailable path below is
// real, reachable and tested, and loadCatalogue() returns {ok, reason,
// products} -- exactly the shape a fetch wrapper returns. Moving to a real
// catalogue service later is this one function, plus moving the agreement
// assertion into gates/e2e.sh.
//
// A separate file from routes.json on purpose. routes.json is the CONTRACT --
// the router, the labeller and the port block all read it, and an app that
// cannot read it has no business starting. products.json is CONFIGURATION: it
// can be absent, stale or wrong in a deployed environment, and that is a state
// this app has to survive and report, not a reason to refuse to boot.
export const CATALOGUE_FILE = join(here, '..', 'products.json');
const PRODUCT_PREFIX = '/p/';

// Read per request, not once at import -- the same reasoning as plp: caching at
// boot makes "the config is missing" unobservable, because the app goes on
// serving the copy it read before someone deleted the file and the operator's
// fix needs a restart before any probe can see it.
//
// Returns a RESULT, never throws. Every caller is on the request path.
export function loadCatalogue(file = CATALOGUE_FILE) {
  let raw;
  try { raw = readFileSync(file, 'utf8'); }
  catch { return { ok: false, reason: 'catalogue-missing', products: [] }; }
  let doc;
  try { doc = JSON.parse(raw); }
  catch { return { ok: false, reason: 'catalogue-malformed', products: [] }; }
  // Parsing is not validating. A file that is valid JSON and the wrong SHAPE
  // ({}, [], "SKU123") parses fine and then throws at the lookup below, which
  // is the crash this function exists to prevent. A single bad ENTRY is
  // declared malformed rather than silently dropped: a catalogue that quietly
  // loses a product 404s a product that exists, which is the unknown-sku
  // failure wearing a costume -- and it is precisely the disagreement with plp
  // that tests/unit/estate.test.js is there to catch.
  const bad = !doc || typeof doc !== 'object' || !Array.isArray(doc.products) ||
    doc.products.some((p) => !p || typeof p.sku !== 'string' || p.sku === '' ||
      typeof p.name !== 'string' || typeof p.price !== 'number' ||
      !Number.isFinite(p.price) || typeof p.availability !== 'string');
  if (bad) return { ok: false, reason: 'catalogue-malformed', products: [] };
  return { ok: true, reason: null, products: doc.products };
}

// The SKU a path names, or null when the path is not a product page.
// '' is a real answer (/p/ and /p): an address under the route that names no
// SKU, which is an unknown product, not a crash.
export function skuOf(path) {
  const p = path.split('?')[0];
  if (p !== '/p' && !p.startsWith(PRODUCT_PREFIX)) return null;
  const rest = p === '/p' ? '' : p.slice(PRODUCT_PREFIX.length).replace(/\/+$/, '');
  // decodeURIComponent throws on a malformed escape (/p/%), and the SKU comes
  // straight off the wire. Fall back to the raw text rather than 500ing.
  try { return decodeURIComponent(rest); } catch { return rest; }
}

// Which paths pdp answers for. Same shape as core's and plp's owns(): a
// declared route is a claim on an ADDRESS PREFIX, and under the prefix
// something narrower decides -- for core the file on disk, for plp the
// catalogue, for pdp the catalogue. Owning /p/ was never a promise that every
// SKU under it exists.
export function owns(path) {
  const p = path.split('?')[0];
  return meta.routes.some((r) => {
    const prefix = r.replace(/:[^/]*$/, '');
    return prefix === '/' ? p === '/' : p.startsWith(prefix);
  });
}

// Status codes, and why these three. Identical to plp's, deliberately: the two
// apps face the same question and an estate where /c/nope is a 404 and /p/nope
// is a 200 has two different stories about what "we do not carry that" means.
//
//   200  the product exists.
//   404  the catalogue loaded and this SKU is not in it. The addressed
//        resource does not exist.
//   503  the catalogue could not be loaded. Nothing is wrong with the REQUEST:
//        /p/SKU123 is very likely a real product the moment the file is back,
//        so answering 404 tells a crawler, a cache and an on-call engineer
//        that the product is GONE -- a lie with consequences, and one that
//        looks identical to a deliberate delisting. Not 500 either: the app is
//        running correctly and its configuration is absent, which is what
//        "unavailable" means. 503 is also the code monitoring pages on; a 404
//        is deliberately not.
//
// One function, so the JSON and the HTML paths cannot drift apart.
export function status(d) {
  if (d.found) return 200;
  if (d.catalogue === 'unavailable') return 503;
  return 404;
}

export function render(path, catalogue = loadCatalogue()) {
  const d = { app: meta.app, path, found: owns(path), block: BLOCK, sha: SHA,
              routes: meta.routes };
  const sku = skuOf(path);
  if (sku === null) return d;   // anything that is not a product page

  d.sku = sku;
  // The field an operator greps for. `catalogue: "unavailable"` and
  // `catalogue: "ok"` with `reason: "unknown-sku"` are two different
  // incidents with two different owners, and a response that cannot tell them
  // apart turns a deleted config file into "that product was delisted".
  d.catalogue = catalogue.ok ? 'ok' : 'unavailable';
  d.product = null;
  if (!catalogue.ok) {
    d.found = false;
    d.reason = catalogue.reason;   // catalogue-missing | catalogue-malformed
    return d;
  }
  const hit = catalogue.products.find((p) => p.sku === sku);
  if (!hit) { d.found = false; d.reason = 'unknown-sku'; return d; }
  d.found = true;
  d.product = {
    sku: hit.sku,
    name: hit.name,
    price: hit.price,
    currency: typeof hit.currency === 'string' ? hit.currency : 'USD',
    availability: hit.availability,
  };
  return d;
}

// An HTML view so the estate can be clicked through. JSON stays the contract
// the gates assert on; HTML is only served when the client asks for it.
export const BACKGROUND = '#fff4e0';

// An error page should not look like a page that worked. pdp renders the same
// chrome whether it found the product or not, so a 404 and a 200 were
// distinguishable only by reading the words -- and gates/smoke.sh already
// proved nobody clicks the sad path on purpose.
//
// Keyed off `found`, the same field status() uses, so the colour cannot
// disagree with the status code. If it renders red it returned 404 or 503.
export const ERROR_BACKGROUND = '#ffe3e3';
const background = (d) => (d.found ? BACKGROUND : ERROR_BACKGROUND);

const SYMBOL = { USD: '$', GBP: '£', EUR: '€' };
export function money(price, currency) {
  const sym = SYMBOL[currency];
  return sym ? `${sym}${price.toFixed(2)}` : `${price.toFixed(2)} ${currency}`;
}

// Prose, not a slug. A page that says `out-of-stock` is showing a person the
// database. Anything the catalogue invents falls through to the raw value
// rather than being dropped -- an availability we do not recognise is still
// information, and it is escaped like everything else.
const AVAILABILITY = {
  'in-stock': 'In stock',
  'low-stock': 'Low stock — only a few left',
  'out-of-stock': 'Out of stock',
  'preorder': 'Available to pre-order',
};

// The product panel: the product, or the reason there is not one.
//
// A person who asks for a SKU we do not have must get a PAGE saying so -- not
// a JSON body, and not a product page with the name blank, which implies the
// product exists and we have merely forgotten what it is called. The two
// no-product cases say different things because they are different promises:
// "we do not have that" versus "we cannot tell you right now".
export function panel(d) {
  if (d.sku === undefined) return '';   // not a product page
  const sku = esc(d.sku || '(no SKU)');
  if (d.catalogue === 'unavailable')
    return `<h2>Product unavailable</h2>
<p>We cannot show <code>${sku}</code> right now — the catalogue is unavailable.
This product has not gone away; try again shortly.</p>
<p class=v>catalogue: unavailable (${esc(d.reason)})</p>`;
  if (!d.found)
    return `<h2>Product not found</h2>
<p>We have no product <code>${sku}</code>. It may have been renamed or removed.</p>
<p class=v>catalogue: ok — this product is not in it</p>`;
  const p = d.product;
  return `<h2>${esc(p.name)}</h2>
<p><b>${esc(money(p.price, p.currency))}</b> · ${esc(AVAILABILITY[p.availability] || p.availability)}</p>
<p>SKU <code>${sku}</code></p>`;
}

// `port` is the port this process is ACTUALLY answering on -- the caller takes
// it off the accepted socket, not from PORT. shared/oneui.js derives the tier
// from it, and a tier derived from something the deployer exported would be the
// estate reporting what it was told rather than what is true (issue #15).
export function renderHtml(path, catalogue = loadCatalogue(), port) {
  const d = render(path, catalogue);
  return page({ ...d, host: HOST, port }, ESTATE, background(d), panel(d));
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
  // One catalogue read per request, shared by both representations, so the
  // status line and the body cannot describe two different reads of the file.
  const catalogue = loadCatalogue();
  const d = render(req.url, catalogue);
  const body = wantsHtml ? renderHtml(req.url, catalogue, req.socket.localPort)
                         : JSON.stringify(d, null, 2);
  res.writeHead(status(d), {
    'content-type': wantsHtml ? 'text/html; charset=utf-8' : 'application/json',
    'x-build-sha': SHA,
    'x-app': meta.app,
    'x-block': BLOCK,
  });
  res.end(body);
}).listen(PORT, BIND, () => {
  console.log(`pdp listening on ${PORT} (block ${BLOCK}, sha ${SHA})`);
});
