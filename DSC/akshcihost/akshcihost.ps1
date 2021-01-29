configuration AKSHCIHost
{
    param 
    ( 
        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$AdminCreds,
        [Int]$RetryCount = 20,
        [Int]$RetryIntervalSec = 30,
        [string]$vSwitchNameHost = "InternalNAT",
        [String]$targetDrive = "V:",
        [String]$sourcePath = "$targetDrive\source",
        [String]$targetVMPath = "$targetDrive\VMs",
        [String]$baseVHDFolderPath = "$targetVMPath\base"
    ) 
    
    Import-DscResource -ModuleName 'xStorage'
    Import-DscResource -ModuleName 'NetworkingDSC'
    Import-DscResource -ModuleName 'PSDesiredStateConfiguration'
    Import-DscResource -ModuleName 'ComputerManagementDsc'
    Import-DscResource -ModuleName 'xHyper-v'
    Import-DscResource -ModuleName 'cHyper-v'
    Import-DscResource -ModuleName 'xPSDesiredStateConfiguration'
    Import-DscResource -ModuleName 'xDHCpServer'
    Import-DscResource -ModuleName 'xDNSServer'
    Import-DscResource -ModuleName 'cChoco'
    Import-DscResource -ModuleName 'DSCR_Shortcut'
    
    $branchFiles = "https://github.com/mattmcspirit/jsontesting/archive/main.zip"

    Node localhost
    {
        LocalConfigurationManager {
            RebootNodeIfNeeded = $true
            ActionAfterReboot  = 'ContinueConfiguration'
            ConfigurationMode  = 'ApplyOnly'
        }

        xWaitforDisk Disk1
        {
            DiskID     = 1
            RetryIntervalSec =$RetryIntervalSec
            RetryCount = $RetryCount
        }

        xDisk dataDisk
        {
            DiskID      = 1
            DriveLetter = $targetDrive
            DependsOn   = "[xWaitForDisk]Disk1"
        }

        File "source" {
            DestinationPath = $sourcePath
            Type            = 'Directory'
            Force           = $true
            DependsOn       = "[xDisk]dataDisk"
        }

        File "folder-vms" {
            Type            = 'Directory'
            DestinationPath = $targetVMPath
            DependsOn       = "[xDisk]dataDisk"
        }

        File "VM-base" {
            Type            = 'Directory'
            DestinationPath = $baseVHDFolderPath
            DependsOn       = "[File]folder-vms"
        } 

        Registry "Disable Internet Explorer ESC for Admin" {
            Key       = "HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A7-37EF-4b3f-8CFC-4F3A74704073}"
            ValueName = "IsInstalled"
            ValueData = "0"
            ValueType = "Dword"
        }

        Registry "Disable Internet Explorer ESC for User" {
            Key       = "HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A8-37EF-4b3f-8CFC-4F3A74704073}"
            ValueName = "IsInstalled"
            ValueData = "0"
            ValueType = "Dword"
        }

        Registry "Add Wac to Intranet zone for SSO" {
            Key       = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Internet Settings\ZoneMap\EscDomains\wac'
            ValueName = "https"
            ValueData = 1
            ValueType = 'Dword'
        }

        ScheduledTask "Disable Server Manager at Startup"
        {
            TaskName = 'ServerManager'
            Enable   = $false
            TaskPath = '\Microsoft\Windows\Server Manager'
        }

        script "Download branch files for main" {
            GetScript  = {
                $result = Test-Path -Path "$using:sourcePath\main.zip"
                return @{ 'Result' = $result }
            }

            SetScript  = {
                Invoke-WebRequest -Uri $using:branchFiles -OutFile "$using:sourcePath\main.zip"
                #Start-BitsTransfer -Source $using:branchFiles -Destination "$using:sourcePath\$using:branch.zip"        
            }

            TestScript = {
                # Create and invoke a scriptblock using the $GetScript automatic variable, which contains a string representation of the GetScript.
                $state = [scriptblock]::Create($GetScript).Invoke()
                return $state.Result
            }
            DependsOn  = "[File]source"
        }

        WindowsFeature DNS { 
            Ensure = "Present" 
            Name   = "DNS"		
        }

        WindowsFeature "Enable Deduplication" { 
            Ensure = "Present" 
            Name   = "FS-Data-Deduplication"		
        }

        Script EnableDNSDiags {
            SetScript  = { 
                Set-DnsServerDiagnostics -All $true
                Write-Verbose -Verbose "Enabling DNS client diagnostics" 
            }
            GetScript  = { @{} }
            TestScript = { $false }
            DependsOn  = "[WindowsFeature]DNS"
        }

        WindowsFeature DnsTools {
            Ensure    = "Present"
            Name      = "RSAT-DNS-Server"
            DependsOn = "[WindowsFeature]DNS"
        }

        WindowsFeature "Install DHCPServer" {
            Name   = 'DHCP'
            Ensure = 'Present'
        }

        WindowsFeature DHCPTools {
            Ensure    = "Present"
            Name      = "RSAT-DHCP"
            DependsOn = "[WindowsFeature]Install DHCPServer"
        }

        WindowsFeature "Hyper-V" {
            Name   = "Hyper-V"
            Ensure = "Present"
        }

        WindowsFeature "RSAT-Hyper-V-Tools" {
            Name      = "RSAT-Hyper-V-Tools"
            Ensure    = "Present"
            DependsOn = "[WindowsFeature]Hyper-V" 
        }

        WindowsFeature "RSAT-Clustering" {
            Name   = "RSAT-Clustering"
            Ensure = "Present"
        }

        xVMHost "hpvHost"
        {
            IsSingleInstance          = 'yes'
            EnableEnhancedSessionMode = $true
            VirtualHardDiskPath       = $targetVMPath
            VirtualMachinePath        = $targetVMPath
            DependsOn                 = "[WindowsFeature]Hyper-V"
        }

        xVMSwitch "$vSwitchNameHost"
        {
            Name      = $vSwitchNameHost
            Type      = "Internal"
            DependsOn = "[WindowsFeature]Hyper-V"
        }

        IPAddress "New IP for vEthernet $vSwitchNameHost"
        {
            InterfaceAlias = "vEthernet `($vSwitchNameHost`)"
            AddressFamily  = 'IPv4'
            IPAddress      = '192.168.0.1/24'
            DependsOn      = "[xVMSwitch]$vSwitchNameHost"
        }

        NetIPInterface "Enable IP forwarding on vEthernet $vSwitchNameHost"
        {   
            AddressFamily  = 'IPv4'
            InterfaceAlias = "vEthernet `($vSwitchNameHost`)"
            Forwarding     = 'Enabled'
            DependsOn      = "[IPAddress]New IP for vEthernet $vSwitchNameHost"
        }

        NetAdapterRdma "Enable RDMA on vEthernet $vSwitchNameHost"
        {
            Name      = "vEthernet `($vSwitchNameHost`)"
            Enabled   = $true
            DependsOn = "[NetIPInterface]Enable IP forwarding on vEthernet $vSwitchNameHost"
        }

        DnsServerAddress "DnsServerAddress for vEthernet $vSwitchNameHost" 
        { 
            Address        = '127.0.0.1' 
            InterfaceAlias = "vEthernet `($vSwitchNameHost`)"
            AddressFamily  = 'IPv4'
            DependsOn      = "[IPAddress]New IP for vEthernet $vSwitchNameHost"
        }

        xDhcpServerOption "DHCpServerOption" 
        { 
            Ensure             = 'Present'
            DnsDomain          = 'akshci.local'
            DnsServerIPAddress = '192.168.0.1'
            AddressFamily      = 'IPv4'
            DependsOn          = @("[WindowsFeature]Install DHCPServer", "[IPAddress]New IP for vEthernet $vSwitchNameHost")
        }

        xDhcpServerScope "Scope 192.168.0.0" { 
            Ensure        = 'Present'
            IPStartRange  = '192.168.0.3'
            IPEndRange    = '192.168.0.240' 
            ScopeId       = '192.168.0.0'
            Name          = 'AKS-HCI Range' 
            SubnetMask    = '255.255.255.0' 
            LeaseDuration = '01.00:00:00' 
            State         = 'Inactive'
            AddressFamily = 'IPv4'
            DependsOn     = "[xDhcpServerScope]Scope 192.168.0.0"
        }

        DhcpScopeOptionValue "DHCpServerScopeOption" {
            OptionId      = 3
            Value         = '192.168.0.1'
            ScopeId       = '192.168.0.0'
            AddressFamily = 'IPv4'
            DependsOn     = "[xDhcpServerOption]DHCpServerOption"
        }

        script NAT {
            GetScript  = {
                $nat = "AKSHCINAT"
                $result = if (Get-NetNat -Name $nat -ErrorAction SilentlyContinue) { $true } else { $false }
                return @{ 'Result' = $result }
            }

            SetScript  = {
                $nat = "AKSHCINAT"
                New-NetNat -Name $nat -InternalIPInterfaceAddressPrefix "192.168.0.0/24"          
            }

            TestScript = {
                # Create and invoke a scriptblock using the $GetScript automatic variable, which contains a string representation of the GetScript.
                $state = [scriptblock]::Create($GetScript).Invoke()
                return $state.Result
            }
            DependsOn  = "[IPAddress]New IP for vEthernet $vSwitchNameHost"
        }

        xDnsServerPrimaryZone SetPrimaryDNSZone {
            Name          = 'akshci.local'
            Ensure        = 'Present'
            DependsOn     = "[script]NAT"
            ZoneFile      = 'akshci.local.dns'
            DynamicUpdate = 'NonSecureAndSecure'
        }

        xDnsServerPrimaryZone SetReverseLookupZone {
            Name          = '0.168.192.in-addr.arpa'
            Ensure        = 'Present'
            DependsOn     = "[xDnsServerPrimaryZone]SetPrimaryDNSZone"
            ZoneFile      = '0.168.192.in-addr.arpa.dns'
            DynamicUpdate = 'NonSecureAndSecure'
        }

        xDnsServerSetting SetListener {
            Name            = 'AksHciListener'
            ListenAddresses = '192.168.0.1'
            Forwarders      = @('1.1.1.1', '1.0.0.1')
            DependsOn       = "[xDnsServerPrimaryZone]SetReverseLookupZone"
        }

        Script SetDHCPDNSSetting {
            SetScript  = { 
                Set-DhcpServerv4DnsSetting -DynamicUpdates "Always" -DeleteDnsRRonLeaseExpiry $True -UpdateDnsRRForOlderClients $True -DisableDnsPtrRRUpdate $false
                Write-Verbose -Verbose "Setting server level DNS dynamic update configuration settings" 
            }
            GetScript  = { @{} 
            }
            TestScript = { $false }
            DependsOn  = "[xDnsServerSetting]SetListener"
        }
        
        cChocoInstaller InstallChoco {
            InstallDir = "c:\choco"
        }

        cChocoFeature allowGlobalConfirmation {
            FeatureName = "allowGlobalConfirmation"
            Ensure      = 'Present'
            DependsOn   = '[cChocoInstaller]installChoco'
        }

        cChocoFeature useRememberedArgumentsForUpgrades {
            FeatureName = "useRememberedArgumentsForUpgrades"
            Ensure      = 'Present'
            DependsOn   = '[cChocoInstaller]installChoco'
        }

        cChocoPackageInstaller "Install Chromium Edge" {
            Name        = 'microsoft-edge'
            Ensure      = 'Present'
            AutoUpgrade = $true
            DependsOn   = '[cChocoInstaller]installChoco'
        }
    }
}