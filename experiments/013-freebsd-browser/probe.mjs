import puppeteer from 'puppeteer-core';
const b = await puppeteer.launch({ executablePath: '/usr/local/bin/chrome',
                                   args: ['--no-sandbox','--disable-dev-shm-usage'] });
const p = await b.newPage();
await p.goto('http://127.0.0.1:9200/checkout', { waitUntil: 'domcontentloaded' });
const bg = await p.evaluate(() => getComputedStyle(document.body).backgroundColor);
const h1 = await p.$eval('h1', e => e.textContent);
const links = await p.$$eval('a', as => as.length);
console.log(JSON.stringify({ h1, bg, links }));
await b.close();
