# Copilot Readiness

The PnP PowerShell scan clients run themselves (`pnp/`).

## The rule book is the one place rules are defined

`rules/rulebook.json` holds every rule: its id, name, advice, check, the site kinds it applies to (SharePoint, OneDrive), its severity, when it is raised, the thresholds, the score and how finding ids are made.

Whenever a change affects what is found, how serious it is, its wording or the score:

1. Change `rules/rulebook.json` first.
2. Make the scan match it: `pnp/CopilotReadiness/Rules.ps1`.
3. Add or update the test cases in `rules/cases.json`.
4. Run `pwsh -File pnp/tests/Invoke-AllTests.ps1`. It needs PowerShell 7.5 or later.
5. Rebuild the client zip with `scripts/New-PnPPackage.ps1`, which copies the rule book into the package.

Changes that don't touch findings or the score (how the scan walks a tenant, the windows, the report layout, throttling) don't belong in the rule book.

## The guide

`README.md` is the overview on the repo's main page. `docs/` holds the guide clients follow, one page per section, with pictures in `docs/pictures`. `scripts/New-PnPPackage.ps1` joins the pages into `START HERE.html` in the zip; its list of pages sets their order, so add any new page there. When a window it shows changes, retake the pictures with `pwsh -STA -File scripts/New-GuidePictures.ps1`, which uses a made-up tenant. Never put a picture from a real tenant in the guide.

## Releases

Build the zip with `-Version`, then attach it to a GitHub release tagged `v<version>`.
