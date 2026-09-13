// IDP release dashboard -- what is on each environment, and what is booked.
//
// NO DEPENDENCIES. The repo forbids adding any, so the WebSocket is implemented
// against RFC 6455 directly: the handshake is a SHA-1 of the client key plus
// the magic GUID, and server->client text frames are unmasked with a 2-, 4- or
// 10-byte header depending on length. That is all this needs -- it only ever
// pushes small JSON payloads and never reads a frame from the client.
//
// THE DASHBOARD ASKS THE ESTATE. It does not read a manifest, a deployment
// record, or anything the deployer wrote. Every row comes from an HTTP request
// to the port in question, because a dashboard fed by the thing it is reporting
// on is the same defect as a gate whose oracle comes from the runner's tree.
// If a port is dark the row says dark; that is a fact about the estate, not an
// error in the dashboard.
import { createServer } from 'node:http';
import { createHash } from 'node:crypto';
import { execFile } from 'node:child_process';

const PORT = Number(process.env.PORT || 9999);
const HOST = process.env.BIND || '0.0.0.0';

// THE DECLARATION IS THE SOURCE. environments.tsv says what is NAMED; probing
// says what is RUNNING. Hardcoding the list here would make the dashboard a
// second, silently-diverging map -- the defect this repo keeps finding.
import { readFileSync } from 'node:fs';
const ENVS = readFileSync(new URL('../environments.tsv', import.meta.url), 'utf8')
  .split('\n')
  .filter((l) => l.trim() && !l.startsWith('#') && !l.startsWith('name\t'))
  .map((l) => l.split('\t'))
  .map(([name, tier, block, base_port, activated, promotes, note]) => ({
    name, tier, block: Number(block), port: Number(base_port),
    activated, promotes, note,
  }))
  // Highest port first, so the front -- the only address a customer reaches --
  // is the first row, then the two replicas behind it, then staging, then the
  // reservations and the dev blocks. Reading order matches blast radius.
  .sort((a, b) => b.port - a.port);

async function probe(env) {
  // A reservation is not expected to answer. Probing it and printing `dark`
  // would report an absence as a fault; `declared` is the true state.
  if (env.activated === 'no') {
    return { ...env, up: false, declared: true, status: null, sha: null, app: null, colour: null };
  }
  const url = `http://127.0.0.1:${env.port}/`;
  const ac = new AbortController();
  const t = setTimeout(() => ac.abort(), 1500);
  try {
    const r = await fetch(url, { signal: ac.signal, redirect: 'manual' });
    return {
      ...env, up: true, declared: false, status: r.status,
      sha: r.headers.get('x-build-sha') || null,
      app: r.headers.get('x-app') || null,
      colour: r.headers.get('x-colour') || null,
    };
  } catch {
    return { ...env, up: false, declared: false, status: null, sha: null, app: null, colour: null };
  } finally { clearTimeout(t); }
}

const sh = (cmd, args) => new Promise((res) =>
  execFile(cmd, args, { cwd: new URL('..', import.meta.url).pathname, timeout: 5000 },
    (e, out) => res(e ? '' : out)));

// WHAT the window is for, not just which number. A row reading `#42` makes the
// reader open GitHub to find out whether staging is held by a one-line copy
// tweak or a five-app release. The branch answers it in place.
const prMeta = new Map();
async function resolvePr(n) {
  if (prMeta.has(n)) return prMeta.get(n);
  const out = await sh('gh', ['pr', 'view', String(n), '--json', 'headRefName,title']);
  let v = { branch: null, title: null };
  if (out) { try { const j = JSON.parse(out); v = { branch: j.headRefName, title: j.title }; } catch {} }
  prMeta.set(n, v);
  return v;
}

