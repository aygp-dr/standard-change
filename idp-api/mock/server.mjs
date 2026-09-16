#!/usr/bin/env node
// server.mjs -- an in-memory IDP that speaks idp-api/openapi.yaml.
//
// A MOCK, and it says so in every response header (x-idp-mock: 1). It holds
// the label machine of tla/Labels.tla in a Map instead of the forge, so the
// three clients (web.html, tui.py, standard-change.el) can be built against
// the contract before the real verbs exist over change/*.sh. The guards are
// the model's twelve rules; refusals carry fact, cost, recovery and berth.
//
//   node idp-api/mock/server.mjs            # :9998
//   IDP_PORT=9997 node idp-api/mock/server.mjs
//
// Nothing here deploys. Settlement takes observations and renders a verdict;
// activation is a POST the scheduler makes; the boundary is a person's act.
import { createServer } from "node:http";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const PORT = Number(process.env.IDP_PORT || 9998);
const now = () => new Date().toISOString().replace(/\.\d+Z$/, "Z");
const plus = (min) => new Date(Date.now() + min * 60_000).toISOString().replace(/\.\d+Z$/, "Z");

// ---- state: a few changes seeded from the repo's own PR list ---------------
const changes = new Map();
const seed = (pr, cls, groups, head, extra = {}) =>
  changes.set(String(pr), {
    id: String(pr), pr, class: cls, lifecycle: "opened", head, draft: false,
    approved: true, groups, labels: [`itil:${cls}`, ...groups.map((g) => `app:${g}`)],
    window: null, lease: null,
    observations: { staging: "none", uat: false, production: "none" }, merged: false, ...extra,
  });
seed(62, "standard", ["pdp"], "a1b2c3d");
seed(59, "standard", ["plp"], "b2c3d4e");
seed(71, "normal", ["checkout"], "fc2ee1b");
seed(80, "normal", ["control-plane"], "c3d4e5f", { labels: ["itil:normal", "control-plane"] });
seed(99, "emergency", ["core"], "e5f6a7b", { labels: ["itil:emergency", "app:core"] });
let boundary = { state: "open", freeze: null, emergency: null };
const windows = [];
const idem = new Map();
let seq = 0;

const holder = () => [...changes.values()].find((c) => c.lease);
const refusal = (code, refused, fact, cost, recovery, exit) => ({
  code, body: { refused, fact, cost, recovery, exit,
    berth: holder() ? `HELD by #${holder().pr} until ${holder().lease.expires_at}` : "not held" } });

// ---- the verbs -------------------------------------------------------------
function reserve(c, body) {
  if (c.lifecycle === "scheduled" || c.window) return refusal(409, "usage", `#${c.pr} already holds window ${c.window.id}`, "two windows for one change is two records of one fact", "DELETE the reservation first", 2);
  if (["complete", "failed", "backed-out"].includes(c.lifecycle)) return refusal(422, "usage", `#${c.pr} is ${c.lifecycle}`, "a change that has landed does not need a window", "open a new change", 2);
  if (!body?.groups?.length) return refusal(422, "usage", "no groups", "nothing to deploy", "send groups from app:*", 2);
  const mins = Number(body.minutes || 30);
  const open = windows.filter((w) => w.result === null && w.env === (body.env || "staging"));
  const start = body.at || (open.length ? open[open.length - 1].end : plus(0));
  const end = new Date(new Date(start).getTime() + mins * 60_000).toISOString().replace(/\.\d+Z$/, "Z");
  const clash = open.find((w) => w.start < end && w.end > start);
  if (clash) return refusal(409, "guard-1", `${body.at ? "the named hour" : "the slot"} collides with ${clash.id}`, "a named hour does not win a clash", `pick another hour, or wait: ${clash.id} ends ${clash.end}`, 5);
  const w = { id: `CHG-${start.replace(/[-:]/g, "").slice(0, 13)}-${c.pr}.${++seq}`, change: c.id, env: body.env || "staging",
    start, end, mode: body.at ? "designated" : "queued", result: null, sha: c.head };
  windows.push(w); c.window = w; c.lifecycle = "scheduled";
  c.labels = c.labels.filter((l) => l !== "release:started").concat("release:scheduled");
  return { code: 201, body: w };
}

