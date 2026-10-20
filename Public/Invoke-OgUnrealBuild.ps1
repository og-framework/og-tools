# SPDX-License-Identifier: MPL-2.0
function Invoke-OgUnrealBuild {
    <#
    .SYNOPSIS
        Builds one or more Unreal targets with UnrealBuildTool (Build.bat). By default it builds the project's Editor target, which
        is the binary that Start-OgPlaytest runs.

    .DESCRIPTION
        For each target, in order, runs:
            <EngineRoot>\Engine\Build\BatchFiles\Build.bat <Target> <Platform> <Configuration> -Project=<abs .uproject> -WaitMutex -FromMsBuild
        with -NoHotReload added for Editor targets (names ending in 'Editor'). The output is streamed to the console and teed to
        <LogDirectory>\og_build_<Target>_<Configuration>_<yyyyMMdd-HHmmss>.log. The cmdlet stops at the first target that fails.

        Target names:
          - Omit -Target to build '<ProjectName>Editor' (for OGBrawlerUnreal.uproject: OGBrawlerUnrealEditor). Start-OgPlaytest
            launches that binary with -game, as standalone server and client processes.
          - 'Editor', 'Game', 'Client' and 'Server' are shorthands for '<ProjectName>Editor', '<ProjectName>',
            '<ProjectName>Client' and '<ProjectName>Server'.
          - Any other name is passed to UBT verbatim, for example the Low-Level Test targets 'OGSimulationTests' and
            'OGBrawlerTests'.

        It refuses to build an Editor target while an UnrealEditor process is running, unless -Force is given: UBT cannot replace
        DLLs that a running editor or a running playtest (Start-OgPlaytest) holds open.

    .PARAMETER ProjectFile
        Path to the .uproject. Default: the single .uproject in the current directory.

    .PARAMETER Target
        One or more targets (see the description). Default: Editor.

    .PARAMETER Configuration
        Debug, DebugGame, Development, Test or Shipping. Default: Development.

    .PARAMETER Platform
        Default: Win64.

    .PARAMETER EngineRoot
        Engine root. Default: resolved from the .uproject's EngineAssociation through the registry.

    .PARAMETER LogDirectory
        Folder for the build logs. Default: <project dir>\Saved\Logs.

    .PARAMETER Force
        Build an Editor target even while an UnrealEditor process is running.

    .OUTPUTS
        One [pscustomobject] per target that ran: Target, Configuration, ExitCode, LogPath and Duration.

    .EXAMPLE
        ogbuild
        # Builds <ProjectName>Editor Win64 Development, the binary the playtest runs.

    .EXAMPLE
        ogbuild -Target Editor, OGSimulationTests, OGBrawlerTests
        # The Editor plus both Low-Level Test targets, one after the other.

    .EXAMPLE
        Invoke-OgUnrealBuild -ProjectFile C:\dev\og-brawler-unreal\OGBrawlerUnreal.uproject -Target Server -Configuration Shipping
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [ValidatePattern('\.uproject$')]
        [string] $ProjectFile,

        [string[]] $Target = @('Editor'),

        [ValidateSet('Debug', 'DebugGame', 'Development', 'Test', 'Shipping')]
        [string] $Configuration = 'Development',

        [string] $Platform = 'Win64',

        [string] $EngineRoot,

        [string] $LogDirectory,

        [switch] $Force
    )

    $projectPath = Resolve-OgProjectFile -ProjectFile $ProjectFile -CallerName 'Invoke-OgUnrealBuild'
    $projectName = [System.IO.Path]::GetFileNameWithoutExtension($projectPath)
    $logDir = if ($LogDirectory) {
        $PSCmdlet.GetUnresolvedProviderPathFromPSPath($LogDirectory)
    }
    else {
        Join-Path (Split-Path -Parent $projectPath) 'Saved\Logs'
    }

    $targets = foreach ($t in $Target) {
        switch ($t) {
            'Editor' { "${projectName}Editor" }
            'Game'   { $projectName }
            'Client' { "${projectName}Client" }
            'Server' { "${projectName}Server" }
            default  { $t }
        }
    }

    $buildsEditor = @($targets | Where-Object { $_ -like '*Editor' }).Count -gt 0
    if ($buildsEditor -and -not $Force) {
        $editor = Get-Process -Name 'UnrealEditor' -ErrorAction SilentlyContinue
        if ($editor) {
            throw "Invoke-OgUnrealBuild: UnrealEditor is running (PID $(@($editor.Id) -join ', ')). Close the editor and any playtest before building an Editor target, or pass -Force."
        }
    }

    $engine = Resolve-OgUnrealEngineRoot -ProjectFile $projectPath -EngineRoot $EngineRoot
    $buildBat = Join-Path $engine 'Engine\Build\BatchFiles\Build.bat'
    if (-not (Test-Path -LiteralPath $buildBat -PathType Leaf)) {
        throw "Invoke-OgUnrealBuild: '$buildBat' does not exist."
    }

    foreach ($t in $targets) {
        $buildArgs = @($t, $Platform, $Configuration, "-Project=$projectPath", '-WaitMutex', '-FromMsBuild')
        if ($t -like '*Editor') { $buildArgs += '-NoHotReload' }
        $logPath = Join-Path $logDir ("og_build_{0}_{1}_{2}.log" -f $t, $Configuration, (Get-Date -Format 'yyyyMMdd-HHmmss'))

        if (-not $PSCmdlet.ShouldProcess("$t $Platform $Configuration", 'Build with UnrealBuildTool')) { continue }

        $result = Invoke-OgProcess -FilePath $buildBat -ArgumentList $buildArgs -WorkingDirectory $engine -LogPath $logPath
        [pscustomobject]@{
            Target        = $t
            Configuration = $Configuration
            ExitCode      = $result.ExitCode
            LogPath       = $logPath
            Duration      = $result.Duration
        }
        if ($result.ExitCode -ne 0) {
            throw "Invoke-OgUnrealBuild: building $t failed with exit code $($result.ExitCode). Log: $logPath"
        }
    }
}