async function schedule() {
  const out = await sh('./change/schedule.sh', ['list', '--open']);
  const rows = out.split('\n').map((l) => l.trim()).filter(Boolean).map((l) => {
    const f = l.split(/\s+/);
    const end = f[4];
    // SECONDS REMAINING, not just a wall-clock time. A soak is 300s and the
    // window is re-checked AFTER the walk (change/uat.sh), so a window with
    // less than a soak left is one the change cannot finish inside -- and the
    // failure lands at the very end, after the deploy and the full hold.
    // Printing the end time alone makes the operator do that subtraction, and
    // #38 is what happens when nobody does.
    const left = Math.round((Date.parse(end) - Date.now()) / 1000);
    // A COUNTDOWN ON A WINDOW THAT HAS NOT STARTED IS A LIE. Eight stacked
    // reservations all showed "Nm left" when only one of them was running; the
    // other seven were counting down to the end of a window they had not
    // entered. Time remaining is a fact about the CURRENT deployment and about
    // nothing else -- a future booking has a start time, not a remainder.
    const started = Date.now() >= Date.parse(f[2]);
    return { id: f[0], env: f[1], start: f[2], end, pr: f[5], started,
             groups: f.slice(6, -1).join(' '), sha: f.at(-1),
             closes_in_s: left, soak_fits: left > SOAK_S, expired: left <= 0 };
  });
  return Promise.all(rows.map(async (r) => ({
    ...r, ...(await resolvePr(Number(String(r.pr).replace('#', '')))),
  })));
}

// ESTATE FLAGS, CACHED. `freeze` and `emergency` are properties of the WORLD,
// not of the PR carrying them -- any open PR wearing one closes the estate to
// everyone, its own carrier included. They are read from the forge, which is
// slow and rate-limited, so the answer is cached for five minutes.
//
// THE CACHE IS SHOWN, NOT HIDDEN. A stale "no freeze" is exactly the reading
// that gets somebody hurt, so every payload carries how old the answer is and
// the page prints it. A dashboard that cannot say when it last looked is
// asserting a fact about now from a measurement about then.
const HOLDER = Number(process.env.ESTATE_ISSUE || 1);
// One soak plus the e2e+smoke walk that follows it. A window shorter than this
// cannot hold a complete staging leg.
const SOAK_S = Number(process.env.SOAK_SECONDS || 300) + 60;
const FLAG_TTL_MS = 5 * 60 * 1000;
let flagCache = { at: 0, value: null };

async function estateFlags() {
  const age = Date.now() - flagCache.at;
  if (flagCache.value && age < FLAG_TTL_MS) {
    // read_at, NOT age_s. An age is a CLOCK, and a clock inside the payload
    // makes the payload differ every tick -- which defeated "push only on
    // change" completely: from the first cache hit onward a full snapshot went
    // to every client every second, the exact behaviour the comment below says
    // teaches readers to ignore the feed. `at` was already excluded from the
    // diff for this reason; age_s was the same mistake nested one level down.
    // The client computes the age.
    return { ...flagCache.value, cached: true };
  }
  // THE HOLDER IS AN ISSUE, NOT A PULL REQUEST (issue #1).
  //
  // A PR carrying `emergency` is a change that the same write both blocks
  // everyone else for and exempts -- the carrier becomes the remedy by
  // construction (PR #48). An issue cannot be deployed, so there is no
  // exemption it could be handed and the bypass has nowhere to land.
  //
  // Open PRs are still read, because labels may linger on them from before the
  // holder existed and a freeze nobody can see is worse than a duplicated one.
  // They are reported SEPARATELY so the holder stays the authority.
  const out = await sh('gh', ['issue', 'view', String(HOLDER), '--json', 'labels']);
  const strays = await sh('gh', ['pr', 'list', '--state', 'open', '--limit', '100',
    '--json', 'number,labels']);
  let value;
  if (!out) {
    // COULD NOT ASK IS NOT `NO FREEZE`. Same rule as preflight's exit 4: an
    // unreachable oracle is unknown, never negative.
    value = { freeze: null, emergency: null, freeze_prs: [], emergency_prs: [],
              unknown: true, holder: HOLDER, read_at: new Date().toISOString() };
  } else {
    const held = JSON.parse(out).labels.map((x) => x.name);
    const carries = (p, l) => p.labels.some((x) => x.name === l);
    let prs = [];
    try { prs = JSON.parse(strays || '[]'); } catch { prs = []; }
    const fz = prs.filter((p) => carries(p, 'freeze')).map((p) => p.number);
    const em = prs.filter((p) => carries(p, 'emergency')).map((p) => p.number);
    value = {
      holder: HOLDER,
      freeze: held.includes('freeze'),
      emergency: held.includes('emergency'),
      // Strays are NOT folded into the verdict. A label left on a PR is a
      // cleanup problem; letting it silently close the estate would restore the
      // exact ambiguity the holder exists to remove.
      freeze_prs: fz, emergency_prs: em,
      unknown: false, open_prs: prs.length,
      read_at: new Date().toISOString(),
    };
  }
  flagCache = { at: Date.now(), value };
  return { ...value, cached: false };
}

