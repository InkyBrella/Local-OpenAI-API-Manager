import http from 'node:http';
import https from 'node:https';
import { timingSafeEqual, randomUUID } from 'node:crypto';
import { appendFileSync, mkdirSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { pipeline } from 'node:stream/promises';
import * as zlib from 'node:zlib';

const MAX_BODY = 32 * 1024 * 1024;
const HOP = new Set(['connection', 'keep-alive', 'proxy-authenticate',
  'proxy-authorization', 'te', 'trailer', 'transfer-encoding', 'upgrade']);
const COMMON_HEADERS = new Set(['accept', 'content-type', 'openai-beta',
  'openai-organization', 'openai-project']);
const CLIENT_FIELDS = ['metadata', 'client_metadata', 'prompt_cache_key'];
const LITE_HEADER = 'x-openai-internal-codex-responses-lite';

function normalizeLiteRequest(data, headers, endpoint) {
  const items = Array.isArray(data.input) ? data.input : [];
  const hasCarrier = items.some(item => item?.type === 'additional_tools');
  if (!hasCarrier && headers[LITE_HEADER] !== 'true') return false;

  const unsupported = (reason) => Object.assign(
    new Error(`responses_lite_${reason}_use_standard_catalog`), { status: 422 });
  if (endpoint !== 'responses' ||
      items.some(item => ['configuration_update', 'compaction_trigger'].includes(item?.type))) {
    throw unsupported('control_not_supported');
  }
  if (hasCarrier) {
    const [carrier, ...history] = items;
    // Declarations later in history have position-dependent scope. Hoisting them changes semantics.
    if (carrier?.type !== 'additional_tools' || carrier.role !== 'developer' || !Array.isArray(carrier.tools) ||
        history.some(item => item?.type === 'additional_tools') ||
        (data.tools !== undefined && !(Array.isArray(data.tools) && data.tools.length === 0))) {
      throw unsupported('tool_declarations_not_supported');
    }
    data.tools = carrier.tools;
    data.input = history;
  }
  for (const item of Array.isArray(data.input) ? data.input : []) {
    if (item && typeof item === 'object') delete item.internal_chat_message_metadata_passthrough;
  }
  return true;
}

function matchesToken(actual, expected) {
  const a = Buffer.from(actual ?? '');
  const b = Buffer.from(`Bearer ${expected}`);
  return a.length === b.length && timingSafeEqual(a, b);
}

function reply(res, status, code) {
  if (res.headersSent || res.destroyed) return;
  res.writeHead(status, { 'content-type': 'application/json', 'cache-control': 'no-store' });
  res.end(JSON.stringify({ error: { type: 'local_proxy_error', code, message: code } }));
}

function clientKind(headers) {
  // Prefer the request's originator; a router may preserve only the User-Agent.
  const originator = String(headers.originator ?? '').trim();
  const agentKind = String(headers['user-agent'] ?? '').split('/', 1)[0].trim();
  switch ((originator || agentKind).toLowerCase()) {
    case 'codex desktop':
    case 'codex_desktop':
    case 'codex_chatgpt_desktop': return 'Desktop';
    case 'codex-tui':
    case 'codex_exec':
    case 'codex_cli_rs': return 'CLI';
    default: return 'Unknown';
  }
}

function cleanHeaders(headers, mode, apiKey) {
  const connectionHeaders = String(headers.connection ?? '').toLowerCase().split(',').map(x => x.trim());
  const blocked = new Set([...HOP, ...connectionHeaders, 'host', 'content-length',
    'content-encoding', 'authorization', 'cookie', 'origin', 'referer', 'expect']);
  const result = {};
  const removed = [];
  for (const [key, value] of Object.entries(headers)) {
    if (blocked.has(key) || (mode === 'filtered' && !COMMON_HEADERS.has(key))) {
      removed.push(key);
    } else if (value !== undefined) {
      result[key] = value;
    }
  }
  result.authorization = `Bearer ${apiKey}`;
  if (mode === 'filtered') result['user-agent'] = 'local-api-proxy/1.0';
  return { headers: result, removed };
}

async function readBody(req) {
  let size = 0;
  const chunks = [];
  for await (const chunk of req) {
    size += chunk.length;
    if (size > MAX_BODY) throw Object.assign(new Error('body_too_large'), { status: 413 });
    chunks.push(chunk);
  }
  let body = Buffer.concat(chunks);
  const encoding = String(req.headers['content-encoding'] ?? 'identity').toLowerCase();
  const decoders = { gzip: zlib.gunzipSync, deflate: zlib.inflateSync,
    br: zlib.brotliDecompressSync, zstd: zlib.zstdDecompressSync };
  if (encoding !== 'identity') {
    if (!decoders[encoding]) throw Object.assign(new Error('unsupported_content_encoding'), { status: 415 });
    try { body = decoders[encoding](body, { maxOutputLength: MAX_BODY }); }
    catch { throw Object.assign(new Error('invalid_or_oversized_compressed_body'), { status: 400 }); }
  }
  return body;
}

// Exported for local mock tests. The executable always uses api.openai.com.
export function createProxy({ apiKey, localToken, instanceId = randomUUID(),
  upstreamBase = 'https://api.openai.com/v1/', audit = () => {}, adminToken,
  initialCredentialName = 'default', onStart = () => {} }) {
  if (!localToken || (!apiKey && !adminToken)) throw new Error('Local token and API key or manager token are required');
  let credential = apiKey ? { apiKey, name: initialCredentialName } : null;
  const stats = { total: 0, completed: 0, successful: 0, active: 0, recent: [] };
  const upstream = new URL(upstreamBase.endsWith('/') ? upstreamBase : `${upstreamBase}/`);
  if (upstream.href !== 'https://api.openai.com/v1/' &&
      !(upstream.protocol === 'http:' && upstream.hostname === '127.0.0.1')) {
    throw new Error('Only official OpenAI or a loopback mock upstream is allowed');
  }
  const transport = upstream.protocol === 'https:' ? https : http;
  const server = http.createServer(async (req, res) => {
    // Browser pages cannot use this as a cross-origin API relay.
    if (req.headers.origin) return reply(res, 403, 'browser_origin_not_allowed');
    if (req.url?.startsWith('/admin/')) {
      if (!adminToken || !matchesToken(req.headers.authorization, adminToken)) return reply(res, 401, 'invalid_manager_token');
      if (req.method === 'GET' && req.url === '/admin/status') {
        res.writeHead(200, { 'content-type': 'application/json', 'cache-control': 'no-store' });
        return res.end(JSON.stringify({ ...stats, instance_id: instanceId,
          credential_name: credential?.name ?? null, upstream: upstream.origin,
          uptime_seconds: Math.floor(process.uptime()) }));
      }
      if (req.method === 'POST' && req.url === '/admin/credential') {
        try {
          const data = JSON.parse((await readBody(req)).toString('utf8'));
          if (typeof data.name !== 'string' || !/^[\p{L}\p{N}_. -]{1,40}$/u.test(data.name) ||
              typeof data.apiKey !== 'string' || !data.apiKey.trim() || /[\r\n]/.test(data.apiKey)) {
            return reply(res, 400, 'invalid_credential');
          }
          credential = { apiKey: data.apiKey.trim(), name: data.name };
          res.writeHead(200, { 'content-type': 'application/json' });
          return res.end(JSON.stringify({ ok: true, credential_name: credential.name }));
        } catch { return reply(res, 400, 'invalid_credential_request'); }
      }
      return reply(res, 404, 'unsupported_admin_endpoint');
    }
    if (!matchesToken(req.headers.authorization, localToken)) return reply(res, 401, 'invalid_local_token');
    if (req.method === 'GET' && req.url === '/health') {
      res.writeHead(200, { 'content-type': 'application/json' });
      return res.end(JSON.stringify({ ok: true, instance_id: instanceId }));
    }
    const route = /^(\/baseline)?\/v1\/(responses(?:\/compact)?|models)$/.exec(req.url ?? '');
    if (!route) return reply(res, 404, 'unsupported_endpoint');
    const endpoint = route[2];
    if (req.method !== (endpoint === 'models' ? 'GET' : 'POST')) return reply(res, 405, 'method_not_allowed');
    const mode = route[1] ? 'baseline' : 'filtered';
    const started = Date.now();
    const record = { time: new Date().toISOString(), id: randomUUID(), mode, client: clientKind(req.headers),
      method: req.method, endpoint, removed_headers: [], removed_body_fields: [] };
    const selected = credential;
    record.credential_name = selected?.name ?? null;
    stats.total++;
    stats.active++;
    try { onStart({ ...record }); } catch { /* Monitoring must not interrupt requests. */ }
    let upstreamReq;
    const abort = () => upstreamReq?.destroy();
    const onClose = () => { if (!res.writableFinished) abort(); };
    res.on('close', onClose);
    req.on('aborted', abort);
    try {
      if (!selected) return reply(res, 503, 'no_active_api_key_select_one_in_manager');
      let body = await readBody(req);
      if (endpoint === 'models' && body.length) return reply(res, 400, 'unexpected_body');
      if (req.method === 'POST') {
        let data;
        try { data = JSON.parse(body.toString('utf8')); }
        catch { throw Object.assign(new Error('invalid_json'), { status: 400 }); }
        if (!data || typeof data !== 'object' || Array.isArray(data)) {
          throw Object.assign(new Error('expected_json_object'), { status: 400 });
        }
        record.model = typeof data.model === 'string' ? data.model.slice(0, 100) : null;
        if (mode === 'filtered') {
          if (normalizeLiteRequest(data, req.headers, endpoint)) record.request_format = 'responses_lite_normalized';
          for (const key of CLIENT_FIELDS) {
            if (Object.hasOwn(data, key)) {
              delete data[key];
              record.removed_body_fields.push(key);
            }
          }
          body = Buffer.from(JSON.stringify(data));
        }
      }
      const prepared = cleanHeaders(req.headers, mode, selected.apiKey);
      record.removed_headers = prepared.removed;
      prepared.headers['accept-encoding'] = 'identity';
      if (req.method === 'POST') {
        prepared.headers['content-type'] = 'application/json';
        prepared.headers['content-length'] = String(body.length);
      }
      const upstreamRes = await new Promise((resolveResponse, reject) => {
        upstreamReq = transport.request(new URL(endpoint, upstream), {
          method: req.method, headers: prepared.headers,
        }, resolveResponse);
        upstreamReq.on('error', reject);
        upstreamReq.setTimeout(300_000, () => upstreamReq.destroy(new Error('upstream_timeout')));
        if (res.destroyed) upstreamReq.destroy();
        else upstreamReq.end(body);
      });
      record.status = upstreamRes.statusCode;
      record.upstream_request_id = upstreamRes.headers['x-request-id'] ?? null;
      const responseHeaders = {};
      const responseConnection = String(upstreamRes.headers.connection ?? '').toLowerCase().split(',').map(x => x.trim());
      for (const [key, value] of Object.entries(upstreamRes.headers)) {
        if (!HOP.has(key) && !responseConnection.includes(key) && key !== 'set-cookie') responseHeaders[key] = value;
      }
      res.writeHead(upstreamRes.statusCode, responseHeaders);
      // Stream bytes immediately with backpressure; SSE and tool-call events stay intact.
      await pipeline(upstreamRes, res);
    } catch (error) {
      record.proxy_error = error.status ? error.message :
        (res.destroyed ? 'client_disconnected' : 'upstream_connection_or_stream_error');
      if (!res.headersSent) reply(res, error.status ?? 502, record.proxy_error);
      else res.destroy();
      abort();
    } finally {
      res.off('close', onClose);
      req.off('aborted', abort);
      record.status ??= res.headersSent ? res.statusCode : null;
      record.duration_ms = Date.now() - started;
      stats.active--;
      stats.completed++;
      if (record.status >= 200 && record.status < 300 && !record.proxy_error) stats.successful++;
      stats.recent.unshift(record);
      stats.recent = stats.recent.slice(0, 12);
      try { audit(record); } catch { console.error('Audit log write failed'); }
    }
  });
  server.requestTimeout = 300_000;
  server.headersTimeout = 60_000;
  server.on('upgrade', (_req, socket) => {
    socket.end('HTTP/1.1 426 Upgrade Required\r\nConnection: close\r\nContent-Length: 0\r\n\r\n');
  });
  return server;
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const serverLog = process.env.LOCAL_PROXY_SERVER_LOG;
  const log = (message) => {
    if (serverLog) appendFileSync(serverLog, message + '\n', 'utf8');
    else console.log(message);
  };
  const apiKey = process.env.OPENAI_API_KEY;
  const localToken = process.env.CODEX_PROXY_KEY;
  const adminToken = process.env.LOCAL_PROXY_ADMIN_TOKEN;
  if ((!apiKey && !adminToken) || !localToken) {
    log('Use API-Manager.cmd or Start-Codex.ps1 to start the proxy.');
    process.exit(1);
  }
  const port = Number(process.env.LOCAL_PROXY_PORT ?? 8787);
  if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error('Invalid port');
  const auditFile = resolve(process.env.LOCAL_PROXY_AUDIT ?? 'logs/audit.jsonl');
  mkdirSync(dirname(auditFile), { recursive: true });
  const server = createProxy({ apiKey, localToken, adminToken,
    initialCredentialName: process.env.LOCAL_PROXY_KEY_NAME ?? 'default',
    instanceId: process.env.LOCAL_PROXY_INSTANCE,
    audit: record => appendFileSync(auditFile, `${JSON.stringify(record)}\n`, 'utf8') });
  server.on('error', error => {
    log(`Proxy could not start (${error.code ?? 'unknown'}).`);
    process.exitCode = 1;
  });
  server.listen(port, '127.0.0.1', () => {
    log(`Filtered: http://127.0.0.1:${port}/v1`);
    log(`Baseline: http://127.0.0.1:${port}/baseline/v1`);
    log(`Audit: ${auditFile}`);
  });
  const stop = () => { server.close(); server.closeAllConnections(); };
  process.on('SIGINT', stop);
  process.on('SIGTERM', stop);
}
