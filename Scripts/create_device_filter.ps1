<#
.SYNOPSIS

Creates and maintains Microsoft Intune Assignment Filters based on
hardware models discovered in the tenant.

.DESCRIPTION

This script reads all Intune managed devices via Microsoft Graph,
identifies Windows hardware models, and optionally creates Intune
Assignment Filters for each detected model.

The script uses Microsoft Graph REST APIs (Invoke-MgGraphRequest)
instead of Get-MgDeviceManagementManagedDevice to avoid Graph SDK
module/version issues commonly encountered in admin workstations.

The script supports two operating modes:

OPTION 1
---------
Inventory Mode

Displays all discovered Windows hardware models and their device counts.

This mode:

- Does NOT create or modify anything
- Does NOT exclude any device models
- Exports a complete hardware inventory report

Output:
- IntuneModels.csv

Use this mode to:
- Review hardware inventory
- Estimate assignment filter requirements
- Identify unsupported hardware
- Verify expected model names

OPTION 2
---------
Create / Update Filters

Creates missing Intune Assignment Filters for physical Windows devices.

This mode:

- Reads existing assignment filters
- Excludes known VM / lab platforms
- Compares existing filters
- Creates only missing filters
- Never duplicates existing filters

Before creating filters the script displays:

- Existing filters
- Filters that would be created
- Excluded models
- Device counts
- Targeted device counts

A double confirmation step prevents accidental creation.

OUTPUT FILES

IntuneModels.csv
----------------
Complete inventory of all Windows device models.

Example:

DeviceCount,Model
125,HP EliteBook 840 G11
88,HP EliteBook 860 G11
44,Latitude 7450

IntuneFilterPreview.csv
-----------------------
Preview of all Intune Assignment Filters.

Example:

DeviceCount,Model,FilterName,Exists
125,HP EliteBook 840 G11,MODEL_HP_EliteBook_840_G11,True
88,HP EliteBook 860 G11,MODEL_HP_EliteBook_860_G11,False

ExcludedModels.csv
------------------
Models intentionally excluded from filter creation.

Example:

DeviceCount,Model
120,VMware7,1
43,Virtual Machine

FILTER NAMING

Generated filter names follow:

MODEL_<ModelName>

Examples:

MODEL_HP_EliteBook_840_G11
MODEL_HP_EliteBook_860_G11
MODEL_Latitude_7450

FILTER RULES

Generated rule example:

(device.model -eq "HP EliteBook 840 G11")

This allows targeting policies, applications,
and driver deployments to specific hardware models.

EXCLUDED MODELS

By default the script excludes:

- Virtual Machine
- VMware7,1
- VMware20,1
- VMware Virtual Platform
- VirtualBox
- KVM
- Bochs
- QEMU
- Default string
- System Product Name
- To be filled by O.E.M.

This prevents assignment filters from being created for
test, lab, VM, and improperly inventoried devices.

REQUIRED GRAPH PERMISSIONS

DeviceManagementManagedDevices.Read.All

Required for:
- Reading managed devices
- Reading hardware model information

DeviceManagementConfiguration.ReadWrite.All

Required for:
- Reading assignment filters
- Creating assignment filters

REQUIRED MODULE

Microsoft.Graph

Example:

Install-Module Microsoft.Graph -Scope CurrentUser

CONNECT TO GRAPH

Connect-MgGraph -Scopes `
    "DeviceManagementManagedDevices.Read.All", `
    "DeviceManagementConfiguration.ReadWrite.All"

EXAMPLE USAGE

Inventory Mode
--------------

.\Intune-ModelFilters.ps1

Select:

1

Result:

- Display all device models
- Export IntuneModels.csv

Create Filters
--------------

.\Intune-ModelFilters.ps1

Select:

2

Review:

- Excluded models
- Existing filters
- Filters to create

Confirm:

Y

Then:

CREATE

Result:

- Missing assignment filters created
- CSV exports generated

USE CASES

Recommended for:

- Intune Driver Management
- Driver Automation Tool environments
- Win32 App targeting
- BIOS update targeting
- Vendor-specific configurations
- Hardware-specific compliance policies

EXAMPLE ASSIGNMENT

Group:
All Devices

Filter:
MODEL_HP_EliteBook_840_G11

Mode:
Include

Result:
Only HP EliteBook 840 G11 devices receive the assignment.

NOTES

- Existing filters are not modified
- Existing filters are not deleted
- Only missing filters are created
- Device inventory is obtained directly from Intune
- Safe to run repeatedly
- Re-running the script is idempotent

AUTHOR

Andreas Wiesinger / CANCOM

VERSION

1.0
#>

Connect-MgGraph -Scopes `
    "DeviceManagementManagedDevices.Read.All", `
    "DeviceManagementConfiguration.ReadWrite.All"

# ------------------------------------------------------------
# Menu
# ------------------------------------------------------------

