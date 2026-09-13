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

// ---- the product data, which plp does not own -------------------------------
//
// WHOSE FILE IS THIS. apps/pdp/products.json is pdp's. plp reads it, and that
// is the deliberate answer to issue #35's third question: a search for a
// product NAME ("trail runner") cannot be answered from categories.json, which
// holds slugs, titles and SKU strings and no product names at all.
//
// The three alternatives and why not:
//
//   ask pdp over HTTP -- plp's page would then be down whenever pdp is down,
//     and plp's health path IS a search (routes.json: "/search?q=ping"), so
//     guard 5 would report plp unhealthy because a SIBLING is unhealthy. One
//     outage becomes two and convergence stops being measurable per app.
//   keep a copy in plp -- two product lists that drift, which is the exact
//     failure apps/pdp/tests/unit/estate.test.js was written to catch. Adding
//     a second instance of the problem in order to avoid a file read is not a
//     trade, it is the bug.
//   search categories only -- honest and narrow, but it answers "shoes" and
//     not "trail runner", and "type a word, see the products whose name
//     contains it" is the whole of what was asked for.
//
// So: ONE product list in the estate, read from the file its owner writes.
// The coupling is real and it is BUILD-TIME, not run-time: the apps ship from
// one tree at one SHA (targets/node/deploy.sh checks out a single worktree and
// starts all four out of it), so plp and pdp cannot be looking at different
// products.json the way two HTTP peers could be on different builds. And it is
// statically checkable, which a runtime dependency is not -- estate.test.js
// now asserts plp reads the same path pdp serves from, in `gmake test`, before
// anything is deployed.
//
// What it costs, stated rather than hidden: a change to pdp's data changes
// plp's search, and an app:pdp-labelled PR can move plp's output without plp
// appearing in the diff. That is the same class of coupling as OneUI (issue
// #10, docs/cross-cutting-coupling.org) and it is named here for the same
// reason.
export const PRODUCTS_FILE = join(here, '..', '..', 'pdp', 'products.json');

// Same shape as loadCatalogue: a RESULT, never a throw, and never a cached
// copy of a file someone has since deleted. The reasons are distinct strings
// (`products-missing`, `products-malformed`) so an operator greps the response
// and learns WHICH file is gone -- "the catalogue is unavailable" over two
// different files would have them checking the wrong app.
export function loadProducts(file = PRODUCTS_FILE) {
  let raw;
  try { raw = readFileSync(file, 'utf8'); }
  catch { return { ok: false, reason: 'products-missing', products: [] }; }
  let doc;
  try { doc = JSON.parse(raw); }
  catch { return { ok: false, reason: 'products-malformed', products: [] }; }
  // Only the two fields plp searches are required. plp must not validate
  // price, currency or availability: those are pdp's business, pdp already
  // checks them, and a second app with an opinion about a field it does not
  // render is a way for a legal catalogue to be rejected by the wrong process.
  const bad = !doc || typeof doc !== 'object' || !Array.isArray(doc.products) ||
    doc.products.some((p) => !p || typeof p.sku !== 'string' || typeof p.name !== 'string');
  if (bad) return { ok: false, reason: 'products-malformed', products: [] };
  return { ok: true, reason: null, products: doc.products };
}

// ---- the query --------------------------------------------------------------
//
// The query a path asks for, or null when the path is not the search page.
// '' is a real answer and is NOT null: `/search` with no q and `/search?q=`
// are both "show me the search page", which is a different thing from "this
// path is not a search at all".
const SEARCH_PATHS = ['/search', '/search/'];

export function queryOf(path) {
  const p = String(path).split('?')[0];
  if (!SEARCH_PATHS.includes(p)) return null;
  // URL parsing rather than a hand-rolled split: it decodes %XX and the `+`
  // that a GET form actually puts on the wire, and -- unlike
  // decodeURIComponent, which categoryOf has to guard against -- it does not
  // throw on a malformed escape (`?q=%` yields "%"). The base is a throwaway;
  // only the search part is read.
  try { return new URL(String(path), 'http://plp.invalid').searchParams.get('q') ?? ''; }
  catch { return ''; }
}

