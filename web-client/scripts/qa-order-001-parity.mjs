import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { chromium } from 'playwright';

const now = new Date();
const runId = process.env.RUN_ID ?? now.toISOString().replace(/[-:]/g, '').replace(/\..+/, 'Z');
const baseURL = process.env.QA_BASE_URL ?? process.env.PLAYWRIGHT_BASE_URL ?? 'http://localhost:5176';

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(scriptDir, '..', '..');

const artifactRoot =
  process.env.QA_ARTIFACT_DIR ??
  path.resolve(repoRoot, 'artifacts', 'verification', runId, 'order-001-parity');
const screenshotDir = path.join(artifactRoot, 'screenshots');

fs.mkdirSync(screenshotDir, { recursive: true });
fs.mkdirSync(artifactRoot, { recursive: true });

const facilityPath = path.resolve(repoRoot, 'facility.json');
const facilityJson = JSON.parse(fs.readFileSync(facilityPath, 'utf-8'));
const facilityId = String(facilityJson.facilityId ?? '0001');

const authUserId = process.env.QA_USER_ID ?? 'doctor1';
const authPasswordPlain = process.env.QA_PASSWORD_PLAIN ?? 'doctor2025';
const authPasswordMd5 = process.env.QA_PASSWORD_MD5 ?? '632080fabdb968f9ac4f31fb55104648';

const patientId = process.env.QA_PATIENT_ID ?? '01415';

const session = {
  facilityId,
  userId: authUserId,
  displayName: `QA ${authUserId}`,
  clientUuid: `qa-${runId}`,
  runId,
  role: 'admin',
  roles: ['admin'],
};

const writePageShot = async (page, name, opts = {}) => {
  const fileName = `${name}.png`;
  const filePath = path.join(screenshotDir, fileName);
  await page.screenshot({ path: filePath, ...opts });
  return `screenshots/${fileName}`;
};

const writeLocatorShot = async (locator, name, opts = {}) => {
  const fileName = `${name}.png`;
  const filePath = path.join(screenshotDir, fileName);
  await locator.screenshot({ path: filePath, ...opts });
  return `screenshots/${fileName}`;
};

const jsonOrText = async (response) => {
  try {
    return await response.json();
  } catch {
    try {
      return await response.text();
    } catch {
      return null;
    }
  }
};

const captureOrderBundleTraffic = (page) => {
  const events = [];
  page.on('request', (req) => {
    const url = req.url();
    if (!url.includes('/orca/order/bundles')) return;
    events.push({
      kind: 'request',
      at: new Date().toISOString(),
      method: req.method(),
      url,
      postData: req.postData() ?? null,
    });
  });
  page.on('response', async (res) => {
    const url = res.url();
    if (!url.includes('/orca/order/bundles')) return;
    const req = res.request();
    events.push({
      kind: 'response',
      at: new Date().toISOString(),
      method: req.method(),
      url,
      status: res.status(),
      statusText: res.statusText(),
      body: await jsonOrText(res),
    });
  });
  return events;
};

