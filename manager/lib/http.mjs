/** Provider HTTP requests with bounded, validated JSON responses. */

const DEFAULT_MAX_RESPONSE_BYTES = 2 * 1024 * 1024;
const HEADER_NAME_PATTERN = /^[!#$%&'*+.^_`|~0-9A-Za-z-]+$/;

function getValueByPath(object, pathString) {
  if (!object || !pathString) return object;
  let current = object;
  for (const part of pathString.split('.').filter(Boolean)) {
    if (current === null || current === undefined || typeof current !== 'object') return undefined;
    current = current[part];
  }
  return current;
}

function buildModelsUrl(baseUrl, apiPath) {
  let parsed;
  try {
    parsed = new URL(baseUrl);
  } catch {
    throw new Error('Base URL must be an absolute URL.');
  }
  if (!['http:', 'https:'].includes(parsed.protocol)) throw new Error('Base URL must use http: or https:.');
  if (parsed.username || parsed.password) throw new Error('Base URL must not contain embedded credentials.');
  if (parsed.search || parsed.hash) throw new Error('Base URL must not contain a query string or fragment.');

  const cleanBase = parsed.toString().replace(/\/+$/, '');
  const cleanPath = String(apiPath || '/models').startsWith('/') ? String(apiPath || '/models') : `/${apiPath}`;
  return `${cleanBase}${cleanPath}`;
}

async function readBoundedBody(response, maximumBytes) {
  const declaredLength = Number(response.headers.get('content-length'));
  if (Number.isFinite(declaredLength) && declaredLength > maximumBytes) {
    throw new Error(`Provider response exceeds the ${maximumBytes}-byte limit.`);
  }
  if (!response.body) return '';

  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  let total = 0;
  let text = '';
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      total += value.byteLength;
      if (total > maximumBytes) {
        await reader.cancel();
        throw new Error(`Provider response exceeds the ${maximumBytes}-byte limit.`);
      }
      text += decoder.decode(value, { stream: true });
    }
    text += decoder.decode();
    return text;
  } finally {
    reader.releaseLock();
  }
}

function normalizeModelId(value) {
  if (value === undefined || value === null) return null;
  const id = String(value).trim();
  if (!id || id.length > 512 || /[\u0000-\u001f\u007f]/.test(id)) return null;
  return id;
}

export async function fetchModels(
  provider,
  baseUrl,
  apiKey = '',
  timeoutMs = 10000,
  maximumBytes = DEFAULT_MAX_RESPONSE_BYTES
) {
  if (typeof baseUrl !== 'string' || !baseUrl.trim()) {
    throw new Error('Base URL is required to fetch models.');
  }
  const fullUrl = buildModelsUrl(baseUrl.trim(), provider?.modelsApi?.path || '/models');
  const safeOrigin = new URL(fullUrl).origin;
  const headerName = provider?.modelsApi?.apiKeyHeader || provider?.apiKeyHeader || 'Authorization';
  if (!HEADER_NAME_PATTERN.test(headerName)) throw new Error('Configured API key header name is invalid.');
  const prefix = provider?.modelsApi?.apiKeyPrefix ?? provider?.apiKeyPrefix ?? 'Bearer ';
  const headers = { Accept: 'application/json' };
  if (apiKey) headers[headerName] = `${prefix}${apiKey}`;

  const controller = new AbortController();
  const timeoutId = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetch(fullUrl, {
      method: 'GET',
      headers,
      signal: controller.signal,
      redirect: 'error'
    });
    if (!response.ok) {
      throw new Error(`HTTP ${response.status} ${response.statusText || ''} when fetching models from ${safeOrigin}`.trim());
    }
    const contentType = response.headers.get('content-type') || '';
    if (!/(^|[+\/])json(?:;|$)/i.test(contentType)) {
      throw new Error(`Expected a JSON response from ${safeOrigin}; received '${contentType || 'unknown'}'.`);
    }

    const rawBody = await readBoundedBody(response, maximumBytes);
    let data;
    try {
      data = JSON.parse(rawBody);
    } catch {
      throw new Error(`Provider at ${safeOrigin} returned invalid JSON.`);
    }

    const itemsPath = provider?.modelsApi?.itemsPath || 'data';
    const idPath = provider?.modelsApi?.idPath || 'id';
    let items = getValueByPath(data, itemsPath);
    if (!Array.isArray(items)) items = Array.isArray(data) ? data : null;
    if (!items) throw new Error(`Provider response from ${safeOrigin} does not contain an array at '${itemsPath}'.`);

    const ids = [];
    const seen = new Set();
    for (const item of items) {
      const rawId = typeof item === 'string' ? item : getValueByPath(item, idPath);
      const id = normalizeModelId(rawId);
      if (id && !seen.has(id)) {
        seen.add(id);
        ids.push(id);
      }
    }
    return ids;
  } catch (error) {
    if (error.name === 'AbortError') {
      throw new Error(`Request timed out after ${timeoutMs / 1000}s when connecting to ${safeOrigin}.`);
    }
    throw error;
  } finally {
    clearTimeout(timeoutId);
  }
}
