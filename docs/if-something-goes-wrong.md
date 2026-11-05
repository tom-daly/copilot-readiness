# If something goes wrong

| What you see | What to do |
|---|---|
| The black window says **needs PowerShell 7.5 or later** | [Install PowerShell 7](install.md#install-powershell-7), then double-click **Start.cmd** again. If you've already installed it, restart your PC. |
| **Windows protected your PC** | Press **More info**, then **Run anyway**, if the zip came from someone you trust. |
| A red X, or **Fix** doesn't work | Read the words next to the X. They say what's wrong. Fix it, then press **Check again**. |
| **There is no tenant called...** | Check the spelling. It's the part before `.sharepoint.com` in your SharePoint address. |
| The browser never opens, or you close it by accident | Close the windows and double-click **Start.cmd** again. |
| After 20 minutes, **Microsoft still won't let it read your sites** | The permissions may not have been accepted. In the Entra admin center, open **App registrations**, then **Copilot Readiness Scanner (PnP)**, then **API permissions**. Each one should say **Granted**. Then start again. |
| The scan stopped, or the PC restarted | Double-click **Start.cmd** and press **Continue that scan**. Nothing already finished is lost. |
| A window has a red heading saying something went wrong | Read the message at the bottom. It stays open until you close it. The same lines are kept in the `logs` folder, which is useful if you ask for help. What the background scan printed is in `scan.log` and `scan-errors.log` in the scan's folder. |

For help, open the **Settings** tab in the main window, which shows who to contact.
