<#
.DESCRIPTION
    Script to remediate BitLocker Key escrow into Azure AD
.EXAMPLE
    PowerShell.exe -ExecutionPolicy ByPass -File <ScriptName>.ps1
.NOTES
    VERSION     AUTHOR              CHANGE
    1.0         Jonathan Conway     Initial script creation
#>
 
# Escrow BitLocker Recovery Key for OSDrive into Azure AD
$BitLockerVolume = Get-BitLockerVolume -MountPoint $env:SystemRoot
$RecoveryPasswordKeyProtector = $BitLockerVolume.KeyProtector | Where-Object { $_.KeyProtectorType -like "RecoveryPassword" }
BackupToAAD-BitLockerKeyProtector -MountPoint $BitLockerVolume.MountPoint -KeyProtectorId $RecoveryPasswordKeyProtector.KeyProtectorId -ErrorAction SilentlyContinue
