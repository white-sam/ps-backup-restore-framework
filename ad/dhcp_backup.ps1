# ============================================================================
# DHCP Server Backups
# ============================================================================

Import-Module "$PSScriptRoot\..\modules\backup_common.psm1" -Force
Import-Module DhcpServer -ErrorAction Stop


# Configuration
$config = Get-BackupConfig
$ExitCode = 0
$AD     = $config.ActiveDirectory
$GLOBAL = $config.Global

$BackupPath = Join-Path `
    $AD.DhcpBackupRoot `
    $GLOBAL.TimeStamp


# Create Backup Folder
New-Item `
    -ItemType Directory `
    -Force `
    -Path $BackupPath | Out-Null


# Log Files
$LogFile = Join-Path `
    $BackupPath `
    "dhcp_backup.log"


# Transcript
$TranscriptFile = Join-Path `
    $BackupPath `
    "transcript.log"

Start-Transcript `
    -Path $TranscriptFile `
    -Force

try {
    Write-Log "Starting DHCP backup" INFO $LogFile
    Write-Log "Domain: $($AD.Domain)" INFO $LogFile
    Write-Log "Backup Path: $BackupPath" INFO $LogFile
    Write-Log "DHCP Servers: $($AD.DhcpServers -join ', ')" INFO $LogFile

    $Results = @()

    foreach ($DHCPServer in $AD.DhcpServers) {
        Write-Log `
            "Starting DHCP backup for $DHCPServer" `
            INFO `
            $LogFile

        $ServerBackupPath = Join-Path `
            $BackupPath `
            $DHCPServer

        New-Item `
            -ItemType Directory `
            -Force `
            -Path $ServerBackupPath | Out-Null

        $Success = $true

        # Native DHCP Backup
        try {
            Write-Log `
                "Running local Backup-DhcpServer on $DHCPServer" `
                INFO `
                $LogFile

            $LocalBackupPath = "C:\Windows\Temp\DHCPBackup"

            Invoke-Command `
                -ComputerName $DHCPServer `
                -ScriptBlock {
                    param($Path)

                    if (Test-Path $Path) {
                        Remove-Item `
                            -Path $Path `
                            -Recurse `
                            -Force
                    }

                    New-Item `
                        -Path $Path `
                        -ItemType Directory `
                        -Force | Out-Null

                    Backup-DhcpServer `
                        -Path $Path `
                        -ErrorAction Stop
                } `
                -ArgumentList $LocalBackupPath

            Write-Log `
                "Local DHCP backup completed on $DHCPServer" `
                SUCCESS `
                $LogFile

            # Copy native backup to repository
            $NativeBackupPath = Join-Path `
                $ServerBackupPath `
                "NativeBackup"

            New-Item `
                -ItemType Directory `
                -Force `
                -Path $NativeBackupPath | Out-Null

            Write-Log `
                "Copying DHCP backup from $DHCPServer" `
                INFO `
                $LogFile

            robocopy `
                "\\$DHCPServer\C$\Windows\Temp\DHCPBackup" `
                $NativeBackupPath `
                /MIR `
                /R:3 `
                /W:5 `
                /NP `
                /NFL `
                /NDL

            if ($LASTEXITCODE -gt 7) {
                throw "Robocopy failed with exit code $LASTEXITCODE"
            }
            Write-Log `
                "Native DHCP backup copied successfully for $DHCPServer" `
                SUCCESS `
                $LogFile
        }
        catch {
            Write-Log `
                "Backup-DhcpServer FAILED for $DHCPServer - $($_.Exception.Message)" `
                ERROR `
                $LogFile

            $Success = $false
        }

        # XML Export
        try {
            Write-Log `
                "Running Export-DhcpServer for $DHCPServer" `
                INFO `
                $LogFile

            Export-DhcpServer `
                -ComputerName $DHCPServer `
                -File (Join-Path `
                    $ServerBackupPath `
                    "DHCP-$DHCPServer-$(Get-Date -Format yyyy-MM-dd).xml") `
                -Leases `
                -ErrorAction Stop

            Write-Log `
                "Export-DhcpServer completed successfully for $DHCPServer" `
                SUCCESS `
                $LogFile
        }
        catch {
            Write-Log `
                "Export-DhcpServer FAILED for $DHCPServer - $($_.Exception.Message)" `
                ERROR `
                $LogFile

            $Success = $false
        }

        # Add result
        $Results += [PSCustomObject]@{
            Server   = $DHCPServer
            Path     = $ServerBackupPath
            Success  = $Success
            ExitCode = if ($Success) {0} else {1}
        }
    }

    # DHCP Failover Configuration
    try {
        Write-Log `
            "Backing up DHCP failover configuration" `
            INFO `
            $LogFile

        $PrimaryDHCP = $AD.DhcpServers[0]

        Get-DhcpServerv4Failover `
            -ComputerName $PrimaryDHCP |
        Export-Clixml `
            -Path (Join-Path `
                $BackupPath `
                "DHCP-Failover-Configuration.xml")

        Write-Log `
            "DHCP failover configuration backup completed" `
            SUCCESS `
            $LogFile
    }
    catch {
        Write-Log `
            "DHCP failover configuration backup FAILED - $($_.Exception.Message)" `
            ERROR `
            $LogFile
    }

    # Create Backup Summary
    $ExitCode = Write-BackupSummary `
        -Results $Results `
        -LogFile $LogFile `
        -NameProperty Server `
        -Title "DHCP Backup Summary"

    # Backup Housekeeping
    Invoke-Housekeeping `
        -Path $AD.DhcpBackupRoot `
        -Keep $GLOBAL.RetentionDays `
        -Filter "*" `
        -LogFile $LogFile
}
catch {
    Write-Log `
        "SCRIPT FAILED - $($_.Exception.Message)" `
        ERROR `
        $LogFile

    $ExitCode = 1
}
finally {

    Stop-Transcript

    if ($ExitCode -eq 0) {
        Write-Log `
            "DHCP backup completed successfully" `
            SUCCESS `
            $LogFile
    }
    else {
        Write-Log `
            "DHCP backup completed with errors" `
            ERROR `
            $LogFile
    }
}

exit $ExitCode