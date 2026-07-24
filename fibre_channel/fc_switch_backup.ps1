# ============================================================================
# Brocade Switch Configuration Backups
# ============================================================================

Import-Module "$PSScriptRoot\..\modules\backup_common.psm1" -Force

# Configuration
$config = Get-BackupConfig
$ExitCode = 0
$FC = $config.FiberChannel
$GLOBAL = $config.Global


# Create local log folder if it doesn't exist
$BackupPath = Join-Path $FC.FcBackupRoot $GLOBAL.Timestamp

# Create backup folder
New-Item -ItemType Directory -Force -Path $BackupPath | Out-Null

# Log files
$LogFile = Join-Path $BackupPath "BrocadeBackup-$($GLOBAL.Timestamp).log"

# Setup and start transcript
$TranscriptFile = Join-Path $BackupPath "transcript.log"
Start-Transcript -Path $TranscriptFile -Force

try 
{
    Write-Log "Starting Brocade configuration backup" INFO $LogFile
    Write-Log "Backup folder : $BackupPath" INFO $LogFile
    Write-Log "FC Switches   : $($FC.Switches.Count)" INFO $LogFile


    #------------------------------------------------------------------------------
    # Backup each switch
    #------------------------------------------------------------------------------
    $Results = foreach ($Switch in $FC.Switches)
    {
        Write-Log "[$Switch] Starting backup..." INFO $LogFile

        $RemoteFile = "$($FC.FcRemotePath)/$($GLOBAL.Timestamp)/$Switch-$($GLOBAL.Timestamp).txt"

        $Command = "configupload -all -P 22 -scp $($FC.ScpHost),$($FC.ScpUser),$RemoteFile"

        Write-Log "[$Switch] Uploading configuration to $RemoteFile" INFO $LogFile

        $Exit   = -1
        $Output = ""

        try
        {
            $Output = & ssh.exe "$($FC.SshUser)@$Switch" $Command 2>&1

            $Exit = $LASTEXITCODE
        }
        catch
        {
            $Output = $_.Exception.Message
            $Exit = -1
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

        if ($Output)
        {
            Write-Log "[$Switch] Output:" INFO $LogFile

            foreach ($Line in ($Output -split "`r?`n"))
            {
                if (![string]::IsNullOrWhiteSpace($Line))
                {
                    Write-Log "[$Switch] $Line" INFO $LogFile
                }
            }
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
        -Title "Fibre Switch Backup Summary"

    # Backup Housekeeping
    Invoke-Housekeeping `
        -Path $FC.FcBackupRoot `
        -Keep $GLOBAL.RetentionDays `
        -Filter "*" `
        -LogFile $LogFile

    if ($ExitCode -eq 0) {
        Write-Log "All switch backups completed successfully." SUCCESS $LogFile
    }
    else {
        Write-Log "Backup completed with errors." WARN $LogFile
    }
}
catch
{
    Write-Log $_.Exception.Message ERROR $LogFile
    Write-Log $_.ScriptStackTrace ERROR $LogFile
    $ExitCode = 1
}
finally
{
    Stop-Transcript
}

exit $ExitCode