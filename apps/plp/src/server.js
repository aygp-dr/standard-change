// plp — node http, no dependencies. Reads PORT; emits x-build-sha (guard 5).
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
// A separate file from routes.json on purpose. routes.json is the CONTRACT --
// the router, the labeller and the port block all read it, and an app that
// cannot read it has no business starting. categories.json is CONFIGURATION:
// it can be absent, stale or wrong in a deployed environment, and that is a
// state this app has to survive and report, not a reason to refuse to boot.
export const CATALOGUE_FILE = join(here, '..', 'categories.json');
const CATEGORY_PREFIX = '/c/';

// Read per request, not once at import.
//
// Caching at boot makes "the config is missing" unobservable: the app goes on
// serving the copy it read before someone deleted the file, and the operator's
// fix -- put the file back -- needs a restart before any probe can see it. The
// file is a few hundred bytes and this is the only thing that reads it, so the
// read is cheaper than the ambiguity would be.
//
// Returns a RESULT, never throws. Every caller is on the request path.
export function loadCatalogue(file = CATALOGUE_FILE) {
  let raw;
  try { raw = readFileSync(file, 'utf8'); }
  catch { return { ok: false, reason: 'catalogue-missing', categories: [] }; }
  let doc;
  try { doc = JSON.parse(raw); }
  catch { return { ok: false, reason: 'catalogue-malformed', categories: [] }; }
  // Parsing is not validating. A file that is valid JSON and the wrong SHAPE
  // ({}, [], "shoes") parses fine and then throws at the lookup below, which
  // is the crash this function exists to prevent. Same for a single bad entry:
  // it is declared malformed rather than silently dropped, because a catalogue
  // that quietly loses a category is the empty-catalogue failure wearing a
  // different hat.
  const bad = !doc || typeof doc !== 'object' || !Array.isArray(doc.categories) ||
    doc.categories.some((c) => !c || typeof c.slug !== 'string' || !Array.isArray(c.skus));
  if (bad) return { ok: false, reason: 'catalogue-malformed', categories: [] };
  return { ok: true, reason: null, categories: doc.categories };
}

// The category a path names, or null when the path is not a category page.
// '' is a real answer (/c/ and /c): an address under the route that names no
// category, which is an unknown category, not a crash.
export function categoryOf(path) {
  const p = path.split('?')[0];
  if (p !== '/c' && !p.startsWith(CATEGORY_PREFIX)) return null;
  const rest = p === '/c' ? '' : p.slice(CATEGORY_PREFIX.length).replace(/\/+$/, '');
  // decodeURIComponent throws on a malformed escape (/c/%), and the slug comes
  // straight off the wire. Fall back to the raw text rather than 500ing.
  try { return decodeURIComponent(rest); } catch { return rest; }
}

// Which paths plp answers for. Same shape as core's owns(): a declared route
// is a claim on an ADDRESS PREFIX, and under the prefix something narrower
// decides -- for core the file on disk, for plp the catalogue. Owning /c/ was
// never a promise that every category under it exists.
export function owns(path) {
  const p = path.split('?')[0];
  return meta.routes.some((r) => {
    const prefix = r.replace(/:[^/]*$/, '');
    return prefix === '/' ? p === '/' : p.startsWith(prefix);
  });
}

// Status codes, and why these three.
//
//   200  the category exists.
//   404  the catalogue loaded and this category is not in it. The addressed
//        resource does not exist, and that is a 404 whether the missing thing
//        is a file (core, under /statics/) or a row in a catalogue.
//   503  the catalogue could not be loaded. Nothing is wrong with the REQUEST:
//        /c/shoes is very likely a real category the moment the file is back,
//        so answering 404 tells a crawler, a cache and an on-call engineer
//        that the category is GONE -- a lie with consequences, and one that
//        looks identical to a deliberate delisting. Not 500 either: the app is
//        running correctly and its configuration is absent, which is what
//        "unavailable" means. 503 is also the code monitoring pages on; a 404
//        is deliberately not.
//
// One function, so the JSON and the HTML paths cannot drift apart. They did in
// an earlier draft -- the HTML branch wrote its own 200 -- and a browser then
// saw a "no results" page that every machine on the path called a success.
export function status(d) {
  if (d.found) return 200;
  if (d.catalogue === 'unavailable') return 503;
  return 404;
}