async function snapshot() {
  const [envs, windows, flags] = await Promise.all([
    Promise.all(ENVS.map(probe)), schedule().catch(() => []),
    estateFlags().catch(() => ({ freeze: null, emergency: null, unknown: true,
                                 freeze_prs: [], emergency_prs: [], cached: false, age_s: 0 })),
  ]);
  // The estate is COHERENT when every protected environment that is up agrees
  // with what the front is serving. Disagreement is not an error -- mid-cutover
  // it is the expected state -- so it is reported, not flagged.
  const front = envs.find((e) => e.name === 'front');
  return {
    at: new Date().toISOString(),
    flags,
    live_colour: front?.colour ?? null,
    live_sha: front?.sha ?? null,
    envs, windows,
  };
}

// ---- WebSocket (RFC 6455), server->client text frames only ----------------
const GUID = '258EAFA5-E914-47DA-95CA-5AB0DC85B11C';
const clients = new Set();

function frame(text) {
  const b = Buffer.from(text);
  const n = b.length;
  let head;
  if (n < 126) { head = Buffer.from([0x81, n]); }
  else if (n < 65536) { head = Buffer.alloc(4); head[0] = 0x81; head[1] = 126; head.writeUInt16BE(n, 2); }
  else { head = Buffer.alloc(10); head[0] = 0x81; head[1] = 127; head.writeBigUInt64BE(BigInt(n), 2); }
  return Buffer.concat([head, b]);
}

const server = createServer(async (req, res) => {
  const send = (code, type, body) => {
    res.writeHead(code, { 'content-type': type, 'cache-control': 'no-store' });
    res.end(body);
  };
  // TOGGLE. A write, so it is POST only and it says what it did. The cache is
  // invalidated immediately rather than left to expire: a five-minute-stale
  // "no freeze" straight after somebody declared one is the exact reading that
  // gets a change deployed into a closed estate.
  if (req.method === 'POST' && req.url?.startsWith('/api/estate/')) {
    const [, , , label, action] = req.url.split('/');
    if (!['freeze', 'emergency'].includes(label) || !['on', 'off'].includes(action))
      return send(400, 'application/json', JSON.stringify({ error: 'bad toggle' }));
    const flag = action === 'on' ? '--add-label' : '--remove-label';
    const r = await sh('gh', ['issue', 'edit', String(HOLDER), flag, label]);
    await sh('gh', ['issue', 'comment', String(HOLDER), '--body',
      `\`${label}\` turned **${action}** from the IDP dashboard at ${new Date().toISOString()}.`]);
    flagCache = { at: 0, value: null };
    const s2 = await snapshot();
    for (const c of clients) { try { c.write(frame(JSON.stringify(s2))); } catch { clients.delete(c); } }
    return send(r === '' && action === 'on' ? 500 : 200, 'application/json',
      JSON.stringify({ ok: true, label, action, flags: s2.flags }, null, 2));
  }
  if (req.url === '/api/status') return send(200, 'application/json', JSON.stringify(await snapshot(), null, 2));
  if (req.url === '/healthz') return send(200, 'application/json', JSON.stringify({ ok: true }));
  if (req.url !== '/') return send(404, 'text/plain', 'not found');
  send(200, 'text/html; charset=utf-8', PAGE);
});

