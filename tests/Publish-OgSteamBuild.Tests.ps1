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

    Context 'Schema version 2: builds, destinations and profiles' {
        BeforeAll {
            function New-TestV2SteamConfig {
                param(
                    [string] $Root,
                    [int] $GameAppId = 0,
                    [int] $GameClientDepotId = 0,
                    [int] $GameServerDepotId = 0,
                    [int] $ToolAppId = 0,
                    [int] $ToolServerDepotId = 0,
                    [string] $BuilderAccount = '',
                    [string] $ServerLauncher = '',
                    [switch] $NoProfiles
                )
                New-Item -ItemType Directory -Path (Join-Path $Root 'project\tools\steam') -Force | Out-Null
                Set-Content -LiteralPath (Join-Path $Root 'project\Game.uproject') -Value '{}'
                Set-Content -LiteralPath (Join-Path $Root 'project\tools\server template.bat') -Value '@echo server'
                $profiles = if ($NoProfiles) { '' } else {
                    @'
    Profiles = @{
        Default         = 'playtest'
        'playtest'      = @('game-client', 'game-server')
        'playtest-tool' = @('game-client', 'game-server', 'tool-server')
        'game-only'     = @('game-client')
        'release'       = @('game-client', 'tool-server')
    }
'@
                }
                $configPath = Join-Path $Root 'project\tools\steam\steam-publish.psd1'
                Set-Content -LiteralPath $configPath -Value @"
@{
    SchemaVersion  = 2
    ProjectFile    = '..\..\Game.uproject'
    Platform       = 'Win64'
    BuilderAccount = '$BuilderAccount'
    Branch         = 'playtest'
    OutputRoot     = '..\..\Saved\Steam\Builds'
    KeepLast       = 3
    Builds = @(
        @{
            Name               = 'client'
            TargetType         = 'Client'
            Configuration      = 'Shipping'
            ExpectedExecutable = 'GameClient.exe'
            FileExclusions     = @('*.pdb', 'Manifest_*.txt')
        }
        @{
            Name               = 'server'
            TargetType         = 'Server'
            Configuration      = 'Shipping'
            ExpectedExecutable = 'GameServer.exe'
            FileExclusions     = @('*.pdb', 'HostLogs\*')
            ExtraFiles         = @(@{ Source = '..\server template.bat'; Destination = 'run_server.bat' })
            $ServerLauncher
        }
    )
    Apps = @(
        @{
            Name   = 'game'
            AppId  = $GameAppId
            Depots = @(
                @{ Name = 'game-client'; DepotId = $GameClientDepotId; Build = 'client' }
                @{ Name = 'game-server'; DepotId = $GameServerDepotId; Build = 'server'; DepotPath = 'Server' }
            )
        }
        @{
            Name   = 'server-tool'
            AppId  = $ToolAppId
            Depots = @(
                @{ Name = 'tool-server'; DepotId = $ToolServerDepotId; Build = 'server' }
            )
        }
    )
$profiles
}
"@
                $configPath
            }

            function New-TestV2ReadyConfig {
                param([string] $Root, [int] $ToolAppId = 2000, [int] $ToolServerDepotId = 2001, [int] $GameServerDepotId = 1002)
                New-TestV2SteamConfig -Root $Root -GameAppId 1000 -GameClientDepotId 1001 -GameServerDepotId $GameServerDepotId `
                    -ToolAppId $ToolAppId -ToolServerDepotId $ToolServerDepotId -BuilderAccount 'builder'
            }

            function ConvertTo-TestGolden {
                param([Parameter(Mandatory)][string] $Text)
                ($Text -replace "`r`n", "`n").Replace('|', "`t").TrimEnd("`n") + "`n"
            }

            function ConvertTo-TestVdfLiteral {
                param([Parameter(Mandatory)][string] $Value)
                $Value.Replace('\', '\\').Replace('"', '\"')
            }

            function Get-TestUtf8Text {
                param([Parameter(Mandatory)][string] $Path)
                [System.IO.File]::ReadAllText($Path, [System.Text.UTF8Encoding]::new($false))
            }
        }

        It 'packages a build that two selected depots use exactly once, into the label folder under the build name' {
            $config = New-TestV2SteamConfig -Root $root
            $result = Publish-OgSteamBuild -ConfigPath $config -Profile playtest-tool -NoUpload
            $buildDir = Join-Path $outputRoot $result.BuildLabel
            Should -Invoke -ModuleName og-framework -CommandName Invoke-OgUnrealPackage -Times 2 -Exactly
            Should -Invoke -ModuleName og-framework -CommandName Invoke-OgUnrealPackage -Times 1 -Exactly -ParameterFilter {
                $TargetType -eq 'Server' -and $Configuration -eq 'Shipping' -and
                $ArchiveDirectory -eq (Join-Path $buildDir 'server') -and $ExpectedExecutable -eq 'GameServer.exe'
            }
            Should -Invoke -ModuleName og-framework -CommandName Invoke-OgUnrealPackage -Times 1 -Exactly -ParameterFilter {
                $TargetType -eq 'Client' -and $ArchiveDirectory -eq (Join-Path $buildDir 'client')
            }
            $callLog | Should -Be @('git status', 'git rev-parse', 'package Client', 'package Server')
            @(Get-ChildItem -LiteralPath $buildDir -Directory | ForEach-Object Name | Sort-Object) | Should -Be @('_steam', 'client', 'server')
        }

        It 'uses the default profile when neither -Profile nor -Depots is passed' {
            $config = New-TestV2SteamConfig -Root $root
            $result = Publish-OgSteamBuild -ConfigPath $config -NoUpload
            $result.Profile | Should -BeExactly 'playtest'
            @($result.Destinations | ForEach-Object Depot) | Should -Be @('game-client', 'game-server')
            @($result.AppVdfs | ForEach-Object AppName) | Should -Be @('game')
            Test-Path -LiteralPath (Join-Path $result.BuildDirectory '_steam\server-tool') | Should -BeFalse
            Should -Invoke -ModuleName og-framework -CommandName Invoke-OgUnrealPackage -Times 2 -Exactly
        }

        It 'uploads every depot of a version 2 config without Profiles' {
            $config = New-TestV2SteamConfig -Root $root -NoProfiles
            $result = Publish-OgSteamBuild -ConfigPath $config -NoUpload
            $result.Profile | Should -BeExactly ''
            @($result.Destinations | ForEach-Object Depot) | Should -Be @('game-client', 'game-server', 'tool-server')
            Should -Invoke -ModuleName og-framework -CommandName Invoke-OgUnrealPackage -Times 2 -Exactly
        }

        It 'packages only the builds of the selected depots (-Depots, case-insensitive)' {
            $config = New-TestV2SteamConfig -Root $root
            $result = Publish-OgSteamBuild -ConfigPath $config -Depots 'Game-Client' -AllowPartialApp -NoUpload
            $result.Profile | Should -BeExactly ''
            Should -Invoke -ModuleName og-framework -CommandName Invoke-OgUnrealPackage -Times 1 -Exactly -ParameterFilter { $TargetType -eq 'Client' }
            Should -Invoke -ModuleName og-framework -CommandName Invoke-OgUnrealPackage -Times 1 -Exactly
            @($result.Depots | ForEach-Object Name) | Should -Be @('game-client')
            Test-Path -LiteralPath (Join-Path $result.BuildDirectory 'server') | Should -BeFalse
            @(Get-ChildItem -LiteralPath (Join-Path $result.BuildDirectory '_steam\game') -File | ForEach-Object Name | Sort-Object) |
                Should -Be @('app_build_0.vdf', 'depot_build_0.vdf')
        }

        It 'reports one Destination per selected depot, sharing the build label, ContentRoot and sizes of its build' {
            $config = New-TestV2SteamConfig -Root $root
            $result = Publish-OgSteamBuild -ConfigPath $config -Profile playtest-tool -NoUpload
            $result.Destinations.Count | Should -Be 3
            foreach ($d in $result.Destinations) {
                @($d.PSObject.Properties.Name) | Should -Be @('App', 'Depot', 'Build', 'DepotPath', 'UploadBytes')
            }
            @($result.Destinations | ForEach-Object { "$($_.App)/$($_.Depot)/$($_.Build)/$($_.DepotPath)" }) |
                Should -Be @('game/game-client/client/.', 'game/game-server/server/Server', 'server-tool/tool-server/server/.')
            $gameServer = $result.Depots | Where-Object Name -EQ 'game-server'
            $toolServer = $result.Depots | Where-Object Name -EQ 'tool-server'
            $toolServer.ContentRoot | Should -Be $gameServer.ContentRoot
            $gameServer.ContentRoot | Should -Be (Join-Path $result.BuildDirectory 'server\WindowsServer')
            $toolServer.BuildInfoPath | Should -Be $gameServer.BuildInfoPath
            $gameServer.UploadBytes | Should -Be ($gameServer.SizeBytes - 10)
            @($result.Destinations | Where-Object Build -EQ 'server' | ForEach-Object UploadBytes) | Should -Be @($gameServer.UploadBytes, $gameServer.UploadBytes)
            $found = @(Get-ChildItem -LiteralPath $result.BuildDirectory -Recurse -File -Filter 'build_info.txt')
            $found.Count | Should -Be 2
            foreach ($file in $found) { (Get-Content -LiteralPath $file.FullName)[0] | Should -BeExactly "label=$($result.BuildLabel)" }
        }

        It 'writes the golden VDFs for two apps and three depots, with DepotPath "Server" on the bundled server only' {
            $config = New-TestV2ReadyConfig -Root $root
            $result = Publish-OgSteamBuild -ConfigPath $config -Profile playtest-tool -NoUpload
            $steamDir = Join-Path $result.BuildDirectory '_steam'
            $clientRoot = ConvertTo-TestVdfLiteral (Join-Path $result.BuildDirectory 'client\WindowsClient')
            $serverRoot = ConvertTo-TestVdfLiteral (Join-Path $result.BuildDirectory 'server\WindowsServer')
            $output = ConvertTo-TestVdfLiteral (Join-Path $steamDir 'output')
            $label = $result.BuildLabel

            @($result.AppVdfs | ForEach-Object Path) | Should -Be @((Join-Path $steamDir 'game\app_build_1000.vdf'), (Join-Path $steamDir 'server-tool\app_build_2000.vdf'))
            @(Get-ChildItem -LiteralPath $steamDir -Recurse -File | ForEach-Object { $_.FullName.Substring($steamDir.Length + 1) } | Sort-Object) |
                Should -Be @('game\app_build_1000.vdf', 'game\depot_build_1001.vdf', 'game\depot_build_1002.vdf', 'server-tool\app_build_2000.vdf', 'server-tool\depot_build_2001.vdf')

            Get-TestUtf8Text (Join-Path $steamDir 'game\app_build_1000.vdf') | Should -BeExactly (ConvertTo-TestGolden @"
"AppBuild"
{
|"AppID"|"1000"
|"Desc"|"$label"
|"BuildOutput"|"$output"
|"ContentRoot"|""
|"SetLive"|"playtest"
|"Preview"|"0"
|"Depots"
|{
||"1001"|"$(ConvertTo-TestVdfLiteral (Join-Path $steamDir 'game\depot_build_1001.vdf'))"
||"1002"|"$(ConvertTo-TestVdfLiteral (Join-Path $steamDir 'game\depot_build_1002.vdf'))"
|}
}
"@)
            Get-TestUtf8Text (Join-Path $steamDir 'game\depot_build_1001.vdf') | Should -BeExactly (ConvertTo-TestGolden @"
"DepotBuild"
{
|"DepotID"|"1001"
|"ContentRoot"|"$clientRoot"
|"FileMapping"
|{
||"LocalPath"|"*"
||"DepotPath"|"."
||"recursive"|"1"
|}
|"FileExclusion"|"*.pdb"
|"FileExclusion"|"Manifest_*.txt"
}
"@)
            Get-TestUtf8Text (Join-Path $steamDir 'game\depot_build_1002.vdf') | Should -BeExactly (ConvertTo-TestGolden @"
"DepotBuild"
{
|"DepotID"|"1002"
|"ContentRoot"|"$serverRoot"
|"FileMapping"
|{
||"LocalPath"|"*"
||"DepotPath"|"Server"
||"recursive"|"1"
|}
|"FileExclusion"|"*.pdb"
|"FileExclusion"|"HostLogs\\*"
}
"@)
            Get-TestUtf8Text (Join-Path $steamDir 'server-tool\app_build_2000.vdf') | Should -BeExactly (ConvertTo-TestGolden @"
"AppBuild"
{
|"AppID"|"2000"
|"Desc"|"$label"
|"BuildOutput"|"$output"
|"ContentRoot"|""
|"SetLive"|"playtest"
|"Preview"|"0"
|"Depots"
|{
||"2001"|"$(ConvertTo-TestVdfLiteral (Join-Path $steamDir 'server-tool\depot_build_2001.vdf'))"
|}
}
"@)
            Get-TestUtf8Text (Join-Path $steamDir 'server-tool\depot_build_2001.vdf') | Should -BeExactly (ConvertTo-TestGolden @"
"DepotBuild"
{
|"DepotID"|"2001"
|"ContentRoot"|"$serverRoot"
|"FileMapping"
|{
||"LocalPath"|"*"
||"DepotPath"|"."
||"recursive"|"1"
|}
|"FileExclusion"|"*.pdb"
|"FileExclusion"|"HostLogs\\*"
}
"@)
        }

        It 'names the depot VDFs of a placeholder dry run after the depots' {
            $config = New-TestV2SteamConfig -Root $root
            $result = Publish-OgSteamBuild -ConfigPath $config -NoUpload
            $gameDir = Join-Path $result.BuildDirectory '_steam\game'
            @(Get-ChildItem -LiteralPath $gameDir -File | ForEach-Object Name | Sort-Object) |
                Should -Be @('app_build_0.vdf', 'depot_build_0_game-client.vdf', 'depot_build_0_game-server.vdf')
            Get-TestUtf8Text (Join-Path $gameDir 'depot_build_0_game-server.vdf') | Should -Match '"DepotPath"\t"Server"'
            Get-TestUtf8Text (Join-Path $gameDir 'depot_build_0_game-client.vdf') | Should -Match '"DepotPath"\t"\."'
        }

        It 'S6: stops <Name> before git and packaging, naming the left-out depot, with <Mode>' -TestCases @(
            @{ Name = 'game-only'; Mode = '-NoUpload'; Ready = $false; Extra = @{ Profile = 'game-only'; NoUpload = $true } }
            @{ Name = 'game-only'; Mode = '-Preview'; Ready = $true; Extra = @{ Profile = 'game-only'; Preview = $true } }
            @{ Name = 'release'; Mode = '-NoUpload'; Ready = $false; Extra = @{ Profile = 'release'; NoUpload = $true } }
            @{ Name = '-Depots game-server'; Mode = 'an upload'; Ready = $true; Extra = @{ Depots = @('game-server') } }
        ) {
            $config = if ($Ready) { New-TestV2ReadyConfig -Root $root } else { New-TestV2SteamConfig -Root $root }
            $extra = $Extra
            $err = { Publish-OgSteamBuild -ConfigPath $config @extra } | Should -Throw -PassThru
            $err.Exception.Message | Should -BeLike "*app 'game' leaves out '*'*"
            $err.Exception.Message | Should -BeLike '*not documented*-AllowPartialApp*'
            Should -Invoke -ModuleName og-framework -CommandName Invoke-Git -Times 0 -Exactly
            Should -Invoke -ModuleName og-framework -CommandName Invoke-OgUnrealPackage -Times 0 -Exactly
            Should -Invoke -ModuleName og-framework -CommandName Resolve-OgSteamCmd -Times 0 -Exactly
        }

        It 'S6: names exactly the depots the run leaves out' {
            $config = New-TestV2SteamConfig -Root $root
            { Publish-OgSteamBuild -ConfigPath $config -Profile game-only -NoUpload } |
                Should -Throw "*only some depots of an app: app 'game' leaves out 'game-server'. What Steam*"
            { Publish-OgSteamBuild -ConfigPath $config -Profile release -NoUpload } |
                Should -Throw "*only some depots of an app: app 'game' leaves out 'game-server'. What Steam*"
        }

        It 'S6: lets <Name> through with -AllowPartialApp' -TestCases @(
            @{ Name = 'game-only'; Builds = 1 }
            @{ Name = 'release'; Builds = 2 }
        ) {
            $config = New-TestV2SteamConfig -Root $root
            $result = Publish-OgSteamBuild -ConfigPath $config -Profile $Name -AllowPartialApp -NoUpload
            $result.Profile | Should -BeExactly $Name
            Should -Invoke -ModuleName og-framework -CommandName Invoke-OgUnrealPackage -Times $Builds -Exactly
        }

        It 'S6: does not apply to an app whose every depot is selected' {
            $config = New-TestV2SteamConfig -Root $root
            $result = Publish-OgSteamBuild -ConfigPath $config -Depots tool-server -NoUpload
            @($result.Destinations | ForEach-Object Depot) | Should -Be @('tool-server')
            @($result.AppVdfs | ForEach-Object AppName) | Should -Be @('server-tool')
        }

        It 'S2: an unselected app with placeholder IDs does not block an upload' {
            $config = New-TestV2ReadyConfig -Root $root -ToolAppId 0 -ToolServerDepotId 0
            $result = Publish-OgSteamBuild -ConfigPath $config -Profile playtest
            $result.Uploaded | Should -BeTrue
            Should -Invoke -ModuleName og-framework -CommandName Invoke-OgProcess -Times 1 -Exactly -ParameterFilter {
                $ArgumentList[3] -eq (Join-Path $result.BuildDirectory '_steam\game\app_build_1000.vdf')
            }
            Should -Invoke -ModuleName og-framework -CommandName Invoke-OgProcess -Times 1 -Exactly
        }

        It 'S2: a selected depot with the placeholder DepotId blocks the upload before git or packaging' {
            $config = New-TestV2ReadyConfig -Root $root -ToolAppId 0 -ToolServerDepotId 0 -GameServerDepotId 0
            $err = { Publish-OgSteamBuild -ConfigPath $config -Profile playtest } | Should -Throw -PassThru
            $err.Exception.Message | Should -BeLike "*Depot 'game-server': DepotId is the placeholder 0*"
            $err.Exception.Message | Should -Not -BeLike '*tool-server*'
            $err.Exception.Message | Should -Not -BeLike '*server-tool*'
            Should -Invoke -ModuleName og-framework -CommandName Invoke-Git -Times 0 -Exactly
            Should -Invoke -ModuleName og-framework -CommandName Invoke-OgUnrealPackage -Times 0 -Exactly
            Should -Invoke -ModuleName og-framework -CommandName Invoke-OgProcess -Times 0 -Exactly
        }

        It 'S2: a selected app with the placeholder AppId blocks the upload' {
            $config = New-TestV2ReadyConfig -Root $root -ToolAppId 0
            { Publish-OgSteamBuild -ConfigPath $config -Profile playtest-tool } | Should -Throw "*App 'server-tool': AppId is the placeholder 0*"
            Should -Invoke -ModuleName og-framework -CommandName Invoke-OgUnrealPackage -Times 0 -Exactly
        }

        It 'passes the selected depots to the readiness check' {
            Mock -ModuleName og-framework -CommandName Assert-OgSteamUploadReady -MockWith { }
            $config = New-TestV2ReadyConfig -Root $root
            Publish-OgSteamBuild -ConfigPath $config -Profile playtest | Out-Null
            Should -Invoke -ModuleName og-framework -CommandName Assert-OgSteamUploadReady -Times 1 -Exactly -ParameterFilter {
                (@($DepotNames | Sort-Object) -join ',') -eq 'game-client,game-server'
            }
        }

        It 'runs steamcmd once per app with a selected depot' {
            $config = New-TestV2ReadyConfig -Root $root
            $result = Publish-OgSteamBuild -ConfigPath $config -Profile playtest-tool
            Should -Invoke -ModuleName og-framework -CommandName Invoke-OgProcess -Times 2 -Exactly
            foreach ($appVdf in $result.AppVdfs) {
                $vdfPath = $appVdf.Path
                Should -Invoke -ModuleName og-framework -CommandName Invoke-OgProcess -Times 1 -Exactly -ParameterFilter {
                    ($ArgumentList -join ' ') -ceq "+login builder +run_app_build $vdfPath +quit"
                }
            }
        }

        It 'rejects <Case> before git' -TestCases @(
            @{ Case = '-Profile together with -Depots'; Extra = @{ Profile = 'playtest'; Depots = @('game-client') }; Message = '*-Profile and -Depots cannot be combined*' }
            @{ Case = 'an unknown profile'; Extra = @{ Profile = 'nightly' }; Message = "*unknown profile 'nightly'. Profiles of *: game-only, playtest, playtest-tool, release*" }
            @{ Case = 'an unknown depot'; Extra = @{ Depots = @('game-client', 'tool-servr') }; Message = "*-Depots names unknown depot 'tool-servr'. Depots of *: game-client, game-server, tool-server*" }
        ) {
            $config = New-TestV2SteamConfig -Root $root
            $extra = $Extra
            { Publish-OgSteamBuild -ConfigPath $config -NoUpload @extra } | Should -Throw $Message
            Should -Invoke -ModuleName og-framework -CommandName Invoke-Git -Times 0 -Exactly
        }

        It 'reuses the build-name folders of a label with -SkipPackage for another profile' {
            $config = New-TestV2SteamConfig -Root $root
            $first = Publish-OgSteamBuild -ConfigPath $config -Profile playtest-tool -NoUpload
            Remove-Item -LiteralPath (Join-Path $first.BuildDirectory '_steam') -Recurse -Force
            $again = Publish-OgSteamBuild -ConfigPath $config -Profile release -AllowPartialApp -NoUpload -SkipPackage -BuildLabel $first.BuildLabel
            Should -Invoke -ModuleName og-framework -CommandName Invoke-OgUnrealPackage -Times 2 -Exactly
            $again.BuildLabel | Should -Be $first.BuildLabel
            @($again.Destinations | ForEach-Object Depot) | Should -Be @('game-client', 'tool-server')
            ($again.Depots | Where-Object Name -EQ 'tool-server').ContentRoot | Should -Be ($first.Depots | Where-Object Name -EQ 'tool-server').ContentRoot
            @($again.AppVdfs | ForEach-Object AppName) | Should -Be @('game', 'server-tool')
        }

        It 'throws on -SkipPackage when a selected build is missing from the label' {
            $config = New-TestV2SteamConfig -Root $root
            $first = Publish-OgSteamBuild -ConfigPath $config -Depots game-client -AllowPartialApp -NoUpload
            { Publish-OgSteamBuild -ConfigPath $config -NoUpload -SkipPackage -BuildLabel $first.BuildLabel } |
                Should -Throw "*build 'server' of build label '$($first.BuildLabel)' does not exist*"
        }

        It 'generates the launcher once into the shared server build, with the ClientLaunch list' {
            $launcher = "ServerLauncher = @{ Title = 'Game server'; Port = 7777; " +
                "JoinLinePattern = 'S: (?:(?<joined>joined)|(?<left>left)) players=(?<players>\d+)'; " +
                "ClientLaunch = @('..\GameClient.exe', 'steam://rungameid/{AppId:game}') }"
            $config = New-TestV2SteamConfig -Root $root -GameAppId 1000 -ServerLauncher $launcher
            $result = Publish-OgSteamBuild -ConfigPath $config -Profile playtest-tool -NoUpload
            $gameServer = $result.Depots | Where-Object Name -EQ 'game-server'
            $toolServer = $result.Depots | Where-Object Name -EQ 'tool-server'
            [object]::ReferenceEquals($gameServer.ServerLauncher, $toolServer.ServerLauncher) | Should -BeTrue
            $gameServer.ServerLauncher.ClientLaunch | Should -Be @('..\GameClient.exe', 'steam://rungameid/1000')
            $settings = Import-PowerShellDataFile -LiteralPath (Join-Path $gameServer.ContentRoot 'host_server.settings.psd1')
            $settings.ClientLaunch | Should -Be @('..\GameClient.exe', 'steam://rungameid/1000')
            Join-Path ($result.Depots | Where-Object Name -EQ 'game-client').ContentRoot 'host_server.ps1' | Should -Not -Exist
        }

        It 'names the build in an early FileExclusions rejection' {
            $config = New-TestV2SteamConfig -Root $root
            (Get-Content -Raw -LiteralPath $config).Replace("FileExclusions     = @('*.pdb', 'HostLogs\*')", "FileExclusions     = @('*.pdb', '*.txt')") |
                Set-Content -LiteralPath $config
            { Publish-OgSteamBuild -ConfigPath $config -NoUpload } | Should -Throw "*pattern '``*.txt' of build 'server' matches 'build_info.txt'*"
        }
    }

    Context 'Schema version 1 configs keep their behaviour' {
        It 'selects every depot, reports Profile '''' and one Destination per depot' {
            $config = New-TestSteamConfig -Root $root
            $result = Publish-OgSteamBuild -ConfigPath $config -NoUpload
            $result.Profile | Should -BeExactly ''
            @($result.Destinations | ForEach-Object { "$($_.App)/$($_.Depot)/$($_.Build)/$($_.DepotPath)" }) |
                Should -Be @('client/client-win64/client-win64/.', 'server/server-win64/server-win64/.')
            ($result.Destinations | Where-Object Depot -EQ 'server-win64').UploadBytes | Should -Be ($result.Depots | Where-Object Name -EQ 'server-win64').UploadBytes
        }

        It 'accepts -Depots on a version 1 config' {
            $config = New-TestSteamConfig -Root $root
            $result = Publish-OgSteamBuild -ConfigPath $config -Depots server-win64 -NoUpload
            Should -Invoke -ModuleName og-framework -CommandName Invoke-OgUnrealPackage -Times 1 -Exactly -ParameterFilter { $TargetType -eq 'Server' }
            Should -Invoke -ModuleName og-framework -CommandName Invoke-OgUnrealPackage -Times 1 -Exactly
            @($result.AppVdfs | ForEach-Object AppName) | Should -Be @('server')
        }

        It 'rejects -Profile on a config without Profiles' {
            $config = New-TestSteamConfig -Root $root
            { Publish-OgSteamBuild -ConfigPath $config -Profile playtest -NoUpload } | Should -Throw "*-Profile 'playtest' was passed, but * defines no Profiles*"
            Should -Invoke -ModuleName og-framework -CommandName Invoke-OgUnrealPackage -Times 0 -Exactly
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
        foreach ($p in 'ConfigPath', 'Profile', 'Depots', 'AllowPartialApp', 'Branch', 'Description', 'NoUpload', 'Preview', 'AllowDirty', 'SkipPackage', 'BuildLabel', 'SteamCmdPath') {
            $documented | Should -Contain $p
        }
    }
}
