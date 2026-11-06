# More detail

## settings.json

The first run writes this file. You can change it with any text editor:

```json
{
  "tenant": "contoso.onmicrosoft.com",
  "sharePointUrl": "https://contoso.sharepoint.com",
  "app": {
    "name": "Copilot Readiness Scanner (PnP)",
    "clientId": "11111111-2222-3333-4444-555555555555",
    "thumbprint": "A1B2C3D4E5F6..."
  },
  "otherTenants": [],
  "scan": {
    "level": "Quick",
    "include": "SharePoint",
    "sites": [],
    "staleDays": 180,
    "resultsFolder": "results",
    "pace": "Normal"
  }
}
```

- **app**: if your IT team already made an app with the right permissions, put its client id and its certificate's thumbprint here before the first run, and no new app is created.
- **otherTenants**: the other tenants set up on this PC, each with its own app. "Sign out" and choosing a new tenant fills this in.
- **scan.level**: the level the window starts on, and the one used without the window.
- **scan.include**: what the window starts on, and what's scanned without the window: `SharePoint`, `OneDrive` or `Both`.
- **scan.sites**: site addresses to start with checked. Leave it empty for every site.
- **scan.staleDays**: how long without changes before a site counts as inactive.
- **scan.resultsFolder**: where results go.
- **scan.pace**: the pace the window starts on, and the one used without the window: `Gentle`, `Normal` or `Fast`. Each scan keeps the pace it started with, including when you continue it. A site is only given up on after 20 minutes of being told to wait, and Continue tries it again.

## What it doesn't cover yet

- SharePoint's own system lists (such as Site Pages and Style Library) aren't scanned.
- Owner checks count owners. Apart from Microsoft 365 group owners, they don't check whether an owner's account is still active.
- If a library has no sensitivity label column, its file labels aren't judged.
- At most 500 findings are kept per library or list; past that, the totals still count everything.

## Removing it

The **Settings** tab has a button for this: **Remove Copilot Readiness from this tenant**. A Global Administrator signs in, and it deletes the app from the tenant and this PC's certificate for it. Everyone using it, on any PC, loses access straight away, and it has to be set up again to be used again. Entra keeps a deleted app for 30 days, so an admin can bring it back from App registrations > Deleted applications in that time. Past scans on the PC are kept.

Do this in each tenant you set up (sign out to switch tenants). Then, on each other PC that used it, delete its certificate: run `certmgr.msc`, open Personal > Certificates, and remove the ones issued to **Copilot Readiness Scanner (PnP)**. Finally, delete this folder.

To do it by hand instead:

1. Delete the **Copilot Readiness Scanner (PnP)** app in the Entra admin center under App registrations, in each tenant you set up.
2. On each PC you used, delete its certificate as above.
3. Delete this folder.
