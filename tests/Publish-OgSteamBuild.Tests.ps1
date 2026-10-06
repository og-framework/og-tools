# SPDX-License-Identifier: MPL-2.0
#Requires -Modules Pester

BeforeAll {
    $moduleRoot = Split-Path -Parent $PSScriptRoot
    Import-Module "$moduleRoot\og-framework.psd1" -Force

    function New-TestSteamConfig {
        param(
            [string] $Root,
            [int] $ClientAppId = 0,
            [int] $ClientDepotId = 0,
            [int] $ServerAppId = 0,
            [int] $ServerDepotId = 0,
            [string] $BuilderAccount = '',
            [string] $Branch = 'playtest',
            [int] $KeepLast = 3,
            [string] $ServerLauncher = '',
            [string] $ServerFileExclusions = "@('*.pdb')",
            [string] $ServerExtraDestination = 'run_server.bat'
        )
        New-Item -ItemType Directory -Path (Join-Path $Root 'project\tools\steam') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $Root 'project\Game.uproject') -Value '{}'
        Set-Content -LiteralPath (Join-Path $Root 'project\tools\server template.bat') -Value '@echo server'
        $configPath = Join-Path $Root 'project\tools\steam\steam-publish.psd1'
        Set-Content -LiteralPath $configPath -Value @"
@{
    SchemaVersion  = 1
    ProjectFile    = '..\..\Game.uproject'
    EngineRoot     = ''
    Platform       = 'Win64'
    BuilderAccount = '$BuilderAccount'
    Branch         = '$Branch'
    OutputRoot     = '..\..\Saved\Steam\Builds'
    KeepLast       = $KeepLast
    Apps = @(
        @{
            Name   = 'client'
            AppId  = $ClientAppId
            Depots = @(
                @{
                    Name               = 'client-win64'
                    DepotId            = $ClientDepotId
                    TargetType         = 'Client'
                    Configuration      = 'Shipping'
                    ExpectedExecutable = 'GameClient.exe'
                    FileExclusions     = @('*.pdb', 'Manifest_*.txt')
                }
            )
        }
        @{
            Name   = 'server'
            AppId  = $ServerAppId
            Depots = @(
                @{
                    Name               = 'server-win64'
                    DepotId            = $ServerDepotId
                    TargetType         = 'Server'
                    Configuration      = 'Development'
                    ExpectedExecutable = 'GameServer.exe'
                    FileExclusions     = $ServerFileExclusions
                    ExtraFiles         = @(@{ Source = '..\server template.bat'; Destination = '$ServerExtraDestination' })
                    $ServerLauncher
                }
            )
        }
    )
}
"@
        $configPath
    }

    function New-UploadReadyConfig {
        param([string] $Root, [int] $KeepLast = 3)
        New-TestSteamConfig -Root $Root -ClientAppId 1000 -ClientDepotId 1001 -ServerAppId 2000 -ServerDepotId 2001 `
            -BuilderAccount 'builder' -KeepLast $KeepLast
    }
}

Describe 'Publish-OgSteamBuild' {

    BeforeEach {
        $script:root        = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:outputRoot  = Join-Path $root 'project\Saved\Steam\Builds'
        $script:gitStatus   = ''
        $script:steamExit   = 0
        $script:steamCmdExe = Join-Path $root 'steam cmd\steamcmd.exe'
        $script:callLog     = [System.Collections.Generic.List[string]]::new()

        Mock -ModuleName og-framework -CommandName Invoke-Git -ParameterFilter { $Arguments[0] -eq 'status' } -MockWith {
            $callLog.Add('git status')
            [pscustomobject]@{ ExitCode = 0; StdOut = $gitStatus; StdErr = ''; WorkingDirectory = $WorkingDirectory }
        }
        Mock -ModuleName og-framework -CommandName Invoke-Git -ParameterFilter { $Arguments[0] -eq 'rev-parse' } -MockWith {
            $callLog.Add('git rev-parse')
            [pscustomobject]@{ ExitCode = 0; StdOut = 'abc1234'; StdErr = ''; WorkingDirectory = $WorkingDirectory }
        }
        Mock -ModuleName og-framework -CommandName Invoke-OgUnrealPackage -MockWith {
            $callLog.Add("package $TargetType")
            $platform = @{ Client = 'WindowsClient'; Server = 'WindowsServer'; Game = 'Windows' }[$TargetType]
            $contentRoot = Join-Path $ArchiveDirectory $platform
            New-Item -ItemType Directory -Path $contentRoot -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $contentRoot $ExpectedExecutable) -Value ('x' * 98) -NoNewline
            Set-Content -LiteralPath (Join-Path $contentRoot 'Game.pdb') -Value ('p' * 10) -NoNewline
            [pscustomobject]@{
                ContentRoot = $contentRoot; ArchiveDirectory = $ArchiveDirectory
                LogPath = 'uat.log'; ExitCode = 0; Duration = [timespan]::Zero
            }
        }
        Mock -ModuleName og-framework -CommandName Resolve-OgSteamCmd -MockWith {
            $callLog.Add('resolve steamcmd')
            $steamCmdExe
        }
        Mock -ModuleName og-framework -CommandName Invoke-OgProcess -MockWith {
            $callLog.Add('steamcmd')
            [pscustomobject]@{ ExitCode = $steamExit; LogPath = $null; Duration = [timespan]::Zero }
        }
    }

    Context 'Happy path with -NoUpload' {
        BeforeEach {
            $script:config = New-TestSteamConfig -Root $root
            $script:result = Publish-OgSteamBuild -ConfigPath $config -NoUpload
        }

        It 'never resolves or runs steamcmd' {
            Should -Invoke -ModuleName og-framework -CommandName Resolve-OgSteamCmd -Times 0 -Exactly
            Should -Invoke -ModuleName og-framework -CommandName Invoke-OgProcess -Times 0 -Exactly
            $result.Uploaded | Should -BeFalse
        }

        It 'labels the build yyyyMMdd-HHmmss-sha7 from a clean tree' {
            $result.BuildLabel | Should -Match '^\d{8}-\d{6}-abc1234$'
            $result.GitSha | Should -Be 'abc1234'
            $result.Dirty | Should -BeFalse
            $result.BuildDirectory | Should -Be (Join-Path $outputRoot $result.BuildLabel)
        }

        It 'packages each depot into <OutputRoot>\<label>\<DepotName> with its config values' {
            $buildDir = Join-Path $outputRoot $result.BuildLabel
            $projectFile = Join-Path $root 'project\Game.uproject'
            Should -Invoke -ModuleName og-framework -CommandName Invoke-OgUnrealPackage -Times 1 -Exactly -ParameterFilter {
                $ProjectFile -eq $projectFile -and $TargetType -eq 'Client' -and $Configuration -eq 'Shipping' -and
                $ArchiveDirectory -eq (Join-Path $buildDir 'client-win64') -and $ExpectedExecutable -eq 'GameClient.exe' -and
                -not $PesterBoundParameters.ContainsKey('EngineRoot')
            }
            Should -Invoke -ModuleName og-framework -CommandName Invoke-OgUnrealPackage -Times 1 -Exactly -ParameterFilter {
                $TargetType -eq 'Server' -and $Configuration -eq 'Development' -and
                $ArchiveDirectory -eq (Join-Path $buildDir 'server-win64') -and $ExpectedExecutable -eq 'GameServer.exe'
            }
        }

        It 'copies ExtraFiles into the depot ContentRoot' {
            $server = $result.Depots | Where-Object Name -eq 'server-win64'
            Get-Content -LiteralPath (Join-Path $server.ContentRoot 'run_server.bat') | Should -Be '@echo server'
        }

        It 'reports each depot ContentRoot and size' {
            $client = $result.Depots | Where-Object Name -eq 'client-win64'
            $client.AppName | Should -Be 'client'
            $client.ContentRoot | Should -Be (Join-Path $outputRoot "$($result.BuildLabel)\client-win64\WindowsClient")
            $client.SizeBytes | Should -Be (108 + (Get-Item -LiteralPath (Join-Path $client.ContentRoot 'build_info.txt')).Length)
        }

        It 'writes one app VDF per app into _steam\<AppName>, so placeholder IDs do not collide' {
            $steamDir = Join-Path $outputRoot "$($result.BuildLabel)\_steam"
            $result.AppVdfs.Count | Should -Be 2
            ($result.AppVdfs | Where-Object AppName -eq 'client').Path | Should -Be (Join-Path $steamDir 'client\app_build_0.vdf')
            ($result.AppVdfs | Where-Object AppName -eq 'server').Path | Should -Be (Join-Path $steamDir 'server\app_build_0.vdf')
            foreach ($vdf in $result.AppVdfs) { Test-Path -LiteralPath $vdf.Path | Should -BeTrue }
        }

        It 'fills the VDFs with the label, the config branch, the shared BuildOutput and the depot ContentRoot' {
            $steamDir = Join-Path $outputRoot "$($result.BuildLabel)\_steam"
            $app = Get-Content -Raw -LiteralPath (Join-Path $steamDir 'server\app_build_0.vdf')
            $app | Should -Match ('"Desc"\t"' + $result.BuildLabel + '"')
            $app | Should -Match '"SetLive"\t"playtest"'
            $app | Should -Match '"Preview"\t"0"'
            $app | Should -Match ('"BuildOutput"\t"' + [regex]::Escape((Join-Path $steamDir 'output').Replace('\', '\\')) + '"')
            $depot = Get-Content -Raw -LiteralPath (Join-Path $steamDir 'server\depot_build_0.vdf')
            $serverRoot = ($result.Depots | Where-Object Name -eq 'server-win64').ContentRoot
            $depot | Should -Match ('"ContentRoot"\t"' + [regex]::Escape($serverRoot.Replace('\', '\\')) + '"')
            $depot | Should -Match '"FileExclusion"\t"\*\.pdb"'
            $result.Branch | Should -Be 'playtest'
        }
    }

    Context 'build_info.txt' {
        It 'writes label, sha, dirty and created as UTF-8 without BOM, LF, in that order' {
            $config = New-TestSteamConfig -Root $root
            $before = [datetime]::UtcNow.AddSeconds(-1)
            $result = Publish-OgSteamBuild -ConfigPath $config -NoUpload
            $after = [datetime]::UtcNow.AddSeconds(1)
            $bytes = [System.IO.File]::ReadAllBytes((Join-Path $result.Depots[0].ContentRoot 'build_info.txt'))
            @($bytes[0..2]) | Should -Not -Be @(0xEF, 0xBB, 0xBF)
            $text = [System.Text.Encoding]::UTF8.GetString($bytes)
            $text | Should -Not -Match "`r"
            $text | Should -Match "`n$"
            $lines = $text.TrimEnd("`n").Split("`n")
            $lines.Count | Should -Be 4
            $lines[0] | Should -BeExactly "label=$($result.BuildLabel)"
            $lines[1] | Should -BeExactly 'sha=abc1234'
            $lines[2] | Should -BeExactly 'dirty=false'
            $lines[3] | Should -Match '^created=\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$'
            $created = [datetime]::ParseExact($lines[3].Substring(8), "yyyy-MM-dd'T'HH:mm:ss'Z'", [cultureinfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal)
            $created | Should -BeGreaterOrEqual $before
            $created | Should -BeLessOrEqual $after
        }

        It 'places one identical build_info.txt in the ContentRoot of every depot and nowhere else' {
            $config = New-TestSteamConfig -Root $root
            $result = Publish-OgSteamBuild -ConfigPath $config -NoUpload
            $found = @(Get-ChildItem -LiteralPath $outputRoot -Recurse -File -Filter 'build_info.txt' | ForEach-Object FullName | Sort-Object)
            $expected = @($result.Depots | ForEach-Object { Join-Path $_.ContentRoot 'build_info.txt' } | Sort-Object)
            $found.Count | Should -Be 2
            $found | Should -Be $expected
            @($result.Depots | ForEach-Object BuildInfoPath | Sort-Object) | Should -Be $expected
            Get-Content -Raw -LiteralPath $found[0] | Should -BeExactly (Get-Content -Raw -LiteralPath $found[1])
        }

        It 'writes dirty=true and the -dirty label for a dirty build with -AllowDirty' {
            $script:gitStatus = ' M Source/Game.cpp'
            $config = New-TestSteamConfig -Root $root
            $result = Publish-OgSteamBuild -ConfigPath $config -NoUpload -AllowDirty
            foreach ($depot in $result.Depots) {
                $lines = (Get-Content -Raw -LiteralPath $depot.BuildInfoPath).TrimEnd("`n").Split("`n")
                $lines[0] | Should -BeExactly "label=$($result.BuildLabel)"
                $lines[0] | Should -Match '-dirty$'
                $lines[2] | Should -BeExactly 'dirty=true'
            }
        }

        It 'rewrites build_info.txt in every depot on -SkipPackage, from the label' {
            $config = New-TestSteamConfig -Root $root
            $label = '20250101-000000-def5678-dirty'
            foreach ($d in 'client-win64\WindowsClient', 'server-win64\WindowsServer') {
                New-Item -ItemType Directory -Path (Join-Path $outputRoot "$label\$d") -Force | Out-Null
            }
            Set-Content -LiteralPath (Join-Path $outputRoot "$label\client-win64\WindowsClient\GameClient.exe") -Value 'x'
            Set-Content -LiteralPath (Join-Path $outputRoot "$label\server-win64\WindowsServer\GameServer.exe") -Value 'x'
            Set-Content -LiteralPath (Join-Path $outputRoot "$label\client-win64\WindowsClient\build_info.txt") -Value 'label=stale'

            $result = Publish-OgSteamBuild -ConfigPath $config -NoUpload -SkipPackage -BuildLabel $label -AllowDirty

            Should -Invoke -ModuleName og-framework -CommandName Invoke-OgUnrealPackage -Times 0 -Exactly
            foreach ($d in 'client-win64\WindowsClient', 'server-win64\WindowsServer') {
                $lines = (Get-Content -Raw -LiteralPath (Join-Path $outputRoot "$label\$d\build_info.txt")).TrimEnd("`n").Split("`n")
                $lines.Count | Should -Be 4
                $lines[0..2] | Should -Be @("label=$label", 'sha=def5678', 'dirty=true')
            }
            @($result.Depots | ForEach-Object BuildInfoPath).Count | Should -Be 2
        }

        It 'is counted in SizeBytes and coexists with ExtraFiles' {
            $config = New-TestSteamConfig -Root $root
            $result = Publish-OgSteamBuild -ConfigPath $config -NoUpload
            $server = $result.Depots | Where-Object Name -eq 'server-win64'
            $server.SizeBytes | Should -Be (Get-ChildItem -LiteralPath $server.ContentRoot -File -Recurse | Measure-Object Length -Sum).Sum
            Join-Path $server.ContentRoot 'run_server.bat' | Should -Exist
            $server.BuildInfoPath | Should -Exist
        }

        It 'rejects a FileExclusions pattern <Pattern> that matches build_info.txt, before git or packaging' -TestCases @(
            @{ Pattern = '*.txt' }, @{ Pattern = 'build_info.*' }, @{ Pattern = 'BUILD_INFO.TXT' }, @{ Pattern = '*' }, @{ Pattern = 'build?info.txt' }
        ) {
            $config = New-TestSteamConfig -Root $root
            (Get-Content -Raw -LiteralPath $config).Replace("FileExclusions     = @('*.pdb')", "FileExclusions     = @('*.pdb', '$Pattern')") |
                Set-Content -LiteralPath $config
            { Publish-OgSteamBuild -ConfigPath $config -NoUpload } | Should -Throw "*pattern '$Pattern' of depot 'server-win64' matches 'build_info.txt'*"
            Should -Invoke -ModuleName og-framework -CommandName Invoke-Git -Times 0 -Exactly
            Should -Invoke -ModuleName og-framework -CommandName Invoke-OgUnrealPackage -Times 0 -Exactly
        }

        It 'accepts FileExclusions that do not match build_info.txt' {
            $config = New-TestSteamConfig -Root $root
            (Get-Content -Raw -LiteralPath $config).Replace("FileExclusions     = @('*.pdb')", "FileExclusions     = @('*.pdb', '[b]uild_info.txt', 'build_info.txt.bak')") |
                Set-Content -LiteralPath $config
            $result = Publish-OgSteamBuild -ConfigPath $config -NoUpload
            ($result.Depots | Where-Object Name -eq 'server-win64').BuildInfoPath | Should -Exist
        }

        It 'rejects an ExtraFiles Destination named build_info.txt, before packaging' {
            $config = New-TestSteamConfig -Root $root
            (Get-Content -Raw -LiteralPath $config).Replace("Destination = 'run_server.bat'", "Destination = 'build_info.txt'") |
                Set-Content -LiteralPath $config
            { Publish-OgSteamBuild -ConfigPath $config -NoUpload } | Should -Throw "*ExtraFiles Destination 'build_info.txt'*reserved*"
            Should -Invoke -ModuleName og-framework -CommandName Invoke-OgUnrealPackage -Times 0 -Exactly
        }
    }

    Context 'Upload size' {
        It 'reports SizeBytes as the whole ContentRoot and UploadBytes without the FileExclusions matches' {
            $config = New-TestSteamConfig -Root $root
            $result = Publish-OgSteamBuild -ConfigPath $config -NoUpload
            $client = $result.Depots | Where-Object Name -EQ 'client-win64'
            $buildInfo = (Get-Item -LiteralPath $client.BuildInfoPath).Length
            $client.SizeBytes | Should -Be (98 + 10 + $buildInfo)
            $client.UploadBytes | Should -Be (98 + $buildInfo)
        }

        It 'matches FileExclusions against the path relative to the ContentRoot, with * spanning folders' {
            $config = New-TestSteamConfig -Root $root -ServerFileExclusions "@('*.pdb', 'HostLogs\*', 'join_info.txt', 'Game\Saved\*')"
            $first = Publish-OgSteamBuild -ConfigPath $config -NoUpload
            $serverRoot = ($first.Depots | Where-Object Name -EQ 'server-win64').ContentRoot
            $plant = @{
                'HostLogs\server-1.log'              = 1000
                'HostLogs\old\server-0.log'          = 2000
                'join_info.txt'                      = 40
                'Game\Saved\Logs\Game.log'           = 3000
                'Game\Binaries\Win64\GameServer.pdb' = 5000
                'Game\Content\join_info.txt'         = 7
                'Game\Content\Saved.txt'             = 11
                'Engine\Saved\Config\Manifest.ini'   = 13
            }
            foreach ($relative in $plant.Keys) {
                $path = Join-Path $serverRoot $relative
                New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
                Set-Content -LiteralPath $path -Value ('r' * $plant[$relative]) -NoNewline
            }

            $result = Publish-OgSteamBuild -ConfigPath $config -NoUpload -SkipPackage -BuildLabel $first.BuildLabel
            $server = $result.Depots | Where-Object Name -EQ 'server-win64'
            $total = (Get-ChildItem -LiteralPath $serverRoot -File -Recurse -Force | Measure-Object Length -Sum).Sum
            $server.SizeBytes | Should -Be $total
            $server.UploadBytes | Should -Be ($total - 10 - 1000 - 2000 - 40 - 3000 - 5000)
        }

        It 'treats [ and ] in a FileExclusions pattern as literal characters' {
            $config = New-TestSteamConfig -Root $root -ServerFileExclusions "@('[G]ame.pdb')"
            $first = Publish-OgSteamBuild -ConfigPath $config -NoUpload
            $serverRoot = ($first.Depots | Where-Object Name -EQ 'server-win64').ContentRoot
            Set-Content -LiteralPath (Join-Path $serverRoot '[G]ame.pdb') -Value ('b' * 20) -NoNewline
            $result = Publish-OgSteamBuild -ConfigPath $config -NoUpload -SkipPackage -BuildLabel $first.BuildLabel
            $server = $result.Depots | Where-Object Name -EQ 'server-win64'
            $server.UploadBytes | Should -Be ($server.SizeBytes - 20)
        }

        It 'reports UploadBytes equal to SizeBytes when no pattern matches' {
            $config = New-TestSteamConfig -Root $root -ServerFileExclusions "@('nothing.here')"
            $result = Publish-OgSteamBuild -ConfigPath $config -NoUpload
            $server = $result.Depots | Where-Object Name -EQ 'server-win64'
            $server.UploadBytes | Should -BeOfType [long]
            $server.UploadBytes | Should -Be $server.SizeBytes
        }
    }

    Context 'Parameters passed through to the VDFs' {
        It 'uses -Description, -Branch and -Preview' {
            $config = New-TestSteamConfig -Root $root
            $result = Publish-OgSteamBuild -ConfigPath $config -NoUpload -Description 'Playtest 3' -Branch 'qa' -Preview
            $app = Get-Content -Raw -LiteralPath ($result.AppVdfs | Where-Object AppName -eq 'client').Path
            $app | Should -Match '"Desc"\t"Playtest 3"'
            $app | Should -Match '"SetLive"\t"qa"'
            $app | Should -Match '"Preview"\t"1"'
            $result.Branch | Should -Be 'qa'
            $result.Preview | Should -BeTrue
        }

        It 'omits SetLive when -Branch is empty' {
            $config = New-TestSteamConfig -Root $root
            $result = Publish-OgSteamBuild -ConfigPath $config -NoUpload -Branch ''
            Get-Content -Raw -LiteralPath $result.AppVdfs[0].Path | Should -Not -Match 'SetLive'
            $result.Branch | Should -Be ''
        }

        It 'passes EngineRoot to packaging when the config sets it' {
            $config = New-TestSteamConfig -Root $root
            New-Item -ItemType Directory -Path (Join-Path $root 'engine') | Out-Null
            (Get-Content -Raw -LiteralPath $config).Replace("EngineRoot     = ''", "EngineRoot     = '..\..\..\engine'") |
                Set-Content -LiteralPath $config
            Publish-OgSteamBuild -ConfigPath $config -NoUpload | Out-Null
            $engine = Join-Path $root 'engine'
            Should -Invoke -ModuleName og-framework -CommandName Invoke-OgUnrealPackage -Times 2 -Exactly -ParameterFilter {
                $EngineRoot -eq $engine
            }
        }
    }

    Context 'S1: the default branch' {
        It 'rejects -Branch <Value> before packaging, even with -NoUpload' -TestCases @(
            @{ Value = 'default' }, @{ Value = 'DEFAULT' }, @{ Value = ' Default ' }
        ) {
            $config = New-TestSteamConfig -Root $root
            { Publish-OgSteamBuild -ConfigPath $config -NoUpload -Branch $Value } | Should -Throw "*branch 'default' is rejected*"
            Should -Invoke -ModuleName og-framework -CommandName Invoke-OgUnrealPackage -Times 0 -Exactly
        }
    }

    Context 'S2: upload readiness is checked before packaging' {
        It 'rejects placeholder IDs on upload before git, packaging or steamcmd' {
            $config = New-TestSteamConfig -Root $root -BuilderAccount 'builder'
            { Publish-OgSteamBuild -ConfigPath $config } | Should -Throw '*AppId is the placeholder 0*'
            Should -Invoke -ModuleName og-framework -CommandName Invoke-Git -Times 0 -Exactly
            Should -Invoke -ModuleName og-framework -CommandName Invoke-OgUnrealPackage -Times 0 -Exactly
            Should -Invoke -ModuleName og-framework -CommandName Resolve-OgSteamCmd -Times 0 -Exactly
            Should -Invoke -ModuleName og-framework -CommandName Invoke-OgProcess -Times 0 -Exactly
        }

        It 'rejects an empty BuilderAccount on upload before packaging' {
            $config = New-TestSteamConfig -Root $root -ClientAppId 1000 -ClientDepotId 1001 -ServerAppId 2000 -ServerDepotId 2001
            { Publish-OgSteamBuild -ConfigPath $config } | Should -Throw '*BuilderAccount is empty*'
            Should -Invoke -ModuleName og-framework -CommandName Invoke-OgUnrealPackage -Times 0 -Exactly
        }

        It 'runs the readiness check and steamcmd resolution before git and packaging' {
            Mock -ModuleName og-framework -CommandName Assert-OgSteamUploadReady -MockWith { $callLog.Add('assert') }
            $config = New-UploadReadyConfig -Root $root
            Publish-OgSteamBuild -ConfigPath $config | Out-Null
            $callLog | Should -Be @(
                'assert', 'resolve steamcmd', 'git status', 'git rev-parse',
                'package Client', 'package Server', 'steamcmd', 'steamcmd'
            )
        }

        It 'forwards -Branch to the readiness check only when it is passed' {
            Mock -ModuleName og-framework -CommandName Assert-OgSteamUploadReady -MockWith { }
            $config = New-UploadReadyConfig -Root $root
            Publish-OgSteamBuild -ConfigPath $config | Out-Null
            Should -Invoke -ModuleName og-framework -CommandName Assert-OgSteamUploadReady -Times 1 -Exactly -ParameterFilter {
                -not $PesterBoundParameters.ContainsKey('Branch')
            }
            Publish-OgSteamBuild -ConfigPath $config -Branch '' -AllowDirty -BuildLabel (Get-ChildItem $outputRoot)[0].Name -SkipPackage | Out-Null
            Should -Invoke -ModuleName og-framework -CommandName Assert-OgSteamUploadReady -Times 1 -Exactly -ParameterFilter {
                $PesterBoundParameters.ContainsKey('Branch') -and $Branch -eq ''
            }
        }

        It 'passes -SteamCmdPath to the resolver' {
            $config = New-UploadReadyConfig -Root $root
            Publish-OgSteamBuild -ConfigPath $config -SteamCmdPath 'D:\steamcmd' | Out-Null
            Should -Invoke -ModuleName og-framework -CommandName Resolve-OgSteamCmd -Times 1 -Exactly -ParameterFilter {
                $Path -eq 'D:\steamcmd'
            }
        }
    }

    Context 'S3: dirty git tree' {
        It 'refuses a dirty tree without -AllowDirty, before packaging' {
            $script:gitStatus = ' M Source/Game.cpp'
            $config = New-TestSteamConfig -Root $root
            { Publish-OgSteamBuild -ConfigPath $config -NoUpload } | Should -Throw '*has uncommitted changes*-AllowDirty*'
            Should -Invoke -ModuleName og-framework -CommandName Invoke-OgUnrealPackage -Times 0 -Exactly
        }

        It 'builds a dirty tree with -AllowDirty and marks the label -dirty' {
            $script:gitStatus = '?? new.txt'
            $config = New-TestSteamConfig -Root $root
            $result = Publish-OgSteamBuild -ConfigPath $config -NoUpload -AllowDirty
            $result.BuildLabel | Should -Match '^\d{8}-\d{6}-abc1234-dirty$'
            $result.Dirty | Should -BeTrue
            Should -Invoke -ModuleName og-framework -CommandName Invoke-OgUnrealPackage -Times 2 -Exactly
        }

        It 'reads git state in the project folder' {
            $config = New-TestSteamConfig -Root $root
            Publish-OgSteamBuild -ConfigPath $config -NoUpload | Out-Null
            $projectDir = Join-Path $root 'project'
            Should -Invoke -ModuleName og-framework -CommandName Invoke-Git -Times 1 -Exactly -ParameterFilter {
                $WorkingDirectory -eq $projectDir -and ($Arguments -join ' ') -eq 'status --porcelain'
            }
            Should -Invoke -ModuleName og-framework -CommandName Invoke-Git -Times 1 -Exactly -ParameterFilter {
                $WorkingDirectory -eq $projectDir -and ($Arguments -join ' ') -eq 'rev-parse --short=7 HEAD'
            }
        }

        It 'throws when git status fails' {
            Mock -ModuleName og-framework -CommandName Invoke-Git -ParameterFilter { $Arguments[0] -eq 'status' } -MockWith {
                [pscustomobject]@{ ExitCode = 128; StdOut = ''; StdErr = 'fatal: not a git repository'; WorkingDirectory = $WorkingDirectory }
            }
            $config = New-TestSteamConfig -Root $root
            { Publish-OgSteamBuild -ConfigPath $config -NoUpload } | Should -Throw '*not a git repository*'
            Should -Invoke -ModuleName og-framework -CommandName Invoke-OgUnrealPackage -Times 0 -Exactly
        }
    }

    Context 'S4: steamcmd upload' {
        BeforeEach {
            $script:config = New-UploadReadyConfig -Root $root
        }

        It 'runs steamcmd once per app with exactly +login user +run_app_build vdf +quit, attached to the console' {
            $result = Publish-OgSteamBuild -ConfigPath $config
            Should -Invoke -ModuleName og-framework -CommandName Invoke-OgProcess -Times 2 -Exactly
            foreach ($appVdf in $result.AppVdfs) {
                $vdfPath = $appVdf.Path
                Should -Invoke -ModuleName og-framework -CommandName Invoke-OgProcess -Times 1 -Exactly -ParameterFilter {
                    $FilePath -eq $steamCmdExe -and
                    -not $PesterBoundParameters.ContainsKey('LogPath') -and
                    $ArgumentList.Count -eq 5 -and
                    $ArgumentList[0] -ceq '+login' -and $ArgumentList[1] -ceq 'builder' -and
                    $ArgumentList[2] -ceq '+run_app_build' -and $ArgumentList[3] -eq $vdfPath -and
                    $ArgumentList[4] -ceq '+quit'
                }
            }
            $result.Uploaded | Should -BeTrue
        }

        It 'never passes a password to steamcmd' {
            Publish-OgSteamBuild -ConfigPath $config | Out-Null
            Should -Invoke -ModuleName og-framework -CommandName Invoke-OgProcess -Times 0 -Exactly -ParameterFilter {
                @($ArgumentList | Where-Object { $_ -like '*password*' }).Count -gt 0 -or
                $ArgumentList[([array]::IndexOf($ArgumentList, '+login') + 2)] -notlike '+*'
            }
        }

        It 'throws on a non-zero steamcmd exit, naming the BuildOutput folder' {
            $script:steamExit = 5
            { Publish-OgSteamBuild -ConfigPath $config } | Should -Throw '*steamcmd failed for app ''client'' (1000) with exit code 5*_steam\output*'
        }
    }

    Context '-SkipPackage' {
        It 'throws when the build label does not exist' {
            $config = New-TestSteamConfig -Root $root
            { Publish-OgSteamBuild -ConfigPath $config -NoUpload -SkipPackage -BuildLabel '20260101-120000-abc1234' } |
                Should -Throw '*build ''20260101-120000-abc1234'' does not exist*'
        }

        It 'throws when a depot of the build is missing' {
            $config = New-TestSteamConfig -Root $root
            New-Item -ItemType Directory -Path (Join-Path $outputRoot '20260101-120000-abc1234\client-win64\WindowsClient') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $outputRoot '20260101-120000-abc1234\client-win64\WindowsClient\GameClient.exe') -Value 'x'
            { Publish-OgSteamBuild -ConfigPath $config -NoUpload -SkipPackage -BuildLabel '20260101-120000-abc1234' } |
                Should -Throw '*depot ''server-win64''*does not exist*'
        }

        It 'regenerates the VDFs of an existing build without git or packaging' {
            $config = New-TestSteamConfig -Root $root
            $first = Publish-OgSteamBuild -ConfigPath $config -NoUpload
            Remove-Item -LiteralPath (Join-Path $first.BuildDirectory '_steam') -Recurse -Force

            $second = Publish-OgSteamBuild -ConfigPath $config -NoUpload -SkipPackage -BuildLabel $first.BuildLabel

            Should -Invoke -ModuleName og-framework -CommandName Invoke-OgUnrealPackage -Times 2 -Exactly
            Should -Invoke -ModuleName og-framework -CommandName Invoke-Git -Times 2 -Exactly
            $second.BuildLabel | Should -Be $first.BuildLabel
            $second.GitSha | Should -Be 'abc1234'
            ($second.Depots | ForEach-Object ContentRoot) | Should -Be ($first.Depots | ForEach-Object ContentRoot)
            foreach ($vdf in $second.AppVdfs) { Test-Path -LiteralPath $vdf.Path | Should -BeTrue }
        }

        It 'refuses a -dirty label without -AllowDirty' {
            $config = New-TestSteamConfig -Root $root
            New-Item -ItemType Directory -Path (Join-Path $outputRoot '20260101-120000-abc1234-dirty') -Force | Out-Null
            { Publish-OgSteamBuild -ConfigPath $config -NoUpload -SkipPackage -BuildLabel '20260101-120000-abc1234-dirty' } |
                Should -Throw '*dirty git tree*-AllowDirty*'
        }

        It 'rejects a malformed -BuildLabel' {
            $config = New-TestSteamConfig -Root $root
            { Publish-OgSteamBuild -ConfigPath $config -NoUpload -SkipPackage -BuildLabel '..\elsewhere' } | Should -Throw
        }

        It 'requires -SkipPackage and -BuildLabel together' {
            $config = New-TestSteamConfig -Root $root
            { Publish-OgSteamBuild -ConfigPath $config -NoUpload -SkipPackage } | Should -Throw
            { Publish-OgSteamBuild -ConfigPath $config -NoUpload -BuildLabel '20260101-120000-abc1234' } | Should -Throw
        }
    }

    Context 'Server host launcher' {
        BeforeAll {
            $script:launcherText = "ServerLauncher = @{ Title = 'Game server'; Port = 7777; ServerArguments = '/Game/Maps/Arena'; " +
                "JoinLinePattern = 'S: (?:(?<joined>joined)|(?<left>left)) players=(?<players>\d+)'; " +
                "ClientLaunch = 'steam://rungameid/{AppId:client}'; LocalHint = 'Tab adds a player.' }"
            $script:launcherFiles = @('Host Local Playtest.bat', 'Host Online Playtest.bat', 'host_server.ps1', 'host_server.settings.psd1')
        }

        It 'generates the launcher into the server ContentRoot only, with the client AppId filled in' {
            $config = New-TestSteamConfig -Root $root -ClientAppId 1000 -ClientDepotId 1001 -ServerAppId 2000 -ServerDepotId 2001 -ServerLauncher $launcherText
            $result = Publish-OgSteamBuild -ConfigPath $config -NoUpload
            $server = $result.Depots | Where-Object Name -EQ 'server-win64'
            $client = $result.Depots | Where-Object Name -EQ 'client-win64'
            foreach ($name in $launcherFiles) {
                Join-Path $server.ContentRoot $name | Should -Exist
                Join-Path $client.ContentRoot $name | Should -Not -Exist
            }
            $client.ServerLauncher | Should -BeNullOrEmpty
            $server.ServerLauncher.Script | Should -Be (Join-Path $server.ContentRoot 'host_server.ps1')
            $settings = Import-PowerShellDataFile -LiteralPath (Join-Path $server.ContentRoot 'host_server.settings.psd1')
            $settings.ServerExecutable | Should -BeExactly 'GameServer.exe'
            $settings.ServerArguments | Should -BeExactly '/Game/Maps/Arena'
            $settings.ClientLaunch | Should -BeExactly 'steam://rungameid/1000'
            $settings.LocalHint | Should -BeExactly 'Tab adds a player.'
            Join-Path $server.ContentRoot 'build_info.txt' | Should -Exist
        }

        It 'warns and writes a skip reason when the client AppId is a placeholder' {
            $config = New-TestSteamConfig -Root $root -ServerLauncher $launcherText
            $result = Publish-OgSteamBuild -ConfigPath $config -NoUpload -WarningVariable warnings -WarningAction SilentlyContinue
            $server = $result.Depots | Where-Object Name -EQ 'server-win64'
            $server.ServerLauncher.ClientLaunchSkipReason | Should -BeExactly "the Steam app 'client' has no AppId yet (placeholder 0)"
            ($warnings | Out-String) | Should -Match "depot 'server-win64' will not start the game"
        }

        It 'regenerates the launcher on -SkipPackage' {
            $config = New-TestSteamConfig -Root $root -ServerLauncher $launcherText
            $first = Publish-OgSteamBuild -ConfigPath $config -NoUpload -WarningAction SilentlyContinue
            $script = ($first.Depots | Where-Object Name -EQ 'server-win64').ServerLauncher.Script
            Remove-Item -LiteralPath $script
            $again = Publish-OgSteamBuild -ConfigPath $config -NoUpload -SkipPackage -BuildLabel $first.BuildLabel -WarningAction SilentlyContinue
            $script | Should -Exist
            ($again.Depots | Where-Object Name -EQ 'server-win64').ServerLauncher.Script | Should -Be $script
            Should -Invoke -ModuleName og-framework -CommandName Invoke-OgUnrealPackage -Times 2 -Exactly
        }

        It 'rejects FileExclusions <Pattern> on the launcher depot before git or packaging' -TestCases @(
            @{ Pattern = '*.bat' }
            @{ Pattern = '*.ps1' }
            @{ Pattern = 'host_server.*' }
        ) {
            $config = New-TestSteamConfig -Root $root -ServerLauncher $launcherText -ServerFileExclusions "@('*.pdb', '$Pattern')"
            { Publish-OgSteamBuild -ConfigPath $config -NoUpload } | Should -Throw "*FileExclusions pattern '$Pattern' of depot 'server-win64' matches*"
            Should -Invoke -ModuleName og-framework -CommandName Invoke-Git -Times 0 -Exactly
            Should -Invoke -ModuleName og-framework -CommandName Invoke-OgUnrealPackage -Times 0 -Exactly
        }

        It 'accepts *.bat on a depot without a launcher' {
            $config = New-TestSteamConfig -Root $root -ServerFileExclusions "@('*.pdb', '*.ps1')"
            { Publish-OgSteamBuild -ConfigPath $config -NoUpload } | Should -Not -Throw
        }

        It 'rejects an ExtraFiles Destination that would overwrite host_server.ps1' {
            $config = New-TestSteamConfig -Root $root -ServerLauncher $launcherText -ServerExtraDestination 'host_server.ps1'
            { Publish-OgSteamBuild -ConfigPath $config -NoUpload } | Should -Throw "*ExtraFiles Destination 'host_server.ps1' of depot 'server-win64' is reserved*"
            Should -Invoke -ModuleName og-framework -CommandName Invoke-OgUnrealPackage -Times 0 -Exactly
        }
    }

    Context 'Pruning' {
        BeforeEach {
            $script:oldLabels = @(
                '20250101-000000-1111111', '20250102-000000-2222222-dirty', '20250103-000000-3333333',
                '20250104-000000-4444444', '20250105-000000-5555555'
            )
            foreach ($l in $oldLabels) { New-Item -ItemType Directory -Path (Join-Path $outputRoot $l) -Force | Out-Null }
            New-Item -ItemType Directory -Path (Join-Path $outputRoot 'notes') -Force | Out-Null
        }

        It 'keeps the newest KeepLast labels and never touches non-label folders' {
            $config = New-TestSteamConfig -Root $root -KeepLast 3
            $result = Publish-OgSteamBuild -ConfigPath $config -NoUpload
            $left = @(Get-ChildItem -LiteralPath $outputRoot -Directory | ForEach-Object Name | Sort-Object)
            $left | Should -Be (@('20250104-000000-4444444', '20250105-000000-5555555', $result.BuildLabel, 'notes') | Sort-Object)
        }

        It 'never prunes the current build, even when it is older than the newest KeepLast' {
            $config = New-TestSteamConfig -Root $root -KeepLast 1
            $current = '20250101-000000-1111111'
            foreach ($d in 'client-win64\WindowsClient', 'server-win64\WindowsServer') {
                New-Item -ItemType Directory -Path (Join-Path $outputRoot "$current\$d") -Force | Out-Null
            }
            Set-Content -LiteralPath (Join-Path $outputRoot "$current\client-win64\WindowsClient\GameClient.exe") -Value 'x'
            Set-Content -LiteralPath (Join-Path $outputRoot "$current\server-win64\WindowsServer\GameServer.exe") -Value 'x'

            Publish-OgSteamBuild -ConfigPath $config -NoUpload -SkipPackage -BuildLabel $current | Out-Null

            $left = @(Get-ChildItem -LiteralPath $outputRoot -Directory | ForEach-Object Name | Sort-Object)
            $left | Should -Be @($current, '20250105-000000-5555555', 'notes')
        }
    }
}

