# SPDX-License-Identifier: MPL-2.0
function New-OgSteamBuildVdf {
    <#
    .SYNOPSIS
        Writes the SteamPipe app build VDF and one depot build VDF per depot.

    .DESCRIPTION
        Generates app_build_<AppId>.vdf and depot_build_<DepotId>.vdf files in SteamPipe
        KeyValues format (https://partner.steamgames.com/doc/sdk/uploading) for use with
        steamcmd +run_app_build. The app VDF references each depot VDF by absolute path and
        leaves its own ContentRoot empty; every depot VDF carries its own absolute ContentRoot
        and maps all of it recursively to the depot root.

        String values are escaped per KeyValues rules (backslash and double quote). Values
        containing control characters are rejected. Files are written tab-indented, LF line
        endings, UTF-8 without BOM, overwriting existing files of the same name.

        SetLive 'default' is rejected in any letter case: Steam cannot set the default branch
        live from a build script; that is done in the Steamworks web UI.

    .PARAMETER AppId
        Steam application ID. 0 is accepted so placeholder configurations can generate files.

    .PARAMETER Description
        Build description shown in Steamworks (the "Desc" key).

    .PARAMETER BuildOutput
        Absolute directory where steamcmd writes build logs and cache.

    .PARAMETER SetLive
        Branch to set the build live on after upload. Empty omits the key.

    .PARAMETER Preview
        Writes "Preview" "1": steamcmd produces logs and a manifest without uploading.

    .PARAMETER Depots
        One or more hashtables or objects with keys DepotId (non-negative integer, unique),
        ContentRoot (absolute directory) and optional FileExclusions (string patterns).

    .PARAMETER OutputDirectory
        Absolute directory the VDF files are written to. Created if missing.

    .OUTPUTS
        System.String. Absolute path of the app build VDF.

    .EXAMPLE
        New-OgSteamBuildVdf -AppId 480 -Description '20260926-120000-abc1234' `
            -BuildOutput 'D:\Builds\_steam\output' -SetLive 'playtest' `
            -Depots @(@{ DepotId = 481; ContentRoot = 'D:\Builds\client\WindowsClient'; FileExclusions = @('*.pdb') }) `
            -OutputDirectory 'D:\Builds\_steam'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [uint32] $AppId,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Description,

        [Parameter(Mandatory)]
        [ValidateScript({ [System.IO.Path]::IsPathFullyQualified($_) }, ErrorMessage = "BuildOutput must be an absolute path: '{0}'")]
        [string] $BuildOutput,

        [AllowEmptyString()]
        [string] $SetLive = '',

        [switch] $Preview,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $Depots,

        [Parameter(Mandatory)]
        [ValidateScript({ [System.IO.Path]::IsPathFullyQualified($_) }, ErrorMessage = "OutputDirectory must be an absolute path: '{0}'")]
        [string] $OutputDirectory
    )

    $escape = {
        param([string] $Name, [string] $Value)
        if ($Value -match '[\x00-\x1F\x7F]') {
            throw "$Name contains a control character, which a VDF string cannot hold: '$Value'."
        }
        '"' + $Value.Replace('\', '\\').Replace('"', '\"') + '"'
    }

    $null = & $escape 'Description' $Description
    $null = & $escape 'SetLive' $SetLive
    $null = & $escape 'BuildOutput' $BuildOutput

    if ($SetLive -ieq 'default') {
        throw "SetLive 'default' is not allowed: the default branch can only be set live in the Steamworks web UI."
    }

    if ($Depots.Count -eq 0) {
        throw 'Depots must contain at least one depot.'
    }

    $allowedDepotKeys = @('DepotId', 'ContentRoot', 'FileExclusions')
    $normalized = [System.Collections.Generic.List[pscustomobject]]::new()
    $seenIds = [System.Collections.Generic.HashSet[uint32]]::new()

    for ($i = 0; $i -lt $Depots.Count; $i++) {
        $depot = $Depots[$i]
        if ($null -eq $depot) {
            throw "Depots[$i] is null."
        }

        $values = @{}
        if ($depot -is [System.Collections.IDictionary]) {
            foreach ($key in $depot.Keys) { $values[[string]$key] = $depot[$key] }
        } else {
            foreach ($prop in $depot.PSObject.Properties) { $values[$prop.Name] = $prop.Value }
        }

        foreach ($key in $values.Keys) {
            if ($allowedDepotKeys -notcontains $key) {
                throw "Depots[$i] has unknown key '$key'. Allowed keys: $($allowedDepotKeys -join ', ')."
            }
        }

        if (-not $values.ContainsKey('DepotId') -or $null -eq $values['DepotId']) {
            throw "Depots[$i] is missing required key 'DepotId'."
        }
        $rawId = $values['DepotId']
        if ($rawId -isnot [int] -and $rawId -isnot [long] -and $rawId -isnot [uint32] -and $rawId -isnot [int16] -and $rawId -isnot [byte]) {
            throw "Depots[$i].DepotId must be an integer, got '$rawId' ($($rawId.GetType().Name))."
        }
        if ($rawId -lt 0 -or $rawId -gt [uint32]::MaxValue) {
            throw "Depots[$i].DepotId is out of range: $rawId."
        }
        $depotId = [uint32]$rawId
        if (-not $seenIds.Add($depotId)) {
            throw "Duplicate DepotId $depotId in Depots."
        }

        $contentRoot = [string]$values['ContentRoot']
        if ([string]::IsNullOrWhiteSpace($contentRoot)) {
            throw "Depots[$i] (DepotId $depotId) is missing required key 'ContentRoot'."
        }
        if (-not [System.IO.Path]::IsPathFullyQualified($contentRoot)) {
            throw "Depots[$i].ContentRoot must be an absolute path: '$contentRoot'."
        }
        $null = & $escape "Depots[$i].ContentRoot" $contentRoot

        $exclusions = @()
        if ($values.ContainsKey('FileExclusions') -and $null -ne $values['FileExclusions']) {
            $exclusions = @($values['FileExclusions'])
        }
        foreach ($pattern in $exclusions) {
            if ($pattern -isnot [string] -or [string]::IsNullOrWhiteSpace($pattern)) {
                throw "Depots[$i].FileExclusions (DepotId $depotId) must contain only non-empty strings."
            }
            $null = & $escape "Depots[$i].FileExclusions" $pattern
        }

        $normalized.Add([pscustomobject]@{
            DepotId        = $depotId
            ContentRoot    = [System.IO.Path]::GetFullPath($contentRoot)
            FileExclusions = [string[]]$exclusions
        })
    }

    $outDir = [System.IO.Path]::GetFullPath($OutputDirectory)
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    if (-not (Test-Path -LiteralPath $outDir -PathType Container)) {
        New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    }

    $depotFiles = [ordered]@{}
    foreach ($depot in $normalized) {
        $lines = [System.Collections.Generic.List[string]]::new()
        $lines.Add('"DepotBuild"')
        $lines.Add('{')
        $lines.Add("`t`"DepotID`"`t" + (& $escape 'DepotId' ([string]$depot.DepotId)))
        $lines.Add("`t`"ContentRoot`"`t" + (& $escape 'ContentRoot' $depot.ContentRoot))
        $lines.Add("`t`"FileMapping`"")
        $lines.Add("`t{")
        $lines.Add("`t`t`"LocalPath`"`t`"*`"")
        $lines.Add("`t`t`"DepotPath`"`t`".`"")
        $lines.Add("`t`t`"recursive`"`t`"1`"")
        $lines.Add("`t}")
        foreach ($pattern in $depot.FileExclusions) {
            $lines.Add("`t`"FileExclusion`"`t" + (& $escape 'FileExclusion' $pattern))
        }
        $lines.Add('}')

        $depotPath = Join-Path $outDir "depot_build_$($depot.DepotId).vdf"
        [System.IO.File]::WriteAllText($depotPath, (($lines -join "`n") + "`n"), $utf8NoBom)
        $depotFiles[[string]$depot.DepotId] = $depotPath
    }

    $app = [System.Collections.Generic.List[string]]::new()
    $app.Add('"AppBuild"')
    $app.Add('{')
    $app.Add("`t`"AppID`"`t" + (& $escape 'AppId' ([string]$AppId)))
    $app.Add("`t`"Desc`"`t" + (& $escape 'Description' $Description))
    $app.Add("`t`"BuildOutput`"`t" + (& $escape 'BuildOutput' ([System.IO.Path]::GetFullPath($BuildOutput))))
    $app.Add("`t`"ContentRoot`"`t`"`"")
    if ($SetLive -ne '') {
        $app.Add("`t`"SetLive`"`t" + (& $escape 'SetLive' $SetLive))
    }
    $app.Add("`t`"Preview`"`t`"" + ($Preview.IsPresent ? '1' : '0') + '"')
    $app.Add("`t`"Depots`"")
    $app.Add("`t{")
    foreach ($id in $depotFiles.Keys) {
        $app.Add("`t`t" + (& $escape 'DepotId' $id) + "`t" + (& $escape 'DepotVdfPath' $depotFiles[$id]))
    }
    $app.Add("`t}")
    $app.Add('}')

    $appPath = Join-Path $outDir "app_build_$AppId.vdf"
    [System.IO.File]::WriteAllText($appPath, (($app -join "`n") + "`n"), $utf8NoBom)
    $appPath
}
