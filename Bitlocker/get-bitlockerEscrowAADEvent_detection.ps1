<#
.DESCRIPTION
    Script to check for BitLocker Key escrow into Azure AD
.EXAMPLE
    PowerShell.exe -ExecutionPolicy ByPass -File <ScriptName>.ps1
.NOTES
    VERSION     AUTHOR              CHANGE
    1.0         Jonathan Conway     Initial script creation
#>
 
# Check for Event 845 in BitLocker API Management Event Log over last 7 days - if contains text "was backed up successfully to your Azure AD" then Detection is complete
try {
    $Result = Get-WinEvent -FilterHashTable @{LogName = "Microsoft-Windows-BitLocker/BitLocker Management"; StartTime = (Get-Date).AddDays(-7) } | Where-Object { ($_.Id -eq "845" -and $_.Message -match "was backed up successfully to your Azure AD") } | Format-Table -Property "Message"
    $ID = $Result | Measure-Object
 
    if ($ID.Count -ge 1) {
        Write-Output "BitLocker Recovery Key escrow to Azure AD succeeded = Compliant"
        exit 0
    }
 
    # If Event is not detected then mark as 'Non Compliant' and exit with 1
    else {
        Write-Warning "BitLocker Escrow Event Missing = Non Compliant"
        exit 1
    }
}
 
catch {
    Write-Warning "An error occurred = Non Compliant"
    exit 1
}