server.on('upgrade', (req, socket) => {
  const key = req.headers['sec-websocket-key'];
  if (!key) return socket.destroy();
  const accept = createHash('sha1').update(key + GUID).digest('base64');
  socket.write(
    'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n' +
    `Connection: Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\n\r\n`);
  clients.add(socket);
  socket.on('close', () => clients.delete(socket));
  socket.on('error', () => clients.delete(socket));
  snapshot().then((s) => socket.write(frame(JSON.stringify(s))));
});

// PUSH ONLY ON CHANGE. A dashboard that re-sends an identical payload every few
// seconds teaches its readers to ignore it, and hides the one update that
// matters inside a stream of ones that do not.
let last = '';
setInterval(async () => {
  const s = JSON.stringify(await snapshot());
  // Both clocks nulled: the snapshot's own `at`, and the flags' read_at.
  const p = JSON.parse(s);
  const cmp = JSON.stringify({ ...p, at: null, flags: { ...p.flags, read_at: null } });
  if (cmp === last) return;
  last = cmp;
  for (const c of clients) { try { c.write(frame(s)); } catch { clients.delete(c); } }
}, 1000);

const PAGE = `<!doctype html><meta charset=utf-8><title>IDP release dashboard</title>
<style>
body{background:#0f1117;color:#e6e6e6;font:13px/1.55 ui-monospace,Menlo,monospace;margin:0;padding:26px}
h1{font-size:15px;margin:0 0 2px}h2{font-size:13px;margin:26px 0 2px;color:#c9d1d9}
.s{color:#8b93a7;font-size:12px;margin:0 0 14px}
table{border-collapse:collapse;width:100%;max-width:74rem;margin-bottom:8px}
th{text-align:left;font-weight:600;color:#8b93a7;font-size:11px;text-transform:uppercase;
letter-spacing:.06em;border-bottom:1px solid #262a35;padding:0 12px 6px 0}
td{padding:5px 12px 5px 0;border-bottom:1px solid #1a1d26}
.up{color:#4ade80}.down{color:#f87171}.dim{color:#6b7280}.decl{color:#7c6f9e}
.sha{color:#fbbf24}.prot{color:#f87171;font-size:11px}.dev{color:#6b7280;font-size:11px}
/* THE COLOUR IS THE ENVIRONMENT'S IDENTITY, not decoration. staging is orange
   because it is the one protected environment that is NOT production and the
   distinction has been mistaken before (this repo shipped a port map calling
   9200 production). front is red because it is the only thing a customer
   actually reaches, and it is never deployed to directly -- it reads the live
   colour per request. blue and green are named for their colour, so they wear
   it: a row whose name and swatch disagree is a bug you can see. */
.n-staging{color:#fb923c;font-weight:600}
.n-production-blue{color:#60a5fa;font-weight:600}
.n-production-green{color:#4ade80;font-weight:600}
.n-front{color:#f87171;font-weight:700}
/* Dev blocks grey: present, disposable, and deliberately not competing with
   the protected rows for attention. Team placeholders stay default -- they are
   reservations, and greying them would read as "running but unimportant"
   rather than "declared, nothing there". */
.n-dev-0,.n-dev-1,.n-dev-2,.n-dev-3,.n-dev-4,
.n-dev-5,.n-dev-6,.n-dev-7,.n-dev-8,.n-dev-9{color:#6b7280}
.swatch{display:inline-block;padding:2px 9px;border-radius:3px;font-size:11px;
font-weight:700;letter-spacing:.05em}
.sw-blue{background:#12233d;color:#93c5fd;border:1px solid #2563eb}
.sw-green{background:#11301c;color:#86efac;border:1px solid #16a34a}
.sw-none{color:#6b7280}
.team{color:#a78bfa;font-size:11px}.live{background:#16201380}
tr.active{background:#1b2740}
tr.active td{border-bottom-color:#2f4468}
tr.active td:first-child{box-shadow:inset 3px 0 0 #60a5fa}
.bar{display:flex;gap:10px;align-items:center;margin:0 0 16px;flex-wrap:wrap}
.st{padding:5px 13px;border-radius:3px;font-weight:700;font-size:12px;letter-spacing:.05em}
.ok{background:#14301c;color:#4ade80;border:1px solid #1f5130}
.no{background:#3b1414;color:#fca5a5;border:1px solid #6b1f1f}
.unk{background:#312a14;color:#fbbf24;border:1px solid #5c4a1f}
.age{color:#6b7280;font-size:11px}
.br{color:#60a5fa;font-size:11px;margin-left:6px}
.ti{color:#8b93a7;font-size:11px;margin-top:2px}
.rem-ok{color:#4ade80;font-size:11px;margin-left:8px}
.rem-warn{color:#fbbf24;font-size:11px;margin-left:8px}
.rem-bad{color:#f87171;font-size:11px;font-weight:700;margin-left:8px}
button{font:inherit;font-size:12px;padding:5px 12px;border-radius:3px;cursor:pointer;
background:#1a1d26;color:#c9d1d9;border:1px solid #30363d}
button:hover{background:#232733}
button.b-freeze{border-color:#2563eb;color:#93c5fd}
button.b-freeze:hover{background:#12233d}
button.b-emergency{border-color:#b91c1c;color:#fca5a5}
button.b-emergency:hover{background:#3b1414}
/* LIFTING IS ITS OWN COLOUR. Once declared, the button no longer declares --
   it undoes. Leaving it blue or red made the control that REMOVES a freeze look
   identical to the one that IMPOSES it, which is the one confusion here with a
   real cost. White, and it wins over the label colour. */
button.on,button.b-freeze.on,button.b-emergency.on{
  background:#f3f4f6;color:#0f1117;border-color:#f3f4f6;font-weight:600}
button.on:hover,button.b-freeze.on:hover,button.b-emergency.on:hover{
  background:#ffffff;border-color:#ffffff}
/* An emergency or a freeze is a property of the WORLD. It does not sit in a
   row of chips beside "no emergency" -- when it is true it is the first and
   largest thing on the page, because every other number here is conditional
   on it. */
.alarm{margin:0 0 16px;padding:14px 18px;border-radius:4px;font-size:15px;font-weight:700;
letter-spacing:.04em;max-width:74rem}
.alarm .d{font-weight:400;font-size:12px;letter-spacing:0;margin-top:5px;opacity:.85}
.emg{background:#4a1010;color:#fecaca;border:2px solid #b91c1c}
.frz{background:#3a2a08;color:#fde68a;border:2px solid #b45309}
.unkn{background:#2a2520;color:#fbbf24;border:2px dashed #7c5f1f}
</style>
<h1>IDP release dashboard</h1>


<div id=alarm></div>
<div class=bar id=flags></div>

<h2>booked windows</h2>
<table><thead><tr><th>change</th><th>groups</th><th>build</th><th>window</th><th>env</th><th>window id</th></tr></thead><tbody id=w></tbody></table>

<h2>environments</h2>
<table><thead><tr><th>environment</th><th>tier</th><th>port</th><th>state</th><th>build</th><th>app</th><th>colour</th><th>promotes</th></tr></thead><tbody id=e></tbody></table>
<script>
const esc=s=>String(s??'').replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
function flagbox(d){
  const f=d.flags||{};
  const cell=(label,state,extra)=>'<span class="f '+state+'">'+esc(label)+'</span>'+
    (extra?'<span class=age>'+esc(extra)+'</span>':'');
  let h='';
  if(f.unknown) h+=cell('ESTATE UNKNOWN','unk','could not ask the forge — this is not "no freeze"');
  else{
    h+=f.freeze?cell('FREEZE IN FORCE','no','declared on #'+f.freeze_prs.join(', #'))
               :cell('no freeze','ok');
    h+=f.emergency?cell('EMERGENCY IN FLIGHT','no','on #'+f.emergency_prs.join(', #'))
                  :cell('no emergency','ok');
  }
  const age=f.read_at?Math.round((Date.now()-Date.parse(f.read_at))/1000):0;
  h+='<span class=age>flags '+(f.cached?'cached '+esc(age)+'s ago':'just read')+
     ' · ttl 300s · holder #'+esc(f.holder)+'</span>';
  const stray=[...(f.freeze_prs||[]),...(f.emergency_prs||[])];
  if(stray.length)h+='<span class="f unk">STRAY LABELS on #'+esc(stray.join(', #'))+
    '</span><span class=age>estate labels left on pull requests. They do NOT count '+
    'toward the verdict — the holder is the authority — but they should be cleaned up.</span>';
  return h;
}
function hms(s){const m=Math.floor(Math.abs(s)/60),r=Math.abs(s)%60;
  return (s<0?'-':'')+(m?m+'m ':'')+r+'s';}
function remain(x){
  if(x.expired)return '<span class=rem-bad>EXPIRED</span>';
  // Not started: it has a start time, not a remainder.
  if(!x.started)return '<span class=dim>'+esc(x.start)+'</span>';
  // Running: the remainder is the only number that matters, and the colour is
  // about whether this deployment can still finish, not about the clock.
  const s=x.closes_in_s;
  const c=s<60?'rem-bad':s<150?'rem-warn':'rem-ok';
  return '<span class='+c+'>'+esc(hms(s))+' left</span>';
}
// A BANNER ONLY WHEN THERE IS SOMETHING TO SAY. The previous version printed a
// banner, a chip and a button for the same fact, and the banner's "Declared on
// #" was left over from when the holder was a PR -- the issue holds it now, so
// the PR list is empty and it rendered a bare hash. A banner that is always
// there is furniture; one that appears only when the estate is shut is a signal.
function banner(d){
  const f=d.flags||{};const o=[];
  if(f.unknown)o.push(['unkn','ESTATE UNKNOWN',
    'Issue #'+f.holder+' could not be read. This is NOT "open" — treat the estate '+
    'as shut until it clears.']);
  if(f.emergency)o.push(['emg','EMERGENCY IN FLIGHT',
    'Every window below is blocked unless its change is classified itil:emergency.']);
  if(f.freeze)o.push(['frz','DEPLOYMENT FREEZE IN FORCE',
    'Blocks everyone, including whoever declared it. Only itil:emergency passes.']);
  return o.map(([c,t,d2])=>'<div class="alarm '+c+'">'+esc(t)+
    '<div class=d>'+esc(d2)+'</div></div>').join('');
}
function estate(d){
  const f=d.flags||{};
  if(f.unknown)return '<span class="st unk">ESTATE UNKNOWN</span>'+
    '<span class=age>could not read issue #'+esc(f.holder)+' — this is not "open"</span>';
  const on=[];
  if(f.freeze)on.push('<span class="st no">FREEZE</span>');
  if(f.emergency)on.push('<span class="st no">EMERGENCY</span>');
  if(!on.length)on.push('<span class="st ok">ESTATE OPEN</span>');
  // THE COLOUR IS THE LABEL'S, NOT THE STATE'S. Freeze is blue: it is a
  // planned, reversible gate -- a maintenance slot, a release embargo -- and
  // nothing is on fire. Emergency is red: something is wrong in the world right
  // now. Colouring both by whether they are currently on made the two look like
  // the same control in two states, and they are not the same decision.
  const btn=(l,v)=>'<button class="b-'+l+(v?' on':'')+'" data-label="'+l+
    '" data-action="'+(v?'off':'on')+'">'+(v?'lift ':'declare ')+l+'</button>';
  const age=f.read_at?Math.round((Date.now()-Date.parse(f.read_at))/1000):0;
  const stray=[...(f.freeze_prs||[]),...(f.emergency_prs||[])];
  return on.join('')+btn('freeze',f.freeze)+btn('emergency',f.emergency)+
    '<span class=age>issue #'+esc(f.holder)+' · read '+esc(age)+'s ago'+
    (f.freeze||f.emergency?' · only itil:emergency passes':'')+'</span>'+
    (stray.length?'<span class="st unk">stray labels on #'+esc(stray.join(', #'))+
      '</span><span class=age>on PRs, not counted — clean up</span>':'');
}
function render(d){
  document.getElementById('alarm').innerHTML=banner(d);
  document.getElementById('flags').innerHTML=estate(d);
  document.getElementById('w').innerHTML=d.windows.length?d.windows.map(x=>
    // THE ONE THAT IS RUNNING LOOKS DIFFERENT. Eight stacked reservations read
    // as eight equal rows; exactly one of them holds the berth right now, and
    // that is the only row anybody is acting on.
    '<tr class="'+(x.started&&!x.expired?'active':'')+'"><td><b>'+esc(x.pr)+'</b>'+(x.branch?' <span class=br>'+esc(x.branch)+'</span>':'')+
    (x.title?'<div class=ti>'+esc(x.title)+'</div>':'')+'</td>'+
    '<td class=dim>'+esc(x.groups||'—')+'</td>'+
    '<td class=sha>'+esc(x.sha)+'</td>'+
    '<td>'+remain(x)+'</td>'+
    '<td class=n-'+esc(x.env)+'>'+esc(x.env)+'</td>'+
    '<td class=dim>'+esc(x.id)+'</td></tr>').join('')
    // "no open window" and "the berth is free" are not the same claim. This
    // lists UNRESOLVED reservations -- a window whose end has passed but which
    // nobody closed is still listed, and an empty list means nobody holds a
    // reservation, not that a deploy could start right now (a freeze, an
    // emergency or a held berth all still refuse). Say the narrow true thing.
    :'<tr><td colspan=6 class=dim>no reservation — nobody has booked staging</td></tr>';
  document.getElementById('e').innerHTML=d.envs.map(x=>{
    const state=x.declared?'<td class=decl>declared</td>'
      :'<td class='+(x.up?'up':'down')+'>'+(x.up?'up '+esc(x.status):'dark')+'</td>';
    // The colour cell means two different things and must not pretend
    // otherwise. On the FRONT it is the ACTIVATED colour -- which replica is
    // serving customers right now. On blue or green it is only that replica
    // naming itself, which tells you nothing about what is live.
    let col='<td class=sw-none>—</td>';
    if(x.name==='front'&&x.colour)
      col='<td><span class="swatch sw-'+esc(x.colour)+'">'+esc(x.colour).toUpperCase()+
          ' LIVE</span></td>';
    else if(x.colour)
      col='<td class=dim>'+esc(x.colour)+'</td>';
    return '<tr class="'+(x.sha&&x.sha===d.live_sha&&x.tier==='protected'?'live':'')+'">'+
    '<td class="n-'+esc(x.name)+'">'+esc(x.name)+'</td><td class='+esc(x.tier)+'>'+esc(x.tier)+'</td>'+
    '<td class=dim>'+esc(x.port)+'</td>'+state+
    '<td class=sha>'+esc(x.sha||'—')+'</td><td class=dim>'+esc(x.app||'—')+'</td>'+
    col+'<td class=dim>'+esc(x.promotes)+'</td></tr>';}).join('');
}
const ws=new WebSocket((location.protocol==='https:'?'wss':'ws')+'://'+location.host+'/');
ws.onopen =()=>{};
ws.onclose=()=>{
  if(!window.__poll)window.__poll=setInterval(()=>fetch('/api/status').then(r=>r.json()).then(render),10000);};
ws.onmessage=e=>render(JSON.parse(e.data));
document.addEventListener('click',e=>{
  const b=e.target.closest('button[data-label]');
  if(b)toggle(b.dataset.label,b.dataset.action);
});
fetch('/api/status').then(r=>r.json()).then(render);
</script>`;

server.listen(PORT, HOST, () =>
  console.log(`idp dashboard on ${HOST}:${PORT} (ws + /api/status)`));
