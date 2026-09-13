import puppeteer from 'puppeteer-core';
const b = await puppeteer.launch({ executablePath: '/usr/local/bin/chrome',
  args: ['--no-sandbox','--disable-dev-shm-usage'] });
const p = await b.newPage();
await p.setViewport({ width: 1180, height: 1000, deviceScaleFactor: 2 });
const r = await p.goto('http://192.168.86.29:9999/', { waitUntil: 'networkidle0', timeout: 20000 });
await new Promise(s => setTimeout(s, 2500));
await p.screenshot({ path: process.argv[2], fullPage: true });
const rows = await p.$$eval('#w tr', t => t.length).catch(() => 0);
const envs = await p.$$eval('#e tr', t => t.length).catch(() => 0);
console.log(`HTTP ${r.status()}  windows=${rows}  envs=${envs}`);
await b.close();
