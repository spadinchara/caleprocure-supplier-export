#!/usr/bin/env node
// Downloads the full Cal eProcure certified supplier list (SB, MB, SB-PW, DVBE, NVSA, NP).
//
// Flow, mirroring the manual process:
//   1. Open the public supplier search page.
//   2. Leave every criterion blank and click "Search".
//   3. Wait for the "Loading..." overlay to clear and the results toolbar to appear.
//   4. Click "Download" in the results toolbar and wait for the overlay again.
//   5. In the "Your file is ready." modal, click "Download Attachment".
//   6. Save the file under the server's default file name.

const fs = require('fs');
const path = require('path');
const { chromium } = require('playwright');

const DEFAULT_URL = 'https://caleprocure.ca.gov/pages/PublicSearch/supplier-search.aspx?psNewWin=true';

function parseArgs(argv) {
  const opts = {
    url: process.env.CALEPROCURE_URL || DEFAULT_URL,
    outDir: process.env.CALEPROCURE_OUT_DIR || path.join(process.cwd(), 'downloads'),
    // The unfiltered search and the export both build ~22k records server-side, so allow minutes.
    timeoutMs: Number(process.env.CALEPROCURE_TIMEOUT_MS) || 10 * 60 * 1000,
    headed: false,
    retries: Number(process.env.CALEPROCURE_RETRIES) || 2,
  };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === '--url') opts.url = argv[++i];
    else if (arg === '--out') opts.outDir = argv[++i];
    else if (arg === '--timeout') opts.timeoutMs = Number(argv[++i]) * 1000;
    else if (arg === '--retries') opts.retries = Number(argv[++i]);
    else if (arg === '--headed') opts.headed = true;
    else if (arg === '-h' || arg === '--help') {
      console.log('Usage: node export-suppliers.js [--out DIR] [--timeout SECONDS] [--retries N] [--headed] [--url URL]');
      process.exit(0);
    } else {
      throw new Error(`Unknown argument: ${arg}`);
    }
  }
  return opts;
}

function log(msg) {
  console.log(`[${new Date().toISOString()}] ${msg}`);
}

// Finds a visible button or link whose text is exactly `name`, in the page or any frame.
async function findClickable(page, name, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  const exact = new RegExp(`^\\s*${name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}\\s*$`, 'i');
  while (Date.now() < deadline) {
    for (const frame of page.frames()) {
      const candidates = [
        frame.getByRole('button', { name, exact: true }),
        frame.getByRole('link', { name, exact: true }),
        frame.locator('button, a, [role=button]').filter({ hasText: exact }),
        frame.locator(`input[type=button][value="${name}" i], input[type=submit][value="${name}" i]`),
      ];
      for (const locator of candidates) {
        const count = await locator.count().catch(() => 0);
        for (let i = 0; i < count; i++) {
          const el = locator.nth(i);
          if (await el.isVisible().catch(() => false)) return el;
        }
      }
    }
    await page.waitForTimeout(500);
  }
  throw new Error(`Timed out waiting for a visible "${name}" button`);
}

// Waits until the "Loading..." overlay has appeared (if it does) and then disappeared.
async function waitForLoadingToClear(page, timeoutMs) {
  const spinner = page.getByText('Loading...', { exact: false });
  await spinner.first().waitFor({ state: 'visible', timeout: 15000 }).catch(() => {});
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    let visible = false;
    for (const frame of page.frames()) {
      const loc = frame.getByText('Loading...', { exact: false });
      const count = await loc.count().catch(() => 0);
      for (let i = 0; i < count && !visible; i++) {
        visible = await loc.nth(i).isVisible().catch(() => false);
      }
      if (visible) break;
    }
    if (!visible) return;
    await page.waitForTimeout(1000);
  }
  throw new Error('Timed out waiting for the Loading... overlay to clear');
}

// Resolves with the first download started by the page or any popup it opens.
function waitForAnyDownload(context, timeoutMs) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      context.off('page', onPage);
      reject(new Error('Timed out waiting for the file download to start'));
    }, timeoutMs);
    const onDownload = (download) => {
      clearTimeout(timer);
      context.off('page', onPage);
      resolve(download);
    };
    const onPage = (p) => p.once('download', onDownload);
    context.pages().forEach(onPage);
    context.on('page', onPage);
  });
}

async function runOnce(opts) {
  const browser = await chromium.launch({ headless: !opts.headed });
  try {
    const context = await browser.newContext({ acceptDownloads: true });
    const page = await context.newPage();
    page.setDefaultTimeout(opts.timeoutMs);

    log(`Opening ${opts.url}`);
    await page.goto(opts.url, { waitUntil: 'domcontentloaded', timeout: 120000 });

    log('Clicking Search with no criteria');
    await (await findClickable(page, 'Search', 120000)).click();
    await waitForLoadingToClear(page, opts.timeoutMs);

    const download = await findClickable(page, 'Download', opts.timeoutMs);
    const summary = await page.getByText(/\d+\s*-\s*\d+\s+of\s+\d+/).first().textContent().catch(() => null);
    if (summary) log(`Results: ${summary.trim()}`);

    log('Clicking Download in the results toolbar');
    await download.click();
    await waitForLoadingToClear(page, opts.timeoutMs);

    log('Clicking Download Attachment');
    const attachment = await findClickable(page, 'Download Attachment', opts.timeoutMs);
    const pending = waitForAnyDownload(context, opts.timeoutMs);
    await attachment.click();
    const file = await pending;

    fs.mkdirSync(opts.outDir, { recursive: true });
    const target = path.join(opts.outDir, file.suggestedFilename());
    await file.saveAs(target);
    const failure = await file.failure();
    if (failure) throw new Error(`Download failed: ${failure}`);
    log(`Saved ${target} (${fs.statSync(target).size} bytes)`);
    return target;
  } finally {
    await browser.close();
  }
}

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  for (let attempt = 1; ; attempt++) {
    try {
      return await runOnce(opts);
    } catch (err) {
      log(`Attempt ${attempt} failed: ${err.message}`);
      if (attempt > opts.retries) throw err;
      await new Promise((r) => setTimeout(r, 30000 * attempt));
    }
  }
}

if (require.main === module) {
  main().catch(() => process.exit(1));
}

module.exports = { runOnce, parseArgs };
