# Setting it up

Connect Copilot Readiness to your Microsoft 365. You only do this once on each PC.

Allow about 30 minutes, most of it waiting for Microsoft. You need someone who can sign in as a **Global Administrator** of your Microsoft 365. After this, anyone with this folder on this PC can run a scan.

## Double-click Start.cmd

Open the folder you extracted, then the **CopilotReadiness-PnP** folder inside it, and double-click **Start.cmd**. Your PC may show it as just **Start**, with a gear icon.

![The folder, with Start.cmd marked in red](pictures/01-start-cmd.png)

A black window opens first. Leave it open; you can minimize it. It goes away when you're finished. If it says it needs PowerShell, go back to [Install PowerShell 7](install.md#install-powershell-7), or restart your PC if you've already done it.

If Windows shows a blue **Windows protected your PC** box, press **More info**, then **Run anyway**. Only do this if the zip came from someone you trust.

## Press Fix if you see it

A **Getting ready** window checks your PC. A green check mark means that item is fine. If **Fix** appears, press it. It installs PnP.PowerShell, the one other thing the scan needs, which takes a minute or two.

![The Getting ready window, with the Fix button marked in red](pictures/02-check-fix.png)

## Type your tenant name and press Continue

Your tenant name is the first part of your SharePoint address. If your sites are at `contoso.sharepoint.com`, type `contoso`. Then press **Continue**.

![The tenant name and the Continue button marked in red](pictures/03-check-tenant.png)

## Sign in and accept

Your web browser opens and shows Microsoft's own pages:

1. Sign in as a **Global Administrator**.
2. Microsoft lists the permissions the scan's app needs. Press **Accept**.

This creates an app called **Copilot Readiness Scanner (PnP)** in your tenant, with a certificate kept in your Windows certificate store. The app can read every site and who it is shared with. It never changes anything. The permissions are listed at the top of `Start.ps1`, and the details are saved in `settings.json`.

## Wait while Microsoft switches it on

Go back to the Copilot Readiness window. Microsoft usually takes a few minutes to switch the permissions on, and sometimes up to 20. It keeps trying by itself, so there's nothing to press. It's fine if you see the same message a few times.

![The window that shows it's waiting for Microsoft](pictures/04-getting-ready.png)

When it's ready, the main window opens by itself.

## Another tenant

The top right of the main window shows which tenant you're signed in to. **Sign out** asks which tenant to scan next. The first time, that tenant is set up like the first one, with its own app, and you sign in as one of its Global Administrators. Every tenant set up on this PC is remembered, so switching back needs no new setup, and you can pick it from the list. Each scan, and the offer to continue one, belongs to its own tenant.

From PowerShell, `./Start.ps1 -Tenant fabrikam` switches straight to that tenant.

## Another PC

The certificate stays on the PC where setup ran. To scan from a different PC, either export the certificate (with its private key) and import it there along with this folder, or run `./Start.ps1 -Setup` on the new PC to create a second app.

**Next:** [Running the scripts](running-the-scripts.md)
