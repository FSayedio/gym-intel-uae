// Executed inside the final non-root runtime with no external network.
import assert from 'node:assert/strict';
import { readFile, readdir } from 'node:fs/promises';
import { spawn } from 'node:child_process';
import { pathToFileURL } from 'node:url';

const modulePath = process.argv[2];
const { render, SOURCE_URL } = await import(pathToFileURL(modulePath));
const fixtureHTML = `<main>Loading...</main><script>
Promise.allSettled([
  fetch('https://example.com/private'),
  fetch('https://puregym-arabia.exerp.site/forbidden-write', {method: 'POST'})
]).then(() => setTimeout(() => document.querySelector('main').textContent =
'CORE AED 199.00 per month + AED 89.00 joining fee PLUS AED 249.00 per month + AED 89.00 joining fee' +
' rtcAbsent=' + (typeof RTCPeerConnection === 'undefined'), 300));
</script>`;

const blocked = [];
const result = await render({ fixtureHTML, onBlocked: request => blocked.push(request) });
assert.equal(result.url, SOURCE_URL);
assert.match(result.text, /199.00/);
assert.match(result.text, /249.00/);
assert.match(result.text, /rtcAbsent=true/);
assert.ok(blocked.some(r => r.url === 'https://example.com/private'));
assert.ok(blocked.some(r => r.url.endsWith('/forbidden-write') && r.method === 'POST'));
console.log('PASS: JavaScript-rendered prices are read after loading');

await assert.rejects(render({ fixtureHTML: '<main>CORE Loading... PLUS Loading...</main>', timeoutMs: 8000 }), /browser_timeout/);
console.log('PASS: incomplete plan cards time out instead of becoming a baseline');

const interrupted = spawn(process.execPath, [modulePath, SOURCE_URL], { stdio: ['pipe', 'pipe', 'pipe'] });
let output = '';
interrupted.stdout.on('data', data => { output += data; });
interrupted.stderr.resume();
setTimeout(() => interrupted.stdin.end(), 1500);
const exit = await new Promise(resolve => interrupted.once('exit', resolve));
assert.equal(exit, 1);
assert.equal(JSON.parse(output).reason, 'browser_interrupted');
console.log('PASS: closing the parent input cancels the browser');

// Tini reaps orphaned descendants. Give it a bounded opportunity to do so.
async function browserProcesses() {
  const names = await Promise.all((await readdir('/proc')).filter(name => /^\d+$/.test(name)).map(async pid => {
    try { return (await readFile(`/proc/${pid}/cmdline`, 'utf8')).trim(); } catch { return ''; }
  }));
  return names.filter(name => /\/firefox|\/geckodriver/.test(name));
}
for (let n = 0; n < 20 && (await browserProcesses()).length; n++) await new Promise(resolve => setTimeout(resolve, 100));
assert.deepEqual(await browserProcesses(), []);
assert.deepEqual((await readdir('/tmp')).filter(name => name.startsWith('gym-source-')), []);
console.log('PASS: success, timeout and interruption leave no browser processes or profiles');
try { console.log('Container peak memory bytes:', (await readFile('/sys/fs/cgroup/memory.peak', 'utf8')).trim()); } catch {}
