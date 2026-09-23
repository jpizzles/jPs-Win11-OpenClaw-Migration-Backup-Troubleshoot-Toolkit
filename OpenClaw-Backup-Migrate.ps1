#requires -Version 5.1
<#
OpenClaw Backup & Migration Toolkit
Designed for a Windows + WSL2 OpenClaw Gateway setup.

Features
- Full verified OpenClaw backup from WSL using the supported `openclaw backup create --verify` flow.
- Captures Windows-side OpenClaw node files and Scheduled Task XML for recovery/reference.
- Creates a portable migration kit containing this tool.
- Restores a migration kit onto another Windows + WSL machine.
- Installs OpenClaw in WSL and Windows if missing.
- Rebuilds the Windows CUA node service with --all-commands.
- SHA-256 checksums, logs, preflight checks, postflight checks, and rollback breadcrumbs.

IMPORTANT
- Backups contain secrets, OAuth state, channel credentials, sessions, and other sensitive data.
- Keep migration folders encrypted/protected.
- The restore path intentionally uses OpenClaw's supported staged restore flow before activation.
#>

[CmdletBinding()]
param(
    [string]$BackupRoot = "$env:USERPROFILE\Documents\OpenClaw-Backups",
    [string]$Distro = "",
    [string]$RestorePackage = "",
    [switch]$NewPC,
    [switch]$PrerequisiteCheckOnly,
    [switch]$NonInteractive
)

Set-StrictMode -Version 2
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$Script:ToolVersion = "1.12.2"
$Script:CurrentLog = $null

$Script:SelectedDistro = $null
$Script:ActivePackageFolder = $null
$Script:RestoreInstalledDistro = $false
$Script:RestoreSupportFolder = $null

function Initialize-Console {
    # Keep the menu readable in classic Windows PowerShell and Windows Terminal.
    # All of this is best-effort; redirected/non-interactive hosts may not expose a console.
    try {
        $raw = $Host.UI.RawUI
        $size = $raw.WindowSize
        if ($size.Width -lt 110) { $size.Width = [Math]::Min(120, $raw.MaxPhysicalWindowSize.Width) }
        if ($size.Height -lt 34) { $size.Height = [Math]::Min(42, $raw.MaxPhysicalWindowSize.Height) }
        $raw.WindowSize = $size

        $buf = $raw.BufferSize
        if ($buf.Width -ne $size.Width) { $buf.Width = $size.Width }
        if ($buf.Height -lt 3000) { $buf.Height = 3000 }
        $raw.BufferSize = $buf
    } catch {
        # Ignore hosts that don't permit console resizing.
    }
}


function Write-Banner {
    Initialize-Console
    try { Clear-Host } catch {}
    $banner = @"
+------------------------------------------------------------------------------------------------------------+
| OpenClaw Backup & Migration Toolkit  v$($Script:ToolVersion)                                                        |
+------------------------------------------------------------------------------------------------------------+
"@
    Write-Host $banner -ForegroundColor Cyan
}

function Step([string]$Text) {
    Write-Host ""
    Write-Host ">>> $Text" -ForegroundColor Cyan
}

function Pass([string]$Text) {
    Write-Host "[PASS] $Text" -ForegroundColor Green
}

function Warn([string]$Text) {
    Write-Host "[WARN] $Text" -ForegroundColor Yellow
}

function Fail([string]$Text) {
    throw "[FAIL] $Text"
}

function Info([string]$Text) {
    Write-Host "[INFO] $Text" -ForegroundColor Gray
}

function Pause-Tool {
    if (-not $NonInteractive) {
        Write-Host ""
        Read-Host "Press Enter to continue" | Out-Null
    }
}

function Ensure-Directory([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Force -Path $Path | Out-Null
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        Fail "Could not create directory: $Path"
    }
}

function Start-RunLog([string]$Folder) {
    Ensure-Directory $Folder
    $Script:CurrentLog = Join-Path $Folder "tool-run.log"
    try {
        Start-Transcript -Path $Script:CurrentLog -Append -Force | Out-Null
    } catch {
        Warn "Could not start PowerShell transcript: $($_.Exception.Message)"
    }
}

function Stop-RunLog {
    try { Stop-Transcript | Out-Null } catch {}
}

function Invoke-Native {
    param(
        [Parameter(Mandatory=$true)][string]$FilePath,
        [Parameter(Mandatory=$false)][string[]]$Arguments = @(),
        [switch]$AllowFailure,
        [switch]$Quiet
    )
    $display = "$FilePath " + ($Arguments -join " ")
    if (-not $Quiet) { Info $display }

    # Windows PowerShell 5.1 can promote native-process stderr into a
    # terminating NativeCommandError when $ErrorActionPreference is Stop.
    # That previously caused a perfectly understandable OpenClaw message on
    # stderr to abort the entire backup before the Payload archive was made.
    $oldEap = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $output = @(& $FilePath @Arguments 2>&1)
        $code = $LASTEXITCODE
    } catch {
        $output = @($_ | Out-String)
        $code = if ($null -ne $LASTEXITCODE) { $LASTEXITCODE } else { 1 }
    } finally {
        $ErrorActionPreference = $oldEap
    }

    if ($output -and (-not $Quiet)) { $output | ForEach-Object { Write-Host $_ } }
    if (($code -ne 0) -and (-not $AllowFailure)) {
        Fail "Command failed with exit code $code`: $display"
    }
    return [pscustomobject]@{ ExitCode=$code; Output=(($output | ForEach-Object { $_.ToString() }) -join "`n") }
}

function Invoke-Wsl {
    param(
        [Parameter(Mandatory=$true)][string]$Command,
        [string[]]$Arguments = @(),
        [switch]$AllowFailure,
        [switch]$SensitiveOutput
    )

    if (-not $Script:SelectedDistro) { Select-WslDistro }

    $cleanDistro = Normalize-WslDistroName $Script:SelectedDistro
    if ([string]::IsNullOrWhiteSpace($cleanDistro)) {
        throw "Selected WSL distro name is empty after normalization."
    }
    $Script:SelectedDistro = $cleanDistro

    # CRITICAL TRANSPORT RULE:
    # Bash source is NEVER placed in the Windows command line. It is streamed
    # through STDIN to `bash -s`. Optional positional arguments are passed
    # separately after `--`, becoming Bash $1, $2, ... without shell quoting.
    $linuxPathPrelude = 'export PATH="$HOME/.openclaw/bin:$HOME/.openclaw/tools/node/bin:$HOME/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"; hash -r;'
    $scriptText = $linuxPathPrelude + "`n" + $Command + "`n"

    $wslExe = "$env:WINDIR\System32\wsl.exe"
    if (-not (Test-Path -LiteralPath $wslExe -PathType Leaf)) {
        $wslExe = "wsl.exe"
    }

    $argTokens = New-Object System.Collections.Generic.List[string]
    $argTokens.Add("-d")
    $argTokens.Add($cleanDistro)
    $argTokens.Add("--exec")
    $argTokens.Add("bash")
    $argTokens.Add("-s")
    $argTokens.Add("--")

    foreach ($a in @($Arguments)) {
        if ($null -eq $a) { $argTokens.Add("") }
        else { $argTokens.Add([string]$a) }
    }

    $quotedArgs = @($argTokens | ForEach-Object { Quote-WindowsArgument $_ })

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $wslExe
    $psi.Arguments = ($quotedArgs -join " ")
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true

    # Windows PowerShell 5.1 uses .NET Framework ProcessStartInfo, which does
    # NOT expose StandardInputEncoding. Bash source is written as raw
    # UTF-8-no-BOM bytes to StandardInput.BaseStream instead.
    if ($psi.PSObject.Properties.Name -contains "StandardOutputEncoding") {
        $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    }
    if ($psi.PSObject.Properties.Name -contains "StandardErrorEncoding") {
        $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    }

    $argCount = @($Arguments).Count
    if ($SensitiveOutput) {
        Info "wsl.exe -d $cleanDistro --exec bash -s -- [sensitive output suppressed; $argCount positional arg(s)]"
    } else {
        Info "wsl.exe -d $cleanDistro --exec bash -s -- [script via STDIN; $argCount positional arg(s)]"
    }

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi

    try {
        if (-not $proc.Start()) {
            throw "wsl.exe failed to start."
        }

        # Read stdout/stderr asynchronously to prevent child-process pipe
        # deadlocks during npm/OpenClaw installations and restore operations.
        $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
        $stderrTask = $proc.StandardError.ReadToEndAsync()

        $utf8NoBom = New-Object System.Text.UTF8Encoding -ArgumentList $false
        $stdinBytes = $utf8NoBom.GetBytes($scriptText)
        $proc.StandardInput.BaseStream.Write($stdinBytes, 0, $stdinBytes.Length)
        $proc.StandardInput.BaseStream.Flush()
        $proc.StandardInput.Close()

        $proc.WaitForExit()

        $stdout = $stdoutTask.Result
        $stderr = $stderrTask.Result
        $exitCode = $proc.ExitCode
    } catch {
        if (-not $AllowFailure) { throw }
        $stdout = ""
        $stderr = $_.Exception.Message
        $exitCode = 1
    } finally {
        try { $proc.Dispose() } catch {}
    }

    $parts = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($stdout)) { $parts.Add($stdout.TrimEnd()) }
    if (-not [string]::IsNullOrWhiteSpace($stderr)) { $parts.Add($stderr.TrimEnd()) }
    $output = ($parts -join "`n")

    if ($output -and (-not $SensitiveOutput)) {
        $output -split "`r?`n" | ForEach-Object { Write-Host $_ }
    }

    if (($exitCode -ne 0) -and (-not $AllowFailure)) {
        throw "WSL command failed with exit code $exitCode."
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Output   = $output
    }
}

