# ============================================================================
# Master Backup Script
#     ESXi Host Configuration          esxi_backup.ps1
#     FC Switch Configuration          fc_switch_backup.ps1
#     Network Switch Configuration     net_switch_backup.ps1
#     AD GPO Configuration             gpo_backup.ps1
#     AD DHCP Configuration            dhcp_backup.ps1
#     AD DNS Configuration             dns_backup.ps1
#     AD System State                  system_state_backup_control.ps1
# ============================================================================

#Import-Module "$PSScriptRoot\modules\backup_common.psm1" -Force
Import-Module "$PSScriptRoot\modules\backup_common.psm1" -Force -ErrorAction Stop

# Configuration
$config = Get-BackupConfig
$GLOBAL = $config.Global

$Scripts = @(
    @{
        Name = "ESXi Backup"
        File = "vsphere\esxi_backup.ps1"
    },
    @{
        Name = "Fibre Channel Switch Backup"
        File = "fibre_channel\fc_switch_backup.ps1"
    },
    @{
        Name = "Network Switch Backup"
        File = "network\net_switch_backup.ps1"
    }
    @{
        Name = "Active Directory GPO Backup"
        File = "ad\gpo_backup.ps1"
    }
    @{
        Name = "Active Directory DHCP Backup"
        File = "ad\dhcp_backup.ps1"
    }
    @{
        Name = "Active Directory DNS Backup"
        File = "ad\dns_backup.ps1"
    }
    @{
        Name = "Active Directory System State Backup"
        File = "ad\system_state_backup_control.ps1"
    }
)


# Create log folder
if (!(Test-Path $config.Global.LogRoot)) {
    New-Item -ItemType Directory -Path $GLOBAL.LogRoot -Force | Out-Null
}

$LogFile = Join-Path $GLOBAL.LogRoot "MasterBackup-$($GLOBAL.Timestamp).log"


# Start logging
$Failures = 0

Write-Log "============================================================" INFO $LogFile
Write-Log "Infrastructure Backup Summary" INFO $LogFile
Write-Log "Started : $(Get-Date)" INFO $LogFile
Write-Log "============================================================" INFO $LogFile

foreach ($Job in $Scripts) {

    $ScriptPath = Join-Path $GLOBAL.ScriptRoot $Job.File

    Write-Log "Running $($Job.Name)..." INFO $LogFile

    $Start = Get-Date

    if (!(Test-Path $ScriptPath)) {

        Write-Log ("{0,-35} FAILED - Script not found" -f $Job.Name) ERROR $LogFile
        $Failures++
        continue
    }
    try {
        & $ScriptPath

        $ExitCode = $LASTEXITCODE
    }
    catch {
        $ExitCode = 999
    }

    $Duration = (Get-Date) - $Start

    if ($ExitCode -eq 0) {
        Write-Log ("{0,-35} SUCCESS   {1:hh\:mm\:ss}" -f $Job.Name,$Duration) INFO $LogFile
    }
    else {
        Write-Log ("{0,-35} FAILED ({1})   {1:hh\:mm\:ss}" -f $Job.Name,$ExitCode,$Duration) ERROR $LogFile
        $Failures++
    }
}

Write-Log "============================================================" INFO $LogFile
Write-Log "Completed : $(Get-Date)" INFO $LogFile

if ($Failures -eq 0) {
    Write-Log "Overall   : SUCCESS" INFO $LogFile
}
else {
    Write-Log "Overall   : FAILED ($Failures job(s) failed)" ERROR $LogFile
}

Write-Log "============================================================" INFO $LogFile

# Display summary
Get-Content $LogFile

# Exit code for Task Scheduler
if ($Failures -eq 0) {
    exit 0
}
else {
    exit 1
}