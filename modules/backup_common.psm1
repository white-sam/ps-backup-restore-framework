# ============================================================================
# Backup/Restore Configuration and Shared Functions
# ============================================================================

# Set strict mode
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Script:Config = @{
    Global = @{
        Timestamp     = Get-Date -Format "yyyyMMdd-HHmmss"
        ScriptRoot    = "E:\Scripts\Backup-Restore"
        BackupRoot    = "E:\Backups"
        LogRoot       = "E:\Backups\Logs"
        RetentionDays = 31
        Computer      = $env:COMPUTERNAME
    }

    ActiveDirectory = @{
        Domain = "sodev-lab.local"
        SystemStateBackupRoot = "\\SODEV-CORE01\Backups\Active_Directory\System_State"
        GpoBackupRoot = "\\SODEV-CORE01\Backups\Active_Directory\Group_Policy"
        DhcpBackupRoot = "\\SODEV-CORE01\Backups\Active_Directory\Dhcp"
        DnsBackupRoot = "\\SODEV-CORE01\Backups\Active_Directory\Dns"
        SysStateBackupRoot = "\\SODEV-CORE01\Backups\Active_Directory\System_State"
        SysStateKeepVersions = 7
        BackupTimeoutHours = 5

        DomainControllers = @(
            "sodev-infra-dc1",
            "sodev-infra-dc2",
            "sodev-infra-dc3"
        )

        DhcpServers = @(
            "sodev-infra-dc1",
            "sodev-infra-dc3"
        )

        DnsServers = @(
            "sodev-infra-dc1",
            "sodev-infra-dc2",
            "sodev-infra-dc3"
        )

        ExcludedZones = @(
            "_msdcs.sodev-lab.local",
            "0.in-addr.arpa",
            "127.in-addr.arpa",
            "255.in-addr.arpa"
        )
    }

    FiberChannel = @{
        SshUser    = "admin"
        ScpHost    = "10.26.178.7"
        ScpUser    = "svc_vcbackup"
        FcBackupRoot = "E:\Backups\fibre_channel_switches"
        FcRemotePath = "backups/fibre_channel_switches"

        Switches = @(
            "fcsw-c2u41.buk.storage.hpecorp.net", # FA_BCK
            "fcsw-c3u41.buk.storage.hpecorp.net", # FA_BCK
            "fcsw-c2u42.buk.storage.hpecorp.net", # FB_BCK
            "fcsw-c3u42.buk.storage.hpecorp.net", # FB_BCK
            "fcsw-c4u42.buk.storage.hpecorp.net", # FB_BCK
            "fcsw-c5u42.buk.storage.hpecorp.net", # FB_BCK
            "fcsw-c6u42.buk.storage.hpecorp.net", # FB_BCK
            "fcsw-c7u42.buk.storage.hpecorp.net"  # FB_BCK
        )
    }
    Network = @{
        CredFile   = "E:\scripts\backup-restore\credentials\net_switches_admin_creds.xml"
        BackupRoot = "E:\Backups\Network_Switches"
        NetRemotePath = "backups/fibre_channel_switches"

        Switches = @(
            "10.26.177.27",    # IRF
            "10.26.177.14",    # IRF
            "10.26.144.120"    # IRF
        )
    }
    Vsphere = @{
        Vcenter    = "sodev-vc01.buk.storage.hpecorp.net"
        BackupRoot = "E:\backups\vsphere\esxi"
        CredFile   = "E:\scripts\backup-restore\credentials\sodev-vc01_creds.xml"

        DomainControllers = @(
            "sodev-infra-dc1",
            "sodev-infra-dc2",
            "sodev-infra-dc3"
        )

        DhcpServers = @(
            "sodev-infra-dc1",
            "sodev-infra-dc3"
        )
    }

}


# ============================================================================
# Get-BackupConfig
# ============================================================================
function Get-BackupConfig {
    return $Script:Config
}


# ============================================================================
# Write-Log
# ============================================================================
function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [ValidateSet('INFO','WARN','ERROR','SUCCESS')]
        [string]$Level = 'INFO',

        [string]$LogFile
    )

    $Time = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $Line = "[$Time] [$Level] $Message"

    Write-Host $Line

    if ($LogFile) {
        Add-Content -Path $LogFile -Value $Line
    }
}