Write-Host ""
Write-Host "===================================================" -ForegroundColor Cyan
Write-Host "Intune Assignment Filter Tool"
Write-Host "===================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "1 - Show all Windows Models and Device Counts"
Write-Host "2 - Create / Update Assignment Filters"
Write-Host ""

$Mode = Read-Host "Select option"

if ($Mode -notin @("1","2")) {
    Write-Host "Invalid selection." -ForegroundColor Red
    return
}

# ------------------------------------------------------------
# Models to Ignore when creating filters
# ------------------------------------------------------------

$ExcludeModels = @(
    "Virtual Machine"
    "VMware Virtual Platform"
    "VMware7,1"
    "VMware20,1"
    "VirtualBox"
    "KVM"
    "Bochs"
    "QEMU"
    "Default string"
    "System Product Name"
    "To be filled by O.E.M."
)

# ------------------------------------------------------------
# Graph Paging
# ------------------------------------------------------------

function Invoke-GraphPagedRequest {

    param (
        [string]$Uri
    )

    $Results = @()

    do {

        Write-Host "Reading Graph page..." -ForegroundColor DarkGray

        $Response = Invoke-MgGraphRequest `
            -Method GET `
            -Uri $Uri

        if ($Response.value) {
            $Results += $Response.value
        }

        $Uri = $Response.'@odata.nextLink'

    } while ($Uri)

    return $Results
}

# ------------------------------------------------------------
# Read Devices
# ------------------------------------------------------------

Write-Host ""
Write-Host "Reading Intune devices..." -ForegroundColor Cyan

$Devices = Invoke-GraphPagedRequest `
    -Uri "https://graph.microsoft.com/beta/deviceManagement/managedDevices?`$select=deviceName,manufacturer,model,operatingSystem&`$top=999"

# ------------------------------------------------------------
# Convert Graph Objects
# ------------------------------------------------------------

$Devices = $Devices | ForEach-Object {

    [PSCustomObject]@{
        DeviceName      = $_.deviceName
        Manufacturer    = $_.manufacturer
        Model           = $_.model
        OperatingSystem = $_.operatingSystem
    }
}

Write-Host ""
Write-Host "Total Devices Found: $($Devices.Count)" -ForegroundColor Green

# ------------------------------------------------------------
# Build Full Model Inventory
# ------------------------------------------------------------

$AllModelStats = $Devices |
    Where-Object {
        $_.OperatingSystem -match "Windows" -and
        $_.Model
    } |
    Group-Object Model |
    Sort-Object Count -Descending

$ModelInventory = $AllModelStats |
    Select-Object `
        @{Name='DeviceCount';Expression={$_.Count}},
        @{Name='Model';Expression={$_.Name}}

# ------------------------------------------------------------
# Export Complete Inventory
# ------------------------------------------------------------

$ModelInventory |
    Export-Csv ".\IntuneModels.csv" -NoTypeInformation

# ------------------------------------------------------------
# Option 1 - Inventory Only
# ------------------------------------------------------------

if ($Mode -eq "1") {

    Write-Host ""
    Write-Host "===================================================" -ForegroundColor Green
    Write-Host "WINDOWS MODEL INVENTORY"
    Write-Host "===================================================" -ForegroundColor Green

    $ModelInventory |
        Sort-Object DeviceCount -Descending |
        Format-Table -AutoSize

    Write-Host ""
    Write-Host "Total Windows Models : $($ModelInventory.Count)"
    Write-Host "Total Devices        : $($Devices.Count)"

    Write-Host ""
    Write-Host "CSV Exported:"
    Write-Host ".\IntuneModels.csv" -ForegroundColor Green

    return
}

# ------------------------------------------------------------
# Option 2 - Exclude VM/Junk Models
# ------------------------------------------------------------

$IgnoredModels = $AllModelStats |
    Where-Object {
        $_.Name -in $ExcludeModels
    }

$ModelStats = $AllModelStats |
    Where-Object {
        $_.Name -notin $ExcludeModels
    }

# ------------------------------------------------------------
# Excluded Models Report
# ------------------------------------------------------------

$IgnoredModels |
    Select-Object `
        @{Name='DeviceCount';Expression={$_.Count}},
        @{Name='Model';Expression={$_.Name}} |
    Export-Csv ".\ExcludedModels.csv" -NoTypeInformation

Write-Host ""
Write-Host "===================================================" -ForegroundColor Yellow
Write-Host "EXCLUDED MODELS"
Write-Host "===================================================" -ForegroundColor Yellow

if ($IgnoredModels) {

    $IgnoredModels |
        Select-Object `
            @{Name='DeviceCount';Expression={$_.Count}},
            @{Name='Model';Expression={$_.Name}} |
        Sort-Object DeviceCount -Descending |
        Format-Table -AutoSize
}
else {

    Write-Host "No excluded models found."
}

# ------------------------------------------------------------
# Read Existing Assignment Filters
# ------------------------------------------------------------