function Convert-ToWslPath([string]$WindowsPath) {
    # Convert ordinary local Windows paths directly so usernames/folders with spaces
    # (for example C:\Users\Mick Jagger\...) are handled reliably.
    if ([string]::IsNullOrWhiteSpace($WindowsPath)) {
        Fail "Cannot convert an empty Windows path to a WSL path."
    }

    $full = [System.IO.Path]::GetFullPath($WindowsPath)

    if ($full -match '^([A-Za-z]):\\(.*)$') {
        $drive = $matches[1].ToLowerInvariant()
        $rest = $matches[2] -replace '\\','/'
        $result = "/mnt/$drive/$rest"
        Info "WSL path mapping: $full -> $result"
        return $result
    }

    if ($full -match '^([A-Za-z]):\\?$') {
        $drive = $matches[1].ToLowerInvariant()
        $result = "/mnt/$drive/"
        Info "WSL path mapping: $full -> $result"
        return $result
    }

    if ($full.StartsWith('\\')) {
        Fail "UNC/network paths are not supported as a backup target by this toolkit. Choose a local Windows folder such as Documents or an attached drive."
    }

    if (-not $Script:SelectedDistro) { Select-WslDistro }
    $Script:SelectedDistro = Normalize-WslDistroName $Script:SelectedDistro
    $output = & wsl.exe -d $Script:SelectedDistro -- wslpath -a -u $full 2>&1
    $code = $LASTEXITCODE
    if ($code -ne 0) {
        Fail "Unable to convert Windows path to WSL path: $full`n$($output -join "`n")"
    }

    $result = (($output | Select-Object -Last 1) -as [string]).Trim()
    if ([string]::IsNullOrWhiteSpace($result) -or -not $result.StartsWith('/')) {
        Fail "WSL path conversion returned an invalid path for: $full"
    }

    Info "WSL path mapping: $full -> $result"
    return $result
}


function Convert-WslNativePathToUnc([string]$WslPath) {
    if ([string]::IsNullOrWhiteSpace($WslPath)) {
        Fail "Cannot convert an empty WSL-native path to a Windows UNC path."
    }
    if (-not $Script:SelectedDistro) { Select-WslDistro }

    $p = $WslPath.Trim()
    if (-not $p.StartsWith('/')) {
        Fail "Expected an absolute WSL path, got: $p"
    }

    $relative = $p.TrimStart('/') -replace '/', '\'
    $unc = "\\wsl.localhost\$($Script:SelectedDistro)\$relative"
    Info "WSL UNC mapping: $p -> $unc"
    return $unc
}

function Wait-ForWindowsFile {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [int]$TimeoutSeconds = 30
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        try {
            if ([System.IO.File]::Exists($Path)) {
                $fi = New-Object System.IO.FileInfo($Path)
                if ($fi.Length -gt 0) { return $fi }
            }
        } catch {}
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)

    return $null
}


function Quote-WindowsArgument([string]$Value) {
    if ($null -eq $Value) { return '""' }
    # Standard Windows command-line quoting for ProcessStartInfo.Arguments.
    if ($Value -notmatch '[\s"]') { return $Value }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    $slashes = 0
    foreach ($ch in $Value.ToCharArray()) {
        if ($ch -eq '\') {
            $slashes++
            continue
        }
        if ($ch -eq '"') {
            [void]$sb.Append(('\' * (($slashes * 2) + 1)))
            [void]$sb.Append('"')
            $slashes = 0
            continue
        }
        if ($slashes -gt 0) {
            [void]$sb.Append(('\' * $slashes))
            $slashes = 0
        }
        [void]$sb.Append($ch)
    }
    if ($slashes -gt 0) {
        [void]$sb.Append(('\' * ($slashes * 2)))
    }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function Copy-WslFileToWindowsRaw {
    param(
        [Parameter(Mandatory=$true)][string]$WslSource,
        [Parameter(Mandatory=$true)][string]$WindowsDestination
    )

    if (-not $Script:SelectedDistro) { Select-WslDistro }
    $Script:SelectedDistro = Normalize-WslDistroName $Script:SelectedDistro

    $destFull = [System.IO.Path]::GetFullPath($WindowsDestination)
    $destDir = [System.IO.Path]::GetDirectoryName($destFull)
    Ensure-Directory $destDir

    Step "Checking WSL source archive size"
    $sizeResult = Invoke-Wsl "stat -c '%s' '$WslSource'" -AllowFailure
    if ($sizeResult.ExitCode -ne 0) {
        Fail "Could not stat WSL source archive: $WslSource"
    }
    $sizeText = ($sizeResult.Output -split "`r?`n" | Where-Object { $_.Trim() -match '^\d+$' } | Select-Object -Last 1)
    if (-not $sizeText) {
        Fail "WSL did not return a valid archive byte count."
    }
    [Int64]$expectedBytes = $sizeText.Trim()
    if ($expectedBytes -le 0) {
        Fail "WSL archive is empty."
    }
    Pass "WSL source archive size: $expectedBytes bytes"

    Step "Streaming archive directly from wsl.exe into Windows"
    # No /mnt/c, no \\wsl.localhost, no PowerShell pipeline/redirection.
    # wsl.exe runs /bin/cat and we copy its raw stdout BaseStream directly into a Windows FileStream.
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "$env:WINDIR\System32\wsl.exe"
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true

    $distroArg = Quote-WindowsArgument $Script:SelectedDistro
    $sourceArg = Quote-WindowsArgument $WslSource
    $psi.Arguments = "-d $distroArg --exec /bin/cat $sourceArg"

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi

    $dstStream = $null
    try {
        if (-not $proc.Start()) {
            Fail "Could not start wsl.exe binary export process."
        }

        # Drain stderr asynchronously to avoid a pipe deadlock.
        $stderrTask = $proc.StandardError.ReadToEndAsync()

        $dstStream = New-Object System.IO.FileStream(
            $destFull,
            [System.IO.FileMode]::Create,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None,
            4194304,
            [System.IO.FileOptions]::SequentialScan
        )

        $proc.StandardOutput.BaseStream.CopyTo($dstStream, 4194304)
        $dstStream.Flush()
        $dstStream.Dispose()
        $dstStream = $null

        $proc.WaitForExit()
        $stderr = $stderrTask.Result

        if ($proc.ExitCode -ne 0) {
            Remove-Item -LiteralPath $destFull -Force -ErrorAction SilentlyContinue
            Fail "wsl.exe binary export failed with exit code $($proc.ExitCode): $stderr"
        }
    } catch {
        if ($dstStream) { $dstStream.Dispose() }
        try {
            if (-not $proc.HasExited) { $proc.Kill() }
        } catch {}
        Remove-Item -LiteralPath $destFull -Force -ErrorAction SilentlyContinue
        throw
    } finally {
        $proc.Dispose()
    }

    if (-not [System.IO.File]::Exists($destFull)) {
        Fail "Windows destination file was not created: $destFull"
    }

    $destInfo = New-Object System.IO.FileInfo($destFull)
    if ($destInfo.Length -ne $expectedBytes) {
        Remove-Item -LiteralPath $destFull -Force -ErrorAction SilentlyContinue
        Fail "Binary transfer byte-count mismatch. WSL=$expectedBytes Windows=$($destInfo.Length)"
    }
    Pass "Binary transfer byte count matches exactly."

    Step "Verifying SHA-256 across WSL and Windows"
    $hashResult = Invoke-Wsl "sha256sum '$WslSource' | cut -d' ' -f1" -AllowFailure
    if ($hashResult.ExitCode -ne 0) {
        Fail "Could not calculate WSL SHA-256."
    }
    $wslHash = ($hashResult.Output -split "`r?`n" | Where-Object { $_.Trim() -match '^[0-9a-fA-F]{64}$' } | Select-Object -Last 1)
    if (-not $wslHash) {
        Fail "WSL SHA-256 output was invalid."
    }
    $wslHash = $wslHash.Trim().ToLowerInvariant()
    $winHash = (Get-FileHash -LiteralPath $destFull -Algorithm SHA256).Hash.ToLowerInvariant()

    if ($wslHash -ne $winHash) {
        Remove-Item -LiteralPath $destFull -Force -ErrorAction SilentlyContinue
        Fail "SHA-256 mismatch after binary transfer. WSL=$wslHash Windows=$winHash"
    }
    Pass "SHA-256 matches exactly across WSL and Windows."

    return $destInfo
}

function Export-PackageZip {
    param(
        [Parameter(Mandatory=$true)][string]$PackageFolder
    )

    Step "Creating single portable ZIP on the Windows Desktop"
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $packageFull = [System.IO.Path]::GetFullPath($PackageFolder)
    $manifestPath = Join-Path $packageFull "package-manifest.json"

    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        Fail "Cannot create portable ZIP because package-manifest.json is missing from the package folder: $manifestPath"
    }

    # Require at least one OpenClaw archive in Payload before zipping.
    $payloadDir = Join-Path $packageFull "Payload"
    $archives = @(Get-ChildItem -LiteralPath $payloadDir -File -Filter "*.tar.gz" -ErrorAction SilentlyContinue)
    if ($archives.Count -lt 1) {
        Fail "Cannot create portable ZIP because Payload contains no .tar.gz OpenClaw archive."
    }

    # Parse the manifest before zipping so malformed JSON never gets packaged as success.
    try {
        $manifestObject = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    } catch {
        Fail "package-manifest.json exists but is invalid JSON: $($_.Exception.Message)"
    }
    Pass "Package manifest exists and parses correctly."
    Pass "OpenClaw archive is present in Payload before ZIP creation."

    $desktop = [Environment]::GetFolderPath('Desktop')
    if ([string]::IsNullOrWhiteSpace($desktop)) {
        $desktop = Join-Path $env:USERPROFILE "Desktop"
    }
    Ensure-Directory $desktop

    $baseName = Split-Path -Leaf $packageFull
    $zipPath = Join-Path $desktop ($baseName + ".zip")
    if (Test-Path -LiteralPath $zipPath) {
        Remove-Item -LiteralPath $zipPath -Force
    }

    # IMPORTANT: includeBaseDirectory = false.
    # This puts package-manifest.json, Payload\, Windows\, and restore files
    # directly at the ZIP root. It also makes restore/finalization deterministic.
    [System.IO.Compression.ZipFile]::CreateFromDirectory(
        $packageFull,
        $zipPath,
        [System.IO.Compression.CompressionLevel]::Optimal,
        $false
    )

    if (-not (Test-Path -LiteralPath $zipPath -PathType Leaf)) {
        Fail "Portable ZIP was not created: $zipPath"
    }

    $zipInfo = Get-Item -LiteralPath $zipPath
    if ($zipInfo.Length -lt 1024) {
        Fail "Portable ZIP is unexpectedly small: $($zipInfo.Length) bytes"
    }

    Step "Reopening and validating the portable ZIP"
    $zr = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
    try {
        $entries = @($zr.Entries)
        if ($entries.Count -eq 0) {
            Fail "Portable ZIP opened successfully but contains zero entries."
        }

        $manifestEntry = $null
        $archiveEntries = @()

        foreach ($entry in $entries) {
            # Normalize either slash style. ZipArchive normally uses '/', but this
            # deliberately handles either Windows or ZIP separators.
            $normalized = $entry.FullName.Replace('\','/').TrimStart('/')

            if ($normalized -ieq "package-manifest.json") {
                $manifestEntry = $entry
            }

            if ($normalized -match '(^|/)Payload/[^/]+\.tar\.gz$') {
                $archiveEntries += $entry
            }
        }

        if (-not $manifestEntry) {
            $sample = ($entries | Select-Object -First 20 | ForEach-Object { $_.FullName }) -join "; "
            Fail "Portable ZIP validation could not find package-manifest.json at ZIP root. Entries seen: $sample"
        }

        if ($archiveEntries.Count -lt 1) {
            Fail "Portable ZIP validation could not find Payload/<archive>.tar.gz."
        }

        # Parse the manifest from INSIDE the ZIP, not merely the source folder.
        $reader = $null
        try {
            $reader = New-Object System.IO.StreamReader($manifestEntry.Open())
            $manifestInsideText = $reader.ReadToEnd()
            $manifestInside = $manifestInsideText | ConvertFrom-Json
        } catch {
            Fail "package-manifest.json inside the ZIP could not be parsed: $($_.Exception.Message)"
        } finally {
            if ($reader) { $reader.Dispose() }
        }

        # Verify the packaged tar.gz byte size matches the source tar.gz.
        $sourceArchive = $archives | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
        $matchingEntry = $null
        foreach ($entry in $archiveEntries) {
            $leaf = ($entry.FullName.Replace('\','/') -split '/')[-1]
            if ($leaf -ieq $sourceArchive.Name) {
                $matchingEntry = $entry
                break
            }
        }

        if (-not $matchingEntry) {
            Fail "The expected OpenClaw archive '$($sourceArchive.Name)' is not present inside the portable ZIP."
        }

        if ([Int64]$matchingEntry.Length -ne [Int64]$sourceArchive.Length) {
            Fail "OpenClaw archive size differs inside ZIP. Source=$($sourceArchive.Length) ZIP=$($matchingEntry.Length)"
        }

        Pass "ZIP contains package-manifest.json at its root."
        Pass "ZIP contains the expected OpenClaw .tar.gz archive."
        Pass "Archive byte size inside ZIP matches the verified Windows source."
    } finally {
        $zr.Dispose()
    }

    # Make sure Windows can independently enumerate the resulting ZIP after it was closed.
    try {
        $testZip = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
        $entryCount = $testZip.Entries.Count
        $testZip.Dispose()
    } catch {
        Fail "Portable ZIP could not be reopened after creation: $($_.Exception.Message)"
    }

    if ($entryCount -lt 2) {
        Fail "Portable ZIP contains too few entries ($entryCount)."
    }

    $zipHash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash
    Pass "Portable ZIP verified and reopened successfully."
    Info "ZIP entries: $entryCount"
    Write-Host ""
    Write-Host "PORTABLE BACKUP/MIGRATION ZIP:" -ForegroundColor Green
    Write-Host "  $zipPath" -ForegroundColor Green
    Write-Host "SHA-256:" -ForegroundColor Green
    Write-Host "  $zipHash" -ForegroundColor Green
    return $zipPath
}

function Test-Command([string]$Name) {
    return $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

function Select-WslDistro {
    Step "Checking WSL"
    if (-not (Test-Command "wsl.exe")) {
        Fail "WSL is not installed. On a new PC, run 'wsl --install -d Ubuntu-24.04', reboot, then rerun this tool."
    }

    $raw = & wsl.exe -l -q 2>$null
    $distros = @($raw | ForEach-Object { ($_ -replace "`0","").Trim() } | Where-Object { $_ })
    if ($distros.Count -eq 0) {
        Fail "WSL is installed but no Linux distribution exists. Run 'wsl --install -d Ubuntu-24.04', reboot, then rerun."
    }

    if ($Distro) {
        if ($distros -notcontains $Distro) {
            Fail "Requested WSL distro '$Distro' was not found. Available: $($distros -join ', ')"
        }
        $Script:SelectedDistro = $Distro
        Pass "Using WSL distro: $Distro"
        return
    }

    if ($distros.Count -eq 1 -or $NonInteractive) {
        $Script:SelectedDistro = $distros[0]
        Pass "Using WSL distro: $($Script:SelectedDistro)"
        return
    }

    Write-Host "Available WSL distributions:"
    for ($i=0; $i -lt $distros.Count; $i++) {
        Write-Host "  $($i+1)) $($distros[$i])"
    }
    do {
        $choice = Read-Host "Choose the WSL distro that runs your OpenClaw Gateway"
        $n = 0
        $ok = [int]::TryParse($choice, [ref]$n)
    } until ($ok -and $n -ge 1 -and $n -le $distros.Count)
    $Script:SelectedDistro = $distros[$n-1]
    Pass "Using WSL distro: $($Script:SelectedDistro)"
}

function Test-OpenClawWsl {
    $cmd = @'
set -e

OC="$HOME/.openclaw/bin/openclaw"
NODE="$HOME/.openclaw/tools/node/bin/node"

test -x "$OC"
test -x "$NODE"

printf 'OPENCLAW_WSL_PATH=%s\n' "$OC"
printf 'NODE_WSL_PATH=%s\n' "$NODE"

"$OC" --version
"$NODE" --version
'@

    $r = Invoke-Wsl $cmd -AllowFailure
    if ($r.ExitCode -eq 0 -and
        $r.Output -match '(?m)^OPENCLAW_WSL_PATH=/' -and
        $r.Output -match '(?m)^NODE_WSL_PATH=/') {

        $versionLine = ($r.Output -split "`r?`n" |
            Where-Object { $_ -match '^OpenClaw ' } |
            Select-Object -Last 1)

        Pass "OpenClaw is installed natively in WSL: $versionLine"
        return $true
    }

    Warn "Native Linux OpenClaw/private Node runtime is not installed or not executable in WSL."
    return $false
}

function Install-OpenClawWslIfMissing {
    param(
        [Parameter(Mandatory=$false)][string]$SupportFolder = "",
        [Parameter(Mandatory=$false)][string]$PackageFolder = ""
    )

    if (Test-OpenClawWsl) { return }

    if ([string]::IsNullOrWhiteSpace($SupportFolder)) { $SupportFolder = New-RestoreSupportFolder }
    if ([string]::IsNullOrWhiteSpace($PackageFolder)) { $PackageFolder = $RestorePackage }

    Step "Installing latest stable OpenClaw inside WSL"
    Info "Using OpenClaw's rootless local-prefix installer so Node and OpenClaw can be provisioned without a Linux sudo password."

    # The installer is allowed up to 15 minutes. The previous build completed
    # installation successfully, then could appear to freeze in a NON-ESSENTIAL
    # post-install profile/symlink mutation. v1.10.4 removes that mutation entirely.
    #
    # Every toolkit WSL call already injects the correct Linux-only PATH, so there
    # is no reason to edit ~/.profile or create ~/.local/bin/openclaw here.
    $installCmd = @'
set -e
if command -v timeout >/dev/null 2>&1; then
  timeout --signal=TERM --kill-after=20s 15m bash -c 'curl -fsSL --proto '"'"'=https'"'"' --tlsv1.2 https://openclaw.ai/install-cli.sh | bash -s -- --runtime-only --version latest'
else
  curl -fsSL --proto '=https' --tlsv1.2 https://openclaw.ai/install-cli.sh | bash -s -- --runtime-only --version latest
fi
'@

    $r = Invoke-Wsl $installCmd -AllowFailure

    if ($r.ExitCode -eq 124) {
        Write-RestoreFallbackGuide -SupportFolder $SupportFolder -PackageFolder $PackageFolder `
            -Problem "The WSL OpenClaw installer exceeded the 15-minute safety timeout." `
            -ManualSteps @(
                "Open the selected WSL distro.",
                "Run: export PATH=`"$HOME/.openclaw/bin:$HOME/.openclaw/tools/node/bin:$HOME/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin`"",
                "Run: openclaw --version",
                "If OpenClaw is already installed, exit WSL and run CONTINUE-RESTORE.cmd.",
                "Otherwise run: curl -fsSL https://openclaw.ai/install-cli.sh | bash -s -- --runtime-only --version latest",
                "Then run CONTINUE-RESTORE.cmd."
            )
        Fail "WSL OpenClaw installer timed out."
    }

    if ($r.ExitCode -eq 0) {
        Step "Verifying native WSL OpenClaw immediately after install"

        # Verify the canonical local-prefix paths directly. Do not touch ~/.profile,
        # do not create symlinks, and do not launch another login-shell customization.
        $verifyCmd = @'
set -e
test -x "$HOME/.openclaw/bin/openclaw"
test -x "$HOME/.openclaw/tools/node/bin/node"
printf 'OPENCLAW_FILE=%s\n' "$HOME/.openclaw/bin/openclaw"
printf 'NODE_FILE=%s\n' "$HOME/.openclaw/tools/node/bin/node"
"$HOME/.openclaw/bin/openclaw" --version
"$HOME/.openclaw/tools/node/bin/node" --version
'@

        $verify = Invoke-Wsl $verifyCmd -AllowFailure
        if ($verify.ExitCode -eq 0 -and
            $verify.Output -match '(?m)^OPENCLAW_FILE=/' -and
            $verify.Output -match '(?m)^NODE_FILE=/') {

            Pass "Native WSL OpenClaw and private Node runtime verified."
            return
        }

        Warn "OpenClaw installer returned success, but the canonical WSL runtime files could not be verified."
    } else {
        Warn "WSL OpenClaw installer returned exit code $($r.ExitCode)."
    }

    Write-RestoreFallbackGuide -SupportFolder $SupportFolder -PackageFolder $PackageFolder `
        -Problem "Automatic OpenClaw installation inside WSL failed or could not be verified." `
        -ManualSteps @(
            "Open the selected WSL distro.",
            "Run: export PATH=`"$HOME/.openclaw/bin:$HOME/.openclaw/tools/node/bin:$HOME/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin`"",
            "Run: curl -fsSL https://openclaw.ai/install-cli.sh | bash -s -- --runtime-only --version latest",
            "Verify: $HOME/.openclaw/bin/openclaw --version",
            "Verify: $HOME/.openclaw/tools/node/bin/node --version",
            "Exit WSL and run CONTINUE-RESTORE.cmd."
        )
    Fail "OpenClaw WSL installation requires manual completion."
}

function Test-GatewayDeep([switch]$AllowFailure) {
    $r = Invoke-Wsl "openclaw gateway status --deep" -AllowFailure
    $healthy = ($r.ExitCode -eq 0 -and $r.Output -match "Connectivity probe:\s*ok")
    if ($healthy) {
        Pass "Gateway deep health probe is OK."
    } else {
        if (-not $AllowFailure) { Fail "Gateway deep health probe failed." }
        Warn "Gateway is not currently healthy/reachable."
    }
    return $healthy
}

function Stop-GatewayForBackup {
    Step "Stopping WSL Gateway for a consistent migration snapshot"
    $status = Invoke-Wsl "systemctl --user is-active openclaw-gateway.service" -AllowFailure
    $wasActive = ($status.Output.Trim() -eq "active")
    if (-not $wasActive) {
        Info "Gateway was not active."
        return $false
    }

    # OpenClaw 2026.9.x protects the operator Gateway from non-interactive stops.
    # --force is required here because a migration-grade backup intentionally quiesces the live Gateway.
    Info "Requesting a protected Gateway stop with --force (required for backup consistency)."
    $stop = Invoke-Wsl "openclaw gateway stop --force" -AllowFailure
    if ($stop.ExitCode -ne 0) {
        Warn "OpenClaw gateway stop returned exit code $($stop.ExitCode). Falling back to systemd stop."
        Invoke-Wsl "systemctl --user stop openclaw-gateway.service" -AllowFailure | Out-Null
    }

    for ($i=0; $i -lt 60; $i++) {
        Start-Sleep -Seconds 2
        $r = Invoke-Wsl "systemctl --user is-active openclaw-gateway.service" -AllowFailure
        if ($r.Output.Trim() -ne "active" -and $r.Output.Trim() -ne "deactivating") {
            Pass "Gateway stopped cleanly."
            return $true
        }
        if (($i+1) % 10 -eq 0) {
            Info "Still waiting for Gateway shutdown... $((($i+1)*2)) seconds"
        }
    }

    Warn "Gateway is still draining after 120 seconds."
    if ($NonInteractive) {
        Fail "Gateway would not stop cleanly in unattended mode."
    }
    $force = Read-Host "Force-stop the Gateway now? This can abandon active runs. Type YES to force"
    if ($force -ne "YES") {
        Fail "Backup cancelled because Gateway did not stop."
    }

    Invoke-Wsl "systemctl --user kill --signal=SIGKILL openclaw-gateway.service || true; sleep 2; systemctl --user reset-failed openclaw-gateway.service || true" -AllowFailure | Out-Null
    $check = Invoke-Wsl "systemctl --user is-active openclaw-gateway.service" -AllowFailure
    if ($check.Output.Trim() -eq "active" -or $check.Output.Trim() -eq "deactivating") {
        Fail "Gateway still appears active after forced stop."
    }
    Pass "Gateway force-stopped."
    return $true
}

function Start-GatewayAndVerify {
    Step "Starting and verifying WSL Gateway"
    Invoke-Wsl "systemctl --user start openclaw-gateway.service" -AllowFailure | Out-Null
    Start-Sleep -Seconds 8
    if (-not (Test-GatewayDeep -AllowFailure)) {
        Warn "First health probe failed; waiting another 10 seconds."
        Start-Sleep -Seconds 10
        if (-not (Test-GatewayDeep -AllowFailure)) {
            $logs = Invoke-Wsl "journalctl --user -u openclaw-gateway.service -n 80 --no-pager" -AllowFailure
            Warn "Gateway did not become healthy. Review the log captured above and in the toolkit log."
            return $false
        }
    }
    return $true
}

function Get-NewestArchive([string]$Folder) {
    $files = Get-ChildItem -LiteralPath $Folder -File -Filter "*.tar.gz" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending
    if (-not $files -or $files.Count -eq 0) { return $null }
    return $files[0]
}

function Backup-WindowsNodeState([string]$PackageFolder) {
    Step "Capturing Windows-side OpenClaw node identity and paired credential state"

    $winFolder = Join-Path $PackageFolder "Windows"
    Ensure-Directory $winFolder

    $schtasks = "$env:WINDIR\System32\schtasks.exe"
    $taskWasRunning = $false

    $taskProbe = Invoke-Native -FilePath $schtasks -Arguments @("/Query","/TN","\OpenClaw Node") -AllowFailure -Quiet
    $taskExists = ($taskProbe.ExitCode -eq 0)

    if ($taskExists) {
        $taskQuery = Invoke-Native -FilePath $schtasks -Arguments @("/Query","/TN","\OpenClaw Node","/V","/FO","LIST") -AllowFailure -Quiet
        if ($taskQuery.ExitCode -eq 0) {
            Set-Content -LiteralPath (Join-Path $winFolder "OpenClaw-Node-task.txt") -Value $taskQuery.Output -Encoding UTF8
            $taskWasRunning = ($taskQuery.Output -match "Status:\s+Running")
        }

        $xmlQuery = Invoke-Native -FilePath $schtasks -Arguments @("/Query","/TN","\OpenClaw Node","/XML") -AllowFailure -Quiet
        if ($xmlQuery.ExitCode -eq 0 -and $xmlQuery.Output) {
            Set-Content -LiteralPath (Join-Path $winFolder "OpenClaw-Node-task.xml") -Value $xmlQuery.Output -Encoding Unicode
            Pass "Exported Windows OpenClaw Node Scheduled Task."
        }

        if ($taskWasRunning) {
            Info "Temporarily stopping Windows OpenClaw Node task to snapshot paired identity state."
            Invoke-Native -FilePath $schtasks -Arguments @("/End","/TN","\OpenClaw Node") -AllowFailure -Quiet | Out-Null
            Start-Sleep -Seconds 2
        }
    } else {
        Warn "Windows OpenClaw Node task is not installed; available Windows state will still be captured."
    }

    # Save the public identity metadata separately so restore can verify that
    # the same paired node identity survived migration. This output contains
    # the device id/public identity, not the shared Gateway bearer token.
    if (Test-Command "openclaw") {
        $identity = Invoke-Native -FilePath "openclaw" -Arguments @("node","identity","--json") -AllowFailure -Quiet
        if ($identity.ExitCode -eq 0 -and $identity.Output) {
            Set-Content -LiteralPath (Join-Path $winFolder "node-identity.json") -Value $identity.Output -Encoding UTF8
            Pass "Captured Windows node identity metadata."
        } else {
            Warn "Windows node identity metadata was not available."
        }
    }

    $src = Join-Path $env:USERPROFILE ".openclaw"
    $zip = Join-Path $winFolder "windows-openclaw-state.zip"

    if (Test-Path -LiteralPath $src -PathType Container) {
        if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }

        try {
            Add-Type -AssemblyName System.IO.Compression.FileSystem

            # ZipFile.CreateFromDirectory enumerates the real directory rather
            # than using a PowerShell wildcard, so hidden/system state is not
            # silently omitted. state\openclaw.sqlite carries nodeHost.config,
            # signed device identity and durable paired device auth tokens.
            [System.IO.Compression.ZipFile]::CreateFromDirectory(
                $src,
                $zip,
                [System.IO.Compression.CompressionLevel]::Optimal,
                $false
            )

            if ((Get-Item -LiteralPath $zip).Length -le 0) {
                Fail "Windows state ZIP is empty."
            }

            $zr = [System.IO.Compression.ZipFile]::OpenRead($zip)
            try {
                $dbEntry = @($zr.Entries | Where-Object {
                    $_.FullName.Replace('\','/') -ieq "state/openclaw.sqlite"
                } | Select-Object -First 1)

                if ($dbEntry) {
                    Pass "Captured Windows paired-node SQLite state."
                } else {
                    Warn "Windows state ZIP does not contain state/openclaw.sqlite; automatic node-pairing migration may need bootstrap enrollment."
                }
            } finally {
                $zr.Dispose()
            }

            Pass "Captured complete Windows .openclaw state: $zip"
        } catch {
            Warn "Windows-side state snapshot failed: $($_.Exception.Message)"
        }
    } else {
        Warn "Windows OpenClaw state folder does not exist: $src"
    }

    @'
WINDOWS NODE CREDENTIAL RECOVERY
================================
The main OpenClaw WSL archive already contains the Gateway state/config/credentials,
including configured Gateway authentication secret state.

This Windows snapshot is separate. Its state/openclaw.sqlite contains the Windows
node's signed identity, nodeHost connection metadata, durable paired device token,
and local exec-approval state.

On a new PC, the Hatch IQ restore engine restores this paired node state first.
That lets Windows CUA reconnect with its durable device credential without exposing,
duplicating, or prompting for the shared Gateway bearer token.

If the paired credential is unavailable or no longer valid, the restore engine uses a
short-lived OpenClaw bootstrap/join credential to re-enroll the Windows node. The
shared Gateway token is not written into an extra plaintext file.
'@ | Set-Content -LiteralPath (Join-Path $winFolder "README-NODE-CREDENTIAL-RECOVERY.txt") -Encoding UTF8

    try {
        $proc = Get-CimInstance Win32_Process |
            Where-Object { $_.CommandLine -match 'openclaw.*node run' } |
            Select-Object ProcessId,ParentProcessId,SessionId,CommandLine |
            Format-List | Out-String
        Set-Content -LiteralPath (Join-Path $winFolder "node-processes.txt") -Value $proc -Encoding UTF8
    } catch {}

    if ($taskExists -and $taskWasRunning) {
        Info "Restarting Windows OpenClaw Node task."
        Invoke-Native -FilePath $schtasks -Arguments @("/Run","/TN","\OpenClaw Node") -AllowFailure -Quiet | Out-Null
    }
}

function Write-PackageManifest([string]$PackageFolder, [string]$ArchivePath, [string]$Mode) {
    Step "Writing package manifest and SHA-256 checksums"

    $files = Get-ChildItem -LiteralPath $PackageFolder -File -Recurse |
        Where-Object { $_.Name -ne "package-manifest.json" }

    $hashList = @()
    foreach ($f in $files) {
        $h = Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256
        $rel = $f.FullName.Substring($PackageFolder.Length).TrimStart('\')
        $hashList += [pscustomobject]@{
            path = $rel
            sha256 = $h.Hash.ToLowerInvariant()
            size = $f.Length
        }
    }

    $wslVer = (Invoke-Wsl "openclaw --version" -AllowFailure).Output.Trim()
    $winVer = ""
    if (Test-Command "openclaw") {
        try { $winVer = (& openclaw --version 2>&1) -join " " } catch {}
    }

    $manifest = [ordered]@{
        format = "openclaw-backup-migration-toolkit"
        toolkitVersion = $Script:ToolVersion
        mode = $Mode
        createdUtc = (Get-Date).ToUniversalTime().ToString("o")
        sourceWindowsUser = $env:USERNAME
        sourceComputer = $env:COMPUTERNAME
        wslDistro = $Script:SelectedDistro
        openclawWslVersion = $wslVer
        openclawWindowsVersion = $winVer
        primaryArchive = (Split-Path -Leaf $ArchivePath)
        files = $hashList
    }

    $manifestPath = Join-Path $PackageFolder "package-manifest.json"
    $manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
    Pass "Manifest written: $manifestPath"
}

function Copy-ToolkitIntoPackage([string]$PackageFolder) {
    Step "Bundling full restore/new-PC bootstrap tools"

    $self = $PSCommandPath
    Copy-Item -LiteralPath $self -Destination (Join-Path $PackageFolder "RESTORE-THIS-BACKUP.ps1") -Force
    Copy-Item -LiteralPath $self -Destination (Join-Path $PackageFolder "RESTORE-ON-NEW-PC.ps1") -Force

    $restoreThis = @'
@echo off
setlocal
title OpenClaw Full Restore
cd /d "%~dp0"
set "PACKAGE_DIR=%CD%"
mode con: cols=120 lines=42 >nul 2>&1
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0RESTORE-THIS-BACKUP.ps1" -RestorePackage "%PACKAGE_DIR%"
set "EXITCODE=%ERRORLEVEL%"
echo.
if not "%EXITCODE%"=="0" echo OpenClaw restore exited with code %EXITCODE%.
pause
exit /b %EXITCODE%
'@

    $restoreNew = @'
@echo off
setlocal
title OpenClaw New-PC Migration Restore
cd /d "%~dp0"
set "PACKAGE_DIR=%CD%"
mode con: cols=120 lines=42 >nul 2>&1
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0RESTORE-ON-NEW-PC.ps1" -RestorePackage "%PACKAGE_DIR%" -NewPC
set "EXITCODE=%ERRORLEVEL%"
echo.
if not "%EXITCODE%"=="0" echo OpenClaw new-PC restore exited with code %EXITCODE%.
pause
exit /b %EXITCODE%
'@

    $checkNew = @'
@echo off
setlocal
title OpenClaw New-PC Prerequisite Check
cd /d "%~dp0"
set "PACKAGE_DIR=%CD%"
mode con: cols=120 lines=42 >nul 2>&1
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0RESTORE-ON-NEW-PC.ps1" -RestorePackage "%PACKAGE_DIR%" -NewPC -PrerequisiteCheckOnly
set "EXITCODE=%ERRORLEVEL%"
echo.
if not "%EXITCODE%"=="0" echo OpenClaw prerequisite check exited with code %EXITCODE%.
pause
exit /b %EXITCODE%
'@

    Set-Content -LiteralPath (Join-Path $PackageFolder "RESTORE-THIS-BACKUP.cmd") -Value $restoreThis -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $PackageFolder "RESTORE-ON-NEW-PC.cmd") -Value $restoreNew -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $PackageFolder "CHECK-NEW-PC-PREREQUISITES.cmd") -Value $checkNew -Encoding ASCII

    $launcherTest = @'
@echo off
setlocal
title OpenClaw Restore Launcher Test
cd /d "%~dp0"
set "PACKAGE_DIR=%CD%"
if not exist "%PACKAGE_DIR%\package-manifest.json" (
  echo [FAIL] package-manifest.json was not found beside this launcher.
  pause
  exit /b 1
)
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$p=$env:PACKAGE_DIR; try { $f=[IO.Path]::GetFullPath($p); if(-not(Test-Path -LiteralPath (Join-Path $f 'package-manifest.json'))){exit 2}; Write-Host '[PASS] Restore package path parses correctly:' $f -ForegroundColor Green; exit 0 } catch { Write-Host '[FAIL]' $_.Exception.Message -ForegroundColor Red; exit 3 }"
set "EXITCODE=%ERRORLEVEL%"
pause
exit /b %EXITCODE%
'@
    Set-Content -LiteralPath (Join-Path $PackageFolder "TEST-RESTORE-LAUNCHER.cmd") -Value $launcherTest -Encoding ASCII

    @'
OPENCLAW FULL RESTORE / NEW-PC MIGRATION
========================================

Same-PC or already-prepared computer:
  Double-click RESTORE-THIS-BACKUP.cmd

Fresh/new Windows 11 computer:
  Double-click RESTORE-ON-NEW-PC.cmd

Optional launcher/path test (does not install or restore anything):
  Double-click TEST-RESTORE-LAUNCHER.cmd

Optional new-PC readiness test without restoring:
  Double-click CHECK-NEW-PC-PREREQUISITES.cmd

NEW-PC bootstrap checks BEFORE live state is restored:
- WSL / WSL2 availability
- a usable Linux distribution (Ubuntu 24.04 is installed automatically when no distro exists)
- systemd inside WSL
- Linux utilities needed by restore
- OpenClaw + compatible local Node runtime inside WSL
- native Windows OpenClaw CLI + Node runtime
- package checksums and OpenClaw archive verification

If an automatic prerequisite install cannot complete:
- the tool DOES NOT continue into a partial restore;
- it creates RESTORE-FALLBACK-INSTRUCTIONS.txt and CONTINUE-RESTORE.cmd under
  Documents\OpenClaw-Restore-Logs\<run>;
- follow those exact manual steps, then run CONTINUE-RESTORE.cmd;
- the rerun rechecks every prerequisite and then continues the automated restore.

A WSL/Windows-feature installation can legitimately require a Windows restart.
The resume CMD is specifically there for that case.

AFTER RESTORE: CONNECT WINDOWS HUB / OPENCLAW COMPANION
--------------------------------------------------------
If OpenClaw Companion says "No gateway yet" or "Disconnected":

1. DO NOT click "Install" under "Get started: install a local gateway".
   The restored Gateway already exists inside WSL.

2. Click "Setup code" under "Or connect to an existing one".

3. Open the restored WSL distro:
     wsl.exe -d <restored-distro-name>

4. Inside WSL run:
     ~/.openclaw/bin/openclaw qr --setup-code-only --url ws://127.0.0.1:18789

5. Paste the resulting short-lived setup code into OpenClaw Companion.

6. If approval is pending, inside WSL run:
     ~/.openclaw/bin/openclaw devices list
     ~/.openclaw/bin/openclaw devices approve <deviceRequestId>

7. Windows node mode has a separate command-surface approval:
     ~/.openclaw/bin/openclaw nodes pending
     ~/.openclaw/bin/openclaw nodes approve <nodeRequestId>

8. Verify:
     ~/.openclaw/bin/openclaw nodes status
     ~/.openclaw/bin/openclaw nodes describe --node "Windows CUA"

Alternative Direct method:
- URL: ws://127.0.0.1:18789
- Token: run ~/.openclaw/bin/openclaw gateway auth-token --show interactively inside WSL.

Prefer Setup code because it uses a short-lived bootstrap credential instead of requiring
you to copy the shared Gateway bearer token.

The restore also writes CONNECT-WINDOWS-HUB.txt into the external restore-log folder with
the exact WSL distro name used on that PC.

At the very end of a successful NEW-PC migration, if Windows Hub is installed, the toolkit
also mints a fresh short-lived Setup code automatically and prints it prominently for
copy/paste into OpenClaw Companion. The transcript is stopped before the code is minted, so
the short-lived bootstrap credential is not written into tool-run.log.

Keep this package private. It contains sensitive OpenClaw state and credentials.
'@ | Set-Content -LiteralPath (Join-Path $PackageFolder "README-RESTORE.txt") -Encoding UTF8

    Pass "Full restore and new-PC bootstrap scripts bundled."
}

function New-FullBackup {
    param([switch]$MigrationKit)

    Write-Banner
    Select-WslDistro
    if (-not (Test-OpenClawWsl)) {
        Fail "OpenClaw must already be installed on the source machine to create a backup."
    }

    $stamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
    $kind = if ($MigrationKit) { "MigrationKit" } else { "FullBackup" }
    $package = Join-Path $BackupRoot "OpenClaw_${kind}_$stamp"
    $payload = Join-Path $package "Payload"
    Ensure-Directory $payload
    $Script:ActivePackageFolder = $package
    Start-RunLog $package

    $gatewayWasActive = $false
    try {
        Step "Source preflight"
        Test-GatewayDeep -AllowFailure | Out-Null

        $bkHelp = Invoke-Wsl "openclaw backup create --help >/dev/null 2>&1" -AllowFailure
        if ($bkHelp.ExitCode -ne 0) {
            Fail "This OpenClaw CLI does not expose 'openclaw backup create'. Update OpenClaw before using this toolkit."
        }
        Pass "OpenClaw backup command is available."
        Pass "Windows backup package directory is ready: $payload"

        $gatewayWasActive = Stop-GatewayForBackup

        Step "Creating supported OpenClaw full archive"

        # Create the archive on the native WSL filesystem first.
        # This avoids Windows/WSL metadata visibility quirks and lets us trust
        # OpenClaw's exact JSON archivePath instead of guessing by scanning.
        $stageStamp = Get-Date -Format "yyyyMMdd-HHmmss"
        $wslStage = "`$HOME/.openclaw-backup-export/$stageStamp"

        $mkStage = Invoke-Wsl "mkdir -p $wslStage" -AllowFailure
        if ($mkStage.ExitCode -ne 0) {
            Fail "Could not create temporary WSL backup staging directory."
        }

        $r = Invoke-Wsl "openclaw backup create --output $wslStage --verify --json" -AllowFailure
        if ($r.ExitCode -ne 0) {
            Fail "OpenClaw backup creation failed. No migration package will be trusted."
        }

        $archivePathWsl = $null
        try {
            $jsonStart = $r.Output.IndexOf("{")
            $jsonEnd = $r.Output.LastIndexOf("}")
            if ($jsonStart -lt 0 -or $jsonEnd -le $jsonStart) {
                Fail "OpenClaw backup output did not contain a JSON result."
            }

            $jsonText = $r.Output.Substring($jsonStart, $jsonEnd - $jsonStart + 1)
            $backupJson = $jsonText | ConvertFrom-Json
            $archivePathWsl = [string]$backupJson.archivePath

            if (-not $backupJson.verified) {
                Fail "OpenClaw created an archive but did not report verified=true."
            }
        } catch {
            Fail "OpenClaw returned backup output, but the JSON result could not be parsed: $($_.Exception.Message)"
        }

        if ([string]::IsNullOrWhiteSpace($archivePathWsl)) {
            Fail "OpenClaw backup result did not contain archivePath."
        }

        Info "OpenClaw reported archive: $archivePathWsl"

        $checkWslArchive = Invoke-Wsl "test -f '$archivePathWsl' && test -s '$archivePathWsl'" -AllowFailure
        if ($checkWslArchive.ExitCode -ne 0) {
            Fail "OpenClaw reported an archive, but it is missing or empty inside WSL: $archivePathWsl"
        }
        Pass "Archive exists and is non-empty inside WSL."

        Step "Independent OpenClaw backup verification"
        $vr = Invoke-Wsl "openclaw backup verify '$archivePathWsl' --json" -AllowFailure
        if ($vr.ExitCode -ne 0) {
            Fail "Independent backup verification failed."
        }
        Pass "OpenClaw archive verification passed."

        Step "Exporting verified archive to Windows"

        $archiveName = [System.IO.Path]::GetFileName($archivePathWsl)
        if ([string]::IsNullOrWhiteSpace($archiveName)) {
            Fail "Could not determine backup archive filename from: $archivePathWsl"
        }

        $archivePathWin = Join-Path $payload $archiveName
        $archive = Copy-WslFileToWindowsRaw -WslSource $archivePathWsl -WindowsDestination $archivePathWin

        if (-not $archive -or $archive.Length -lt 1024) {
            Fail "Exported Windows archive is missing or unexpectedly small."
        }

        Pass "Verified OpenClaw archive exported to Windows:"
        Write-Host "  $($archive.FullName)" -ForegroundColor Green
        Pass "Payload is non-empty: $([math]::Round($archive.Length / 1MB, 2)) MiB"

        # The Windows copy is now byte-for-byte verified, so WSL staging can be removed.
        Invoke-Wsl "rm -rf $wslStage" -AllowFailure | Out-Null

        Backup-WindowsNodeState $package

        # BOTH a normal full backup and a migration kit are independently restorable.
        Copy-ToolkitIntoPackage $package

        if ($MigrationKit) {
            @"
OPENCLAW MIGRATION KIT
======================

1. Prefer the single portable ZIP created on the Windows Desktop. Copy that ZIP to the new PC using an encrypted/protected drive or other trusted channel, then extract it.
2. On the new PC, extract the ZIP and double-click RESTORE-ON-NEW-PC.cmd.
3. The packaged restore script automatically uses the package beside it.
4. The tool verifies SHA-256 checksums, ensures WSL/OpenClaw exist, restores the WSL archive into staging,
   activates the recorded state/workspace assets, runs Doctor, installs/rebuilds the Gateway service,
   and attempts to recreate the Windows CUA node service.
5. After the migration reports COMPLETE, connect OpenClaw Windows Hub / Companion to the restored WSL Gateway:
   - launch OpenClaw Companion;
   - DO NOT choose "Install a local gateway";
   - choose "Setup code" under "connect to an existing one";
   - inside the restored WSL distro run:
       ~/.openclaw/bin/openclaw qr --setup-code-only --url ws://127.0.0.1:18789
   - paste that short-lived setup code into the Companion;
   - approve device/node requests from WSL if prompted:
       ~/.openclaw/bin/openclaw devices list
       ~/.openclaw/bin/openclaw devices approve <deviceRequestId>
       ~/.openclaw/bin/openclaw nodes pending
       ~/.openclaw/bin/openclaw nodes approve <nodeRequestId>
   - verify Windows CUA:
       ~/.openclaw/bin/openclaw nodes status
       ~/.openclaw/bin/openclaw nodes describe --node "Windows CUA"

6. The restore writes CONNECT-WINDOWS-HUB.txt into Documents\OpenClaw-Restore-Logs\<run> with the exact distro name.
7. At the very end of a successful migration, the toolkit automatically prints a fresh short-lived Hub Setup code.
   In OpenClaw Companion choose Connection -> Setup code, paste it, and connect.
   The transcript is stopped before the code is generated, so the bootstrap credential is not persisted in tool-run.log.
8. Keep this folder private: it contains credentials and session history.

The Windows\windows-openclaw-state.zip file contains the source Windows node's paired identity/credential state.
The current restore engine uses that snapshot to recover durable Windows CUA pairing when possible. If the old
pairing is stale, complete the Setup code/device/node approval flow above to establish a fresh valid pairing.
"@ | Set-Content -LiteralPath (Join-Path $package "README-MIGRATION.txt") -Encoding UTF8
        }

        # Finalize the transcript before checksumming/zipping it so package hashes stay stable
        # and the ZIP writer never fights an open log handle.
        Stop-RunLog
        $Script:CurrentLog = $null

        Write-PackageManifest -PackageFolder $package -ArchivePath $archive.FullName -Mode $kind

        Step "Verifying package files against newly-created manifest"
        $check = Test-PackageChecksums $package
        if (-not $check) { Fail "Package checksum self-check failed." }

        $portableZip = Export-PackageZip -PackageFolder $package

        Pass "BACKUP COMPLETE"
        Write-Host ""
        Write-Host "Working package: $package" -ForegroundColor Green
        Write-Host "OpenClaw archive: $($archive.FullName)" -ForegroundColor Green
        Write-Host "Portable ZIP: $portableZip" -ForegroundColor Green
        Write-Host ""
        Warn "The ZIP contains secrets. Store it like a password vault."

    } catch {
        try {
            $failure = @"
BACKUP / MIGRATION PACKAGE CREATION FAILED

Time: $(Get-Date -Format o)

Reason:
$($_.Exception.Message)

The Payload folder is NOT a valid backup unless a verified .tar.gz archive exists there.
See tool-run.log in this folder for the complete transcript.
"@
            Set-Content -LiteralPath (Join-Path $package "BACKUP_FAILED.txt") -Value $failure -Encoding UTF8

            $payloadFiles = @(Get-ChildItem -LiteralPath $payload -File -ErrorAction SilentlyContinue)
            if ($payloadFiles.Count -eq 0) {
                Set-Content -LiteralPath (Join-Path $payload "NO_BACKUP_EXPORTED.txt") `
                    -Value "No verified archive is present in the Windows Payload folder. The OpenClaw archive may still exist in temporary WSL staging if the raw binary export failed. See ..\BACKUP_FAILED.txt and ..\tool-run.log." `
                    -Encoding UTF8
            }
        } catch {}
        throw
    } finally {
        $Script:ActivePackageFolder = $null
        if ($gatewayWasActive) {
            Start-GatewayAndVerify | Out-Null
        }
        Stop-RunLog
    }
}

function Test-PackageChecksums([string]$PackageFolder) {
    $manifestPath = Join-Path $PackageFolder "package-manifest.json"
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        Warn "No package-manifest.json found."
        return $false
    }

    try {
        $m = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    } catch {
        Warn "Package manifest is invalid JSON: $($_.Exception.Message)"
        return $false
    }

    $ok = $true
    foreach ($entry in $m.files) {
        $path = Join-Path $PackageFolder $entry.path
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            Warn "Missing package file: $($entry.path)"
            $ok = $false
            continue
        }
        $h = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($h -ne $entry.sha256.ToLowerInvariant()) {
            Warn "Checksum mismatch: $($entry.path)"
            $ok = $false
        }
    }
    if ($ok) { Pass "All package SHA-256 checksums match." }
    return $ok
}

