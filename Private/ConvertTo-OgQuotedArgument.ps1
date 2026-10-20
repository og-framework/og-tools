# SPDX-License-Identifier: MPL-2.0
function ConvertTo-OgQuotedArgument {
    <#
    .SYNOPSIS
        Wraps a value in double quotes when it contains a space, for Start-Process -ArgumentList.

    .DESCRIPTION
        Start-Process joins its argument list with spaces and does not quote the elements, so a path with a space would split into
        two arguments. Values that are already quoted, or that hold no space, are returned unchanged.

    .PARAMETER Value
        The argument value.

    .OUTPUTS
        [string]
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [AllowEmptyString()]
        [string] $Value
    )

    if ($Value -notmatch '\s' -or ($Value.StartsWith('"') -and $Value.EndsWith('"'))) { return $Value }
    '"' + $Value + '"'
}
