
# Define allowed IP addresses or subnets (comma-separated)
$allowedIPs = "*"

# Ensure WinRM service is set to start automatically and is running
Set-Service -Name WinRM -StartupType Automatic
Start-Service -Name WinRM

# Enable PowerShell Remoting
Enable-PSRemoting -Force
# Set IPv4Filter to restrict incoming connections
winrm set winrm/config/service "@{IPv4Filter=`"$allowedIPs`"}"

# Set TrustedHosts (optional, for outgoing connections)
Set-Item -Path WSMan:\localhost\Client\TrustedHosts -Value $allowedIPs -Force

# Confirm or create HTTP listener with IP filter
$listener = Get-WSManInstance -ResourceURI winrm/config/Listener -Enumerate
if (-not ($listener | Where-Object { $_.Transport -eq "HTTP" })) {
    Write-Output "Creating HTTP listener..."
    winrm create winrm/config/Listener?Address=*+Transport=HTTP "@{Hostname=`"*`"; Enabled=`"true`"; IPv4Filter=`"$allowedIPs`"}"
} else {
    Write-Output "HTTP listener already exists."
}
