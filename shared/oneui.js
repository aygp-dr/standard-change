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
import { hostname } from 'node:os';

// 1.3.0 -- a `.b` badge class in the shared stylesheet. One line, and the
// smallest possible change that still redeploys every app: nothing in the
// surface changed, no function signature moved, and every app's output is
// byte-identical unless it uses the class. A MINOR rather than a patch because
// the stylesheet IS part of the surface -- an app may now rely on `.b` existing.
//
// 1.2.0 -- the page now states WHERE it is served from: host, port tier and
// environment (issue #15). A MINOR: `environment` and `HOST` are added to the
// surface and page() reads two new optional fields off `d`. Nothing was
// removed and page()'s required arity is unchanged, so an app that pins 1.1
// still renders -- it renders "unknown" for the tier, which is the honest
// answer for a caller that did not say what port it is listening on.
//
// 1.1.1 -- the estate nav no longer invents an instance of a parameterised
// route; it reads the one the app declares (`probes`), and escapes the href
// and app name it interpolates, which 1.0.1 missed because those come from
// config rather than the request line. A PATCH: a defect fix, no surface
// change. Inherited here unchanged.
//
// 1.1.0 -- page() gained an optional `extra` slot. A MINOR on top of the 1.0.1
// security patch, not a replacement for it: 1.0.1 escaped what page()
// interpolates and that escaping is inherited here unchanged. This release adds
// to the surface, which is why it is not a patch.
export const VERSION = '1.3.0';

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

// The machine, asked of the machine. Not process.env.HOSTNAME: a page that
// reports what it was told is the same defect as a tier read from the
// environment (below), one field over.
export const HOST = hostname();

// ---- where am I? ------------------------------------------------------------
//
// The footer used to end with `block <BLOCK>`, which is whatever string the
// deployer exported: sometimes a number, sometimes "staging", sometimes
// "production-blue", and never a statement of what KIND of environment this
// is. Staging and a dev block both rendered a correct-looking page and telling
// them apart meant reading x-build-sha out of the headers (issue #15).
//
// DERIVED FROM THE LISTENING PORT, ON PURPOSE. The tier could have been another
// environment variable next to BLOCK, and then the estate would report what it
// was told rather than what is true -- guard 5's defect, and the same shape as
// targets/bastille/deploy.sh stamping a SHA nobody built. The port a process is
// bound to is a fact about that process: it is read from the accepted socket
// (`req.socket.localPort`), not from PORT, so an app started with a lying PORT
// still reports the address it actually answers on.
//
// The ranges are the port map (spec.org, The port map; CLAUDE.md, Conventions).
const TIERS = [
  { lo: 9000, hi: 9099, tier: 'dev', note: 'disposable' },
  { lo: 9100, hi: 9199, tier: 'team', note: 'cannot promote' },
  { lo: 9200, hi: 9299, tier: 'protected', note: 'the path to production' },
];

// Within the protected tier the ten-port block names the environment, the same
// mapping targets/node/deploy.sh deploys by and gates/{e2e,smoke}.sh label by.
// The colour is a property of the block, so the page agrees with
// `targets/node/switch.sh status` without asking it -- and cannot be told it is
// the other colour.
const PROTECTED = {
  20: { env: 'staging' },
  21: { env: 'production', colour: 'blue' },
  22: { env: 'production', colour: 'green' },
  23: { env: 'production', note: 'front router' },
};

// A port -> everything the page can honestly say about where it is running.
// Unknown is a real answer: a port outside the project range (a test harness
// on an ephemeral port, something else entirely) must not be dressed up as a
// tier it is not in.
export function environment(port) {
  const p = Number(port);
  const t = Number.isInteger(p) && TIERS.find((x) => p >= x.lo && p <= x.hi);
  if (!t) return { port: Number.isInteger(p) && p > 0 ? p : null, block: null,
                   tier: 'unknown', note: 'outside the project port map',
                   env: null, colour: null };
  const block = Math.floor((p - 9000) / 10);
  const known = t.tier === 'protected' ? PROTECTED[block] : null;
  return {
    port: p,
    block,
    tier: t.tier,
    note: known && known.note ? `${t.note} — ${known.note}` : t.note,
    // Dev and team blocks have no name beyond their number: dev blocks are
    // claimed and released by ports.sh, team environments by IDP checkout, and
    // neither registry is readable from inside the process. The block number
    // is what is true, so the block number is what it says.
    env: known ? known.env : `block ${block}`,
    colour: (known && known.colour) || null,
  };
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

// The second footer line: which machine, which tier, which environment. Every
// value here is escaped like everything else page() interpolates -- d.host and
// d.port arrive from the caller, and "it comes from config" is exactly what was
// said about d.block before a request path proved the rule has no exceptions
// (issue #13).
//
// d.block is not thrown away, it is demoted: it moves to the version line at
// the bottom, labelled "declared", because that is what it is -- a string the
// deployer chose. Keeping it next to the derived tier would put a claim and a
// measurement side by side in the same typeface.
function whereLine(d) {
  const w = environment(d.port);
  const bits = [`<span class=t>${esc(w.tier)}</span>`];
  if (w.env) bits.push(esc(w.env));
  if (w.colour) bits.push(`<b>${esc(w.colour)}</b>`);
  return `<p class="e ${esc(w.tier)}" title="${esc(w.note)}">` +
    `${esc(d.host || '?')}:${esc(w.port ?? '?')} · ${bits.join(' · ')}</p>`;
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
.e{margin:-12px 0 0;font-size:13px;color:#555}
.e .t{font-weight:600;text-transform:uppercase;letter-spacing:.04em}
.e.dev .t{color:#6b7280}.e.team .t{color:#b45309}.e.protected .t{color:#b91c1c}
.v{color:#999;font-size:11px;margin-top:22px}
.b{background:#22c55e;color:#fff;font-size:11px;padding:2px 6px;border-radius:3px;vertical-align:middle;margin-right:6px}</style>
<main><h1>${esc(d.app)}</h1>
<p>served by <b>${esc(d.app)}</b> · path <code>${esc(d.path)}</code> · build <code>${esc(d.sha)}</code></p>
${whereLine(d)}
${extra}
<p class=g style="color:#666;margin:14px 0 6px">every route, by the app that owns it — a link that changes the name above crossed to a sibling app:</p>
${own}
<p class=g style="color:#666;margin:18px 0 4px">shared surface — every app links back to core:</p>
<div class=g><b>core</b> ${shared}</div>
<p class=v>OneUI ${VERSION} · declared block <code>${esc(d.block)}</code></p>
</main>`;
}