// What a query matches. Substring, case-insensitive, no ranking and no fuzzy
// matching -- issue #35 puts all three out of scope on purpose, because the
// interesting part of this change is escaping, status codes and where the data
// comes from, and a scorer would hide all three behind itself.
//
// Two kinds of result, kept apart in the payload rather than merged into one
// ranked list: a category is a place to browse and a product is a thing to
// buy, and a client that cannot tell them apart cannot link them correctly.
//
// A CATEGORY HIT REACHES ITS PRODUCTS. This is the defect that was live on
// production blue: /search?q=shoes matched the shoes category, rendered one
// link to /c/shoes, and listed no products at all -- while /c/shoes, one click
// away, listed three. A person who types the name of a category and is shown
// nothing they can buy has been told, wrongly, that we have nothing.
//
// So the products a query reaches are the union of two routes to the same
// thing: named directly (by product name or SKU), or named THROUGH a category
// the query matched. Deduped by SKU with the direct hit kept, because "trail"
// matching Trail Runner by name and again through a category is one product,
// not two, and `via` records which route found it.
export function searchResults(q, categories, products) {
  const needle = q.trim().toLowerCase();
  if (!needle) return [];
  const hit = (s) => typeof s === 'string' && s.toLowerCase().includes(needle);
  const cats = categories
    .filter((c) => hit(c.slug) || hit(c.title))
    .map((c) => ({ kind: 'category', slug: c.slug,
                   title: typeof c.title === 'string' ? c.title : c.slug,
                   href: `/c/${encodeURIComponent(c.slug)}`,
                   skus: Array.isArray(c.skus) ? c.skus : [] }));

  const byS = new Map(products.map((p) => [p.sku, p]));
  const seen = new Set();
  const prods = [];
  const push = (sku, name, via) => {
    if (typeof sku !== 'string' || seen.has(sku)) return;
    seen.add(sku);
    prods.push({ kind: 'product', sku, name,
                 href: `/p/${encodeURIComponent(sku)}`, via });
  };
  for (const p of products) if (hit(p.name) || hit(p.sku)) push(p.sku, p.name, null);
  for (const c of cats) {
    for (const s of c.skus) {
      // A SKU a category lists but the product file does not carry still
      // lists, under its SKU -- the same thing /c/<category> has always done
      // with it. plp does not get to delist a category's item because it
      // could not find a name for it; that is a data fault for pdp to fix and
      // an operator can see it on the page.
      push(s, byS.has(s) ? byS.get(s).name : null, c.slug);
    }
  }
  return [...cats, ...prods];
}

