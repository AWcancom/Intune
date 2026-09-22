#Setting registry key to block AAD Registration 
$RegistryLocation = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
$keyname = "TaskbarAl"

#Test if path exists and create if missing
if (!(Test-Path -Path $RegistryLocation)){
Write-Output "Registry location missing. Creating"
New-Item $RegistryLocation | Out-Null
}

#Force create key with value 1 
New-ItemProperty -Path $RegistryLocation -Name $keyname -PropertyType DWord -Value 0 -Force | Out-Null
Write-Output "Registry key set"