function activate(c) {
  const emg = c.class === "emergency";
  if (c.draft) return refusal(409, "draft", "the author says it is not ready", "an urgent unfinished change is still unfinished", "gh pr ready", 6);
  if (c.class === "undefined") return refusal(409, "class", "this change has two classes", "every rule below branches on the class", "a person removes the class that is wrong", 2);
  if (!c.window || c.window.result !== null) return refusal(409, "guard-3", "no open window covers now", "the calendar is what tells everyone the path is occupied", "reserve a window", 7);
  if (boundary.state === "frozen" && !emg) return refusal(423, "boundary", `a DEPLOYMENT FREEZE is in force (${boundary.freeze.reason})`, "standard and normal changes do not progress during a freeze", "wait for it to lift, or a person declares this itil:emergency", 3);
  if (boundary.state === "emergency" && !emg) return refusal(423, "boundary", `an EMERGENCY is in flight (#${boundary.emergency.change})`, "it will land under you and invalidate your staging pass", "wait for the estate to reopen", 2);
  const h = holder();
  if (h && h.id !== c.id) return refusal(423, "guard-1", `staging held by #${h.pr}`, "one change holds staging", emg ? "declare the emergency on the boundary; the holder is evicted" : `wait for #${h.pr} to settle or expire`, 5);
  if (c.lease) return { code: 201, body: c.lease };
  c.lease = { id: `brth_${Math.random().toString(16).slice(2, 6)}`, change: c.id, env: c.window.env, activated_at: now(), expires_at: c.window.end, revalidate: false };
  c.lifecycle = "implementing"; c.labels.push("deploy:staging");
  return { code: 201, body: c.lease };
}

function settle(c, body) {
  if (!c.lease || body?.lease !== c.lease.id) return refusal(412, "cas", "that lease is not the berth's", "a settlement must name the lease it holds", "activate, then settle with the lease returned", 9);
  const obs = body.observations || [];
  if (!obs.length) return refusal(422, "usage", "no observations", "a settlement without evidence is a claim", "probe /version.json and send what you saw", 2);
  const seen = [...new Set(obs.map((o) => o.build))];
  if (seen.length !== 1 || seen[0] !== body.claimed_build)
    return { code: 409, body: { state: "unconverged", distinct_builds: seen.length, seen, detail: "the estate is serving more than one build; re-running will not change it" } };
  c.observations.production = "healthy"; c.lifecycle = "complete"; c.merged = true;
  if (c.window) c.window.result = "passed";
  c.lease = null; c.window = null;
  c.labels = c.labels.filter((l) => !/^(deploy:|staging:|production:|change:|release)/.test(l));
  return { code: 202, body: { state: "settled", attested_by: "convergence-probe", confidence: "sampled", samples: obs.length, distinct_builds: 1, merged: true, pir: `#${c.pr} (comment)` } };
}

function closure(c, body) {
  if (!["failed", "backed-out"].includes(body?.code)) return refusal(422, "usage", "closure code must be failed or backed-out", "ITIL closure codes are a closed set", "send one of the two", 2);
  if (body.code === "backed-out" && !body.to) return refusal(422, "usage", "backed-out without `to`", "the word asserts an estate action", "name the sha production was returned to", 2);
  if (c.window && c.window.result === null) c.window.result = "failed";
  c.lease = null; c.window = null; c.lifecycle = body.code;
  c.labels = c.labels.filter((l) => !/^(deploy:|staging:|production:|release:scheduled|release)/.test(l)).concat(`change:${body.code}`);
  return { code: 200, body: c };
}

function evictFor(e) {
  const h = holder();
  if (!h || h.id === e.id || h.class === "emergency" || h.labels.includes("deploy:production")) return [];
  h.lease = null; h.lifecycle = "opened";
  if (h.window) { h.window.result = "cancelled"; }
  const w = h.window; h.window = null; h.observations = { staging: "none", uat: false, production: "none" };
  h.labels = h.labels.filter((l) => !/^(deploy:staging|staging:|release:scheduled)/.test(l));
  return [{ change: h.id, window: w?.id, reason: `evicted by emergency #${e.pr}: loses the berth, the window and its observations; keeps class, approval and head; not closed` }];
}

function reap() {
  const t = now(), reaped = [], spared = [];
  for (const w of windows) {
    if (w.result !== null || w.end >= t) continue;
    const c = changes.get(w.change);
    if (c?.labels.includes("deploy:production") || c?.merged) { spared.push(w); continue; }
    w.result = "expired"; reaped.push(w);
    if (c) { c.window = null; c.lease = null; c.lifecycle = "opened"; c.labels = c.labels.filter((l) => !/^(release:scheduled|deploy:staging)$/.test(l)); }
  }
  return { code: 200, body: { reaped, spared } };
}

// ---- http ------------------------------------------------------------------
const json = (res, code, body) => {
  res.writeHead(code, { "content-type": "application/json", "x-idp-mock": "1", "access-control-allow-origin": "*" });
  res.end(JSON.stringify(body, null, 2));
};
const read = (req) => new Promise((ok) => { let b = ""; req.on("data", (d) => (b += d)); req.on("end", () => { try { ok(b ? JSON.parse(b) : {}); } catch { ok(null); } }); });

