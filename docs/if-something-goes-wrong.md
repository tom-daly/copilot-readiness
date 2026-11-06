# If something goes wrong

| What you see | What to do |
|---|---|
| The black window says **needs PowerShell 7.5 or later** | [Install PowerShell 7](install.md#install-powershell-7), then double-click **Start.cmd** again. If you've already installed it, restart your PC. |
| **Windows protected your PC** | Press **More info**, then **Run anyway**, if the zip came from someone you trust. |
| A red X, or **Fix** doesn't work | Read the words next to the X. They say what's wrong. Fix it, then press **Check again**. |
| **There is no tenant called...** | Check the spelling. It's the part before `.sharepoint.com` in your SharePoint address. |
| The sign-in page doesn't appear, or opens in the wrong browser profile | Check your other browser windows. If it's in the wrong one, click into the profile you want so it's the last one used, close the Copilot Readiness windows, and double-click **Start.cmd** again. |
| The browser never opens, or you close it by accident | Close the windows and double-click **Start.cmd** again. |
| After 20 minutes, **Microsoft still won't let it read your sites** | The permissions may not have been accepted. In the Entra admin center, open **App registrations**, then **Copilot Readiness Scanner (PnP)**, then **API permissions**. Each one should say **Granted**. Then start again. |
| **This tenant has 2 apps called...** | In the Entra admin center, under **App registrations**, delete the ones nobody uses so that one is left. Then start again. |
| The scan stopped, or the PC restarted | Double-click **Start.cmd** and press **Continue that scan**. Nothing already finished is lost. |
| A newer version asks you to set up or sign in as an administrator again | This happens once when moving up from version 1.2.1 or earlier, or if this computer's certificate or remembered setup has gone. See [Getting a newer version](install.md#getting-a-newer-version). If the certificate is still on this computer and on the app, it's used again and no new one is added. |
| A newer version shows no past scans | Your results are in the older version's `results` folder. If that folder still exists, copy its `results` folder into the new version's folder, and set **scan.resultsFolder** in `settings.json` back to `results`. |
| **Can't save results in...** | The results folder can't be reached. If it's on a network or USB drive, connect the drive and try again. Otherwise change **scan.resultsFolder** in `settings.json`. |
| **Your past scans can't be found** | They're in a folder the new version can't see. If it's on a network or USB drive, connect the drive and press **Look again**. If you deleted the folder, press **Start a new results folder**. |
| A stopped scan says **Stopped, older rules** | It started under an older version whose rules have since changed, so it can't be continued. Start a new scan. |
| A stopped scan says **Stopped, newer rules** | It started in a newer version than the one you've opened. Continue it in that version, or start a new scan. |
| A window has a red heading saying something went wrong | Read the message at the bottom. It stays open until you close it. The same lines are kept in the `logs` folder, which is useful if you ask for help. What the background scan printed is in `scan.log` and `scan-errors.log` in the scan's folder. |

For help, open the **Settings** tab in the main window, which shows who to contact.
