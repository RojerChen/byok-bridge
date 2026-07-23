/**
 * Helper module for Provider HTTP requests (e.g., fetching models).
 */

function getValueByPath(obj, pathStr) {
  if (!obj || !pathStr) return obj;
  const parts = pathStr.split('.').filter(Boolean);
  let curr = obj;
  for (const part of parts) {
    if (curr === null || curr === undefined || typeof curr !== 'object') {
      return undefined;
    }
    curr = curr[part];
  }
  return curr;
}

export async function fetchModels(provider, baseUrl, apiKey = '', timeoutMs = 10000) {
  if (!baseUrl || typeof baseUrl !== 'string' || !baseUrl.trim()) {
    throw new Error('Base URL is required to fetch models.');
  }

  const cleanBase = baseUrl.trim().replace(/\/+$/, '');
  const apiPath = provider?.modelsApi?.path || '/models';
  const cleanPath = apiPath.startsWith('/') ? apiPath : '/' + apiPath;
  const fullUrl = cleanBase + cleanPath;

  const headerName = provider?.modelsApi?.apiKeyHeader || provider?.apiKeyHeader || 'Authorization';
  const prefix = provider?.modelsApi?.apiKeyPrefix ?? provider?.apiKeyPrefix ?? 'Bearer ';

  const headers = {
    'Accept': 'application/json'
  };

  if (apiKey) {
    headers[headerName] = `${prefix}${apiKey}`;
  }

  const controller = new AbortController();
  const timeoutId = setTimeout(() => controller.abort(), timeoutMs);

  try {
    const response = await fetch(fullUrl, {
      method: 'GET',
      headers,
      signal: controller.signal,
      redirect: 'error' // Reject HTTP redirects for security
    });

    clearTimeout(timeoutId);

    if (!response.ok) {
      const status = response.status;
      const statusText = response.statusText || '';
      throw new Error(`HTTP ${status} ${statusText} when fetching models from ${cleanBase}`);
    }

    const contentType = response.headers.get('content-type') || '';
    if (!contentType.includes('json')) {
      throw new Error(`Expected JSON response from ${fullUrl}, got content-type: ${contentType}`);
    }

    const data = await response.json();
    const itemsPath = provider?.modelsApi?.itemsPath || 'data';
    const idPath = provider?.modelsApi?.idPath || 'id';

    let items = getValueByPath(data, itemsPath);
    if (!Array.isArray(items)) {
      if (Array.isArray(data)) {
        items = data;
      } else {
        items = [];
      }
    }

    const modelIds = [];
    for (const item of items) {
      if (typeof item === 'string') {
        modelIds.push(item);
      } else if (item && typeof item === 'object') {
        const idVal = getValueByPath(item, idPath);
        if (idVal !== undefined && idVal !== null) {
          modelIds.push(String(idVal));
        }
      }
    }

    return modelIds;
  } catch (err) {
    clearTimeout(timeoutId);
    if (err.name === 'AbortError') {
      throw new Error(`Request timed out after ${timeoutMs / 1000}s when connecting to ${cleanBase}`);
    }
    throw err;
  }
}
