function Get-RandomPassword {
    param (
        [Parameter(Mandatory)]
        [int] $length,
        [int] $amountOfNonAlphanumeric = 1
        )
    Add-Type -AssemblyName 'System.Web'
    return [System.Web.Security.Membership]::GeneratePassword($length, $amountOfNonAlphanumeric)
}

$userName = "LAPSAdmin"
$userexist = (Get-LocalUser).Name -Contains $userName
$password = Get-RandomPassword -Length 30 | ConvertTo-SecureString -AsPlainText -Force

if($userexist -eq $false) {
    try {
        New-LocalUser -Name $username -Description "LAPS admin account" -Password $password
        Exit 0
    }
    Catch {
        Write-error $_
        Exit 1
    }
}
