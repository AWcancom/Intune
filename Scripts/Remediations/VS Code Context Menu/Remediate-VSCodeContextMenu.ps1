<#
.SYNOPSIS
    Intune Remediation - Remediate: "Open with Code" context menu entries for VS Code.
.DESCRIPTION
    Creates or corrects the "Open with Code" context menu for files, folders and folder background,
    the same way the VS Code installer does:
    Windows 11 menu -> registers VS Code's sparse package (code_<arch>.appx, ExplorerCommandHandler DLL)
                       from the install folder and sets the VSCodeContextMenu title key.
    Classic menu    -> ...\shell\VSCode keys, when the package is not available or the classic menu is forced.
    User install    -> HKCU\Software\Classes (or HKU\<SID> when run as System), pointing to the user's Code.exe.
    Machine install -> HKLM\Software\Classes (System context). In user context, per-user entries pointing
                       to the machine Code.exe are written instead, because a user cannot write HKLM.
    Stale per-user entries that would override HKLM with a wrong path are corrected.
#>

#region Shared logic (identical in Detect and Remediate script)
$ErrorActionPreference = 'Stop'

# Same key names and text the VS Code installer uses ("&" underlines the i as access key),
# so we never create a second entry next to its own.
$KeyName      = 'VSCode'
$TitleKeyName = 'VSCodeContextMenu'   # title read by VS Code's Windows 11 menu handler
$MenuText     = 'Open w&ith Code'
$Entries      = @(
    [pscustomobject]@{ Name = 'Files';             Path = '*\shell';                    Arg = '%1' }
    [pscustomobject]@{ Name = 'Folders';           Path = 'Directory\shell';            Arg = '%V' }
    [pscustomobject]@{ Name = 'Folder background'; Path = 'Directory\Background\shell'; Arg = '%V' }
)
# Present when a user restored the full classic menu on Windows 11; VS Code then skips its Windows 11 handler.
$ClassicMenuKey = 'Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32'
$IsWin11 = [Environment]::OSVersion.Version.Build -ge 22000

function Open-BaseKey([string]$Hive) {
    [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]$Hive, [Microsoft.Win32.RegistryView]::Registry64)
}

function Test-RegKey([string]$Hive, [string]$SubKey) {
    $base = Open-BaseKey $Hive
    try {
        $k = $base.OpenSubKey($SubKey)
        if ($k) { $k.Close(); return $true }
        return $false
    } finally { $base.Close() }
}

function Get-MachineCodeExe {
    $roots = @($env:ProgramW6432, $env:ProgramFiles, ${env:ProgramFiles(x86)}) | Where-Object { $_ } | Select-Object -Unique
    foreach ($root in $roots) {
        $exe = Join-Path $root 'Microsoft VS Code\Code.exe'
        if (Test-Path -LiteralPath $exe) { return $exe }
    }
    return $null
}

