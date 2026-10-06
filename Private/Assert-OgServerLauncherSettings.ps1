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
          ClientLaunch     '', a URI such as steam://rungameid/<id>, or a path relative to the
                           launcher folder; {AppId:<app name>} tokens must name an app in AppNames
          ServerArguments, LocalHint  no line break

        Every message has the form '<Prefix><Key>' <problem>.

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
        [AllowEmptyString()] [string] $ClientLaunch = '',
        [AllowEmptyString()] [string] $LocalHint = '',
        [string[]] $AppNames = @(),
        [string] $Prefix = ''
    )

    $values = [ordered]@{
        Title            = $Title
        ServerArguments  = $ServerArguments
        JoinLinePattern  = $JoinLinePattern
        ReadyLinePattern = $ReadyLinePattern
        ClientLaunch     = $ClientLaunch
        LocalHint        = $LocalHint
    }
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

    if ($ClientLaunch -ne '') {
        foreach ($token in [regex]::Matches($ClientLaunch, '\{AppId:(?<name>[^}]*)\}')) {
            $name = $token.Groups['name'].Value
            if ($AppNames -notcontains $name) {
                throw "'${Prefix}ClientLaunch' references unknown app '$name' in '$($token.Value)'. Known apps: $($AppNames -join ', ')."
            }
        }
        $isUri = $ClientLaunch -match '^[A-Za-z][A-Za-z0-9+.-]+:'
        if (-not $isUri -and [System.IO.Path]::IsPathRooted($ClientLaunch)) {
            throw "'${Prefix}ClientLaunch' must be a URI or a path relative to the launcher folder, got '$ClientLaunch'."
        }
    }
}
