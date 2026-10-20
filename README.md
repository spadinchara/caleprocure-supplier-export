# Cal eProcure supplier export

Downloads the full list of certified suppliers (MB, SB, SB-PW, DVBE, NVSA, NP) from the
public [Cal eProcure supplier search](https://caleprocure.ca.gov/pages/PublicSearch/supplier-search.aspx?psNewWin=true).

## What it does

It follows the same steps as a person in the browser, using headless Chromium (Playwright):

1. Opens the supplier search page.
2. Clicks **Search** with every criterion left blank, so all suppliers are returned (about 22,000).
3. Waits for the **Loading...** overlay to clear and the results toolbar to appear.
4. Clicks **Download** in the results toolbar and waits for the overlay again while the file is built.
5. Clicks **Download Attachment** in the "Your file is ready." modal.
6. Saves the file under the server's default name (what the browser's Save As dialog would offer).

Each wait looks for the overlay to clear or the next button to appear, not a fixed delay. If any
step fails, the whole run is retried from a fresh browser.

## Setup

```bash
cd caleprocure-supplier-export
npm install
npx playwright install chromium   # skip if Chromium is already provided
```

## Run

```bash
npm run export                                    # saves to ./downloads
node export-suppliers.js --out /data/caleprocure  # choose the folder
node export-suppliers.js --headed                 # watch the browser while it runs
```

| Option | Env var | Default | Meaning |
|---|---|---|---|
| `--out DIR` | `CALEPROCURE_OUT_DIR` | `./downloads` | Folder for the saved file |
| `--timeout SECONDS` | `CALEPROCURE_TIMEOUT_MS` (ms) | 600 s | Longest wait for each loading step |
| `--retries N` | `CALEPROCURE_RETRIES` | 2 | Extra attempts after a failure |
| `--headed` | | off | Show the browser window |
| `--url URL` | `CALEPROCURE_URL` | Cal eProcure search page | Starting page |

It prints the saved path when it succeeds and exits with code 1 if every attempt fails, so it
can be run from cron, Windows Task Scheduler, or a CI job.

## Test

```bash
npm test
```

The test runs the whole flow against `test/mock-site.html`, a local page that mimics the search,
both loading overlays, the modal and the file download. It checks the script's clicking, waiting
and saving logic. It does not check the live site.
