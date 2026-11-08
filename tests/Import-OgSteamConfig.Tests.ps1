# SPDX-License-Identifier: MPL-2.0
#Requires -Modules Pester

BeforeAll {
    $moduleRoot = Split-Path -Parent $PSScriptRoot
    Import-Module "$moduleRoot\og-framework.psd1" -Force

    function ConvertTo-TestPsd1Text {
        param($Value, [int] $Depth = 0)
        $pad = '    ' * ($Depth + 1)
        $end = '    ' * $Depth
        if ($null -eq $Value) { return '$null' }
        if ($Value -is [System.Collections.IDictionary]) {
            $lines = foreach ($key in $Value.Keys) {
                $name = if ($key -match '^[A-Za-z_][A-Za-z0-9_]*$') { $key } else { "'$key'" }
                "$pad$name = $(ConvertTo-TestPsd1Text $Value[$key] ($Depth + 1))"
            }
            return "@{`n$($lines -join "`n")`n$end}"
        }
        if ($Value -is [array]) {
            $items = foreach ($item in $Value) { "$pad$(ConvertTo-TestPsd1Text $item ($Depth + 1))" }
            return "@(`n$($items -join "`n")`n$end)"
        }
        if ($Value -is [string]) { return "'$($Value.Replace("'", "''"))'" }
        if ($Value -is [bool]) { return "`$$($Value.ToString().ToLower())" }
        if ($Value -is [double]) { return $Value.ToString([cultureinfo]::InvariantCulture) }
        return "$Value"
    }

    function New-TestSteamConfigTable {
        [ordered]@{
            SchemaVersion  = 1
            ProjectFile    = '..\Game\Game.uproject'
            EngineRoot     = ''
            Platform       = 'Win64'
            BuilderAccount = ''
            Branch         = 'playtest'
            OutputRoot     = '..\Game\Saved\Steam\Builds'
            KeepLast       = 3
            Apps           = @(
                [ordered]@{
                    Name   = 'client'
                    AppId  = 0
                    Depots = @(
                        [ordered]@{
                            Name               = 'client-win64'
                            DepotId            = 0
                            TargetType         = 'Client'
                            Configuration      = 'Shipping'
                            ExpectedExecutable = 'GameClient.exe'
                            FileExclusions     = @('*.pdb', 'Manifest_*.txt')
                            ExtraFiles         = @()
                        }
                    )
                }
                [ordered]@{
                    Name   = 'server'
                    AppId  = 0
                    Depots = @(
                        [ordered]@{
                            Name               = 'server-win64'
                            DepotId            = 0
                            TargetType         = 'Server'
                            Configuration      = 'Development'
                            ExpectedExecutable = 'GameServer.exe'
                            FileExclusions     = @('*.pdb')
                            ExtraFiles         = @(
                                [ordered]@{ Source = '..\Game\run_server_template.bat'; Destination = 'run_server.bat' }
                            )
                        }
                    )
                }
            )
        }
    }

    function Write-TestSteamConfig {
        param([scriptblock] $Mutate)
        $table = New-TestSteamConfigTable
        if ($Mutate) { & $Mutate $table }
        $path = Join-Path $TestDrive 'config\steam-publish.psd1'
        Set-Content -LiteralPath $path -Value (ConvertTo-TestPsd1Text $table) -Encoding utf8
        $path
    }

    function Import-TestSteamConfig {
        param([string] $Path)
        InModuleScope og-framework -Parameters @{ Path = $Path } {
            param($Path)
            Import-OgSteamConfig -Path $Path
        }
    }

    function Assert-TestUploadReady {
        param($Config, [hashtable] $Extra = @{})
        InModuleScope og-framework -Parameters @{ Config = $Config; Extra = $Extra } {
            param($Config, $Extra)
            Assert-OgSteamUploadReady -Config $Config @Extra
        }
    }

    function New-TestReadyConfig {
        $config = Import-TestSteamConfig (Write-TestSteamConfig {
                param($t)
                $t.BuilderAccount = 'builder'
                $t.Apps[0].AppId = 1000
                $t.Apps[0].Depots[0].DepotId = 1001
                $t.Apps[1].AppId = 2000
                $t.Apps[1].Depots[0].DepotId = 2001
            })
        $config
    }

    New-Item -ItemType Directory -Path (Join-Path $TestDrive 'config') | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $TestDrive 'Game') | Out-Null
    Set-Content -LiteralPath (Join-Path $TestDrive 'Game\Game.uproject') -Value '{}'
    Set-Content -LiteralPath (Join-Path $TestDrive 'Game\run_server_template.bat') -Value '@echo off'
}

