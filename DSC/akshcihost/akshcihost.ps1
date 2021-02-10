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

        #### STAGE 1a - CREATE STORAGE SPACES V: & VM FOLDER ###

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
            DiskId           = $(Get-VirtualDisk -FriendlyName AksHciDisk).UniqueId
            DiskIdType       = 'UniqueId'
            RetryIntervalSec = $RetryIntervalSec
            RetryCount       = $RetryCount
            DependsOn        = '[Script]InitializeDisk'
        }

        Disk ADDSvolume {
            DiskId      = $(Get-VirtualDisk -FriendlyName AksHciDisk).UniqueId
            DiskIdType  = 'UniqueId'
            DriveLetter = $AdDrive
            Size        = 20GB
            FSFormat    = 'NTFS'
            DependsOn   = '[WaitForDisk]Disk1'
        }

        Disk AksHCIVolume {
            DiskId      = $(Get-VirtualDisk -FriendlyName AksHciDisk).UniqueId
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
    }
}