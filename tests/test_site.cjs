const assert = require('node:assert/strict');
const { readFile } = require('node:fs/promises');
const http = require('node:http');
const path = require('node:path');
const { test } = require('node:test');
const { chromium } = require('playwright');

async function openNavigation(page) {
  if (!await page.locator('.nav-panel').isVisible()) {
    await page.locator('.menu-toggle').click();
    assert.equal(await page.locator('.menu-toggle').getAttribute('aria-expanded'), 'true');
  }
}

async function switchLanguage(page) {
  await openNavigation(page);
  await page.locator('.language-picker summary').click();
  const language = await page.locator('html').getAttribute('lang');
  await page.locator(`[data-language="${language === 'en' ? 'zh-Hans' : 'en'}"]`).click();
}

test('multilingual website, system appearance, signals and navigation', async () => {
  const root = path.resolve(__dirname, '../release/site');
  const files = new Set(['index.html', 'install.html', 'style.css', 'language.js', 'translations.js', 'site.js', 'keyboard.js', 'keyboards.json', 'icon.png', 'tutti.png', 'app-preview-zh.png', 'app-preview-en.png']);
  const types = { '.html': 'text/html', '.css': 'text/css', '.js': 'text/javascript', '.png': 'image/png', '.json': 'application/json' };
  const catalogText = await readFile(path.join(root, 'keyboards.json'), 'utf8');
  assert.equal(catalogText, await readFile(path.resolve(__dirname, '../app/Sources/KeyphoreCore/Resources/candidate-keyboards.json'), 'utf8'));
  const catalog = JSON.parse(catalogText);
  const server = http.createServer(async (request, response) => {
    const name = new URL(request.url, 'http://localhost').pathname.slice(1) || 'index.html';
    if (!files.has(name)) { response.writeHead(404).end(); return; }
    response.setHeader('Content-Type', types[path.extname(name)] + '; charset=utf-8');
    response.end(await readFile(path.join(root, name)));
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const browser = await chromium.launch({ headless: true });
  const url = `http://127.0.0.1:${server.address().port}`;
  let combinations = 0;
  try {
    for (const locale of ['zh-CN', 'zh-TW', 'en-US', 'de-DE']) {
      for (const colorScheme of ['light', 'dark']) {
        for (const width of [320, 1440]) {
          const context = await browser.newContext({ locale, colorScheme, viewport: { width, height: 1000 } });
          const page = await context.newPage();
          const errors = [];
          page.on('pageerror', error => errors.push(error.message));
          page.on('response', response => { if (response.status() >= 400) errors.push(`${response.status()}: ${response.url()}`); });
          await page.goto(url);
          const language = ({ 'zh-CN': 'zh-Hans', 'zh-TW': 'zh-Hant', 'en-US': 'en', 'de-DE': 'de' })[locale];
          assert.equal(await page.locator('html').getAttribute('lang'), language);
          assert.equal(await page.locator('.language-picker').isVisible(), width > 960);
          await openNavigation(page);
          assert.equal(await page.locator('.language-picker').isVisible(), true);
          if (width <= 960) {
            await page.keyboard.press('Escape');
            assert.equal(await page.locator('.menu-toggle').getAttribute('aria-expanded'), 'false');
            assert.equal(await page.locator('.nav-panel').isVisible(), false);
          }
          assert.equal(await page.locator('.download-button').getAttribute('href'), 'https://github.com/BarryBarrywu/Keyphore/releases/latest');
          assert.equal(await page.locator('[data-i18n="downloadApp"]').innerText(), await page.evaluate(() => keyphoreTranslations[document.documentElement.lang].downloadApp));
          assert.doesNotMatch(await page.locator('body').innerText(), /安装包尚未|Download coming later|此型号仅展示布局|Layout preview only/);
          assert.equal(await page.locator('.brand-mark').evaluate(node => node.complete && node.naturalWidth > 0), true);
          assert.equal(await page.locator('#keyboard .key-light').count(), 67);
          assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true);
          const background = () => page.evaluate(() => getComputedStyle(document.documentElement).backgroundColor);
          assert.equal(await background(), colorScheme === 'dark' ? 'rgb(24, 25, 28)' : 'rgb(250, 250, 250)');
          for (const [state, color] of [['execution', 'rgb(0, 0, 255)'], ['attention', 'rgb(255, 132, 0)'], ['completion', 'rgb(0, 255, 0)'], ['off', 'rgba(0, 0, 0, 0)']]) {
            await page.locator(`[data-state="${state}"]`).click();
            assert.equal(await page.locator('.demo').getAttribute('data-signal'), state);
            assert.equal(await page.locator('.signal-controls [aria-pressed="true"]').count(), 1);
            assert.equal(await page.locator('.key-light').first().evaluate(node => getComputedStyle(node).fill), color);
          }
          await page.locator('[data-state="attention"]').focus();
          await page.keyboard.press('Enter');
          assert.equal(await page.locator('.demo').getAttribute('data-signal'), 'attention');
          assert.equal(await page.locator('[data-state="attention"]').evaluate(node => getComputedStyle(node).transitionDuration), '0s');
          await page.locator('#keyboard-model[data-loaded="true"]').waitFor();
          assert.equal(await page.locator('#keyboard-model option').count(), catalog.models.length + 1);
          for (const model of catalog.models) {
            await page.selectOption('#keyboard-model', model.sourceModel);
            assert.equal(await page.locator('#keyboard').getAttribute('data-model'), model.sourceModel);
            assert.equal(await page.locator('#model-name').innerText(), (model.sourceModel === 'Air75V3' ? 'Air75 V3 ANSI' : model.name).toUpperCase());
            const supported = model.sourceModel === 'Air75V3';
            assert.equal(await page.locator('.demo').getAttribute('data-supported'), String(supported));
            assert.equal(await page.locator('[data-state="attention"]').isDisabled(), false);
            for (const [state, color] of [['execution', 'rgb(0, 0, 255)'], ['completion', 'rgb(0, 255, 0)'], ['off', 'rgba(0, 0, 0, 0)'], ['attention', 'rgb(255, 132, 0)']]) {
              await page.locator(`[data-state="${state}"]`).click();
              assert.equal(await page.locator('.demo').getAttribute('data-signal'), state);
              assert.equal(await page.locator('.signal-controls [aria-pressed="true"]').count(), 1);
              assert.equal(await page.locator('.key-light').first().evaluate(node => getComputedStyle(node).fill), color);
            }
            assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true);
            assert.equal(await page.locator('#keyboard').evaluate(svg => {
              const box = svg.viewBox.baseVal;
              return [...svg.querySelectorAll('.key-base')].every(key => {
                const bounds = key.getBBox();
                return bounds.x >= 0 && bounds.y >= 0 && bounds.x + bounds.width <= box.width && bounds.y + bounds.height <= box.height;
              });
            }), true);
          }
          await page.selectOption('#keyboard-model', 'Node100HighJIS');
          await switchLanguage(page);
          assert.equal(await page.locator('#keyboard').getAttribute('data-model'), 'Node100HighJIS');
          assert.equal(await page.locator('#model-status').innerText(), language === 'en' ? '候选型号 · 待验证' : 'Candidate · Unverified');
          assert.equal(await page.locator('[data-state="attention"]').isDisabled(), false);
          await switchLanguage(page);
          await page.selectOption('#keyboard-model', 'Air65V3');
          assert.equal(await page.locator('.demo').getAttribute('data-signal'), 'attention');
          await switchLanguage(page);
          const switched = language === 'en' ? 'zh-Hans' : 'en';
          assert.equal(await page.locator('html').getAttribute('lang'), switched);
          assert.equal(await page.locator('.demo').getAttribute('data-signal'), 'attention');
          await page.reload();
          assert.equal(await page.locator('html').getAttribute('lang'), switched);
          await openNavigation(page);
          await page.locator('nav a[href="install.html"]').click();
          assert.equal(new URL(page.url()).pathname, '/install.html');
          assert.equal(await page.locator('html').getAttribute('lang'), switched);
          assert.equal(await page.title(), switched === 'en' ? 'Install Keyphore' : '安装 Keyphore');
          assert.equal(await page.locator('.download-button').getAttribute('href'), 'https://github.com/BarryBarrywu/Keyphore/releases/latest');
          assert.doesNotMatch(await page.locator('body').innerText(), /安装包尚未|not available yet/);
          assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true);
          await page.emulateMedia({ colorScheme: colorScheme === 'dark' ? 'light' : 'dark' });
          assert.equal(await background(), colorScheme === 'light' ? 'rgb(24, 25, 28)' : 'rgb(250, 250, 250)');
          await page.emulateMedia({ reducedMotion: 'reduce' });
          assert.equal(await page.locator('.primary-button').first().evaluate(node => getComputedStyle(node).transitionDuration), '0s');
          assert.deepEqual(errors, []);
          await context.close();
          combinations++;
        }
      }
    }
    const context = await browser.newContext({ locale: 'en-US' });
    await context.addInitScript(() => {
      Object.defineProperty(window, 'localStorage', { get() { throw new DOMException('Blocked', 'SecurityError'); } });
    });
    const page = await context.newPage();
    await page.goto(url);
    assert.equal(await page.locator('html').getAttribute('lang'), 'en');
    await switchLanguage(page);
    assert.equal(await page.locator('html').getAttribute('lang'), 'zh-Hans');
    await context.close();
    const failedCatalog = await browser.newContext({ locale: 'en-US' });
    const failedPage = await failedCatalog.newPage();
    await failedPage.route('**/keyboards.json', route => route.fulfill({ status: 503, body: 'Unavailable' }));
    await failedPage.goto(url);
    await failedPage.getByText('The model catalog could not load. Refresh the page to try again.').waitFor();
    assert.equal(await failedPage.locator('#keyboard-model option').count(), 2);
    await failedPage.selectOption('#keyboard-model', 'Air75V3');
    assert.equal(await failedPage.locator('#keyboard').getAttribute('data-model'), 'Air75V3');
    await failedCatalog.close();
    const noScript = await browser.newContext({ javaScriptEnabled: false });
    const staticPage = await noScript.newPage();
    await staticPage.goto(url);
    assert.equal(await staticPage.locator('h1').innerText(), 'Codex status.\nRight on your keyboard.');
    assert.equal(await staticPage.locator('noscript').isVisible(), true);
    assert.equal(await staticPage.locator('.language-picker').isVisible(), false);
    await noScript.close();
    console.log(`Verified ${combinations} locale/theme/viewport combinations with all ${catalog.models.length + 1} models, catalog parity, storage denial, and no-JS fallback.`);
  } finally {
    await browser.close();
    await new Promise(resolve => server.close(resolve));
  }
});