export function render(path, catalogue = loadCatalogue()) {
  const d = { app: meta.app, path, found: owns(path), block: BLOCK, sha: SHA,
              routes: meta.routes };
  // The term the shopper typed. '' is a real answer: /search with no q is a
  // search page nobody has searched from yet, not "this is not a search".
  const [p, qs] = path.split('?');
  if (p === '/search') d.query = new URLSearchParams(qs || '').get('q') ?? '';
  // A match is a category whose slug or title contains the term; '' matches nothing.
  if (d.query !== undefined) d.results = !d.query ? [] : catalogue.categories
    .filter((c) => `${c.slug} ${c.title || ''}`.toLowerCase().includes(d.query.toLowerCase()))
    .flatMap((c) => c.skus);
  const slug = categoryOf(path);
  if (slug === null) return d;   // /search, and anything else: unchanged

  d.category = slug;
  // The field an operator greps for. `catalogue: "unavailable"` and
  // `results: []` with `catalogue: "ok"` are two different incidents, and a
  // response that cannot tell them apart turns a deleted config file into
  // "the catalogue is empty today" -- which reads as a merchandising problem
  // and gets routed to the wrong team.
  d.catalogue = catalogue.ok ? 'ok' : 'unavailable';
  d.results = [];
  if (!catalogue.ok) {
    d.found = false;
    d.reason = catalogue.reason;   // catalogue-missing | catalogue-malformed
    return d;
  }
  const hit = catalogue.categories.find((c) => c.slug === slug);
  if (!hit) { d.found = false; d.reason = 'unknown-category'; return d; }
  d.title = typeof hit.title === 'string' ? hit.title : hit.slug;
  d.results = hit.skus;
  return d;
}

// An HTML view so the estate can be clicked through. JSON stays the contract
// the gates assert on; HTML is only served when the client asks for it.
export const BACKGROUND = '#e6f7ee';

// The category panel: results, or the reason there are none.
//
// A person who asks for a category we do not have must get a PAGE saying so --
// not a JSON body, and not a category page with an empty grid that implies the
// category exists and happens to be sold out. The two no-results cases say
// different things because they are different promises: "we do not have that"
// versus "we cannot tell you right now".
export function panel(d) {
  // esc(): d.query is request text, not config. Issue #13's rule has no
  // exceptions, and this is the shortest path from the wire to the document.
  if (d.query === '') return `<h2>Search</h2>
<p>Nothing searched for yet — add a term, as in <code>/search?q=shoes</code>, or pick a category below.</p>`;
  if (d.query !== undefined) return `<h2>${d.results.length} result(s) for <code>${esc(d.query)}</code></h2>
<div class=g>${d.results.map((s) => `<a href="/p/${encodeURIComponent(s)}">${esc(s)}</a>`).join(' ') || 'Nothing matched. Try a shorter word, or pick a category below.'}</div>`;
  if (d.results === undefined) return '';   // not a category page
  const name = esc(d.category || '(none)');
  if (d.catalogue === 'unavailable')
    return `<h2>No results</h2>
<p>We cannot show <code>${name}</code> right now — the catalogue is unavailable.
Nothing is wrong with this category; try again shortly.</p>
<p class=v>catalogue: unavailable (${esc(d.reason)})</p>`;
  if (!d.found)
    return `<h2>No results</h2>
<p>We have nothing in <code>${name}</code>. It may have been renamed or removed.</p>
<p class=v>catalogue: ok — this category is not in it</p>`;
  return `<h2>${esc(d.title)}</h2>
<p>${d.results.length} result(s) in <code>${name}</code></p>
<div class=g>${d.results.map((s) => `<a href="/p/${encodeURIComponent(s)}">${esc(s)}</a>`).join(' ')}</div>`;
}

// `port` is the port this process is ACTUALLY answering on: the caller takes it
// off the accepted socket, not from PORT. shared/oneui.js derives the tier from
// it, and a tier derived from something the deployer exported would be the
// estate reporting what it was told (issue #15).
export function renderHtml(path, catalogue = loadCatalogue(), port) {
  const d = render(path, catalogue);
  return page({ ...d, host: HOST, port }, ESTATE, BACKGROUND, panel(d));
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
  console.log(`plp listening on ${PORT} (block ${BLOCK}, sha ${SHA})`);
});
