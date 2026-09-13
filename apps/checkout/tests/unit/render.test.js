import { test } from 'node:test';
import assert from 'node:assert/strict';
import { render, renderHtml, shippingForm, DUE } from '../../src/server.js';

test('checkout render carries app identity and path', () => {
  const r = render('/x');
  assert.equal(r.app, 'checkout');
  assert.equal(r.path, '/x');
});

// Step 1 of the copy stack: the shopper is told the figure before being asked
// to fill anything in, not after. DUE is asserted through the panel rather than
// only as a constant -- a constant nothing renders is not copy.
test('the checkout panel states what the order comes to', () => {
  assert.match(shippingForm(new URLSearchParams()), /Your order comes to/);
  assert.ok(shippingForm(new URLSearchParams()).includes(DUE), 'the amount is rendered');
});

// Step 2: the payment step used to render no panel at all -- renderHtml only
// built `extra` for /checkout. Assert both halves: the panel exists, and the
// shipping form has NOT leaked onto it.
test('the payment step says what is about to happen, and for how much', () => {
  const html = renderHtml('/checkout/payment', 9000);
  assert.match(html, /Nothing is charged until you confirm/);
  assert.ok(html.includes(DUE), 'the payment step names the same amount');
  assert.ok(!html.includes('Shipping address'), 'the shipping form stays on /checkout');
});

// Step 3: a way back that does not cost the shopper the address they typed.
// The href is the one request-derived value these panels interpolate, and
// page()'s `extra` is inserted raw -- so the escaping is asserted, not assumed.
const backHref = (html) => html.match(/href="(\/checkout\?[^"]*)"/)[1];

test('the payment step offers a way back that keeps the typed address', () => {
  const html = renderHtml('/checkout/payment?name=Ada&city=Hull', 9000);
  assert.match(html, /Back to shipping address/);
  const href = backHref(html);
  assert.match(href, /name=Ada/);
  assert.match(href, /city=Hull/);
  // Scoped to the href on purpose. Asserting /&amp;/ against the whole document
  // passes with esc() deleted -- the estate nav elsewhere on the page supplies a
  // match -- so that version of this test pinned nothing.
  assert.ok(!/&(?!amp;)/.test(href), `raw & left in the href: ${href}`);
});

test('a hostile query cannot break out of the back-link attribute', () => {
  const html = renderHtml('/checkout/payment?name="><script>alert(1)</script>', 9000);
  assert.ok(!/<script>alert\(1\)<\/script>/.test(html), 'no live script reached the page');
  assert.ok(!html.includes('"><script'), 'no attribute break-out');
});
