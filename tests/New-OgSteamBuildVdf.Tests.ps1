# SPDX-License-Identifier: MPL-2.0
#Requires -Modules Pester

BeforeAll {
    $moduleRoot = Split-Path -Parent $PSScriptRoot
    Import-Module "$moduleRoot\og-framework.psd1" -Force

    function ConvertTo-Golden {
        param([Parameter(Mandatory)][string] $Text)
        ($Text -replace "`r`n", "`n").Replace('|', "`t").TrimEnd("`n") + "`n"
    }

    function ConvertTo-VdfLiteral {
        param([Parameter(Mandatory)][string] $Value)
        $Value.Replace('\', '\\').Replace('"', '\"')
    }

    function Get-FileText {
        param([Parameter(Mandatory)][string] $Path)
        [System.IO.File]::ReadAllText($Path, [System.Text.UTF8Encoding]::new($false))
    }

    function Invoke-Vdf {
        param([Parameter(Mandatory)][hashtable] $Splat)
        InModuleScope og-framework -Parameters @{ Splat = $Splat } {
            param($Splat)
            New-OgSteamBuildVdf @Splat
        }
    }

    $script:clientDepot = @{
        DepotId        = 1001
        ContentRoot    = 'C:\Build Root\client-win64\WindowsClient'
        FileExclusions = @('*.pdb', 'Manifest_*.txt')
    }
    $script:serverDepot = @{
        DepotId        = 1002
        ContentRoot    = 'C:\Build Root\server-win64\WindowsServer'
        FileExclusions = @()
    }
}

Describe 'New-OgSteamBuildVdf' {

    BeforeEach {
        $script:outDir = Join-Path $TestDrive ("steam out " + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $script:base = @{
            AppId           = 1000
            Description     = '20260926-120000-abc1234'
            BuildOutput     = 'C:\Build Root\_steam\output'
            OutputDirectory = $script:outDir
        }
    }

    Context 'Golden output' {

        It 'writes a single-depot app VDF and depot VDF (no SetLive, Preview off, paths with spaces)' {
            $splat = $script:base.Clone()
            $splat.Depots = @($script:clientDepot)

            $appPath = Invoke-Vdf $splat

            $depotPath = Join-Path $script:outDir 'depot_build_1001.vdf'
            $appPath | Should -Be (Join-Path $script:outDir 'app_build_1000.vdf')
            [System.IO.Path]::IsPathFullyQualified($appPath) | Should -BeTrue

            $expectedApp = ConvertTo-Golden @"
"AppBuild"
{
|"AppID"|"1000"
|"Desc"|"20260926-120000-abc1234"
|"BuildOutput"|"C:\\Build Root\\_steam\\output"
|"ContentRoot"|""
|"Preview"|"0"
|"Depots"
|{
||"1001"|"$(ConvertTo-VdfLiteral $depotPath)"
|}
}
"@
            $expectedDepot = ConvertTo-Golden @'
"DepotBuild"
{
|"DepotID"|"1001"
|"ContentRoot"|"C:\\Build Root\\client-win64\\WindowsClient"
|"FileMapping"
|{
||"LocalPath"|"*"
||"DepotPath"|"."
||"recursive"|"1"
|}
|"FileExclusion"|"*.pdb"
|"FileExclusion"|"Manifest_*.txt"
}
'@
            Get-FileText $appPath   | Should -BeExactly $expectedApp
            Get-FileText $depotPath | Should -BeExactly $expectedDepot
        }

        It 'writes two depots in input order, each with its own depot VDF' {
            $splat = $script:base.Clone()
            $splat.Depots = @($script:clientDepot, $script:serverDepot)

            $appPath = Invoke-Vdf $splat

            $clientPath = Join-Path $script:outDir 'depot_build_1001.vdf'
            $serverPath = Join-Path $script:outDir 'depot_build_1002.vdf'
            $expectedApp = ConvertTo-Golden @"
"AppBuild"
{
|"AppID"|"1000"
|"Desc"|"20260926-120000-abc1234"
|"BuildOutput"|"C:\\Build Root\\_steam\\output"
|"ContentRoot"|""
|"Preview"|"0"
|"Depots"
|{
||"1001"|"$(ConvertTo-VdfLiteral $clientPath)"
||"1002"|"$(ConvertTo-VdfLiteral $serverPath)"
|}
}
"@
            $expectedServer = ConvertTo-Golden @'
"DepotBuild"
{
|"DepotID"|"1002"
|"ContentRoot"|"C:\\Build Root\\server-win64\\WindowsServer"
|"FileMapping"
|{
||"LocalPath"|"*"
||"DepotPath"|"."
||"recursive"|"1"
|}
}
'@
            Get-FileText $appPath    | Should -BeExactly $expectedApp
            Get-FileText $serverPath | Should -BeExactly $expectedServer
            Test-Path -LiteralPath $clientPath | Should -BeTrue
            @(Get-ChildItem -LiteralPath $script:outDir -File).Count | Should -Be 3
        }

        It 'writes SetLive after ContentRoot when given, and Preview "1" with -Preview' {
            $splat = $script:base.Clone()
            $splat.Depots = @($script:clientDepot)
            $splat.SetLive = 'playtest'
            $splat.Preview = $true

            $appPath = Invoke-Vdf $splat

            $depotPath = Join-Path $script:outDir 'depot_build_1001.vdf'
            $expectedApp = ConvertTo-Golden @"
"AppBuild"
{
|"AppID"|"1000"
|"Desc"|"20260926-120000-abc1234"
|"BuildOutput"|"C:\\Build Root\\_steam\\output"
|"ContentRoot"|""
|"SetLive"|"playtest"
|"Preview"|"1"
|"Depots"
|{
||"1001"|"$(ConvertTo-VdfLiteral $depotPath)"
|}
}
"@
            Get-FileText $appPath | Should -BeExactly $expectedApp
        }

        It 'omits SetLive when it is empty' {
            $splat = $script:base.Clone()
            $splat.Depots = @($script:clientDepot)
            $splat.SetLive = ''

            $appPath = Invoke-Vdf $splat

            Get-FileText $appPath | Should -Not -Match 'SetLive'
        }

        It 'escapes double quotes and backslashes in Desc' {
            $splat = $script:base.Clone()
            $splat.Depots = @($script:clientDepot)
            $splat.Description = 'say "hi" from C:\x\'

            $appPath = Invoke-Vdf $splat

            $descLine = (Get-FileText $appPath) -split "`n" | Where-Object { $_ -like "`t`"Desc`"*" }
            $descLine | Should -BeExactly ("`t`"Desc`"`t" + '"say \"hi\" from C:\\x\\"')
        }

        It 'writes UTF-8 without BOM, LF line endings and tab indentation' {
            $splat = $script:base.Clone()
            $splat.Depots = @($script:clientDepot)
            $splat.Description = 'build é'

            $appPath = Invoke-Vdf $splat

            $bytes = [System.IO.File]::ReadAllBytes($appPath)
            ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should -BeFalse
            $bytes -contains [byte]13 | Should -BeFalse
            (Get-FileText $appPath) | Should -Match "`n`t`"Desc`"`t`"build é`"`n"
        }

        It 'accepts AppId and DepotId 0 (placeholders) and pscustomobject depots' {
            $splat = $script:base.Clone()
            $splat.AppId = 0
            $splat.Depots = @([pscustomobject]@{ DepotId = 0; ContentRoot = 'C:\c' })

            $appPath = Invoke-Vdf $splat

            $appPath | Should -Be (Join-Path $script:outDir 'app_build_0.vdf')
            Get-FileText (Join-Path $script:outDir 'depot_build_0.vdf') | Should -Match '"DepotID"\t"0"'
            Get-FileText (Join-Path $script:outDir 'depot_build_0.vdf') | Should -Not -Match 'FileExclusion'
        }

        It 'overwrites existing VDF files' {
            New-Item -ItemType Directory -Path $script:outDir | Out-Null
            Set-Content -LiteralPath (Join-Path $script:outDir 'app_build_1000.vdf') -Value 'stale'
            $splat = $script:base.Clone()
            $splat.Depots = @($script:clientDepot)

            $appPath = Invoke-Vdf $splat

            Get-FileText $appPath | Should -Not -Match 'stale'
        }
    }

    Context 'Rejections' {

        It 'S1: rejects SetLive "<Branch>" and writes nothing' -ForEach @(
            @{ Branch = 'default' }
            @{ Branch = 'Default' }
            @{ Branch = 'DEFAULT' }
        ) {
            $splat = $script:base.Clone()
            $splat.Depots = @($script:clientDepot)
            $splat.SetLive = $Branch

            { Invoke-Vdf $splat } | Should -Throw "*SetLive 'default' is not allowed*"
            Test-Path -LiteralPath $script:outDir | Should -BeFalse
        }

        It 'rejects an empty Depots array' {
            $splat = $script:base.Clone()
            $splat.Depots = @()

            { Invoke-Vdf $splat } | Should -Throw '*at least one depot*'
            Test-Path -LiteralPath $script:outDir | Should -BeFalse
        }

        It 'rejects duplicate DepotIds' {
            $splat = $script:base.Clone()
            $splat.Depots = @($script:clientDepot, @{ DepotId = 1001; ContentRoot = 'C:\other' })

            { Invoke-Vdf $splat } | Should -Throw '*Duplicate DepotId 1001*'
            Test-Path -LiteralPath $script:outDir | Should -BeFalse
        }

        It 'rejects an unknown depot key' {
            $splat = $script:base.Clone()
            $splat.Depots = @(@{ DepotId = 1001; ContentRoot = 'C:\c'; FileExclusion = @('*.pdb') })

            { Invoke-Vdf $splat } | Should -Throw "*unknown key 'FileExclusion'*"
        }

        It 'rejects a non-integer DepotId' {
            $splat = $script:base.Clone()
            $splat.Depots = @(@{ DepotId = '1001'; ContentRoot = 'C:\c' })

            { Invoke-Vdf $splat } | Should -Throw '*DepotId must be an integer*'
        }

        It 'rejects a negative DepotId' {
            $splat = $script:base.Clone()
            $splat.Depots = @(@{ DepotId = -1; ContentRoot = 'C:\c' })

            { Invoke-Vdf $splat } | Should -Throw '*DepotId is out of range*'
        }

        It 'rejects a missing or relative ContentRoot' {
            $splat = $script:base.Clone()
            $splat.Depots = @(@{ DepotId = 1001 })
            { Invoke-Vdf $splat } | Should -Throw "*missing required key 'ContentRoot'*"

            $splat.Depots = @(@{ DepotId = 1001; ContentRoot = 'relative\dir' })
            { Invoke-Vdf $splat } | Should -Throw '*ContentRoot must be an absolute path*'
        }

        It 'rejects a relative BuildOutput or OutputDirectory' {
            $splat = $script:base.Clone()
            $splat.Depots = @($script:clientDepot)
            $splat.BuildOutput = 'out'
            { Invoke-Vdf $splat } | Should -Throw '*BuildOutput must be an absolute path*'

            $splat = $script:base.Clone()
            $splat.Depots = @($script:clientDepot)
            $splat.OutputDirectory = 'steam'
            { Invoke-Vdf $splat } | Should -Throw '*OutputDirectory must be an absolute path*'
        }

        It 'rejects control characters in a value' {
            $splat = $script:base.Clone()
            $splat.Depots = @($script:clientDepot)
            $splat.Description = "line1`nline2"

            { Invoke-Vdf $splat } | Should -Throw '*Description contains a control character*'
            Test-Path -LiteralPath $script:outDir | Should -BeFalse
        }

        It 'rejects an empty FileExclusions pattern' {
            $splat = $script:base.Clone()
            $splat.Depots = @(@{ DepotId = 1001; ContentRoot = 'C:\c'; FileExclusions = @('*.pdb', '') })

            { Invoke-Vdf $splat } | Should -Throw '*FileExclusions*non-empty strings*'
        }
    }
}