createServer(async (req, res) => {
  const url = new URL(req.url, "http://x");
  const p = url.pathname, m = req.method;
  if (m === "GET" && (p === "/" || p === "/web.html")) {
    res.writeHead(200, { "content-type": "text/html; charset=utf-8", "x-idp-mock": "1" });
    return res.end(readFileSync(join(here, "web.html")));
  }
  if (m === "GET" && p === "/openapi.yaml") {
    res.writeHead(200, { "content-type": "application/yaml", "x-idp-mock": "1" });
    return res.end(readFileSync(join(here, "..", "openapi.yaml")));
  }
  if (m === "GET" && p === "/changes") return json(res, 200, [...changes.values()]);
  if (m === "GET" && p === "/schedule") return json(res, 200, { windows: url.searchParams.get("open") ? windows.filter((w) => w.result === null) : windows, boundary: { ...boundary, berth: holder() ? { held_by: holder().id, lease: holder().lease.id } : null } });
  if (m === "POST" && p === "/schedule/reap") { const r = reap(); return json(res, r.code, r.body); }
  if (p === "/boundary" && m === "GET") return json(res, 200, { ...boundary, berth: holder() ? { held_by: holder().id, lease: holder().lease.id } : null });
  if (p === "/boundary/freeze") {
    if (m === "PUT") { const b = await read(req); boundary = { state: "frozen", freeze: { reason: b?.reason || "unstated", since: now(), until: b?.until || null, by: "a person" }, emergency: null }; return json(res, 200, boundary); }
    if (m === "DELETE") { boundary = { state: "open", freeze: null, emergency: null }; return json(res, 200, boundary); }
  }
  if (p === "/boundary/emergency") {
    if (m === "PUT") {
      const b = await read(req); const e = changes.get(String(b?.change || "").replace("#", ""));
      if (!e) return json(res, 404, { refused: "usage", fact: "no such change", cost: "an emergency must name its fix", recovery: "send the PR number", berth: "n/a", exit: 2 });
      if (e.class !== "emergency") return json(res, 409, { refused: "class", fact: `#${e.pr} is itil:${e.class}`, cost: "only a person's declaration makes an emergency", recovery: "add itil:emergency to the change first", berth: holder() ? "HELD" : "not held", exit: 1 });
      boundary = { state: "emergency", freeze: null, emergency: { change: e.id, reason: b.reason || "unstated", since: now(), by: "a person" } };
      const ready = e.window && e.window.result === null && !e.draft;
      const evicted = ready ? evictFor(e) : [];
      return json(res, 200, { ...boundary, evicted, note: ready ? undefined : "the emergency is not booked and ready; nothing evicted, entry is blocked" });
    }
    if (m === "DELETE") { boundary = { state: "open", freeze: null, emergency: null }; return json(res, 200, boundary); }
  }
  const mm = p.match(/^\/changes\/#?(\d+)(?:\/(reservation|activation|settlement|closure))?$/);
  if (mm) {
    const c = changes.get(mm[1]);
    if (!c) return json(res, 404, { refused: "usage", fact: `no change #${mm[1]}`, cost: "", recovery: "", berth: "n/a", exit: 2 });
    if (!mm[2] && m === "GET") return json(res, 200, c);
    const key = req.headers["idempotency-key"];
    if (m === "POST" && !key) return json(res, 422, { refused: "usage", fact: "Idempotency-Key missing", cost: "a retried activation must not re-run the guards", recovery: "send one", berth: "n/a", exit: 2 });
    if (m === "POST" && idem.has(key)) return json(res, ...idem.get(key));
    let r;
    if (mm[2] === "reservation" && m === "POST") r = reserve(c, await read(req));
    else if (mm[2] === "reservation" && m === "DELETE") { if (!c.window) return res.writeHead(404).end(); c.window.result = "cancelled"; c.window = null; c.lifecycle = "opened"; c.labels = c.labels.filter((l) => l !== "release:scheduled"); return res.writeHead(204).end(); }
    else if (mm[2] === "activation" && m === "POST") r = activate(c);
    else if (mm[2] === "settlement" && m === "POST") r = settle(c, await read(req));
    else if (mm[2] === "closure" && m === "POST") r = closure(c, await read(req));
    if (r) { idem.set(key, [r.code, r.body]); return json(res, r.code, r.body); }
  }
  json(res, 404, { refused: "usage", fact: `${m} ${p} is not in the contract`, cost: "", recovery: "GET /openapi.yaml", berth: "n/a", exit: 2 });
}).listen(PORT, "127.0.0.1", () => console.log(`idp mock on http://127.0.0.1:${PORT}  (web: /, contract: /openapi.yaml)`));