function Get-UserLocalAppData([string]$Sid) {
    # Profile path from ProfileList, Local AppData from the user's shell folders (may be redirected).
    $profilePath = $null
    $hklm = Open-BaseKey 'LocalMachine'
    try {
        $k = $hklm.OpenSubKey("SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$Sid")
        if ($k) { $profilePath = $k.GetValue('ProfileImagePath'); $k.Close() }
    } finally { $hklm.Close() }
    if (-not $profilePath) { return $null }
    $profilePath = [Environment]::ExpandEnvironmentVariables($profilePath)

    $localAppData = $null
    $hku = Open-BaseKey 'Users'
    try {
        $k = $hku.OpenSubKey("$Sid\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders")
        if ($k) {
            $raw = $k.GetValue('Local AppData', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            $k.Close()
            if ($raw) { $localAppData = [regex]::Replace($raw, '(?i)%USERPROFILE%', { $profilePath }) }
        }
    } finally { $hku.Close() }
    if (-not $localAppData -or $localAppData -match '%') { $localAppData = Join-Path $profilePath 'AppData\Local' }
    return $localAppData
}

function Get-CodeInstall([string]$Exe) {
    # One VS Code install plus the sparse package (code_<arch>.appx with the ExplorerCommandHandler DLL)
    # it ships for the Windows 11 menu. Newer builds keep it in a versioned subfolder: <install>\<commit>\appx.
    $dir = Split-Path -Parent $Exe
    $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }
    $appxDirs = @(Join-Path $dir 'appx') + @(Get-ChildItem -LiteralPath $dir -Directory -ErrorAction SilentlyContinue | ForEach-Object { Join-Path $_.FullName 'appx' })
    $appx = $appxDirs | Where-Object { Test-Path -LiteralPath (Join-Path $_ "code_$arch.appx") } |
        ForEach-Object { Get-Item -LiteralPath (Join-Path $_ "code_$arch.appx") } |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    $identity = $null
    if ($appx) {
        try { $identity = Get-AppxIdentity $appx.FullName } catch { $identity = $null }
    }
    [pscustomobject]@{
        Exe      = $Exe
        AppxPath = if ($identity) { $appx.FullName } else { $null }
        AppxDir  = if ($identity) { $appx.DirectoryName } else { $null }
        Identity = $identity
    }
}

function Get-AppxIdentity([string]$Path) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $reader = New-Object IO.StreamReader($zip.GetEntry('AppxManifest.xml').Open())
        try { [xml]$xml = $reader.ReadToEnd() } finally { $reader.Close() }
    } finally { $zip.Dispose() }
    [pscustomobject]@{ Name = $xml.Package.Identity.Name; Version = [version]$xml.Package.Identity.Version }
}

