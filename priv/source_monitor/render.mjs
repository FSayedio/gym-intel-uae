// Fixed public-page renderer. No npm dependencies; Node's built-in WebSocket
// speaks WebDriver BiDi to a temporary, sandboxed Firefox process.
import { spawn } from 'node:child_process';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

export const SOURCE_URL = 'https://puregym-arabia.exerp.site/join/plan?center=8002';
const ORIGIN = new URL(SOURCE_URL).origin;
const PLAN_LOOKUP = `${ORIGIN}/api/subscription/load-available-subscriptions-for-annonymous`;
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));

export function allowedRequest(url, method) {
  try {
    const target = new URL(url);
    return target.origin === ORIGIN && !target.username && !target.password &&
      (method === 'GET' || (method === 'POST' && target.href === PLAN_LOOKUP));
  } catch { return false; }
}

export function plansReady(text) {
  const value = text.replace(/\s+/gu, ' ');
  const core = value.search(/\bCORE\b/i);
  const plus = value.search(/\bPLUS\b/i);
  const price = /AED\s*[\d,]+(?:\.\d+)?\s*per month\s*\+\s*AED\s*[\d,]+(?:\.\d+)?\s*joining fee/i;
  return core >= 0 && plus > core && price.test(value.slice(core, plus)) && price.test(value.slice(plus));
}

function connectBidi(url, onRequest) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(url);
    let sequence = 0;
    const pending = new Map();
    const send = (method, params = {}) => new Promise((done, fail) => {
      const id = ++sequence;
      pending.set(id, { done, fail });
      ws.send(JSON.stringify({ id, method, params }));
    });
    ws.addEventListener('error', () => reject(new Error('browser_connection_failed')));
    ws.addEventListener('close', () => {
      for (const { fail } of pending.values()) fail(new Error('browser_connection_closed'));
      pending.clear();
    });
    ws.addEventListener('message', event => {
      const message = JSON.parse(event.data);
      if (message.id && pending.has(message.id)) {
        const { done, fail } = pending.get(message.id);
        pending.delete(message.id);
        if (message.type === 'error') fail(new Error('browser_protocol_failed'));
        else done(message.result);
      } else if (message.method === 'network.beforeRequestSent' && message.params.isBlocked) {
        onRequest(message.params, send).catch(() => ws.close());
      }
    });
    ws.addEventListener('open', () => resolve({ send, close: () => ws.close() }));
  });
}

