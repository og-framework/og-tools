# SPDX-License-Identifier: MPL-2.0

function Assert-OgSteamUploadReady {
    <#
    .SYNOPSIS
        Throws unless a loaded Steam config can be uploaded: real IDs, a builder account and a
        branch other than 'default'.

    .DESCRIPTION
        Run on the object returned by Import-OgSteamConfig before any packaging or steamcmd call.
        Collects every problem and throws once, listing all of them:
          - an AppId or DepotId that is still the placeholder 0,
          - an AppId or DepotId used more than once,
          - an empty BuilderAccount,
          - an effective branch equal to 'default' (any case). The effective branch is -Branch
            when it is passed, otherwise the config's Branch. The default branch is only ever set
            live in the Steamworks web UI.

    .PARAMETER Config
        The object returned by Import-OgSteamConfig.

    .PARAMETER Branch
        Optional branch override. When passed it replaces the config's Branch, including ''.

    .EXAMPLE
        $config = Import-OgSteamConfig -Path .\tools\steam\steam-publish.psd1
        Assert-OgSteamUploadReady -Config $config -Branch playtest

    .OUTPUTS
        None. Throws one error that lists every problem found.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNull()]
        [pscustomobject] $Config,

        [AllowEmptyString()]
        [string] $Branch
    )

    $effectiveBranch = if ($PSBoundParameters.ContainsKey('Branch')) { $Branch } else { [string]$Config.Branch }
    $problems = [System.Collections.Generic.List[string]]::new()

    if ($effectiveBranch.Trim() -eq 'default') {
        $problems.Add("Branch '$effectiveBranch' is rejected: set the default branch live in the Steamworks web UI, never from a script.")
    }

    if ([string]::IsNullOrWhiteSpace([string]$Config.BuilderAccount)) {
        $problems.Add("BuilderAccount is empty: set the Steam login name of the builder account.")
    }

    $appIds = @{}
    $depotIds = @{}
    foreach ($app in @($Config.Apps)) {
        if ($app.AppId -eq 0) {
            $problems.Add("App '$($app.Name)': AppId is the placeholder 0.")
        }
        elseif ($appIds.ContainsKey($app.AppId)) {
            $problems.Add("App '$($app.Name)': AppId $($app.AppId) is also used by app '$($appIds[$app.AppId])'.")
        }
        else {
            $appIds[$app.AppId] = $app.Name
        }

        foreach ($depot in @($app.Depots)) {
            if ($depot.DepotId -eq 0) {
                $problems.Add("Depot '$($depot.Name)': DepotId is the placeholder 0.")
            }
            elseif ($depotIds.ContainsKey($depot.DepotId)) {
                $problems.Add("Depot '$($depot.Name)': DepotId $($depot.DepotId) is also used by depot '$($depotIds[$depot.DepotId])'.")
            }
            else {
                $depotIds[$depot.DepotId] = $depot.Name
            }
        }
    }

    if ($problems.Count -gt 0) {
        throw "Steam config '$($Config.ConfigPath)' is not ready for upload:`n  - $($problems -join "`n  - ")"
    }
}
