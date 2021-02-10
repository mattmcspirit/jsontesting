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
        [String]$AdDrive = "F",
        [String]$targetDrive = "V",
        [String]$targetVMPath = "$targetDrive" + ":\VMs",
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

    if ($enableDHCP -eq "Enabled") {
        $dhcpStatus = "Active"
    }
    else { $dhcpStatus = "Inactive" }

    #[System.Management.Automation.PSCredential]$DomainCreds = New-Object System.Management.Automation.PSCredential ("${DomainName}\$($Admincreds.UserName)", $Admincreds.Password)

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

        # STAGE 1 -> PRE-HYPER-V REBOOT
        # STAGE 2 -> POST-HYPER-V REBOOT
        # STAGE 3 -> POST CREDSSP REBOOT

        #### STAGE 1a - CREATE STORAGE SPACES V: & VM FOLDER ####

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
        Script InitializeDisk {
            SetScript  = {
                Get-VirtualDisk -FriendlyName AksHciDisk | Get-Disk | Initialize-Disk
            }
            TestScript = { 
                (Get-Disk -FriendlyName AksHciDisk -ErrorAction SilentlyContinue).PartitionStyle -eq 'GPT'
            }
            GetScript  = {
                @{Ensure = if ((Get-Disk -FriendlyName AksHciDisk).PartitionStyle -eq 'GPT') { 'Present' } Else { 'Absent' } }
            }
            DependsOn  = "[Script]VirtualDisk"
        }

        WaitForDisk Disk1 {
            DiskId           = "$((Get-VirtualDisk -FriendlyName AksHciDisk).UniqueId)"
            DiskIdType       = 'UniqueId'
            RetryIntervalSec = $RetryIntervalSec
            RetryCount       = $RetryCount
            DependsOn        = '[Script]InitializeDisk'
        }

        Disk ADDSvolume {
            DiskId      = "$((Get-VirtualDisk -FriendlyName AksHciDisk).UniqueId)"
            DiskIdType  = 'UniqueId'
            DriveLetter = $AdDrive
            Size        = 20GB
            FSFormat    = 'NTFS'
            DependsOn   = '[WaitForDisk]Disk1'
        }

        Disk AksHCIVolume {
            DiskId      = "$((Get-VirtualDisk -FriendlyName AksHciDisk).UniqueId)"
            DiskIdType  = 'UniqueId'
            DriveLetter = $targetDrive
            FSLabel     = 'AksHciData'
            DependsOn   = '[Disk]ADDSvolume'
        }

        File "VMfolder" {
            Type            = 'Directory'
            DestinationPath = $targetVMPath
            DependsOn       = "[Disk]AksHciVolume"
        }

        #### STAGE 1b - SET WINDOWS DEFENDER EXCLUSION FOR VM STORAGE ####

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
            DependsOn  = "[File]VMfolder"
        }

        #### STAGE 1c - REGISTRY & SCHEDULED TASK TWEAKS ####

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
        
        Registry "Disable Server Manager WAC Prompt" {
            Key       = "HKLM:\SOFTWARE\Microsoft\ServerManager"
            Ensure    = 'Present'
            ValueName = "DoNotPopWACConsoleAtSMLaunch"
            ValueData = "1"
            ValueType = "Dword"
        }

        Registry "Disable Network Profile Prompt" {
            Key       = 'HKLM:\System\CurrentControlSet\Control\Network\NewNetworkWindowOff'
            Ensure    = 'Present'
            ValueName = ''
        }

        Registry "Set Network Private Profile Default" {
            Key       = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\CurrentVersion\NetworkList\Signatures\010103000F0000F0010000000F0000F0C967A3643C3AD745950DA7859209176EF5B87C875FA20DF21951640E807D7C24'
            Ensure    = 'Present'
            ValueName = "Category"
            ValueData = "1"
            ValueType = "Dword"
        }

        Registry "SetWorkgroupDomain" {
            Key       = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters"
            Ensure    = 'Present'
            ValueName = "Domain"
            ValueData = "akshci.local"
            ValueType = "String"
        }

        Registry "SetWorkgroupNVDomain" {
            Key       = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters"
            Ensure    = 'Present'
            ValueName = "NV Domain"
            ValueData = "akshci.local"
            ValueType = "String"
        }

        Registry "NewCredSSPKey" {
            Key       = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CredentialsDelegation\AllowFreshCredentialsWhenNTLMOnly'
            Ensure    = 'Present'
            ValueName = ''
        }

        Registry "NewCredSSPKey2" {
            Key       = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CredentialsDelegation'
            ValueName = 'AllowFreshCredentialsWhenNTLMOnly'
            ValueData = '1'
            ValueType = "Dword"
            DependsOn = "[Registry]NewCredSSPKey"
        }

        Registry "NewCredSSPKey3" {
            Key       = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CredentialsDelegation\AllowFreshCredentialsWhenNTLMOnly'
            ValueName = '1'
            ValueData = "*.$domainName"
            ValueType = "String"
            DependsOn = "[Registry]NewCredSSPKey2"
        }

        ScheduledTask "Disable Server Manager at Startup"
        {
            TaskName = 'ServerManager'
            Enable   = $false
            TaskPath = '\Microsoft\Windows\Server Manager'
        }

        #### STAGE 1d - CUSTOM FIREWALL BASED ON ARM TEMPLATE ####

        if ($customRdpPort -ne "3389") {

            Registry "Set Custom RDP Port" {
                Key       = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp'
                ValueName = "PortNumber"
                ValueData = "$customRdpPort"
                ValueType = 'Dword'
            }
        
            Firewall AddFirewallRule
            {
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

        #### STAGE 1e - ENABLE ROLES & FEATURES ####

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

        DnsServerAddress "DnsServerAddress for $InterfaceAlias"
        { 
            Address        = '127.0.0.1'
            InterfaceAlias = $InterfaceAlias
            AddressFamily  = 'IPv4'
            DependsOn      = "[WindowsFeature]DNS"
        }

        WindowsFeature "RSAT-Clustering" {
            Name   = "RSAT-Clustering"
            Ensure = "Present"
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

        Registry "DHCpConfigComplete" {
            Key       = 'HKLM:\SOFTWARE\Microsoft\ServerManager\Roles\12'
            ValueName = "ConfigurationState"
            ValueData = "2"
            ValueType = 'Dword'
            DependsOn = "[WindowsFeature]DHCPTools"
        }

        WindowsFeature "Hyper-V" {
            Name      = "Hyper-V"
            Ensure    = "Present"
            DependsOn = "[Registry]NewCredSSPKey3"
        }

        WindowsFeature "RSAT-Hyper-V-Tools" {
            Name      = "RSAT-Hyper-V-Tools"
            Ensure    = "Present"
            DependsOn = "[WindowsFeature]Hyper-V" 
        }

        #### STAGE 2a - HYPER-V vSWITCH CONFIG ####

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
            IPAddress      = '192.168.0.1/16'
            DependsOn      = "[xVMSwitch]$vSwitchNameHost"
        }

        NetIPInterface "Enable IP forwarding on vEthernet $vSwitchNameHost"
        {   
            AddressFamily  = 'IPv4'
            InterfaceAlias = "vEthernet `($vSwitchNameHost`)"
            Forwarding     = 'Enabled'
            DependsOn      = "[IPAddress]New IP for vEthernet $vSwitchNameHost"
        }

        NetAdapterRdma "EnableRDMAonvEthernet"
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

        #### STAGE 2b - PRIMARY NIC CONFIG ####

        NetConnectionProfile SetProfile
        {
            InterfaceAlias  = 'Ethernet'
            NetworkCategory = 'Private'
        }

        NetAdapterBinding DisableIPv6Host
        {
            InterfaceAlias = 'Ethernet'
            ComponentId    = 'ms_tcpip6'
            State          = 'Disabled'
            DependsOn      = "[NetConnectionProfile]SetProfile"
        }

        #### STAGE 2c - CONFIGURE InternaNAT NIC

        script NAT {
            GetScript  = {
                $nat = "AKSHCINAT"
                $result = if (Get-NetNat -Name $nat -ErrorAction SilentlyContinue) { $true } else { $false }
                return @{ 'Result' = $result }
            }
        
            SetScript  = {
                $nat = "AKSHCINAT"
                New-NetNat -Name $nat -InternalIPInterfaceAddressPrefix "192.168.0.0/16"          
            }
        
            TestScript = {
                # Create and invoke a scriptblock using the $GetScript automatic variable, which contains a string representation of the GetScript.
                $state = [scriptblock]::Create($GetScript).Invoke()
                return $state.Result
            }
            DependsOn  = "[IPAddress]New IP for vEthernet $vSwitchNameHost"
        }

        NetAdapterBinding DisableIPv6NAT
        {
            InterfaceAlias = "vEthernet `($vSwitchNameHost`)"
            ComponentId    = 'ms_tcpip6'
            State          = 'Disabled'
            DependsOn      = "[Script]NAT"
        }

        #### STAGE 2d - CONFIGURE DHCP SERVER

        xDhcpServerScope "AksHciDhcpScope" { 
            Ensure        = 'Present'
            IPStartRange  = '192.168.0.3'
            IPEndRange    = '192.168.0.149' 
            ScopeId       = '192.168.0.0'
            Name          = 'AKS-HCI Lab Range'
            SubnetMask    = '255.255.0.0'
            LeaseDuration = '01.00:00:00'
            State         = "$dhcpStatus"
            AddressFamily = 'IPv4'
            DependsOn     = @("[WindowsFeature]Install DHCPServer", "[IPAddress]New IP for vEthernet $vSwitchNameHost")
        }

        xDhcpServerOption "AksHciDhcpServerOption" { 
            Ensure             = 'Present' 
            ScopeID            = '192.168.0.0' 
            DnsDomain          = 'akshci.local'
            DnsServerIPAddress = '192.168.0.1'
            AddressFamily      = 'IPv4'
            Router             = '192.168.0.1'
            DependsOn          = "[xDhcpServerScope]AksHciDhcpScope"
        }

        #### STAGE 2e - CONFIGURE DNS SERVER

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

        <#
        xDnsServerSetting SetListener {
            Name            = 'AksHciListener'
            ListenAddresses = '192.168.0.1'
            Forwarders      = @('1.1.1.1', '1.0.0.1')
            DependsOn       = "[xDnsServerPrimaryZone]SetReverseLookupZone"
        }
        #>

        #### STAGE 2f - FINALIZE DHCP

        Script SetDHCPDNSSetting {
            SetScript  = { 
                Set-DhcpServerv4DnsSetting -DynamicUpdates "Always" -DeleteDnsRRonLeaseExpiry $True -UpdateDnsRRForOlderClients $True -DisableDnsPtrRRUpdate $false
                Write-Verbose -Verbose "Setting server level DNS dynamic update configuration settings"
            }
            GetScript  = { @{} 
            }
            TestScript = { $false }
            DependsOn  = "[xDnsServerPrimaryZone]SetReverseLookupZone"
        }

        #### STAGE 2g - CONFIGURE DNS CLIENT ON NICS

        <#
        DnsServerAddress "DnsServerAddress for HostNic"
        { 
            Address        = '192.168.0.1'
            InterfaceAlias = "Ethernet"
            AddressFamily  = 'IPv4'
            DependsOn      = @("[WindowsFeature]DNS", "[Script]NAT", "[xDnsServerSetting]SetListener")
        }

        DnsServerAddress "DnsServerAddress for NATNic"
        { 
            Address        = '192.168.0.1'
            InterfaceAlias = "vEthernet `($vSwitchNameHost`)"
            AddressFamily  = 'IPv4'
            DependsOn      = @("[WindowsFeature]DNS", "[IPAddress]New IP for vEthernet $vSwitchNameHost", "[xDnsServerSetting]SetListener")
        }
        #>

        DnsConnectionSuffix AddSpecificSuffixHostNic
        {
            InterfaceAlias           = 'Ethernet'
            ConnectionSpecificSuffix = 'akshci.local'
            DependsOn                = "[xDnsServerPrimaryZone]SetPrimaryDNSZone"
        }

        DnsConnectionSuffix AddSpecificSuffixNATNic
        {
            InterfaceAlias           = "vEthernet `($vSwitchNameHost`)"
            ConnectionSpecificSuffix = 'akshci.local'
            DependsOn                = "[xDnsServerPrimaryZone]SetPrimaryDNSZone"
        }

        #### STAGE 2h - CONFIGURE CREDSSP & WinRM

        xCredSSP Server {
            Ensure         = "Present"
            Role           = "Server"
            DependsOn      = "[DnsConnectionSuffix]AddSpecificSuffixNATNic"
            SuppressReboot = $true
        }
        xCredSSP Client {
            Ensure         = "Present"
            Role           = "Client"
            DelegateComputers = "$env:COMPUTERNAME" + ".$domainName"
            DependsOn      = "[xCredSSP]Server"
            SuppressReboot = $true
        }

        #### STAGE 3a - CONFIGURE WinRM

        Script ConfigureWinRM {
            SetScript  = {
                Set-Item WSMan:\localhost\Client\TrustedHosts "*.$domainName" -Force
            }
            TestScript = {
                (Get-Item WSMan:\localhost\Client\TrustedHosts).Value -contains "*.$domainName"
            }
            GetScript  = {
                @{Ensure = if ((Get-Item WSMan:\localhost\Client\TrustedHosts).Value -contains "*.$domainName") { 'Present' } Else { 'Absent' } }
            }
            DependsOn  = "[xCredSSP]Client"
        }

        #### STAGE 3b - INSTALL CHOCO & DEPLOY EDGE

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