Describe 'Import-OgSteamConfig' {

    Context 'A fully valid config' {

        BeforeAll {
            $path = Write-TestSteamConfig
            $config = Import-TestSteamConfig $path
        }

        It 'returns the config path and absolute, resolved paths' {
            $config.ConfigPath | Should -Be (Join-Path $TestDrive 'config\steam-publish.psd1')
            $config.ProjectFile | Should -Be (Join-Path $TestDrive 'Game\Game.uproject')
            $config.OutputRoot | Should -Be (Join-Path $TestDrive 'Game\Saved\Steam\Builds')
            [System.IO.Path]::IsPathRooted($config.ProjectFile) | Should -BeTrue
            $config.ProjectFile | Should -Not -Match '\\\.\.\\'
            $config.Apps[1].Depots[0].ExtraFiles[0].Source | Should -Be (Join-Path $TestDrive 'Game\run_server_template.bat')
            $config.Apps[1].Depots[0].ExtraFiles[0].Destination | Should -Be 'run_server.bat'
        }

        It 'keeps every top-level value with the right type' {
            $config.SchemaVersion | Should -Be 1
            $config.EngineRoot | Should -Be ''
            $config.Platform | Should -Be 'Win64'
            $config.BuilderAccount | Should -Be ''
            $config.Branch | Should -Be 'playtest'
            $config.KeepLast | Should -BeOfType [int]
            $config.KeepLast | Should -Be 3
        }

        It 'returns apps and depots as arrays of pscustomobjects with back-references' {
            $config.Apps.Count | Should -Be 2
            $config.Apps[0] | Should -BeOfType [pscustomobject]
            $config.Apps[0].Name | Should -Be 'client'
            $config.Apps[0].AppId | Should -BeOfType [uint32]
            $config.Apps[0].AppId | Should -Be 0

            $depot = $config.Apps[0].Depots[0]
            $depot | Should -BeOfType [pscustomobject]
            $depot.Name | Should -Be 'client-win64'
            $depot.DepotId | Should -BeOfType [uint32]
            $depot.TargetType | Should -Be 'Client'
            $depot.Configuration | Should -Be 'Shipping'
            $depot.ExpectedExecutable | Should -Be 'GameClient.exe'
            ,$depot.FileExclusions | Should -BeOfType [string[]]
            $depot.FileExclusions | Should -Be @('*.pdb', 'Manifest_*.txt')
            @($depot.ExtraFiles).Count | Should -Be 0
            $depot.AppName | Should -Be 'client'
            $depot.AppId | Should -Be 0

            $config.Apps[1].Depots[0].AppName | Should -Be 'server'
        }

        It 'accepts AppId and DepotId 0 as placeholders at load time' {
            @($config.Apps | Where-Object AppId -eq 0).Count | Should -Be 2
        }

        It 'resolves a relative config path against the current location' {
            Push-Location $TestDrive
            try {
                (Import-TestSteamConfig 'config\steam-publish.psd1').ConfigPath |
                    Should -Be (Join-Path $TestDrive 'config\steam-publish.psd1')
            }
            finally { Pop-Location }
        }

        It 'resolves a non-empty EngineRoot against the config folder' {
            $c = Import-TestSteamConfig (Write-TestSteamConfig { param($t) $t.EngineRoot = '..\Engine' })
            $c.EngineRoot | Should -Be (Join-Path $TestDrive 'Engine')
        }

        It 'treats omitted optional keys as empty' {
            $c = Import-TestSteamConfig (Write-TestSteamConfig {
                    param($t)
                    $t.Remove('EngineRoot'); $t.Remove('BuilderAccount'); $t.Remove('Branch')
                    $t.Apps[0].Depots[0].Remove('ExpectedExecutable')
                    $t.Apps[0].Depots[0].Remove('FileExclusions')
                    $t.Apps[0].Depots[0].Remove('ExtraFiles')
                })
            $c.EngineRoot | Should -Be ''
            $c.BuilderAccount | Should -Be ''
            $c.Branch | Should -Be ''
            $c.Apps[0].Depots[0].ExpectedExecutable | Should -Be ''
            @($c.Apps[0].Depots[0].FileExclusions).Count | Should -Be 0
            @($c.Apps[0].Depots[0].ExtraFiles).Count | Should -Be 0
        }
    }

    Context 'Rejections, each naming the offending key' {

        It 'rejects a missing required key: <Key>' -TestCases @(
            @{ Key = 'SchemaVersion'; Mutate = { param($t) $t.Remove('SchemaVersion') } }
            @{ Key = 'ProjectFile'; Mutate = { param($t) $t.Remove('ProjectFile') } }
            @{ Key = 'Platform'; Mutate = { param($t) $t.Remove('Platform') } }
            @{ Key = 'OutputRoot'; Mutate = { param($t) $t.Remove('OutputRoot') } }
            @{ Key = 'KeepLast'; Mutate = { param($t) $t.Remove('KeepLast') } }
            @{ Key = 'Apps'; Mutate = { param($t) $t.Remove('Apps') } }
            @{ Key = 'Apps[0].Name'; Mutate = { param($t) $t.Apps[0].Remove('Name') } }
            @{ Key = 'Apps[0].AppId'; Mutate = { param($t) $t.Apps[0].Remove('AppId') } }
            @{ Key = 'Apps[0].Depots'; Mutate = { param($t) $t.Apps[0].Remove('Depots') } }
            @{ Key = 'Apps[0].Depots[0].Name'; Mutate = { param($t) $t.Apps[0].Depots[0].Remove('Name') } }
            @{ Key = 'Apps[0].Depots[0].DepotId'; Mutate = { param($t) $t.Apps[0].Depots[0].Remove('DepotId') } }
            @{ Key = 'Apps[0].Depots[0].TargetType'; Mutate = { param($t) $t.Apps[0].Depots[0].Remove('TargetType') } }
            @{ Key = 'Apps[0].Depots[0].Configuration'; Mutate = { param($t) $t.Apps[0].Depots[0].Remove('Configuration') } }
            @{ Key = 'Apps[1].Depots[0].ExtraFiles[0].Destination'; Mutate = { param($t) $t.Apps[1].Depots[0].ExtraFiles[0].Remove('Destination') } }
        ) {
            $path = Write-TestSteamConfig $Mutate
            { Import-TestSteamConfig $path } | Should -Throw "*missing required key '$([WildcardPattern]::Escape($Key))'*"
        }

        It 'rejects an unknown key: <Key>' -TestCases @(
            @{ Key = 'Brnach'; Mutate = { param($t) $t.Brnach = 'x' } }
            @{ Key = 'Apps[0].AppID2'; Mutate = { param($t) $t.Apps[0].AppID2 = 1 } }
            @{ Key = 'Apps[0].Depots[0].FileExclusion'; Mutate = { param($t) $t.Apps[0].Depots[0].FileExclusion = @('*.pdb') } }
            @{ Key = 'Apps[1].Depots[0].ExtraFiles[0].Dest'; Mutate = { param($t) $t.Apps[1].Depots[0].ExtraFiles[0].Dest = 'x' } }
        ) {
            $path = Write-TestSteamConfig $Mutate
            { Import-TestSteamConfig $path } | Should -Throw "*unknown key '$([WildcardPattern]::Escape($Key))'*"
        }

        It 'rejects SchemaVersion <Value>' -TestCases @(
            @{ Value = 3; Mutate = { param($t) $t.SchemaVersion = 3 } }
            @{ Value = 0; Mutate = { param($t) $t.SchemaVersion = 0 } }
            @{ Value = "'1'"; Mutate = { param($t) $t.SchemaVersion = '1' } }
        ) {
            $path = Write-TestSteamConfig $Mutate
            { Import-TestSteamConfig $path } | Should -Throw "*'SchemaVersion'*"
        }

        It 'rejects Platform other than Win64' {
            $path = Write-TestSteamConfig { param($t) $t.Platform = 'Linux' }
            { Import-TestSteamConfig $path } | Should -Throw "*'Platform' must be one of Win64*"
        }

        It 'rejects TargetType outside Client, Server, Game' {
            $path = Write-TestSteamConfig { param($t) $t.Apps[0].Depots[0].TargetType = 'Editor' }
            { Import-TestSteamConfig $path } | Should -Throw "*'Apps[[]0].Depots[[]0].TargetType' must be one of*"
        }

        It 'rejects Configuration outside Development, Shipping' {
            $path = Write-TestSteamConfig { param($t) $t.Apps[0].Depots[0].Configuration = 'Debug' }
            { Import-TestSteamConfig $path } | Should -Throw "*'Apps[[]0].Depots[[]0].Configuration' must be one of*"
        }

        It 'rejects a duplicate depot Name across apps' {
            $path = Write-TestSteamConfig { param($t) $t.Apps[1].Depots[0].Name = 'client-win64' }
            { Import-TestSteamConfig $path } | Should -Throw "*duplicate depot name 'client-win64' at 'Apps[[]1].Depots[[]0].Name'*"
        }

        It 'rejects depot Name <Name> that does not match ^[a-z0-9-]+$' -TestCases @(
            @{ Name = 'Client-Win64' }
            @{ Name = 'client_win64' }
            @{ Name = 'client win64' }
        ) {
            $bad = $Name
            $path = Write-TestSteamConfig { param($t) $t.Apps[0].Depots[0].Name = $bad }.GetNewClosure()
            { Import-TestSteamConfig $path } | Should -Throw "*'Apps[[]0].Depots[[]0].Name' must match*"
        }

        It 'rejects KeepLast <Value>' -TestCases @(
            @{ Value = 0 }
            @{ Value = -1 }
        ) {
            $v = $Value
            $path = Write-TestSteamConfig { param($t) $t.KeepLast = $v }.GetNewClosure()
            { Import-TestSteamConfig $path } | Should -Throw "*'KeepLast' must be between 1 and*"
        }

        It 'rejects <Key> = <Shown>' -TestCases @(
            @{ Key = 'Apps[0].AppId'; Shown = '-1'; Mutate = { param($t) $t.Apps[0].AppId = -1 } }
            @{ Key = 'Apps[0].AppId'; Shown = "'480'"; Mutate = { param($t) $t.Apps[0].AppId = '480' } }
            @{ Key = 'Apps[0].AppId'; Shown = '1.5'; Mutate = { param($t) $t.Apps[0].AppId = 1.5 } }
            @{ Key = 'Apps[0].AppId'; Shown = '4294967296'; Mutate = { param($t) $t.Apps[0].AppId = 4294967296 } }
            @{ Key = 'Apps[0].Depots[0].DepotId'; Shown = '-5'; Mutate = { param($t) $t.Apps[0].Depots[0].DepotId = -5 } }
            @{ Key = 'Apps[0].Depots[0].DepotId'; Shown = "'abc'"; Mutate = { param($t) $t.Apps[0].Depots[0].DepotId = 'abc' } }
            @{ Key = 'Apps[0].Depots[0].DepotId'; Shown = '$true'; Mutate = { param($t) $t.Apps[0].Depots[0].DepotId = $true } }
        ) {
            $path = Write-TestSteamConfig $Mutate
            $escaped = $Key.Replace('[', '[[]')
            { Import-TestSteamConfig $path } | Should -Throw "*'$escaped' must be*"
        }

        It 'rejects a ProjectFile that does not exist' {
            $path = Write-TestSteamConfig { param($t) $t.ProjectFile = '..\Game\Missing.uproject' }
            { Import-TestSteamConfig $path } | Should -Throw "*'ProjectFile'*Missing.uproject' does not exist*"
        }

        It 'rejects a ProjectFile that is not a .uproject' {
            $path = Write-TestSteamConfig { param($t) $t.ProjectFile = '..\Game\run_server_template.bat' }
            { Import-TestSteamConfig $path } | Should -Throw "*'ProjectFile' must point to a .uproject file*"
        }

        It 'rejects an ExtraFiles.Source that does not exist' {
            $path = Write-TestSteamConfig { param($t) $t.Apps[1].Depots[0].ExtraFiles[0].Source = '..\Game\nope.bat' }
            { Import-TestSteamConfig $path } | Should -Throw "*'Apps[[]1].Depots[[]0].ExtraFiles[[]0].Source'*nope.bat' does not exist*"
        }

        It 'rejects an ExtraFiles.Destination that leaves the content root: <Destination>' -TestCases @(
            @{ Destination = '..\run_server.bat' }
            @{ Destination = 'C:\run_server.bat' }
        ) {
            $dest = $Destination
            $path = Write-TestSteamConfig { param($t) $t.Apps[1].Depots[0].ExtraFiles[0].Destination = $dest }.GetNewClosure()
            { Import-TestSteamConfig $path } | Should -Throw "*'Apps[[]1].Depots[[]0].ExtraFiles[[]0].Destination' must be a path inside*"
        }

        It 'rejects an app with no depots' {
            $path = Write-TestSteamConfig { param($t) $t.Apps[0].Depots = @() }
            { Import-TestSteamConfig $path } | Should -Throw "*'Apps[[]0].Depots' must contain at least one depot*"
        }

        It 'rejects a config file that does not exist' {
            { Import-TestSteamConfig (Join-Path $TestDrive 'nope.psd1') } | Should -Throw '*does not exist*'
        }

        It 'S1: rejects Branch <Value> at config load' -TestCases @(
            @{ Value = 'default' }
            @{ Value = 'DEFAULT' }
            @{ Value = ' Default ' }
        ) {
            $v = $Value
            $path = Write-TestSteamConfig { param($t) $t.Branch = $v }.GetNewClosure()
            { Import-TestSteamConfig $path } | Should -Throw "*'Branch' must not be 'default'*"
        }
    }
}

