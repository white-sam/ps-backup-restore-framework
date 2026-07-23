# ============================================================================
# System State Backup Controller
# ============================================================================

Import-Module "$PSScriptRoot\..\modules\backup_common.psm1" -Force

# Configuration
$config = Get-BackupConfig
$ExitCode = 0
$AD     = $config.ActiveDirectory
$GLOBAL = $config.Global

# Paths
$BackupPath = Join-Path `
    $AD.SysStateBackupRoot `
    $GLOBAL.Timestamp

# Create Backup Folder
New-Item `
    -ItemType Directory `
    -Force `
    -Path $BackupPath | Out-Null

$LogFile = Join-Path `
    $BackupPath `
    "sys_state_controller.log"

# Run Context
$RunContext = @{
    Timestamp = $GLOBAL.Timestamp
    StartedBy = "$env:USERDOMAIN\$env:USERNAME"
}

$RunContextFile = Join-Path `
    $AD.SysStateBackupRoot `
    "CurrentRun.json"

$RunContext |
    ConvertTo-Json |
    Set-Content `
        -Path $RunContextFile `
        -Force

# Transcript
$TranscriptFile = Join-Path `
    $BackupPath `
    "transcript.log"

$TranscriptStarted = $false

try {
    Start-Transcript `
        -Path $TranscriptFile `
        -Force `
        -ErrorAction Stop

    $TranscriptStarted = $true
}
catch {
    Write-Host "WARN: Unable to start transcript - $($_.Exception.Message)"
}

try {
    Write-Log "Starting System State Backup Controller" INFO $LogFile
    Write-Log "Domain Controllers: $($AD.DomainControllers -join ', ')" INFO $LogFile
    Write-Log "Backup timeout: $($AD.BackupTimeoutHours) hours" INFO $LogFile

    $Jobs = @()
    $Results = @()

    foreach ($DC in $AD.DomainControllers)
    {
        Write-Log "Starting backup task on $DC" INFO $LogFile

        try {
            $Jobs += Invoke-Command `
                -ComputerName $DC `
                -ScriptBlock {
                    param(
                        $BackupTimeoutHours
                    )

                    try {
                        $TaskName = "SODEV-SystemStateBackup"

                        # Start task
                        Start-ScheduledTask `
                            -TaskName $TaskName `
                            -ErrorAction Stop

                        $StartTime = Get-Date

                        # Wait for task to enter running state
                        $StartTimeout = (Get-Date).AddMinutes(5)
                        do {
                            Start-Sleep -Seconds 5

                            $Task = Get-ScheduledTask `
                                -TaskName $TaskName

                            if ((Get-Date) -gt $StartTimeout)
                            {
                                throw "Scheduled task failed to enter Running state within 5 minutes"
                            }
                        }
                        while (
                            $Task.State -ne "Running"
                        )

                        # Monitor
                        while ($Task.State -eq "Running")
                        {
                            # Pause for backup job to start
                            Start-Sleep -Seconds 30
                            $Elapsed = (Get-Date) - $StartTime

                            if ($Elapsed.TotalHours -ge $BackupTimeoutHours)
                            {
                                Stop-ScheduledTask `
                                    -TaskName $TaskName `
                                    -ErrorAction SilentlyContinue

                                throw "Backup exceeded timeout of $BackupTimeoutHours hours"
                            }
                            $Task = Get-ScheduledTask `
                                -TaskName $TaskName
                        }

                        # Get final result
                        $TaskInfo = Get-ScheduledTaskInfo `
                            -TaskName $TaskName

                        if ($TaskInfo.LastTaskResult -eq 0)
                        {
                            [PSCustomObject]@{
                                Server         = $env:COMPUTERNAME
                                Success        = $true
                                Message        = "Backup completed successfully"
                                ExitCode       = 0
                                Duration       = ((Get-Date)-$StartTime)
                                LastTaskResult = $TaskInfo.LastTaskResult
                            }
                        }
                        else
                        {
                            [PSCustomObject]@{
                                Server         = $env:COMPUTERNAME
                                Success        = $false
                                Message        = "Backup failed. Task result $($TaskInfo.LastTaskResult)"
                                ExitCode       = $TaskInfo.LastTaskResult
                                Duration       = ((Get-Date)-$StartTime)
                                LastTaskResult = $TaskInfo.LastTaskResult
                            }
                        }
                    }
                    catch {
                        [PSCustomObject]@{
                            Server         = $env:COMPUTERNAME
                            Success        = $false
                            Message        = $_.Exception.Message
                            ExitCode       = 1
                            LastTaskResult = $null
                        }
                    }
                } `
                -ArgumentList @(
                    $AD.BackupTimeoutHours
                ) `
                -AsJob `
                -ErrorAction Stop
        }
        catch {
            Write-Log "$DC : Failed to start remote job - $($_.Exception.Message)" ERROR $LogFile

            $Results += [PSCustomObject]@{
                Server  = $DC
                Success = $false
                Message = $_.Exception.Message
                ExitCode = 1
            }
            $ExitCode = 1
        }
    }

    Write-Log "$($Jobs.Count) backup jobs launched" INFO $LogFile

    # Collect results
    foreach ($Job in $Jobs)
    {
        try {
            $Result = $Job |
                Wait-Job |
                Receive-Job

            $Results += $Result
        }
        catch {
            $Results += [PSCustomObject]@{
                Server  = "Unknown"
                Success = $false
                Message = $_.Exception.Message
                ExitCode = 1
            }
            $ExitCode = 1
        }
        finally {
            Remove-Job `
                $Job `
                -Force `
                -ErrorAction SilentlyContinue
        }
    }

    # Process results
    foreach ($Result in $Results)
    {
        if ($Result.Success)
        {
            Write-Log "$($Result.Server): $($Result.Message) Duration=$($Result.Duration)" SUCCESS $LogFile
        }
        else
        {
            Write-Log "$($Result.Server): $($Result.Message)" ERROR $LogFile

            $ExitCode = 1
        }
    }

    $ExitCode = Write-BackupSummary `
        -Results $Results `
        -LogFile $LogFile `
        -NameProperty Server `
        -Title "System State Backup Controller Summary"
}
catch {
    Write-Log "SCRIPT FAILED - $($_.Exception.Message)" ERROR $LogFile

    $ExitCode = 1
}
finally {
    if ($ExitCode -eq 0)
    {
        Write-Log "System State backup controller completed successfully" SUCCESS $LogFile
    }
    else
    {

        Write-Log "System State backup controller completed with errors" ERROR $LogFile
    }


    if (Test-Path $RunContextFile)
    {
        Remove-Item `
            $RunContextFile `
            -Force `
            -ErrorAction SilentlyContinue
    }

    if ($TranscriptStarted)
    {
        Stop-Transcript `
            -ErrorAction SilentlyContinue
    }
}

exit $ExitCode