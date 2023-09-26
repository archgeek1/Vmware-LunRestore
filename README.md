# Vmware-LunRestore

## Synopsis
Migrates all VMs running on a vsphere server to updated images located on a newly imported LUN

Stops ALL VMs and removes them from inventory. Looks for a new LUN and prompts user for selection.
Attaches the new LUN, reassigns signatures, imports ALL .vmx files to inventory, and starts new VMs