const run = async () => {
  const summary = {
    runId,
    executedAt: new Date().toISOString(),
    baseURL,
    facilityId,
    patientId,
    medOrder: {
      bundleName: `ORDER-001 処方 ${runId}`,
      saved: false,
      uiListed: false,
      recordsReturned: null,
    },
    generalOrder: {
      bundleName: `ORDER-001 オーダー ${runId}`,
      saved: false,
      uiListed: false,
      recordsReturned: null,
    },
    actionBar: {
      sendDisabled: null,
      sendDisabledReason: null,
      finishDisabled: null,
      finishDisabledReason: null,
      sendDialogOpened: false,
    },
    errors: [],
    evidence: {
      screenshots: [],
      network: 'orca-order-bundles.network.json',
      summaryJson: 'summary.json',
      summaryMd: 'summary.md',
    },
  };

  const browser = await chromium.launch({ headless: true });
  const context = await browser.newContext({ ignoreHTTPSErrors: true, baseURL });
  await context.addInitScript(
    ([key, value, auth]) => {
      window.sessionStorage.setItem(key, value);
      window.sessionStorage.setItem('devFacilityId', auth.facilityId);
      window.sessionStorage.setItem('devUserId', auth.userId);
      window.sessionStorage.setItem('devPasswordMd5', auth.passwordMd5);
      window.sessionStorage.setItem('devPasswordPlain', auth.passwordPlain);
      window.sessionStorage.setItem('devClientUuid', auth.clientUuid);
      window.sessionStorage.setItem(
        `opendolphin:web-client:charts:encounter-context:v2:${auth.facilityId}:${auth.userId}`,
        JSON.stringify({ patientId: auth.patientId }),
      );
      window.localStorage.setItem('devFacilityId', auth.facilityId);
      window.localStorage.setItem('devUserId', auth.userId);
      window.localStorage.setItem('devPasswordMd5', auth.passwordMd5);
      window.localStorage.setItem('devPasswordPlain', auth.passwordPlain);
      window.localStorage.setItem('devClientUuid', auth.clientUuid);
    },
    [
      'opendolphin:web-client:auth',
      JSON.stringify(session),
      {
        facilityId,
        userId: authUserId,
        passwordMd5: authPasswordMd5,
        passwordPlain: authPasswordPlain,
        clientUuid: session.clientUuid,
        patientId,
      },
    ],
  );

  const page = await context.newPage();
  const traffic = captureOrderBundleTraffic(page);

  try {
    const chartUrl = `/f/${encodeURIComponent(facilityId)}/charts?patientId=${encodeURIComponent(patientId)}`;
    await page.goto(chartUrl, { waitUntil: 'domcontentloaded' });
    await page.locator('.charts-page').waitFor({ timeout: 30000 });

    // Best-effort: if MSW scenario controller exists, prefer server-handoff for /orca/* passthrough.
    await page
      .waitForFunction(() => window.__OUTPATIENT_SCENARIO__?.select, { timeout: 3000 })
      .then(async () => {
        await page.evaluate(() => {
          window.__OUTPATIENT_SCENARIO__.select('server-handoff');
        });
      })
      .catch(() => {});

    // Evidence: avoid full-page (patient info). Capture only side panel + action controls.
    const utilityTabs = page.locator('[data-utility-action="prescription-edit"], [data-utility-action="order-edit"]');
    await utilityTabs.first().waitFor({ state: 'visible', timeout: 30000 });

    summary.evidence.screenshots.push(await writeLocatorShot(page.locator('#charts-actionbar'), '00-actionbar'));

    // 1) medOrder create/save
    await page.locator('[data-utility-action="prescription-edit"]').click();
    await page.locator('[data-test-id="medOrder-edit-panel"]').waitFor({ timeout: 30000 });

    await page.locator('#medOrder-bundle-name').fill(summary.medOrder.bundleName);
    await page.locator('#medOrder-admin').fill('1日1回');
    await page.locator('#medOrder-item-name-0').fill('アムロジピン');
    await page.locator('#medOrder-item-quantity-0').fill('1');
    await page.locator('#medOrder-item-unit-0').fill('錠');

    summary.evidence.screenshots.push(
      await writeLocatorShot(page.locator('.charts-side-panel'), '01-medOrder-filled'),
    );

    const medSaveRespPromise = page
      .waitForResponse(
        (response) =>
          response.url().includes('/orca/order/bundles') && response.request().method() === 'POST',
        { timeout: 20000 },
      )
      .catch(() => null);
    await page.locator('form.charts-side-panel__form button[type="submit"]').first().click();
    const medSaveResp = await medSaveRespPromise;
    summary.medOrder.saved = Boolean(medSaveResp && medSaveResp.ok());

    await page.waitForTimeout(800);
    summary.evidence.screenshots.push(
      await writeLocatorShot(page.locator('.charts-side-panel'), '02-medOrder-after-save'),
    );

    const medList = page.locator('.charts-side-panel__items');
    summary.medOrder.uiListed = await medList
      .getByText(summary.medOrder.bundleName)
      .first()
      .waitFor({ timeout: 8000 })
      .then(() => true)
      .catch(() => false);

    const medBundlesResp = await page.request.get(
      `/orca/order/bundles?patientId=${encodeURIComponent(patientId)}&entity=medOrder`,
    );
    if (medBundlesResp.ok()) {
      const payload = await medBundlesResp.json().catch(() => null);
      if (payload && typeof payload.recordsReturned === 'number') {
        summary.medOrder.recordsReturned = payload.recordsReturned;
      }
    }

    // 2) generalOrder create/save
    await page.locator('[data-utility-action="order-edit"]').click();
    await page.locator('[data-test-id="generalOrder-edit-panel"]').waitFor({ timeout: 30000 });

    await page.locator('#generalOrder-bundle-name').fill(summary.generalOrder.bundleName);
    await page.locator('#generalOrder-item-name-0').fill('処置A');
    await page.locator('#generalOrder-item-quantity-0').fill('1');
    await page.locator('#generalOrder-item-unit-0').fill('回');

    summary.evidence.screenshots.push(
      await writeLocatorShot(page.locator('.charts-side-panel'), '03-generalOrder-filled'),
    );

    const generalSaveRespPromise = page
      .waitForResponse(
        (response) =>
          response.url().includes('/orca/order/bundles') && response.request().method() === 'POST',
        { timeout: 20000 },
      )
      .catch(() => null);
    await page.locator('form.charts-side-panel__form button[type="submit"]').first().click();
    const generalSaveResp = await generalSaveRespPromise;
    summary.generalOrder.saved = Boolean(generalSaveResp && generalSaveResp.ok());

    await page.waitForTimeout(800);
    summary.evidence.screenshots.push(
      await writeLocatorShot(page.locator('.charts-side-panel'), '04-generalOrder-after-save'),
    );

    const generalList = page.locator('.charts-side-panel__items');
    summary.generalOrder.uiListed = await generalList
      .getByText(summary.generalOrder.bundleName)
      .first()
      .waitFor({ timeout: 8000 })
      .then(() => true)
      .catch(() => false);

    const generalBundlesResp = await page.request.get(
      `/orca/order/bundles?patientId=${encodeURIComponent(patientId)}&entity=generalOrder`,
    );
    if (generalBundlesResp.ok()) {
      const payload = await generalBundlesResp.json().catch(() => null);
      if (payload && typeof payload.recordsReturned === 'number') {
        summary.generalOrder.recordsReturned = payload.recordsReturned;
      }
    }

    // 3) send/finish entry: it is OK if blocked; we must show reasons.
    const actionBar = page.locator('#charts-actionbar');
    await actionBar.waitFor({ timeout: 20000 });

    const sendBtn = page.locator('#charts-action-send');
    const finishBtn = page.locator('#charts-action-finish');

    const sendDisabled = await sendBtn.isDisabled().catch(() => null);
    const finishDisabled = await finishBtn.isDisabled().catch(() => null);
    summary.actionBar.sendDisabled = sendDisabled;
    summary.actionBar.finishDisabled = finishDisabled;
    summary.actionBar.sendDisabledReason = (await sendBtn.getAttribute('data-disabled-reason').catch(() => null)) ?? null;
    summary.actionBar.finishDisabledReason = (await finishBtn.getAttribute('data-disabled-reason').catch(() => null)) ?? null;

    if (sendDisabled === false) {
      await sendBtn.click();
      const dialog = page.locator('[data-test-id="charts-send-dialog"]');
      summary.actionBar.sendDialogOpened = await dialog
        .waitFor({ timeout: 8000 })
        .then(() => true)
        .catch(() => false);
      if (summary.actionBar.sendDialogOpened) {
        summary.evidence.screenshots.push(await writeLocatorShot(dialog, '05-send-dialog'));
        await dialog.getByRole('button', { name: 'キャンセル' }).click().catch(() => {});
      }
    } else {
      const guard = actionBar.locator('.charts-actions__guard-summary');
      const guardVisible = await guard.isVisible().catch(() => false);
      if (guardVisible) {
        summary.evidence.screenshots.push(await writeLocatorShot(guard, '05-send-guard-summary'));
      } else {
        // Always keep at least the controls evidence.
        summary.evidence.screenshots.push(await writeLocatorShot(actionBar.locator('.charts-actions__controls'), '05-action-controls'));
      }
    }
  } catch (error) {
    summary.errors.push(String(error));
    try {
      summary.evidence.screenshots.push(await writePageShot(page, 'error', { fullPage: false }));
    } catch {}
  } finally {
    fs.writeFileSync(path.join(artifactRoot, summary.evidence.network), JSON.stringify(traffic, null, 2));
    fs.writeFileSync(path.join(artifactRoot, summary.evidence.summaryJson), JSON.stringify(summary, null, 2));

    const md = [
      '# ORDER-001 Parity Evidence (Order Edit Minimal Ops)',
      `- RUN_ID: ${summary.runId}`,
      `- baseURL: ${summary.baseURL}`,
      `- facilityId: ${summary.facilityId}`,
      `- patientId: ${summary.patientId}`,
      '',
      '## Minimal Operation Set',
      `- (1) Charts open: OK (charts-page)`,
      `- (2) medOrder add/save: saved=${summary.medOrder.saved} uiListed=${summary.medOrder.uiListed} recordsReturned=${summary.medOrder.recordsReturned ?? 'n/a'}`,
      `- (3) generalOrder add/save: saved=${summary.generalOrder.saved} uiListed=${summary.generalOrder.uiListed} recordsReturned=${summary.generalOrder.recordsReturned ?? 'n/a'}`,
      `- (4) Persistence: GET /orca/order/bundles recordsReturned captured above (if n/a, rely on UI list evidence)`,
      `- (5) Send/finish: sendDisabled=${String(summary.actionBar.sendDisabled)} reason=${summary.actionBar.sendDisabledReason ?? 'n/a'} finishDisabled=${String(summary.actionBar.finishDisabled)} reason=${summary.actionBar.finishDisabledReason ?? 'n/a'}`,
      '',
      '## Evidence',
      `- screenshots: ${summary.evidence.screenshots.length} files under ${summary.evidence.screenshots.length ? 'screenshots/' : '(none)'} `,
      `- network: ${summary.evidence.network}`,
      `- summary: ${summary.evidence.summaryJson}`,
      '',
      summary.errors.length ? '## Errors\n' + summary.errors.map((e) => `- ${e}`).join('\n') : '',
    ]
      .filter(Boolean)
      .join('\n');
    fs.writeFileSync(path.join(artifactRoot, summary.evidence.summaryMd), md);

    await context.close();
    await browser.close();
  }
};

run().catch((error) => {
  console.error(error);
  process.exit(1);
});

