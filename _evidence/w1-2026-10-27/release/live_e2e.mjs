import { chromium } from 'playwright';
import fs from 'node:fs';
import path from 'node:path';

const SITE = 'https://dukekang0124.github.io/chunkspoke/';
const WEB = 'https://dukekang0124.github.io/chunkspoke/web/';
const OUT = process.env.OUT || 'D:/tmp/w1e2e/out-live';
fs.mkdirSync(OUT, { recursive: true });

const rec = {
  at: new Date().toISOString(),
  siteConsoleErrors: [],
  webConsoleErrors: [],
  pageErrors: [],
  failedRequests: [],
  hosts: {},
  encodings: {},
  steps: [],
};
const step = (name, ok, extra = {}) => {
  rec.steps.push({ name, ok, ...extra });
  console.log(`${ok ? 'PASS' : 'FAIL'} ${name} ${JSON.stringify(extra)}`);
};

async function enableSemantics(page) {
  await page.waitForFunction(() => !!document.querySelector('flt-semantics-placeholder'), null, {
    timeout: 120000,
  });
  await page.evaluate(() => document.querySelector('flt-semantics-placeholder')?.click());
  await page.waitForTimeout(800);
}

async function clickText(page, text, { exact = true, timeout = 20000 } = {}) {
  const loc = page.getByText(text, { exact }).first();
  await loc.waitFor({ state: 'attached', timeout });
  await loc.click({ timeout });
  await page.waitForTimeout(700);
}

const bodyText = (page) => page.evaluate(() => document.body.innerText);

const browser = await chromium.launch({ channel: 'chrome' });
const context = await browser.newContext({ viewport: { width: 1440, height: 900 }, acceptDownloads: true });
const page = await context.newPage();

let phase = 'site';
page.on('console', (m) => {
  if (m.type() !== 'error') return;
  const where = m.location();
  (phase === 'site' ? rec.siteConsoleErrors : rec.webConsoleErrors).push(
    `${m.text()} @ ${where.url || '?'}:${where.lineNumber ?? '?'}`,
  );
});
page.on('pageerror', (e) => rec.pageErrors.push(String(e)));
page.on('response', (r) => {
  const u = new URL(r.url());
  rec.hosts[u.hostname] = (rec.hosts[u.hostname] || 0) + 1;
  const p = u.pathname;
  if (/(index\.html|main\.dart\.js|flutter_bootstrap\.js|canvaskit(\.wasm|\/chromium\/canvaskit\.wasm)|AssetManifest\.bin\.json|version\.json)$/.test(p)) {
    rec.encodings[p.split('/').slice(-2).join('/')] = {
      status: r.status(),
      contentEncoding: r.headers()['content-encoding'] || null,
      contentLength: r.headers()['content-length'] || null,
    };
  }
  if (r.status() >= 400) rec.failedRequests.push({ status: r.status(), url: r.url() });
});

// 1) 官网入口
await page.goto(SITE, { waitUntil: 'load', timeout: 120000 });
await page.screenshot({ path: path.join(OUT, 'live_01_site.png') });
const siteText = await bodyText(page);
step('site-entry-visible', siteText.includes('网页版 Beta') && siteText.includes('打开网页版'));

// 2) 点入口 → /web/
phase = 'web';
await Promise.all([
  page.waitForURL((u) => u.pathname.replace(/\/$/, '') === '/chunkspoke/web', { timeout: 120000 }),
  page.getByText('打开网页版', { exact: false }).first().click(),
]);
step('entry-click-navigates', page.url().startsWith(WEB), { url: page.url() });

await enableSemantics(page);
await page.waitForFunction(() => document.body.innerText.includes('487 块'), null, { timeout: 180000 });
const portal = await bodyText(page);
step('portal-content', portal.includes('487 块') && portal.includes('24 篇'));
await page.screenshot({ path: path.join(OUT, 'live_02_portal.png') });

// 3) 复习一张卡
await clickText(page, '复习');
await clickText(page, '新学', { exact: false }).catch(() => {});
await page.waitForTimeout(500);
await page.keyboard.press('Enter');
await page.waitForTimeout(1500);
const reviewText = await bodyText(page);
step('review-one-card', reviewText.includes('已加入复习') || reviewText.includes('已认识'), {
  snippet: reviewText.slice(0, 120).replace(/\s+/g, ' '),
});
await page.screenshot({ path: path.join(OUT, 'live_03_review.png') });

// 4) 导出 → 导入
await clickText(page, '数据');
await page.waitForTimeout(800);
let exportDoc = null;
try {
  const [dl] = await Promise.all([
    page.waitForEvent('download', { timeout: 30000 }),
    page.getByText('导出', { exact: true }).first().click(),
  ]);
  const file = path.join(OUT, 'live_export.json');
  await dl.saveAs(file);
  exportDoc = JSON.parse(fs.readFileSync(file, 'utf8'));
} catch (e) {
  rec.exportError = String(e);
}
step('export-schema-v1', !!exportDoc && exportDoc.schema_version === 1 && Array.isArray(exportDoc.chunks), {
  chunks: exportDoc?.chunks?.length,
  events: exportDoc?.events?.length,
});
await page.screenshot({ path: path.join(OUT, 'live_04_export.png') });

let previewOk = false;
let importOk = false;
try {
  const [chooser] = await Promise.all([
    page.waitForEvent('filechooser', { timeout: 30000 }),
    page.getByText('选择文件', { exact: true }).first().click(),
  ]);
  await chooser.setFiles(path.join(OUT, 'live_export.json'));
  await page.waitForFunction(() => document.body.innerText.includes('导入预览'), null, { timeout: 30000 });
  const preview = await bodyText(page);
  previewOk = preview.includes('预计新增');
  await page.screenshot({ path: path.join(OUT, 'live_05_preview.png') });
  await clickText(page, '合并导入');
  await page.waitForFunction(() => document.body.innerText.includes('导入完成'), null, { timeout: 30000 });
  importOk = (await bodyText(page)).includes('导入完成');
} catch (e) {
  rec.importError = String(e);
}
step('import-preview', previewOk);
step('import-merge-done', importOk);
await page.screenshot({ path: path.join(OUT, 'live_06_imported.png') });

rec.finalUrl = page.url();
rec.siteConsoleErrorCount = rec.siteConsoleErrors.length;
rec.webConsoleErrorCount = rec.webConsoleErrors.length;
rec.pageErrorCount = rec.pageErrors.length;
await browser.close();

fs.writeFileSync(path.join(OUT, 'live_summary.json'), JSON.stringify(rec, null, 2));
const hardFails =
  rec.steps.filter((s) => !s.ok).length +
  (rec.siteConsoleErrors.length ? 1 : 0) +
  (rec.webConsoleErrors.length ? 1 : 0) +
  (rec.pageErrors.length ? 1 : 0) +
  (rec.failedRequests.length ? 1 : 0);
console.log('console errors site/web:', rec.siteConsoleErrors.length, rec.webConsoleErrors.length);
console.log('page errors:', rec.pageErrors.length, 'failed requests:', rec.failedRequests.length);
console.log('hosts:', JSON.stringify(rec.hosts));
console.log('encodings:', JSON.stringify(rec.encodings, null, 1));
console.log(hardFails === 0 ? 'LIVE E2E: PASS' : `LIVE E2E: FAIL (${hardFails})`);
process.exitCode = hardFails === 0 ? 0 : 1;