export async function render({ url = SOURCE_URL, timeoutMs = 60_000, fixtureHTML, signal,
  onBlocked = () => {}, onPage = () => {} } = {}) {
  if (url !== SOURCE_URL) throw new Error('unapproved_url');
  const profile = await mkdtemp(join(tmpdir(), 'gym-source-'));
  let driver, endpoint, session, bidi, timer;
  let stopping = false;
  const killGroup = kind => {
    if (driver?.pid) {
      try { process.kill(-driver.pid, kind); } catch { /* already gone */ }
    }
  };
  const cleanup = async () => {
    if (stopping) return;
    stopping = true;
    bidi?.close();
    if (session && endpoint) {
      await fetch(`${endpoint}/session/${session}`, { method: 'DELETE', signal: AbortSignal.timeout(2000) }).catch(() => {});
    }
    killGroup('SIGTERM');
    await pause(300);
    killGroup('SIGKILL');
    if (driver && driver.exitCode === null && driver.signalCode === null) {
      await Promise.race([new Promise(resolve => driver.once('exit', resolve)), pause(1000)]);
    }
    await rm(profile, { recursive: true, force: true });
  };
  const aborted = new Promise((_, reject) => {
    timer = setTimeout(() => reject(new Error('browser_timeout')), timeoutMs);
    if (signal?.aborted) reject(new Error('browser_interrupted'));
    signal?.addEventListener('abort', () => reject(new Error('browser_interrupted')), { once: true });
  });
  const work = async () => {
    driver = spawn('/usr/bin/geckodriver', ['--host', '127.0.0.1', '--port', '0'], {
      detached: true, stdio: ['ignore', 'pipe', 'pipe'],
      env: { PATH: '/usr/bin:/bin', HOME: profile, TMPDIR: profile, LANG: 'C.UTF-8' }
    });
    const port = await new Promise((resolve, reject) => {
      let buffer = '';
      const read = chunk => {
        buffer = (buffer + chunk.toString()).slice(-4096);
        const match = buffer.match(/Listening on 127\.0\.0\.1:(\d+)/);
        if (match) resolve(Number(match[1]));
      };
      driver.stdout.on('data', read);
      driver.stderr.on('data', read);
      driver.once('error', () => reject(new Error('browser_unavailable')));
      driver.once('exit', () => reject(new Error('browser_start_failed')));
    });
    endpoint = `http://127.0.0.1:${port}`;
    const command = async (path, data) => {
      const response = await fetch(`${endpoint}${path}`, {
        method: 'POST', headers: { 'content-type': 'application/json' },
        body: JSON.stringify(data), signal: AbortSignal.timeout(30_000)
      });
      const result = await response.json();
      if (!response.ok || result.value?.error) throw new Error('browser_command_failed');
      return result.value;
    };
    const created = await command('/session', { capabilities: { alwaysMatch: {
      browserName: 'firefox', acceptInsecureCerts: false, webSocketUrl: true,
      pageLoadStrategy: 'eager',
      'moz:firefoxOptions': { args: ['-headless', '-profile', profile], prefs: {
        'browser.shell.checkDefaultBrowser': false,
        'browser.sessionstore.resume_from_crash': false,
        'media.peerconnection.enabled': false,
        'dom.serviceWorkers.enabled': false,
        'network.captive-portal-service.enabled': false,
        'network.connectivity-service.enabled': false,
        'datareporting.healthreport.uploadEnabled': false,
        'datareporting.policy.dataSubmissionEnabled': false,
        'toolkit.telemetry.enabled': false
      } }
    } } });
    session = created.sessionId;
    bidi = await connectBidi(created.capabilities.webSocketUrl, async (event, send) => {
      const request = event.request;
      // Fixture substitution is an in-process test hook; it is never accepted
      // from CLI arguments, environment variables or a submitted source URL.
      if (fixtureHTML !== undefined && request.url === SOURCE_URL) {
        await send('network.provideResponse', { request: request.request, statusCode: 200,
          headers: [{ name: 'content-type', value: { type: 'string', value: 'text/html' } }],
          body: { type: 'base64', value: Buffer.from(fixtureHTML).toString('base64') } });
      } else if (fixtureHTML === undefined && allowedRequest(request.url, request.method)) {
        await send('network.continueRequest', { request: request.request });
      } else {
        onBlocked({ url: request.url, method: request.method });
        await send('network.failRequest', { request: request.request });
      }
    });
    await bidi.send('session.subscribe', { events: ['network.beforeRequestSent'] });
    await bidi.send('network.addIntercept', { phases: ['beforeRequestSent'], urlPatterns: [
      { type: 'pattern', protocol: 'http' }, { type: 'pattern', protocol: 'https' }
    ] });
    await command(`/session/${session}/url`, { url });
    while (true) {
      const page = await command(`/session/${session}/execute/sync`, {
        script: 'return {url: location.href, text: (document.querySelector("main") || document.body).innerText};', args: []
      });
      if (page.url !== SOURCE_URL) throw new Error('browser_navigation_changed');
      onPage(page);
      if (typeof page.text !== 'string' || Buffer.byteLength(page.text) > 100_000) throw new Error('browser_content_too_large');
      if (plansReady(page.text)) return { url: page.url, text: page.text };
      await pause(200);
    }
  };
  try {
    return await Promise.race([work(), aborted]);
  } finally {
    clearTimeout(timer);
    await cleanup();
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const controller = new AbortController();
  process.stdin.resume();
  process.stdin.on('end', () => controller.abort());
  process.on('SIGTERM', () => controller.abort());
  process.on('SIGINT', () => controller.abort());
  let output;
  try {
    output = { ok: true, ...await render({ url: process.argv[2], signal: controller.signal }) };
  } catch (error) {
    const reasons = ['unapproved_url', 'browser_timeout', 'browser_interrupted', 'browser_unavailable',
      'browser_start_failed', 'browser_navigation_changed', 'browser_content_too_large'];
    output = { ok: false, reason: reasons.includes(error.message) ? error.message : 'browser_check_failed' };
  }
  await new Promise(resolve => process.stdout.write(JSON.stringify(output), resolve));
  process.exit(output.ok ? 0 : 1);
}