# ============================================================================
# New-BackupFolder
# ============================================================================
function New-BackupFolder {
    param(
        [Parameter(Mandatory)]
        [string]$Root
    )

    $Folder = Join-Path $Root (Get-Date -Format "yyyy-MM-dd_HHmmss")

    if (!(Test-Path $Folder)) {
        New-Item -ItemType Directory -Path $Folder -Force | Out-Null
    }

    return $Folder
}


# ============================================================================
# Invoke-Housekeeping
# ============================================================================
function Invoke-Housekeeping {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [int]$Keep = 31,

        [string]$LogFile
    )

    if (!(Test-Path $Path)) {
        Write-Log "Housekeeping path does not exist: $Path" WARN $LogFile
        return
    }

    $Folders = Get-ChildItem $Path -Directory |
        Sort-Object CreationTime -Descending |
        Select-Object -Skip $Keep

    foreach ($Folder in $Folders)
    {
        Write-Log "Removing old backup folder: $($Folder.FullName)" INFO $LogFile

        Remove-Item `
            -Path $Folder.FullName `
            -Recurse `
            -Force
    }

    Write-Log "Housekeeping complete." INFO $LogFile
}


# ============================================================================
# Invoke-SystemStateMetadataHousekeeping
# ============================================================================
function Invoke-SystemStateMetadataHousekeeping
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [string]$MetadataRoot,

        [Parameter(Mandatory)]
        [string]$BackupTarget,

        [string]$LogFile
    )

    Write-Log "Synchronising System State metadata with wbadmin catalog" INFO $LogFile

    try
    {
        $Output = & wbadmin get versions "-backuptarget:$BackupTarget" 2>&1

        if ($LASTEXITCODE -ne 0)
        {
            throw "wbadmin get versions failed."
        }

        # Build a list of retained backup timestamps
        $ValidFolders = New-Object System.Collections.Generic.HashSet[string]

        foreach ($Line in $Output)
        {
            if ($Line -match '^Version identifier:\s*(.+)$')
            {
                try
                {
                    $Date = [datetime]::Parse($Matches[1])
                    $FolderName = $Date.ToString("yyyyMMdd-HHmmss")
                    $null = $ValidFolders.Add($FolderName)
                }
                catch
                {
                    Write-Log "Unable to parse version identifier '$($Matches[1])'" WARNING $LogFile
                }
            }
        }

        if ($ValidFolders.Count -eq 0)
        {
            Write-Log "No versions returned by wbadmin. Metadata cleanup skipped." WARNING $LogFile
            return
        }

        Get-ChildItem `
            -Path $MetadataRoot `
            -Directory |
        Where-Object {
            $_.Name -match '^\d{8}-\d{6}$'
        } |
        ForEach-Object {

            if (-not $ValidFolders.Contains($_.Name))
            {
                try
                {
                    Write-Log "Removing orphaned metadata folder $($_.Name)" INFO $LogFile

                    Remove-Item `
                        -Path $_.FullName `
                        -Recurse `
                        -Force

                    Write-Log "Removed $($_.Name)" SUCCESS $LogFile
                }
                catch
                {
                    Write-Log "Failed removing $($_.Name): $($_.Exception.Message)" ERROR $LogFile
                }
            }
        }
        Write-Log "Metadata synchronisation completed" SUCCESS $LogFile
    }
    catch
    {
        Write-Log "Metadata housekeeping failed: $($_.Exception.Message)" ERROR $LogFile
    }
}

# ============================================================================
# Start-WBAdminStatusMonitor
# ============================================================================

function Start-WBAdminStatusMonitor {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$LogFile,

        [int]$IntervalSeconds = 30
    )

    Start-Job -Name "WBAdminStatus" -ArgumentList $LogFile,$IntervalSeconds -ScriptBlock {

        param($LogFile,$Interval)

        while ($true)
        {
            try
            {
                $Status = wbadmin get status 2>&1

                if ($Status -notmatch "No backup or recovery operation")
                {
                    $Time = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

                    Add-Content $LogFile @"

[$Time] [STATUS]

$($Status -join "`r`n")

"@
                }
            }
            catch
            {
            }

            Start-Sleep $Interval
        }

    }

}


