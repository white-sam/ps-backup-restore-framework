# ============================================================================
# FlexFabric Network Switch Configuration Backups
# ============================================================================

Import-Module Posh-SSH -ErrorAction Stop
Import-Module "$PSScriptRoot\..\modules\backup_common.psm1" -Force

# Configuration
$config = Get-BackupConfig
$ExitCode = 0
$NET = $config.Network
$GLOBAL = $config.Global
$BackupPath = Join-Path $NET.BackupRoot $GLOBAL.TimeStamp


# Run once to create the secure credentials
#
# $Cred = Get-Credential
# $Cred | Export-Clixml "E:\scripts\backup-restore\credentials\net_switches_admin_creds.xml"

# Create backup folder
New-Item -ItemType Directory -Force -Path $BackupPath | Out-Null

# Log files
$LogFile = Join-Path $BackupPath "net_swtich_backup.log"

# Setup and start transcript
$TranscriptFile = Join-Path $BackupPath "transcript.log"
Start-Transcript -Path $TranscriptFile -Force

try {
    # Import credentials
    $Cred = Get-SecureCredential -CredentialFile $NET.CredFile

    Write-Log "Starting network switch configuration backups" INFO $LogFile

    $Results = foreach ($Switch in $NET.Switches)
    {
        Write-Log "Connecting to $Switch" INFO $LogFile

        try
        {
            $Session = New-SFTPSession `
            -ComputerName $Switch `
            -Credential $Cred `
            -AcceptKey

            Write-Log "Connected successfully" INFO $LogFile

            Get-SFTPItem `
               -SessionId $Session.SessionId `
               -Path "startup.cfg" `
               -Destination $BackupPath

            $Exit = $LASTEXITCODE

            Rename-Item `
                -Path "$BackupPath/startup.cfg" `
                -NewName "$Switch.cfg"

            Write-Log "Backup successful for switch $Switch" INFO $LogFile
        }
        catch
        {
            $Output = $_.Exception.Message
            $Exit = -1
        }
        finally
        {
            Write-Log "Disconnecting from Switch $Switch" INFO $LogFile

            Remove-SFTPSession -SessionId $Session.SessionId | Out-Null
        }

        $Success = ($Exit -eq 0)

        if ($Success)
        {
            Write-Log "[$Switch] Backup completed successfully." SUCCESS $LogFile
        }
        else
        {
            Write-Log "[$Switch] Backup FAILED (ExitCode $Exit)." ERROR $LogFile
        }

        [PSCustomObject]@{
            Switch   = $Switch
            Success  = $Success
            ExitCode = $Exit
        }
    }

    # Create Backup Summary
    $ExitCode = Write-BackupSummary `
        -Results $Results `
        -LogFile $LogFile `
        -NameProperty Switch `
        -Title "Network Switch Backup Summary"

    # Backup Housekeeping
    Invoke-Housekeeping `
        -Path $NET.BackupRoot `
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
    Write-Log "Backup completed" SUCCESS $LogFile
    $ExitCode = 0
}

exit $ExitCode