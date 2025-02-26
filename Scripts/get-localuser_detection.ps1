$Username = "LAPSAdmin"
$Userexists = (Get-LocalUser).Name -Contains $Username

if ($userexists) { 
    Write-Host "The account $Username already exists" 
    Exit 0
} 
Else {
    Write-Host "The account $Username does not Exist"
    Exit 1
}