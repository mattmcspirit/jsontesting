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

        #### STAGE 1b - CREATE STORAGE SPACES V: & VM FOLDER ####

        Script StoragePool {
            SetScript  = {
                New-StoragePool -FriendlyName AksHciPool -StorageSubSystemFriendlyName '*storage*' -PhysicalDisks (Get-PhysicalDisk -CanPool $true)
            }
            TestScript = {
                (Get-StoragePool -ErrorAction SilentlyContinue -FriendlyName AksHciPool).OperationalStatus -eq 'OK'
            }
            GetScript  = {
                @{Ensure = if ((Get-StoragePool -FriendlyName AksHciPool).OperationalStatus -eq 'OK') { 'Present' } Else { 'Absent' } }
            }
            DependsOn  = "[Script]Fake reboot"
        }
        Script VirtualDisk {
            SetScript  = {
                $disks = Get-StoragePool -FriendlyName AksHciPool -IsPrimordial $False | Get-PhysicalDisk
                $diskNum = $disks.Count
                New-VirtualDisk -StoragePoolFriendlyName AksHciPool -FriendlyName AksHciDisk -ResiliencySettingName Simple -NumberOfColumns $diskNum -UseMaximumSize
            }
            TestScript = {
                (Get-VirtualDisk -ErrorAction SilentlyContinue -FriendlyName AksHciDisk).OperationalStatus -eq 'OK'
            }
            GetScript  = {
                @{Ensure = if ((Get-VirtualDisk -FriendlyName AksHciDisk).OperationalStatus -eq 'OK') { 'Present' } Else { 'Absent' } }
            }
            DependsOn  = "[Script]StoragePool"
        }
        Script FormatDisk {
            SetScript  = {
                $vDisk = Get-VirtualDisk -FriendlyName AksHciDisk
                if ($vDisk | Get-Disk | Where-Object PartitionStyle -eq 'raw') {
                    $vDisk | Get-Disk | Initialize-Disk -Passthru | New-Partition -DriveLetter $Using:targetDrive -UseMaximumSize | Format-Volume -NewFileSystemLabel AksHciData -AllocationUnitSize 64KB -FileSystem NTFS
                }
                elseif ($vDisk | Get-Disk | Where-Object PartitionStyle -eq 'GPT') {
                    $vDisk | Get-Disk | New-Partition -DriveLetter $Using:targetDrive -UseMaximumSize | Format-Volume -NewFileSystemLabel AksHciData -AllocationUnitSize 64KB -FileSystem NTFS
                }
            }
            TestScript = { 
                (Get-Volume -ErrorAction SilentlyContinue -FileSystemLabel AksHciData).FileSystem -eq 'NTFS'
            }
            GetScript  = {
                @{Ensure = if ((Get-Volume -FileSystemLabel AksHciData).FileSystem -eq 'NTFS') { 'Present' } Else { 'Absent' } }
            }
            DependsOn  = "[Script]VirtualDisk"
        }

        File "VMfolder" {
            Type            = 'Directory'
            DestinationPath = $targetVMPath
            DependsOn       = "[Script]FormatDisk"
        }
        
        File "ADfolder" {
            Type            = 'Directory'
            DestinationPath = $targetADPath
            DependsOn       = "[Script]FormatDisk"
        }

        #### STAGE 1c - SET WINDOWS DEFENDER EXCLUSION FOR VM STORAGE ####

        Script defenderExclusions {
            SetScript  = {
                $exclusionPath = "$Using:targetDrive" + ":\"
                Add-MpPreference -ExclusionPath "$exclusionPath"               
            }
            TestScript = {
                $exclusionPath = "$Using:targetDrive" + ":\"
                (Get-MpPreference).ExclusionPath -contains "$exclusionPath"
            }
            GetScript  = {
                $exclusionPath = "$Using:targetDrive" + ":\"
                @{Ensure = if ((Get-MpPreference).ExclusionPath -contains "$exclusionPath") { 'Present' } Else { 'Absent' } }
            }
            DependsOn  = @("[File]VMfolder", "[File]ADfolder")
        }
        
        #### STAGE 1d - REGISTRY & SCHEDULED TASK TWEAKS ####

        Registry "Disable Internet Explorer ESC for Admin" {
            Key       = "HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A7-37EF-4b3f-8CFC-4F3A74704073}"
            Ensure    = 'Present'
            ValueName = "IsInstalled"
            ValueData = "0"
            ValueType = "Dword"
        }

        Registry "Disable Internet Explorer ESC for User" {
            Key       = "HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A8-37EF-4b3f-8CFC-4F3A74704073}"
            Ensure    = 'Present'
            ValueName = "IsInstalled"
            ValueData = "0"
            ValueType = "Dword"
        }

        Registry "Add Wac to Intranet zone for SSO" {
            Key       = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Internet Settings\ZoneMap\EscDomains\wac'
            Ensure    = 'Present'
            ValueName = "https"
            ValueData = "1"
            ValueType = 'Dword'
        }
        
        <#
        Registry "Disable Server Manager WAC Prompt" {
            Key       = "HKLM:\SOFTWARE\Microsoft\ServerManager"
            Ensure    = 'Present'
            ValueName = "DoNotPopWACConsoleAtSMLaunch"
            ValueData = "1"
            ValueType = "Dword"
            DependsOn  = @("[File]VMfolder", "[File]ADfolder")
        }

        
        Registry "Disable Network Profile Prompt" {
            Key       = 'HKLM:\System\CurrentControlSet\Control\Network\NewNetworkWindowOff'
            Ensure    = 'Present'
            ValueName = ''
            DependsOn  = @("[File]VMfolder", "[File]ADfolder")
        }
        #>

        ScheduledTask "Disable Server Manager at Startup" {
            TaskName = 'ServerManager'
            Enable   = $false
            TaskPath = '\Microsoft\Windows\Server Manager'
        }

        #### STAGE 1e - CUSTOM FIREWALL BASED ON ARM TEMPLATE ####

        if ($customRdpPort -ne "3389") {

            Registry "Set Custom RDP Port" {
                Key       = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp'
                ValueName = "PortNumber"
                ValueData = "$customRdpPort"
                ValueType = 'Dword'
            }
        
            Firewall AddFirewallRule {
                Name        = 'CustomRdpRule'
                DisplayName = 'Custom Rule for RDP'
                Ensure      = 'Present'
                Enabled     = 'True'
                Profile     = 'Any'
                Direction   = 'Inbound'
                LocalPort   = "$customRdpPort"
                Protocol    = 'TCP'
                Description = 'Firewall Rule for Custom RDP Port'
            }
        }
    }
}