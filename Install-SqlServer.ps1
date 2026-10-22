#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
Download and install SQL Server 2025 Express, then configure its TCP port and firewall.
.EXAMPLE
.\Install-SqlServer.ps1 -MediaPath E:\ -AcceptLicenseTerms -CheckOnly
.EXAMPLE
.\Install-SqlServer.ps1 -MediaPath E:\ -AcceptLicenseTerms
#>
[CmdletBinding()]
param(
    [string]$MediaPath,
    [string]$DownloadDirectory = "$env:ProgramData\SqlServer2025ExpressMedia",
    [uri]$DownloadUrl = 'https://download.microsoft.com/download/7ab8f535-7eb8-4b16-82eb-eca0fa2d38f3/SQL2025-SSEI-Expr.exe',
    [ValidatePattern('^[A-Za-z][A-Za-z0-9_]{0,15}$')][string]$InstanceName = 'MSSQLSERVER',
    [ValidateRange(512,2147483647)][int]$MaxServerMemoryMB = 4096,
    [switch]$EnforceSaPasswordPolicy,
    [string[]]$SqlSysAdminAccounts = @([Security.Principal.WindowsIdentity]::GetCurrent().Name),
    [string]$LogDirectory = "$env:ProgramData\SqlServerInstallLogs",
    [string[]]$RemoteAddress = @('Any'),
    [switch]$ConfigureOnly,
    [switch]$AcceptLicenseTerms,
    [switch]$CheckOnly
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Network policy: never use any of these TCP ports for this SQL instance.
$BlockedPorts = @(
    135,136,137,138,139,445,593,
    1024,1025,1026,1027,1028,1029,1030,1080,1214,
    1363,1364,1368,1373,1377,1433,2222,2283,2535,2745,
    3127,3128,3333,3410,4444,5554,8866,9898,10000,10080,
    12345,14444,17300,22222,27374,33333
)

function Quote-SetupValue([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value -match '["\r\n]') {
        throw 'Setup values must not be empty or contain quotes/newlines.'
    }
    return '"' + $Value + '"'
}

function Write-Stage([string]$Message) {
    Write-Host ('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Message) -ForegroundColor Cyan
}

function Invoke-TrackedProcess {
    param([string]$FilePath, [string]$ArgumentLine, [string]$Activity, [string]$WatchDirectory)
    Write-Stage "$Activity - starting (elapsed time is not a completion percentage)."
    # Keep Start-Process -Wait semantics, including descendant processes.
    $job = Start-Job -ArgumentList $FilePath,$ArgumentLine -ScriptBlock {
        param($file, $arguments)
        $ErrorActionPreference = 'Stop'
        $p = Start-Process -FilePath $file -ArgumentList $arguments -WindowStyle Hidden -Wait -PassThru
        $p.ExitCode
    }
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $lastReport = -10
    try {
        while ($job.State -in @('NotStarted','Running')) {
            $seconds = [int]$watch.Elapsed.TotalSeconds
            if ($seconds - $lastReport -ge 10) {
                $status = "Running; elapsed $seconds seconds"
                if ($WatchDirectory -and (Test-Path -LiteralPath $WatchDirectory)) {
                    $files = @(Get-ChildItem -LiteralPath $WatchDirectory -File -Recurse -ErrorAction SilentlyContinue)
                    $bytes = 0
                    if ($files.Count -gt 0) { $bytes = ($files | Measure-Object -Property Length -Sum).Sum }
                    $status += ('; observed folder size {0:N1} MB (not total download progress)' -f ($bytes / 1MB))
                    $latest = $files | Sort-Object LastWriteTime -Descending | Select-Object -First 1
                    if ($null -ne $latest) { $status += "; latest file update $($latest.LastWriteTime.ToString('HH:mm:ss'))" }
                }
                Write-Stage "$Activity : $status"
                Write-Progress -Id 10 -Activity $Activity -Status $status -PercentComplete -1
                $lastReport = $seconds
            }
            $null = Wait-Job -Job $job -Timeout 1
        }
        $output = @(Receive-Job -Job $job -ErrorAction Stop)
        if ($job.State -ne 'Completed' -or $output.Count -ne 1) {
            throw "$Activity process monitoring failed. Check running setup processes and logs before retrying."
        }
        $code = [int]$output[0]
        Write-Stage "$Activity finished; exit code $code; elapsed $([int]$watch.Elapsed.TotalSeconds) seconds."
        return $code
    } finally {
        Write-Progress -Id 10 -Activity $Activity -Completed
        if ($job.State -in @('Completed','Failed','Stopped')) { Remove-Job -Job $job }
    }
}

function Read-SaPassword {
    while ($true) {
        Write-Stage '[1/7] INPUT REQUIRED: enter a new sa password below, then press Enter. Input is hidden.'
        $first = Read-Host 'Set sa password (12-128 characters; at least 3 of uppercase/lowercase/digits/symbols)' -AsSecureString
        Write-Stage 'INPUT REQUIRED: enter the same password again, then press Enter.'
        $second = Read-Host 'Confirm sa password' -AsSecureString
        $a = $null
        $b = $null
        try {
            $a = ([PSCredential]::new('sa', $first)).GetNetworkCredential().Password
            $b = ([PSCredential]::new('sa', $second)).GetNetworkCredential().Password
            $groups = 0
            foreach ($pattern in @('[A-Z]','[a-z]','[0-9]','[^A-Za-z0-9]')) {
                if ($a -cmatch $pattern) { $groups++ }
            }
            if ($a -cne $b) { Write-Warning 'Passwords do not match. Try again.' }
            elseif ($a.Length -lt 12 -or $a.Length -gt 128 -or $groups -lt 3) { Write-Warning 'Password does not meet the requirements. Try again.' }
            else { $first.MakeReadOnly(); return $first }
            $first.Dispose()
        } finally { $a = $null; $b = $null; $second.Dispose() }
    }
}

function Enable-SaLogin([Security.SecureString]$Password) {
    $source = 'lpc:.'
    if ($InstanceName -ine 'MSSQLSERVER') { $source = 'lpc:.\' + $InstanceName }
    $connection = [System.Data.SqlClient.SqlConnection]::new("Data Source=$source;Integrated Security=True;Initial Catalog=master;Encrypt=True;TrustServerCertificate=True;Pooling=False;Connect Timeout=30")
    $command = $connection.CreateCommand()
    $command.CommandText = @'
DECLARE @statement nvarchar(max) = N'ALTER LOGIN [sa] WITH CHECK_EXPIRATION = OFF, CHECK_POLICY = OFF; ALTER LOGIN [sa] WITH PASSWORD = ' + QUOTENAME(@password, '''') + N';';
EXEC sys.sp_executesql @statement;
IF @enforcePolicy = 1 ALTER LOGIN [sa] WITH CHECK_POLICY = ON;
ALTER LOGIN [sa] ENABLE;
EXEC master.dbo.xp_instance_regwrite N'HKEY_LOCAL_MACHINE', N'Software\Microsoft\MSSQLServer\MSSQLServer', N'LoginMode', REG_DWORD, 2;
DECLARE @oldAdvanced int = (SELECT CONVERT(int, value_in_use) FROM sys.configurations WHERE name = N'show advanced options');
IF @oldAdvanced = 0 BEGIN EXEC sys.sp_configure N'show advanced options', 1; RECONFIGURE; END;
BEGIN TRY
    EXEC sys.sp_configure N'max server memory (MB)', @memoryMB;
    RECONFIGURE;
END TRY
BEGIN CATCH
    IF @oldAdvanced = 0 BEGIN EXEC sys.sp_configure N'show advanced options', 0; RECONFIGURE; END;
    THROW;
END CATCH;
IF @oldAdvanced = 0 BEGIN EXEC sys.sp_configure N'show advanced options', 0; RECONFIGURE; END;
'@
    try {
        $connection.Open()
        $parameter = $command.Parameters.Add('@password', [System.Data.SqlDbType]::NVarChar, 128)
        $parameter.Value = ([PSCredential]::new('sa', $Password)).GetNetworkCredential().Password
        $null = $command.Parameters.Add('@memoryMB', [System.Data.SqlDbType]::Int)
        $command.Parameters['@memoryMB'].Value = $MaxServerMemoryMB
        $null = $command.Parameters.Add('@enforcePolicy', [System.Data.SqlDbType]::Bit)
        $command.Parameters['@enforcePolicy'].Value = $EnforceSaPasswordPolicy.IsPresent
        $null = $command.ExecuteNonQuery()
    } catch {
        # Do not write SQL exception text: it can contain parts of the submitted statement.
        throw 'Could not configure sa or memory. Check Windows SQL administrator access and password settings, then rerun -ConfigureOnly.'
    } finally {
        $command.Parameters.Clear()
        $command.Dispose()
        $connection.Dispose()
    }
}

if (-not [Environment]::Is64BitProcess) { throw 'Use 64-bit Windows PowerShell.' }
$os = Get-CimInstance Win32_OperatingSystem
if ($os.ProductType -eq 1 -or [int]$os.BuildNumber -notin @(17763,20348,26100)) {
    throw "Supported OS: Windows Server 2019/2022/2025. Detected: $($os.Caption), build $($os.BuildNumber)."
}
if ((Get-CimInstance Win32_ComputerSystem).DomainRole -in @(4,5)) {
    throw 'This script does not install SQL Server on a domain controller.'
}
Import-Module NetSecurity -ErrorAction Stop
Import-Module NetTCPIP -ErrorAction Stop
function Assert-MicrosoftSignature([string]$Path) {
    $sig = Get-AuthenticodeSignature -LiteralPath $Path
    if ($sig.Status -ne 'Valid' -or $null -eq $sig.SignerCertificate -or $sig.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') {
        throw "Microsoft signature verification failed for $Path : $($sig.Status)"
    }
}
function Resolve-SqlSetup {
if ([string]::IsNullOrWhiteSpace($MediaPath)) {
    if ($DownloadUrl.Scheme -ne 'https') { throw 'DownloadUrl must use HTTPS.' }
    $null = New-Item -ItemType Directory -Path $DownloadDirectory -Force
    $downloadRoot = (Resolve-Path -LiteralPath $DownloadDirectory).ProviderPath
    $runDirectory = Join-Path $downloadRoot ([guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $runDirectory
    $bootstrapper = Join-Path $runDirectory 'SQL2025-SSEI-Expr.exe'
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    Write-Stage "[2/7] Downloading SQL Server 2025 Express bootstrapper from $DownloadUrl"
    $oldProgress = $ProgressPreference
    try {
        $ProgressPreference = 'Continue'
        for ($retry = 1; $retry -le 3; $retry++) {
            try {
                Write-Stage "Bootstrapper download attempt $retry of 3 (request timeout: 300 seconds)."
                Invoke-WebRequest -Uri $DownloadUrl -OutFile $bootstrapper -UseBasicParsing -TimeoutSec 300
                break
            } catch {
                if ($retry -eq 3) { throw }
                Start-Sleep -Seconds 3
            }
        }
    } finally { $ProgressPreference = $oldProgress }
    Write-Stage 'Checking bootstrapper Microsoft signature...'
    Assert-MicrosoftSignature $bootstrapper
    $mediaDirectory = Join-Path $runDirectory 'Media'
    $null = New-Item -ItemType Directory -Path $mediaDirectory
    Write-Host 'Downloading full English Express media from Microsoft. This can take several minutes.'
    $downloadArgs = '/ACTION=Download /MEDIATYPE=Expr /LANGUAGE=en-US /QUIET /IACCEPTSQLSERVERLICENSETERMS /MEDIAPATH=' + (Quote-SetupValue $mediaDirectory)
    $downloadCode = Invoke-TrackedProcess -FilePath $bootstrapper -ArgumentLine $downloadArgs -Activity '[3/7] Downloading full Express media' -WatchDirectory $mediaDirectory
    if ($downloadCode -ne 0) { throw "Media download failed: $downloadCode. Files: $runDirectory" }
    $packages = @(Get-ChildItem -LiteralPath $mediaDirectory -Filter 'SQLEXPR*x64*.exe' -File -Recurse)
    if ($packages.Count -ne 1) { throw "Expected one full Express package; found $($packages.Count) in $mediaDirectory." }
    Write-Stage 'Checking full media Microsoft signature...'
    Assert-MicrosoftSignature $packages[0].FullName
    $extractDirectory = Join-Path $runDirectory 'Extracted'
    Write-Host "Extracting SQL Server media to $extractDirectory"
    $extractCode = Invoke-TrackedProcess -FilePath $packages[0].FullName -ArgumentLine ('/Q /X:' + (Quote-SetupValue $extractDirectory)) -Activity '[4/7] Extracting media' -WatchDirectory $extractDirectory
    if ($extractCode -ne 0) { throw "Media extraction failed: $extractCode." }
    $MediaPath = $extractDirectory
}
$resolvedMedia = (Resolve-Path -LiteralPath $MediaPath).ProviderPath
if (Test-Path -LiteralPath $resolvedMedia -PathType Container) {
    $setup = Join-Path $resolvedMedia 'setup.exe'
} else { $setup = $resolvedMedia }
if (-not (Test-Path -LiteralPath $setup -PathType Leaf) -or
    [IO.Path]::GetFileName($setup) -ine 'setup.exe') {
    throw 'Provide the full installation media directory or its setup.exe, not a web downloader or ISO file.'
}
$mediaMajor = (Get-Item -LiteralPath $setup).VersionInfo.ProductMajorPart
if ($mediaMajor -ne 17) {
    throw "Expected SQL Server 2025 Express full media (major version 17); detected $mediaMajor."
}
$signature = Get-AuthenticodeSignature -LiteralPath $setup
if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') {
    throw "SQL Server setup Microsoft signature could not be verified: $($signature.Status)."
}
return $setup
}
if (-not $SqlSysAdminAccounts -or $SqlSysAdminAccounts.Count -eq 0) { throw 'Specify at least one Windows SQL administrator.' }
# The executing Windows account configures sa over local shared memory after setup.
$SqlSysAdminAccounts = @($SqlSysAdminAccounts + @([Security.Principal.WindowsIdentity]::GetCurrent().Name) | Select-Object -Unique)
foreach ($account in $SqlSysAdminAccounts) {
    $null = Quote-SetupValue $account
    $ntAccount = New-Object Security.Principal.NTAccount($account)
    $null = $ntAccount.Translate([Security.Principal.SecurityIdentifier])
}
$instanceKey = 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL'
if (Test-Path $instanceKey) {
    $instances = Get-ItemProperty $instanceKey
    if (-not $ConfigureOnly -and $instances.PSObject.Properties.Name -contains $InstanceName) {
        throw "Instance '$InstanceName' already exists. This script only performs a new install."
    }
}
$rebootKeys = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
)
foreach ($key in $rebootKeys) {
    if (Test-Path $key) { Write-Warning 'Windows has a pending restart marker. Continuing; SQL Setup will evaluate prerequisites. This script will not restart Windows.' }
}
$pending = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue
if ($null -ne $pending -and $pending.PendingFileRenameOperations) {
    Write-Warning 'Pending file operations detected. Continuing; SQL Setup will evaluate prerequisites. This script will not restart Windows.'
}
if (-not $ConfigureOnly -and -not $AcceptLicenseTerms -and -not $CheckOnly) { throw 'Read the SQL Server license and specify -AcceptLicenseTerms to install.' }

$serviceName = 'MSSQLSERVER'
if ($InstanceName -ine 'MSSQLSERVER') { $serviceName = 'MSSQL$' + $InstanceName }
$serviceAccount = 'NT Service\' + $serviceName
$arguments = @(
    '/Q', '/ACTION=Install', '/FEATURES=SQLENGINE', '/IACCEPTSQLSERVERLICENSETERMS',
    ('/INSTANCENAME=' + (Quote-SetupValue $InstanceName)),
    ('/SQLSVCACCOUNT=' + (Quote-SetupValue $serviceAccount)),
    '/SQLSVCSTARTUPTYPE=Automatic',
    ('/SQLSYSADMINACCOUNTS=' + (($SqlSysAdminAccounts | ForEach-Object { Quote-SetupValue $_ }) -join ' ')),
    '/TCPENABLED=0', '/NPENABLED=0', '/UPDATEENABLED=False'
)
Write-Host "OS: $($os.Caption); target: SQL Server 2025 Express; instance: $InstanceName"
Write-Host 'Target authentication: Windows and SQL Server; login: sa; password entered interactively.'
Write-Host 'SQL Setup will perform additional hardware, prerequisite, and edition checks.'
if ($CheckOnly) {
    Write-Host 'Local preflight passed. No download or installation performed; media, connectivity and SQL Setup rules have not been checked.'
    return
}

$null = New-Item -ItemType Directory -Path $LogDirectory -Force
$runId = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
$transcript = Join-Path $LogDirectory "Install-$runId.log"
$exitCode = 1
$saPassword = $null
Start-Transcript -Path $transcript | Out-Null
try {
    $saPassword = Read-SaPassword
    if (-not $ConfigureOnly) {
    $setup = Resolve-SqlSetup
    $mediaMajor = 17
    Write-Host "Starting $setup"
    $setupLogs = "$env:ProgramFiles\Microsoft SQL Server\170\Setup Bootstrap\Log"
    Write-Stage "SQL Setup logs: $setupLogs"
    $exitCode = Invoke-TrackedProcess -FilePath $setup -ArgumentLine ($arguments -join ' ') -Activity '[5/7] Installing SQL Server' -WatchDirectory $setupLogs
    Write-Host "SQL Setup exit code: $exitCode"
    Write-Host "SQL Setup logs: $env:ProgramFiles\Microsoft SQL Server\${mediaMajor}0\Setup Bootstrap\Log"
    if ($exitCode -notin @(0,3010)) { throw "SQL Setup failed ($exitCode). Review Summary.txt and Detail.txt in the SQL Setup log directory." }
    if ($exitCode -eq 3010) {
        Write-Warning "Restart Windows, then run this script with -ConfigureOnly -InstanceName $InstanceName. Network configuration has NOT been performed."
        exit 3010
    }
    }
    $exitCode = 1
    $instanceProperty = (Get-ItemProperty $instanceKey).PSObject.Properties[$InstanceName]
    if ($null -eq $instanceProperty) { throw 'Installed instance not found. Specify the correct -InstanceName.' }
    $instanceId = $instanceProperty.Value
    $root = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$instanceId"
    $installed = Get-ItemProperty "$root\Setup"
    if ($installed.Edition -notmatch 'Express' -or $installed.Version -notmatch '^17\.') {
        throw 'The installed instance is not SQL Server 2025 Express. Network configuration stopped; use Express installation media.'
    }
    Add-Type -AssemblyName System.Data
    Write-Stage '[6/7] Configuring sa, authentication, memory and TCP port...'
    Start-Service -Name $serviceName
    Enable-SaLogin -Password $saPassword
    $tcp = "$root\MSSQLServer\SuperSocketNetLib\Tcp"
    $existingPort = [string](Get-ItemProperty "$tcp\IPAll").TcpPort
    $port = 0
    if ($ConfigureOnly -and $existingPort -match '^\d+$' -and [int]$existingPort -ge 20000 -and [int]$existingPort -le 49000 -and [int]$existingPort -notin $BlockedPorts) {
        $port = [int]$existingPort
    } else {
        $allowedPorts = @(20000..49000 | Where-Object { $_ -notin $BlockedPorts })
        foreach ($candidate in (Get-Random -InputObject $allowedPorts -Count 100)) {
            $probe = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Any, $candidate)
            try {
                $probe.Server.ExclusiveAddressUse = $true
                $probe.Start()
                $port = $candidate
                break
            } catch [Net.Sockets.SocketException] {
                continue
            } finally { $probe.Stop() }
        }
    }
    if ($port -eq 0 -or $port -in $BlockedPorts) { throw 'Could not select an available port allowed by the network policy.' }
    Set-ItemProperty $tcp -Name Enabled -Value 1
    Set-ItemProperty $tcp -Name ListenOnAllIPs -Value 1
    Get-ChildItem $tcp | Where-Object { $_.PSChildName -like 'IP*' } | ForEach-Object {
        Set-ItemProperty $_.PSPath -Name TcpDynamicPorts -Value ''
        Set-ItemProperty $_.PSPath -Name TcpPort -Value ([string]$port)
    }
    Write-Stage "Restarting SQL service $serviceName; selected TCP port: $port"
    Restart-Service -Name $serviceName -ErrorAction Stop
    $listening = $false
    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        $sqlService = Get-CimInstance Win32_Service -Filter "Name='$serviceName'"
        $listeners = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object { $_.OwningProcess -eq $sqlService.ProcessId -and $sqlService.ProcessId -ne 0 })
        $listeningPorts = @($listeners | Select-Object -ExpandProperty LocalPort)
        if (@($listeningPorts | Where-Object { $_ -in $BlockedPorts }).Count -gt 0) { throw 'SQL Server is unexpectedly listening on a blocked port.' }
        if ($listeningPorts -contains $port) { $listening = $true; break }
        Start-Sleep -Seconds 2
    }
    if (-not $listening) { throw "SQL Server is not listening on $port. Check the SQL error log; firewall rule has not been opened." }
    Write-Stage '[7/7] Verifying sa TCP login and configuring firewall...'
    $testConnection = [System.Data.SqlClient.SqlConnection]::new("Data Source=tcp:127.0.0.1,$port;Initial Catalog=master;Encrypt=True;TrustServerCertificate=True;Pooling=False;Connect Timeout=30")
    try {
        $testConnection.Credential = [System.Data.SqlClient.SqlCredential]::new('sa', $saPassword)
        $testConnection.Open()
        $testCommand = $testConnection.CreateCommand()
        try {
            $testCommand.CommandText = "SELECT IS_SRVROLEMEMBER('sysadmin');"
            if ($testCommand.ExecuteScalar() -ne 1) { throw 'Missing sysadmin role.' }
        } finally { $testCommand.Dispose() }
    } catch { throw 'sa TCP login verification failed. Firewall rule has not been opened by this run.' }
    finally { $testConnection.Dispose() }
    Set-NetFirewallProfile -Profile Domain,Private,Public -Enabled True
    $ruleName = "SQL2025Express-$InstanceName-TCP"
    $oldRule = Get-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue
    if ($oldRule) { $oldRule | Remove-NetFirewallRule }
    New-NetFirewallRule -Name $ruleName -DisplayName "SQL Server 2025 Express $InstanceName TCP $port" -Direction Inbound -Action Allow -Protocol TCP -LocalPort $port -Service $serviceName -Profile Any -RemoteAddress $RemoteAddress | Out-Null
    $disabledProfiles = @(Get-NetFirewallProfile -PolicyStore ActiveStore | Where-Object { $_.Enabled -ne $true })
    if ($disabledProfiles.Count -gt 0) { throw 'One or more effective firewall profiles remain disabled. Check Group Policy.' }
    if (-not (Get-NetFirewallRule -Name $ruleName -PolicyStore ActiveStore -ErrorAction SilentlyContinue)) { throw 'Firewall rule is absent from effective policy. Check Group Policy.' }
    $resultFile = Join-Path $LogDirectory "$InstanceName-connection.json"
    [ordered]@{ Instance = $InstanceName; Edition = $installed.Edition; Port = $port; Connection = "tcp:$env:COMPUTERNAME,$port"; Authentication = 'SQL Server and Windows'; Login = 'sa'; FirewallRule = $ruleName; RemoteAddress = $RemoteAddress } | ConvertTo-Json | Set-Content -LiteralPath $resultFile -Encoding UTF8
    Write-Host "Ready: tcp:$env:COMPUTERNAME,$port (SQL Server authentication; login: sa; password: the value you entered)"
    Write-Host "Connection details saved to $resultFile"
    Write-Host "Max server memory setting: $MaxServerMemoryMB MB; sa password policy enforced: $($EnforceSaPasswordPolicy.IsPresent)"
    $exitCode = 0
} catch {
    if ($exitCode -in @(0,3010)) { $exitCode = 1 }
    Write-Error -Message $_.Exception.Message -ErrorAction Continue
} finally {
    if ($null -ne $saPassword) { $saPassword.Dispose() }
    Stop-Transcript | Out-Null
}
exit $exitCode
