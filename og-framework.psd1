# SPDX-License-Identifier: MPL-2.0
@{
    RootModule        = 'og-framework.psm1'
    ModuleVersion     = '1.1.1'
    GUID              = '70abd67b-8e61-465d-a290-641a2265916e'
    Author            = 'Grahnen92'
    Description       = 'Cross-repo PowerShell toolkit for the og-framework submodule workflow'
    PowerShellVersion = '7.4'

    FunctionsToExport = @(
        'Add-OgChange'
        'Get-OgRepoStatus'
        'Invoke-OgLowLevelTest'
        'Merge-OgToMain'
        'New-OgCloneScenario'
        'New-OgCommit'
        'New-OgFeatureBranch'
        'Push-OgFramework'
        'Show-OgDiff'
        'Sync-OgFramework'
        'Test-OgPinConsistency'
        'Update-LicenseChangeDate'
        'Update-OgLibPin'
    )

    AliasesToExport   = @(
        'oggitstatus'
        'oggitsync'
        'oggitadd'
        'oggitcommit'
        'oggitpush'
        'oggitmerge'
        'oggitdiff'
        'oglltest'
        'oglicstamp'
    )

    CmdletsToExport   = @()
    VariablesToExport = @()

    FormatsToProcess  = @('og-framework.format.ps1xml')
}
