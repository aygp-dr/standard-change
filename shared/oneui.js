// OneUI -- the shared UI surface (issue #10).
//
// Deliberately at the repo root, not under apps/: apps/ means DEPLOYABLE UNITS,
// and this is a library. Putting it under apps/ would mint an app:shared label
// for something with no routes.json and no port, and router/generate.sh globs
// apps/*/routes.json.
//
// The cost is stated plainly in VERSION below: every app pins a version, and a
// change here is a change to all of them.
import { readFileSync } from 'node:fs';

// 1.1.1 -- the estate nav no longer invents an instance of a parameterised
// route; it reads the one the app declares (`probes`, see below), and it
// escapes the href and the app name it interpolates, which 1.0.1 missed
// because those values come from config rather than from the request line.
// A PATCH: nothing was added to or removed from the surface, page() still
// takes (d, estate, background, extra?), and every caller is unchanged. What
// changed is which URL the nav points at, which is a defect fix.
export const VERSION = '1.1.1';

// d.path is whatever the client put in the request line, and it went straight
// into the document: GET /<script>alert(1)</script> came back as live markup
// from every app in the estate, in every environment, including the rollback
// target. Found by an agent that was editing this file for an unrelated reason.
//
// Escape at the point of INTERPOLATION, not at the point where the value
// enters the app. An app that sanitised its own inputs would still be one
// forgetful caller away from this, and there are four callers. The renderer is
// the only place that knows it is building HTML.
export function esc(s) {
  return String(s ?? '').replace(/[&<>"']/g,
    (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

const SHARED_ROUTES = ['/about', '/contact', '/jobs'];

// A parameterised route has no universally valid instance, and this function
// used to invent one: ':sku' -> 'SKU1'. That was invisible for as long as pdp
// echoed back whatever it was handed with a 200. The moment pdp started
// checking the SKU against a catalogue (#17), every page of every app in every
// environment carried a link to a product that does not exist -- and
// gates/smoke.sh, which is the only gate that follows links, went red on the
// estate nav rather than on anything pdp serves.
//
// The app is the only thing that knows a real instance, and it already
// declares one: `probes` in routes.json, which gates/e2e.sh fetches for its
// ownership check and gates/lint-app.mjs validates lies inside the route it
// names. Read the same declaration here, so the nav and the gate cannot
// disagree about what a working instance of a route looks like. Substitution
// stays the fallback for routes whose parameters are still free.
const probe = (app, r) => (app.probes && app.probes[r])
  || r.replace(':sku', 'SKU1').replace(':category', 'shoes');

export function loadEstate(routesJsonPath, fallback) {
  try {
    return JSON.parse(readFileSync(routesJsonPath, 'utf8'))
      .sort((a, b) => a.port_offset - b.port_offset);
  } catch {
    return [fallback];
  }
}

// `extra` is an app-specific block rendered above the estate nav -- plp's
// results / no-results panel is the first user. It lives here rather than in
// plp's own copy of the document because the alternative was plp doing string
// surgery on the page this function returns, and a second renderer for the
// same chrome is how the two drift apart.
export function page(d, estate, background, extra = '') {
  const own = estate.map((a) =>
    `<div class=g><b>${a.app === d.app ? '▸ ' : ''}${esc(a.app)}</b> ` +
    a.routes.filter((r) => !SHARED_ROUTES.includes(r))
            .map((r) => probe(a, r))
            .map((p) => `<a href="${esc(p)}">${esc(p)}</a>`).join(' ') + '</div>').join('');
  const shared = SHARED_ROUTES.map((r) => `<a href="${r}">${r}</a>`).join(' ');
  return `<!doctype html><meta charset=utf-8><title>${esc(d.app)}</title>
<style>body{background:${background};font:14px/1.6 system-ui;margin:0;padding:40px}
main{max-width:40rem}code{background:#fff;padding:2px 6px;border-radius:3px}
a{margin-right:10px;display:inline-block}h1{margin:0 0 4px}
h2{margin:22px 0 2px;font-size:17px}
.g{margin:2px 0;font-size:13px}.g b{display:inline-block;width:5.5rem;color:#555}
.v{color:#999;font-size:11px;margin-top:22px}</style>
<main><h1>${esc(d.app)}</h1>
<p>served by <b>${esc(d.app)}</b> · path <code>${esc(d.path)}</code> · build <code>${esc(d.sha)}</code> · block <code>${esc(d.block)}</code></p>
${extra}
<p class=g style="color:#666;margin:14px 0 6px">every route, by the app that owns it — a link that changes the name above crossed to a sibling app:</p>
${own}
<p class=g style="color:#666;margin:18px 0 4px">shared surface — every app links back to core:</p>
<div class=g><b>core</b> ${shared}</div>
<p class=v>OneUI ${VERSION}</p>
</main>`;
}
