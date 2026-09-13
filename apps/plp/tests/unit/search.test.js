// What plp does with /search.
//
// The catalogue tests next door cover /c/:category. This file covers the other
// declared route, which until now plp answered with the generic app document:
// it read no query, searched nothing, and its page said nothing about what had
// been asked for.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { render, panel, renderHtml } from '../../src/server.js';

// ---- step 1: the term comes off the URL -------------------------------------

test('a search carries the term it was asked for', () => {
  assert.equal(render('/search?q=boots').query, 'boots');
});

test('the term is decoded, not echoed raw', () => {
  assert.equal(render('/search?q=red%20shoes').query, 'red shoes');
  assert.equal(render('/search?q=a%26b').query, 'a&b');
});

// '' and undefined are different states and the page says different things
// about them (step 4). A search page nobody has searched from is not the same
// as a page that is not a search page.
test('a search with no term is still a search', () => {
  assert.equal(render('/search').query, '');
  assert.equal(render('/search?q=').query, '');
  assert.equal(render('/search?page=2').query, '');
});

test('a page that is not a search carries no term at all', () => {
  for (const p of ['/c/shoes', '/c/nope', '/x'])
    assert.equal(render(p).query, undefined, `${p} claimed to be a search`);
});

// /search answers 200 whether or not anything matched. A search that finds
// nothing is a successful answer to a valid request; 404 would tell a crawler
// the search page does not exist.
test('a search is a 200, matched or not', async () => {
  const { status } = await import('../../src/server.js');
  assert.equal(status(render('/search?q=boots')), 200);
  assert.equal(status(render('/search?q=zzzznothing')), 200);
});

// ---- step 2: the page names the term back -----------------------------------

test('the search page names the term that was searched for', () => {
  assert.match(panel(render('/search?q=boots')), /Results for <code>boots<\/code>/);
});

test('a search page is not dressed up as a category page', () => {
  const html = renderHtml('/search?q=boots');
  assert.doesNotMatch(html, /\(none\)/, 'search rendered the category copy');
  assert.doesNotMatch(html, /<h2><\/h2>/, 'search rendered an empty heading');
});

// THE ESCAPING TEST. q comes straight off the request line -- the same path
// that put live markup in every page in the estate at OneUI 1.0.0. Delete the
// esc() call in panel() and this test must go red; if it does not, it is not
// testing anything.
test('the term is escaped on its way into the document', () => {
  const evil = '<script>alert(1)</script>';
  const html = renderHtml(`/search?q=${encodeURIComponent(evil)}`);
  assert.doesNotMatch(html, /<script>alert\(1\)<\/script>/,
    'the search term reached the document as live markup');
  assert.match(html, /&lt;script&gt;alert\(1\)&lt;\/script&gt;/,
    'the search term should appear, escaped');
});

test('quotes and ampersands in the term are escaped too', () => {
  const html = renderHtml('/search?q=%22a%26b%27');
  assert.doesNotMatch(html, /Results for <code>"a&b'/);
  assert.match(html, /&quot;a&amp;b&#39;/);
});
