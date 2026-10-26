import test from 'node:test';
import assert from 'node:assert/strict';
import { allowedRequest, plansReady, SOURCE_URL, render } from '../../priv/source_monitor/render.mjs';

test('only the reviewed host and its exact read-only plan lookup are allowed', () => {
  assert.equal(allowedRequest(SOURCE_URL, 'GET'), true);
  for (const url of ['http://puregym-arabia.exerp.site/', 'https://puregym-arabia.exerp.site.evil.example/',
    'http://127.0.0.1:4444/', 'http://postgres:5432/', 'file:///run/secrets/password',
    'https://name:password@puregym-arabia.exerp.site/', 'not a URL']) {
    assert.equal(allowedRequest(url, 'GET'), false);
  }
  for (const method of ['POST', 'DELETE', 'PUT']) assert.equal(allowedRequest(SOURCE_URL, method), false);
  const lookup = 'https://puregym-arabia.exerp.site/api/subscription/load-available-subscriptions-for-annonymous';
  assert.equal(allowedRequest(lookup, 'POST'), true);
  assert.equal(allowedRequest(lookup + '?other=1', 'POST'), false);
});

test('both cards must contain their own numeric monthly price and joining fee', () => {
  const core = 'CORE AED 199.00 per month + AED 89.00 joining fee';
  const plus = 'PLUS AED 249.00 per month + AED 89.00 joining fee';
  assert.equal(plansReady(`${core}\n${plus}`), true);
  assert.equal(plansReady(`${core.replace('199.00', '219.00')} ${plus}`), true);
  assert.equal(plansReady(core), false);
  assert.equal(plansReady(`CORE Loading... ${plus}`), false);
  assert.equal(plansReady(`${core} PLUS Loading...`), false);
  assert.equal(plansReady(`CORE unavailable PLUS unavailable`), false);
});

test('another branch URL is rejected before starting a browser', async () => {
  await assert.rejects(render({ url: SOURCE_URL.replace('8002', '8001') }), /unapproved_url/);
});
