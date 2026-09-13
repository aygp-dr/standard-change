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
  }));

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

async function schedule() {
  const out = await sh('./change/schedule.sh', ['list', '--open']);
  return out.split('\n').map((l) => l.trim()).filter(Boolean).map((l) => {
    const f = l.split(/\s+/);
    return { id: f[0], env: f[1], start: f[2], end: f[4], pr: f[5], sha: f.at(-1) };
  });
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
const FLAG_TTL_MS = 5 * 60 * 1000;
let flagCache = { at: 0, value: null };

async function estateFlags() {
  const age = Date.now() - flagCache.at;
  if (flagCache.value && age < FLAG_TTL_MS) {
    return { ...flagCache.value, cached: true, age_s: Math.round(age / 1000) };
  }
  const out = await sh('gh', ['pr', 'list', '--state', 'open', '--limit', '100',
    '--json', 'number,labels']);
  let value;
  if (!out) {
    // COULD NOT ASK IS NOT `NO FREEZE`. Same rule as preflight's exit 4: an
    // unreachable oracle is unknown, never negative.
    value = { freeze: null, emergency: null, freeze_prs: [], emergency_prs: [],
              unknown: true };
  } else {
    const prs = JSON.parse(out);
    const carries = (p, l) => p.labels.some((x) => x.name === l);
    const fz = prs.filter((p) => carries(p, 'freeze')).map((p) => p.number);
    const em = prs.filter((p) => carries(p, 'emergency') || carries(p, 'itil:emergency'))
                  .map((p) => p.number);
    value = { freeze: fz.length > 0, emergency: em.length > 0,
              freeze_prs: fz, emergency_prs: em, unknown: false, open_prs: prs.length };
  }
  flagCache = { at: Date.now(), value };
  return { ...value, cached: false, age_s: 0 };
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
  const cmp = JSON.stringify({ ...JSON.parse(s), at: null });
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
.swatch{display:inline-block;padding:2px 9px;border-radius:3px;font-size:11px;
font-weight:700;letter-spacing:.05em}
.sw-blue{background:#12233d;color:#93c5fd;border:1px solid #2563eb}
.sw-green{background:#11301c;color:#86efac;border:1px solid #16a34a}
.sw-none{color:#6b7280}
.team{color:#a78bfa;font-size:11px}.live{background:#16201380}
.bar{display:flex;gap:10px;align-items:center;margin:0 0 16px;flex-wrap:wrap}
.f{padding:5px 12px;border-radius:3px;font-weight:600;font-size:12px;letter-spacing:.03em}
.ok{background:#14301c;color:#4ade80;border:1px solid #1f5130}
.no{background:#3b1414;color:#fca5a5;border:1px solid #6b1f1f}
.unk{background:#312a14;color:#fbbf24;border:1px solid #5c4a1f}
.age{color:#6b7280;font-size:11px}
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
<p class=s><span id=ws>connecting…</span> · <a href="/api/status" style="color:#60a5fa">/api/status</a>
· every environment row is an HTTP request to that port, nothing read from a manifest</p>

<div id=alarm></div>
<div class=bar id=flags></div>

<h2>booked windows</h2>
<p class=s>the change schedule — this and the estate below are what an audit compares</p>
<table><thead><tr><th>id</th><th>env</th><th>opens</th><th>closes</th><th>pr</th><th>build</th></tr></thead><tbody id=w></tbody></table>

<h2>environments</h2>
<p class=s>declared in <code>environments.tsv</code>; state is probed live</p>
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
  h+='<span class=age>flags '+(f.cached?'cached '+esc(f.age_s)+'s ago':'just read')+
     ' · ttl 300s</span>';
  return h;
}
function alarms(d){
  const f=d.flags||{};const out=[];
  if(f.emergency)out.push('<div class="alarm emg">EMERGENCY IN FLIGHT'+
    '<div class=d>Declared on #'+esc(f.emergency_prs.join(', #'))+
    '. Standard and normal changes do not progress. Every window below is blocked '+
    'unless its change is classified itil:emergency.</div></div>');
  if(f.freeze)out.push('<div class="alarm frz">DEPLOYMENT FREEZE IN FORCE'+
    '<div class=d>Declared on #'+esc(f.freeze_prs.join(', #'))+
    '. One rule, two causes: a freeze blocks everyone including the PR carrying '+
    'the label. Only an emergency is exempt.</div></div>');
  if(f.unknown)out.push('<div class="alarm unkn">ESTATE STATE UNKNOWN'+
    '<div class=d>The forge could not be asked whether a freeze or emergency is '+
    'declared. This is NOT "no freeze" — unreachable is not falsified. Treat the '+
    'estate as closed until this clears.</div></div>');
  return out.join('');
}
function render(d){
  document.getElementById('alarm').innerHTML=alarms(d);
  document.getElementById('flags').innerHTML=flagbox(d);
  document.getElementById('w').innerHTML=d.windows.length?d.windows.map(x=>
    '<tr><td>'+esc(x.id)+'</td><td>'+esc(x.env)+'</td><td class=dim>'+esc(x.start)+'</td>'+
    '<td>'+esc(x.end)+'</td><td>'+esc(x.pr)+'</td><td class=sha>'+esc(x.sha)+'</td></tr>').join('')
    :'<tr><td colspan=6 class=dim>no open window — the berth is free</td></tr>';
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
ws.onopen =()=>document.getElementById('ws').textContent='live (websocket)';
ws.onclose=()=>{document.getElementById('ws').textContent='disconnected — polling every 10s';
  if(!window.__poll)window.__poll=setInterval(()=>fetch('/api/status').then(r=>r.json()).then(render),10000);};
ws.onmessage=e=>render(JSON.parse(e.data));
fetch('/api/status').then(r=>r.json()).then(render);
</script>`;

server.listen(PORT, HOST, () =>
  console.log(`idp dashboard on ${HOST}:${PORT} (ws + /api/status)`));
