<#
GitHub launcher. Supports IEX (DownloadString(...)) and direct execution.
The installer runs in a child Windows PowerShell process so exit does not close
the caller's shell. No SQL installation package is hosted in this repository.
#>
& {
    $ErrorActionPreference = 'Stop'
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Open Windows PowerShell as Administrator, then run this command again.'
    }
    Write-Host 'SQL Server 2025 Express | MSSQLSERVER | sa | random allowed TCP port'
    Write-Host 'SQL Server license terms: https://aka.ms/useterms'
    $accept = Read-Host 'Do you accept the SQL Server license terms and start installation? Type YES'
    if ($accept -ine 'YES') { Write-Host 'Installation cancelled.'; return }
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $uri = 'https://raw.githubusercontent.com/shangchuanji/kabuto/main/Install-SqlServer.ps1'
    $folder = Join-Path $env:TEMP ('SQL2025Express-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $folder
    $installer = Join-Path $folder 'Install-SqlServer.ps1'
    Write-Host "Downloading installer script to $installer"
    Invoke-WebRequest -Uri $uri -OutFile $installer -UseBasicParsing -TimeoutSec 120 -ErrorAction Stop
    $parseTokens = $null
    $parseErrors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($installer, [ref]$parseTokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) { throw 'Downloaded script is invalid. Check the GitHub file.' }
    $powershellPath = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not [Environment]::Is64BitProcess) {
        $powershellPath = Join-Path $env:WINDIR 'Sysnative\WindowsPowerShell\v1.0\powershell.exe'
    }
    & $powershellPath -NoProfile -ExecutionPolicy Bypass -File $installer -AcceptLicenseTerms
    $result = $LASTEXITCODE
    if ($result -eq 3010) {
        Write-Warning 'SQL Setup requires a Windows restart. Windows was NOT restarted. After scheduling a restart, complete configuration with:'
        Write-Host "& '$powershellPath' -NoProfile -ExecutionPolicy Bypass -File '$installer' -ConfigureOnly"
    } elseif ($result -ne 0) {
        throw "Installation/configuration failed (exit code $result). Script saved at $installer. Review C:\ProgramData\SqlServerInstallLogs."
    }
}
