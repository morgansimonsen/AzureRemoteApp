<#
	.NAME
    New-AzureCustomRemoteAppImage.ps1

    .SYNOPSIS
	Builds an Azure RemoteApp image in an Azure VM

	.DESCRIPTION
    Used to automate the build process for Azure RemoteApp images
    Operations:
    - Create VM from a previous specialized image
    - Create a new specialized image, a snapshot of the changes performed
    - Create a new generalized image to be imported into ARA
    - Import image into RemoteApp storage accounts
	
    .VERSION
    0.2

    .AUTHOR
    Morgan Simonsen, Lumagate
    morgan.simonsen@lumagate.com
	
    .PARAMETER VMHostName
    Host name of the VM to create

	.PARAMETER CloudServiceName
    Name of cloud service to create VM in
    We do not check if this exits

	.PARAMETER VMSourceImageName
    Name of the Azure OS Image to create the new VM from

	.PARAMETER VMNewSpecializedImageName
    Name of the new specialized image to created, based on the changes the user made in the image
    This will server as the source image on the next build cycle

	.PARAMETER VMNewGeneralizedImageName
    Name of the new generalized image to create and later import into Azure RemoteApp
    This is a sysprepped image

    .PARAMETER AzureRemoteAppImageName
    Name given to the imported generalized image when stored in the Azure RemoteApp image gallery

	.EXAMPLE
	.\New-AzureCustomRemoteAppImage.ps1 -VMName aratest1 -CloudServiceName tc-ara-build -VMSourceImageName araimgbuild-v02-20150304-206047 -VMNewSpecializedImageName araimgbuild-v03-spec -VMNewGeneralizedImageName araimgbuild-v03-gen

	.OUTPUTS
	None

	.NOTES
	- It is probably a good idea NOT to join the VM to a domain
    - Use the Azure RemoteApp collection name as a base for the images created; specialized, generalized and Azure RemoteApp Template
      E.g.
      Specialized        : <collectionname>-<version>-spe
      Generalized        : <collectionname>-<version>-gen
      ARA Template image : <collectionname>-<version>
    - The VM name, the one visible in the Azure portal, can be anything since the VM container is destroyed when the generalized image is created

	.LINK
#>

# Parameters
[CmdletBinding()]
Param(
    [Parameter(Mandatory=$True,Position=1)]
    [string]$VMHostName,

  [Parameter(Mandatory=$True,Position=2)]
   [string]$CloudServiceName,

  [Parameter(Mandatory=$True,Position=3)]
   [string]$vNetName,

  [Parameter(Mandatory=$True,Position=4)]
   [string]$SubnetName,

  [Parameter(Mandatory=$True,Position=5,ParameterSetName="GenericImage")]
   [string]$VMSourceGenericImageFamilyName="Windows Server RDSHwO365P on Windows Server 2012 R2",

  [Parameter(Mandatory=$True,Position=5,ParameterSetName="CustomImage")]
   [string]$VMSourceCustomImageName,

  [Parameter(Mandatory=$True,Position=6)]
   [string]$VMNewSpecializedImageName,

    [Parameter(Mandatory=$True,Position=7)]
    [string]$VMNewGeneralizedImageName,

    [Parameter(Mandatory=$True,Position=8)]
    [string]$AzureRemoteAppImageName,

    [Parameter(Mandatory=$True,Position=9)]
    [string]$AzureRemoteAppImageLocation   
)

# Variables
$VMSize = "A5"
$VMConfigurationArchive = "AzureRemoteApp.ps1.zip"
$VMConfigurationName = "AzureRemoteAppImageBuild"  
#$vNetName = "SafeRoad-vNET1"
#$SubnetName = "MemberServers"
#$Location = "North Europe"

# Load my custom functions module
Import-Module "..\ManagementInclude.psm1" -Force

# Load credentials
Get-CustomerCredentials

