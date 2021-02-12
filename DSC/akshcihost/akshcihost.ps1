configuration AKSHCIHost
{
    param 
    ( 
        [Parameter(Mandatory)]
        [string]$DomainName,
        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$Admincreds,
        [Parameter(Mandatory)]
        [string]$enableDHCP,
        [Parameter(Mandatory)]
        [string]$customRdpPort,
        [Int]$RetryCount = 20,
        [Int]$RetryIntervalSec = 30,
        [string]$vSwitchNameHost = "InternalNAT",
        [String]$targetDrive = "V",
        [String]$targetVMPath = "$targetDrive" + ":\VMs",
        [String]$targetADPath = "$targetDrive" + ":\ADDS",
        [String]$baseVHDFolderPath = "$targetVMPath\base"
    ) 
    
    Import-DscResource -ModuleName 'PSDesiredStateConfiguration'
    Import-DscResource -ModuleName 'xPSDesiredStateConfiguration'
    Import-DscResource -ModuleName 'ComputerManagementDsc'
    Import-DscResource -ModuleName 'xHyper-v'
    Import-DscResource -ModuleName 'StorageDSC'
    Import-DscResource -ModuleName 'NetworkingDSC'
    Import-DscResource -ModuleName 'xDHCpServer'
    Import-DscResource -ModuleName 'xDNSServer'
    Import-DscResource -ModuleName 'cChoco'
    Import-DscResource -ModuleName 'DSCR_Shortcut'
    Import-DscResource -ModuleName 'xCredSSP'
    Import-DscResource -ModuleName 'xActiveDirectory'

    if ($enableDHCP -eq "Enabled") {
        $dhcpStatus = "Active"
    }
    else { $dhcpStatus = "Inactive" }

    [System.Management.Automation.PSCredential]$DomainCreds = New-Object System.Management.Automation.PSCredential ("${DomainName}\$($Admincreds.UserName)", $Admincreds.Password)

    $ipConfig = (Get-NetAdapter -Physical | Get-NetIPConfiguration | Where-Object IPv4DefaultGateway)
    $netAdapters = Get-NetAdapter -Name ($ipConfig.InterfaceAlias) | Select-Object -First 1
    $InterfaceAlias = $($netAdapters.Name)

    Node localhost
    {
        LocalConfigurationManager {
            RebootNodeIfNeeded = $true
            ActionAfterReboot  = 'ContinueConfiguration'
            ConfigurationMode  = 'ApplyOnly'
        }

        #### STAGE 1a - INSTALL CHOCO & DEPLOY EDGE

        cChocoInstaller InstallChoco {
            InstallDir = "c:\choco"
        }
                    
        cChocoFeature allowGlobalConfirmation {
            FeatureName = "allowGlobalConfirmation"
            Ensure      = 'Present'
            DependsOn   = '[cChocoInstaller]InstallChoco'
        }
                
        cChocoFeature useRememberedArgumentsForUpgrades {
            FeatureName = "useRememberedArgumentsForUpgrades"
            Ensure      = 'Present'
            DependsOn   = '[cChocoInstaller]InstallChoco'
        }
                
        cChocoPackageInstaller "Install Chromium Edge" {
            Name        = 'microsoft-edge'
            Ensure      = 'Present'
            AutoUpgrade = $true
            DependsOn   = '[cChocoInstaller]InstallChoco'
        }
        
        cChocoPackageInstaller "Install WAC" {
            Name        = 'windows-admin-center'
            Ensure      = 'Present'
            AutoUpgrade = $true
            DependsOn   = '[cChocoInstaller]InstallChoco'
            Params      = "'/Port:443'"
        }

        PendingReboot "reboot"
        {
            Name = 'reboot'
        }

        Script "Fake reboot"
        {
            TestScript = {
                return (Test-Path HKLM:\SOFTWARE\RebootKey)
            }
            SetScript = {
                New-Item -Path HKLM:\SOFTWARE\RebootKey -Force
                $global:DSCMachineStatus = 1 
            }
            GetScript = {
                return @{result = 'result'}
            }
            DependsOn = "[cChocoPackageInstaller]Install WAC"
        }
    }
}