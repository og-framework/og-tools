# SPDX-License-Identifier: MPL-2.0
function Assert-OgServerLauncherSettings {
    <#
    .SYNOPSIS
        Validates the values of a dedicated-server host launcher; throws naming the first bad key.

    .DESCRIPTION
        Shared by Import-OgSteamConfig (depot key ServerLauncher) and New-OgDedicatedServerLauncher.

          Title            non-empty, no double quote (it names the firewall rule), no line break
          Port             1-65535
          JoinLinePattern  a valid .NET regex defining the named groups joined, left and players
                           (tested and local are optional)
          ReadyLinePattern '' or a valid .NET regex
          ClientLaunch     no entry, a single '', or one or more entries, each a URI such as
                           steam://rungameid/<id> or a path relative to the launcher folder;
                           {AppId:<app name>} tokens must name an app in AppNames; an entry of
                           a list of two or more must not be empty
          ServerArguments, LocalHint  no line break

        Every message has the form '<Prefix><Key>' <problem>. A ClientLaunch entry of a list of two
        or more is named ClientLaunch[<index>].

    .PARAMETER Prefix
        Text put in front of each key name in error messages, e.g. 'Apps[1].Depots[0].ServerLauncher.'.

    .PARAMETER AppNames
        App names that {AppId:<name>} tokens in ClientLaunch may reference.
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyString()] [string] $Title,
        [int] $Port,
        [AllowEmptyString()] [string] $ServerArguments = '',
        [AllowEmptyString()] [string] $JoinLinePattern,
        [AllowEmptyString()] [string] $ReadyLinePattern = '',
        [AllowEmptyCollection()] [AllowEmptyString()] [string[]] $ClientLaunch = @(),
        [AllowEmptyString()] [string] $LocalHint = '',
        [string[]] $AppNames = @(),
        [string] $Prefix = ''
    )

    $launchEntries = @($ClientLaunch)
    $launchKey = {
        param([int] $Index)
        if ($launchEntries.Count -gt 1) { "ClientLaunch[$Index]" } else { 'ClientLaunch' }
    }

    $values = [ordered]@{
        Title            = $Title
        ServerArguments  = $ServerArguments
        JoinLinePattern  = $JoinLinePattern
        ReadyLinePattern = $ReadyLinePattern
        LocalHint        = $LocalHint
    }
    for ($i = 0; $i -lt $launchEntries.Count; $i++) { $values[(& $launchKey $i)] = $launchEntries[$i] }
    foreach ($key in $values.Keys) {
        if ([string]$values[$key] -match '[\r\n]') {
            throw "'$Prefix$key' must be a single line."
        }
    }

    if ([string]::IsNullOrWhiteSpace($Title)) {
        throw "'${Prefix}Title' must not be empty."
    }
    if ($Title.Contains('"')) {
        throw "'${Prefix}Title' must not contain a double quote; it names the firewall rule."
    }

    if ($Port -lt 1 -or $Port -gt 65535) {
        throw "'${Prefix}Port' must be between 1 and 65535, got $Port."
    }

    if ([string]::IsNullOrWhiteSpace($JoinLinePattern)) {
        throw "'${Prefix}JoinLinePattern' must not be empty."
    }
    try {
        $joinRegex = [regex]::new($JoinLinePattern)
    }
    catch {
        throw "'${Prefix}JoinLinePattern' is not a valid regular expression: $($_.Exception.InnerException.Message)"
    }
    $groupNames = $joinRegex.GetGroupNames()
    $missing = @('joined', 'left', 'players') | Where-Object { $groupNames -notcontains $_ }
    if ($missing) {
        throw "'${Prefix}JoinLinePattern' must define the named groups (?<joined>...), (?<left>...) and (?<players>...); missing: $($missing -join ', ')."
    }

    if ($ReadyLinePattern -ne '') {
        try {
            $null = [regex]::new($ReadyLinePattern)
        }
        catch {
            throw "'${Prefix}ReadyLinePattern' is not a valid regular expression: $($_.Exception.InnerException.Message)"
        }
    }

    for ($i = 0; $i -lt $launchEntries.Count; $i++) {
        $entry = [string]$launchEntries[$i]
        $key = "$Prefix$(& $launchKey $i)"
        if ([string]::IsNullOrWhiteSpace($entry)) {
            if ($launchEntries.Count -gt 1) {
                throw "'$key' must not be empty."
            }
            continue
        }
        foreach ($token in [regex]::Matches($entry, '\{AppId:(?<name>[^}]*)\}')) {
            $name = $token.Groups['name'].Value
            if ($AppNames -notcontains $name) {
                throw "'$key' references unknown app '$name' in '$($token.Value)'. Known apps: $($AppNames -join ', ')."
            }
        }
        $isUri = $entry -match '^[A-Za-z][A-Za-z0-9+.-]+:'
        if (-not $isUri -and [System.IO.Path]::IsPathRooted($entry)) {
            throw "'$key' must be a URI or a path relative to the launcher folder, got '$entry'."
        }
    }
}