#region Classic menu entries (HKLM / HKCU / HKU\<SID> \Software\Classes\...\shell\VSCode)
function Test-Entry($Scope, $Entry) {
    $base = Open-BaseKey $Scope.Hive
    try {
        $key = $base.OpenSubKey("$($Scope.Prefix)\$($Entry.Path)\$KeyName")
        if (-not $key) { return 'Missing' }
        try {
            $cmdKey = $key.OpenSubKey('command')
            if (-not $cmdKey) { return 'Wrong' }
            $cmd = [string]$cmdKey.GetValue('')
            $cmdKey.Close()
            $icon = (([string]$key.GetValue('Icon')) -replace ',\s*-?\d+$', '').Trim().Trim('"')
            if ($cmd.Trim() -ne "`"$($Scope.Exe)`" `"$($Entry.Arg)`"") { return 'Wrong' }
            if ($icon -ne $Scope.Exe) { return 'Wrong' }
            return 'OK'
        } finally { $key.Close() }
    } finally { $base.Close() }
}

function Set-Entry($Scope, $Entry) {
    $base = Open-BaseKey $Scope.Hive
    try {
        $key = $base.CreateSubKey("$($Scope.Prefix)\$($Entry.Path)\$KeyName")
        $key.SetValue('', $MenuText)
        $key.SetValue('Icon', $Scope.Exe)
        $cmdKey = $key.CreateSubKey('command')
        $cmdKey.SetValue('', "`"$($Scope.Exe)`" `"$($Entry.Arg)`"")
        $cmdKey.Close()
        $key.Close()
    } finally { $base.Close() }
}
#endregion

#region Windows 11 menu (sparse package with ExplorerCommandHandler + title key)
function Test-Title($Scope) {
    $base = Open-BaseKey $Scope.Hive
    try {
        $key = $base.OpenSubKey("$($Scope.Prefix)\$TitleKeyName")
        if (-not $key) { return 'Missing' }
        try { if ([string]$key.GetValue('Title')) { return 'OK' } else { return 'Missing' } } finally { $key.Close() }
    } finally { $base.Close() }
}

function Set-Title($Scope) {
    $base = Open-BaseKey $Scope.Hive
    try {
        $key = $base.CreateSubKey("$($Scope.Prefix)\$TitleKeyName")
        $key.SetValue('Title', $MenuText, [Microsoft.Win32.RegistryValueKind]::ExpandString)
        $key.Close()
    } finally { $base.Close() }
}

function Get-RegisteredAppx($Install, [bool]$Machine) {
    # Machine: provisioned for all users (System context). User: registered for the current user.
    if ($Machine) {
        @(Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -eq $Install.Identity.Name })
    } else {
        @(Get-AppxPackage -Name $Install.Identity.Name)
    }
}

function Test-Appx($Install, [bool]$Machine) {
    $pkgs = @(Get-RegisteredAppx $Install $Machine)
    if ($pkgs.Count -eq 0) { return 'Missing' }
    if (-not ($pkgs | Where-Object { [version]$_.Version -eq $Install.Identity.Version })) { return 'Wrong' }
    return 'OK'
}

function Set-Appx($Install, [bool]$Machine) {
    # Same commands the VS Code installer runs; an outdated registration is removed first.
    $old = @(Get-RegisteredAppx $Install $Machine | Where-Object { [version]$_.Version -ne $Install.Identity.Version })
    if ($Machine) {
        foreach ($p in $old) { Remove-AppxProvisionedPackage -Online -PackageName $p.PackageName | Out-Null }
        Add-AppxPackage -Stage $Install.AppxPath -ExternalLocation $Install.AppxDir
        Add-AppxProvisionedPackage -Online -SkipLicense -PackagePath $Install.AppxPath | Out-Null
    } else {
        foreach ($p in $old) { Remove-AppxPackage -Package $p.PackageFullName }
        Add-AppxPackage -Path $Install.AppxPath -ExternalLocation $Install.AppxDir
    }
}
#endregion

function New-Check($Kind, $Name, $Mode, $Scope, $Entry, $Install, [bool]$Machine) {
    [pscustomobject]@{ Kind = $Kind; Name = $Name; Mode = $Mode; Scope = $Scope; Entry = $Entry; Install = $Install; Machine = $Machine }
}

function New-ClassicChecks($Scope, $Mode) {
    foreach ($e in $Entries) { New-Check 'Classic' "$($Scope.Name) / $($e.Name)" $Mode $Scope $e $null $false }
}

function New-Win11Checks($Scope, $Install, [bool]$Machine) {
    New-Check 'Appx'  "$($Scope.Name) / Windows 11 menu handler" 'Required' $Scope $null $Install $Machine
    New-Check 'Title' "$($Scope.Name) / Windows 11 menu title"   'Required' $Scope $null $Install $Machine
}

function Test-Check($Check) {
    switch ($Check.Kind) {
        'Classic' { Test-Entry $Check.Scope $Check.Entry }
        'Title'   { Test-Title $Check.Scope }
        'Appx'    { Test-Appx $Check.Install $Check.Machine }
    }
}

function Repair-Check($Check) {
    switch ($Check.Kind) {
        'Classic' { Set-Entry $Check.Scope $Check.Entry }
        'Title'   { Set-Title $Check.Scope }
        'Appx'    { Set-Appx $Check.Install $Check.Machine }
    }
}

function Get-Checks {
    # Windows 11 with VS Code's sparse package available: the package (ExplorerCommandHandler) puts
    # "Open with Code" in the new menu, classic entries are only corrected if present (the installer removes them).
    # Otherwise (Windows 10, older VS Code, classic menu forced, or a user install seen from System context):
    # classic entries, shown under "Show more options" on Windows 11.
    # Mode Required: must exist. Mode IfPresent: only checked when it exists (a stale per-user entry overrides HKLM).
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $isSystem = $identity.IsSystem
    $isAdmin  = (New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $checks = @()

    $machine = $null; $machineNew = $false; $machineClassicOk = $false
    $machineExe = Get-MachineCodeExe
    if ($machineExe) {
        $machine = Get-CodeInstall $machineExe
        $machineNew = $IsWin11 -and [bool]$machine.AppxPath
        $machineScope = [pscustomobject]@{ Name = 'Machine (HKLM)'; Hive = 'LocalMachine'; Prefix = 'Software\Classes'; Exe = $machineExe }
        $machineClassicOk = -not ($Entries | Where-Object { (Test-Entry $machineScope $_) -ne 'OK' })
        # HKLM and provisioning are only managed when this run can write them (System context or elevated).
        if ($isAdmin) {
            if ($machineNew) {
                $checks += New-Win11Checks $machineScope $machine $true
                $checks += New-ClassicChecks $machineScope 'IfPresent'
            } else {
                $checks += New-ClassicChecks $machineScope 'Required'
            }
        }
    }

    $users = @()
    if ($isSystem) {
        $hku = Open-BaseKey 'Users'
        try { $sids = $hku.GetSubKeyNames() | Where-Object { $_ -match '^S-1-(5-21|12-1)-[\d-]+$' } } finally { $hku.Close() }
        foreach ($sid in $sids) {
            $lad = Get-UserLocalAppData $sid
            if ($lad) { $users += [pscustomobject]@{ Name = "User $sid"; Hive = 'Users'; Prefix = "$sid\Software\Classes"; LocalAppData = $lad } }
        }
    } else {
        $users += [pscustomobject]@{ Name = "User $($identity.Name)"; Hive = 'CurrentUser'; Prefix = 'Software\Classes'; LocalAppData = $env:LOCALAPPDATA }
    }

    foreach ($u in $users) {
        $classicForced = Test-RegKey $u.Hive "$($u.Prefix -replace 'Software\\Classes$', '')$ClassicMenuKey"
        $userExe = Join-Path $u.LocalAppData 'Programs\Microsoft VS Code\Code.exe'
        if (Test-Path -LiteralPath $userExe) {
            $install = Get-CodeInstall $userExe
            $scope = [pscustomobject]@{ Name = $u.Name; Hive = $u.Hive; Prefix = $u.Prefix; Exe = $userExe }
            # A package can only be registered for a user from that user's own context.
            if ($IsWin11 -and $install.AppxPath -and -not $classicForced -and -not $isSystem) {
                $checks += New-Win11Checks $scope $install $false
                $checks += New-ClassicChecks $scope 'IfPresent'
            } else {
                $checks += New-ClassicChecks $scope 'Required'
            }
        } elseif ($machine) {
            # Machine install only: HKLM covers the user. Per-user classic entries are needed when the
            # classic entries in HKLM are not correct and will not be fixed by this run, or are not used
            # (Windows 11 handler) while this user has the classic menu forced.
            $scope = [pscustomobject]@{ Name = $u.Name; Hive = $u.Hive; Prefix = $u.Prefix; Exe = $machineExe }
            $needed = -not $machineClassicOk -and (($machineNew -and $classicForced) -or (-not $machineNew -and -not $isAdmin))
            $checks += New-ClassicChecks $scope $(if ($needed) { 'Required' } else { 'IfPresent' })
        }
    }
    return $checks
}

function Get-Problems($Checks) {
    foreach ($c in $Checks) {
        $state = Test-Check $c
        if ($state -eq 'OK') { continue }
        if ($state -eq 'Missing' -and $c.Mode -eq 'IfPresent') { continue }
        [pscustomobject]@{ Check = $c; State = $state }
    }
}
#endregion

try {
    $checks = @(Get-Checks)
    if ($checks.Count -eq 0) {
        Write-Output 'VS Code not installed (or no signed-in user with a user install). Nothing to do.'
        exit 0
    }
    $fixed = @()
    foreach ($p in @(Get-Problems $checks)) {
        Repair-Check $p.Check
        $fixed += "$($p.Check.Name)"
    }
    $left = @(Get-Problems $checks)
    if ($left.Count -gt 0) {
        $summary = ($left | ForEach-Object { "$($_.Check.Name): $($_.State)" }) -join '; '
        Write-Output "Remediation incomplete: $summary"
        exit 1
    }
    Write-Output "Fixed $($fixed.Count) item(s): $($fixed -join '; ')"
    exit 0
} catch {
    Write-Output "Remediation error: $($_.Exception.Message)"
    exit 1
}
