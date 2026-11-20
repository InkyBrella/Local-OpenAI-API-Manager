import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { setTimeout as delay } from 'node:timers/promises';
import { gzipSync, zstdCompressSync } from 'node:zlib';
import { createProxy } from '../proxy.mjs';

const apiKey = 'fake-upstream-key-never-logged';
const localToken = 'fake-local-token-never-forwarded';
const requests = [];
const audit = [];
let cancelObserved;
const mock = http.createServer(async (req, res) => {
  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
  const body = Buffer.concat(chunks).toString();
  requests.push({ headers: req.headers, url: req.url, body });
  const parsed = body ? JSON.parse(body) : {};
  if (parsed.input === 'reject') {
    res.writeHead(429, { 'content-type': 'application/json', 'x-request-id': 'req_mock_429', 'retry-after': '2' });
    return res.end(JSON.stringify({ error: { code: 'credit_balance_exhausted' } }));
  }
  if (parsed.input === 'cancel') {
    res.writeHead(200, { 'content-type': 'text/event-stream' });
    res.write('event: response.created\ndata: {}\n\n');
    const timer = setInterval(() => res.write(': keepalive\n\n'), 50);
    res.on('close', () => { clearInterval(timer); cancelObserved?.(); });
    return;
  }
  if (parsed.stream) {
    res.writeHead(200, { 'content-type': 'text/event-stream', 'x-request-id': 'req_mock_stream' });
    res.write('event: response.created\ndata: {"type":"response.created"}\n\n');
    await delay(150);
    res.write('event: response.function_call_arguments.delta\ndata: {"delta":"{}"}\n\n');
    return res.end('event: response.completed\ndata: {"type":"response.completed"}\n\n');
  }
  res.writeHead(200, { 'content-type': 'application/json', 'x-request-id': 'req_mock_json' });
  res.end(JSON.stringify({ ok: true }));
});

const listen = server => new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
await listen(mock);
const proxy = createProxy({ apiKey, localToken,
  upstreamBase: `http://127.0.0.1:${mock.address().port}/v1/`, audit: record => audit.push(record) });
await listen(proxy);
const base = `http://127.0.0.1:${proxy.address().port}`;
const headers = { authorization: `Bearer ${localToken}`, 'content-type': 'application/json',
  'user-agent': 'codex_cli_rs/0.170.0', originator: 'codex_cli_rs', version: '0.170.0',
  'x-codex-session-id': 'session-private', 'x-client-request-id': 'trace-private',
  cookie: 'private-cookie', 'openai-project': 'proj_mock' };
const payload = { model: 'test-model', instructions: 'You are Codex. Keep this unchanged.',
  input: [{ role: 'user', content: 'Explain Codex without editing the question.' }],
  tools: [{ type: 'function', name: 'codex_tool', parameters: { type: 'object' } }],
  metadata: { originator: 'codex' }, client_metadata: { session_id: 'private' },
  prompt_cache_key: 'codex-session', previous_response_id: 'resp_previous',
  safety_identifier: 'preserved-safety-id' };
async function post(path, body, extraHeaders = {}) {
  return fetch(base + path, { method: 'POST', headers: { ...headers, ...extraHeaders },
    body: typeof body === 'string' || Buffer.isBuffer(body) ? body : JSON.stringify(body) });
}