# ============================================================================
# Start-BackupEventMonitor
# ============================================================================

function Start-BackupEventMonitor {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$LogFile,

        [datetime]$StartTime = (Get-Date),

        [int]$IntervalSeconds = 5
    )

    Start-Job -Name "BackupEvents" `
        -ArgumentList $LogFile,$StartTime,$IntervalSeconds `
        -ScriptBlock {

        param($LogFile,$StartTime,$Interval)

        $LastRecord = 0

        while ($true)
        {
            try
            {
                $Events = Get-WinEvent -FilterHashtable @{
                    LogName   = "Microsoft-Windows-Backup/Operational"
                    StartTime = $StartTime
                } |
                Sort-Object RecordId

                foreach ($Event in $Events)
                {
                    if ($Event.RecordId -gt $LastRecord)
                    {
                        $Time = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                        Add-Content $LogFile @"

[$Time] [EVENT] ID=$($Event.Id)

$($Event.Message)
"@

                        $LastRecord = $Event.RecordId
                    }
                }
            }
            catch
            {
            }
            Start-Sleep $Interval
        }
    }
}


# ============================================================================
# Stop-BackupMonitor
# ============================================================================

function Stop-BackupMonitor {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.Job[]]$Jobs
    )

    foreach ($Job in $Jobs)
    {
        if ($null -eq $Job)
        {
            continue
        }

        try
        {
            if ($Job.State -eq 'Running')
            {
                Stop-Job $Job -Force
            }

            Receive-Job $Job -ErrorAction SilentlyContinue | Out-Null

            Remove-Job $Job -Force
        }
        catch
        {
        }
    }

}


# ============================================================================
# Wait-BackupProcess
# ============================================================================

function Wait-BackupProcess {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Diagnostics.Process]$Process,

        [int]$PollSeconds = 5
    )

    while (-not $Process.HasExited)
    {
        Start-Sleep $PollSeconds
        $Process.Refresh()
    }

    return $Process.ExitCode

}

function Write-BackupSummary
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [array]$Results,

        [Parameter(Mandatory)]
        [string]$LogFile,

        [Parameter(Mandatory)]
        [string]$NameProperty,

        [string]$Title = "Backup Summary"
    )

    Write-Log "==================================================" INFO $LogFile
    Write-Log $Title INFO $LogFile
    Write-Log "==================================================" INFO $LogFile

    foreach ($Result in $Results)
    {
        $Status = if ($Result.Success) { "SUCCESS" } else { "FAILED" }

        Write-Log (
            "{0,-50} {1,-8} ExitCode={2}" -f
            $Result.$NameProperty,
            $Status,
            $Result.ExitCode
        ) INFO $LogFile
    }

    if ($Results.Success -contains $false)
    {
        Write-Log "One or more items failed." ERROR $LogFile
        return 1
    }

    return 0
}

function Get-SecureCredential
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$CredentialFile
    )

    if (!(Test-Path $CredentialFile))
    {
        throw "Credential file not found: $CredentialFile"
    }

    try
    {
        return Import-Clixml $CredentialFile
    }
    catch
    {
        throw "Failed to import credential file '$CredentialFile': $($_.Exception.Message)"
    }
}

function Set-BackupEnvironment
{
    [CmdletBinding()]
    param()

    Set-StrictMode -Version Latest
    $script:ErrorActionPreference = 'Stop'
}

Export-ModuleMember -Function `
    Set-BackupEnvironment,
    Get-BackupConfig,
    Write-Log,
    New-BackupFolder,
    Invoke-Housekeeping,
    Start-WBAdminStatusMonitor,
    Start-BackupEventMonitor,
    Stop-BackupMonitor,
    Wait-BackupProcess,
    Write-BackupSummary,
    Get-SecureCredential,
    Invoke-SystemStateMetadataHousekeeping