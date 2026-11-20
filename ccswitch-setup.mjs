import { randomUUID } from 'node:crypto';
import { readFileSync, renameSync, unlinkSync, writeFileSync } from 'node:fs';
import { isAbsolute, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { isDeepStrictEqual } from 'node:util';
import toml from './vendor/smol-toml.cjs';

const marker = 'Local OpenAI API Manager (localhost)';
const parse = text => toml.parse(text.replace(/^\uFEFF/, ''), { integersAsBigInt: true, useLegacyDate: false });

function readText(path) {
  try {
    return readFileSync(path, 'utf8');
  } catch (error) {
    if (error.code === 'ENOENT') return null;
    throw error;
  }
}

function readToml(text, label) {
  try {
    return parse(text);
  } catch {
    // The parser's error excerpt can include credentials from the original file.
    throw new Error(`Cannot parse ${label}. No Codex settings were changed.`);
  }
}

function readConnection(path) {
  const config = readToml(readFileSync(path, 'utf8'), 'the generated connection file');
  const route = config.model_providers?.[config.model_provider];
  const endpoint = route?.base_url;
  const token = route?.experimental_bearer_token;
  const catalog = config.model_catalog_json;
  if (!/^http:\/\/127\.0\.0\.1:\d{1,5}\/v1$/.test(endpoint) ||
      !/^lp-[0-9a-f]{64}$/.test(token) ||
      !/^[A-Za-z0-9_.:/-]{1,100}$/.test(config.model) ||
      typeof catalog !== 'string' || !isAbsolute(catalog)) {
    throw new Error('The generated connection file is missing required fields.');
  }
  return { endpoint, token, model: config.model, catalog };
}

export function makeImportLink(connectionPath) {
  const { endpoint, token, model } = readConnection(connectionPath);
  // CC Switch intentionally drops filesystem pointers carried by import links.
  // Install the catalog pointer separately, only after this route is active.
  const config = toml.stringify({
    model_provider: 'custom', model,
    model_providers: {
      custom: {
        name: 'Local OpenAI Manager', base_url: endpoint, wire_api: 'responses',
        requires_openai_auth: false, supports_websockets: false, experimental_bearer_token: token,
      },
    },
  });
  const params = new URLSearchParams({
    resource: 'provider', app: 'codex', name: 'Local OpenAI Manager', endpoint, model,
    homepage: new URL(endpoint).origin, apiKey: token, apiFormat: 'openai_responses',
    enabled: 'true', notes: marker, configFormat: 'toml',
    config: Buffer.from(config).toString('base64'),
  });
  return `ccswitch://v1/import?${params}`;
}

function withCatalog(text, doc, catalog) {
  const expected = Object.assign(Object.create(null), doc, { model_catalog_json: catalog });
  const assignment = `model_catalog_json = ${JSON.stringify(catalog)}`;
  const bom = text.startsWith('\uFEFF') ? '\uFEFF' : '';
  const body = text.slice(bom.length);
  if (!Object.hasOwn(doc, 'model_catalog_json')) {
    const newline = text.includes('\r\n') ? '\r\n' : '\n';
    return bom + assignment + newline + body;
  }
  const pattern = /^[\t ]*(?:model_catalog_json|"model_catalog_json"|'model_catalog_json')[\t ]*=[^\r\n]*/gm;
  for (const match of body.matchAll(pattern)) {
    const candidate = bom + body.slice(0, match.index) + assignment + body.slice(match.index + match[0].length);
    try {
      if (isDeepStrictEqual(parse(candidate), expected)) return candidate;
    } catch {
      // A matching line may be inside a multiline TOML value.
    }
  }
  throw new Error('The existing model_catalog_json is not a single-line top-level setting.');
}

function isActiveRoute(doc, endpoint, token) {
  const route = typeof doc.model_provider === 'string' ? doc.model_providers?.[doc.model_provider] : null;
  // Require both the exact endpoint and the token from this manager installation.
  return route?.base_url === endpoint && route.experimental_bearer_token === token && !route.env_key &&
    !route.auth && route.wire_api === 'responses';
}

function readModelCatalog(catalog) {
  const text = readText(catalog);
  if (text === null) return null;
  try {
    const models = JSON.parse(text)?.models;
    return Array.isArray(models) ? models : null;
  } catch {
    return null;
  }
}

export function inspectActiveCatalog(connectionPath, configPath) {
  const { endpoint, token, catalog } = readConnection(connectionPath);
  const text = readText(configPath);
  if (text === null) return { status: 'missing_config' };
  const doc = readToml(text, 'the active Codex configuration');
  if (!isActiveRoute(doc, endpoint, token)) return { status: 'not_active' };
  if (!Object.hasOwn(doc, 'model_catalog_json')) return { status: 'missing_catalog' };
  if (typeof doc.model_catalog_json !== 'string' || !isAbsolute(doc.model_catalog_json) ||
      resolve(doc.model_catalog_json) !== resolve(catalog)) {
    return { status: 'different_catalog' };
  }
  const models = readModelCatalog(catalog);
  if (models === null) return { status: 'invalid_catalog' };
  const model = typeof doc.model === 'string' && /^[A-Za-z0-9_.:/-]{1,100}$/.test(doc.model) ? doc.model : null;
  const entry = models.find(entry => entry?.slug === model);
  if (!entry) return { status: 'model_not_listed', model };
  return { status: entry.use_responses_lite === false ? 'current' : 'lite_enabled', model };
}

export function syncActiveCatalog(connectionPath, configPath) {
  const { endpoint, token, catalog } = readConnection(connectionPath);
  const text = readText(configPath);
  if (text === null) return { status: 'not_active' };
  const doc = readToml(text, 'the active Codex configuration');
  if (!isActiveRoute(doc, endpoint, token)) return { status: 'not_active' };
  if (readModelCatalog(catalog) === null) {
    throw new Error('The packaged standard model catalog is missing or invalid.');
  }
  if (doc.model_catalog_json === catalog) return { status: 'current' };
  const updated = withCatalog(text, doc, catalog);
  const expected = Object.assign(Object.create(null), doc, { model_catalog_json: catalog });
  if (!isDeepStrictEqual(parse(updated), expected)) throw new Error('Could not preserve existing Codex settings.');

  const backup = `${configPath}.api-manager-${randomUUID()}.bak`;
  const temp = `${backup}.tmp`;
  writeFileSync(temp, updated, { encoding: 'utf8', flag: 'wx' });
  try {
    if (readText(configPath) !== text) return { status: 'retry' };
    writeFileSync(backup, text, { encoding: 'utf8', flag: 'wx' });
    if (readText(configPath) !== text) return { status: 'retry' };
    renameSync(temp, configPath);
  } finally {
    try { unlinkSync(temp); } catch (error) { if (error.code !== 'ENOENT') throw error; }
  }
  return { status: 'updated', backup };
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const [, , command, connection, config] = process.argv;
  try {
    if (command === 'link') console.log(makeImportLink(connection));
    else if (command === 'sync') console.log(JSON.stringify(syncActiveCatalog(connection, config)));
    else if (command === 'inspect') console.log(JSON.stringify(inspectActiveCatalog(connection, config)));
    else throw new Error('Expected link, sync or inspect.');
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
