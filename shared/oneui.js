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

// 1.0.1 -- a patch, and deliberately not a minor: nothing was added to the
// surface. page() takes the same arguments and returns the same document for
// every input that was not already an injection. An app pinned to 1.0.0 is
// wrong about one thing only, and it is a security bug.
export const VERSION = '1.0.1';

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
const probe = (r) => r.replace(':sku', 'SKU1').replace(':category', 'shoes');

export function loadEstate(routesJsonPath, fallback) {
  try {
    return JSON.parse(readFileSync(routesJsonPath, 'utf8'))
      .sort((a, b) => a.port_offset - b.port_offset);
  } catch {
    return [fallback];
  }
}

export function page(d, estate, background) {
  const own = estate.map((a) =>
    `<div class=g><b>${a.app === d.app ? '▸ ' : ''}${a.app}</b> ` +
    a.routes.filter((r) => !SHARED_ROUTES.includes(r))
            .map((r) => `<a href="${probe(r)}">${probe(r)}</a>`).join(' ') + '</div>').join('');
  const shared = SHARED_ROUTES.map((r) => `<a href="${r}">${r}</a>`).join(' ');
  return `<!doctype html><meta charset=utf-8><title>${esc(d.app)}</title>
<style>body{background:${background};font:14px/1.6 system-ui;margin:0;padding:40px}
main{max-width:40rem}code{background:#fff;padding:2px 6px;border-radius:3px}
a{margin-right:10px;display:inline-block}h1{margin:0 0 4px}
.g{margin:2px 0;font-size:13px}.g b{display:inline-block;width:5.5rem;color:#555}
.v{color:#999;font-size:11px;margin-top:22px}</style>
<main><h1>${esc(d.app)}</h1>
<p>served by <b>${esc(d.app)}</b> · path <code>${esc(d.path)}</code> · build <code>${esc(d.sha)}</code> · block <code>${esc(d.block)}</code></p>
<p class=g style="color:#666;margin:14px 0 6px">every route, by the app that owns it — a link that changes the name above crossed to a sibling app:</p>
${own}
<p class=g style="color:#666;margin:18px 0 4px">shared surface — every app links back to core:</p>
<div class=g><b>core</b> ${shared}</div>
<p class=v>OneUI ${VERSION}</p>
</main>`;
}
