# SPDX-License-Identifier: MPL-2.0
<#
.SYNOPSIS
    Runs the og-tools Pester suite with one pwsh process per test file, a few at a time, and sums the
    results.

.DESCRIPTION
    Every *.Tests.ps1 file under -Path runs in its OWN `pwsh -NoProfile -NonInteractive` child process,
    at most -ThrottleLimit at once, with stdin closed. Each child runs Invoke-Pester on its one file and
    writes a small JSON result; this script waits for all of them, prints one line per file as it
    finishes, then a summary table (counts and duration per file, in run order) and the totals, and
    exits non-zero if any test failed or any child did not finish cleanly.

    It is an alternative to `Invoke-Pester -Path tests`, which keeps working unchanged (this script
    is not a *.Tests.ps1 file, so Pester never collects it).

    Why one process per file, and why these defaults (measured, od task 13, 2026-10-23):
      - Time: the files are independent (each builds its own repos under its own $TestDrive and
        imports the module itself), and the slow ones are slow on git work, not CPU, so running a few
        at once cuts the wall time to about the slowest file's.
      - Memory: the whole suite in ONE process was killed twice by a low-memory reaper on a machine
        with 3-6 GB free. A process per file returns its memory when the file ends, and the throttle
        bounds how many are alive. The default, min(logical CPUs / 2, 4), keeps that bound small on a
        many-core machine; the runner reports the peak working set it saw, so a lower -ThrottleLimit
        can be chosen from data.
      - -NonInteractive and a closed stdin: without them Publish-OgSteamBuild.Tests hangs on a prompt
        and a Push-OgFramework -WhatIf test fails. Do not drop either.

    Logs: each child's console output and JSON result go to -OutputDirectory (by default a new folder
    under %TEMP%\og-test-suite), never into the repo.

.PARAMETER Path
    A tests folder, or test files. Default: the folder this script is in. Several may follow -Path
    separated by spaces; under `pwsh -File`, a list written with commas arrives as separate words
    with a trailing comma each (`a,` `b`), so a trailing comma is dropped from each word.

.PARAMETER ThrottleLimit
    How many test files run at once. Default: min(logical CPUs / 2, 4), at least 1.

.PARAMETER OutputDirectory
    Where the per-file logs and results go. Default: %TEMP%\og-test-suite\<yyyyMMdd-HHmmss>.

.PARAMETER TimeoutMinutes
    A child still running after this long is killed (with its process tree) and reported as
    timed-out. Default 30; 0 waits forever.

.PARAMETER PassThru
    Also returns one result object per file.

.EXAMPLE
    pwsh -NoProfile -File tests\Invoke-OgTestSuite.ps1
    Runs every test file, four at a time on a machine with 8 or more logical CPUs.

.EXAMPLE
    pwsh -NoProfile -File tests\Invoke-OgTestSuite.ps1 -ThrottleLimit 2 -Path tests\Show-OgDiff.Tests.ps1 tests\Resolve-OgCommitRange.Tests.ps1
    Runs two files side by side.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)] [string[]] $Path = @($PSScriptRoot),
    [ValidateRange(1, 64)] [int] $ThrottleLimit =
        [Math]::Max(1, [Math]::Min([int][Math]::Floor([Environment]::ProcessorCount / 2), 4)),
    [string] $OutputDirectory,
    [ValidateRange(0, 1440)] [int] $TimeoutMinutes = 30,
    [switch] $PassThru,
    # The words after -Path's first one (see -Path). A named parameter takes one word, so the rest
    # would be a binding error without this.
    [Parameter(ValueFromRemainingArguments, DontShow)] [string[]] $MorePath
)

$ErrorActionPreference = 'Stop'

<#
.SYNOPSIS
    The command a child pwsh runs: Invoke-Pester on ONE test file, then its counts as JSON.