Describe 'Assert-OgSteamUploadReady' {

    It 'passes a config with real IDs, a builder account and a non-default branch' {
        $config = New-TestReadyConfig
        { Assert-TestUploadReady $config } | Should -Not -Throw
        { Assert-TestUploadReady $config @{ Branch = 'beta' } } | Should -Not -Throw
        { Assert-TestUploadReady $config @{ Branch = '' } } | Should -Not -Throw
    }

    It 'S2: rejects placeholder AppId and DepotId 0, naming every one' {
        $config = Import-TestSteamConfig (Write-TestSteamConfig { param($t) $t.BuilderAccount = 'builder' })
        $err = { Assert-TestUploadReady $config } | Should -Throw -PassThru
        $err.Exception.Message | Should -BeLike "*App 'client': AppId is the placeholder 0*"
        $err.Exception.Message | Should -BeLike "*App 'server': AppId is the placeholder 0*"
        $err.Exception.Message | Should -BeLike "*Depot 'client-win64': DepotId is the placeholder 0*"
        $err.Exception.Message | Should -BeLike "*Depot 'server-win64': DepotId is the placeholder 0*"
    }

    It 'S2: with -DepotNames, an unselected app may keep placeholder IDs' {
        $config = New-TestReadyConfig
        $config.Apps[1].AppId = [uint32]0
        $config.Apps[1].Depots[0].DepotId = [uint32]0
        { Assert-TestUploadReady $config @{ DepotNames = @('CLIENT-WIN64') } } | Should -Not -Throw
        { Assert-TestUploadReady $config } | Should -Throw "*App 'server': AppId is the placeholder 0*"
    }

    It 'S2: with -DepotNames, a selected placeholder DepotId and its app are still rejected' {
        $config = New-TestReadyConfig
        $config.Apps[1].AppId = [uint32]0
        $config.Apps[1].Depots[0].DepotId = [uint32]0
        $err = { Assert-TestUploadReady $config @{ DepotNames = @('server-win64') } } | Should -Throw -PassThru
        $err.Exception.Message | Should -BeLike "*App 'server': AppId is the placeholder 0*"
        $err.Exception.Message | Should -BeLike "*Depot 'server-win64': DepotId is the placeholder 0*"
        $err.Exception.Message | Should -Not -BeLike "*client*"
    }

    It 'S2: with -DepotNames, a duplicate real ID in an unselected app is still rejected' {
        $config = New-TestReadyConfig
        $config.Apps[1].Depots[0].DepotId = [uint32]1001
        { Assert-TestUploadReady $config @{ DepotNames = @('client-win64') } } | Should -Throw "*DepotId 1001 is also used by depot 'client-win64'*"
    }

    It 'S2: rejects a single remaining placeholder DepotId' {
        $config = New-TestReadyConfig
        $config.Apps[1].Depots[0].DepotId = [uint32]0
        { Assert-TestUploadReady $config } | Should -Throw "*Depot 'server-win64': DepotId is the placeholder 0*"
    }

    It 'rejects an empty BuilderAccount' {
        $config = New-TestReadyConfig
        $config.BuilderAccount = ''
        { Assert-TestUploadReady $config } | Should -Throw '*BuilderAccount is empty*'
    }

    It 'rejects duplicate AppId and DepotId values' {
        $config = New-TestReadyConfig
        $config.Apps[1].AppId = [uint32]1000
        $config.Apps[1].Depots[0].DepotId = [uint32]1001
        $err = { Assert-TestUploadReady $config } | Should -Throw -PassThru
        $err.Exception.Message | Should -BeLike "*AppId 1000 is also used by app 'client'*"
        $err.Exception.Message | Should -BeLike "*DepotId 1001 is also used by depot 'client-win64'*"
    }

    It 'S1: rejects a -Branch override of <Value>' -TestCases @(
        @{ Value = 'default' }
        @{ Value = 'Default' }
        @{ Value = 'DEFAULT ' }
    ) {
        $config = New-TestReadyConfig
        { Assert-TestUploadReady $config @{ Branch = $Value } } | Should -Throw "*Branch '$Value' is rejected*"
    }

    It 'S1: rejects a config object whose own Branch is default when no override is given' {
        $config = New-TestReadyConfig
        $config.Branch = 'default'
        { Assert-TestUploadReady $config } | Should -Throw "*Branch 'default' is rejected*"
    }
}