# PSAutomation compatible credentials
# When connecting to VM with remote PowerShell using a local account the New-PSSession cmdlet requires a credential object that
# includes the servername, like server\user. If just username is specified we get access denied
# This object is a second version of the LocalServerCredentials object that includes the servername
$LocalServerCredentials2 = New-Object System.Management.Automation.PSCredential (($VMHostName+"\"+$LocalServerCredentials.UserName), ($LocalServerCredentials.Password))

# Select the Azure subscription from the Current Working Directory (CWD)
# Make sure you are in the right one
#Select-AzureCWDSubscription
Add-AzureAccount

#=====================================================================
# MAIN SCRIPT
#=====================================================================

# Starting up
Write-Host "Starting creation of new Azure RemoteApp image..."
Write-Host "Source image information:"

switch ($PsCmdlet.ParameterSetName) 
{ 
    "GenericImage"
    {
        $SelectedARAImageName = Get-AzureLatestVMImageVersion $VMSourceGenericImageFamilyName
        Write-Verbose "Image family: $VMSourceGenericImageFamilyName"
        Write-Verbose "Using image: $SelectedARAImageName"
        Get-AzureVMImage -ImageName $SelectedARAImageName | Select ImageName,Label,Description
    } 
    "CustomImage"
    {
        Get-AzureVMImage -ImageName $VMSourceCustomImageName | Select ImageName,Label,Description -ExpandProperty OSDiskConfiguration
    }
} 

Write-Host "VM Host name        : $VMHostName"
Write-Host "Cloud Service  : $CloudServiceName"

# Check if VM already exists
Write-Host "Checking for existing VM..."
If (Get-AzureVM -ServiceName $CloudServiceName -Name $VMHostName)
{
    Write-Host "VM $VMHostName already exists in Cloud Service $CloudServiceName; quitting!"
    Exit
}
Else
{
    Write-Host "VM $VMHostName not found; continuing..."
}

# Configure and provision VM
Write-Host "Provisioning VM..."

switch ($PsCmdlet.ParameterSetName) 
{ 
    "GenericImage"
    {
        New-AzureQuickVM -Windows -Name $VMHostName -ServiceName $CloudServiceName -ImageName $SelectedARAImageName -WaitForBoot -VNetName $vNetName -SubnetNames $SubnetName -InstanceSize $VMSize -AdminUsername $LocalServerCredentials.UserName -Password ($LocalServerCredentials.GetNetworkCredential().password)
    }
    "CustomImage"
    {
        New-AzureQuickVM -Windows -Name $VMHostName -ServiceName $CloudServiceName -ImageName $VMSourceCustomImageName -WaitForBoot -VNetName $vNetName -SubnetNames $SubnetName -InstanceSize $VMSize
    }
}

# Get new VM object
$NewVM = Get-AzureVM -ServiceName $CloudServiceName -Name $VMHostName

# Download RDP file
Write-Host "Downloading RDP file..."
Get-AzureRemoteDesktopFile -ServiceName $CloudServiceName -Name $VMHostName -LocalPath ([environment]::getfolderpath("UserProfile")+"\Downloads\"+$VMHostName+".rdp")

# Prompt to customize
$RemoteDesktopEndpoint = $NewVM | Get-AzureEndpoint | where { $_.LocalPort -eq 3389 }
# Wait for VM RDP Endpoint to become available
Do
{
    Try
    {
    (New-Object System.Net.Sockets.TcpClient).Connect($CloudServiceName,$RemoteDesktopEndpoint)
    $RDPOK=$true
    }
    Catch
    {
    Start-Sleep 5
    $RDPOK=$false
    }
}
Until ( $RDPOK=$true )

Write-Host "VM ready for user customization, connect using downloaded RDP file."
Write-Host "Internal IP address:                  " $NewVM.IpAddress
Write-Host "Cloud service connection information: " ($CloudServiceName+":"+($RemoteDesktopEndpoint).ToString())

PressKeyToContinue -pauseKey "I" -modifier Alt -hideKeysStrokes:$true

#Shut down VM before specialized capture
Write-Host "Shutting down VM in preparation of specialized capture..."
$NewVM | Stop-AzureVM -StayProvisioned:$true

# Wait for VM to shut down
Do
{
    $NewVM = Get-AzureVM -ServiceName $CloudServiceName -Name $VMHostName
    Start-Sleep 5
}
Until ( $NewVM.InstanceStatus -eq "StoppedVM" )

# Save specialized copy
Write-Host "Starting specialized capture..."
$NewVM | Save-AzureVMImage –ImageName $VMNewSpecializedImageName –OSState "Specialized"

Write-Host "Starting VM..."
$NewVM | Start-AzureVM

# Wait for VM to become ready
Do
{
    $NewVM = Get-AzureVM -ServiceName $CloudServiceName -Name $VMHostName
    Start-Sleep 5
}
Until ( $NewVM.InstanceStatus -eq "ReadyRole" )

# Must wait longer here; or check that PS endpoint/connection works

# Run sysprep in VM
Write-Host "Running sysprep in VM..."
$pso = New-PSSessionOption -SkipCACheck:$true -SkipCNCheck:$true -SkipRevocationCheck:$true
$PowerShellEndpoint = $NewVM | Get-AzureEndpoint | where { $_.LocalPort -eq 5986 }
$VMSession = New-PSSession -ComputerName ($NewVM.ServiceName+".cloudapp.net") -Credential $LocalServerCredentials2 -SessionOption $pso -UseSSL -Port $PowerShellEndpoint.Port
Invoke-Command -Session $VMSession -ScriptBlock { Set-Content -Value ((gc env:systemroot)+"\system32\sysprep\sysprep.exe /oobe /generalize /shutdown") -Path runsysprep.cmd }
#Invoke-Command -Session $VMSession -ScriptBlock { If (!(Get-WURebootStatus -Silent)) { Start-Process -FilePath .\runsysprep.cmd -WindowStyle Normal -Verbose} Else { Write-Host "A reboot is pending, cannot run sysprep. Manually restart server and run sysprep" } }
Invoke-Command -Session $VMSession -ScriptBlock { Start-Process -FilePath .\runsysprep.cmd -WindowStyle Normal -Verbose} 

#PressKeyToContinue -pauseKey "I" -modifier Alt -hideKeysStrokes:$true

# Save specialized copy
Write-Host "Starting generalized capture..."

# Wait for VM to shut down
Do
{
    $NewVM = Get-AzureVM -ServiceName $CloudServiceName -Name $VMHostName
    Start-Sleep 5
}
Until ( $NewVM.InstanceStatus -eq "StoppedVM" )

$NewVM | Save-AzureVMImage –ImageName $VMNewGeneralizedImageName –OSState "Generalized"

# Import custom image into Azure RemoteApp storage
Write-Host "Importing VM image to Azure RemoteApp storage..."
#.\Import-AzureRemoteAppTemplateImage.ps1 -AzureVMImageName $VMNewGeneralizedImageName -RemoteAppTemplateImageName $AzureRemoteAppImageName
New-AzureRemoteAppTemplateImage -ImageName $AzureRemoteAppImageName -Location $AzureRemoteAppImageLocation -AzureVmImageName $VMNewGeneralizedImageName

# Wait for image import to finish
[int]$s = 60
Write-Host "Waiting for image import to finish... (Checking status every $s seconds)"
Do
    {
        $AzureRemoteAppImageImportStatus = (Get-AzureRemoteAppTemplateImage -ImageName $AzureRemoteAppImageName).Status
        Write-Host "  Image upload status: $AzureRemoteAppImageImportStatus"
        Start-Sleep $s
    }
Until ($AzureRemoteAppImageImportStatus -eq "Ready")

# Update Azure RemoteApp service
#Write-Host "Importing image into Azure RemoteApp deployment..."
#Update-AzureRemoteAppService -RemoteAppServiceName $AzureRemoteAppServiceName -RemoteAppTemplateImageName $AzureRemoteAppImageName

Write-Host "Done!"
Write-Host "Specialized image name     :" $VMNewSpecializedImageName
Write-Host "Generalized image name     :" $VMNewGeneralizedImageName
Write-Host "Azure RemoteApp image name :" $AzureRemoteAppImageName
