<#
.SYNOPSIS VM specs migration to different Host/vCenter, and Veeam Disk Restore Automation
.NOTES  Author:  Jorge de la Cruz
.NOTES  Site:    www.jorgedelacruz.uk
#>

# System variables and connections
$ItisAlwaysSSL = Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false
$VCSAconnection = Connect-VIServer -Server YOURSOURCEVCSA -User administrator@vsphere.local -Password YOURPASS
$VBRconnection = Connect-VBRServer -Server YOURVBR -User DOMAIN\USER -Password YOURPASS

# Collect the name of the VM to migrate, and shutdown
$VMtoMove = Read-Host -Prompt 'Introduce the VM Name to Migrate to AVS'
Write-Progress -Activity 'Step 1' -Status 'Shutdown VM Guest' -PercentComplete 15
$PowerOff = Get-VM $VMtoMove | Shutdown-VMGuest -Confirm:$false

Write-Progress -Activity 'Step 2' -Status 'Migrating CPU/RAM/vNet Specs to AVS' -PercentComplete 25
$VMtoMoveProperties = Get-VM $VMtoMove | select-Object NumCpu, MemoryGB
$VMtoMoveMAC = Get-VM $VMtoMove | Get-NetworkAdapter | Select-Object MacAddress
$VMtoMoveMAC = $VMtoMoveMAC.MacAddress
Write-Progress -Activity 'Step 3' -Status 'Creating new AVS VM' -PercentComplete 40
$NewVM = New-VM -Name "NEW-$VMtoMove" -vmhost 'YOURTARGETESXI/VCENTER' -Datastore 'YOURTARGETDATASTOREFORNEWVM' -NumCpu $VMtoMoveProperties.NumCpu -MemoryGB $VMtoMoveProperties.MemoryGB -NetworkName 'YOURTARGETVMNETWORK' | Get-NetworkAdapter | Set-NetworkAdapter -Type Vmxnet3 -Confirm:$false

# MAC Address edit based on source VM / Should work to a new vCenter
Write-Progress -Activity 'Step 4' -Status 'Applying old MAC to the new AVS VM' -PercentComplete 50

# To double check with VMware please
$vm = Get-vm "NEW-$VMtoMove"
$nic = Get-NetworkAdapter -VM $vm
$spec = New-Object VMware.Vim.VirtualMachineConfigSpec

$oldSpec = New-Object VMware.Vim.VirtualDeviceConfigSpec
$oldSpec.Operation = 'remove'
$oldSpec.Device = $nic.ExtensionData
$spec.DeviceChange += $oldSpec

$devSpec = New-Object VMware.Vim.VirtualDeviceConfigSpec
$devSpec.Operation = 'add'
$devSpec.Device = New-Object VMware.Vim.VirtualVmxnet3
$devSpec.Device.Backing = $nic.ExtensionData.Backing
$devSpec.Device.AddressType = $nic.ExtensionData.AddressType
$devSpec.Device.MacAddress = "$VMtoMoveMAC"
$devSpec.Device.WakeOnLanEnabled = $nic.WakeOnLanEnabled
$devSpec.Device.UptCompatibilityEnabled = $false
$devSpec.Device.Key = -1
$devSpec.Device.DeviceInfo = $nic.ExtensionData.DeviceInfo
$devSpec.Device.Connectable = $nic.ExtensionData.Connectable
$devSpec.Device.ControllerKey = $nic.ExtensionData.ControllerKey
$devSpec.Device.UnitNumber = $nic.ExtensionData.UnitNumber
$spec.DeviceChange += $devSpec
$vm.ExtensionData.ReconfigVM($spec)

Write-Progress -Activity 'Step 5' -Status 'Injecting Drives from latest backup' -PercentComplete 75

# Let's prepare all the environment for a smooth Veeam injection
$backup = Get-VBRBackup -Name "VMware - Backup of Linux workloads (Immutable)"
$SourcevCenterorESXi = Get-VBRServer -name "YOURVCSA"
$restorepoint = Get-VBRRestorePoint -Name $VMtoMove -Backup $backup | Sort-Object -Property CreationTime -Descending | Select-Object -First 1

# Let's now build the whole VM Disk Restore, including target, disk mappings, etc.
$TargetvCenterESXi = Get-VBRServer -Name "YOURTARGETESXI"
$proxy = Get-VBRViProxy -Name "YOURTARGETVEEAMPROXY-MOSTLIKELYTHESAMEVBR"
$SourceDisks = Get-VBRViVirtualDevice -RestorePoint $restorepoint
$TargetDatastore=Find-VBRViDatastore -Server $TargetvCenterESXi -Name "YOURTARGETDATASTORE"
$mappingrule = New-VBRViVirtualDeviceMappingRule -SourceVirtualDevice $SourceDisks -Datastore $TargetDatastore
$newVM = Find-VBRViEntity -Name "NEW-$VMtoMove" -Server $SourcevCenterorESXi


# Where we are going we do not need roads
$VBRDiskRestore = Start-VBRViVirtualDiskRestore -RestorePoint $restorepoint -VirtualDeviceMapping $mappingrule -TargetVM $newVM -Proxy $proxy -PowerOn:$True

Write-Progress -Activity 'Finished' -Status 'All steps have been completed correctly' -PercentComplete 100

# Cleaning up just in case
Disconnect-VBRServer
Disconnect-VIServer