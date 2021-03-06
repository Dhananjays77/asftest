PARAM(
   [Parameter(Mandatory=$True, Position=0)]
   [string]$targetDrive,

   [Parameter(Mandatory=$True, Position=1)]
   [string]$environmentName,

   [Parameter(Mandatory=$True, Position=2)]
   [string]$roleName,

   [Parameter(Mandatory=$True, Position=3)]
   [string]$serviceKey,

   [Parameter(Mandatory=$True, Position=4)]
   [string]$xpertEnvironment,

   [Parameter(Mandatory=$False, Position=5)]
   [switch]$force
)

Set-StrictMode -Version 2.0

#Constants
Set-Variable -Name XpertEndpointOSG -Value ([string]"xpertdata.data.microsoft.com") -Option Constant
Set-Variable -Name XpertEndpointXboxProd -Value ([string]"xpertdata.xboxlive.com") -Option Constant
Set-Variable -Name XpertEndpointXboxNonProd -Value ([string]"xpertdata.dnet.xboxlive.com") -Option Constant

#Maps the xpertEnvironment parameter to the supported DNS names for our public endpoints (Defaults to OSG if input isn't valid)
function MapEnvironmentToXpertEndpoint($environment)
{
    If($environment -ieq "osg")
    {
        $XpertEndpointOSG
    }
    ElseIf($environment -ieq "xbox")
    {
        $XpertEndpointXboxProd
    }
    ElseIf($environment -ieq "xboxnonprod")
    {
        $XpertEndpointXboxNonProd
    }
    Else
    {
        Write-Host -backgroundcolor DarkRed "Invalid environment type provided. Defaulting to OSG."

        $XpertEndpointOSG
    }
}

function Expand-ZIPFile($file, $destination)
{
    #Load the assembly with the ZipFile class
    [System.Reflection.Assembly]::LoadWithPartialName("System.IO.Compression.FileSystem") | Out-Null

    #Unzip the file using the ZipFile class
    [System.IO.Compression.ZipFile]::ExtractToDirectory($file, $destination)
}

