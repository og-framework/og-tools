# SPDX-License-Identifier: MPL-2.0
function Test-OgSteamFileExcluded {
    <#
    .SYNOPSIS
        Tells whether a depot file matches any SteamPipe FileExclusion pattern.

    .DESCRIPTION
        Matches the way the depot VDF's FileExclusion lines are read: each pattern is a path relative
        to the depot ContentRoot, compared case-insensitively with the file's path relative to that
        ContentRoot (backslash-separated). Only '*' and '?' are wildcards, and '*' also spans folder
        separators, so '*.pdb' matches a .pdb in any folder and 'HostLogs\*' matches every file below
        HostLogs. '[' , ']' and '`' are literal characters.

    .PARAMETER RelativePath
        The file's path relative to the ContentRoot, e.g. 'OGBrawlerUnreal\Saved\Logs\Game.log' or 'build_info.txt'.

    .PARAMETER Pattern
        The depot's FileExclusions patterns.

    .OUTPUTS
        [bool]

    .EXAMPLE
        Test-OgSteamFileExcluded -RelativePath 'HostLogs\server-1.log' -Pattern @('*.pdb', 'HostLogs\*')

        Returns $true.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $RelativePath,

        [AllowEmptyCollection()]
        [string[]] $Pattern
    )

    foreach ($candidate in @($Pattern)) {
        if ([string]::IsNullOrEmpty($candidate)) { continue }
        $wildcard = $candidate.Replace('`', '``').Replace('[', '`[').Replace(']', '`]')
        if ($RelativePath -like $wildcard) { return $true }
    }
    $false
}
