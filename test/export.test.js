// Runs the exporter against a local page that mimics the Cal eProcure flow.
const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const http = require('http');
const { runOnce } = require('../export-suppliers');

test('searches, waits for both loading overlays, and saves the attachment', async () => {
  const html = fs.readFileSync(path.join(__dirname, 'mock-site.html'));
  const server = http.createServer((req, res) => {
    if (req.url === '/file') {
      res.writeHead(200, {
        'Content-Type': 'text/csv',
        'Content-Disposition': 'attachment; filename="SupplierSearchResults.csv"',
      });
      return res.end('Business Name,Certification\nS&F Cleaning Co. LLC,SB(Micro)\n');
    }
    res.writeHead(200, { 'Content-Type': 'text/html' });
    res.end(html);
  });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  const outDir = fs.mkdtempSync(path.join(os.tmpdir(), 'caleprocure-'));
  try {
    const saved = await runOnce({
      url: `http://127.0.0.1:${server.address().port}/?delay=2000`,
      outDir,
      timeoutMs: 30000,
      headed: false,
    });
    assert.strictEqual(path.basename(saved), 'SupplierSearchResults.csv');
    assert.match(fs.readFileSync(saved, 'utf8'), /S&F Cleaning Co\. LLC/);
  } finally {
    server.close();
    fs.rmSync(outDir, { recursive: true, force: true });
  }
});
