# VS Code "Open with Code" context menu (Intune Remediation)

Adds or repairs **Open with Code** for files, folders and folder background, the same way the
VS Code installer does.

| File | Purpose |
|---|---|
| `Detect-VSCodeContextMenu.ps1` | Exit 1 when VS Code is installed but the menu is missing or points to a wrong path/version, else exit 0 |
| `Remediate-VSCodeContextMenu.ps1` | Fixes it, then re-checks (exit 0 = fixed) |

## Two kinds of menu entry

- **Windows 11 menu** (top level, no "Show more options"): current VS Code ships a sparse package
  (`<install>\<commit>\appx\code_x64.appx` + `code_explorer_command_x64.dll`, an ExplorerCommandHandler).
  The scripts register that package and set the `Software\Classes\VSCodeContextMenu` title key.
  Windows 11 only shows ExplorerCommandHandlers from packaged apps, which is why the package is needed.
- **Classic menu** (`...\shell\VSCode` keys, under "Show more options" on Windows 11): used on Windows 10,
  for VS Code builds without the package, for users who restored the full classic menu, and for user
  installs when running as System (a package can't be registered for another user).
  Where the Windows 11 handler is used, existing classic keys are only corrected, not added
  (the installer removes them too).

## Which run context to choose in Intune

**Machine installs: System** (`Run this script using the logged-on credentials` = **No**), 64-bit PowerShell = **Yes**.
- Provisions the package for all users (`Add-AppxProvisionedPackage`); existing users get it at next sign-in.
- Also adds classic entries to every **signed-in** user's hive for user installs (including Entra ID accounts).

**User installs with the Windows 11 menu: logged-on user** (= **Yes**).
- Registers the package for that user (`Add-AppxPackage -ExternalLocation`) and writes HKCU.

Both contexts can be used together as two remediation assignments with the same scripts.
Enforce signature check: **No** (scripts are unsigned). Only VS Code stable is handled, not Insiders.

## Status
Parse-checked, and package discovery tested against a mock folder. Not yet run on Windows or in Intune.
