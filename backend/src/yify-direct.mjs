const challenge = /checking your browser|cloudflare|captcha|attention required/i;

function attributes(tag) {
  const result = {};
  for (const match of tag.matchAll(/([\w-]+)=["']([^"']*)["']/g)) result[match[1]] = match[2];
  return result;
}

export class YifyDirectProvider {
  constructor({ enabled = false, baseUrl = '', fetchImpl = fetch, timeoutMs = 10000, maxBytes = 5 * 1024 * 1024 }) {
    this.enabled = enabled; this.baseUrl = baseUrl.replace(/\/$/, ''); this.fetchImpl = fetchImpl;
    this.timeoutMs = timeoutMs; this.maxBytes = maxBytes;
  }

  ensureEnabled() { if (!this.enabled) throw new Error('provider_disabled'); }

  async request(url, { allowNotFound = false } = {}) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), this.timeoutMs);
    try {
      const response = await this.fetchImpl(url, { signal: controller.signal, redirect: 'follow' });
      if (allowNotFound && response?.status === 404) return response;
      if (!response?.ok) throw new Error('provider_unavailable');
      return response;
    } catch (error) {
      if (error.message === 'provider_unavailable') throw error;
      throw new Error('provider_unavailable');
    } finally { clearTimeout(timer); }
  }

  async search(movie, language) {
    this.ensureEnabled();
    if (!this.baseUrl || !movie?.imdbId || !/^(vi|en)$/.test(language)) throw new Error('invalid_request');
    const response = await this.request(`${this.baseUrl}/movie-imdb/${encodeURIComponent(movie.imdbId)}`, { allowNotFound: true });
    if (response.status === 404) return [];
    const html = await response.text();
    if (challenge.test(html)) throw new Error('provider_unavailable');
    const results = [];
    const languageName = language === 'vi' ? 'Vietnamese' : 'English';
    for (const match of html.matchAll(/<tr\b[^>]*data-id=["'][^"']+["'][^>]*>[\s\S]*?<\/tr>/gi)) {
      const row = match[0];
      const item = attributes(row.match(/<a\b[^>]*href=["'][^"']+["'][^>]*>/i)?.[0] ?? '');
      const foundLanguage = row.match(/class=["']sub-lang["'][^>]*>([^<]+)/i)?.[1]?.trim();
      if (foundLanguage !== languageName || !item.href) continue;
      const release = row.match(/<a\b[^>]*>[\s\S]*?<span[^>]*>subtitle<\/span>\s*([\s\S]*?)<\/a>/i)?.[1]
        ?.replace(/<br\s*\/?>/gi, ' / ').replace(/<[^>]+>/g, '').trim();
      const score = Number(row.match(/class=["'][^"']*label[^"']*["'][^>]*>(-?\d+)/i)?.[1] ?? 0);
      results.push({
        provider: 'YIFY Direct', source: 'yify-direct', language,
        release: release || `${movie.title} ${movie.year}`,
        score, hearingImpaired: /hi-subtitle/i.test(row),
        format: 'zip', subtitleId: item.href,
      });
    }
    return results;
  }

  async download(subtitleId) {
    this.ensureEnabled();
    if (!subtitleId?.startsWith('/')) throw new Error('invalid_subtitle_url');
    const resolved = new URL(subtitleId, `${this.baseUrl}/`);
    if (resolved.origin !== new URL(this.baseUrl).origin) throw new Error('invalid_subtitle_url');
    let response = await this.request(resolved);
    if (!/\.(srt|vtt|ass|zip)$/i.test(resolved.pathname)) {
      const html = await response.text();
      if (challenge.test(html)) throw new Error('provider_unavailable');
      const href = html.match(/class=["'][^"']*download-subtitle[^"']*["'][^>]*href=["']([^"']+)/i)?.[1];
      if (!href) throw new Error('download_failed');
      const downloadUrl = new URL(href, `${this.baseUrl}/`);
      if (downloadUrl.origin !== new URL(this.baseUrl).origin) throw new Error('invalid_subtitle_url');
      response = await this.request(downloadUrl);
      resolved.pathname = downloadUrl.pathname;
    }
    const buffer = Buffer.from(await response.arrayBuffer());
    if (!buffer.length) throw new Error('empty subtitle');
    if (buffer.length > this.maxBytes) throw new Error('subtitle too large');
    const format = resolved.pathname.split('.').pop()?.toLowerCase();
    if (!['srt', 'vtt', 'ass', 'zip'].includes(format)) throw new Error('unsupported format');
    return { buffer, format };
  }
}
