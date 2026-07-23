# ============================================================================
# System State Backups
# ============================================================================

Import-Module "$PSScriptRoot\..\modules\backup_common.psm1" -Force
Import-Module ActiveDirectory -ErrorAction Stop


# Configuration
$config = Get-BackupConfig
$ExitCode = 0
$AD     = $config.ActiveDirectory
$GLOBAL = $config.Global

# File Name Prefix
$FilePrefix = "$($GLOBAL.Computer)_"

# Determine Backup Timestamp
$RunContextFile = Join-Path `
    $AD.SysStateBackupRoot `
    "CurrentRun.json"

if (Test-Path $RunContextFile)
{
    $RunContext = Get-Content `
        $RunContextFile |
        ConvertFrom-Json

    $Timestamp = $RunContext.Timestamp
}
else
{
    # Fallback if manually run
    $Timestamp = $GLOBAL.Timestamp
}

# Backup Path
$BackupPathTimestamp = Join-Path `
    (Join-Path `
        $AD.SysStateBackupRoot `
        $Timestamp) `
    $GLOBAL.Computer

$BackupPath = $AD.SysStateBackupRoot

# Create Backup Folder
New-Item `
    -ItemType Directory `
    -Force `
    -Path $BackupPath | Out-Null

# Create Backup Timestamp Folder
New-Item `
    -ItemType Directory `
    -Force `
    -Path $BackupPathTimestamp | Out-Null

# Log Files
$LogFile = Join-Path `
    $BackupPathTimestamp `
    "${FilePrefix}sys_state_backup.log"

$TranscriptFile = Join-Path `
    $BackupPathTimestamp `
    "${FilePrefix}transcript.log"

$StatusFile = Join-Path `
    $BackupPathTimestamp `
    "${FilePrefix}wbadmin-status.log"

Start-Transcript `
    -Path $TranscriptFile `
    -Force

try {
    Write-Log "Starting System State backup" INFO $LogFile
    Write-Log "Domain: $($AD.Domain)" INFO $LogFile
    Write-Log "Server: $($GLOBAL.Computer)" INFO $LogFile
    Write-Log "Backup Path: $BackupPath" INFO $LogFile

    # Check wbadmin
    if (-not (Get-Command wbadmin.exe -ErrorAction SilentlyContinue))
    {
        throw "wbadmin.exe not found. Windows Server Backup is not installed"
    }

    Write-Log "Windows Server Backup detected" SUCCESS $LogFile

    # Capture DC Information
    try {
        Write-Log "Capturing Domain Controller information" INFO $LogFile

        Get-ADDomainController |
        Export-Clixml `
            -Path (Join-Path `
                $BackupPathTimestamp `
                "${FilePrefix}DC-Info.xml")

        netdom query fsmo |
        Out-File `
            -FilePath (Join-Path `
                $BackupPathTimestamp `
                "${FilePrefix}FSMO-Roles.txt")

        Get-WindowsFeature |
        Where-Object Installed |
        Export-Clixml `
            -Path (Join-Path `
                $BackupPathTimestamp `
                "${FilePrefix}Installed-Roles.xml")

        Write-Log "DC information captured successfully" SUCCESS $LogFile
    }
    catch {
        Write-Log "Failed capturing DC information - $($_.Exception.Message)" ERROR $LogFile
    }

    # Start System State Backup
    Write-Log "Starting wbadmin system state backup" INFO $LogFile

    $Arguments = @(
        "start"
        "systemstatebackup"
        "-backuptarget:$BackupPath"
        "-quiet"
    )

    $Process = Start-Process `
        -FilePath "wbadmin.exe" `
        -ArgumentList $Arguments `
        -PassThru

    Write-Log "wbadmin started (PID $($Process.Id))" INFO $LogFile

    Start-Sleep `
        -Seconds 30

    # Start wbadmin status monitor
    Write-Log "Starting wbadmin status monitor" INFO $LogFile

    if (Test-Path $StatusFile)
    {
        Remove-Item `
            $StatusFile `
            -Force
    }

    $StatusProcess = Start-Process `
        -FilePath "cmd.exe" `
        -ArgumentList "/c wbadmin get status > `"$StatusFile`"" `
        -WindowStyle Hidden `
        -PassThru

    # Monitor backup
    while (-not $Process.HasExited)
    {
        Start-Sleep `
            -Seconds 30

        $Process.Refresh()
    }

    # Stop status monitor
    Stop-Process `
        -Id $StatusProcess.Id `
        -Force `
        -ErrorAction SilentlyContinue

    Write-Log "wbadmin completed with exit code $($Process.ExitCode)" INFO $LogFile

    if ($Process.ExitCode -ne 0)
    {
        throw "System State backup failed with exit code $($Process.ExitCode)"
    }

    # Result
    $Results = @()

    $Results += [PSCustomObject]@{
        Server   = $GLOBAL.Computer
        Path     = $BackupPath
        Success  = $true
        ExitCode = 0
    }

    $ExitCode = Write-BackupSummary `
        -Results $Results `
        -LogFile $LogFile `
        -NameProperty Server `
        -Title "System State Backup Summary"

    # Backup Housekeeping
    if ($Process.ExitCode -eq 0)
    {
        Write-Log "Running System State housekeeping" INFO $LogFile

        $Delete = Start-Process `
            -FilePath "wbadmin.exe" `
            -ArgumentList @(
                "delete"
                "backup"
                "-backupTarget:$BackupPath"
                "-keepVersions:$($AD.SysStateKeepVersions)"
                "-quiet"
            ) `
            -Wait `
            -PassThru

        if ($Delete.ExitCode -eq 0)
        {
            Write-Log "Housekeeping completed successfully" SUCCESS $LogFile
        }
        else
        {
            Write-Log "Housekeeping returned exit code $($Delete.ExitCode)" WARN $LogFile
        }

        # Always clean metadata
        Invoke-SystemStateMetadataHousekeeping `
            -MetadataRoot $AD.SysStateBackupRoot `
            -BackupTarget $BackupPath `
            -LogFile $LogFile
    }

}
catch {
    Write-Log "SCRIPT FAILED - $($_.Exception.Message)" ERROR $LogFile
    $ExitCode = 1
}
finally {
    Stop-Process `
        -Name wbadmin `
        -ErrorAction SilentlyContinue

    Stop-Transcript

    if ($ExitCode -eq 0)
    {
        Write-Log "System State backup completed successfully" SUCCESS $LogFile
    }
    else
    {
        Write-Log "System State backup completed with errors" ERROR $LogFile
    }
}

exit $ExitCode