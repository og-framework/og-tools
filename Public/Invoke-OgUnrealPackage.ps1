# SPDX-License-Identifier: MPL-2.0
function Invoke-OgUnrealPackage {
    <#
    .SYNOPSIS
        Builds, cooks, stages, packages and archives a Win64 Unreal target with UAT BuildCookRun.

    .DESCRIPTION
        Runs <EngineRoot>\Engine\Build\BatchFiles\RunUAT.bat BuildCookRun for one target type and
        configuration, archiving into -ArchiveDirectory. UAT output is streamed to the console and
        teed to <LogDirectory>\og_package_<TargetType>_<Configuration>_<yyyyMMdd-HHmmss>.log.

        Refuses to start while an UnrealEditor process is running.

        UAT arguments per TargetType:
          Client : -client -clientconfig=<cfg> -targetplatform=Win64
          Server : -server -serverconfig=<cfg> -serverplatform=Win64 -noclient
          Game   : -clientconfig=<cfg> -targetplatform=Win64
        Common   : -project=<abs> -build -cook -stage -package -pak -archive -archivedirectory=<abs> -unattended -nop4 -utf8output

        Game requires the project to have exactly one Game target or a DefaultGameTarget in
        [/Script/BuildSettings.BuildSettings]; UAT fails otherwise.

        ContentRoot is the folder UAT archives the platform build into:
        <ArchiveDirectory>\WindowsClient, \WindowsServer or \Windows (Game). When a component of
        -ArchiveDirectory already starts with that folder name or with 'Win64', UAT archives into
        -ArchiveDirectory itself and ContentRoot is -ArchiveDirectory.

    .PARAMETER ProjectFile
        Path to the .uproject.

    .PARAMETER TargetType
        Client, Server or Game.

    .PARAMETER Configuration
        Development or Shipping.

    .PARAMETER ArchiveDirectory
        Folder UAT archives into (-archivedirectory).

    .PARAMETER EngineRoot
        Engine root. Default: resolved from the .uproject EngineAssociation via the registry.

    .PARAMETER ExpectedExecutable
        Path relative to ContentRoot that must exist after a successful package, e.g. GameClient.exe.

    .PARAMETER LogDirectory
        Folder for the UAT log. Default: <project dir>\Saved\Logs.

    .OUTPUTS
        [pscustomobject] with ContentRoot, ArchiveDirectory, LogPath, ExitCode, Duration.

    .EXAMPLE
        Invoke-OgUnrealPackage -ProjectFile C:\dev\game\Game.uproject -TargetType Client -Configuration Shipping -ArchiveDirectory C:\builds\client -ExpectedExecutable GameClient.exe

    .EXAMPLE
        Invoke-OgUnrealPackage -ProjectFile .\Game.uproject -TargetType Server -Configuration Development -ArchiveDirectory .\Saved\Archive\Server -EngineRoot C:\dev\UnrealEngine
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('\.uproject$')]
        [string] $ProjectFile,

        [Parameter(Mandatory)]
        [ValidateSet('Client', 'Server', 'Game')]
        [string] $TargetType,

        [Parameter(Mandatory)]
        [ValidateSet('Development', 'Shipping')]
        [string] $Configuration,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $ArchiveDirectory,

        [string] $EngineRoot,

        [ValidateScript({ -not [System.IO.Path]::IsPathRooted($_) })]
        [string] $ExpectedExecutable,

        [string] $LogDirectory
    )

    $projectPath = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($ProjectFile)
    if (-not (Test-Path -LiteralPath $projectPath -PathType Leaf)) {
        throw "Invoke-OgUnrealPackage: project file '$projectPath' does not exist."
    }
    $archivePath = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($ArchiveDirectory)
    $logDir = if ($LogDirectory) {
        $PSCmdlet.GetUnresolvedProviderPathFromPSPath($LogDirectory)
    }
    else {
        Join-Path (Split-Path -Parent $projectPath) 'Saved\Logs'
    }

    $editor = Get-Process -Name 'UnrealEditor' -ErrorAction SilentlyContinue
    if ($editor) {
        throw "Invoke-OgUnrealPackage: UnrealEditor is running (PID $(@($editor.Id) -join ', ')). Close the editor before packaging; UAT cannot rebuild binaries it holds open."
    }

    $engine = Resolve-OgUnrealEngineRoot -ProjectFile $projectPath -EngineRoot $EngineRoot
    $runUat = Join-Path $engine 'Engine\Build\BatchFiles\RunUAT.bat'

    $targetArgs = switch ($TargetType) {
        'Client' { '-client', "-clientconfig=$Configuration", '-targetplatform=Win64' }
        'Server' { '-server', "-serverconfig=$Configuration", '-serverplatform=Win64', '-noclient' }
        'Game'   { "-clientconfig=$Configuration", '-targetplatform=Win64' }
    }
    $uatArgs = @('BuildCookRun', "-project=$projectPath") + $targetArgs + @(
        '-build', '-cook', '-stage', '-package', '-pak',
        '-archive', "-archivedirectory=$archivePath",
        '-unattended', '-nop4', '-utf8output'
    )

    $logPath = Join-Path $logDir ("og_package_{0}_{1}_{2}.log" -f $TargetType, $Configuration, (Get-Date -Format 'yyyyMMdd-HHmmss'))

    $result = Invoke-OgProcess -FilePath $runUat -ArgumentList $uatArgs -WorkingDirectory $engine -LogPath $logPath
    if ($result.ExitCode -ne 0) {
        throw "Invoke-OgUnrealPackage: UAT BuildCookRun failed with exit code $($result.ExitCode). Log: $logPath"
    }

    $cookPlatform = switch ($TargetType) {
        'Client' { 'WindowsClient' }
        'Server' { 'WindowsServer' }
        'Game'   { 'Windows' }
    }
    $components = $archivePath.Split([System.IO.Path]::DirectorySeparatorChar, [System.StringSplitOptions]::RemoveEmptyEntries)
    $archiveNamesPlatform = $components | Where-Object {
        $_.StartsWith($cookPlatform, [System.StringComparison]::OrdinalIgnoreCase) -or
        $_.StartsWith('Win64', [System.StringComparison]::OrdinalIgnoreCase)
    }
    $contentRoot = if ($archiveNamesPlatform) { $archivePath } else { Join-Path $archivePath $cookPlatform }

    if ($ExpectedExecutable) {
        $exe = Join-Path $contentRoot $ExpectedExecutable
        if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
            throw "Invoke-OgUnrealPackage: UAT succeeded but the expected executable '$exe' does not exist. Log: $logPath"
        }
    }

    [pscustomobject]@{
        ContentRoot      = $contentRoot
        ArchiveDirectory = $archivePath
        LogPath          = $logPath
        ExitCode         = $result.ExitCode
        Duration         = $result.Duration
    }
}
