# SPDX-License-Identifier: MPL-2.0
$private = Get-ChildItem -Path "$PSScriptRoot\Private\*.ps1" -ErrorAction SilentlyContinue
$public  = Get-ChildItem -Path "$PSScriptRoot\Public\*.ps1"  -ErrorAction SilentlyContinue

foreach ($file in @($private) + @($public)) {
    . $file.FullName
}

Export-ModuleMember -Function ($public | ForEach-Object { $_.BaseName })

Set-Alias -Name oggitstatus   -Value Get-OgRepoStatus
Set-Alias -Name oggitsync     -Value Sync-OgFramework
Set-Alias -Name oggitadd      -Value Add-OgChange
Set-Alias -Name oggitcommit   -Value New-OgCommit
Set-Alias -Name oggitpush     -Value Push-OgFramework
Set-Alias -Name oggitdiff     -Value Show-OgDiff
Set-Alias -Name oglltest      -Value Invoke-OgLowLevelTest
Set-Alias -Name oglicstamp    -Value Update-LicenseChangeDate

Export-ModuleMember -Alias oggitstatus, oggitsync, oggitadd, oggitcommit, oggitpush, oggitdiff, oglltest, oglicstamp
