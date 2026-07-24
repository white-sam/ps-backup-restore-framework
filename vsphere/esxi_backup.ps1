# ============================================================================
# ESXi Host Configuration Backups
# ============================================================================

Import-Module "$PSScriptRoot\..\modules\backup_common.psm1" -Force

# Run once to create the secure credentials
#
# $Cred = Get-Credential
# $Cred | Export-Clixml "E:\scripts\credentials\sodev-vc01_creds.xml"

# Ignore self-signed vCenter certificates
Set-PowerCLIConfiguration `
    -InvalidCertificateAction Ignore `
    -Scope Session `
    -Confirm:$false | Out-Null


# Configuration
$config = Get-BackupConfig
$ExitCode = 0
$VC = $config.Vsphere
$GLOBAL = $config.Global
$BackupPath = Join-Path $VC.BackupRoot $GLOBAL.TimeStamp


# Create backup folder
New-Item -ItemType Directory -Force -Path $BackupPath | Out-Null

# Log files
$LogFile = Join-Path $BackupPath "esxi_backup.log"

# Setup and start transcript
$TranscriptFile = Join-Path $BackupPath "transcript.log"
Start-Transcript -Path $TranscriptFile -Force

try {
    Write-Log "Starting ESXi configuration backup" INFO $LogFile

    # Import credentials
    $Cred = Get-SecureCredential -CredentialFile $VC.CredFile

    Write-Log "Connecting to vCenter $($VC.Vcenter)" INFO $LogFile

    Connect-VIServer `
        -Server $VC.Vcenter `
        -Credential $Cred `
        -ErrorAction Stop | Out-Null

    Write-Log "Connected successfully" SUCCESS $LogFile


    # Backup each ESXi host
    Get-VMHost | ForEach-Object {

        $HostName = $_.Name

        Write-Log "Backing up $HostName" INFO $LogFile

        try {

            Get-VMHostFirmware `
                -VMHost $_ `
                -BackupConfiguration `
                -DestinationPath $BackupPath `
                -ErrorAction Stop | Out-Null

            Write-Log "Backup successful for $HostName" SUCCESS $LogFile

        }
        catch {

            Write-Log "Backup FAILED for $HostName - $($_.Exception.Message)" ERROR $LogFile

        }
    }

    # Export host inventory
    Write-Log "Exporting host inventory" INFO $LogFile

    Get-VMHost |
    Select-Object `
        Name,
        Version,
        Build,
        Manufacturer,
        Model,
        ConnectionState |
    Export-Csv `
        -Path "$BackupPath\ESXiHosts.csv" `
        -NoTypeInformation

    Write-Log "Inventory export complete" INFO $LogFile

    # Backup Housekeeping
    Invoke-Housekeeping `
        -Path $VC.BackupRoot `
        -Keep $GLOBAL.RetentionDays `
        -Filter "*" `
        -LogFile $LogFile
}
catch {
    Write-Log "SCRIPT FAILED - $($_.Exception.Message)" ERROR $LogFile
    $ExitCode = 1
}
finally {
    Write-Log "Disconnecting from vCenter" INFO $LogFile

    Disconnect-VIServer * `
        -Confirm:$false `
        -ErrorAction SilentlyContinue

    Stop-Transcript
    Write-Log "Backup completed" INFO $LogFile
    $ExitCode = 0
}

exit $ExitCode