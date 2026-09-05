(() => {
  const root = document.documentElement;
  const languagePicker = document.querySelector('.language-picker');
  const header = document.querySelector('.site-header');
  const menuButton = document.querySelector('.menu-toggle');
  const closeMenu = () => {
    header.removeAttribute('data-menu-open');
    menuButton.setAttribute('aria-expanded', 'false');
  };
  header.dataset.menuReady = '';
  menuButton.hidden = false;
  menuButton.addEventListener('click', () => {
    const open = header.toggleAttribute('data-menu-open');
    menuButton.setAttribute('aria-expanded', String(open));
  });
  matchMedia('(min-width: 961px)').addEventListener('change', closeMenu);
  const isGuide = document.body.dataset.page === 'guide';
  const copy = window.keyphoreTranslations;
  const demo = document.querySelector('.demo');
  const controls = document.querySelector('.signal-controls');
  const description = document.querySelector('.signal-description');

  const models = new Map([
    ['Air65V3', { name: 'Air65 V3 ANSI', sourceModel: 'Air65V3', supported: true }],
    ['Air75V3', { name: 'Air75 V3 ANSI', sourceModel: 'Air75V3', supported: true }]
  ]);
  const modelSelect = document.querySelector('#keyboard-model');
  let selectedModel = models.get('Air65V3');
  let selectedSignal = 'execution';
  let catalogFailed = false;

  function updateDemo() {
    const text = copy[root.lang];
    const supported = selectedModel.supported === true;
    demo.dataset.supported = String(supported);
    demo.dataset.signal = selectedSignal;
    document.querySelector('#model-name').textContent = selectedModel.name.toUpperCase();
    document.querySelector('#model-status').textContent = text[supported ? 'supported' : 'candidate'];
    document.querySelector('#supported-models').label = text.supported;
    document.querySelector('#candidate-models').label = text.candidate;
    for (const button of controls.querySelectorAll('button')) {
      button.setAttribute('aria-pressed', String(button.dataset.state === selectedSignal));
    }
    description.textContent = text[{ execution: 'execution', attention: 'attentionMessage', completion: 'completionMessage', off: 'offMessage' }[selectedSignal]];
    if (catalogFailed) document.querySelector('#catalog-note').textContent = text.catalogError;
  }

  function updateLanguage() {
    const text = copy[root.lang];
    document.querySelectorAll('[data-i18n]').forEach(element => {
      element.innerHTML = text[element.dataset.i18n];
    });
    const selected = languagePicker.querySelector('[data-language="' + root.lang + '"]');
    languagePicker.querySelector('.language-current').textContent = selected.textContent;
    languagePicker.querySelector('summary').setAttribute('aria-label', text.language);
    languagePicker.querySelectorAll('[data-language]').forEach(button => {
      button.setAttribute('aria-pressed', String(button === selected));
    });
    document.querySelectorAll('[data-tutti]').forEach(link => {
      link.href = root.lang.startsWith('zh') ? 'https://tutti.barrybarrywu.com/zh/' : 'https://tutti.barrybarrywu.com/';
    });
    document.title = isGuide ? text.install : 'Keyphore · ' + text.headline.replace('<br>', ' ');
    document.querySelector('meta[name="description"]').content = text.lead.replace('<br>', ' ');
    document.querySelector('nav').setAttribute('aria-label', text.navigation);
    menuButton.setAttribute('aria-label', text.navigation);
    const appPreview = document.querySelector('#app-preview');
    if (appPreview) {
      appPreview.src = root.lang.startsWith('zh') ? 'app-preview-zh.png' : 'app-preview-en.png';
      appPreview.alt = text.appScreenshotAlt;
    }
    if (demo) {
      demo.setAttribute('aria-label', text.demoLabel);
      controls.setAttribute('aria-label', text.signalLabel);
      updateDemo();
    }
  }
  languagePicker.hidden = false;
  languagePicker.querySelectorAll('[data-language]').forEach(button => {
    button.addEventListener('click', () => {
      root.lang = button.dataset.language;
      try { localStorage.setItem('keyphore-language', root.lang); } catch {}
      updateLanguage();
      languagePicker.open = false;
      languagePicker.querySelector('summary').focus();
    });
  });
  document.addEventListener('click', event => {
    if (!languagePicker.contains(event.target)) languagePicker.open = false;
    if (!header.contains(event.target)) closeMenu();
  });
  document.addEventListener('keydown', event => {
    if (event.key === 'Escape' && languagePicker.open) {
      languagePicker.open = false;
      languagePicker.querySelector('summary').focus();
    } else if (event.key === 'Escape' && header.hasAttribute('data-menu-open')) {
      closeMenu();
      menuButton.focus();
    }
  });
  document.addEventListener('keydown', () => root.classList.add('keyboard-input'));
  document.addEventListener('pointerdown', () => root.classList.remove('keyboard-input'));

  if (demo) {
    const svg = document.querySelector('#keyboard');
    renderKeyboard(svg, selectedModel);
    controls.hidden = false;
    document.querySelector('.model-picker').hidden = false;
    modelSelect.addEventListener('change', () => {
      selectedModel = models.get(modelSelect.value);
      renderKeyboard(svg, selectedModel);
      updateDemo();
    });
    for (const button of controls.querySelectorAll('button')) {
      button.addEventListener('click', () => {
        selectedSignal = button.dataset.state;
        updateDemo();
      });
    }
    fetch('keyboards.json')
      .then(response => {
        if (!response.ok) throw new Error('Catalog unavailable');
        return response.json();
      })
      .then(catalog => {
        const candidates = catalog.models.filter(model => !models.has(model.sourceModel))
          .sort((a, b) => a.name.localeCompare(b.name, 'en'));
        for (const model of candidates) {
          models.set(model.sourceModel, model);
          document.querySelector('#candidate-models').append(new Option(model.name, model.sourceModel));
        }
        modelSelect.dataset.loaded = 'true';
      })
      .catch(() => {
        catalogFailed = true;
        updateDemo();
      });
  }
  updateLanguage();
})();
