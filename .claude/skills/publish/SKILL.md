---
name: publish
description: >-
  Publish a new release of Copilot Readiness. Checks the README, guide and pictures are up to date and accurate,
  builds the zip, runs the tests, commits, creates the GitHub release and removes older releases. Use this whenever
  the user asks to publish, release, ship or put out a new version, or asks to "do a release" or "cut 1.x", even if
  they don't say "publish".
---

# Publish a release

Steps 1 to 5 only change files on this computer. Steps 6 to 9 are public, because the repo is public and clients download from it. So stop at step 5 and get a yes before going further.

Write everything for the user in plain English, as described in the global instructions: say what a person using the program would see.

If a step fails, stop and say what failed. Don't work around it, and don't publish with anything unresolved. Don't run a code review as part of this unless asked.

## 1. Choose the version

Find the latest release with `gh release list`. Propose the next number: the last part goes up for fixes (1.3.0 to 1.3.1), the middle part for new features (1.2.1 to 1.3.0). The user can overrule it.

## 2. Check the documentation

Read what clients will notice has changed since the last release: `git log` and `git diff v<last-version>` (this includes uncommitted work). Then read `README.md` and every page in `docs/` against those changes, and fix what's wrong or missing:

- A new or changed feature, button, message or requirement is described, and what's described still matches the program.
- Mentions of version numbers are still right, such as "1.2.1 or earlier" for moving up.
- Links between pages, and to headings within them, still go somewhere.
- A new guide page is in the list of pages in `scripts/New-PnPPackage.ps1`, or it won't reach the zip.
- If the rule book changed, its `version` went up and `rules/rulebook.lock.json` matches.

Keep the guide's voice: short sentences, written for someone who isn't technical. Only change what needs changing.

## 3. Check the pictures

From the changes in step 2, work out which windows the guide shows have changed. If any have, retake the pictures:

```
pwsh -STA -File scripts/New-GuidePictures.ps1
```

It uses a made-up tenant and opens windows on screen while it runs. It rewrites every picture, and they nearly all differ slightly because of dates, so look at the ones that changed and keep only those that show something new. Put the others back with `git checkout -- docs/pictures/<name>`. If a new feature would be hard to follow without a picture, say so, but don't add one without asking.

## 4. Check nothing private is going public

Look through what's about to be committed for real tenant names, email addresses, app IDs, certificate thumbprints and client details. Pictures must only show the made-up tenant. `pnp/settings.json`, results, logs and certificates must not be staged. Only ever push to `origin`: the `archive` remote holds old private history that must never reach it.

## 5. Build and test, then ask

Hand this to a sub-agent on the Haiku model, as the project instructions say for tests. The build runs all the tests first and refuses to build if any fail, so there's no separate test run:

```
pwsh -NoProfile -File scripts/New-PnPPackage.ps1 -Version <version>
```

Have it report whether the tests passed, the exact text of any failure, and the zip's path. Then check the zip yourself. It should have `START HERE.html`, `Start.cmd`, `Start.ps1` and `rulebook.json`, and no `settings.json`, results, logs or certificate files. The guide inside it should include what you changed in step 2.

Write the release notes, following the last release (`gh release view`): one line on what the program is, **New in this version** in plain words, anything people must do when moving up, **To install**, and **You need**.

Then show the user the version, what changed in the docs and pictures, the test result, the notes, and which older releases will be removed. Ask whether to publish. Mention anything known to be unfinished or untested, including whether it has been tried on a real tenant. Wait for a yes.

## 6. Commit and push

Commit everything that belongs to this release, with a plain message saying what changed. Leave out any line crediting an AI assistant or its maker. Push to `origin`.

## 7. Create the release

```
gh release create v<version> dist/CopilotReadiness-PnP-<version>.zip --title "Copilot Readiness <version>" --notes-file <notes>
```

## 8. Check it, then remove the older releases

Confirm with `gh release view v<version>` that it's marked as the latest and has the zip attached. Only then delete each older release with `gh release delete v<old-version> --yes`, so people can always download something. The user always wants this, so don't ask again. Leave their version tags in place unless told otherwise.

## 9. Report

Give the user the release link and say what was removed. Say plainly if any step didn't go as planned.
