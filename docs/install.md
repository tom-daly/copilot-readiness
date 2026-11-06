# Install

Put Copilot Readiness on your PC. This takes about five minutes.

**You need:**

- A Windows 10 or 11 PC.
- The **CopilotReadiness-PnP** zip file. [Download the latest one](https://github.com/tom-daly/copilot-readiness/releases/latest).

## Install PowerShell 7

This is a free program from Microsoft. It isn't the same as the "Windows PowerShell" already on your PC.

1. Click the **Start** button, type `cmd` and press **Enter**.
2. In the black window, paste this line and press **Enter**:

   ```
   winget install Microsoft.PowerShell
   ```

3. When it says it's finished, close that window.

If that doesn't work, download the installer from <https://aka.ms/powershell>. You need version 7.5 or later.

## Unzip the folder

1. Right-click the zip file and choose **Properties**. If you see an **Unblock** box at the bottom, tick it and press **OK**. This stops Windows warning you about each file.
2. Right-click the zip file again, choose **Extract All**, and extract it somewhere easy to find, such as `C:\CopilotReadiness`.

Keep this folder. Your settings and scan results are saved in it.

## Getting a newer version

You don't have to set anything up again, sign in as an administrator or make a new certificate. The one exception is moving up from version 1.2.1 or earlier, below.

1. Unzip the new version to a new folder, as above. Leave the old folder where it is.
2. Double-click **Start.cmd** in the new folder.

It finds the setup you already have on this computer and uses the same app and certificate. It says so when it starts, and tells you where your results are. It keeps using your earlier results in the old folder, so **don't delete the old folder**. If the new version can't find them, it asks: connect the drive and look again, if they're on a network or USB drive, or start a new `results` folder of its own, with no past scans, if you deleted them.

Let any scan or preview that's running finish first, or stop it, before you start the new version. If the new version has changed the rules, a stopped scan can't be continued, because its report would mix old and new rules. It stays under **Past scans** as **Stopped, older rules**. Start a new scan instead. Opened in an older copy, a scan from a newer version shows as **Stopped, newer rules**: continue it in the newer version.

**Moving up from version 1.2.1 or earlier?** Those versions don't remember their setup. Once, before you start the new version, copy `settings.json` and the `results` folder from the old folder into the new one. After that, you can delete the old folder if you want to, and every later version works as described above, using the results in this folder.

If you don't copy them, a Global Administrator has to sign in twice in a row. That's normal: the first sign-in finds the app is already there, and the second checks this computer's certificate. It then uses the certificate this computer already has. Your past scans stay in the old folder and won't show in the new one.

**Next:** [Setting it up](setting-it-up.md)