Describe 'og-framework module surface for Steam publishing' {
    It 'exports <Name>' -TestCases @(
        @{ Name = 'Publish-OgSteamBuild' }, @{ Name = 'Invoke-OgUnrealPackage' }, @{ Name = 'Install-OgSteamCmd' }
    ) {
        (Get-Command -Module og-framework -Name $Name).CommandType | Should -Be 'Function'
    }

    It 'exports the alias ogsteampublish for Publish-OgSteamBuild' {
        $alias = Get-Command -Module og-framework -Name ogsteampublish
        $alias.CommandType | Should -Be 'Alias'
        $alias.ResolvedCommandName | Should -Be 'Publish-OgSteamBuild'
    }

    It 'keeps the private helpers private' {
        Get-Command -Module og-framework -Name Import-OgSteamConfig, New-OgSteamBuildVdf, Resolve-OgSteamCmd, Invoke-OgProcess -ErrorAction SilentlyContinue |
            Should -BeNullOrEmpty
    }

    It 'documents every parameter in Get-Help' {
        $help = Get-Help Publish-OgSteamBuild -Full
        $documented = @($help.parameters.parameter | Where-Object { $_.description } | ForEach-Object Name)
        foreach ($p in 'ConfigPath', 'Branch', 'Description', 'NoUpload', 'Preview', 'AllowDirty', 'SkipPackage', 'BuildLabel', 'SteamCmdPath') {
            $documented | Should -Contain $p
        }
    }
}
