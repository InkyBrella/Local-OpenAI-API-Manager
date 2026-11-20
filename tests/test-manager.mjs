import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { createProxy } from '../proxy.mjs';

const localToken = 'local-provider-token';
const adminToken = 'separate-private-manager-token';
const keyA = 'fake-manager-official-key-A';
const keyB = 'fake-manager-official-key-B';
const received = [];
const rows = [];
let releaseFirst;
let firstStarted;
const firstReady = new Promise(resolve => { firstStarted = resolve; });
const mock = http.createServer(async (req, res) => {
  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
  const data = JSON.parse(Buffer.concat(chunks).toString());
  received.push(req.headers.authorization);
  if (data.input === 'hold') {
    firstStarted();
    await new Promise(resolve => { releaseFirst = resolve; });
  }
  res.writeHead(200, { 'content-type': 'application/json' });
  res.end('{"ok":true}');
});
const listen = server => new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
await listen(mock);
const proxy = createProxy({ localToken, adminToken,
  upstreamBase: `http://127.0.0.1:${mock.address().port}/v1/`, audit: row => rows.push(row) });
await listen(proxy);
const base = `http://127.0.0.1:${proxy.address().port}`;
const admin = (path, body, token = adminToken) => fetch(base + path, {
  method: body ? 'POST' : 'GET', headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
  body: body ? JSON.stringify(body) : undefined });
const send = input => fetch(base + '/v1/responses', { method: 'POST',
  headers: { authorization: `Bearer ${localToken}`, 'content-type': 'application/json' },
  body: JSON.stringify({ model: 'test-model', input }) });

try {
  await test('provider token cannot read or change manager state', async () => {
    assert.equal((await admin('/admin/status', null, localToken)).status, 401);
    assert.equal((await admin('/admin/credential', { name: 'stolen', apiKey: 'no' }, localToken)).status, 401);
    const status = await (await admin('/admin/status')).json();
    assert.equal(status.credential_name, null);
  });
  await test('manager starts without an upstream key and never forwards unconfigured requests', async () => {
    const res = await send('before-key');
    assert.equal(res.status, 503);
    assert.match((await res.json()).error.code, /no_active_api_key/);
    assert.equal(received.length, 0);
  });
  await test('hot switching applies to new requests while an in-flight request retains its selected key', async () => {
    assert.equal((await admin('/admin/credential', { name: 'project-a', apiKey: keyA })).status, 200);
    const first = send('hold');
    await firstReady;
    const during = await (await admin('/admin/status')).json();
    assert.equal(during.active, 1);
    assert.equal((await admin('/admin/credential', { name: 'project-b', apiKey: keyB })).status, 200);
    const second = await send('new');
    await second.text();
    releaseFirst();
    await (await first).text();
    assert.deepEqual(received, [`Bearer ${keyA}`, `Bearer ${keyB}`]);
    assert.equal(rows.find(row => row.credential_name === 'project-a').status, 200);
    assert.equal(rows.find(row => row.credential_name === 'project-b').status, 200);
    const status = await (await admin('/admin/status')).json();
    assert.equal(status.credential_name, 'project-b');
    assert.equal(status.active, 0);
    assert.equal(status.total, 3);
    assert.equal(status.successful, 2);
    const output = JSON.stringify({ status, rows });
    for (const secret of [keyA, keyB, localToken, adminToken]) assert.ok(!output.includes(secret));
  });
  await test('invalid manager credentials do not replace the active key', async () => {
    assert.equal((await admin('/admin/credential', { name: 'bad\nname', apiKey: keyA })).status, 400);
    assert.equal((await admin('/admin/credential', { name: 'safe', apiKey: 'key\r\nheader' })).status, 400);
    assert.equal((await (await admin('/admin/status')).json()).credential_name, 'project-b');
  });
} finally {
  releaseFirst?.();
  proxy.closeAllConnections(); mock.closeAllConnections();
  await Promise.all([new Promise(resolve => proxy.close(resolve)), new Promise(resolve => mock.close(resolve))]);
}