.DESCRIPTION
    A self-contained -EncodedCommand, not this script in a child mode: the test file then runs in a
    pristine session, with none of this script's variables or its $ErrorActionPreference = 'Stop' in
    scope (PowerShell scoping is dynamic, so a test would see them), the same as under a plain
    Invoke-Pester. The JSON is the only channel back: counts, Pester's own duration and the failed
    tests' names. Exit code 0 when nothing failed, 1 otherwise; a child that dies before writing the
    JSON is reported as crashed.
.PARAMETER TestFile
    The test file.
.PARAMETER ResultFile
    The JSON file to write.
#>
function Get-OgTestSuiteChildCommand {
    param([Parameter(Mandatory)] [string] $TestFile, [Parameter(Mandatory)] [string] $ResultFile)
    $q = { param($s) "'" + $s.Replace("'", "''") + "'" }
    $script = @"
Import-Module Pester -MinimumVersion 5.0
`$__ogSuiteConfig = New-PesterConfiguration
`$__ogSuiteConfig.Run.Path = $(& $q $TestFile)
`$__ogSuiteConfig.Run.PassThru = `$true
`$__ogSuiteConfig.Output.Verbosity = 'Normal'
`$__ogSuiteResult = Invoke-Pester -Configuration `$__ogSuiteConfig
[PSCustomObject]@{
    Passed = `$__ogSuiteResult.PassedCount; Failed = `$__ogSuiteResult.FailedCount; Skipped = `$__ogSuiteResult.SkippedCount
    NotRun = `$__ogSuiteResult.NotRunCount; Total = `$__ogSuiteResult.TotalCount; Result = "`$(`$__ogSuiteResult.Result)"
    PesterSeconds = [Math]::Round(`$__ogSuiteResult.Duration.TotalSeconds, 1)
    FailedTests = @(`$__ogSuiteResult.Failed | ForEach-Object { `$_.ExpandedPath })
} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $(& $q $ResultFile) -Encoding utf8
if (`$__ogSuiteResult.FailedCount -gt 0 -or "`$(`$__ogSuiteResult.Result)" -ne 'Passed') { exit 1 }
exit 0
"@
    [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($script))
}

<#
.SYNOPSIS
    The test files to run: every *.Tests.ps1 under each folder of -Path, and each file given directly.
.DESCRIPTION
    Sorted largest first, so the slowest files (the big ones) start first and the short ones fill the
    gaps; with a throttle, starting a long file last would make it the tail of the whole run.
.PARAMETER Path
    Folders and/or files.
#>
function Get-OgTestSuiteFile {
    param([Parameter(Mandatory)] [string[]] $Path)
    $files = foreach ($p in $Path) {
        $p = $p.TrimEnd(',')
        if (-not $p) { continue }
        $item = Get-Item -LiteralPath $p
        if ($item.PSIsContainer) { Get-ChildItem -LiteralPath $item.FullName -Filter '*.Tests.ps1' -File -Recurse }
        else { $item }
    }
    @($files | Sort-Object FullName -Unique | Sort-Object Length -Descending)
}

<#
.SYNOPSIS
    Starts one child pwsh for one test file, its stdout and stderr copied into two log files.
.DESCRIPTION
    stdin is redirected and closed at once, so a prompt reads end-of-input instead of waiting (with
    -NonInteractive, it fails instead of hanging). stdout and stderr are copied to the logs by .NET
    stream copies that run on their own, without this script's help: a child whose output pipe nobody
    reads blocks once the pipe buffer is full, and PowerShell event handlers only run when this script
    yields, so they are not used.
.PARAMETER TestFile
    The test file.
.PARAMETER LogFile
    The console log (stdout); stderr goes beside it as <name>.err.log.
.PARAMETER ResultFile
    The child's JSON result.
#>
function Start-OgTestSuiteChild {
    param([string] $TestFile, [string] $LogFile, [string] $ResultFile)
    $psi = [System.Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
    foreach ($a in '-NoProfile', '-NonInteractive', '-EncodedCommand', (Get-OgTestSuiteChildCommand -TestFile $TestFile -ResultFile $ResultFile)) {
        $psi.ArgumentList.Add($a)
    }
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardInput  = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.CreateNoWindow         = $true
    $psi.WorkingDirectory       = Split-Path -Parent $TestFile
    $proc = [System.Diagnostics.Process]::new()
    $proc.StartInfo = $psi
    [void] $proc.Start()
    $proc.StandardInput.Close()
    $errLog = [System.IO.Path]::ChangeExtension($LogFile, '.err.log')
    $outFile = [System.IO.File]::Create($LogFile)
    $errFile = [System.IO.File]::Create($errLog)
    [PSCustomObject]@{
        File = $TestFile; Process = $proc; Log = $LogFile; ErrLog = $errLog; ResultFile = $ResultFile
        Streams = @($outFile, $errFile)
        Copies  = @($proc.StandardOutput.BaseStream.CopyToAsync($outFile), $proc.StandardError.BaseStream.CopyToAsync($errFile))
        Started = [DateTime]::UtcNow; PeakWorkingSet = 0L; TimedOut = $false
    }
}

<#
.SYNOPSIS
    Reads a finished child's JSON result into one result row, or a crashed/timed-out row without one.
.PARAMETER Child
    The child record from Start-OgTestSuiteChild, after its process exited.
#>
function Complete-OgTestSuiteChild {
    param([Parameter(Mandatory)] $Child)
    $Child.Process.WaitForExit()
    [void] [System.Threading.Tasks.Task]::WaitAll([System.Threading.Tasks.Task[]] $Child.Copies, [TimeSpan]::FromSeconds(30))
    foreach ($stream in $Child.Streams) { $stream.Dispose() }
    $wall = ([DateTime]::UtcNow - $Child.Started).TotalSeconds
    $exit = $Child.Process.ExitCode
    $json = if (Test-Path -LiteralPath $Child.ResultFile) { Get-Content -LiteralPath $Child.ResultFile -Raw | ConvertFrom-Json } else { $null }
    $status = if ($Child.TimedOut) { 'timed-out' } elseif ($null -eq $json) { 'crashed' }
              elseif ($json.Failed -gt 0 -or $json.Result -ne 'Passed') { 'failed' } elseif ($exit -ne 0) { 'crashed' } else { 'passed' }
    [PSCustomObject]@{
        PSTypeName  = 'Og.TestSuiteFileResult'
        File        = Split-Path $Child.File -Leaf
        Status      = $status
        Passed      = if ($json) { [int] $json.Passed } else { 0 }
        Failed      = if ($json) { [int] $json.Failed } else { 0 }
        Skipped     = if ($json) { [int] $json.Skipped } else { 0 }
        NotRun      = if ($json) { [int] $json.NotRun } else { 0 }
        Total       = if ($json) { [int] $json.Total } else { 0 }
        Seconds     = [Math]::Round($wall, 1)
        PeakMB      = [Math]::Round($Child.PeakWorkingSet / 1MB)
        ExitCode    = $exit
        FailedTests = if ($json) { @($json.FailedTests) } else { @() }
        Log         = $Child.Log
    }
}

if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ('og-test-suite\' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
}
[void] [System.IO.Directory]::CreateDirectory($OutputDirectory)
$files = Get-OgTestSuiteFile -Path (@($Path) + @($MorePath) | Where-Object { $_ })
if ($files.Count -eq 0) { throw "No *.Tests.ps1 file found under: $($Path -join ', ')" }

Write-Host ("Running {0} test file(s), {1} at a time; logs in {2}" -f $files.Count, $ThrottleLimit, $OutputDirectory)
$clock   = [System.Diagnostics.Stopwatch]::StartNew()
$queue   = [System.Collections.Generic.Queue[object]]::new([object[]] $files)
$running = [System.Collections.Generic.List[object]]::new()
$results = [System.Collections.Generic.List[object]]::new()
$self    = Get-Process -Id $PID
$peakTotal = 0L
$peakSelf  = 0L
$timeout = if ($TimeoutMinutes -gt 0) { [TimeSpan]::FromMinutes($TimeoutMinutes) } else { [TimeSpan]::MaxValue }

try {
    while ($queue.Count -gt 0 -or $running.Count -gt 0) {
        while ($queue.Count -gt 0 -and $running.Count -lt $ThrottleLimit) {
            $f = $queue.Dequeue()
            $stem = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
            $running.Add((Start-OgTestSuiteChild -TestFile $f.FullName -LogFile (Join-Path $OutputDirectory "$stem.log") `
                -ResultFile (Join-Path $OutputDirectory "$stem.result.json")))
        }
        Start-Sleep -Milliseconds 250
        # Memory: the runner's own working set plus every live child's, sampled each poll. A child's
        # git.exe grandchildren are short-lived and not included.
        $self.Refresh()
        $sum = $self.WorkingSet64
        $peakSelf = [Math]::Max($peakSelf, $self.PeakWorkingSet64)
        foreach ($c in @($running)) {
            if (-not $c.Process.HasExited) {
                try {
                    $c.Process.Refresh()
                    $sum += $c.Process.WorkingSet64
                    $c.PeakWorkingSet = [Math]::Max($c.PeakWorkingSet, $c.Process.PeakWorkingSet64)
                } catch [System.InvalidOperationException] { }   # exited between the check and the read
                if (([DateTime]::UtcNow - $c.Started) -gt $timeout) {
                    $c.TimedOut = $true
                    $c.Process.Kill($true)
                }
            }
            if ($c.Process.HasExited) {
                [void] $running.Remove($c)
                $row = Complete-OgTestSuiteChild -Child $c
                $results.Add($row)
                Write-Host ("[{0,2}/{1}] {2,-9} {3,-44} {4,4} passed {5,3} failed {6,3} skipped {7,7:n1} s {8,5} MB" -f
                    $results.Count, $files.Count, $row.Status, $row.File, $row.Passed, $row.Failed, $row.Skipped, $row.Seconds, $row.PeakMB)
            }
        }
        $peakTotal = [Math]::Max($peakTotal, $sum)
    }
} finally {
    # Ctrl+C or an error in the runner: never leave children behind.
    foreach ($c in @($running)) { if (-not $c.Process.HasExited) { $c.Process.Kill($true) } }
}
$clock.Stop()

$results | Format-Table File, Status, Passed, Failed, Skipped, NotRun, Total, Seconds, PeakMB -AutoSize | Out-Host
$sumOf = { param($name) ($results | Measure-Object -Property $name -Sum).Sum }
Write-Host ("Total: {0} passed, {1} failed, {2} skipped, {3} not run, {4} tests in {5} files; wall {6:n1} s (sum of file times {7:n1} s)" -f
    (& $sumOf Passed), (& $sumOf Failed), (& $sumOf Skipped), (& $sumOf NotRun), (& $sumOf Total), $results.Count,
    $clock.Elapsed.TotalSeconds, (& $sumOf Seconds))
Write-Host ("Peak working set: runner {0:n0} MB, largest child {1:n0} MB, runner + live children together {2:n0} MB (sampled every 250 ms)" -f
    ($peakSelf / 1MB), (($results | Measure-Object -Property PeakMB -Maximum).Maximum), ($peakTotal / 1MB))
$bad = @($results | Where-Object Status -ne 'passed')
foreach ($b in $bad) {
    Write-Host "$($b.Status): $($b.File) (exit $($b.ExitCode); log $($b.Log))"
    foreach ($t in $b.FailedTests) { Write-Host "    $t" }
}
if ($PassThru) { $results }
if ($bad.Count -gt 0) { exit 1 }
exit 0