Describe 'Import-OgSteamConfig ServerLauncher' {

    BeforeAll {
        function New-TestLauncherTable {
            [ordered]@{
                Title           = 'Game server'
                Port            = 7777
                JoinLinePattern = 'S: (?:(?<joined>joined)|(?<left>left)) players=(?<players>\d+) tested=(?<tested>\d+)'
            }
        }

        function Write-TestLauncherConfig {
            param([scriptblock] $Change)
            $table = New-TestLauncherTable
            $apply = {
                param($t)
                $t.Apps[1].Depots[0].ServerLauncher = $table
                if ($Change) { & $Change $t $t.Apps[1].Depots[0].ServerLauncher }
            }.GetNewClosure()
            Write-TestSteamConfig $apply
        }
    }

    It 'is $null on a depot without the key' {
        $config = Import-TestSteamConfig (Write-TestSteamConfig)
        $config.Apps[1].Depots[0].PSObject.Properties.Name | Should -Contain 'ServerLauncher'
        $config.Apps[1].Depots[0].ServerLauncher | Should -BeNullOrEmpty
    }

    It 'returns all seven keys, the optional ones defaulting to empty' {
        $launcher = (Import-TestSteamConfig (Write-TestLauncherConfig)).Apps[1].Depots[0].ServerLauncher
        $launcher.Title | Should -BeExactly 'Game server'
        $launcher.Port | Should -Be 7777
        $launcher.Port | Should -BeOfType [int]
        $launcher.JoinLinePattern | Should -Match '\(\?<joined>'
        foreach ($key in 'ServerArguments', 'ReadyLinePattern', 'LocalHint') {
            $launcher.$key | Should -BeExactly '' -Because "$key is optional"
        }
        , $launcher.ClientLaunch | Should -BeOfType [string[]]
        $launcher.ClientLaunch.Count | Should -Be 0 -Because 'ClientLaunch is optional'
    }

    It 'reads ClientLaunch <Case> as a list of <Count>' -TestCases @(
        @{ Case = "''"; Value = ''; Count = 0 }
        @{ Case = 'an empty list'; Value = @(); Count = 0 }
        @{ Case = 'one string'; Value = '..\GameClient.exe'; Count = 1 }
        @{ Case = 'a list'; Value = @('..\GameClient.exe', 'steam://rungameid/{AppId:client}'); Count = 2 }
    ) {
        $v = $Value
        $launcher = (Import-TestSteamConfig (Write-TestLauncherConfig { param($t, $l) $l.ClientLaunch = $v }.GetNewClosure())).Apps[1].Depots[0].ServerLauncher
        , $launcher.ClientLaunch | Should -BeOfType [string[]]
        $launcher.ClientLaunch.Count | Should -Be $Count
        if ($Count -gt 0) { $launcher.ClientLaunch | Should -Be @($Value) }
    }

    It 'keeps every optional value, including an {AppId:<name>} token of an app in the file' {
        $launcher = (Import-TestSteamConfig (Write-TestLauncherConfig {
                    param($t, $l)
                    $l.ServerArguments = '/Game/Maps/Arena'
                    $l.ReadyLinePattern = 'listening on port \d+'
                    $l.ClientLaunch = 'steam://rungameid/{AppId:client}'
                    $l.LocalHint = 'Press Tab to add a local player.'
                })).Apps[1].Depots[0].ServerLauncher
        $launcher.ServerArguments | Should -BeExactly '/Game/Maps/Arena'
        $launcher.ReadyLinePattern | Should -BeExactly 'listening on port \d+'
        $launcher.ClientLaunch | Should -BeExactly 'steam://rungameid/{AppId:client}'
        $launcher.LocalHint | Should -BeExactly 'Press Tab to add a local player.'
    }

    It 'rejects <Case>' -TestCases @(
        @{ Case = 'an unknown key'; Mutate = { param($t, $l) $l.Colour = 'red' }; Message = "*unknown key 'Apps[1].Depots[0].ServerLauncher.Colour'*" }
        @{ Case = 'a missing Title'; Mutate = { param($t, $l) $l.Remove('Title') }; Message = "*missing required key 'Apps[1].Depots[0].ServerLauncher.Title'*" }
        @{ Case = 'a missing Port'; Mutate = { param($t, $l) $l.Remove('Port') }; Message = "*missing required key 'Apps[1].Depots[0].ServerLauncher.Port'*" }
        @{ Case = 'a missing JoinLinePattern'; Mutate = { param($t, $l) $l.Remove('JoinLinePattern') }; Message = "*missing required key 'Apps[1].Depots[0].ServerLauncher.JoinLinePattern'*" }
        @{ Case = 'Port 0'; Mutate = { param($t, $l) $l.Port = 0 }; Message = "*'Apps[1].Depots[0].ServerLauncher.Port' must be between 1 and 65535*" }
        @{ Case = 'Port 65536'; Mutate = { param($t, $l) $l.Port = 65536 }; Message = "*'Apps[1].Depots[0].ServerLauncher.Port' must be between 1 and 65535*" }
        @{ Case = 'a string Port'; Mutate = { param($t, $l) $l.Port = '7777' }; Message = "*'Apps[1].Depots[0].ServerLauncher.Port' must be an integer*" }
        @{ Case = 'an invalid JoinLinePattern'; Mutate = { param($t, $l) $l.JoinLinePattern = '(?<joined>' }; Message = "*'Apps[1].Depots[0].ServerLauncher.JoinLinePattern' is not a valid regular expression*" }
        @{ Case = 'a JoinLinePattern without players'; Mutate = { param($t, $l) $l.JoinLinePattern = '(?<joined>j)|(?<left>l)' }; Message = "*'Apps[1].Depots[0].ServerLauncher.JoinLinePattern' must define the named groups*missing: players*" }
        @{ Case = 'an invalid ReadyLinePattern'; Mutate = { param($t, $l) $l.ReadyLinePattern = '[' }; Message = "*'Apps[1].Depots[0].ServerLauncher.ReadyLinePattern' is not a valid regular expression*" }
        @{ Case = 'a token naming an unknown app'; Mutate = { param($t, $l) $l.ClientLaunch = 'steam://rungameid/{AppId:game}' }; Message = "*'Apps[1].Depots[0].ServerLauncher.ClientLaunch' references unknown app 'game'*Known apps: client, server*" }
        @{ Case = 'an absolute ClientLaunch path'; Mutate = { param($t, $l) $l.ClientLaunch = 'C:\Games\GameClient.exe' }; Message = "*'Apps[1].Depots[0].ServerLauncher.ClientLaunch' must be a URI or a path relative*" }
        @{ Case = 'a ClientLaunch list entry naming an unknown app'; Mutate = { param($t, $l) $l.ClientLaunch = @('..\GameClient.exe', 'steam://rungameid/{AppId:game}') }; Message = "*'Apps[1].Depots[0].ServerLauncher.ClientLaunch[1]' references unknown app 'game'*" }
        @{ Case = 'an absolute ClientLaunch list entry'; Mutate = { param($t, $l) $l.ClientLaunch = @('C:\Games\GameClient.exe', 'steam://rungameid/{AppId:client}') }; Message = "*'Apps[1].Depots[0].ServerLauncher.ClientLaunch[0]' must be a URI or a path relative*" }
        @{ Case = 'an empty ClientLaunch list entry'; Mutate = { param($t, $l) $l.ClientLaunch = @('..\GameClient.exe', '') }; Message = "*'Apps[1].Depots[0].ServerLauncher.ClientLaunch[1]' must not be empty*" }
        @{ Case = 'a ClientLaunch list entry that is not a string'; Mutate = { param($t, $l) $l.ClientLaunch = @('..\GameClient.exe', 5) }; Message = "*'Apps[1].Depots[0].ServerLauncher.ClientLaunch[1]' must be a string*" }
        @{ Case = 'a Title with a double quote'; Mutate = { param($t, $l) $l.Title = 'A "B"' }; Message = "*'Apps[1].Depots[0].ServerLauncher.Title' must not contain a double quote*" }
        @{ Case = 'a ServerLauncher on a Client depot'; Mutate = { param($t, $l) $t.Apps[1].Depots[0].TargetType = 'Client' }; Message = "*'Apps[1].Depots[0].ServerLauncher' needs TargetType Server or Game, got 'Client'*" }
        @{ Case = 'a ServerLauncher without ExpectedExecutable'; Mutate = { param($t, $l) $t.Apps[1].Depots[0].Remove('ExpectedExecutable') }; Message = "*'Apps[1].Depots[0].ServerLauncher' needs 'Apps[1].Depots[0].ExpectedExecutable'*" }
        @{ Case = 'a ServerLauncher that is not a hashtable'; Mutate = { param($t, $l) $t.Apps[1].Depots[0].ServerLauncher = 'yes' }; Message = "*'Apps[1].Depots[0].ServerLauncher' must be a hashtable*" }
    ) {
        $path = Write-TestLauncherConfig $Mutate
        { Import-TestSteamConfig $path } | Should -Throw ($Message.Replace('[', '`[').Replace(']', '`]'))
    }

    It 'accepts a ServerLauncher on a Game depot' {
        $launcher = (Import-TestSteamConfig (Write-TestLauncherConfig { param($t, $l) $t.Apps[1].Depots[0].TargetType = 'Game' })).Apps[1].Depots[0].ServerLauncher
        $launcher.Title | Should -BeExactly 'Game server'
    }
}

