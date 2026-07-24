# ============================================================================
# Active Directory Group Policy Object Backups
# ============================================================================

Import-Module "$PSScriptRoot\..\modules\backup_common.psm1" -Force
Import-Module GroupPolicy -ErrorAction Stop


# Configuration
$config = Get-BackupConfig

$ExitCode = 0

$AD     = $config.ActiveDirectory
$GLOBAL = $config.Global

$BackupPath = Join-Path `
    $AD.GPOBackupRoot `
    $GLOBAL.TimeStamp


# Create Backup Folder
New-Item `
    -ItemType Directory `
    -Force `
    -Path $BackupPath | Out-Null


# Log Files
$LogFile = Join-Path `
    $BackupPath `
    "gpo_backup.log"


# Setup and start transcript
$TranscriptFile = Join-Path `
    $BackupPath `
    "transcript.log"

Start-Transcript `
    -Path $TranscriptFile `
    -Force


try {
    Write-Log "Starting Group Policy backup" INFO $LogFile

    Write-Log "Domain: $($AD.Domain)" INFO $LogFile

    Write-Log "Backup Path: $BackupPath" INFO $LogFile


    # Create GPO Inventory
    try {
        Write-Log "Creating GPO inventory" INFO $LogFile

        Get-GPO `
            -All `
            -Domain $AD.Domain |
        Select-Object `
            DisplayName,
            Id,
            GpoStatus,
            CreationTime,
            ModificationTime |
        Export-Csv `
            -Path "$BackupPath\GPO-Inventory.csv" `
            -NoTypeInformation

        Write-Log "GPO inventory created successfully" SUCCESS $LogFile
    }
    catch {
        Write-Log "Failed to create GPO inventory - $($_.Exception.Message)" ERROR $LogFile
    }


    # Backup GPOs
    try {
        Write-Log "Starting Backup-GPO operation" INFO $LogFile

        Backup-GPO `
            -Domain $AD.Domain `
            -All `
            -Path $BackupPath `
            -ErrorAction Stop

        Write-Log "GPO backup completed successfully" SUCCESS $LogFile

        $Success = $true
        $Exit    = 0
    }
    catch {
        Write-Log "GPO backup FAILED - $($_.Exception.Message)" ERROR $LogFile

        $Success = $false
        $Exit    = 1
    }


    # Backup Summary
    $Results = @(
        [PSCustomObject]@{
            Domain   = $AD.Domain
            Path     = $BackupPath
            Success  = $Success
            ExitCode = $Exit
        }
    )

    $ExitCode = Write-BackupSummary `
        -Results $Results `
        -LogFile $LogFile `
        -NameProperty Domain `
        -Title "Group Policy Backup Summary"

    # Backup Housekeeping
    Invoke-Housekeeping `
        -Path $AD.GPOBackupRoot `
        -Keep $GLOBAL.RetentionDays `
        -Filter "*" `
        -LogFile $LogFile
}
catch {
    Write-Log "SCRIPT FAILED - $($_.Exception.Message)" ERROR $LogFile

    $ExitCode = 1
}
finally {
    Stop-Transcript

    if ($ExitCode -eq 0) {
        Write-Log "Group Policy backup completed successfully" SUCCESS $LogFile
    }
    else {
        Write-Log "Group Policy backup completed with errors" ERROR $LogFile
    }
}

exit $ExitCode