function Get-ScriptDirectory
{
    $Invocation = (Get-Variable MyInvocation -Scope 1).Value;
    if($Invocation.PSScriptRoot)
    {
        $Invocation.PSScriptRoot;
    }
    Elseif($Invocation.MyCommand.Path)
    {
        Split-Path $Invocation.MyCommand.Path
    }
    else
    {
        $Invocation.InvocationName.Substring(0, $Invocation.InvocationName.LastIndexOf("\"));
    }
}

$scriptPath = Get-ScriptDirectory
$agentInstallZipPath = "$scriptPath\NonAPXpertBinaries.zip"

#Validate Parameters
If (!(Test-Path($targetDrive))) 
{
    Write-Host -backgroundcolor DarkRed $env:COMPUTERNAME,"Target drive ",$targetDrive," does not exist!"
    Exit
}

If (!(Test-Path($agentInstallZipPath)))
{
    Write-Host -backgroundcolor DarkRed $env:COMPUTERNAME,"Xpert Agent files does not exist!"
    Exit
}

$principal = new-object System.Security.Principal.WindowsPrincipal([System.Security.Principal.WindowsIdentity]::GetCurrent())
If (-not ($principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)))
{
    Write-Host -backgroundcolor DarkRed $env:COMPUTERNAME,"Not running as administrator!"
    Exit
}

$appDir = “$targetDrive\XpertAgent\app”
$dataDir = “$targetDrive\XpertAgent\data”

# Skip the file copy and config, if the app and data folder both exist and the -force flag is set to false
If ( ($force) -or (-not (Test-Path($appDir)) -or (-not (Test-Path($dataDir)))))
{
    #Setup Environment Variables
    Write-Host "Setting Environment Variables..."

    [Environment]::SetEnvironmentVariable(“APPDIR”, $appDir,[EnvironmentVariableTarget]::Machine)
    [Environment]::SetEnvironmentVariable(“DATADIR”, $dataDir,[EnvironmentVariableTarget]::Machine)
    [Environment]::SetEnvironmentVariable(“XPERT_AGENT_INSTALL_LOCATION”, “$appDir\XpertAgent”,[EnvironmentVariableTarget]::Machine)

    Stop-Process -Name Xpert.Agent* -Force

    #Extract ZIP file contents
    Write-Host "Extracting ZIP file..."

    Remove-Item $env:TEMP\XpertAgentInstall\* -Recurse -ErrorAction SilentlyContinue
    New-Item $env:TEMP\XpertAgentInstall\ -ItemType Directory -ErrorAction SilentlyContinue

    Expand-ZIPFile -File $agentInstallZipPath -Destination $env:TEMP\XpertAgentInstall\

    Write-Host "Start file copy..."

    #Copy Files
    robocopy "$env:TEMP\XpertAgentInstall\app\" $appDir /mir /LOG:appcopy.log /R:3
    robocopy "$env:TEMP\XpertAgentInstall\data\" $dataDir /mir /LOG:datacopy.log /R:3

    #Grant Network Service permissions to access APP and DATA folder
    icacls $appDir /grant "NETWORK SERVICE:(OI)(CI)F"
    icacls $dataDir /grant "NETWORK SERVICE:(OI)(CI)F"

    #Setup DataCollectorConfig.xml
    Write-Host "Setting up DataCollector.config.xml..."

    $targetEndpoint = MapEnvironmentToXpertEndpoint($xpertEnvironment)
    $xpertDataCollectorConfig = Get-Content $appDir\xpertagent\DataCollector.config.xml
    $xpertDataCollectorConfig | % { $_.Replace("XPERTENDPOINT", $targetEndpoint) } | Set-Content $appDir\xpertagent\DataCollector.config.xml

    #Setup AgentIdentityConfiguration.xml
    Write-Host "Setting up AgentIdentityConfiguration.xml..."

    $agentIdentityConfiguration = Get-Content $datadir\AgentIdentityConfiguration.xml
    $agentIdentityConfiguration | % { $_.Replace("ENVIRONMENT", $environmentName) } | % { $_.Replace("ROLE", $roleName) } | % { $_.Replace("SERVICEKEY", $serviceKey) } | Set-Content $datadir\AgentIdentityConfiguration.xml

    #Setup XpertAgent.xml file
    Write-Host "Setting up XpertAgent task script..."

    $xpertAgentTaskScript = Get-Content $appDir\xpertagent\XpertAgent.xml
    $xpertAgentTaskScript | % { $_.Replace("XPERT_AGENT_INSTALL_LOCATION", “$appDir\XpertAgent”) } | Set-Content $appDir\xpertagent\XpertAgent.xml

    #Setup XpertAgentStarter.xml file
    Write-Host "Setting up XpertAgentStarter task script..."

    $xpertAgentStarterTaskScript = Get-Content $appDir\xpertagent\XpertAgentStarter.xml
    $xpertAgentStarterTaskScript | % { $_.Replace("XPERT_AGENT_INSTALL_LOCATION", “$appDir\XpertAgent”) } | Set-Content $appDir\xpertagent\XpertAgentStarter.xml

    #Setup Task Scheduler Tasks
    Write-Host "Setting up Task Scheduler tasks..."

    Schtasks /Create /XML $appDir\xpertagent\XpertAgent.xml /TN XpertAgent /f
    Schtasks /Create /XML $appDir\xpertagent\XpertAgentStarter.xml /TN XpertAgentStarter /RU System /f

    #Start the XpertAgentStarter Scheduled Task
    Schtasks /Run /TN XpertAgentStarter
    
    #Give the Scheduled Task time to start the Agent
    Sleep 60
}

$processActive = Get-Process Xpert.Agent -ErrorAction SilentlyContinue
If($processActive -eq $null)
{
    Write-Host -backgroundcolor DarkRed $env:COMPUTERNAME,"XpertAgent not started"
}
Else
{
    Write-Host -backgroundcolor DarkGreen $env:COMPUTERNAME,"XpertAgent started"
}