Write-Host ""
Write-Host "Reading Assignment Filters..." -ForegroundColor Cyan

$ExistingFilters = Invoke-GraphPagedRequest `
    -Uri "https://graph.microsoft.com/beta/deviceManagement/assignmentFilters"

$ExistingNames = $ExistingFilters.displayName

# ------------------------------------------------------------
# Build Filter Preview
# ------------------------------------------------------------

$Preview = foreach ($ModelGroup in $ModelStats) {

    $Model = $ModelGroup.Name
    $DeviceCount = $ModelGroup.Count

    $FilterName = "MODEL_" + (
        $Model -replace '[^A-Za-z0-9]', '_'
    )

    [PSCustomObject]@{
        DeviceCount = $DeviceCount
        Model       = $Model
        FilterName  = $FilterName
        Exists      = ($ExistingNames -contains $FilterName)
    }
}

# ------------------------------------------------------------
# Export Preview
# ------------------------------------------------------------

$Preview |
    Sort-Object DeviceCount -Descending |
    Export-Csv ".\IntuneFilterPreview.csv" -NoTypeInformation

# ------------------------------------------------------------
# Show Preview
# ------------------------------------------------------------

Write-Host ""
Write-Host "===================================================" -ForegroundColor Cyan
Write-Host "FILTER PREVIEW"
Write-Host "===================================================" -ForegroundColor Cyan

$Preview |
    Sort-Object DeviceCount -Descending |
    Format-Table `
        DeviceCount,
        Model,
        FilterName,
        Exists -AutoSize

$Missing = $Preview |
    Where-Object {
        -not $_.Exists
    }

$TargetedDevices = (
    $Missing |
    Measure-Object DeviceCount -Sum
).Sum

# ------------------------------------------------------------
# Summary
# ------------------------------------------------------------

Write-Host ""
Write-Host "Models Found           : $($Preview.Count)"
Write-Host "Excluded Models        : $($IgnoredModels.Count)"
Write-Host "Existing Filters       : $(($Preview | Where-Object Exists).Count)"
Write-Host "Filters To Create      : $($Missing.Count)"
Write-Host "Targeted Devices       : $TargetedDevices"

if ($Missing.Count -eq 0) {

    Write-Host ""
    Write-Host "No new filters need to be created." -ForegroundColor Green
    return
}

Write-Host ""
Write-Host "Filters that will be created:" -ForegroundColor Yellow

$Missing |
    Sort-Object DeviceCount -Descending |
    Select-Object DeviceCount,Model,FilterName |
    Format-Table -AutoSize

# ------------------------------------------------------------
# Confirmation
# ------------------------------------------------------------

$Continue = Read-Host "Continue (Y/N)"

if ($Continue -notmatch '^(Y|YES)$') {
    Write-Host "Operation cancelled."
    return
}

$Final = Read-Host "Type CREATE to continue"

if ($Final -ne "CREATE") {
    Write-Host "Operation cancelled."
    return
}

# ------------------------------------------------------------
# Create Filters
# ------------------------------------------------------------

$CreatedCount = 0

foreach ($Filter in $Missing) {

    $Rule = "(device.model -eq `"$($Filter.Model)`")"

    $Body = @{
        displayName = $Filter.FilterName
        description = "Auto-created from Intune device model"
        platform    = "windows10AndLater"
        rule        = $Rule
    } | ConvertTo-Json

    try {

        Invoke-MgGraphRequest `
            -Method POST `
            -Uri "https://graph.microsoft.com/beta/deviceManagement/assignmentFilters" `
            -Body $Body `
            -ContentType "application/json" | Out-Null

        $CreatedCount++

        Write-Host "Created: $($Filter.FilterName)" -ForegroundColor Green
    }
    catch {

        Write-Host "FAILED: $($Filter.FilterName)" -ForegroundColor Red
        Write-Host $_.Exception.Message
    }
}

# ------------------------------------------------------------
# Final Overview
# ------------------------------------------------------------

Write-Host ""
Write-Host "===================================================" -ForegroundColor Green
Write-Host "FINAL MODEL OVERVIEW"
Write-Host "===================================================" -ForegroundColor Green

$ModelInventory |
    Sort-Object DeviceCount -Descending |
    Format-Table -AutoSize

Write-Host ""
Write-Host "Total Devices      : $($Devices.Count)"
Write-Host "Total Models       : $($ModelInventory.Count)"
Write-Host "Excluded Models    : $($IgnoredModels.Count)"
Write-Host "Filters Created    : $CreatedCount"
Write-Host "Targeted Devices   : $TargetedDevices"

Write-Host ""
Write-Host "CSV Files Created:"
Write-Host " - IntuneModels.csv"
Write-Host " - IntuneFilterPreview.csv"
Write-Host " - ExcludedModels.csv"

Write-Host ""
Write-Host "Finished." -ForegroundColor Green