// The SKUs a category lists, resolved to the products they name, in the order
// the category gave them. Same shape as the `product` results above (sku,
// name) so that ONE renderer can list either -- see productList().
export function itemsFor(skus, products) {
  const byS = new Map(products.map((p) => [p.sku, p]));
  return skus.map((s) => ({ sku: s, name: byS.has(s) ? byS.get(s).name : null }));
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
// SEARCH IS DIFFERENT, AND DELIBERATELY SO.
//
//   200  the search ran. Results, or no results, or no query yet -- all 200.
//        A query that matched nothing is a SUCCESSFUL ANSWER to a reasonable
//        question: /search?q=zzzz is a real address that a person may share,
//        bookmark and reload, and the server did exactly what was asked. This
//        is not the /p/NOSUCH case, where the addressed RESOURCE does not
//        exist; here the resource is the search page and it is right there.
//   503  the data needed to answer could not be read. Same rule as a category:
//        "we cannot tell you" must never render as "there is nothing".
//
// There is no 404 on /search at all, and that is load-bearing rather than
// cosmetic: apps/plp/routes.json declares `health: "/search?q=ping"` and guard
// 5 fetches it expecting 200. "ping" matches nothing. A 404-on-no-results
// search would therefore report a perfectly healthy plp as UNHEALTHY the day
// search started working -- which is exactly what happened to pdp in #24 when
// its health path became /p/PING against a catalogue that validates SKUs.
//
// This does mean plp and pdp now answer differently for a miss (200 here, 404
// there). That is not an inconsistency to be tidied up later: the two are
// answering different questions, and the difference is the reason this app can
// carry a health path at all.
//
// One function, so the JSON and the HTML paths cannot drift apart. They did in
// an earlier draft -- the HTML branch wrote its own 200 -- and a browser then
// saw a "no results" page that every machine on the path called a success.
export function status(d) {
  if (d.found) return 200;
  // Either data source being unreadable is an availability fault, not a
  // not-found: the category or the product is very likely still there the
  // moment the file is back.
  if (d.catalogue === 'unavailable' || d.products === 'unavailable') return 503;
  return 404;
}

// The search branch of render(). Four states, and they must stay four.
//
//   query + matches      found:true   count>0   reason:null         200
//   query + no matches   found:true   count=0   reason:no-results   200
//   no query             found:true   count=0   reason:empty-query  200
//   data unreadable      found:false  count=0   reason:<which file> 503
//
// `found` on a search page means THE SEARCH RAN, not "something matched" --
// the thing being addressed is the search, and it is right there. `count` and
// `reason` are what say whether anything matched, and they are separate fields
// so that a client cannot read one and infer the other.
//
// There is no partial answer. If the product file is unreadable, plp does NOT
// fall back to searching categories alone and report "no results for trail
// runner": that is a lie by omission, and it is the same lie -- "we cannot
// tell you" wearing "there is nothing" -- that the category page's 503 exists
// to refuse.
function search(d, q, catalogue, products) {
  d.query = q;
  d.catalogue = catalogue.ok ? 'ok' : 'unavailable';
  d.products = products.ok ? 'ok' : 'unavailable';
  d.results = [];
  // The products to LIST, in listing order. A separate field from `results`
  // on purpose: `results` is the mixed, kind-tagged answer a client reasons
  // about, and `items` is the one thing both this route and /c/:category
  // render the same way. Always an array, in every state, so the view never
  // has to ask whether it exists.
  d.items = [];
  d.count = 0;

  if (!q.trim()) {
    // No claim is made about results here, so it does not matter whether the
    // data could be read: nothing was asked. The availability fields above are
    // still reported honestly, because an operator watching the health path
    // should be able to see a file go missing before a query does.
    d.reason = 'empty-query';
    return d;
  }
  if (!catalogue.ok || !products.ok) {
    d.found = false;
    d.reason = catalogue.ok ? products.reason : catalogue.reason;
    return d;
  }
  d.results = searchResults(q, catalogue.categories, products.products);
  d.items = d.results.filter((r) => r.kind === 'product')
                     .map((r) => ({ sku: r.sku, name: r.name }));
  d.count = d.results.length;
  d.reason = d.count ? null : 'no-results';
  return d;
}

export function render(path, catalogue = loadCatalogue(), products = loadProducts()) {
  const d = { app: meta.app, path, found: owns(path), block: BLOCK, sha: SHA,
              routes: meta.routes };

  const q = queryOf(path);
  if (q !== null) return search(d, q, catalogue, products);

  const slug = categoryOf(path);
  if (slug === null) return d;   // anything else: unchanged

  d.category = slug;
  // The field an operator greps for. `catalogue: "unavailable"` and
  // `results: []` with `catalogue: "ok"` are two different incidents, and a
  // response that cannot tell them apart turns a deleted config file into
  // "the catalogue is empty today" -- which reads as a merchandising problem
  // and gets routed to the wrong team.
  d.catalogue = catalogue.ok ? 'ok' : 'unavailable';
  d.results = [];
  d.items = [];
  if (!catalogue.ok) {
    d.found = false;
    d.reason = catalogue.reason;   // catalogue-missing | catalogue-malformed
    return d;
  }
  const hit = catalogue.categories.find((c) => c.slug === slug);
  if (!hit) { d.found = false; d.reason = 'unknown-category'; return d; }
  d.title = typeof hit.title === 'string' ? hit.title : hit.slug;
  d.results = hit.skus;
  // The SKUs are still `results` -- that is this route's contract and the
  // e2e/unit assertions read it. `items` is the same list with names attached
  // for the renderer it now shares with /search. Names are a NICETY here, not
  // a dependency: an unreadable product file leaves every name null and the
  // category page lists SKUs exactly as it did before search existed. A
  // category page must not go dark because a sibling app's data file did.
  d.items = itemsFor(hit.skus, products.products);
  return d;
}

// An HTML view so the estate can be clicked through. JSON stays the contract
// the gates assert on; HTML is only served when the client asks for it.
export const BACKGROUND = '#e6f7ee';

// ---- the product list, which both routes render -----------------------------
//
// ONE renderer, used by /c/:category and by /search. It was two, and they
// diverged exactly the way two copies of anything do: the category page listed
// products in a wrapping row of links and the search page listed them as
// stacked rows with a `product` label, so the same product looked like two
// different things depending on how you arrived at it -- and the search page's
// copy was never reached for a category-name query at all. A person searching
// "shoes" and a person browsing /c/shoes are looking at the same shelf.
//
// `name` may be null: a SKU a category lists that the product file does not
// carry. It lists under its SKU rather than vanishing.
//
// EVERY interpolation goes through esc(), including the ones that come from
// config. Issue #13 was a live reflected XSS in this estate through a single
// unescaped interpolation, and "it comes from a JSON file we ship" is exactly
// what was said about the values that turned out to be reachable. The href is
// built with encodeURIComponent AND escaped: the first makes it a correct URL,
// the second makes it safe to put inside a double-quoted attribute, and
// neither does the other's job.
export function productList(items) {
  if (!items.length) return '';
  return `<div class=g>${items.map((p) =>
    `<span style="display:inline-block;margin-right:14px">` +
    `<a href="${esc(`/p/${encodeURIComponent(p.sku)}`)}" style="margin-right:4px">` +
    `${esc(p.name || p.sku)}</a>` +
    // The SKU is shown alongside a name and IS the label when there is none,
    // so the category page loses nothing it used to show.
    (p.name ? `<span class=v>${esc(p.sku)}</span>` : '') +
    `</span>`).join('')}</div>`;
}

// The category panel: results, or the reason there are none.
//
// A person who asks for a category we do not have must get a PAGE saying so --
// not a JSON body, and not a category page with an empty grid that implies the
// category exists and happens to be sold out. The two no-results cases say
// different things because they are different promises: "we do not have that"
// versus "we cannot tell you right now".
// The search panel: the box a person types into, and what came back.
//
// THE FORM IS ALWAYS RENDERED, including on the 503. A page that says "we
// cannot search right now" and then takes the box away gives a person nothing
// to retry with, and the retry is the whole of what they can usefully do.
//
// GET, action="/search". Not POST: the result of a search has to be an ADDRESS
// -- something a person can link to a colleague and something gates/smoke.sh
// can keep walking (/search?q=shoes is step 2 of the journey) and guard 5 can
// keep probing (/search?q=ping). A POST result is neither.
//
// ESCAPING. `q` is the first thing in this estate that is user-supplied and is
// not a route the router already constrained, and it lands in TWO contexts:
// text, and the input's value= ATTRIBUTE. esc() covers both -- it escapes the
// quote characters, which is what makes `?q=" onfocus="alert(1)` inert here
// and what d.path never needed. Issue #13 was a live reflected XSS in this
// estate through exactly one unescaped interpolation, so every one below goes
// through esc() including the ones that "come from config".
export function searchPanel(d) {
  const q = esc(d.query);
  const form = `<form class=s action="/search" method="get" role="search" style="margin:18px 0 6px">
<label for=q style="margin-right:6px">Search</label>
<input id=q name=q type="search" value="${q}" placeholder="shoes, trail, SKU123"
 autocomplete="off" style="font:inherit;padding:4px 8px;width:16rem">
<button type="submit" style="font:inherit;padding:4px 10px;margin-left:6px">Search</button>
</form>`;

  if (d.reason === 'empty-query')
    return `${form}
<p>Type a word to search categories and products. Nothing has been searched
yet, so this page is not claiming there is nothing.</p>`;

  if (d.products === 'unavailable' || d.catalogue === 'unavailable')
    return `${form}
<h2>We cannot search right now</h2>
<p>Your search for <code>${q}</code> was not run — the catalogue is
unavailable. This is not a statement that there is nothing; try again
shortly.</p>
<p class=v>search: unavailable (${esc(d.reason)})</p>`;

  if (!d.count)
    return `${form}
<h2>No results</h2>
<p>Nothing matches <code>${q}</code>. The search ran and found nothing — try a
category name, a product name or a SKU.</p>
<p class=v>catalogue: ok — nothing matched</p>`;

  // Categories first, as places to go; then the products themselves, listed by
  // the SAME function /c/:category lists them with. The category rows stay --
  // "browse the whole shelf" is a useful answer and the e2e link check walks
  // every href in `results` -- but they are no longer the ONLY answer to a
  // query that names a category, which is what made this page useless.
  const cats = d.results.filter((r) => r.kind === 'category');
  const catRows = cats.map((r) =>
    `<div class=g><b>category</b> <a href="${esc(r.href)}">${esc(r.title)}</a> ` +
    `<span class=v>${r.skus.length} item(s)</span></div>`).join('');
  return `${form}
<h2>${d.count} result(s)</h2>
<p>for <code>${q}</code></p>
${catRows}${d.items.length ? `<p class=g style="color:#666;margin:10px 0 4px">products</p>` : ''}
${productList(d.items)}`;
}

export function panel(d) {
  if (d.query !== undefined) return searchPanel(d);
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
<p>${d.items.length} result(s) in <code>${name}</code></p>
${productList(d.items)}`;
}

// `port` is the port this process is ACTUALLY answering on: the caller takes it
// off the accepted socket, not from PORT. shared/oneui.js derives the tier from
// it, and a tier derived from something the deployer exported would be the
// estate reporting what it was told (issue #15).
export function renderHtml(path, catalogue = loadCatalogue(), port,
                           products = loadProducts()) {
  const d = render(path, catalogue, products);
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
  // Same rule for the product file: read once per request and hand the ONE
  // result to both representations, so the status line and the body cannot
  // describe two different reads of the file.
  const products = loadProducts();
  const d = render(req.url, catalogue, products);
  const body = wantsHtml
    ? renderHtml(req.url, catalogue, req.socket.localPort, products)
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