function Resolve-PackageFolder {
    # Packaged restore scripts live inside the extracted backup package.
    # Prefer that directory whenever it contains the manifest. This makes the
    # restore immune to CMD trailing-backslash quoting problems and lets the
    # script recover even if a caller supplied a malformed -RestorePackage value.
    $scriptDir = $null
    try {
        $scriptDir = [System.IO.Path]::GetFullPath($PSScriptRoot)
    } catch {
        $scriptDir = Split-Path -Parent $PSCommandPath
    }

    $scriptManifest = Join-Path $scriptDir "package-manifest.json"
    if (Test-Path -LiteralPath $scriptManifest -PathType Leaf) {
        if (-not [string]::IsNullOrWhiteSpace($RestorePackage)) {
            try {
                $candidate = $RestorePackage.Trim().Trim('"')
                $candidate = [System.IO.Path]::GetFullPath($candidate)
                $candidateManifest = Join-Path $candidate "package-manifest.json"

                if ((Test-Path -LiteralPath $candidate -PathType Container) -and
                    (Test-Path -LiteralPath $candidateManifest -PathType Leaf)) {
                    Pass "Using packaged restore source: $candidate"
                    return $candidate
                }

                Warn "Supplied restore path is not a valid package; using the package beside this restore script."
            } catch {
                Warn "Supplied restore path is malformed; using the package beside this restore script."
            }
        }

        Pass "Using restore package beside script: $scriptDir"
        return $scriptDir
    }

    if (-not [string]::IsNullOrWhiteSpace($RestorePackage)) {
        try {
            $candidate = $RestorePackage.Trim().Trim('"')
            $forced = [System.IO.Path]::GetFullPath($candidate)
        } catch {
            Fail "Restore package path is invalid: $RestorePackage"
        }

        if (-not (Test-Path -LiteralPath $forced -PathType Container)) {
            Fail "Restore package folder does not exist: $forced"
        }
        if (-not (Test-Path -LiteralPath (Join-Path $forced "package-manifest.json") -PathType Leaf)) {
            Fail "Restore package does not contain package-manifest.json: $forced"
        }

        Pass "Using packaged restore source: $forced"
        return $forced
    }

    # Interactive toolkit restore: if the toolkit itself is not inside a package,
    # allow the user to choose an extracted backup/migration package.
    Add-Type -AssemblyName System.Windows.Forms
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = "Select the extracted OpenClaw backup/migration folder containing package-manifest.json"
    $dlg.ShowNewFolderButton = $false
    if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
        Fail "No restore package selected."
    }

    $selected = [System.IO.Path]::GetFullPath($dlg.SelectedPath)
    if (-not (Test-Path -LiteralPath (Join-Path $selected "package-manifest.json") -PathType Leaf)) {
        Fail "Selected folder does not contain package-manifest.json: $selected"
    }
    return $selected
}


function New-RestoreSupportFolder {
    $root = Join-Path $env:USERPROFILE "Documents\OpenClaw-Restore-Logs"
    $folder = Join-Path $root ("Prerequisites_" + (Get-Date -Format "yyyy-MM-dd_HH-mm-ss"))
    Ensure-Directory $folder
    $Script:RestoreSupportFolder = $folder
    return $folder
}

function Write-RestoreFallbackGuide {
    param(
        [Parameter(Mandatory=$true)][string]$SupportFolder,
        [Parameter(Mandatory=$true)][string]$PackageFolder,
        [Parameter(Mandatory=$true)][string]$Problem,
        [Parameter(Mandatory=$false)][string[]]$ManualSteps = @()
    )

    Ensure-Directory $SupportFolder
    $guide = Join-Path $SupportFolder "RESTORE-FALLBACK-INSTRUCTIONS.txt"
    $continue = Join-Path $SupportFolder "CONTINUE-RESTORE.cmd"

    $lines = @(
        "OPENCLAW RESTORE - MANUAL FALLBACK",
        "==================================",
        "",
        "Problem:",
        $Problem,
        "",
        "The backup/migration package has NOT been activated or partially restored by this prerequisite failure.",
        "Complete the steps below, then run CONTINUE-RESTORE.cmd.",
        ""
    )

    if ($ManualSteps -and $ManualSteps.Count -gt 0) {
        $lines += "Manual steps:"
        $n = 1
        foreach ($s in $ManualSteps) {
            $lines += ("{0}. {1}" -f $n, $s)
            $n++
        }
        $lines += ""
    }

    $lines += @(
        "Package:",
        $PackageFolder,
        "",
        "Resume:",
        $continue
    )
    Set-Content -LiteralPath $guide -Value $lines -Encoding UTF8

    $restorePs1 = Join-Path $PackageFolder "RESTORE-THIS-BACKUP.ps1"
    if (-not (Test-Path -LiteralPath $restorePs1 -PathType Leaf)) {
        $restorePs1 = $PSCommandPath
    }

    $newPcSwitch = if ($NewPC) { " -NewPC" } else { "" }
    $cmd = @"
@echo off
setlocal
title Continue OpenClaw Restore
set "PACKAGE_DIR=$PackageFolder"
set "RESTORE_SCRIPT=$restorePs1"
cd /d "%PACKAGE_DIR%"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%RESTORE_SCRIPT%" -RestorePackage "%PACKAGE_DIR%"$newPcSwitch
set "EXITCODE=%ERRORLEVEL%"
echo.
if not "%EXITCODE%"=="0" echo OpenClaw restore exited with code %EXITCODE%.
pause
exit /b %EXITCODE%
"@
    Set-Content -LiteralPath $continue -Value $cmd -Encoding ASCII

    Write-Host ""
    Warn $Problem
    Write-Host "Fallback guide: $guide" -ForegroundColor Yellow
    Write-Host "After fixing the prerequisite, run: $continue" -ForegroundColor Yellow
}

function Normalize-WslDistroName {
    param([Parameter(Mandatory=$false)][string]$Name)

    if ($null -eq $Name) { return "" }

    # Remove NULs, BOM/zero-width format characters, and other Unicode control/
    # format characters that can appear when wsl.exe UTF-16 output is captured
    # by Windows PowerShell 5.1.
    $n = [string]$Name
    $n = $n -replace "`0", ""
    $n = $n -replace "[\uFEFF\u200B\u200C\u200D\u2060]", ""
    $n = [regex]::Replace($n, "\p{C}", "")
    return $n.Trim()
}

function Get-WslDistroNames {
    $wslExe = "$env:WINDIR\System32\wsl.exe"
    if (-not (Test-Path -LiteralPath $wslExe)) { return @() }

    $r = Invoke-Native -FilePath $wslExe -Arguments @("-l","-q") -AllowFailure -Quiet
    if ($r.ExitCode -ne 0) { return @() }

    $seen = New-Object System.Collections.Generic.HashSet[string]([StringComparer]::OrdinalIgnoreCase)
    $result = New-Object System.Collections.Generic.List[string]

    foreach ($line in ($r.Output -split "`r?`n")) {
        $name = Normalize-WslDistroName $line
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        if ($seen.Add($name)) { $result.Add($name) }
    }

    return @($result)
}

function Test-WslDistroLaunch {
    param([Parameter(Mandatory=$true)][string]$DistroName)

    $name = Normalize-WslDistroName $DistroName
    if ([string]::IsNullOrWhiteSpace($name)) { return $false }

    $wslExe = "$env:WINDIR\System32\wsl.exe"

    # Normal WSL distro names are ASCII without spaces. If a custom distro name
    # contains whitespace, use the existing Windows argument quoting helper.
    if ($name -match '^[A-Za-z0-9._-]+$') {
        $nameArg = $name
    } else {
        $nameArg = Quote-WindowsArgument $name
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $wslExe
    $psi.Arguments = "-d $nameArg --exec /bin/true"
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true

    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    try {
        if (-not $p.Start()) { return $false }
        $outTask = $p.StandardOutput.ReadToEndAsync()
        $errTask = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit(15000)) {
            try { $p.Kill() } catch {}
            return $false
        }
        $null = $outTask.Result
        $null = $errTask.Result
        return ($p.ExitCode -eq 0)
    } catch {
        return $false
    } finally {
        try { $p.Dispose() } catch {}
    }
}

function Resolve-WorkingWslDistro {
    # First normalize/re-test the already selected distro.
    $selected = Normalize-WslDistroName $Script:SelectedDistro
    if ($selected) {
        if ($selected -ne $Script:SelectedDistro) {
            Warn "Normalized hidden/control characters out of WSL distro name."
        }
        $Script:SelectedDistro = $selected

        if (Test-WslDistroLaunch $selected) {
            Pass "WSL distro launch probe succeeded: $selected"
            return $true
        }

        Warn "WSL lists '$selected', but a direct launch probe failed. Refreshing distro list."
    }

    $distros = @(Get-WslDistroNames)
    if ($distros.Count -eq 0) { return $false }

    # Prefer toolkit topology names, then test every listed distro.
    $ordered = @()
    foreach ($preferred in @("OpenClawGateway","Ubuntu-24.04")) {
        if ($distros -contains $preferred) { $ordered += $preferred }
    }
    foreach ($d in $distros) {
        if ($ordered -notcontains $d) { $ordered += $d }
    }

    foreach ($candidate in $ordered) {
        $candidate = Normalize-WslDistroName $candidate
        if (Test-WslDistroLaunch $candidate) {
            $Script:SelectedDistro = $candidate
            Pass "Selected launchable WSL distro: $candidate"
            return $true
        }
        Warn "Ignoring listed but non-launchable WSL distro: $candidate"
    }

    return $false
}