Describe 'Import-OgSteamConfig schema version 2' {

    BeforeAll {
        function New-TestV2Table {
            [ordered]@{
                SchemaVersion  = 2
                ProjectFile    = '..\Game\Game.uproject'
                Platform       = 'Win64'
                BuilderAccount = ''
                Branch         = 'playtest'
                OutputRoot     = '..\Game\Saved\Steam\Builds'
                KeepLast       = 3
                Builds         = @(
                    [ordered]@{
                        Name               = 'client'
                        TargetType         = 'Client'
                        Configuration      = 'Shipping'
                        ExpectedExecutable = 'GameClient.exe'
                        FileExclusions     = @('*.pdb', 'Manifest_*.txt')
                    }
                    [ordered]@{
                        Name               = 'server'
                        TargetType         = 'Server'
                        Configuration      = 'Shipping'
                        ExpectedExecutable = 'GameServer.exe'
                        FileExclusions     = @('*.pdb', 'HostLogs\*')
                        ExtraFiles         = @([ordered]@{ Source = '..\Game\run_server_template.bat'; Destination = 'run_server.bat' })
                        ServerLauncher     = [ordered]@{
                            Title           = 'Game server'
                            Port            = 7777
                            JoinLinePattern = 'S: (?:(?<joined>joined)|(?<left>left)) players=(?<players>\d+)'
                            ClientLaunch    = @('..\GameClient.exe', 'steam://rungameid/{AppId:game}')
                        }
                    }
                )
                Apps           = @(
                    [ordered]@{
                        Name   = 'game'
                        AppId  = 0
                        Depots = @(
                            [ordered]@{ Name = 'game-client'; DepotId = 0; Build = 'client' }
                            [ordered]@{ Name = 'game-server'; DepotId = 0; Build = 'server'; DepotPath = 'Server' }
                        )
                    }
                    [ordered]@{
                        Name   = 'server-tool'
                        AppId  = 0
                        Depots = @(
                            [ordered]@{ Name = 'tool-server'; DepotId = 0; Build = 'server' }
                        )
                    }
                )
                Profiles       = [ordered]@{
                    Default         = 'playtest'
                    'playtest'      = @('game-client', 'game-server')
                    'playtest-tool' = @('game-client', 'game-server', 'tool-server')
                    'game-only'     = 'game-client'
                }
            }
        }

        function Write-TestV2Config {
            param([scriptblock] $Mutate)
            $table = New-TestV2Table
            if ($Mutate) { & $Mutate $table }
            $path = Join-Path $TestDrive 'config\steam-publish.psd1'
            Set-Content -LiteralPath $path -Value (ConvertTo-TestPsd1Text $table) -Encoding utf8
            $path
        }

        function Get-TestThrowPattern {
            param([string] $Message)
            $Message.Replace('[', '`[').Replace(']', '`]')
        }
    }

    Context 'A fully valid version 2 config' {

        BeforeAll {
            $config = Import-TestSteamConfig (Write-TestV2Config)
        }

        It 'returns the builds with their keys and absolute ExtraFiles sources' {
            $config.SchemaVersion | Should -Be 2
            @($config.Builds | ForEach-Object Name) | Should -Be @('client', 'server')
            $server = $config.Builds[1]
            $server | Should -BeOfType [pscustomobject]
            $server.TargetType | Should -Be 'Server'
            $server.Configuration | Should -Be 'Shipping'
            $server.ExpectedExecutable | Should -Be 'GameServer.exe'
            $server.FileExclusions | Should -Be @('*.pdb', 'HostLogs\*')
            $server.ExtraFiles[0].Source | Should -Be (Join-Path $TestDrive 'Game\run_server_template.bat')
            $server.ServerLauncher.Title | Should -BeExactly 'Game server'
            $server.ServerLauncher.ClientLaunch | Should -Be @('..\GameClient.exe', 'steam://rungameid/{AppId:game}')
            $config.Builds[0].ServerLauncher | Should -BeNullOrEmpty
        }

        It 'gives every depot its build, its DepotPath and its build''s keys' {
            $client = $config.Apps[0].Depots[0]
            $client.Name | Should -Be 'game-client'
            $client.Build | Should -Be 'client'
            $client.DepotPath | Should -Be '.'
            $client.TargetType | Should -Be 'Client'
            $client.ExpectedExecutable | Should -Be 'GameClient.exe'
            $client.AppName | Should -Be 'game'

            $gameServer = $config.Apps[0].Depots[1]
            $gameServer.Build | Should -Be 'server'
            $gameServer.DepotPath | Should -Be 'Server'
            $gameServer.FileExclusions | Should -Be @('*.pdb', 'HostLogs\*')

            $toolServer = $config.Apps[1].Depots[0]
            $toolServer.Build | Should -Be 'server'
            $toolServer.DepotPath | Should -Be '.'
            $toolServer.AppName | Should -Be 'server-tool'
            [object]::ReferenceEquals($toolServer.ServerLauncher, $gameServer.ServerLauncher) | Should -BeTrue
        }

        It 'returns the profiles sorted by name and the default profile' {
            @($config.Profiles | ForEach-Object Name) | Should -Be @('game-only', 'playtest', 'playtest-tool')
            ($config.Profiles | Where-Object Name -EQ 'playtest-tool').Depots | Should -Be @('game-client', 'game-server', 'tool-server')
            , ($config.Profiles | Where-Object Name -EQ 'game-only').Depots | Should -BeOfType [string[]]
            ($config.Profiles | Where-Object Name -EQ 'game-only').Depots | Should -Be @('game-client')
            $config.DefaultProfile | Should -BeExactly 'playtest'
        }

        It 'matches build, depot and profile references case-insensitively and returns the defined casing' {
            $c = Import-TestSteamConfig (Write-TestV2Config {
                    param($t)
                    $t.Apps[0].Depots[1].Build = 'SERVER'
                    $t.Profiles.'game-only' = @('Game-Client', 'game-client')
                    $t.Profiles.Default = 'PlayTest'
                })
            $c.Apps[0].Depots[1].Build | Should -BeExactly 'server'
            ($c.Profiles | Where-Object Name -EQ 'game-only').Depots | Should -Be @('game-client')
            $c.DefaultProfile | Should -BeExactly 'playtest'
        }

        It 'accepts a version 2 config without Profiles' {
            $c = Import-TestSteamConfig (Write-TestV2Config { param($t) $t.Remove('Profiles') })
            @($c.Profiles).Count | Should -Be 0
            $c.DefaultProfile | Should -BeExactly ''
        }

        It 'warns about a build that no depot uses, without failing' {
            $path = Write-TestV2Config {
                param($t)
                $t.Builds += [ordered]@{ Name = 'spare'; TargetType = 'Game'; Configuration = 'Development' }
            }
            $output = @(InModuleScope og-framework -Parameters @{ Path = $path } {
                    param($Path)
                    Import-OgSteamConfig -Path $Path 3>&1
                })
            $warnings = @($output | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
            $c = @($output | Where-Object { $_ -isnot [System.Management.Automation.WarningRecord] })[0]
            $c.Builds.Count | Should -Be 3
            $warnings.Count | Should -Be 1
            $warnings[0].Message | Should -Match "build 'spare' \(Builds\[2\]\) is not used by any depot"
            $quiet = @(InModuleScope og-framework -Parameters @{ Path = (Write-TestV2Config) } {
                    param($Path)
                    Import-OgSteamConfig -Path $Path 3>&1
                })
            @($quiet | Where-Object { $_ -is [System.Management.Automation.WarningRecord] }).Count | Should -Be 0
        }

        It 'normalises DepotPath <Given> to <Expected>' -TestCases @(
            @{ Given = 'Server'; Expected = 'Server' }
            @{ Given = 'Server/Bin'; Expected = 'Server\Bin' }
            @{ Given = '.\Server\'; Expected = 'Server' }
            @{ Given = 'Server//Bin/./x'; Expected = 'Server\Bin\x' }
            @{ Given = '.'; Expected = '.' }
            @{ Given = './'; Expected = '.' }
        ) {
            $g = $Given
            $c = Import-TestSteamConfig (Write-TestV2Config { param($t) $t.Apps[0].Depots[1].DepotPath = $g }.GetNewClosure())
            $c.Apps[0].Depots[1].DepotPath | Should -BeExactly $Expected
        }
    }

    Context 'Version 1 configs' {

        It 'turns each version 1 depot into a build named after it with DepotPath .' {
            $c = Import-TestSteamConfig (Write-TestSteamConfig)
            @($c.Builds | ForEach-Object Name) | Should -Be @('client-win64', 'server-win64')
            $c.Builds[1].ExtraFiles[0].Destination | Should -Be 'run_server.bat'
            foreach ($depot in @($c.Apps | ForEach-Object { $_.Depots })) {
                $depot.Build | Should -BeExactly $depot.Name
                $depot.DepotPath | Should -BeExactly '.'
            }
            @($c.Profiles).Count | Should -Be 0
            $c.DefaultProfile | Should -BeExactly ''
        }

        It 'rejects the version 2 key <Key> in a version 1 config' -TestCases @(
            @{ Key = 'Profiles'; Mutate = { param($t) $t.Profiles = @{ Default = 'x'; x = @('client-win64') } } }
            @{ Key = 'Builds'; Mutate = { param($t) $t.Builds = @() } }
            @{ Key = 'Apps[0].Depots[0].DepotPath'; Mutate = { param($t) $t.Apps[0].Depots[0].DepotPath = 'Server' } }
            @{ Key = 'Apps[0].Depots[0].Build'; Mutate = { param($t) $t.Apps[0].Depots[0].Build = 'client' } }
        ) {
            $path = Write-TestSteamConfig $Mutate
            { Import-TestSteamConfig $path } | Should -Throw "*unknown key '$([WildcardPattern]::Escape($Key))'*"
        }
    }

    Context 'Version 2 rejections, each naming the offending key' {

        It 'rejects <Case>' -TestCases @(
            @{ Case = 'a missing Builds'; Mutate = { param($t) $t.Remove('Builds') }; Message = "*missing required key 'Builds'*" }
            @{ Case = 'an empty Builds'; Mutate = { param($t) $t.Builds = @() }; Message = "*'Builds' must contain at least one build*" }
            @{ Case = 'an unknown top-level key'; Mutate = { param($t) $t.Profile = 'x' }; Message = "*unknown key 'Profile'*" }
            @{ Case = 'a build that is not a hashtable'; Mutate = { param($t) $t.Builds = @('client') }; Message = "*'Builds[0]' must be a hashtable*" }
            @{ Case = 'an unknown build key'; Mutate = { param($t) $t.Builds[0].DepotId = 5 }; Message = "*unknown key 'Builds[0].DepotId'*" }
            @{ Case = 'a build without Name'; Mutate = { param($t) $t.Builds[0].Remove('Name') }; Message = "*missing required key 'Builds[0].Name'*" }
            @{ Case = 'a build without TargetType'; Mutate = { param($t) $t.Builds[1].Remove('TargetType') }; Message = "*missing required key 'Builds[1].TargetType'*" }
            @{ Case = 'a build name with capitals'; Mutate = { param($t) $t.Builds[0].Name = 'Client'; $t.Apps[0].Depots[0].Build = 'Client' }; Message = "*'Builds[0].Name' must match*" }
            @{ Case = 'a duplicate build name'; Mutate = { param($t) $t.Builds[1].Name = 'client' }; Message = "*duplicate build name 'client' at 'Builds[1].Name'*" }
            @{ Case = 'a bad build TargetType'; Mutate = { param($t) $t.Builds[0].TargetType = 'Editor' }; Message = "*'Builds[0].TargetType' must be one of*" }
            @{ Case = 'a ServerLauncher on a Client build'; Mutate = { param($t) $t.Builds[0].ServerLauncher = $t.Builds[1].ServerLauncher }; Message = "*'Builds[0].ServerLauncher' needs TargetType Server or Game*" }
            @{ Case = 'a build ExtraFiles Destination outside the content root'; Mutate = { param($t) $t.Builds[1].ExtraFiles[0].Destination = '..\x.bat' }; Message = "*'Builds[1].ExtraFiles[0].Destination' must be a path inside*" }
            @{ Case = 'a build key on a version 2 depot'; Mutate = { param($t) $t.Apps[0].Depots[0].TargetType = 'Client' }; Message = "*unknown key 'Apps[0].Depots[0].TargetType'*" }
            @{ Case = 'a depot without Build'; Mutate = { param($t) $t.Apps[0].Depots[0].Remove('Build') }; Message = "*missing required key 'Apps[0].Depots[0].Build'*" }
            @{ Case = 'a depot naming an unknown build'; Mutate = { param($t) $t.Apps[1].Depots[0].Build = 'dedicated' }; Message = "*'Apps[1].Depots[0].Build' names unknown build 'dedicated'. Builds: client, server*" }
            @{ Case = 'a duplicate depot name across apps'; Mutate = { param($t) $t.Apps[1].Depots[0].Name = 'game-server' }; Message = "*duplicate depot name 'game-server' at 'Apps[1].Depots[0].Name'*" }
            @{ Case = 'a ClientLaunch token naming an unknown app'; Mutate = { param($t) $t.Builds[1].ServerLauncher.ClientLaunch = @('steam://rungameid/{AppId:client}') }; Message = "*'Builds[1].ServerLauncher.ClientLaunch' references unknown app 'client'*" }
            @{ Case = 'Profiles that is not a hashtable'; Mutate = { param($t) $t.Profiles = @('playtest') }; Message = "*'Profiles' must be a hashtable*" }
            @{ Case = 'Profiles without Default'; Mutate = { param($t) $t.Profiles.Remove('Default') }; Message = "*missing required key 'Profiles.Default'*" }
            @{ Case = 'a Default naming an unknown profile'; Mutate = { param($t) $t.Profiles.Default = 'release' }; Message = "*'Profiles.Default' names unknown profile 'release'. Profiles: game-only, playtest, playtest-tool*" }
            @{ Case = 'a Default that is not a string'; Mutate = { param($t) $t.Profiles.Default = @('playtest') }; Message = "*'Profiles.Default' must be a string*" }
            @{ Case = 'a profile entry naming an unknown depot'; Mutate = { param($t) $t.Profiles.'playtest-tool' = @('game-client', 'tool-servr') }; Message = "*'Profiles.playtest-tool[1]' names unknown depot 'tool-servr'*" }
            @{ Case = 'an empty profile'; Mutate = { param($t) $t.Profiles.'game-only' = @() }; Message = "*'Profiles.game-only' must name at least one depot*" }
            @{ Case = 'a profile name with capitals'; Mutate = { param($t) $t.Profiles.Release = @('game-client') }; Message = "*must match ^[a-z0-9-]+$, got 'Release'*" }
        ) {
            $path = Write-TestV2Config $Mutate
            { Import-TestSteamConfig $path } | Should -Throw (Get-TestThrowPattern $Message)
        }

        It 'rejects DepotPath <Given> (<Why>)' -TestCases @(
            @{ Given = '..'; Why = 'parent folder'; Message = "*'Apps[0].Depots[1].DepotPath' must not contain a '..' segment*" }
            @{ Given = 'Server\..\..\Other'; Why = 'parent segment inside'; Message = "*'Apps[0].Depots[1].DepotPath' must not contain a '..' segment*" }
            @{ Given = 'Server/../x'; Why = 'parent segment with /'; Message = "*'Apps[0].Depots[1].DepotPath' must not contain a '..' segment*" }
            @{ Given = 'C:\Server'; Why = 'drive root'; Message = "*'Apps[0].Depots[1].DepotPath' must be a relative path*" }
            @{ Given = 'C:Server'; Why = 'drive-relative'; Message = "*'Apps[0].Depots[1].DepotPath' must be a relative path*" }
            @{ Given = '\Server'; Why = 'rooted'; Message = "*'Apps[0].Depots[1].DepotPath' must be a relative path*" }
            @{ Given = '/Server'; Why = 'rooted with /'; Message = "*'Apps[0].Depots[1].DepotPath' must be a relative path*" }
            @{ Given = '\\host\share'; Why = 'UNC'; Message = "*'Apps[0].Depots[1].DepotPath' must be a relative path*" }
            @{ Given = 'Server\*'; Why = 'wildcard *'; Message = "*'Apps[0].Depots[1].DepotPath' must not contain a wildcard*" }
            @{ Given = 'Serv?r'; Why = 'wildcard ?'; Message = "*'Apps[0].Depots[1].DepotPath' must not contain a wildcard*" }
            @{ Given = 'Ser|ver'; Why = 'invalid character'; Message = "*'Apps[0].Depots[1].DepotPath' holds a character a folder name cannot hold*" }
            @{ Given = ''; Why = 'empty'; Message = "*'Apps[0].Depots[1].DepotPath' must not be empty*" }
        ) {
            $g = $Given
            $path = Write-TestV2Config { param($t) $t.Apps[0].Depots[1].DepotPath = $g }.GetNewClosure()
            { Import-TestSteamConfig $path } | Should -Throw (Get-TestThrowPattern $Message)
        }

        It 'rejects a DepotPath that is not a string' {
            $path = Write-TestV2Config { param($t) $t.Apps[0].Depots[1].DepotPath = 5 }
            { Import-TestSteamConfig $path } | Should -Throw (Get-TestThrowPattern "*'Apps[0].Depots[1].DepotPath' must be a string*")
        }
    }
}
