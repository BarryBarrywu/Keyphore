(() => {
  let saved;
  try { saved = localStorage.getItem('keyphore-language'); } catch {}
  const supported = ['en', 'zh-Hans', 'zh-Hant', 'ja', 'ko', 'fr', 'de', 'it', 'es'];
  const match = value => {
    const code = value.toLowerCase();
    if (code.startsWith('zh')) return /hant|tw|hk|mo/.test(code) ? 'zh-Hant' : 'zh-Hans';
    return supported.find(lang => lang === code.split('-')[0]);
  };
  document.documentElement.lang = supported.includes(saved) ? saved
    : (navigator.languages || [navigator.language]).map(match).find(Boolean) || 'en';
})();
