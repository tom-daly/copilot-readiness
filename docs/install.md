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

**Next:** [Setting it up](setting-it-up.md)