try {
  await test('filters identity headers/metadata but preserves instructions, tools, and conversation state', async () => {
    const res = await post('/v1/responses', payload);
    assert.equal(res.status, 200);
    await res.text();
    const sent = requests.at(-1);
    assert.equal(sent.url, '/v1/responses');
    assert.equal(sent.headers.authorization, `Bearer ${apiKey}`);
    assert.equal(sent.headers['user-agent'], 'local-api-proxy/1.0');
    for (const key of ['originator', 'version', 'x-codex-session-id', 'x-client-request-id', 'cookie']) {
      assert.equal(sent.headers[key], undefined);
    }
    assert.equal(sent.headers['openai-project'], 'proj_mock');
    const expected = structuredClone(payload);
    for (const key of ['metadata', 'client_metadata', 'prompt_cache_key']) delete expected[key];
    assert.deepEqual(JSON.parse(sent.body), expected);
    const row = audit.at(-1);
    assert.equal(row.upstream_request_id, 'req_mock_json');
    assert.ok(row.removed_headers.includes('originator'));
    assert.deepEqual(row.removed_body_fields, ['metadata', 'client_metadata', 'prompt_cache_key']);
    const log = JSON.stringify(audit);
    for (const secret of [apiKey, localToken, 'session-private', 'private-cookie', payload.instructions]) {
      assert.ok(!log.includes(secret));
    }
  });

  await test('baseline preserves client identity and body for controlled comparison', async () => {
    const res = await post('/baseline/v1/responses', payload);
    assert.equal(res.status, 200);
    await res.text();
    const sent = requests.at(-1);
    for (const key of ['user-agent', 'originator', 'version', 'x-codex-session-id']) {
      assert.equal(sent.headers[key], headers[key]);
    }
    assert.equal(sent.headers.cookie, undefined);
    assert.deepEqual(JSON.parse(sent.body), payload);
  });

  await test('adapts a compressed Lite request and preserves namespaced tools and streaming', async () => {
    const liteHeader = 'x-openai-internal-codex-responses-lite';
    const tool = { type: 'namespace', name: 'functions', description: 'Local tools', tools: payload.tools };
    const input = [
      { ...payload.input[0], internal_chat_message_metadata_passthrough: { content_item_metadata: [] } },
      { type: 'function_call', name: 'codex_tool', namespace: 'functions', call_id: 'call_1', arguments: '{}' },
      { type: 'function_call_output', call_id: 'call_1', output: 'fixture_result' },
    ];
    const lite = { model: payload.model, input: [{ type: 'additional_tools', role: 'developer', tools: [tool] }, ...input],
      stream: true, reasoning: { effort: 'medium', context: 'all_turns' }, client_metadata: { session_id: 'private' } };
    const res = await post('/v1/responses', zstdCompressSync(Buffer.from(JSON.stringify(lite))),
      { [liteHeader]: 'true', 'content-encoding': 'zstd' });
    const events = await res.text();
    assert.equal(res.status, 200, events);
    assert.match(events, /response.function_call_arguments.delta/);
    assert.match(events, /response.completed/);
    const sent = requests.at(-1);
    assert.equal(sent.headers[liteHeader], undefined);
    assert.deepEqual(JSON.parse(sent.body), { model: lite.model, input: [...payload.input, ...input.slice(1)],
      tools: [tool], stream: true, reasoning: lite.reasoning });
    assert.equal(audit.at(-1).request_format, 'responses_lite_normalized');
    const baseline = await post('/baseline/v1/responses', lite, { [liteHeader]: 'true' });
    assert.equal(baseline.status, 200);
    await baseline.text();
    assert.equal(requests.at(-1).headers[liteHeader], 'true');
    assert.deepEqual(JSON.parse(requests.at(-1).body), lite);
  });

  await test('recognizes an initial Lite tool declaration if an intermediate router removed its header', async () => {
    const input = [{ type: 'additional_tools', role: 'developer', tools: payload.tools }, ...payload.input];
    const res = await post('/v1/responses', { model: payload.model, tools: [], input });
    assert.equal(res.status, 200);
    await res.text();
    assert.deepEqual(JSON.parse(requests.at(-1).body), { model: payload.model, tools: payload.tools, input: payload.input });
  });

  await test('rejects Lite controls or late tool declarations that cannot be converted safely', async () => {
    const count = requests.length;
    const control = { type: 'configuration_update', reasoning: { effort: 'high' } };
    const carrier = { type: 'additional_tools', role: 'developer', tools: payload.tools };
    for (const [input, reason] of [
      [[control], 'control'],
      [[...payload.input, carrier], 'tool_declarations'],
      [[{ ...carrier, tools: {} }], 'tool_declarations'],
      [[carrier, carrier], 'tool_declarations'],
      [[{ type: 'compaction_trigger' }], 'control'],
    ]) {
      const res = await post('/v1/responses', { model: payload.model, input },
        { 'x-openai-internal-codex-responses-lite': 'true' });
      assert.equal(res.status, 422);
      assert.equal((await res.json()).error.code, `responses_lite_${reason}_not_supported_use_standard_catalog`);
    }
    assert.equal(requests.length, count);
  });

  await test('streams the first SSE event before completion, including tool-call deltas', async () => {
    const res = await post('/v1/responses', { ...payload, stream: true });
    const reader = res.body.getReader();
    const first = await reader.read();
    const firstText = new TextDecoder().decode(first.value);
    assert.match(firstText, /response.created/);
    assert.doesNotMatch(firstText, /response.completed/);
    let text = firstText;
    while (true) {
      const chunk = await reader.read();
      if (chunk.done) break;
      text += new TextDecoder().decode(chunk.value);
    }
    assert.match(text, /response.function_call_arguments.delta/);
    assert.match(text, /response.completed/);
  });

  await test('forwards upstream errors, request IDs, and retry information unchanged', async () => {
    const res = await post('/v1/responses', { input: 'reject' });
    assert.equal(res.status, 429);
    assert.equal(res.headers.get('x-request-id'), 'req_mock_429');
    assert.equal(res.headers.get('retry-after'), '2');
    assert.deepEqual(await res.json(), { error: { code: 'credit_balance_exhausted' } });
  });

  await test('supports compressed JSON requests without forwarding stale length/encoding', async () => {
    for (const [encoding, compress] of [['gzip', gzipSync], ['zstd', zstdCompressSync]]) {
      const res = await post('/v1/responses', compress(Buffer.from(JSON.stringify(payload))), { 'content-encoding': encoding });
      assert.equal(res.status, 200);
      await res.text();
      const sent = requests.at(-1);
      assert.equal(sent.headers['content-encoding'], undefined);
      assert.equal(Number(sent.headers['content-length']), Buffer.byteLength(sent.body));
      assert.equal(JSON.parse(sent.body).metadata, undefined);
    }
  });

  await test('authenticates locally and rejects browser origins, unknown routes, and invalid JSON', async () => {
    const count = requests.length;
    assert.equal((await post('/v1/responses', {}, { authorization: 'Bearer wrong' })).status, 401);
    assert.equal((await post('/v1/responses', {}, { origin: 'https://example.com' })).status, 403);
    assert.equal((await post('/v1/unknown', {})).status, 404);
    assert.equal((await post('/v1/responses?target=https://example.com', {})).status, 404);
    assert.equal((await post('/v1/responses', '{bad')).status, 400);
    assert.equal((await post('/v1/responses', [])).status, 400);
    assert.equal((await post('/v1/responses', Buffer.from('bad'), { 'content-encoding': 'zstd' })).status, 400);
    assert.equal(requests.length, count);
  });

  await test('supports model listing and compact requests on the same fixed upstream', async () => {
    const res = await fetch(base + '/v1/models', { headers: { authorization: `Bearer ${localToken}` } });
    assert.equal(res.status, 200);
    await res.text();
    assert.equal(requests.at(-1).url, '/v1/models');
    const compact = await post('/v1/responses/compact', { model: 'test-model', input: [] });
    assert.equal(compact.status, 200);
    await compact.text();
    assert.equal(requests.at(-1).url, '/v1/responses/compact');
  });

  await test('reports a refused upstream connection for model listing without exposing credentials', async () => {
    const closed = http.createServer();
    await listen(closed);
    const closedPort = closed.address().port;
    await new Promise(resolve => closed.close(resolve));
    const offline = createProxy({ apiKey, localToken, upstreamBase: `http://127.0.0.1:${closedPort}/`,
      audit: record => audit.push(record) });
    await listen(offline);
    try {
      const response = await fetch(`http://127.0.0.1:${offline.address().port}/v1/models`,
        { headers: { authorization: `Bearer ${localToken}` } });
      assert.equal(response.status, 502);
      assert.deepEqual((await response.json()).error, {
        type: 'local_proxy_error', code: 'upstream_connection_or_stream_error',
        message: 'upstream_connection_or_stream_error', network_code: 'ECONNREFUSED',
      });
      assert.equal(audit.at(-1).network_code, 'ECONNREFUSED');
      const record = JSON.stringify(audit.at(-1));
      assert.ok(!record.includes(apiKey) && !record.includes(localToken));
    } finally {
      offline.closeAllConnections();
      await new Promise(resolve => offline.close(resolve));
    }
  });

  await test('client cancellation closes the upstream stream', async () => {
    const stopped = new Promise(resolve => { cancelObserved = resolve; });
    const res = await post('/v1/responses', { input: 'cancel', stream: true });
    const reader = res.body.getReader();
    await reader.read();
    await reader.cancel();
    const result = await Promise.race([stopped.then(() => true), delay(2000).then(() => false)]);
    assert.equal(result, true);
  });
} finally {
  proxy.closeAllConnections();
  mock.closeAllConnections();
  await Promise.all([new Promise(resolve => proxy.close(resolve)), new Promise(resolve => mock.close(resolve))]);
}
