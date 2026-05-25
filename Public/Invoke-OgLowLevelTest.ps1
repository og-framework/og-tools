# SPDX-License-Identifier: MPL-2.0
function Invoke-OgLowLevelTest {
    <#
    .SYNOPSIS
        Runs an og-framework Low-Level Test exe with the og-only tag filter.

    .DESCRIPTION
        Wraps the LLT exes (OGSimulationTests, OGBrawlerTests) with a default Catch2
        tag filter that whitelists only the og tests. Without this filter, UE's
        auto-included LLT framework smoke tests run alongside ours and crash because
        our targets disable engine/CoreUObject/ApplicationCore.

        The exes themselves cannot be made to self-filter without engine modifications
        — UE's LLT runner (Engine/Source/Developer/LowLevelTestsRunner/Private/TestRunner.cpp)
        forwards all unrecognised argv to Catch2 and provides no default-filter hook.
        This cmdlet supplies the filter at invocation time.

        Build the exes first via:
            <Engine>\Build\BatchFiles\Build.bat <TargetName> Win64 Development -Project=<uproject>

    .PARAMETER Suite
        Which test suite: 'simulation' or 'brawler'.

    .PARAMETER ProjectRoot
        UE project root. Defaults to current working directory. Must contain
        Binaries/Win64/<TargetName>/<TargetName>.exe.

    .PARAMETER Filter
        Override the default Catch2 tag filter. Useful for running a subset.
        Example: -Filter '[PCTM]' or -Filter '[DAttack][SimulationReconciliation]'

    .PARAMETER PassThruArgs
        Additional Catch2 arguments forwarded to the exe verbatim
        (e.g. --reporter compact, --success, --abort).

    .EXAMPLE
        oglltest brawler
        # Runs OGBrawlerTests.exe with the default brawler-only tag filter.

    .EXAMPLE
        oglltest simulation -Filter '[PCTM]'
        # Runs only the PCTM-tagged subset of og-simulation-tests.

    .EXAMPLE
        oglltest brawler --reporter junit --out brawler-results.xml
        # Default filter + junit reporter for CI ingestion.

    .OUTPUTS
        None. Writes Catch2 output to the console and returns the exe's exit code via $LASTEXITCODE.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateSet('simulation', 'brawler')]
        [string] $Suite,

        [string] $ProjectRoot = (Get-Location).Path,

        [string] $Filter,

        [Parameter(ValueFromRemainingArguments = $true)]
        [string[]] $PassThruArgs
    )

    $exeName = if ($Suite -eq 'simulation') { 'OGSimulationTests' } else { 'OGBrawlerTests' }

    # Default filter is the [@og] Catch2 tag alias — defined in C++ alongside the tests
    # (og-brawler-tests/Source/OGBrawlerTests/OgTagAliases.cpp and the og-simulation-tests
    # equivalent). The alias expands to "~[SelfTests]" which excludes UE's auto-included
    # LLT framework self-tests. Maintaining the exclusion list in C++ keeps it next to
    # the test sources — no parallel list to drift here.
    if (-not $Filter) {
        $Filter = '[@og]'
    }

    $ProjectRoot = (Resolve-Path -LiteralPath $ProjectRoot).ProviderPath
    $exePath     = Join-Path $ProjectRoot "Binaries\Win64\$exeName\$exeName.exe"

    if (-not (Test-Path -LiteralPath $exePath)) {
        Write-Error @"
LLT exe not found: $exePath

Build it first:
    `$build    = '<Engine>\Build\BatchFiles\Build.bat'
    `$uproject = '$ProjectRoot\<ProjectName>.uproject'
    & `$build $exeName Win64 Development -Project=`"`$uproject`" -WaitMutex -FromMsBuild
"@
        return
    }

    Write-Verbose "Running: $exePath $Filter $($PassThruArgs -join ' ')"
    & $exePath $Filter @PassThruArgs
}
