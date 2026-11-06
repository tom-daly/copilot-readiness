# Copilot Readiness

The PnP PowerShell scan clients run themselves (`pnp/`).

## The rule book is the one place rules are defined

`rules/rulebook.json` holds every rule: its id, name, advice, check, the site kinds it applies to (SharePoint, OneDrive), its severity, when it is raised, the thresholds, the score and how finding ids are made.

Whenever a change affects what is found, how serious it is, its wording or the score:

1. Change `rules/rulebook.json` first, and raise its `version`. A stopped scan can only be continued under the version it started with, so its report never mixes two sets of rules. The tests fail until you've also updated `rules/rulebook.lock.json`, and they tell you what to put there.
2. Make the scan match it: `pnp/CopilotReadiness/Rules.ps1`.
3. Add or update the test cases in `rules/cases.json`.
4. Run `pwsh -File pnp/tests/Invoke-AllTests.ps1`. It needs PowerShell 7.5 or later.
5. Rebuild the client zip with `scripts/New-PnPPackage.ps1`, which copies the rule book into the package.

Changes that don't touch findings or the score (how the scan walks a tenant, the windows, the report layout, throttling) don't belong in the rule book.

## Running the tests

Don't run the tests yourself. Hand them to a sub-agent on the Haiku model, and have it run them and report the results back: which passed, and the exact failure text for any that failed. This covers `pnp/tests/Invoke-AllTests.ps1` and any single test file. It only runs tests and reports; it doesn't change any code.

## The guide

`README.md` is the overview on the repo's main page. `docs/` holds the guide clients follow, one page per section, with pictures in `docs/pictures`. `scripts/New-PnPPackage.ps1` joins the pages into `START HERE.html` in the zip; its list of pages sets their order, so add any new page there. When a window it shows changes, retake the pictures with `pwsh -STA -File scripts/New-GuidePictures.ps1`, which uses a made-up tenant. Never put a picture from a real tenant in the guide.

## Releases

Use the `publish` skill (`/publish`). It checks the README, guide and pictures, builds the zip with `-Version`, runs the tests, asks before anything public, attaches the zip to a GitHub release tagged `v<version>`, then removes the older releases.