function Get-AvailableOpenClawDistroName {
    $distros = @(Get-WslDistroNames)

    if ($distros -notcontains "OpenClawGateway") {
        return "OpenClawGateway"
    }

    if (Test-WslDistroLaunch "OpenClawGateway") {
        return "OpenClawGateway"
    }

    for ($i = 2; $i -le 50; $i++) {
        $candidate = "OpenClawGateway-$i"
        if ($distros -notcontains $candidate) { return $candidate }
    }

    Fail "Could not find a free WSL distro name for OpenClawGateway."
}

function Test-IsWindowsAdministrator {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($id)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}


function Get-WindowsNativeArchitecture {
    $arch = $env:PROCESSOR_ARCHITEW6432
    if ([string]::IsNullOrWhiteSpace($arch)) { $arch = $env:PROCESSOR_ARCHITECTURE }

    if ($arch -match '(?i)ARM64') { return "arm64" }
    if ($arch -match '(?i)AMD64|x86_64') { return "amd64" }

    Fail "Unsupported Windows architecture for automatic Ubuntu WSL import: $arch"
}

function Wait-ForWslDistro {
    param(
        [Parameter(Mandatory=$true)][string]$DistroName,
        [int]$TimeoutSeconds = 90
    )

    $DistroName = Normalize-WslDistroName $DistroName
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        if ((Get-WslDistroNames) -contains $DistroName) { return $true }
        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $deadline)

    return $false
}

function Ensure-WslPlatformReadyForImport {
    param(
        [Parameter(Mandatory=$true)][string]$SupportFolder,
        [Parameter(Mandatory=$true)][string]$PackageFolder
    )

    $wslExe = "$env:WINDIR\System32\wsl.exe"
    Step "Checking WSL platform readiness"

    $status = Invoke-Native -FilePath $wslExe -Arguments @("--status") -AllowFailure
    if ($status.ExitCode -eq 0) {
        Pass "WSL platform is ready."
        return
    }

    Warn "WSL exists but Windows features are not ready. Attempting platform-only installation."

    $help = Invoke-Native -FilePath $wslExe -Arguments @("--help") -AllowFailure -Quiet
    if ($help.Output -notmatch '--no-distribution') {
        Write-RestoreFallbackGuide -SupportFolder $SupportFolder -PackageFolder $PackageFolder `
            -Problem "WSL Windows features are not ready and this WSL build does not support automatic platform-only installation." `
            -ManualSteps @(
                "Open PowerShell as Administrator.",
                "Run: wsl --install --no-distribution",
                "Restart Windows if requested.",
                "Run CONTINUE-RESTORE.cmd."
            )
        Fail "WSL Windows features require manual/reboot completion."
    }

    try {
        if (Test-IsWindowsAdministrator) {
            $r = Invoke-Native -FilePath $wslExe -Arguments @("--install","--no-distribution") -AllowFailure
            $installCode = $r.ExitCode
        } else {
            Info "A UAC prompt may appear to enable WSL Windows features."
            $p = Start-Process -FilePath $wslExe -Verb RunAs -ArgumentList @("--install","--no-distribution") -Wait -PassThru
            $installCode = $p.ExitCode
        }
    } catch {
        $installCode = 1
    }

    Start-Sleep -Seconds 4
    $again = Invoke-Native -FilePath $wslExe -Arguments @("--status") -AllowFailure -Quiet
    if ($again.ExitCode -eq 0) {
        Pass "WSL platform became ready without a reboot."
        return
    }

    Write-RestoreFallbackGuide -SupportFolder $SupportFolder -PackageFolder $PackageFolder `
        -Problem "WSL Windows components were installed/updated, but Windows must restart before migration can continue." `
        -ManualSteps @(
            "Restart Windows.",
            "Sign back into the same Windows account.",
            "Run CONTINUE-RESTORE.cmd."
        )
    Fail "WSL platform requires a Windows restart."
}

