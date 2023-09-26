<# 
    .SYNOPSIS
    LUN restore script. Migrates virtual machines to latest version on imported LUN
    .DESCRIPTION
    Stops all VMs and removes them from inventory. Looks for a new LUN and prompts user for selection.
    Attaches the new LUN, reassigns signatures, imports ALL .vmx files to inventory, and starts new VMs

    .PARAMETER HostServer
    Specify ESXi host IP address. If not supplied, script will prompt you. 

    .PARAMETER DontResign
    Don't reassign signatures to new LUN. Only do this if VmWare won't detect new LUN as a snapshot.

#>


param (
    $HostServer = (Read-Host "Enter Host IP address"),
    [switch] $DontResign
)


Try {
    Connect-VIServer -Server $HostServer -ErrorAction Stop | Out-Null
    Write-Output "Connected to $HostServer"
}
Catch {
    throw "Cant connect to server $HostServer!"
}

Write-output "Refreshing storage"
Get-VMHostStorage -Refresh -RescanVmfs -RescanAllHba | Out-Null

Write-Output "Searching for new LUNs"
#this adds Scsi Target property to the $ScsiLunTarget object
$ScsiLunPath = get-scsilun | Get-ScsiLunPath
$ScsiLunTarget = @()
Get-ScsiLun | ForEach-Object -Process {
    $Lun = $_
    $Match = $ScsiLunPath | Where-Object ScsiCanonicalName -EQ $Lun.CanonicalName
    Add-Member -InputObject $Lun -NotePropertyName ScsiTarget -NotePropertyValue $Match.SanId
    $ScsiLunTarget += $Lun
}

$Datastore = Get-Datastore
#Filters Luns that are already datastores, and local ones without a scsi target. Then adds an index number to the object
$ScsiLunSelection = @()
$ScsiLunTarget | Where-Object CanonicalName -NotIn $datastore.extensiondata.info.vmfs.extent.diskname |  Where-Object ScsiTarget -NotLike $null |
    ForEach-Object -Begin {$i=0} -Process {
        $Lun = $_
        $i++
        Add-Member -InputObject $Lun -NotePropertyName Index -NotePropertyValue $i
        $ScsiLunSelection += $Lun
    }

Write-Output $ScsiLunSelection |Select-Object Index, CapacityGB, ScsiTarget | Format-Table

$NewLun = Read-Host "Enter Index of New Lun"

$NewLun = $ScsiLunSelection | Where-Object Index -EQ $NewLun
$NewDatastoreName = (Read-Host "Enter name for new datastore")

$VMs = Get-VM
$OnVMs = $VMs | Where-Object PowerState -NE PoweredOff
$VMDatastore = get-datastore -Id $VMs.DatastoreIdList
$VMHost = Get-VMHost "$HostServer"

if ($OnVMs) {
Write-Output "
    Stopping VMs"
    Try {
        Stop-VM -Confirm:$false -VM $OnVMs -ErrorAction Stop
    }
    Catch {
        throw "Error stopping VMs"
    }
}

Write-Output "
Removing from Inventory"
try {
    Remove-VM -Confirm:$false -VM $VMs -ErrorAction Stop
}
Catch {
    throw "Error removing VMs"
}


Write-Output "Unmounting datastore"
try {
    $canonicalname = (Get-scsilun -Datastore $VMDatastore).CanonicalName
    $storSys = Get-View $VMHost.Extensiondata.ConfigManager.StorageSystem
    $device = $storsys.StorageDeviceInfo.ScsiLun | where {$_.CanonicalName -eq $canonicalName}

    if($device.OperationalState -eq 'ok'){
        $StorSys.UnmountVmfsVolume($VMDatastore.ExtensionData.Info.Vmfs.Uuid)
    }
}
Catch {
    throw "Error Unmounting Datastore"
}

Write-output "Attaching new datastore"
if ($DontResign) {
    Try {
    New-Datastore -VMHost $VMHost -Name $NewDatastoreName -path $NewLun.CanonicalName -ErrorAction Stop | Out-Null
    }
    Catch {
        throw "Error attaching datastore"
    }
}

#reassigns signatures to if the volume is detected as a snapshot
#makes sure resignatured datastore is the same as $newlun

if (-not $DontResign) {

    $EsxCli = Get-EsxCli -VMHost $VMHost
    $Volume = ($EsxCli.storage.vmfs.snapshot.list()).VolumeName #this is the one detected as a snapshot
    if ($NewLun.CanonicalName -eq $EsxCli.storage.vmfs.snapshot.extent.list().devicename) {
        $EsxCli.storage.vmfs.snapshot.resignature($Volume)
        Get-VMHostStorage -Refresh -RescanVmfs -RescanAllHba | Out-Null #rescan storage
        Start-Sleep -Seconds 2
		
        $NewAttachedDatastore = Get-Datastore | Where-Object {$_.extensiondata.info.vmfs.extent.diskname -eq $NewLun.CanonicalName}
        Set-Datastore -Datastore $NewAttachedDatastore -Name $NewDatastoreName
    }
}

Write-Output "Adding VMs to inventory"
try {
    $VMXs = Get-ChildItem -Path vmstore:\ha-datacenter\$NewDatastoreName -Recurse -Filter *.vmx
    foreach ($VMX in $VMXs){
        New-vm -VMFilePath $VMX.datastorefullpath
    }
}
Catch {
    throw "Error adding VMs to inventory"
}

Write-Output "Starting VMs"
try {
    Get-VM | Start-VM -ErrorAction Stop
}
Catch {
    Start-Sleep -Seconds 5
    Write-Output "Answering I Moved It"
    Get-VMQuestion | Set-VMQuestion -Option "button.uuid.movedTheVM" -Confirm:$false
}

Disconnect-VIServer -Confirm:$false
Write-Output "Done"
