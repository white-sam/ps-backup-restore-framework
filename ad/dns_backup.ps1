Import-Module "$PSScriptRoot\..\modules\backup_common.psm1" -Force
#requires -Modules DnsServer

$ErrorActionPreference = "Stop"


# Configuration
$config = Get-BackupConfig
$ExitCode = 0
$AD     = $config.ActiveDirectory
$GLOBAL = $config.Global
$BackupPath = Join-Path $AD.DnsBackupRoot $GLOBAL.TimeStamp
$BackupResults = @()

# Create Backup Folder
New-Item `
    -Path $BackupPath `
    -ItemType Directory `
    -Force | Out-Null

# Log Files
$LogFile = Join-Path $BackupPath "dns_backup.log"

# Setup and start transcript
$TranscriptFile = Join-Path $BackupPath "transcript.log"
Start-Transcript -Path $TranscriptFile -Force


# Backup DNS Servers
Write-Log "Starting DNS backup" INFO $LogFile
Write-Log "Domain: $($AD.Domain)" INFO $LogFile
Write-Log "Backup Path: $BackupPath" INFO $LogFile

foreach ($Server in $AD.DnsServers) {
    Write-Log "Backing up DNS server $Server" INFO $LogFile
    
    $Result = [PSCustomObject]@{
        Server   = $Server
        Success  = $true
        ExitCode = 0
        Error    = ""
    }

    try {
        $ServerPath =
        Join-Path $BackupPath $Server

        New-Item `
            -Path $ServerPath `
            -ItemType Directory `
            -Force | Out-Null

    # DNS Server Information
    Write-Log "Collecting DNS server information" INFO $LogFile

    Get-DnsServer `
        -ComputerName $Server |

    Export-Csv `
        (Join-Path $ServerPath "dns_server.csv") `
        -NoTypeInformation

    Get-DnsServerSetting `
        -ComputerName $Server `
        -All |

    Export-Csv `
        (Join-Path $ServerPath "dns_settings.csv") `
        -NoTypeInformation


    Get-DnsServerForwarder `
        -ComputerName $Server |

    Export-Csv `
        (Join-Path $ServerPath "forwarders.csv") `
        -NoTypeInformation

    Get-DnsServerRootHint `
        -ComputerName $Server |

    Export-Csv `
        (Join-Path $ServerPath "root_hints.csv") `
        -NoTypeInformation


    # Zones
    $Zones =
    Get-DnsServerZone `
        -ComputerName $Server

    $Zones |
        Select-Object `
        ZoneName,
        ZoneType,
        IsDsIntegrated,
        ReplicationScope,
        DynamicUpdate |
        Export-Csv `
        (Join-Path $ServerPath "zone_inventory.csv") `
        -NoTypeInformation


    foreach ($Zone in $Zones) {
        Write-Log "Processing zone $($Zone.ZoneName)" INFO $LogFile

        try {
            $SafeZone =
            $Zone.ZoneName -replace '[\\/:*?"<>|]','_'


            # Records

            $Records = @(
                Get-DnsServerResourceRecord `
                    -ComputerName $Server `
                    -ZoneName $Zone.ZoneName
                )

            if ($Records.Count -gt 0) {
                $Records |
                    Select-Object `
                    HostName,
                    RecordType,
                    Timestamp,
                    @{
                        Name="RecordData"
                        Expression={
                            $_.RecordData.ToString()
                        }
                    } |

                    Export-Csv `
                    (Join-Path `
                    $ServerPath `
                    "$SafeZone-records.csv") `
                    -NoTypeInformation

                Write-Log "Record export complete: $($Zone.ZoneName)" SUCCESS $LogFile
            }
            else {
                Write-Log "No records found: $($Zone.ZoneName)" WARN $LogFile
            }
        }
        catch {
            Write-Log "Zone failed $($Zone.ZoneName): $($_.Exception.Message)" ERROR $LogFile

            $Result.Success=$false
            $Result.ExitCode=1
            $Result.Error +=
            $_.Exception.Message
        }
    }

    # Manifest
    $Manifest = [PSCustomObject]@{
        Server=$Server
        BackupTime=
        (Get-Date)
        ZoneCount=
        $Zones.Count
    }

    $Manifest |
        Export-Csv `
        (Join-Path $ServerPath "manifest.csv") `
        -NoTypeInformation

    Write-Log "DNS server backup complete: $Server" SUCCESS $LogFile
}

catch {
    Write-Log "Server backup failed $Server : $($_.Exception.Message)" ERROR $LogFile

    $Result.Success=$false
    $Result.ExitCode=1
    $Result.Error=$_.Exception.Message
}

$BackupResults += $Result
}


# Summary
Write-Log "=================================================="  INFO $LogFile
Write-Log "DNS Backup Summary"  INFO $LogFile
Write-Log "=================================================="  INFO $LogFile


foreach ($Item in $BackupResults) {
    if ($Item.Success) {
        Write-Log "$($Item.Server.PadRight(35)) SUCCESS ExitCode=$($Item.ExitCode)" INFO $LogFile
    }
    else {
        Write-Log "$($Item.Server.PadRight(35)) FAILED ExitCode=$($Item.ExitCode)" ERROR $LogFile
    }
}



# Global Summary File

$BackupResults |
    Export-Csv `
    (Join-Path $BackupPath "backup_summary.csv") `
    -NoTypeInformation

# Backup Retention / Housekeeping
Invoke-Housekeeping `
    -Path $AD.DnsBackupRoot `
    -Keep $GLOBAL.RetentionDays



if ($BackupResults.Success -contains $false)
{
    Write-Log "DNS backup completed with errors" ERROR $LogFile
    Stop-Transcript
    exit 1
}
else {
    Write-Log "DNS backup completed successfully" SUCCESS $LogFile
    Stop-Transcript
    exit 0
}