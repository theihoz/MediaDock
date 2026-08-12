function clean(value) { return String(value ?? '').trim(); }

export function normalizeSubtitle(value, source) {
  const provider = clean(value.provider || (source === 'yify-direct' ? 'YIFY Direct' : source));
  const language = clean(value.language || value.code2 || value.lang).toLowerCase();
  const release = clean(value.release || value.name || value.title);
  return {
    id: clean(value.id) || `${source}:${provider}:${language}:${release}`,
    provider,
    source,
    language,
    release,
    score: Number(value.score ?? 0),
    hearingImpaired: Boolean(value.hearingImpaired ?? value.hearing_impaired ?? value.hi),
    format: clean(value.format || value.extension || 'srt').replace(/^\./, '').toLowerCase(),
    downloadToken: value.downloadToken ?? null,
  };
}

export function filterSubtitleResults(items, language, provider = 'all') {
  const expectedLanguage = clean(language).toLowerCase();
  const expectedProvider = clean(provider).toLowerCase();
  return items.filter(item => {
    const itemLanguage = clean(item.language || item.code2 || item.lang).toLowerCase();
    const itemProvider = clean(item.provider).toLowerCase();
    return (!expectedLanguage || itemLanguage === expectedLanguage) &&
      (!expectedProvider || expectedProvider === 'all' || itemProvider === expectedProvider);
  });
}

export function mergeSubtitleResults(groups) {
  const merged = new Map();
  for (const item of groups.flat()) {
    const key = `${clean(item.language).toLowerCase()}:${clean(item.release).toLowerCase()}`;
    const previous = merged.get(key);
    if (!previous || Number(item.score ?? 0) > Number(previous.score ?? 0)) merged.set(key, item);
  }
  return [...merged.values()];
}

export function shouldUseDirectFallback(options, bazarrResults) {
  return Boolean(options?.enabled) && bazarrResults.length === 0;
}