function Download-OfficialUbuntuWslRootfs {
    param(
        [Parameter(Mandatory=$true)][string]$SupportFolder,
        [Parameter(Mandatory=$true)][string]$PackageFolder
    )

    $arch = Get-WindowsNativeArchitecture
    $baseUrl = "https://cloud-images.ubuntu.com/wsl/releases/noble/current"
    $fileName = if ($arch -eq "arm64") {
        "ubuntu-noble-wsl-arm64-wsl.rootfs.tar.gz"
    } else {
        "ubuntu-noble-wsl-amd64-wsl.rootfs.tar.gz"
    }

    $cacheRoot = Join-Path $env:LOCALAPPDATA "HatchIQ\OpenClaw\WSL-Cache"
    Ensure-Directory $cacheRoot

    $rootfs = Join-Path $cacheRoot $fileName
    $sums = Join-Path $cacheRoot "SHA256SUMS"
    $curl = Join-Path $env:WINDIR "System32\curl.exe"

    Step "Preparing official Ubuntu 24.04 WSL root filesystem"
    Info "Architecture: $arch"
    Info "Canonical source: $baseUrl/$fileName"

    $sumOk = $false
    if (Test-Path -LiteralPath $curl) {
        $sumDl = Invoke-Native -FilePath $curl -Arguments @(
            "-L","--fail","--silent","--show-error",
            "--retry","3","--retry-delay","2",
            "-o",$sums,"$baseUrl/SHA256SUMS"
        ) -AllowFailure
        $sumOk = ($sumDl.ExitCode -eq 0)
    }

    if (-not $sumOk) {
        try {
            Invoke-WebRequest -UseBasicParsing -Uri "$baseUrl/SHA256SUMS" -OutFile $sums -TimeoutSec 60
            $sumOk = $true
        } catch {}
    }

    if (-not $sumOk -or -not (Test-Path -LiteralPath $sums -PathType Leaf)) {
        Write-RestoreFallbackGuide -SupportFolder $SupportFolder -PackageFolder $PackageFolder `
            -Problem "Could not download Canonical's SHA256SUMS file, so the toolkit will not install an unverified Ubuntu image." `
            -ManualSteps @(
                "Confirm Internet access to cloud-images.ubuntu.com.",
                "Run CONTINUE-RESTORE.cmd again.",
                "If your network blocks Canonical cloud images, install Ubuntu manually with: wsl --install --web-download -d Ubuntu-24.04",
                "Then run CONTINUE-RESTORE.cmd."
            )
        Fail "Unable to retrieve Ubuntu rootfs verification metadata."
    }

    $sumText = Get-Content -LiteralPath $sums -Raw
    $escaped = [regex]::Escape($fileName)
    $m = [regex]::Match($sumText, "(?im)^([0-9a-f]{64})\s+\*?$escaped\s*$")
    if (-not $m.Success) {
        Fail "Canonical SHA256SUMS did not contain $fileName"
    }
    $expected = $m.Groups[1].Value.ToLowerInvariant()

    $validCache = $false
    if (Test-Path -LiteralPath $rootfs -PathType Leaf) {
        try {
            $cached = (Get-FileHash -LiteralPath $rootfs -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($cached -eq $expected) {
                $validCache = $true
                Pass "Cached Ubuntu WSL rootfs SHA-256 verified."
            } else {
                Warn "Cached Ubuntu rootfs checksum is wrong; deleting it."
                Remove-Item -LiteralPath $rootfs -Force -ErrorAction SilentlyContinue
            }
        } catch {}
    }

    if (-not $validCache) {
        $downloadOk = $false

        if (Test-Path -LiteralPath $curl) {
            $dl = Invoke-Native -FilePath $curl -Arguments @(
                "-L","--fail","--show-error","--progress-bar",
                "--retry","3","--retry-delay","3",
                "-o",$rootfs,"$baseUrl/$fileName"
            ) -AllowFailure
            $downloadOk = ($dl.ExitCode -eq 0)
        }

        if (-not $downloadOk) {
            Warn "curl.exe could not download the rootfs; trying PowerShell."
            try {
                Invoke-WebRequest -UseBasicParsing -Uri "$baseUrl/$fileName" -OutFile $rootfs -TimeoutSec 1800
                $downloadOk = $true
            } catch {}
        }

        if (-not $downloadOk -or -not (Test-Path -LiteralPath $rootfs -PathType Leaf)) {
            Write-RestoreFallbackGuide -SupportFolder $SupportFolder -PackageFolder $PackageFolder `
                -Problem "Automatic Ubuntu 24.04 WSL rootfs download failed." `
                -ManualSteps @(
                    "Confirm Internet access.",
                    "Try: wsl --install --web-download -d Ubuntu-24.04",
                    "Restart Windows if requested.",
                    "Run CONTINUE-RESTORE.cmd."
                )
            Fail "Ubuntu WSL rootfs download failed."
        }

        $actual = (Get-FileHash -LiteralPath $rootfs -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne $expected) {
            Remove-Item -LiteralPath $rootfs -Force -ErrorAction SilentlyContinue
            Fail "Downloaded Ubuntu rootfs failed Canonical SHA-256 verification."
        }

        Pass "Downloaded Ubuntu WSL rootfs SHA-256 verified."
    }

    $fi = Get-Item -LiteralPath $rootfs
    if ($fi.Length -lt 100MB) {
        Fail "Ubuntu WSL rootfs is unexpectedly small ($($fi.Length) bytes)."
    }

    return $rootfs
}

function Install-OpenClawGatewayDistroByImport {
    param(
        [Parameter(Mandatory=$true)][string]$SupportFolder,
        [Parameter(Mandatory=$true)][string]$PackageFolder
    )

    $wslExe = "$env:WINDIR\System32\wsl.exe"
    $distroName = Get-AvailableOpenClawDistroName

    if ((Get-WslDistroNames) -contains $distroName -and (Test-WslDistroLaunch $distroName)) {
        $Script:SelectedDistro = $distroName
        Pass "$distroName is already registered and launchable."
        return
    }

    Ensure-WslPlatformReadyForImport -SupportFolder $SupportFolder -PackageFolder $PackageFolder
    $rootfs = Download-OfficialUbuntuWslRootfs -SupportFolder $SupportFolder -PackageFolder $PackageFolder

    $baseInstall = Join-Path $env:LOCALAPPDATA "HatchIQ\OpenClaw\WSL"
    Ensure-Directory $baseInstall
    $installLocation = Join-Path $baseInstall ("OpenClawGateway-" + (Get-Date -Format "yyyyMMdd-HHmmss"))
    Ensure-Directory $installLocation

    Step "Importing Ubuntu 24.04 as OpenClawGateway"
    Info "Install location: $installLocation"
    Info "Using wsl --import so Microsoft Store/first-launch registration is not required."

    $import = Invoke-Native -FilePath $wslExe -Arguments @(
        "--import",$distroName,$installLocation,$rootfs,"--version","2"
    ) -AllowFailure

    if ($import.ExitCode -ne 0) {
        if ($import.Output -match '(?i)reboot|restart|optional component|Virtual Machine Platform|WSL_E_WSL_OPTIONAL_COMPONENT_REQUIRED') {
            Write-RestoreFallbackGuide -SupportFolder $SupportFolder -PackageFolder $PackageFolder `
                -Problem "Ubuntu import is blocked until Windows finishes enabling WSL/Virtual Machine Platform." `
                -ManualSteps @(
                    "Restart Windows.",
                    "Run CONTINUE-RESTORE.cmd."
                )
            Fail "Windows restart required before Ubuntu import."
        }

        Write-RestoreFallbackGuide -SupportFolder $SupportFolder -PackageFolder $PackageFolder `
            -Problem "Automatic Ubuntu WSL import failed." `
            -ManualSteps @(
                "Run: wsl --status",
                "If Windows reports WSL features are incomplete, open PowerShell as Administrator and run: wsl --install --no-distribution",
                "Restart Windows if requested.",
                "Run CONTINUE-RESTORE.cmd."
            )
        Fail "Ubuntu WSL import failed."
    }

    if (-not (Wait-ForWslDistro -DistroName $distroName -TimeoutSeconds 60)) {
        Write-RestoreFallbackGuide -SupportFolder $SupportFolder -PackageFolder $PackageFolder `
            -Problem "wsl --import returned success, but OpenClawGateway did not become visible in the WSL registry." `
            -ManualSteps @(
                "Run: wsl -l -v",
                "Restart Windows if OpenClawGateway is not listed.",
                "Run CONTINUE-RESTORE.cmd."
            )
        Fail "Imported OpenClawGateway did not register."
    }

    $Script:SelectedDistro = $distroName
    $Script:RestoreInstalledDistro = $true
    Pass "Ubuntu 24.04 imported and registered as OpenClawGateway."
}

function Initialize-NewOpenClawWslDistro {
    param(
        [Parameter(Mandatory=$true)][string]$DistroName,
        [Parameter(Mandatory=$true)][string]$SupportFolder,
        [Parameter(Mandatory=$false)][string]$PackageFolder = ""
    )

    if ([string]::IsNullOrWhiteSpace($PackageFolder)) { $PackageFolder = $RestorePackage }

    Step "Initializing imported OpenClawGateway distro"
    $wslExe = "$env:WINDIR\System32\wsl.exe"

    $initScript = @'
set -e

if ! command -v useradd >/dev/null 2>&1; then
  echo "useradd is missing"
  exit 41
fi

if ! id openclaw >/dev/null 2>&1; then
  useradd -m -s /bin/bash openclaw
fi

mkdir -p /home/openclaw
chown -R openclaw:openclaw /home/openclaw

if [ -f /etc/wsl.conf ] && [ ! -f /etc/wsl.conf.hatchiq-pre-restore.bak ]; then
  cp /etc/wsl.conf /etc/wsl.conf.hatchiq-pre-restore.bak
fi

cat >/etc/wsl.conf <<'EOF'
[boot]
systemd=true

[user]
default=openclaw
EOF
'@

    $r = Invoke-Native -FilePath $wslExe -Arguments @(
        "-d",$DistroName,"-u","root","--","bash","-lc",$initScript
    ) -AllowFailure

    if ($r.ExitCode -ne 0) {
        Write-RestoreFallbackGuide -SupportFolder $SupportFolder -PackageFolder $PackageFolder `
            -Problem "OpenClawGateway registered, but user/systemd initialization failed." `
            -ManualSteps @(
                "Run: wsl -d $DistroName -u root",
                "Verify the Ubuntu shell opens.",
                "Exit, then run CONTINUE-RESTORE.cmd."
            )
        Fail "OpenClawGateway initialization failed."
    }

    Invoke-Native -FilePath $wslExe -Arguments @("--terminate",$DistroName) -AllowFailure -Quiet | Out-Null

    # Microsoft documents that WSL config changes may need several seconds after
    # the distro fully stops. Give it enough time before relaunching.
    Start-Sleep -Seconds 10

    $Script:SelectedDistro = $DistroName
    $freshDistroProbeCmd = 'printf "user="; whoami; printf "\npid1="; ps -p 1 -o comm= 2>/dev/null || true'
    $probe = Invoke-Wsl $freshDistroProbeCmd -AllowFailure

    if ($probe.ExitCode -ne 0 -or $probe.Output -notmatch 'user=openclaw') {
        Write-RestoreFallbackGuide -SupportFolder $SupportFolder -PackageFolder $PackageFolder `
            -Problem "OpenClawGateway is installed but the configured default user did not become active." `
            -ManualSteps @(
                "Run: wsl --terminate $DistroName",
                "Wait 10 seconds.",
                "Run: wsl -d $DistroName",
                "Verify a shell opens, then exit.",
                "Run CONTINUE-RESTORE.cmd."
            )
        Fail "OpenClawGateway default-user verification failed."
    }

    Pass "OpenClawGateway default user initialized."
}

function Ensure-WslSystemd {
    param(
        [Parameter(Mandatory=$true)][string]$SupportFolder,
        [Parameter(Mandatory=$true)][string]$PackageFolder
    )

    Step "Checking WSL systemd"

    # Shell-routing self-test. If this prints WSL_REDIRECT_OK, Bash—not Windows
    # PowerShell—handled /dev/null redirection correctly.
    $redirectSelfTestCmd = 'printf "WSL_REDIRECT_OK"; test -r /dev/null >/dev/null 2>&1'
    $redirectSelfTest = Invoke-Wsl $redirectSelfTestCmd -AllowFailure
    if ($redirectSelfTest.ExitCode -ne 0 -or $redirectSelfTest.Output -notmatch 'WSL_REDIRECT_OK') {
        Fail "WSL shell redirection self-test failed before the systemd check."
    }
    Pass "WSL /dev/null redirection is being handled inside Linux."

    # IMPORTANT: keep the Bash command in a SINGLE-QUOTED PowerShell string.
    # PowerShell does not use backslash to escape double quotes. The old form
    # accidentally let PowerShell parse `2>/dev/null` as a Windows redirection
    # and attempted to create C:\dev\null.
    $systemdCheckCmd = 'test "$(ps -p 1 -o comm= 2>/dev/null)" = systemd && systemctl --version >/dev/null 2>&1'
    $check = Invoke-Wsl $systemdCheckCmd -AllowFailure
    if ($check.ExitCode -eq 0) {
        Pass "WSL systemd is enabled."
        return
    }

    Warn "systemd is not active. Attempting automatic WSL systemd configuration."
    $wslExe = "$env:WINDIR\System32\wsl.exe"

    $cfg = @'
set -e
python3 - <<'PY' 2>/dev/null || true
PY
if [ -f /etc/wsl.conf ]; then
  cp /etc/wsl.conf /etc/wsl.conf.openclaw-pre-restore.bak
fi
if grep -q '^\[boot\]' /etc/wsl.conf 2>/dev/null; then
  if grep -q '^systemd=' /etc/wsl.conf 2>/dev/null; then
    sed -i 's/^systemd=.*/systemd=true/' /etc/wsl.conf
  else
    sed -i '/^\[boot\]/a systemd=true' /etc/wsl.conf
  fi
else
  printf '\n[boot]\nsystemd=true\n' >> /etc/wsl.conf
fi
'@

    $cfgResult = Invoke-Native -FilePath $wslExe -Arguments @(
        "-d",$Script:SelectedDistro,"-u","root","--","bash","-lc",$cfg
    ) -AllowFailure

    if ($cfgResult.ExitCode -ne 0) {
        Write-RestoreFallbackGuide -SupportFolder $SupportFolder -PackageFolder $PackageFolder `
            -Problem "The restore tool could not enable systemd inside WSL." `
            -ManualSteps @(
                "Inside the WSL distro, make sure /etc/wsl.conf contains [boot] and systemd=true.",
                "From Windows PowerShell run: wsl --shutdown",
                "Start the distro again.",
                "Run CONTINUE-RESTORE.cmd."
            )
        Fail "WSL systemd configuration failed."
    }

    Invoke-Native -FilePath $wslExe -Arguments @("--terminate",$Script:SelectedDistro) -AllowFailure -Quiet | Out-Null
    Start-Sleep -Seconds 4

    $systemdVerifyCmd = 'test "$(ps -p 1 -o comm= 2>/dev/null)" = systemd && systemctl --version >/dev/null 2>&1'
    $verify = Invoke-Wsl $systemdVerifyCmd -AllowFailure
    if ($verify.ExitCode -ne 0) {
        Write-RestoreFallbackGuide -SupportFolder $SupportFolder -PackageFolder $PackageFolder `
            -Problem "systemd was configured but did not become active after restarting WSL." `
            -ManualSteps @(
                "Restart Windows, or run: wsl --shutdown",
                "Start the WSL distro again.",
                "Verify: ps -p 1 -o comm=   (it should say systemd)",
                "Run CONTINUE-RESTORE.cmd."
            )
        Fail "WSL requires a restart before restore can continue."
    }

    Pass "WSL systemd enabled successfully."
}

function Ensure-LinuxRestorePrerequisites {
    param(
        [Parameter(Mandatory=$true)][string]$SupportFolder,
        [Parameter(Mandatory=$true)][string]$PackageFolder
    )

    Step "Checking Linux restore prerequisites"

    $linuxPrereqProbeCmd = 'for c in bash curl python3 tar gzip sha256sum systemctl; do command -v "$c" >/dev/null 2>&1 || echo "MISSING:$c"; done'
    $probe = Invoke-Wsl $linuxPrereqProbeCmd -AllowFailure
    if ($probe.ExitCode -eq 0 -and $probe.Output -notmatch 'MISSING:') {
        Pass "Required Linux utilities are available."
        return
    }

    Warn "One or more Linux utilities are missing. Attempting automatic package installation."
    $wslExe = "$env:WINDIR\System32\wsl.exe"

    $hasApt = Invoke-Native -FilePath $wslExe -Arguments @(
        "-d",$Script:SelectedDistro,"-u","root","--","bash","-lc","command -v apt-get >/dev/null 2>&1"
    ) -AllowFailure -Quiet

    if ($hasApt.ExitCode -eq 0) {
        $install = Invoke-Native -FilePath $wslExe -Arguments @(
            "-d",$Script:SelectedDistro,"-u","root","--","bash","-lc",
            "apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates python3 tar gzip coreutils dbus-x11 sudo passwd"
        ) -AllowFailure

        if ($install.ExitCode -eq 0) {
            $linuxPrereqVerifyCmd = 'for c in bash curl python3 tar gzip sha256sum systemctl; do command -v "$c" >/dev/null 2>&1 || exit 1; done'
            $again = Invoke-Wsl $linuxPrereqVerifyCmd -AllowFailure
            if ($again.ExitCode -eq 0) {
                Pass "Linux prerequisites installed automatically."
                return
            }
        }
    }

    Write-RestoreFallbackGuide -SupportFolder $SupportFolder -PackageFolder $PackageFolder `
        -Problem "Automatic Linux prerequisite installation failed." `
        -ManualSteps @(
            "Open the selected WSL distro.",
            "For Ubuntu/Debian run: sudo apt-get update",
            "Then run: sudo apt-get install -y curl ca-certificates python3 tar gzip coreutils dbus-x11",
            "Exit WSL and run CONTINUE-RESTORE.cmd."
        )
    Fail "Linux prerequisites require manual installation."
}

function Ensure-WslForRestore {
    param(
        [Parameter(Mandatory=$false)][string]$SupportFolder = "",
        [Parameter(Mandatory=$false)][string]$PackageFolder = ""
    )

    if ([string]::IsNullOrWhiteSpace($SupportFolder)) { $SupportFolder = New-RestoreSupportFolder }
    if ([string]::IsNullOrWhiteSpace($PackageFolder)) { $PackageFolder = $RestorePackage }

    Step "Checking Windows Subsystem for Linux"
    $wslExe = "$env:WINDIR\System32\wsl.exe"

    if (-not (Test-Path -LiteralPath $wslExe)) {
        Write-RestoreFallbackGuide -SupportFolder $SupportFolder -PackageFolder $PackageFolder `
            -Problem "wsl.exe is not present on this Windows installation." `
            -ManualSteps @(
                "Open PowerShell as Administrator.",
                "Run: wsl --install -d Ubuntu-24.04",
                "Restart Windows if requested.",
                "Run CONTINUE-RESTORE.cmd."
            )
        Fail "WSL is unavailable."
    }

    # Update WSL itself on a new PC when possible, but never make an update failure fatal.
    if ($NewPC) {
        Step "Checking for WSL platform updates"
        $update = Invoke-Native -FilePath $wslExe -Arguments @("--update") -AllowFailure
        if ($update.ExitCode -eq 0) { Pass "WSL update check completed." }
        else { Warn "WSL update check did not complete; continuing with the installed WSL platform." }
    }

    $distros = @(Get-WslDistroNames)

    if ($Distro) {
        if ($distros -contains $Distro) {
            $Script:SelectedDistro = $Distro
        } else {
            Fail "Requested WSL distro '$Distro' was not found."
        }
    } elseif ($distros -contains "OpenClawGateway") {
        $Script:SelectedDistro = "OpenClawGateway"
    } elseif ($distros -contains "Ubuntu-24.04") {
        $Script:SelectedDistro = "Ubuntu-24.04"
    } elseif ($distros.Count -eq 1) {
        $Script:SelectedDistro = $distros[0]
    } elseif ($distros.Count -gt 1) {
        Select-WslDistro
    }

    $workingDistro = Resolve-WorkingWslDistro

    if (-not $workingDistro) {
        if ($NewPC) {
            Warn "No listed WSL distro passed a real launch probe."
            Info "Provisioning a fresh dedicated Ubuntu 24.04 OpenClawGateway distro with wsl --import."

            $Script:SelectedDistro = $null
            Install-OpenClawGatewayDistroByImport -SupportFolder $SupportFolder -PackageFolder $PackageFolder
            Initialize-NewOpenClawWslDistro -DistroName $Script:SelectedDistro -SupportFolder $SupportFolder -PackageFolder $PackageFolder

            if (-not (Resolve-WorkingWslDistro)) {
                Fail "Freshly imported OpenClawGateway distro still cannot be launched."
            }
        } else {
            Write-RestoreFallbackGuide -SupportFolder $SupportFolder -PackageFolder $PackageFolder `
                -Problem "WSL distributions are listed, but none can actually be launched." `
                -ManualSteps @(
                    "Run: wsl -l -v",
                    "Try opening the intended distro once.",
                    "Run CONTINUE-RESTORE.cmd."
                )
            Fail "No launchable WSL distro is available."
        }
    }

    Pass "Using WSL distro: $($Script:SelectedDistro)"

    # Confirm the selected distro can execute the real STDIN transport too.
    $shellProbe = Invoke-Wsl "printf 'OPENCLAW_WSL_OK
'; id -u; whoami" -AllowFailure
    if ($shellProbe.ExitCode -ne 0 -or $shellProbe.Output -notmatch 'OPENCLAW_WSL_OK') {
        if ($NewPC) {
            Warn "The selected distro passed /bin/true but failed the Bash STDIN probe. Trying a fresh dedicated OpenClawGateway distro."

            $Script:SelectedDistro = $null
            Install-OpenClawGatewayDistroByImport -SupportFolder $SupportFolder -PackageFolder $PackageFolder
            Initialize-NewOpenClawWslDistro -DistroName $Script:SelectedDistro -SupportFolder $SupportFolder -PackageFolder $PackageFolder

            $shellProbe = Invoke-Wsl "printf 'OPENCLAW_WSL_OK
'; id -u; whoami" -AllowFailure
        }

        if ($shellProbe.ExitCode -ne 0 -or $shellProbe.Output -notmatch 'OPENCLAW_WSL_OK') {
            Write-RestoreFallbackGuide -SupportFolder $SupportFolder -PackageFolder $PackageFolder `
                -Problem "No WSL distro could pass the actual Bash STDIN execution probe." `
                -ManualSteps @(
                    "Run: wsl -l -v",
                    "Run: wsl -d $($Script:SelectedDistro) --exec /bin/true",
                    "Run CONTINUE-RESTORE.cmd."
                )
            Fail "WSL distro cannot execute the restore shell."
        }
    }

    Pass "WSL Bash STDIN execution probe succeeded."

    Ensure-WslSystemd -SupportFolder $SupportFolder -PackageFolder $PackageFolder
    Ensure-LinuxRestorePrerequisites -SupportFolder $SupportFolder -PackageFolder $PackageFolder
}

function Build-WslRestoreScript([string]$PackageFolder, [string]$ArchiveFile) {
    $restoreScript = Join-Path $PackageFolder "_openclaw_restore_wsl.sh"
    $content = @'
#!/usr/bin/env bash
set -Eeuo pipefail

export PATH="$HOME/.openclaw/bin:$HOME/.openclaw/tools/node/bin:$HOME/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
hash -r

ARCHIVE="${1:?archive path required}"
LOG="${2:-$HOME/openclaw-migration-restore.log}"

mkdir -p "$(dirname "$LOG")"
exec > >(tee -a "$LOG") 2>&1

say()  { printf '\n>>> %s\n' "$*"; }
pass() { printf '[PASS] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
die()  { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

trap 'warn "Restore failed at line $LINENO. Existing pre-restore backup/rollback folders were intentionally left in place."' ERR

say "Restore preflight"
command -v curl >/dev/null 2>&1 || die "curl is required"
command -v python3 >/dev/null 2>&1 || die "python3 is required"
test -f "$ARCHIVE" || die "Archive not found: $ARCHIVE"

OC="$HOME/.openclaw/bin/openclaw"

if [[ ! -x "$OC" ]]; then
  say "Installing latest stable OpenClaw"
  curl -fsSL --proto '=https' --tlsv1.2 https://openclaw.ai/install-cli.sh | bash -s -- --runtime-only --version latest
fi

[[ -x "$OC" ]] || die "Native Linux OpenClaw is still not available"
printf '[INFO] Native WSL OpenClaw: %s\n' "$OC"
"$OC" --version
pass "Native WSL OpenClaw CLI available"

say "Verifying archive before touching live state"
"$OC" backup verify "$ARCHIVE" --json
pass "Archive verified"

STAMP="$(date +%Y%m%d-%H%M%S)"
PRER="$HOME/OpenClaw-PreRestore-$STAMP"
STAGE="$HOME/OpenClaw-Restore-Staging-$STAMP"
ROLL="$HOME/OpenClaw-Rollback-$STAMP"
mkdir -p "$PRER" "$ROLL"

say "Stopping Gateway and creating a safety backup of destination state"
"$OC" gateway stop --force >/dev/null 2>&1 || true
for i in $(seq 1 30); do
  state="$(systemctl --user is-active openclaw-gateway.service 2>/dev/null || true)"
  [[ "$state" != "active" && "$state" != "deactivating" ]] && break
  sleep 2
done

if [[ -e "$HOME/.openclaw" ]]; then
  "$OC" backup create --output "$PRER" --verify --json || warn "Destination pre-restore OpenClaw backup could not be created; rollback folder will still be used."
fi

say "Restoring OpenClaw archive to staging"
rm -rf "$STAGE"
"$OC" backup restore "$ARCHIVE" --target "$STAGE"
test -d "$STAGE" || die "Restore staging directory was not created"

MANIFEST="$(find "$STAGE" -name manifest.json -type f -print -quit)"
test -n "$MANIFEST" || die "manifest.json not found in staged restore"
pass "Staged manifest: $MANIFEST"

say "Planning, validating, and transactionally activating restored assets"
python3 - "$MANIFEST" "$ROLL" "$STAGE" "$STAMP" <<'PY'
import json
import os
import shutil
import sys
from pathlib import Path

manifest_path = Path(sys.argv[1]).resolve()
rollback = Path(sys.argv[2]).resolve()
stage_root = Path(sys.argv[3]).resolve()
stamp = sys.argv[4]
manifest_dir = manifest_path.parent
home = Path.home().resolve()

m = json.loads(manifest_path.read_text(encoding="utf-8-sig"))
assets = m.get("assets") or []
if not assets:
    raise SystemExit("No assets[] found in manifest.")

# Infer the old user's home from the state asset where possible.
old_home = None
for a in assets:
    if a.get("kind") == "state":
        sp = str(a.get("sourcePath", ""))
        marker = "/.openclaw"
        if marker in sp:
            old_home = Path(sp.split(marker, 1)[0])
            break

def map_dest(source):
    p = Path(source)
    if old_home:
        try:
            return home / p.relative_to(old_home)
        except Exception:
            pass
    return p

def is_within(path, parent):
    try:
        path.resolve(strict=False).relative_to(parent.resolve(strict=False))
        return True
    except Exception:
        return False

def resolve_archive_path(archive):
    ap = Path(str(archive))
    candidates = []

    if ap.is_absolute():
        candidates.append(ap)
    else:
        # OpenClaw restore currently may keep archivePath prefixed by the backup
        # directory name while placing manifest.json inside that same directory.
        # STAGE/archivePath is therefore the primary candidate.
        candidates.append(stage_root / ap)
        candidates.append(manifest_dir / ap)
        candidates.append(manifest_dir.parent / ap)

        # If archivePath begins with the manifest directory's own name, strip
        # that duplicated prefix and resolve from manifest_dir.
        parts = ap.parts
        if parts and parts[0] == manifest_dir.name and len(parts) > 1:
            candidates.append(manifest_dir.joinpath(*parts[1:]))

    seen = set()
    checked = []
    for c in candidates:
        c = c.resolve(strict=False)
        key = str(c)
        if key in seen:
            continue
        seen.add(key)
        checked.append(c)

        # Staged source material must remain inside the restore staging tree.
        if not is_within(c, stage_root):
            continue
        if c.exists() or c.is_symlink():
            return c

    checked_text = "\n  ".join(str(x) for x in checked)
    raise SystemExit(
        f"Staged asset missing for archivePath={archive!r}. Checked:\n  {checked_text}"
    )

planned = []
for a in assets:
    source = a.get("sourcePath")
    archive = a.get("archivePath")
    kind = a.get("kind", "unknown")
    if not source or not archive:
        continue

    src = resolve_archive_path(archive)
    dst = map_dest(source).resolve(strict=False)
    planned.append({
        "kind": kind,
        "src": src,
        "dst": dst,
        "original": source,
        "archive": archive,
    })

if not planned:
    raise SystemExit("Manifest contained no restorable assets with sourcePath + archivePath.")

# Parent destinations first, then remove child assets covered by a parent.
planned.sort(key=lambda x: (len(str(x["dst"])), str(x["dst"])))
top = []
for item in planned:
    if any(is_within(item["dst"], parent["dst"]) for parent in top):
        print(f"[SKIP] {item['kind']}: {item['dst']} (covered by parent asset)")
        continue
    top.append(item)

# Validate every source BEFORE touching destination state.
for item in top:
    src = item["src"]
    if not src.exists() and not src.is_symlink():
        raise SystemExit(f"Validated staged source disappeared before activation: {src}")
    print(f"[VALID] {item['kind']}: {item['archive']} -> {src}")

# Pre-copy every top-level asset to temporary destination-side paths.
# No existing live destination is moved until ALL copies have succeeded.
prepared = []
try:
    for idx, item in enumerate(top, 1):
        src = item["src"]
        dst = item["dst"]
        dst.parent.mkdir(parents=True, exist_ok=True)

        temp = dst.parent / f".{dst.name}.openclaw-restore-new-{stamp}-{idx}"
        if temp.exists() or temp.is_symlink():
            if temp.is_dir() and not temp.is_symlink():
                shutil.rmtree(temp)
            else:
                temp.unlink()

        print(f"[PREPARE] {item['kind']}: {src} -> {temp}")
        if src.is_dir() and not src.is_symlink():
            shutil.copytree(src, temp, symlinks=True, copy_function=shutil.copy2)
        elif src.is_symlink():
            os.symlink(os.readlink(src), temp)
        else:
            shutil.copy2(src, temp, follow_symlinks=False)

        prepared.append((item, temp))
except Exception:
    for _, temp in prepared:
        try:
            if temp.is_dir() and not temp.is_symlink():
                shutil.rmtree(temp)
            elif temp.exists() or temp.is_symlink():
                temp.unlink()
        except Exception:
            pass
    raise

print(f"[PASS] Prepared {len(prepared)} top-level asset(s) without modifying live state.")

# Swap prepared assets into place. If ANY swap fails, automatically restore
# previously moved live destinations from rollback.
activated = []
try:
    for item, temp in prepared:
        dst = item["dst"]
        original = item["original"]
        kind = item["kind"]

        rb = rollback / Path(str(dst).lstrip("/").replace(":", "_"))
        had_old = dst.exists() or dst.is_symlink()

        print(f"[PLAN] {kind}: {original} -> {dst}")

        if had_old:
            rb.parent.mkdir(parents=True, exist_ok=True)
            if rb.exists() or rb.is_symlink():
                if rb.is_dir() and not rb.is_symlink():
                    shutil.rmtree(rb)
                else:
                    rb.unlink()
            shutil.move(str(dst), str(rb))
            print(f"[ROLLBACK] moved existing {dst} -> {rb}")

        # Same-filesystem rename of the fully prepared replacement.
        os.replace(str(temp), str(dst))
        activated.append((dst, rb, had_old))
        print(f"[ACTIVATE] {dst}")

except Exception as exc:
    print(f"[ERROR] Activation failed: {exc}", file=sys.stderr)
    print("[ROLLBACK] Automatically restoring destinations already swapped.", file=sys.stderr)

    for dst, rb, had_old in reversed(activated):
        try:
            if dst.is_dir() and not dst.is_symlink():
                shutil.rmtree(dst)
            elif dst.exists() or dst.is_symlink():
                dst.unlink()

            if had_old and (rb.exists() or rb.is_symlink()):
                dst.parent.mkdir(parents=True, exist_ok=True)
                shutil.move(str(rb), str(dst))
                print(f"[ROLLBACK] restored {dst}", file=sys.stderr)
        except Exception as rb_exc:
            print(f"[ROLLBACK-WARN] Could not restore {dst}: {rb_exc}", file=sys.stderr)

    # Clean any prepared-but-not-activated temp assets.
    for _, temp in prepared:
        try:
            if temp.is_dir() and not temp.is_symlink():
                shutil.rmtree(temp)
            elif temp.exists() or temp.is_symlink():
                temp.unlink()
        except Exception:
            pass

    raise

print(f"[PASS] Activated {len(activated)} top-level restored asset(s).")
print(f"[INFO] Rollback material: {rollback}")
PY

say "Reinstalling/refreshing latest stable OpenClaw runtime after state activation"
curl -fsSL --proto '=https' --tlsv1.2 https://openclaw.ai/install-cli.sh | bash -s -- --runtime-only --version latest
export PATH="$HOME/.openclaw/bin:$HOME/.openclaw/tools/node/bin:$HOME/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
hash -r
OC="$HOME/.openclaw/bin/openclaw"
[[ -x "$OC" ]] || die "Native Linux OpenClaw unavailable after runtime refresh"
"$OC" --version

say "Running database/config preflight and Doctor"
"$OC" database preflight || warn "Database preflight is unavailable or reported a problem; continuing to Doctor."
"$OC" doctor || die "OpenClaw Doctor failed after restore"

say "Converging installed plugins"
"$OC" update repair || warn "Plugin/update repair reported warnings. Review 'openclaw update status' after migration."

say "Installing/reinstalling WSL Gateway service"
"$OC" gateway install || warn "Gateway service install returned non-zero; existing service may already be present."
systemctl --user start openclaw-gateway.service || "$OC" gateway start || true
sleep 8

say "Final Gateway verification"
if ! "$OC" gateway status --deep; then
  sleep 10
  "$OC" gateway status --deep || {
    journalctl --user -u openclaw-gateway.service -n 100 --no-pager || true
    die "Gateway deep health probe failed after restore."
  }
fi

pass "WSL migration restore completed."
echo "STAGING=$STAGE"
echo "ROLLBACK=$ROLL"
echo "PRERESTORE_BACKUP=$PRER"

'@

    # Windows PowerShell 5.1's `Set-Content -Encoding UTF8` writes a UTF-8 BOM.
    # A BOM before #!/usr/bin/env breaks Linux shebang parsing. Always write the
    # restore shell as UTF-8 WITHOUT BOM.
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($restoreScript, $content, $utf8NoBom)

    return $restoreScript
}

function Refresh-WindowsOpenClawPath {
    # Refresh machine/user PATH, then add common OpenClaw/npm shim locations
    # to THIS process so a just-completed installer is immediately usable.
    $machinePath = [Environment]::GetEnvironmentVariable("Path","Machine")
    $userPath = [Environment]::GetEnvironmentVariable("Path","User")

    $candidateDirs = New-Object System.Collections.Generic.List[string]
    foreach ($p in @($machinePath,$userPath)) {
        if (-not [string]::IsNullOrWhiteSpace($p)) {
            foreach ($part in ($p -split ';')) {
                if (-not [string]::IsNullOrWhiteSpace($part)) {
                    $candidateDirs.Add($part.Trim())
                }
            }
        }
    }

    $candidateDirs.Add((Join-Path $env:APPDATA "npm"))
    $candidateDirs.Add((Join-Path $env:USERPROFILE ".local\bin"))

    if (Test-Command "npm") {
        $prefixResult = Invoke-Native -FilePath "npm" -Arguments @("config","get","prefix") -AllowFailure -Quiet
        if ($prefixResult.ExitCode -eq 0) {
            $prefix = ($prefixResult.Output -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 1)
            if ($prefix) { $candidateDirs.Add($prefix.Trim()) }
        }
    }

    $existing = New-Object System.Collections.Generic.HashSet[string]([StringComparer]::OrdinalIgnoreCase)
    foreach ($p in ($env:PATH -split ';')) {
        if (-not [string]::IsNullOrWhiteSpace($p)) { [void]$existing.Add($p.Trim()) }
    }

    foreach ($dir in $candidateDirs) {
        if ([string]::IsNullOrWhiteSpace($dir)) { continue }
        try {
            $full = [Environment]::ExpandEnvironmentVariables($dir.Trim())
            $isDir = $false
            try { $isDir = Test-Path -LiteralPath $full -PathType Container -ErrorAction SilentlyContinue } catch {}
            if ($isDir -and (-not $existing.Contains($full))) {
                $env:PATH = "$full;$env:PATH"
                [void]$existing.Add($full)
            }
        } catch {}
    }
}

function Find-WindowsOpenClawShim {
    $candidates = @(
        (Join-Path $env:APPDATA "npm\openclaw.cmd"),
        (Join-Path $env:USERPROFILE ".local\bin\openclaw.cmd"),
        (Join-Path $env:USERPROFILE ".local\bin\openclaw.exe")
    )

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }
    return $null
}

function Ensure-WindowsOpenClaw {
    param(
        [Parameter(Mandatory=$false)][string]$SupportFolder = "",
        [Parameter(Mandatory=$false)][string]$PackageFolder = ""
    )

    Step "Checking native Windows OpenClaw CLI"
    Refresh-WindowsOpenClawPath

    if (Test-Command "openclaw") {
        $v = Invoke-Native -FilePath "openclaw" -Arguments @("--version") -AllowFailure -Quiet
        if ($v.ExitCode -eq 0) {
            Pass "Windows OpenClaw CLI available: $($v.Output.Trim())"
            return
        }
    }

    if ([string]::IsNullOrWhiteSpace($SupportFolder)) { $SupportFolder = New-RestoreSupportFolder }
    if ([string]::IsNullOrWhiteSpace($PackageFolder)) { $PackageFolder = $RestorePackage }

    Warn "Windows OpenClaw CLI not found. Installing latest stable OpenClaw automatically."

    $installerDir = Join-Path $env:TEMP ("HatchIQ-OpenClaw-Installer-" + [guid]::NewGuid().ToString("N"))
    $installerFile = Join-Path $installerDir "install.ps1"
    Ensure-Directory $installerDir

    try {
        Step "Downloading official Windows OpenClaw installer"
        Info "Source: https://openclaw.ai/install.ps1"

        # IMPORTANT: download installer bytes to a .ps1 file and execute with -File.
        # Do NOT use Invoke-WebRequest(...).Content -> [scriptblock]::Create(...).
        # On Windows PowerShell 5.1 / some current Windows builds, Content may be a
        # byte[]; coercing it to string becomes decimal byte values like
        # '35 32 79 112 ...', which is invalid PowerShell.
        $downloaded = $false

        try {
            Invoke-WebRequest -UseBasicParsing -Uri "https://openclaw.ai/install.ps1" `
                -OutFile $installerFile -TimeoutSec 90
            $downloaded = $true
        } catch {
            Warn "Invoke-WebRequest download failed: $($_.Exception.Message)"
        }

        if (-not $downloaded) {
            $curl = Join-Path $env:WINDIR "System32\curl.exe"
            if (Test-Path -LiteralPath $curl) {
                $dl = Invoke-Native -FilePath $curl -Arguments @(
                    "-L","--fail","--show-error",
                    "--retry","3","--retry-delay","2",
                    "-o",$installerFile,
                    "https://openclaw.ai/install.ps1"
                ) -AllowFailure
                $downloaded = ($dl.ExitCode -eq 0)
            }
        }

        if (-not $downloaded -or -not (Test-Path -LiteralPath $installerFile -PathType Leaf)) {
            throw "Official OpenClaw installer could not be downloaded."
        }

        $fi = Get-Item -LiteralPath $installerFile
        if ($fi.Length -lt 1024) {
            throw "Downloaded OpenClaw installer is unexpectedly small ($($fi.Length) bytes)."
        }

        # Basic sanity check: make sure the downloaded payload is text PowerShell,
        # not an HTML error page or an array/string conversion artifact.
        $firstLines = (Get-Content -LiteralPath $installerFile -TotalCount 8 -ErrorAction Stop) -join "`n"
        if ($firstLines -match '(?i)<html|<!doctype') {
            throw "Downloaded installer appears to be HTML rather than PowerShell."
        }
        if ($firstLines -match '^\s*\d+\s+\d+\s+\d+') {
            throw "Downloaded installer appears to contain decimal byte values instead of PowerShell source."
        }
        Pass "Official Windows installer downloaded as a real .ps1 file."

        Step "Running official Windows OpenClaw installer"
        $powershellExe = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
        if (-not (Test-Path -LiteralPath $powershellExe -PathType Leaf)) {
            $powershellExe = "powershell.exe"
        }

        # OpenClaw docs explicitly support direct `powershell -File`; direct file mode
        # returns a non-zero exit code for automation if installation fails.
        $installResult = Invoke-Native -FilePath $powershellExe -Arguments @(
            "-NoLogo",
            "-NoProfile",
            "-ExecutionPolicy","Bypass",
            "-File",$installerFile,
            "-NoOnboard"
        ) -AllowFailure

        if ($installResult.ExitCode -ne 0) {
            throw "Official OpenClaw installer exited with code $($installResult.ExitCode)."
        }

        Pass "Official Windows OpenClaw installer completed."
    } catch {
        Warn "Automatic Windows OpenClaw installer failed: $($_.Exception.Message)"
    } finally {
        try { Remove-Item -LiteralPath $installerDir -Recurse -Force -ErrorAction SilentlyContinue } catch {}
    }

    Step "Refreshing Windows PATH after OpenClaw install"
    Refresh-WindowsOpenClawPath

    $shim = Find-WindowsOpenClawShim
    if ($shim) {
        $shimDir = Split-Path -Parent $shim
        if ($env:PATH -notlike "*$shimDir*") {
            $env:PATH = "$shimDir;$env:PATH"
        }
        Info "Detected OpenClaw launcher: $shim"
    }

    if (Test-Command "openclaw") {
        $v = Invoke-Native -FilePath "openclaw" -Arguments @("--version") -AllowFailure -Quiet
        if ($v.ExitCode -eq 0) {
            Pass "Windows OpenClaw installed successfully: $($v.Output.Trim())"
            return
        }
    }

    # If the command name still does not resolve but a known shim exists, invoke
    # that exact shim once so PATH propagation cannot create a false failure.
    if ($shim) {
        $v2 = Invoke-Native -FilePath $shim -Arguments @("--version") -AllowFailure -Quiet
        if ($v2.ExitCode -eq 0) {
            Pass "Windows OpenClaw installed successfully via launcher: $($v2.Output.Trim())"
            return
        }
    }

    Write-RestoreFallbackGuide -SupportFolder $SupportFolder -PackageFolder $PackageFolder `
        -Problem "Automatic Windows OpenClaw installation did not leave a working 'openclaw' command." `
        -ManualSteps @(
            "Open a normal Windows PowerShell window.",
            "Run: iwr -useb https://openclaw.ai/install.ps1 | iex",
            "Or download https://openclaw.ai/install.ps1 to a local file and run: powershell.exe -ExecutionPolicy Bypass -File .\\install.ps1 -NoOnboard",
            "Close and reopen PowerShell.",
            "Verify: openclaw --version",
            "If it is still not recognized, run: npm config get prefix",
            "Add that returned folder to your USER Path, then reopen PowerShell.",
            "Run CONTINUE-RESTORE.cmd."
        )
    Fail "Windows OpenClaw CLI requires manual installation/PATH repair."
}

function Get-JsonStringCandidates {
    param([Parameter(Mandatory=$true)]$Object)

    $results = New-Object System.Collections.Generic.List[string]

    function Walk-JsonValue($Value) {
        if ($null -eq $Value) { return }

        if ($Value -is [string]) {
            $results.Add([string]$Value)
            return
        }

        if ($Value -is [System.Collections.IDictionary]) {
            foreach ($key in $Value.Keys) { Walk-JsonValue $Value[$key] }
            return
        }

        if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
            foreach ($item in $Value) { Walk-JsonValue $item }
            return
        }

        foreach ($prop in $Value.PSObject.Properties) {
            Walk-JsonValue $prop.Value
        }
    }

    Walk-JsonValue $Object
    return @($results)
}

function Restore-WindowsNodePairingState {
    param([Parameter(Mandatory=$true)][string]$PackageFolder)

    if (-not $NewPC) { return $false }

    $snapshot = Join-Path $PackageFolder "Windows\windows-openclaw-state.zip"
    if (-not (Test-Path -LiteralPath $snapshot -PathType Leaf)) {
        Warn "No Windows node-state snapshot is present in this package."
        return $false
    }

    Step "Restoring Windows node paired identity from backup"

    Invoke-Native -FilePath "openclaw" -Arguments @("node","stop") -AllowFailure -Quiet | Out-Null

    # Keep the optional Hub from touching shared Windows OpenClaw state while
    # its node identity database is being replaced.
    try {
        Get-Process -ErrorAction SilentlyContinue | Where-Object {
            $_.ProcessName -match '(?i)^OpenClaw(\.Tray\.WinUI|Tray)?$'
        } | Stop-Process -Force -ErrorAction SilentlyContinue
    } catch {}

    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $extract = Join-Path $Script:RestoreSupportFolder ("WindowsNodeState-" + [guid]::NewGuid().ToString("N"))
    Ensure-Directory $extract

    try {
        [System.IO.Compression.ZipFile]::ExtractToDirectory($snapshot, $extract)

        $sourceDb = Join-Path $extract "state\openclaw.sqlite"
        if (-not (Test-Path -LiteralPath $sourceDb -PathType Leaf)) {
            Warn "The Windows snapshot does not contain state\openclaw.sqlite."
            return $false
        }

        $destRoot = Join-Path $env:USERPROFILE ".openclaw"
        $destState = Join-Path $destRoot "state"
        Ensure-Directory $destState

        # Preserve the newly-created destination state before replacing it.
        $destDb = Join-Path $destState "openclaw.sqlite"
        if (Test-Path -LiteralPath $destDb -PathType Leaf) {
            $safetyDir = Join-Path $Script:RestoreSupportFolder "WindowsNodeState-BeforeRestore"
            Ensure-Directory $safetyDir

            foreach ($name in @("openclaw.sqlite","openclaw.sqlite-wal","openclaw.sqlite-shm")) {
                $candidate = Join-Path $destState $name
                if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                    Copy-Item -LiteralPath $candidate -Destination (Join-Path $safetyDir $name) -Force
                }
            }
        }

        foreach ($name in @("openclaw.sqlite","openclaw.sqlite-wal","openclaw.sqlite-shm")) {
            Remove-Item -LiteralPath (Join-Path $destState $name) -Force -ErrorAction SilentlyContinue
        }

        foreach ($name in @("openclaw.sqlite","openclaw.sqlite-wal","openclaw.sqlite-shm")) {
            $srcFile = Join-Path (Join-Path $extract "state") $name
            if (Test-Path -LiteralPath $srcFile -PathType Leaf) {
                Copy-Item -LiteralPath $srcFile -Destination (Join-Path $destState $name) -Force
            }
        }

        # Include retired identity inputs if they exist. Doctor owns migration
        # of these older layouts and will reconcile them into canonical SQLite.
        $legacyIdentity = Join-Path $extract "identity"
        if (Test-Path -LiteralPath $legacyIdentity -PathType Container) {
            $destIdentity = Join-Path $destRoot "identity"
            if (-not (Test-Path -LiteralPath $destIdentity)) {
                Copy-Item -LiteralPath $legacyIdentity -Destination $destIdentity -Recurse -Force
            }
        }

        foreach ($legacyName in @("node.json")) {
            $legacy = Join-Path $extract $legacyName
            if (Test-Path -LiteralPath $legacy -PathType Leaf) {
                Copy-Item -LiteralPath $legacy -Destination (Join-Path $destRoot $legacyName) -Force
            }
        }

        $doctor = Invoke-Native -FilePath "openclaw" -Arguments @("doctor","--fix") -AllowFailure -Quiet
        if ($doctor.ExitCode -ne 0) {
            Warn "Windows Doctor returned non-zero after restoring node state; continuing to identity verification."
        }

        $identity = Invoke-Native -FilePath "openclaw" -Arguments @("node","identity","--json") -AllowFailure -Quiet
        if ($identity.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($identity.Output)) {
            Warn "Restored Windows node identity could not be verified."
            return $false
        }

        Set-Content -LiteralPath (Join-Path $Script:RestoreSupportFolder "restored-windows-node-identity.json") `
            -Value $identity.Output -Encoding UTF8

        # Compare the source identity metadata when the source backup included it.
        $savedIdentityPath = Join-Path $PackageFolder "Windows\node-identity.json"
        if (Test-Path -LiteralPath $savedIdentityPath -PathType Leaf) {
            try {
                $saved = Get-Content -LiteralPath $savedIdentityPath -Raw | ConvertFrom-Json
                $restored = $identity.Output | ConvertFrom-Json

                $savedStrings = @(Get-JsonStringCandidates $saved)
                $restoredStrings = @(Get-JsonStringCandidates $restored)

                $sharedIds = @($savedStrings | Where-Object {
                    $_ -match '^[0-9a-fA-F]{32,128}$' -and $restoredStrings -contains $_
                })

                if ($sharedIds.Count -gt 0) {
                    Pass "Restored Windows node cryptographic identity matches backup metadata."
                } else {
                    Warn "Windows node identity restored, but source identity metadata could not be matched exactly."
                }
            } catch {
                Warn "Could not compare source/restored Windows node identity JSON."
            }
        }

        Pass "Restored Windows node paired credential state from the backup."
        return $true
    } catch {
        Warn "Windows node paired-state restore failed: $($_.Exception.Message)"
        return $false
    } finally {
        Remove-Item -LiteralPath $extract -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Test-WindowsCuaConnected {
    $r = Invoke-Wsl '"$HOME/.openclaw/bin/openclaw" nodes list --connected --json' -AllowFailure
    if ($r.ExitCode -ne 0) { return $false }
    return ($r.Output -match '(?i)Windows CUA')
}

function Get-AutomaticNodeJoinTarget {
    Step "Minting short-lived Windows node bootstrap credential"

    # First try the node-specific join-code flow. Suppress output because it
    # contains a single-use bootstrap credential.
    $join = Invoke-Wsl `
        -Command '"$HOME/.openclaw/bin/openclaw" devices join-code --json --url ws://127.0.0.1:18789' `
        -AllowFailure -SensitiveOutput

    if ($join.ExitCode -eq 0 -and $join.Output) {
        try {
            $obj = $join.Output | ConvertFrom-Json
            foreach ($s in @(Get-JsonStringCandidates $obj)) {
                if ($s -match '(https?://[^\s"]+/j/[A-Za-z0-9_-]+)') { return $Matches[1] }
                if ($s -match '(oc-pair://[A-Za-z0-9._~:/?#\[\]@!$&''()*+,;=%-]+)') { return $Matches[1] }
            }
        } catch {}
    }

    # Fallback: create a direct setup code with an explicit same-host WSL
    # Gateway endpoint. `openclaw connect` accepts the bare setup code.
    $qr = Invoke-Wsl `
        -Command '"$HOME/.openclaw/bin/openclaw" qr --setup-code-only --url ws://127.0.0.1:18789' `
        -AllowFailure -SensitiveOutput

    if ($qr.ExitCode -eq 0 -and $qr.Output) {
        $candidate = @($qr.Output -split "`r?`n" |
            ForEach-Object { $_.Trim() } |
            Where-Object {
                $_ -and
                $_ -notmatch '^[│◇├╰╭╮╯]' -and
                $_ -notmatch '^(Update history|Recorded warnings|WARNING:)'
            } |
            Select-Object -Last 1)

        if ($candidate) { return [string]$candidate }
    }

    return $null
}

function Enroll-WindowsCuaWithBootstrap {
    Step "Enrolling Windows CUA with a short-lived bootstrap credential"

    $target = Get-AutomaticNodeJoinTarget
    if ([string]::IsNullOrWhiteSpace($target)) {
        Warn "Could not mint a Windows node bootstrap credential automatically."
        return $false
    }

    # Use --target-file so the short-lived bootstrap credential never appears
    # in the Windows child-process command line or transcript.
    $targetFile = Join-Path $env:TEMP ("openclaw-node-join-" + [guid]::NewGuid().ToString("N") + ".txt")
    try {
        [System.IO.File]::WriteAllText(
            $targetFile,
            $target.Trim(),
            (New-Object System.Text.UTF8Encoding -ArgumentList $false)
        )

        Invoke-Native -FilePath "openclaw" -Arguments @("node","stop") -AllowFailure -Quiet | Out-Null
        Invoke-Native -FilePath "openclaw" -Arguments @("node","uninstall") -AllowFailure -Quiet | Out-Null

        $connect = Invoke-Native -FilePath "openclaw" -Arguments @(
            "connect",
            "--target-file",$targetFile,
            "--service",
            "--display-name","Windows CUA",
            "--all-commands"
        ) -AllowFailure -Quiet

        if ($connect.ExitCode -ne 0) {
            Warn "Short-lived Windows node bootstrap enrollment failed."
            return $false
        }

        Start-Sleep -Seconds 6
        if (Test-WindowsCuaConnected) {
            Pass "Windows CUA enrolled with a durable paired-device credential."
            return $true
        }

        Warn "Bootstrap enrollment completed but Windows CUA is not yet connected."
        return $false
    } finally {
        # connect --target-file consumes/removes it on success. Delete it
        # explicitly on all other paths.
        Remove-Item -LiteralPath $targetFile -Force -ErrorAction SilentlyContinue
        $target = $null
    }
}

function Rebuild-WindowsCuaNode {
    param([Parameter(Mandatory=$false)][string]$PackageFolder = "")

    Step "Rebuilding Windows CUA node service without exposing the shared Gateway token"

    Ensure-WindowsOpenClaw -SupportFolder $Script:RestoreSupportFolder -PackageFolder $PackageFolder

    $pairedStateRestored = $false
    if ($NewPC -and -not [string]::IsNullOrWhiteSpace($PackageFolder)) {
        $pairedStateRestored = Restore-WindowsNodePairingState -PackageFolder $PackageFolder
    }

    $enableCua = Invoke-Native -FilePath "openclaw" -Arguments @("plugins","enable","cua-computer") -AllowFailure
    if ($enableCua.ExitCode -ne 0) {
        Warn "Could not enable cua-computer plugin automatically."
    }

    $lintResult = Invoke-Native -FilePath "openclaw" -Arguments @("doctor","--lint","--only","cua-computer/driver-artifacts") -AllowFailure
    if ($lintResult.ExitCode -eq 0) {
        Pass "Windows CUA driver-artifact check completed."
    } else {
        Warn "CUA driver-artifact check returned non-zero."
    }

    # First try the durable paired-device credential already present on this
    # Windows machine or restored from the backup. OpenClaw explicitly prefers
    # the saved paired node credential for the saved Gateway endpoint.
    Invoke-Native -FilePath "openclaw" -Arguments @("node","stop") -AllowFailure -Quiet | Out-Null

    $nodeInstall = Invoke-Native -FilePath "openclaw" -Arguments @(
        "node","install","--force",
        "--host","127.0.0.1",
        "--port","18789",
        "--no-tls",
        "--display-name","Windows CUA",
        "--all-commands"
    ) -AllowFailure

    if ($nodeInstall.ExitCode -eq 0) {
        $nodeStart = Invoke-Native -FilePath "openclaw" -Arguments @("node","start") -AllowFailure
        if ($nodeStart.ExitCode -eq 0) {
            Start-Sleep -Seconds 6
            if (Test-WindowsCuaConnected) {
                if ($pairedStateRestored) {
                    Pass "Windows CUA reconnected using paired credential state restored from the backup."
                } else {
                    Pass "Windows CUA reconnected using its existing durable paired credential."
                }
            }
        }
    } else {
        Warn "Windows node service install returned exit code $($nodeInstall.ExitCode)."
    }

    # If there was no reusable paired credential (or it was revoked), enroll
    # with a short-lived bootstrap credential. This never reveals or persists
    # the shared Gateway token.
    if (-not (Test-WindowsCuaConnected)) {
        Warn "Durable paired node credential was not sufficient; trying automatic bootstrap enrollment."
        $enrolled = Enroll-WindowsCuaWithBootstrap

        if (-not $enrolled) {
            Warn "Automatic Windows node enrollment could not be completed."
            Warn "The restored Gateway credential state is intact; no shared Gateway token has been lost."
            Warn "Manual recovery, if needed: open an interactive WSL terminal and run:"
            Write-Host "  ~/.openclaw/bin/openclaw gateway auth-token --show" -ForegroundColor Yellow
            Write-Host "Then use the Windows Hub Connections/Devices flow or OpenClaw pairing flow." -ForegroundColor Yellow
            return
        }
    }

    Step "Checking Windows CUA from the WSL Gateway"
    $nodes = Invoke-Wsl '"$HOME/.openclaw/bin/openclaw" nodes list --connected --json' -AllowFailure
    if ($nodes.ExitCode -eq 0 -and $nodes.Output -match '(?i)Windows CUA') {
        Pass "Windows CUA is connected to the restored Gateway."
    } else {
        Warn "Windows CUA is not currently shown as connected."
    }

    $pending = Invoke-Wsl '"$HOME/.openclaw/bin/openclaw" nodes pending' -AllowFailure
    if ($pending.Output -and $pending.Output -notmatch "No pending") {
        Warn "A command-surface expansion approval may still be pending; review the output above."
    }

    $desc = Invoke-Wsl '"$HOME/.openclaw/bin/openclaw" nodes describe --node "Windows CUA"' -AllowFailure
    if ($desc.ExitCode -eq 0) {
        $needed = @("system.run","screen.snapshot","computer.act")
        foreach ($n in $needed) {
            if ($desc.Output -match [regex]::Escape($n)) { Pass "Node advertises $n" }
            else { Warn "Node does not currently advertise $n" }
        }
    }
}

function Get-WindowsHubExecutable {
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA "OpenClawTray\OpenClaw.Tray.WinUI.exe"),
        (Join-Path $env:LOCALAPPDATA "Programs\OpenClaw\OpenClaw.Tray.WinUI.exe")
    )

    foreach ($candidate in $candidates) {
        try {
            if (Test-Path -LiteralPath $candidate -PathType Leaf -ErrorAction SilentlyContinue) {
                return $candidate
            }
        } catch {}
    }
    return $null
}

function Ensure-WindowsHub {
    param(
        [Parameter(Mandatory=$false)][string]$SupportFolder = "",
        [Parameter(Mandatory=$false)][string]$PackageFolder = ""
    )

    Step "Checking OpenClaw Windows Hub companion"

    $existing = Get-WindowsHubExecutable
    if ($existing) {
        Pass "OpenClaw Windows Hub is installed: $existing"
        return
    }

    if (-not $NewPC) {
        Warn "OpenClaw Windows Hub is not installed. It is optional for CLI-only restore."
        return
    }

    if ([string]::IsNullOrWhiteSpace($SupportFolder)) { $SupportFolder = New-RestoreSupportFolder }
    if ([string]::IsNullOrWhiteSpace($PackageFolder)) { $PackageFolder = $RestorePackage }

    Info "Installing the native OpenClaw Windows Hub companion for GUI/tray/chat/node mode."

    $arch = $env:PROCESSOR_ARCHITEW6432
    if ([string]::IsNullOrWhiteSpace($arch)) { $arch = $env:PROCESSOR_ARCHITECTURE }

    if ($arch -match '(?i)ARM64') { $hubArch = "arm64" }
    else { $hubArch = "x64" }

    $releaseApi = "https://api.github.com/repos/openclaw/openclaw-windows-node/releases/latest"
    $installerName = "OpenClawCompanion-Setup-$hubArch.exe"

    $tempDir = Join-Path $env:TEMP ("HatchIQ-OpenClawHub-" + [guid]::NewGuid().ToString("N"))
    Ensure-Directory $tempDir

    $installer = Join-Path $tempDir $installerName
    $releaseJson = Join-Path $tempDir "latest-release.json"
    $curl = Join-Path $env:WINDIR "System32\curl.exe"

    try {
        if (-not (Test-Path -LiteralPath $curl -PathType Leaf)) {
            throw "Windows curl.exe is unavailable."
        }

        Step "Reading official OpenClaw Windows Hub release metadata"
        $metaDownload = Invoke-Native -FilePath $curl -Arguments @(
            "-L","--fail","--silent","--show-error",
            "--retry","3","--retry-delay","2",
            "-H","Accept: application/vnd.github+json",
            "-H","X-GitHub-Api-Version: 2022-11-28",
            "-o",$releaseJson,
            $releaseApi
        ) -AllowFailure

        if ($metaDownload.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $releaseJson -PathType Leaf)) {
            throw "Could not retrieve official Windows Hub release metadata from GitHub."
        }

        try {
            $release = Get-Content -LiteralPath $releaseJson -Raw -ErrorAction Stop | ConvertFrom-Json
        } catch {
            throw "Windows Hub release metadata was not valid JSON: $($_.Exception.Message)"
        }

        $asset = @($release.assets | Where-Object { $_.name -eq $installerName } | Select-Object -First 1)
        if (-not $asset -or [string]::IsNullOrWhiteSpace([string]$asset.browser_download_url)) {
            throw "The latest Windows Hub release does not contain $installerName."
        }

        $downloadUrl = [string]$asset.browser_download_url
        $expectedDigest = [string]$asset.digest
        $releaseTag = [string]$release.tag_name

        Info "Windows Hub release: $releaseTag"
        Info "Installer asset: $installerName"

        Step "Downloading signed OpenClaw Windows Hub installer"
        $dlInstaller = Invoke-Native -FilePath $curl -Arguments @(
            "-L","--fail","--show-error",
            "--retry","3","--retry-delay","2",
            "-o",$installer,
            $downloadUrl
        ) -AllowFailure

        if ($dlInstaller.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $installer -PathType Leaf)) {
            throw "Windows Hub installer download failed."
        }

        # GitHub release assets expose a digest field (for current releases this is
        # sha256:<hex>). Use that authoritative per-asset digest instead of probing
        # for a separate SHA256SUMS file that the Windows Hub project does not publish.
        if (-not [string]::IsNullOrWhiteSpace($expectedDigest) -and
            $expectedDigest -match '(?i)^sha256:([0-9a-f]{64})$') {
            $expected = $Matches[1].ToLowerInvariant()
            $actual = (Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash.ToLowerInvariant()

            if ($expected -ne $actual) {
                throw "Windows Hub installer SHA-256 does not match GitHub release metadata."
            }

            Pass "Windows Hub installer SHA-256 verified against GitHub release metadata."
        } else {
            Warn "GitHub release metadata did not expose a SHA-256 digest; Authenticode validation will still be required."
        }

        Step "Validating Windows Hub code signature"
        $sig = Get-AuthenticodeSignature -LiteralPath $installer
        if ($sig.Status -ne [System.Management.Automation.SignatureStatus]::Valid) {
            throw "Windows Hub installer Authenticode signature is not valid: $($sig.Status)"
        }
        Pass "Windows Hub installer signature is valid."

        Step "Installing OpenClaw Windows Hub companion"
        # The official installer is Inno Setup. Silent mode avoids launching the
        # first-run wizard during migration; the user can connect the Hub to the
        # restored WSL Gateway after migration completes.
        $hubInstall = Start-Process -FilePath $installer -ArgumentList @(
            "/VERYSILENT",
            "/SUPPRESSMSGBOXES",
            "/NORESTART",
            "/SP-"
        ) -Wait -PassThru

        if ($hubInstall.ExitCode -ne 0) {
            throw "Windows Hub installer exited with code $($hubInstall.ExitCode)."
        }

        $hubExe = Get-WindowsHubExecutable
        if (-not $hubExe) {
            throw "Windows Hub installer completed but OpenClaw.Tray.WinUI.exe was not found."
        }

        Pass "OpenClaw Windows Hub installed: $hubExe"
        Info "The Hub was not auto-launched. After migration, open OpenClaw Companion and connect it to the restored Gateway."
    } catch {
        Warn "Automatic OpenClaw Windows Hub installation failed: $($_.Exception.Message)"
        Warn "Windows Hub is optional for the core restore. Continuing with Gateway/CLI/node restore."
        Warn "After migration, install OpenClaw Companion manually and connect it to the existing WSL Gateway."
        return
    } finally {
        try { Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue } catch {}
    }
}

function Ensure-RestorePrerequisites {
    param(
        [Parameter(Mandatory=$true)][string]$PackageFolder,
        [Parameter(Mandatory=$true)][string]$SupportFolder
    )

    Step "NEW-PC / RESTORE PREREQUISITE PREFLIGHT"
    if ($NewPC) {
        Write-Host "Mode: NEW PC bootstrap + restore" -ForegroundColor Cyan
    } else {
        Write-Host "Mode: restore with automatic prerequisite detection" -ForegroundColor Cyan
    }

    # These checks happen BEFORE the live OpenClaw state is activated.
    Ensure-WslForRestore -SupportFolder $SupportFolder -PackageFolder $PackageFolder
    Install-OpenClawWslIfMissing -SupportFolder $SupportFolder -PackageFolder $PackageFolder
    Ensure-WindowsOpenClaw -SupportFolder $SupportFolder -PackageFolder $PackageFolder
    Ensure-WindowsHub -SupportFolder $SupportFolder -PackageFolder $PackageFolder

    Step "Verifying prerequisite versions"

    $wslVerifyCmd = @'
set -e

OC="$HOME/.openclaw/bin/openclaw"
NODE="$HOME/.openclaw/tools/node/bin/node"

test -x "$OC"
test -x "$NODE"

printf 'OPENCLAW_PATH=%s\n' "$OC"
printf 'NODE_PATH=%s\n' "$NODE"

"$OC" --version
"$NODE" --version
python3 --version

PID1="$(ps -p 1 -o comm= | tr -d '[:space:]')"
printf 'PID1=%s\n' "$PID1"
test "$PID1" = "systemd"
'@

    $wslVersion = Invoke-Wsl $wslVerifyCmd -AllowFailure
    if ($wslVersion.ExitCode -ne 0 -or
        $wslVersion.Output -notmatch '(?m)^OPENCLAW_PATH=/' -or
        $wslVersion.Output -notmatch '(?m)^NODE_PATH=/' -or
        $wslVersion.Output -notmatch '(?m)^OpenClaw ' -or
        $wslVersion.Output -notmatch '(?m)^PID1=systemd$') {

        Write-RestoreFallbackGuide -SupportFolder $SupportFolder -PackageFolder $PackageFolder `
            -Problem "WSL prerequisite verification failed after installation." `
            -ManualSteps @(
                'Open the selected WSL distro.',
                'Run: $HOME/.openclaw/bin/openclaw --version',
                'Run: $HOME/.openclaw/tools/node/bin/node --version',
                'Run: python3 --version',
                'Run: ps -p 1 -o comm=   (should say systemd)',
                'Run CONTINUE-RESTORE.cmd.'
            )
        Fail "WSL prerequisite verification failed."
    }

    $resolvedOpenClaw = ($wslVersion.Output -split "`r?`n" |
        Where-Object { $_ -like 'OPENCLAW_PATH=*' } |
        Select-Object -Last 1)
    $resolvedNode = ($wslVersion.Output -split "`r?`n" |
        Where-Object { $_ -like 'NODE_PATH=*' } |
        Select-Object -Last 1)

    Pass "WSL native OpenClaw resolution: $resolvedOpenClaw"
    Pass "WSL native Node resolution: $resolvedNode"

    $winVersion = Invoke-Native -FilePath "openclaw" -Arguments @("--version") -AllowFailure -Quiet
    if ($winVersion.ExitCode -ne 0) {
        Fail "Windows OpenClaw prerequisite verification failed."
    }

    Pass "WSL is operational."
    Pass "systemd is operational."
    Pass "Linux restore utilities are available."
    Pass "OpenClaw is installed in WSL."
    Pass "OpenClaw is installed on Windows."
    Pass "Prerequisite preflight complete."
}

function Get-WindowsHubSetupCode {
    $r = Invoke-Wsl `
        -Command '"$HOME/.openclaw/bin/openclaw" qr --setup-code-only --url ws://127.0.0.1:18789' `
        -AllowFailure -SensitiveOutput

    if ($r.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($r.Output)) {
        return $null
    }

    $lines = @($r.Output -split "`r?`n" |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ })

    [array]::Reverse($lines)

    foreach ($line in $lines) {
        if ($line -notmatch '^[A-Za-z0-9_-]{80,}$') { continue }

        try {
            $padded = $line.Replace('-','+').Replace('_','/')
            $mod = $padded.Length % 4
            if ($mod -eq 2) { $padded += "==" }
            elseif ($mod -eq 3) { $padded += "=" }
            elseif ($mod -ne 0) { continue }

            $bytes = [Convert]::FromBase64String($padded)
            $jsonText = [System.Text.Encoding]::UTF8.GetString($bytes)
            $obj = $jsonText | ConvertFrom-Json

            if (-not [string]::IsNullOrWhiteSpace([string]$obj.url) -and
                -not [string]::IsNullOrWhiteSpace([string]$obj.bootstrapToken)) {
                return $line
            }
        } catch {
            continue
        }
    }

    return $null
}

function Write-WindowsHubConnectionGuide {
    param(
        [Parameter(Mandatory=$true)][string]$SupportFolder
    )

    $distro = Normalize-WslDistroName $Script:SelectedDistro
    if ([string]::IsNullOrWhiteSpace($distro)) { $distro = "<your WSL distro>" }

    $guidePath = Join-Path $SupportFolder "CONNECT-WINDOWS-HUB.txt"

    $guide = @"
OPENCLAW WINDOWS HUB - CONNECT TO THE RESTORED WSL GATEWAY
==========================================================

IMPORTANT:
- DO NOT click "Install" under "Get started: install a local gateway".
- The migration already restored the real Gateway inside WSL.
- Use the existing-Gateway connection flow instead.

RECOMMENDED METHOD: SETUP CODE
------------------------------
1. Launch "OpenClaw Companion" from the Windows Start menu.

2. On the Connection page, click:
      Setup code
   Do NOT choose "Install a local gateway".

3. Open a separate Windows PowerShell window and enter the restored WSL distro:
      wsl.exe -d $distro

4. Inside WSL, generate a short-lived setup code:
      ~/.openclaw/bin/openclaw qr --setup-code-only --url ws://127.0.0.1:18789

5. Copy the setup code printed in that WSL terminal.

6. Back in OpenClaw Companion, paste the code into the Setup code box and connect.

7. The Companion should change from "Disconnected" to connected/green.

IF PAIRING APPROVAL IS REQUESTED
--------------------------------
Inside the restored WSL Gateway run:

      ~/.openclaw/bin/openclaw devices list

Approve the device request shown there:

      ~/.openclaw/bin/openclaw devices approve <deviceRequestId>

Windows node mode uses a SEPARATE command-surface approval. If node mode is pending:

      ~/.openclaw/bin/openclaw nodes pending
      ~/.openclaw/bin/openclaw nodes approve <nodeRequestId>

Then restart Windows node mode / OpenClaw Companion so it reconnects.

VERIFY WINDOWS CUA
------------------
Inside WSL:

      ~/.openclaw/bin/openclaw nodes status
      ~/.openclaw/bin/openclaw nodes describe --node "Windows CUA"

The Windows Hub top bar should show Connected and the Windows CUA node should be present.

DIRECT TOKEN METHOD (ALTERNATIVE)
---------------------------------
If you intentionally want to use Direct instead of Setup code:

Gateway URL:
      ws://127.0.0.1:18789

Retrieve the configured shared token INTERACTIVELY inside WSL:
      ~/.openclaw/bin/openclaw gateway auth-token --show

Then in OpenClaw Companion choose:
      Direct
and enter the URL + token.

Treat that token as a password. The Setup code method above is preferred because it uses a
short-lived bootstrap credential instead of making you copy the shared Gateway token.

ABOUT STALE DEVICE-AUTH WARNINGS
--------------------------------
A warning that an old cached node device credential no longer matches the active Gateway
means the old Windows node pairing is stale. It does NOT mean the restored Gateway data is
missing. Complete the Setup code/device/node approval flow above to establish a fresh valid
pairing.

RESTORED WSL DISTRO:
      $distro
"@

    Set-Content -LiteralPath $guidePath -Value $guide -Encoding UTF8
    return $guidePath
}

function Restore-MigrationKit {
    Write-Banner
    $package = Resolve-PackageFolder

    $restoreLogRoot = Join-Path $env:USERPROFILE "Documents\OpenClaw-Restore-Logs"
    $restoreLogFolder = Join-Path $restoreLogRoot ("Restore_" + (Get-Date -Format "yyyy-MM-dd_HH-mm-ss"))
    Start-RunLog $restoreLogFolder

    try {
        Step "Migration package integrity check"
        if (-not (Test-PackageChecksums $package)) {
            Fail "Migration package integrity verification failed. Do not restore from this package."
        }

        $manifest = Get-Content -LiteralPath (Join-Path $package "package-manifest.json") -Raw | ConvertFrom-Json
        $archiveName = $manifest.primaryArchive
        $archive = Get-ChildItem -LiteralPath (Join-Path $package "Payload") -File -Filter $archiveName -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if (-not $archive) {
            $archive = Get-NewestArchive (Join-Path $package "Payload")
        }
        if (-not $archive) { Fail "No OpenClaw .tar.gz archive found in the package Payload folder." }

        $Script:RestoreSupportFolder = $restoreLogFolder
        Ensure-RestorePrerequisites -PackageFolder $package -SupportFolder $restoreLogFolder

        if ($PrerequisiteCheckOnly) {
            Pass "PREREQUISITE CHECK COMPLETE - NO RESTORE WAS PERFORMED"
            Write-Host "This machine is ready for RESTORE-THIS-BACKUP.cmd." -ForegroundColor Green
            return
        }

        $wslArchive = Convert-ToWslPath $archive.FullName

        # Keep a human-readable restore script in the external restore log folder
        # for debugging, but DO NOT execute that /mnt/c file. Read the exact script
        # text and stream it to WSL bash over STDIN. The archive path is Bash $1.
        $restoreScript = Build-WslRestoreScript -PackageFolder $restoreLogFolder -ArchiveFile $archive.FullName
        $restoreContent = [System.IO.File]::ReadAllText($restoreScript, [System.Text.Encoding]::UTF8)

        Step "Running staged WSL restore and activation"
        $rr = Invoke-Wsl -Command $restoreContent -Arguments @($wslArchive) -AllowFailure
        if ($rr.ExitCode -ne 0) {
            Fail "WSL migration restore failed. Review the migration log and rollback/pre-restore locations printed above."
        }
        Pass "WSL state/workspace migration completed."

        Rebuild-WindowsCuaNode -PackageFolder $package

        Step "Final end-to-end checks"
        Test-GatewayDeep -AllowFailure | Out-Null
        $doctor = Invoke-Wsl '"$HOME/.openclaw/bin/openclaw" doctor' -AllowFailure
        if ($doctor.ExitCode -eq 0) { Pass "Final OpenClaw Doctor completed." }
        else { Warn "Final Doctor returned non-zero; review output." }

        Pass "MIGRATION COMPLETE"
        Write-Host ""

        $hubGuide = Write-WindowsHubConnectionGuide -SupportFolder $restoreLogFolder
        $hubExe = Get-WindowsHubExecutable

        if ($hubExe) {
            Write-Host "OpenClaw Windows Hub is installed:" -ForegroundColor Green
            Write-Host "  $hubExe" -ForegroundColor Gray
            Write-Host ""
            Write-Host "WINDOWS HUB: CONNECT IT TO THE RESTORED WSL GATEWAY" -ForegroundColor Cyan
            Write-Host "---------------------------------------------------" -ForegroundColor Cyan
            Write-Host "1. Launch 'OpenClaw Companion' from Start." -ForegroundColor White
            Write-Host "2. DO NOT click 'Install' under 'install a local gateway'." -ForegroundColor Yellow
            Write-Host "3. Click 'Setup code' under 'connect to an existing one'." -ForegroundColor White
            Write-Host "4. Open a separate PowerShell window and run:" -ForegroundColor White
            Write-Host "     wsl.exe -d $($Script:SelectedDistro)" -ForegroundColor Green
            Write-Host "5. Inside WSL run:" -ForegroundColor White
            Write-Host "     ~/.openclaw/bin/openclaw qr --setup-code-only --url ws://127.0.0.1:18789" -ForegroundColor Green
            Write-Host "6. Paste that short-lived setup code into OpenClaw Companion." -ForegroundColor White
            Write-Host "7. If pairing is pending, approve device/node requests from WSL." -ForegroundColor White
            Write-Host ""
            Write-Host "Full GUI connection instructions:" -ForegroundColor Cyan
            Write-Host "  $hubGuide" -ForegroundColor Green
            Write-Host ""
        } else {
            Warn "Windows Hub is not installed. Core restore is complete."
            Write-Host "GUI connection instructions were still written to:" -ForegroundColor Gray
            Write-Host "  $hubGuide" -ForegroundColor Gray
            Write-Host ""
        }

        Write-Host "The source Windows node snapshot is preserved here for recovery/reference:" -ForegroundColor Gray
        Write-Host "  $(Join-Path $package 'Windows\windows-openclaw-state.zip')" -ForegroundColor Gray
        Write-Host ""
        Warn "Do not delete the migration kit until you have tested sessions, channels, memory, plugins, Windows Hub, and Windows CUA."

        if ($hubExe) {
            Write-Host ""
            Write-Host "Preparing a fresh short-lived Windows Hub setup code..." -ForegroundColor Cyan

            # The setup code contains a short-lived bootstrap credential.
            # Stop the PowerShell transcript BEFORE minting/printing it so the
            # credential is visible to the user but is not persisted in tool-run.log.
            Stop-RunLog

            $setupCode = Get-WindowsHubSetupCode

            Write-Host ""
            Write-Host "============================================================" -ForegroundColor Cyan
            Write-Host " OPENCLAW WINDOWS HUB - SETUP CODE" -ForegroundColor Cyan
            Write-Host "============================================================" -ForegroundColor Cyan

            if (-not [string]::IsNullOrWhiteSpace($setupCode)) {
                Write-Host ""
                Write-Host $setupCode -ForegroundColor Green
                Write-Host ""
                Write-Host "In OpenClaw Companion:" -ForegroundColor White
                Write-Host "  Connection -> Setup code -> paste the code above -> Connect" -ForegroundColor Green
                Write-Host ""
                Write-Host "This is a short-lived bootstrap credential. If it expires, regenerate it in WSL with:" -ForegroundColor Yellow
                Write-Host "  ~/.openclaw/bin/openclaw qr --setup-code-only --url ws://127.0.0.1:18789" -ForegroundColor Yellow
            } else {
                Write-Host ""
                Write-Host "The toolkit could not mint the setup code automatically." -ForegroundColor Yellow
                Write-Host "Open WSL and run:" -ForegroundColor White
                Write-Host "  ~/.openclaw/bin/openclaw qr --setup-code-only --url ws://127.0.0.1:18789" -ForegroundColor Green
            }

            Write-Host ""
            Write-Host "DO NOT click 'Install a local gateway' in the Windows Hub." -ForegroundColor Yellow
            Write-Host "Use the restored WSL Gateway at ws://127.0.0.1:18789." -ForegroundColor White
            Write-Host "============================================================" -ForegroundColor Cyan

            $setupCode = $null
        }

    } finally {
        Stop-RunLog
    }
}



function Get-WindowsOpenClawNodeProcesses {
    try {
        return @(Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object {
            $_.Name -ieq "node.exe" -and
            $_.CommandLine -and
            $_.CommandLine -match '(?i)openclaw.*\bnode\s+run\b'
        })
    } catch {
        Warn "Could not enumerate Windows node-host processes: $($_.Exception.Message)"
        return @()
    }
}

function Get-WindowsOpenClawNodeRootProcesses {
    $all = @(Get-WindowsOpenClawNodeProcesses)
    if ($all.Count -eq 0) { return @() }

    $ids = @{}
    foreach ($p in $all) { $ids[[int]$p.ProcessId] = $true }

    return @($all | Where-Object {
        -not $ids.ContainsKey([int]$_.ParentProcessId)
    })
}

function Stop-AllWindowsOpenClawNodeProcesses {
    Step "Terminating every Windows OpenClaw node-host instance"

    $schtasks = "$env:WINDIR\System32\schtasks.exe"
    $taskkill = "$env:WINDIR\System32\taskkill.exe"

    # Stop the installed OpenClaw node service first. Missing service/task is normal
    # during a repair and must NEVER abort the repair.
    if (Test-Command "openclaw") {
        Invoke-Native -FilePath "openclaw" -Arguments @("node","stop") -AllowFailure -Quiet | Out-Null
    }

    Invoke-Native -FilePath $schtasks -Arguments @("/End","/TN","\OpenClaw Node") -AllowFailure -Quiet | Out-Null
    Start-Sleep -Seconds 1

    for ($pass = 1; $pass -le 3; $pass++) {
        $roots = @(Get-WindowsOpenClawNodeRootProcesses)
        if ($roots.Count -eq 0) { break }

        foreach ($p in $roots) {
            Info "Killing node-host process tree PID $($p.ProcessId)"
            Invoke-Native -FilePath $taskkill -Arguments @("/PID",[string]$p.ProcessId,"/T","/F") -AllowFailure | Out-Null
        }
        Start-Sleep -Seconds 1
    }

    # Last cleanup for any orphan children whose original parent disappeared.
    $left = @(Get-WindowsOpenClawNodeProcesses)
    foreach ($p in $left) {
        Info "Killing orphan node-host PID $($p.ProcessId)"
        Invoke-Native -FilePath $taskkill -Arguments @("/PID",[string]$p.ProcessId,"/T","/F") -AllowFailure -Quiet | Out-Null
    }

    Start-Sleep -Seconds 1
    $final = @(Get-WindowsOpenClawNodeProcesses)
    if ($final.Count -eq 0) {
        Pass "No Windows OpenClaw node-host processes remain."
    } else {
        Fail "Could not terminate all Windows OpenClaw node-host processes. Remaining: $($final.Count)"
    }
}

function Stop-AccidentalWindowsGateway {
    Step "Checking for accidental native-Windows Gateway instances"

    $schtasks = "$env:WINDIR\System32\schtasks.exe"
    $taskkill = "$env:WINDIR\System32\taskkill.exe"

    try {
        $gatewayProcs = @(Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object {
            $_.Name -ieq "node.exe" -and
            $_.CommandLine -and
            $_.CommandLine -match '(?i)openclaw.*\bgateway\b'
        })

        if ($gatewayProcs.Count -eq 0) {
            Pass "No native-Windows OpenClaw Gateway process found."
        } else {
            foreach ($p in $gatewayProcs) {
                Warn "Killing accidental Windows Gateway PID $($p.ProcessId)"
                Invoke-Native -FilePath $taskkill -Arguments @("/PID",[string]$p.ProcessId,"/T","/F") -AllowFailure -Quiet | Out-Null
            }
        }
    } catch {
        Warn "Could not inspect native Windows Gateway processes: $($_.Exception.Message)"
    }

    # IMPORTANT: a missing task is the EXPECTED healthy state for this topology.
    # schtasks.exe returns an error code and writes to stderr when a named task
    # does not exist. Invoke-Native(... -AllowFailure -Quiet) prevents that normal
    # condition from becoming a terminating PowerShell 5.1 error.
    $probe = Invoke-Native -FilePath $schtasks -Arguments @("/Query","/TN","\OpenClaw Gateway") -AllowFailure -Quiet

    if ($probe.ExitCode -eq 0) {
        Warn "Found a native Windows 'OpenClaw Gateway' Scheduled Task. This topology uses the WSL Gateway; removing the competing task."
        Invoke-Native -FilePath $schtasks -Arguments @("/End","/TN","\OpenClaw Gateway") -AllowFailure -Quiet | Out-Null
        $delete = Invoke-Native -FilePath $schtasks -Arguments @("/Delete","/TN","\OpenClaw Gateway","/F") -AllowFailure -Quiet
        if ($delete.ExitCode -eq 0) {
            Pass "Removed competing native Windows Gateway Scheduled Task."
        } else {
            Warn "Could not delete the competing native Windows Gateway Scheduled Task."
        }
    } else {
        Pass "No competing native Windows Gateway Scheduled Task found."
    }
}

function Get-OpenClawCompanionProcessInfo {
    try {
        return @(Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object {
            $_.Name -match '(?i)^openclaw.*\.exe$' -and
            $_.ExecutablePath -and
            $_.ExecutablePath -notmatch '(?i)powershell|cmd\.exe'
        } | Select-Object ProcessId, ExecutablePath)
    } catch {
        return @()
    }
}

function Stop-OpenClawCompanion {
    param([object[]]$Processes)

    if (-not $Processes -or $Processes.Count -eq 0) {
        Info "No running Windows OpenClaw companion process was detected."
        return
    }

    Step "Stopping Windows OpenClaw companion application"
    foreach ($p in $Processes) {
        try {
            Invoke-Native -FilePath "$env:WINDIR\System32\taskkill.exe" -Arguments @("/PID",[string]$p.ProcessId,"/T","/F") -AllowFailure -Quiet | Out-Null
            Info "Stopped companion PID $($p.ProcessId)"
        } catch {}
    }
    Pass "Windows companion application stopped."
}

function Start-OpenClawCompanion {
    param([object[]]$PreviousProcesses)

    $paths = @()
    if ($PreviousProcesses) {
        $paths += @($PreviousProcesses | ForEach-Object { $_.ExecutablePath } | Where-Object { $_ } | Select-Object -Unique)
    }

    if ($paths.Count -eq 0) {
        $candidates = @(
            (Join-Path $env:LOCALAPPDATA "Programs\OpenClaw\OpenClaw.exe"),
            (Join-Path $env:LOCALAPPDATA "OpenClaw\OpenClaw.exe"),
            (Join-Path $env:ProgramFiles "OpenClaw\OpenClaw.exe")
        )
        $paths += @($candidates | Where-Object { Test-Path -LiteralPath $_ })
    }

    if ($paths.Count -eq 0) {
        Warn "Windows companion executable was not found automatically. Gateway/node recovery is still complete."
        return
    }

    Step "Restarting Windows OpenClaw companion application"
    foreach ($path in ($paths | Select-Object -Unique)) {
        try {
            Start-Process -FilePath $path | Out-Null
            Pass "Started companion: $path"
            break
        } catch {
            Warn "Could not start companion '$path': $($_.Exception.Message)"
        }
    }
}

function Get-RecursiveJsonObjects {
    param([object]$Object)

    $result = New-Object System.Collections.ArrayList

    function Visit-JsonObject([object]$Value) {
        if ($null -eq $Value) { return }

        if ($Value -is [System.Management.Automation.PSCustomObject]) {
            [void]$result.Add($Value)
            foreach ($prop in $Value.PSObject.Properties) {
                Visit-JsonObject $prop.Value
            }
            return
        }

        if (($Value -is [System.Collections.IEnumerable]) -and -not ($Value -is [string])) {
            foreach ($item in $Value) {
                Visit-JsonObject $item
            }
        }
    }

    Visit-JsonObject $Object
    return @($result)
}

function ConvertTo-NodeRecord {
    param([object]$Object)

    if ($null -eq $Object -or -not $Object.PSObject) { return $null }

    $name = $null
    foreach ($key in @("displayName","name","nodeName")) {
        $p = $Object.PSObject.Properties[$key]
        if ($p -and -not [string]::IsNullOrWhiteSpace([string]$p.Value)) {
            $name = [string]$p.Value
            break
        }
    }

    $id = $null
    foreach ($key in @("nodeId","id","deviceId")) {
        $p = $Object.PSObject.Properties[$key]
        if ($p -and -not [string]::IsNullOrWhiteSpace([string]$p.Value)) {
            $id = [string]$p.Value
            break
        }
    }

    if ([string]::IsNullOrWhiteSpace($name) -or [string]::IsNullOrWhiteSpace($id)) {
        return $null
    }

    $connected = $false
    foreach ($key in @("connected","isConnected","online")) {
        $p = $Object.PSObject.Properties[$key]
        if ($p -and $p.Value -eq $true) { $connected = $true }
    }
    foreach ($key in @("status","state","connectionState")) {
        $p = $Object.PSObject.Properties[$key]
        if ($p -and ([string]$p.Value) -match '(?i)connected|online|active') { $connected = $true }
    }

    return [pscustomobject]@{
        Name = $name
        Id = $id
        Connected = $connected
    }
}

function Get-GatewayNodeRecords {
    param([switch]$ConnectedOnly)

    $cmd = if ($ConnectedOnly) { "openclaw nodes list --connected --json" } else { "openclaw nodes list --json" }
    $r = Invoke-Wsl $cmd -AllowFailure
    if ($r.ExitCode -ne 0) { return @() }

    try {
        $start = $r.Output.IndexOf("{")
        $arrayStart = $r.Output.IndexOf("[")
        if ($arrayStart -ge 0 -and ($start -lt 0 -or $arrayStart -lt $start)) { $start = $arrayStart }
        if ($start -lt 0) { return @() }

        $jsonText = $r.Output.Substring($start)
        $obj = $jsonText | ConvertFrom-Json
        $allObjects = @(Get-RecursiveJsonObjects $obj)
        $records = @()
        foreach ($o in $allObjects) {
            $rec = ConvertTo-NodeRecord $o
            if ($rec) { $records += $rec }
        }

        $seen = @{}
        $unique = @()
        foreach ($r2 in $records) {
            if (-not $seen.ContainsKey($r2.Id)) {
                $seen[$r2.Id] = $true
                $unique += $r2
            }
        }
        return $unique
    } catch {
        Warn "Could not parse node JSON for duplicate cleanup: $($_.Exception.Message)"
        return @()
    }
}

function Repair-DuplicateWindowsCuaRegistryNodes {
    Step "Checking Gateway node registry for duplicate Windows CUA records"

    $all = @(Get-GatewayNodeRecords)
    $connected = @(Get-GatewayNodeRecords -ConnectedOnly)

    $allCua = @($all | Where-Object { $_.Name -eq "Windows CUA" })
    $connectedIds = @{}
    foreach ($n in $connected) {
        if ($n.Name -eq "Windows CUA") { $connectedIds[$n.Id] = $true }
    }

    if ($allCua.Count -le 1) {
        Pass "No duplicate 'Windows CUA' registry records detected."
        return
    }

    if ($connectedIds.Count -ne 1) {
        Warn "Found $($allCua.Count) Windows CUA records, but could not identify exactly one connected record. No registry record will be removed automatically."
        return
    }

    $keeper = @($connectedIds.Keys)[0]
    Info "Keeping connected Windows CUA node: $keeper"

    foreach ($n in $allCua) {
        if ($n.Id -eq $keeper) { continue }
        Warn "Removing stale duplicate Windows CUA node: $($n.Id)"
        $rm = Invoke-Wsl "openclaw nodes remove --node '$($n.Id)'" -AllowFailure
        if ($rm.ExitCode -eq 0) {
            Pass "Removed stale node $($n.Id)"
        } else {
            Warn "Could not remove stale node $($n.Id)"
        }
    }

    $after = @(Get-GatewayNodeRecords | Where-Object { $_.Name -eq "Windows CUA" })
    if ($after.Count -eq 1) {
        Pass "Gateway registry now contains one Windows CUA record."
    } else {
        Warn "Gateway registry still reports $($after.Count) Windows CUA records."
    }
}

function Test-AndRepairNodeRuntimeDuplicates {
    Step "Checking for duplicate Windows node-host process trees"

    Start-Sleep -Seconds 3
    $roots = @(Get-WindowsOpenClawNodeRootProcesses)

    if ($roots.Count -eq 1) {
        Pass "Exactly one Windows OpenClaw node-host process tree is running."
        return
    }

    Warn "Expected one Windows node-host process tree; found $($roots.Count). Performing one clean rebuild."
    Stop-AllWindowsOpenClawNodeProcesses
    Rebuild-WindowsCuaNode
    Start-Sleep -Seconds 4

    $roots = @(Get-WindowsOpenClawNodeRootProcesses)
    if ($roots.Count -ne 1) {
        Fail "Windows node-host duplication could not be resolved automatically. Root process trees still present: $($roots.Count)"
    }

    Pass "Duplicate-process cleanup succeeded; exactly one node-host process tree remains."
}

function Repair-OpenClawStack {
    Write-Banner

    $repairRoot = Join-Path $env:USERPROFILE "Documents\OpenClaw-Repair-Logs"
    $repairFolder = Join-Path $repairRoot ("Repair_" + (Get-Date -Format "yyyy-MM-dd_HH-mm-ss"))
    Start-RunLog $repairFolder

    $companionBefore = @()

    try {
        Step "Repair profile"
        Write-Host "Topology: WSL Gateway + Windows CUA node" -ForegroundColor Gray
        Write-Host "This operation intentionally stops all OpenClaw runtime components, repairs them, and starts one clean stack." -ForegroundColor Gray

        Step "Windows repair-engine self-check"
        $missingTaskProbe = Invoke-Native -FilePath "$env:WINDIR\System32\schtasks.exe" -Arguments @("/Query","/TN","\OpenClaw Gateway") -AllowFailure -Quiet
        if ($missingTaskProbe.ExitCode -eq 0) {
            Info "Native Windows Gateway task exists and will be removed later in this repair."
        } else {
            Pass "Missing native Windows Gateway task is handled as a normal condition (no abort)."
        }

        Select-WslDistro
        if (-not (Test-OpenClawWsl)) {
            Fail "OpenClaw is not installed in the selected WSL distro."
        }

        $companionBefore = @(Get-OpenClawCompanionProcessInfo)

        Step "Pre-repair diagnostics"
        Test-GatewayDeep -AllowFailure | Out-Null
        Invoke-Wsl "openclaw doctor --deep" -AllowFailure | Out-Null

        $rootsBefore = @(Get-WindowsOpenClawNodeRootProcesses)
        Info "Windows node-host root process trees before cleanup: $($rootsBefore.Count)"

        Stop-OpenClawCompanion -Processes $companionBefore
        Stop-AllWindowsOpenClawNodeProcesses
        Stop-AccidentalWindowsGateway

        Step "Stopping the WSL Gateway completely"
        Invoke-Wsl "openclaw gateway stop --force" -AllowFailure | Out-Null
        Invoke-Wsl "systemctl --user stop openclaw-gateway.service || true; systemctl --user kill --kill-who=all --signal=SIGKILL openclaw-gateway.service 2>/dev/null || true" -AllowFailure | Out-Null
        Start-Sleep -Seconds 2

        $state = Invoke-Wsl "systemctl --user is-active openclaw-gateway.service || true" -AllowFailure
        if ($state.Output.Trim() -match '^active$|^deactivating$') {
            Fail "WSL Gateway would not fully stop."
        }
        Pass "WSL Gateway is fully stopped."

        Step "Creating best-effort pre-repair safety snapshot"
        $safetyStamp = Get-Date -Format "yyyyMMdd-HHmmss"
        $safety = Invoke-Wsl "mkdir -p `$HOME/.openclaw-repair-safety/$safetyStamp && openclaw backup create --output `$HOME/.openclaw-repair-safety/$safetyStamp --verify --json" -AllowFailure
        if ($safety.ExitCode -eq 0) {
            Pass "Pre-repair safety backup created inside WSL."
            Info "WSL safety backup: ~/.openclaw-repair-safety/$safetyStamp"
        } else {
            Warn "Safety backup failed; continuing with repair because the stack is already stopped."
        }

        Step "Running OpenClaw repair/migration maintenance"
        $doctorFix = Invoke-Wsl "openclaw doctor --fix" -AllowFailure
        if ($doctorFix.ExitCode -eq 0) {
            Pass "Doctor --fix completed."
        } else {
            Warn "Doctor --fix returned exit code $($doctorFix.ExitCode). Continuing to update repair and final checks."
        }

        Step "Repairing update/plugin convergence"
        $updateRepair = Invoke-Wsl "openclaw update repair --yes --no-restart --json" -AllowFailure
        if ($updateRepair.ExitCode -eq 0) {
            Pass "Update/plugin repair completed."
        } else {
            Warn "Update repair returned exit code $($updateRepair.ExitCode). Final Doctor will determine remaining issues."
        }

        Step "Reinstalling the intended WSL Gateway service definition"
        $gwInstall = Invoke-Wsl "openclaw gateway install --force" -AllowFailure
        if ($gwInstall.ExitCode -ne 0) {
            Warn "Gateway install --force returned non-zero; attempting to start the existing service definition."
        }

        if (-not (Start-GatewayAndVerify)) {
            Warn "Gateway failed first recovery start. Reinstalling service once more and retrying."
            Invoke-Wsl "openclaw gateway stop --force || true; openclaw gateway install --force; systemctl --user start openclaw-gateway.service" -AllowFailure | Out-Null
            Start-Sleep -Seconds 10
            if (-not (Test-GatewayDeep -AllowFailure)) {
                Fail "Gateway could not be restored to a healthy state."
            }
        }

        Step "Rebuilding Windows CUA node cleanly"
        Rebuild-WindowsCuaNode
        Test-AndRepairNodeRuntimeDuplicates

        Step "Repairing stale exec-node binding"
        $nodeDesc = Invoke-Wsl "openclaw nodes describe --node 'Windows CUA'" -AllowFailure
        if ($nodeDesc.ExitCode -ne 0) {
            Warn "Windows CUA did not describe successfully. Restarting the node once to clear possible stale device-token state."
            if (Test-Command "openclaw") {
                try { & openclaw node restart 2>&1 | ForEach-Object { Write-Host $_ } } catch {}
            }
            Start-Sleep -Seconds 5
            $nodeDesc = Invoke-Wsl "openclaw nodes describe --node 'Windows CUA'" -AllowFailure
        }

        if ($nodeDesc.ExitCode -eq 0) {
            Invoke-Wsl "openclaw config set tools.exec.host node" -AllowFailure | Out-Null
            Invoke-Wsl "openclaw config set tools.exec.node 'Windows CUA'" -AllowFailure | Out-Null
            Pass "Exec-node binding points at Windows CUA."

            foreach ($required in @("computer.act","screen.snapshot","system.run")) {
                if ($nodeDesc.Output -match [regex]::Escape($required)) {
                    Pass "Windows CUA advertises $required"
                } else {
                    Warn "Windows CUA does not currently advertise $required"
                }
            }
        } else {
            Warn "Windows CUA is not yet describable. Check device/node pairing requests below."
        }

        Repair-DuplicateWindowsCuaRegistryNodes

        Step "Checking pairing queues"
        $deviceList = Invoke-Wsl "openclaw devices list" -AllowFailure
        $pending = Invoke-Wsl "openclaw nodes pending" -AllowFailure
        if ($pending.Output -and $pending.Output -notmatch '(?i)no pending|none') {
            Warn "A node command-surface approval may still be pending. Security approvals are not auto-approved by this repair tool."
        } else {
            Pass "No obvious pending node command-surface request."
        }

        Step "Final diagnostics"
        if (-not (Test-GatewayDeep -AllowFailure)) {
            Fail "Final Gateway deep probe failed."
        }

        $finalDoctor = Invoke-Wsl "openclaw doctor --lint --json" -AllowFailure
        if ($finalDoctor.ExitCode -eq 0) {
            Pass "Final Doctor lint completed successfully."
        } else {
            Warn "Final Doctor lint reports remaining warnings/errors. Review the repair log."
        }

        $finalRoots = @(Get-WindowsOpenClawNodeRootProcesses)
        if ($finalRoots.Count -eq 1) {
            Pass "Final Windows node process check: exactly one root instance."
        } else {
            Fail "Final Windows node process check found $($finalRoots.Count) root instances."
        }

        Start-OpenClawCompanion -PreviousProcesses $companionBefore

        Pass "OPENCLAW RESET / REPAIR COMPLETE"
        Write-Host ""
        Write-Host "Repair log: $($Script:CurrentLog)" -ForegroundColor Green
        Write-Host "Gateway: healthy" -ForegroundColor Green
        Write-Host "Windows node root instances: 1" -ForegroundColor Green
        Write-Host ""
        Warn "If a device/node approval is pending, approve it explicitly; this tool does not bypass OpenClaw security approvals."

    } finally {
        Stop-RunLog
    }
}


function Finalize-ExistingPackage {
    Write-Banner

    Add-Type -AssemblyName System.Windows.Forms
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = "Select an OpenClaw FullBackup or MigrationKit folder that already contains package-manifest.json and Payload"
    $dlg.ShowNewFolderButton = $false
    if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
        Fail "No package folder selected."
    }

    $package = $dlg.SelectedPath
    $verifyLogRoot = Join-Path $env:USERPROFILE "Documents\OpenClaw-Verification-Logs"
    $verifyLogFolder = Join-Path $verifyLogRoot ("Finalize_" + (Get-Date -Format "yyyy-MM-dd_HH-mm-ss"))
    Start-RunLog $verifyLogFolder
    try {
        Step "Validating existing package before ZIP finalization"

        $manifestPath = Join-Path $package "package-manifest.json"
        if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
            Fail "Selected folder does not contain package-manifest.json."
        }

        $payload = Join-Path $package "Payload"
        $archives = @(Get-ChildItem -LiteralPath $payload -File -Filter "*.tar.gz" -ErrorAction SilentlyContinue)
        if ($archives.Count -lt 1) {
            Fail "Selected folder does not contain a .tar.gz archive in Payload."
        }

        if (-not (Test-PackageChecksums $package)) {
            Fail "Existing package checksum verification failed. It will not be zipped."
        }

        # Stop transcript so the log is not open while ZIP is being created.
        Stop-RunLog
        $Script:CurrentLog = $null

        $zip = Export-PackageZip -PackageFolder $package
        Pass "EXISTING PACKAGE FINALIZED SUCCESSFULLY"
        Write-Host "Portable ZIP: $zip" -ForegroundColor Green
    } finally {
        Stop-RunLog
    }
}

function Verify-ExistingPackage {
    Write-Banner
    $package = Resolve-PackageFolder
    $verifyLogRoot = Join-Path $env:USERPROFILE "Documents\OpenClaw-Verification-Logs"
    $verifyLogFolder = Join-Path $verifyLogRoot ("Verify_" + (Get-Date -Format "yyyy-MM-dd_HH-mm-ss"))
    Start-RunLog $verifyLogFolder
    try {
        Step "Checking package checksums"
        if (-not (Test-PackageChecksums $package)) { Fail "Package checksum verification failed." }

        Select-WslDistro
        if (-not (Test-OpenClawWsl)) {
            Warn "OpenClaw is not installed in WSL, so only outer package checksums were verified."
            return
        }

        $manifest = Get-Content -LiteralPath (Join-Path $package "package-manifest.json") -Raw | ConvertFrom-Json
        $archive = Get-NewestArchive (Join-Path $package "Payload")
        if (-not $archive) { Fail "No .tar.gz backup archive found." }
        $wa = Convert-ToWslPath $archive.FullName
        Step "Running OpenClaw's internal archive verifier"
        $r = Invoke-Wsl "openclaw backup verify '$wa' --json" -AllowFailure
        if ($r.ExitCode -ne 0) { Fail "OpenClaw archive verification failed." }
        Pass "Package AND OpenClaw archive verification passed."
    } finally {
        Stop-RunLog
    }
}

function Show-Diagnostics {
    Write-Banner
    Select-WslDistro
    Step "WSL OpenClaw"
    Test-OpenClawWsl | Out-Null
    if (Test-OpenClawWsl) {
        Test-GatewayDeep -AllowFailure | Out-Null
        Invoke-Wsl "openclaw doctor" -AllowFailure | Out-Null
        Invoke-Wsl "openclaw nodes list" -AllowFailure | Out-Null
    }

    Step "Windows OpenClaw processes"
    try {
        Get-CimInstance Win32_Process |
            Where-Object { $_.CommandLine -match 'openclaw.*node run' } |
            Select-Object ProcessId,ParentProcessId,SessionId,CommandLine |
            Format-List
    } catch {
        Warn "Could not query Win32_Process."
    }

    Step "Windows OpenClaw Node Scheduled Task"
    $taskDiag = Invoke-Native -FilePath "$env:WINDIR\System32\schtasks.exe" -Arguments @("/Query","/TN","\OpenClaw Node","/V","/FO","LIST") -AllowFailure
    if ($taskDiag.ExitCode -ne 0) {
        Warn "OpenClaw Node Scheduled Task is not installed."
    }
}

function Test-ToolkitRuntimeCompatibility {
    Step "Toolkit runtime compatibility check"

    if ($PSVersionTable.PSVersion.Major -lt 5) {
        Fail "Windows PowerShell 5.1 or newer is required."
    }

    $psiTest = New-Object System.Diagnostics.ProcessStartInfo
    foreach ($name in @(
        "FileName",
        "Arguments",
        "UseShellExecute",
        "RedirectStandardInput",
        "RedirectStandardOutput",
        "RedirectStandardError"
    )) {
        if ($psiTest.PSObject.Properties.Name -notcontains $name) {
            Fail "Required .NET ProcessStartInfo property is missing: $name"
        }
    }

    $utf8 = New-Object System.Text.UTF8Encoding -ArgumentList $false
    $bytes = $utf8.GetBytes("test")
    if ($bytes.Length -ne 4) {
        Fail "UTF-8 no-BOM runtime self-test failed."
    }

    Pass "Windows PowerShell/.NET runtime is compatible with toolkit transport."
}

function Main {
    Test-ToolkitRuntimeCompatibility

    $packageBesideScript = $false
    try {
        $packageBesideScript = Test-Path -LiteralPath (Join-Path $PSScriptRoot "package-manifest.json") -PathType Leaf
    } catch {}

    if ((-not [string]::IsNullOrWhiteSpace($RestorePackage)) -or
        $NewPC -or
        $PrerequisiteCheckOnly -or
        $packageBesideScript) {
        Restore-MigrationKit
        return
    }

    while ($true) {
        Write-Banner
        $menu = @'
  [1] Full verified backup
      Everything needed for recovery on this computer.

  [2] Create portable migration kit
      Full verified backup + restore tool for a new computer.

  [3] Restore / migrate onto THIS computer
      Verify package, stage restore, activate state, repair, and self-test.

  [4] Verify an existing backup / migration package
      SHA-256 package verification + OpenClaw archive verification.

  [5] Diagnostics only
      Read-only checks; makes no configuration changes.

  [6] Full reset / repair / clean restart
      Stops all OpenClaw components, fixes common state/service/plugin/node problems,
      removes duplicate runtime node instances, then validates a clean restart.

  [7] Finalize an existing package into a Desktop ZIP
      Use this if backup/migration succeeded but ZIP finalization failed.

  [Q] Quit
'@
        Write-Host $menu
        Write-Host ("-" * 108) -ForegroundColor DarkGray

        $choice = if ($NonInteractive) { "1" } else { (Read-Host "Select 1-7 or Q").Trim() }

        try {
            switch ($choice.ToUpperInvariant()) {
                "1" { New-FullBackup; Pause-Tool }
                "2" { New-FullBackup -MigrationKit; Pause-Tool }
                "3" { Restore-MigrationKit; Pause-Tool }
                "4" { Verify-ExistingPackage; Pause-Tool }
                "5" { Show-Diagnostics; Pause-Tool }
                "6" { Repair-OpenClawStack; Pause-Tool }
                "7" { Finalize-ExistingPackage; Pause-Tool }
                "Q" { return }
                default {
                    Warn "Invalid selection '$choice'. Choose 1, 2, 3, 4, 5, 6, 7, or Q."
                    Start-Sleep -Seconds 1
                }
            }
        } catch {
            Write-Host ""
            Write-Host $_.Exception.Message -ForegroundColor Red
            if ($Script:CurrentLog) {
                Write-Host "Log: $($Script:CurrentLog)" -ForegroundColor Yellow
            }
            if ($Script:ActivePackageFolder) {
                Write-Host "Failed package folder: $($Script:ActivePackageFolder)" -ForegroundColor Yellow
            }
            Stop-RunLog
            Pause-Tool
        }

        if ($NonInteractive) { return }
    }
}

Main
