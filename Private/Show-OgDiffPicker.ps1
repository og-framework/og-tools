# SPDX-License-Identifier: MPL-2.0
#
# The commit picker behind `oggitdiff -Pick` (design D6): a console list of the project root's recent
# commits on the first-parent line of HEAD, each with the og repos it touched. The parts:
#
#   Get-OgPickerRows           the row list builder (read-only `git log --first-parent`).
#   New-OgPickerModel          rows + the injected touch resolver (+ summary formatter, title).
#   Resolve-OgPickerRowTouch   fills one row's Touched/Entries through the resolver.
#   Get-OgPickerPendingIndex   which visible row to resolve next (lazy: visible rows only).
#   Format-OgPickerScreen      the PURE renderer: plain-text lines for a size and a state.
#   Get-OgPickerScrollTop      the PURE viewport rule (keeps the selection visible at both edges).
#   Select-OgPickerRow         the key loop; every console access goes through a one-line seam below.
#   Get-OgPickerChoice         the PURE choice rule: a key (Enter, h, w), the selection and the mark ->
#                              an Og.PickerChoice (one commit, a range, or a commit vs the working tree).
#   Invoke-OgDiffPicker        the dry-run entry point: lists, picks, returns the choice, opens nothing.
#
# Ranges (od task 11a, R5): Space marks the selected row as one end of a range (one mark at a time); Enter
# on another row then chooses the range between the two, the LOWER row (the older commit: the list is
# newest first) as its base. `h` chooses selected..HEAD and `w` selected..the working tree. The picker only
# CHOOSES: Show-OgDiff routes the Og.PickerChoice to -Commit or the range path.
#
# The picker never calls the commit-range resolver itself: the caller injects it as a scriptblock
# (`-TouchResolver { param($sha) ... }`, returning Og.CommitRangeEntry objects). Rows are resolved
# lazily, only while they are visible, and each sha at most once: the row itself is the cache (a row is
# pending only while its Touched is $null, and a sha occurs once in a first-parent list).
#
# Console contract: the picker draws on the terminal's ALTERNATE screen buffer (VT sequences), so the
# user's screen and scrollback come back untouched when it closes, and it restores the cursor and the
# colours in a `finally`, so an exception or Ctrl+C never leaves a hidden cursor or an inverse-video
# prompt behind.

function Invoke-OgDiffPicker {
    <#
    .SYNOPSIS
        Dry-run entry point of the commit picker: shows the root's recent first-parent commits in the
        console, lets the user choose one commit or a range, and returns the choice. Opens no diff and
        launches nothing.

    .DESCRIPTION
        Lists the last -Count commits on the first-parent line of HEAD in -ProjectRoot (Get-OgPickerRows),
        then runs the key loop (Select-OgPickerRow):
          Up/Down, PgUp/PgDn, Home/End   move the selection
          Space                          marks the selected row as one end of a range ('*'), or clears
                                         the mark when the selected row is the marked one
          Enter                          no mark: the selected commit (Kind Commit); with a mark: the range
                                         between the marked and the selected row, the older (lower) row as
                                         its base (Kind Range); on the marked row itself: nothing happens
          h                              selected..HEAD (Kind Range, To 'HEAD')
          w                              selected..the working tree (Kind WorkingTree)
          Esc or q                       returns nothing
        The returned Og.PickerChoice is described under OUTPUTS (Get-OgPickerChoice builds it).
        The touched-repo column and the detail line come from -TouchResolver, called lazily for the
        visible rows only and at most once per commit. Without a resolver they show an ellipsis.

        Needs an interactive console: with redirected input or output, or a host without virtual
        terminal support, it throws an error that names `oggitdiff -Commit <sha>` instead, before it
        runs any git command.

        It is private (not exported). Run it through the module:
            & (Get-Module og-framework) { Invoke-OgDiffPicker -ProjectRoot C:\dev\og-brawler-unreal }

    .PARAMETER ProjectRoot
        The og project root. Defaults to the current location.

    .PARAMETER Count
        How many commits to list (default 30).

    .PARAMETER TouchResolver
        Scriptblock `param($sha)` returning the repos a root commit touched, as Og.CommitRangeEntry
        objects (Repo, Path, WorkingDirectory, BaseRev, HeadRev, Status, Error). Optional.
        It runs inside the picker's own call chain, so a caller variable it names is looked up dynamically
        and is SHADOWED by a picker variable of the same name (e.g. $ProjectRoot, $Count, $rows, $row):
        copy what it needs into a distinctly named variable (e.g. $pickRoot) before building it.

    .PARAMETER TouchSummary
        Scriptblock `param($entries)` returning the short text of the touched-repo column. Optional;
        defaults to Format-OgPickerTouchSummary ('root +3').

    .OUTPUTS
        Og.PickerChoice (Kind, Commit, From, To, WorkingTree, Sha, Row; see Get-OgPickerChoice), or nothing
        on cancel.

    .EXAMPLE
        & (Get-Module og-framework) {
            Invoke-OgDiffPicker -ProjectRoot C:\dev\og-brawler-unreal -TouchResolver {
                param($sha)
                [PSCustomObject]@{ Repo = 'root'; Path = ''; BaseRev = "$sha"; HeadRev = "$sha"; Status = 'changed' }
            }
        }
        # A trivial resolver until the real one is wired in: every commit shows 'root'.
        # Mark a row with Space, move to another and press Enter: the result is
        # Kind Range, From <the older row's sha>, To <the newer row's sha>.
    #>
    [CmdletBinding()]
    param(
        [string] $ProjectRoot = (Get-Location).Path,

        [ValidateRange(1, 10000)]
        [int] $Count = 30,

        [scriptblock] $TouchResolver,

        [scriptblock] $TouchSummary
    )

    $ProjectRoot = (Resolve-Path -LiteralPath $ProjectRoot).ProviderPath

    # Fail before any git work: a redirected console can never answer the picker.
    Assert-OgPickerInteractive

    $rows  = Get-OgPickerRows -ProjectRoot $ProjectRoot -Count $Count
    $model = New-OgPickerModel -Rows $rows -TouchResolver $TouchResolver -TouchSummary $TouchSummary `
        -Title (Split-Path -Path $ProjectRoot -Leaf)
    Select-OgPickerRow -Model $model
}

function Get-OgPickerRows {
    <#
    .SYNOPSIS
        The picker's row list builder: the last -Count commits on the first-parent line of HEAD in
        -ProjectRoot, newest first, one Og.PickerRow each (Touched still unresolved).

    .DESCRIPTION
        Read-only: one `git log --first-parent` in the project root, nothing else. First parent only,
        because every oggitcommit run ends in ONE root commit on the branch it runs on; a merged side
        branch's own commits are not runs of this branch and would only bury them.

        Each row: Sha (full id), ShortSha (git's %h), Date (author date, LOCAL time, 'yyyy-MM-dd HH:mm'),
        Subject, and Touched/Entries/TouchError, which stay $null until Resolve-OgPickerRowTouch fills
        them. Throws when HEAD has no commit (an unborn branch) or the folder is not a repo.

    .PARAMETER ProjectRoot
        The og project root (a git working tree).

    .PARAMETER Count
        The maximum number of rows (default 30).

    .OUTPUTS
        Og.PickerRow objects, newest first.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $ProjectRoot,

        [ValidateRange(1, 10000)]
        [int] $Count = 30
    )

    # Invoke-OgGitPlumbing, not Invoke-Git: it decodes stdout as UTF-8 (Invoke-Git uses the console code
    # page, which mangles a non-ASCII subject) and does not trim it.
    # --encoding=UTF-8 so an i18n.logOutputEncoding setting cannot re-encode the subjects;
    # --no-show-signature so a log.showSignature setting cannot put gpg lines into the records.
    # -z ends each record with NUL; the fields are split on the unit separator (%x1f), which a subject
    # cannot contain in a way that matters here (%s is a single line).
    $result = Invoke-OgGitPlumbing -WorkingDirectory $ProjectRoot -Arguments @(
        'log', '--first-parent', '--no-show-signature', '--encoding=UTF-8', '-z',
        "--max-count=$Count", '--format=%H%x1f%h%x1f%at%x1f%s', 'HEAD', '--'
    )
    if ($result.ExitCode -ne 0) {
        throw "Cannot list the commits of HEAD in '$ProjectRoot': $($result.StdErr)"
    }

    foreach ($record in $result.StdOut.Split([char] 0, [System.StringSplitOptions]::RemoveEmptyEntries)) {
        $fields = $record.Split([char] 0x1f, 4)
        if ($fields.Count -lt 4) { continue }
        $local = [System.DateTimeOffset]::FromUnixTimeSeconds([long] $fields[2]).LocalDateTime
        [PSCustomObject]@{
            PSTypeName = 'Og.PickerRow'
            Sha        = $fields[0]
            ShortSha   = $fields[1]
            Date       = $local.ToString('yyyy-MM-dd HH:mm', [System.Globalization.CultureInfo]::InvariantCulture)
            Subject    = $fields[3]
            Touched    = $null
            Entries    = $null
            TouchError = $null
        }
    }
}

function New-OgPickerModel {
    <#
    .SYNOPSIS
        Bundles the picker's rows with the injected touch resolver, the optional summary formatter and the
        header title.

    .PARAMETER Rows
        Og.PickerRow objects (Get-OgPickerRows). The rows are updated in place as they are resolved.

    .PARAMETER TouchResolver
        Scriptblock `param($sha)` returning Og.CommitRangeEntry objects, or $null (nothing is resolved).

    .PARAMETER TouchSummary
        Scriptblock `param($entries)` returning the touched-column text, or $null for
        Format-OgPickerTouchSummary.

    .PARAMETER Title
        Shown in the header line (the project folder's name).

    .OUTPUTS
        Og.PickerModel (Rows, Title, TouchResolver, TouchSummary).
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()]
        [object[]] $Rows = @(),

        [scriptblock] $TouchResolver,

        [scriptblock] $TouchSummary,

        [string] $Title = ''
    )

    [PSCustomObject]@{
        PSTypeName    = 'Og.PickerModel'
        Rows          = @($Rows)
        Title         = $Title
        TouchResolver = $TouchResolver
        TouchSummary  = $TouchSummary
    }
}

function Resolve-OgPickerRowTouch {
    <#
    .SYNOPSIS
        Fills one row's Touched (summary text), Entries and TouchError through the model's resolver.

    .DESCRIPTION
        Never throws for a resolver failure: the picker must stay usable when one commit cannot be
        resolved. A throwing resolver, or one that writes an error record, gives Touched '!' (when it
        returned no entry) and TouchError with the message. Touched is never left $null here, so the row is
        no longer pending (Get-OgPickerPendingIndex) and is never resolved again, a broken commit included:
        it is not retried on every keypress.

        The resolver's warning, verbose, debug and information streams are discarded: the screen belongs
        to the picker, and anything printed would scribble over the frame. Without a resolver this does
        nothing (the row stays unresolved).

    .PARAMETER Model
        Og.PickerModel (New-OgPickerModel).

    .PARAMETER Index
        The row's index in Model.Rows.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Model,
        [Parameter(Mandatory)] [int] $Index
    )

    if ($null -eq $Model.TouchResolver) { return }
    $row = $Model.Rows[$Index]
    if ($null -ne $row.Touched) { return }

    $entries = @()
    $errorText = $null
    try {
        $output   = @(& $Model.TouchResolver $row.Sha 2>&1 3>$null 4>$null 5>$null 6>$null)
        $errors   = @($output | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] })
        $entries  = @($output | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] })
        if ($errors.Count -gt 0) { $errorText = $errors[0].ToString() }
    } catch {
        $errorText = $_.Exception.Message
    }

    $summary = $null
    if ($null -ne $errorText -and $entries.Count -eq 0) {
        $summary = '!'
    } else {
        try {
            $summary = if ($null -ne $Model.TouchSummary) { [string] (& $Model.TouchSummary $entries) }
                       else { Format-OgPickerTouchSummary -Entries $entries }
        } catch {
            $summary = '!'
            if ($null -eq $errorText) { $errorText = $_.Exception.Message }
        }
        if ([string]::IsNullOrEmpty($summary)) { $summary = '-' }
    }

    $row.Entries    = $entries
    $row.TouchError = $errorText
    $row.Touched    = $summary
}

function Get-OgPickerPendingIndex {
    <#
    .SYNOPSIS
        The next visible row that still needs its touched repos resolved, or -1.

    .DESCRIPTION
        The selected row comes first (its repos fill the detail line), then the visible rows top to bottom.
        Rows outside the viewport are never pending: resolving is lazy, so a 30-row list on a 10-line
        window resolves 10 commits, not 30. Always -1 without a resolver.

    .PARAMETER Model
        Og.PickerModel.

    .PARAMETER Selected
        The selected row's index.

    .PARAMETER Top
        The first visible row's index.

    .PARAMETER ViewportHeight
        How many rows are visible.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Model,
        [Parameter(Mandatory)] [int] $Selected,
        [Parameter(Mandatory)] [int] $Top,
        [Parameter(Mandatory)] [int] $ViewportHeight
    )

    if ($null -eq $Model.TouchResolver) { return -1 }
    $rows = $Model.Rows
    if ($Selected -ge 0 -and $Selected -lt $rows.Count -and $null -eq $rows[$Selected].Touched) { return $Selected }
    $last = [Math]::Min($rows.Count, $Top + $ViewportHeight) - 1
    for ($i = [Math]::Max(0, $Top); $i -le $last; $i++) {
        if ($null -eq $rows[$i].Touched) { return $i }
    }
    -1
}

function Format-OgPickerTouchSummary {
    <#
    .SYNOPSIS
        The default touched-column text for a commit's entries: the first repo's name plus how many more
        ('root +3'), '-' for none, prefixed with '!' when any repo is missing-commit.

    .PARAMETER Entries
        Og.CommitRangeEntry objects (Repo, Status, ...).
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]] $Entries
    )

    $list = @($Entries | Where-Object { $null -ne $_ })
    if ($list.Count -eq 0) { return '-' }
    $first = if ([string]::IsNullOrEmpty([string] $list[0].Repo)) { '?' } else { [string] $list[0].Repo }
    $text  = if ($list.Count -gt 1) { "$first +$($list.Count - 1)" } else { $first }
    if (@($list | Where-Object { $_.Status -eq 'missing-commit' }).Count -gt 0) { $text = "!$text" }
    $text
}

function Format-OgPickerDetail {
    <#
    .SYNOPSIS
        The detail line's text for a row: every touched repo with its range, e.g.
        'repos: root 1a2b3c4..5d6e7f8, og-sim 0000000..89abcde (added), lib (missing-commit)'.

    .DESCRIPTION
        An empty side (an added or removed submodule) is shown as git's null id 0000000. An unresolved
        row shows the ellipsis, a failed one 'cannot resolve: <message>'.

    .PARAMETER Row
        Og.PickerRow.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Row
    )

    $ellipsis = [string] [char] 0x2026
    if ($null -eq $Row.Touched) { return "repos: $ellipsis" }
    $entries = @($Row.Entries | Where-Object { $null -ne $_ })
    $parts = foreach ($entry in $entries) {
        $name = if ([string]::IsNullOrEmpty([string] $entry.Repo)) { '?' } else { [string] $entry.Repo }
        if ($entry.Status -eq 'missing-commit') { "$name (missing-commit)"; continue }
        $range = '{0}..{1}' -f (Get-OgPickerShortRev $entry.BaseRev), (Get-OgPickerShortRev $entry.HeadRev)
        $status = [string] $entry.Status
        if ($status -and $status -ne 'changed') { "$name $range ($status)" } else { "$name $range" }
    }

    $text = if (@($parts).Count -gt 0) { 'repos: ' + (@($parts) -join ', ') } else { 'repos: none touched' }
    if ($Row.TouchError) { $text += "; cannot resolve: $($Row.TouchError)" }
    $text
}

function Get-OgPickerShortRev {
    <#
    .SYNOPSIS
        The first 7 characters of a commit id; git's null id 0000000 for an empty side ('' or $null).

    .PARAMETER Rev
        A full commit id, or '' / $null for an empty side.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Rev
    )

    if ([string]::IsNullOrEmpty($Rev)) { return '0000000' }
    if ($Rev.Length -le 7) { return $Rev }
    $Rev.Substring(0, 7)
}

function ConvertTo-OgPickerFitted {
    <#
    .SYNOPSIS
        Fits text into a width: control characters become spaces, and text that is too long is cut and
        ends in an ellipsis, so the result is never longer than -Width.

    .DESCRIPTION
        Control characters are replaced, not kept, because a commit subject is untrusted text: a tab would
        shift every column after it, and an ESC would be executed by the terminal as an escape sequence.

    .PARAMETER Text
        The text.

    .PARAMETER Width
        The maximum length (0 or less gives '').
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Text,

        [Parameter(Mandatory, Position = 1)]
        [int] $Width
    )

    if ($Width -le 0) { return '' }
    $clean = ([string] $Text) -replace '\p{Cc}', ' '
    if ($clean.Length -le $Width) { return $clean }
    $clean.Substring(0, $Width - 1) + [char] 0x2026
}

function Get-OgPickerLayout {
    <#
    .SYNOPSIS
        Which chrome lines fit a window height, and how many list rows remain (the viewport).

    .DESCRIPTION
        A full screen is: a header line, the viewport, the detail line, the help footer. A very short window
        drops the footer first, then the header, then the detail line; the viewport always has at least one
        row. The renderer and the key loop both use this, so the selection's line and the scrolling agree.

    .PARAMETER Height
        The window height in lines.

    .OUTPUTS
        PSCustomObject: Header, Detail, Footer (booleans), ViewportHeight, RowOffset (the first row's line).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [int] $Height
    )

    $footer = $Height -ge 4
    $header = $Height -ge 3
    $detail = $Height -ge 2
    $chrome = [int] $footer + [int] $header + [int] $detail
    [PSCustomObject]@{
        Header         = $header
        Detail         = $detail
        Footer         = $footer
        ViewportHeight = [Math]::Max(1, $Height - $chrome)
        RowOffset      = [int] $header
    }
}

function Get-OgPickerScrollTop {
    <#
    .SYNOPSIS
        The viewport's first row for a selection: scrolls only when the selection would leave the viewport,
        by exactly as much as needed, at the top and at the bottom edge.

    .DESCRIPTION
        The selection is visible when Top <= Selected <= Top + ViewportHeight - 1. Moving past the bottom
        edge puts the selection on the LAST visible line (Top = Selected - ViewportHeight + 1), past the top
        edge on the first (Top = Selected). The result is then clamped to 0..(Count - ViewportHeight), so a
        window that grows never shows blank lines below the last row while rows above are hidden.

    .PARAMETER Selected
        The selected row's index.

    .PARAMETER Top
        The current first visible row's index.

    .PARAMETER ViewportHeight
        How many rows fit.

    .PARAMETER Count
        How many rows there are.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [int] $Selected,
        [Parameter(Mandatory)] [int] $Top,
        [Parameter(Mandatory)] [int] $ViewportHeight,
        [Parameter(Mandatory)] [int] $Count
    )

    $height = [Math]::Max(1, $ViewportHeight)
    if ($Selected -lt $Top) {
        $Top = $Selected
    } elseif ($Selected -ge $Top + $height) {
        $Top = $Selected - $height + 1
    }
    $maxTop = [Math]::Max(0, $Count - $height)
    [Math]::Min([Math]::Max(0, $Top), $maxTop)
}

function Format-OgPickerScreen {
    <#
    .SYNOPSIS
        The PURE renderer: the picker's screen as plain-text lines, no colour or escape codes.

    .DESCRIPTION
        Returns exactly -Height lines (at least one), none longer than -Width:
          header    'Pick a commit: <title>  (<selected>/<count>)', plus '  base: <short sha>' while a row
                    is marked (the base Enter would use: the OLDER of the marked and the selected row)
          rows      '><sha>  <date>  <touched>  <subject>' where the first two characters are the marker
                    columns: '>' (or ' ') for the selected row, then '*' (or ' ') for the marked row; an
                    unresolved touched column shows an ellipsis; the line is cut to the width with an
                    ellipsis, so it is the subject (the last column) that gets truncated
          (blank)   below the last row when the list is shorter than the viewport
          detail    the selected row's repos and ranges (Format-OgPickerDetail), whatever is marked
          footer    the keys (Get-OgPickerFooter)
        The rows shown are Top .. Top + viewport - 1; the caller keeps Top consistent with the selection
        (Get-OgPickerScrollTop). The colours (the selected row in inverse video) are added only by the
        drawing seam, so the output of this function compares as plain text.

    .PARAMETER Rows
        Og.PickerRow objects.

    .PARAMETER Selected
        The selected row's index.

    .PARAMETER Top
        The first visible row's index.

    .PARAMETER Width
        The usable width in characters.

    .PARAMETER Height
        The window height in lines.

    .PARAMETER Title
        The header's title (the project folder's name).

    .PARAMETER Marked
        The marked row's index, or -1 (the default) when no row is marked.
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()]
        [object[]] $Rows = @(),

        [Parameter(Mandatory)] [int] $Selected,
        [Parameter(Mandatory)] [int] $Top,
        [Parameter(Mandatory)] [int] $Width,
        [Parameter(Mandatory)] [int] $Height,

        [string] $Title = '',

        [int] $Marked = -1
    )

    $layout   = Get-OgPickerLayout -Height $Height
    $ellipsis = [string] [char] 0x2026
    $touchWidth = 12
    $shaWidth = 7
    foreach ($row in $Rows) { $shaWidth = [Math]::Max($shaWidth, ([string] $row.ShortSha).Length) }

    $hasMark = $Marked -ge 0 -and $Marked -lt $Rows.Count
    $lines = [System.Collections.Generic.List[string]]::new()
    if ($layout.Header) {
        $header = "Pick a commit: $Title  ($($Selected + 1)/$($Rows.Count))"
        if ($hasMark) {
            # The base Enter WOULD use, not simply the marked row: when the selection moves below the mark
            # (to an older commit), the selected row becomes the base and the marked row the head, and a
            # header that kept naming the mark would announce the wrong base.
            $baseIndex = if ($Selected -ge 0 -and $Selected -lt $Rows.Count) { [Math]::Max($Marked, $Selected) } else { $Marked }
            $header += "  base: $([string] $Rows[$baseIndex].ShortSha)"
        }
        $lines.Add((ConvertTo-OgPickerFitted $header $Width))
    }
    for ($i = $Top; $i -lt $Top + $layout.ViewportHeight; $i++) {
        if ($i -lt 0 -or $i -ge $Rows.Count) { $lines.Add(''); continue }
        $row     = $Rows[$i]
        # Two one-character marker columns, selection then mark, in the two characters the selection marker
        # '> ' always took. Keep them two wide: the touched column's offset (29) is pinned by the 5a and 5b
        # tests and read by the -Pick tests in Show-OgDiff.Tests.ps1; a third column would shift every column.
        $marker  = $(if ($i -eq $Selected) { '>' } else { ' ' }) + $(if ($i -eq $Marked) { '*' } else { ' ' })
        $touched = if ($null -eq $row.Touched) { $ellipsis } else { [string] $row.Touched }
        $touched = (ConvertTo-OgPickerFitted $touched $touchWidth).PadRight($touchWidth)
        $line    = $marker + ([string] $row.ShortSha).PadRight($shaWidth) + '  ' + $row.Date + '  ' + $touched + '  ' + $row.Subject
        $lines.Add((ConvertTo-OgPickerFitted $line $Width))
    }
    if ($layout.Detail) {
        $detail = if ($Selected -ge 0 -and $Selected -lt $Rows.Count) { Format-OgPickerDetail -Row $Rows[$Selected] } else { '' }
        $lines.Add((ConvertTo-OgPickerFitted ('  ' + $detail) $Width))
    }
    if ($layout.Footer) {
        $lines.Add((Get-OgPickerFooter -Width $Width))
    }
    $lines.ToArray()
}

function Get-OgPickerFooter {
    <#
    .SYNOPSIS
        The footer line: the keys, in full when they fit the width, else in a compact form, cut with an
        ellipsis only when even that does not fit.

    .DESCRIPTION
        Full:    'Space: mark  Enter: open  h: vs HEAD  w: vs working tree  Esc/q: cancel' (71 characters)
        Compact: 'Space:mark Enter:open h:HEAD w:worktree Esc/q:cancel' (52 characters)
        The move keys (arrows, PgUp/PgDn, Home/End) are not listed: they do what they say, and the five
        keys above would not fit an 80-column window next to them.

    .PARAMETER Width
        The usable width in characters.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [int] $Width
    )

    $full    = 'Space: mark  Enter: open  h: vs HEAD  w: vs working tree  Esc/q: cancel'
    $compact = 'Space:mark Enter:open h:HEAD w:worktree Esc/q:cancel'
    if ($full.Length -le $Width) { return $full }
    ConvertTo-OgPickerFitted $compact $Width
}

function Format-OgPickerFrame {
    <#
    .SYNOPSIS
        Turns the renderer's plain lines into ONE string of VT sequences that redraws the screen in place:
        each line at its own absolute position, cleared to the end of the line, the selected line in
        inverse video, the rest of the screen cleared below.

    .DESCRIPTION
        Absolute positioning (ESC[<n>;1H) instead of newlines: a newline after the window's last line would
        scroll the screen by one and every later frame would draw one line too high. One string per frame,
        written with one call, so the terminal never shows a half-drawn frame.

    .PARAMETER Lines
        The renderer's lines.

    .PARAMETER Highlight
        The index in -Lines of the selected row's line, or -1.

    .PARAMETER Width
        The usable width; the highlighted line is padded to it so the inverse bar spans the row.
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()]
        [string[]] $Lines = @(),

        [int] $Highlight = -1,

        [int] $Width = 0
    )

    $esc = [char] 27
    $sb = [System.Text.StringBuilder]::new()
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        [void] $sb.Append("$esc[$($i + 1);1H")
        if ($i -eq $Highlight) {
            [void] $sb.Append("$esc[7m").Append($Lines[$i].PadRight($Width)).Append("$esc[27m")
        } else {
            [void] $sb.Append($Lines[$i])
        }
        [void] $sb.Append("$esc[K")
    }
    [void] $sb.Append("$esc[0m$esc[J")
    $sb.ToString()
}

function Get-OgPickerKeyAction {
    <#
    .SYNOPSIS
        Maps a key to a picker action: Up, Down, PageUp, PageDown, Home, End, Pick (Enter), Cancel (Esc, q),
        Mark (Space), VsHead (h), VsWorkingTree (w) or None (any other key).

    .DESCRIPTION
        The letters are matched on the typed character, either case, like q: a Caps Lock left on must
        not turn h into an ignored key.

    .PARAMETER Key
        The pressed key.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.ConsoleKeyInfo] $Key
    )

    switch ($Key.Key) {
        ([System.ConsoleKey]::UpArrow)   { return 'Up' }
        ([System.ConsoleKey]::DownArrow) { return 'Down' }
        ([System.ConsoleKey]::PageUp)    { return 'PageUp' }
        ([System.ConsoleKey]::PageDown)  { return 'PageDown' }
        ([System.ConsoleKey]::Home)      { return 'Home' }
        ([System.ConsoleKey]::End)       { return 'End' }
        ([System.ConsoleKey]::Enter)     { return 'Pick' }
        ([System.ConsoleKey]::Escape)    { return 'Cancel' }
        ([System.ConsoleKey]::Spacebar)  { return 'Mark' }
    }
    # -eq on [char] is case-sensitive, hence both cases spelled out.
    if ($Key.KeyChar -eq [char] 'q' -or $Key.KeyChar -eq [char] 'Q') { return 'Cancel' }
    if ($Key.KeyChar -eq [char] 'h' -or $Key.KeyChar -eq [char] 'H') { return 'VsHead' }
    if ($Key.KeyChar -eq [char] 'w' -or $Key.KeyChar -eq [char] 'W') { return 'VsWorkingTree' }
    'None'
}

function Get-OgPickerChoice {
    <#
    .SYNOPSIS
        The PURE choice rule: what an Enter, h or w key chooses for a selection and a mark, as an
        Og.PickerChoice, or nothing when the key does nothing (Enter on the marked row itself).

    .DESCRIPTION
        Rows are newest first, so a LOWER row (a higher index) is an OLDER commit.
          Pick (Enter), no mark          Kind Commit: Commit = the selected row's sha
          Pick (Enter), a mark           Kind Range: From = the older of the marked and the selected row,
                                         To = the newer one, whichever of the two was marked
          Pick on the marked row         nothing (a range from a commit to itself is empty)
          VsHead (h)                     Kind Range: From = the selected row, To = 'HEAD' (the literal
                                         revision; the mark is ignored)
          VsWorkingTree (w)              Kind WorkingTree: From = the selected row, WorkingTree = $true
                                         (the mark is ignored)
        Every other action gives nothing.

        Every choice carries: Kind; Commit (full sha, Kind Commit only, else $null); From and To (full
        shas, To 'HEAD' for h, To $null for WorkingTree; both $null for Commit); WorkingTree (bool); Row
        (the Og.PickerRow the key was pressed on); and Sha (= Commit, $null for the other kinds).

        Sha exists for the single-commit caller from od task 5b: Show-OgDiff -Pick reads `$picked.Sha`,
        and on a Commit choice it is exactly the picked row's Sha, as when the picker returned the row.
        Do not drop it before Show-OgDiff routes on Kind (od task 11b), and never fill it for a Range or
        WorkingTree choice: a non-null Sha there would send a range down the single-commit path.

    .PARAMETER Rows
        Og.PickerRow objects, newest first.

    .PARAMETER Action
        The key's action (Get-OgPickerKeyAction).

    .PARAMETER Selected
        The selected row's index.

    .PARAMETER Marked
        The marked row's index, or -1 (the default) when no row is marked.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $Rows,

        [Parameter(Mandatory)] [string] $Action,
        [Parameter(Mandatory)] [int] $Selected,

        [int] $Marked = -1
    )

    if ($Selected -lt 0 -or $Selected -ge $Rows.Count) { return }
    $row     = $Rows[$Selected]
    $hasMark = $Marked -ge 0 -and $Marked -lt $Rows.Count

    $kind = $null; $commit = $null; $from = $null; $to = $null
    switch ($Action) {
        'Pick' {
            if (-not $hasMark) {
                $kind = 'Commit'; $commit = [string] $row.Sha
            } elseif ($Marked -ne $Selected) {
                # The higher index is the older commit and therefore the base, regardless of which end was
                # marked first: marking the newer row and moving down must give the same range as the reverse.
                $kind = 'Range'
                $from = [string] $Rows[[Math]::Max($Marked, $Selected)].Sha
                $to   = [string] $Rows[[Math]::Min($Marked, $Selected)].Sha
            }
        }
        'VsHead'        { $kind = 'Range'; $from = [string] $row.Sha; $to = 'HEAD' }
        'VsWorkingTree' { $kind = 'WorkingTree'; $from = [string] $row.Sha }
    }
    if ($null -eq $kind) { return }

    [PSCustomObject]@{
        PSTypeName  = 'Og.PickerChoice'
        Kind        = $kind
        Commit      = $commit
        From        = $from
        To          = $to
        WorkingTree = $kind -eq 'WorkingTree'
        Sha         = $commit
        Row         = $row
    }
}

function Get-OgPickerNextSelection {
    <#
    .SYNOPSIS
        The selection after a move action, clamped to the list (no wrap-around): Up/Down by one,
        PageUp/PageDown by one viewport, Home/End to the first/last row.

    .PARAMETER Action
        The action (Get-OgPickerKeyAction). Pick, Cancel and None leave the selection as it is.

    .PARAMETER Selected
        The selected row's index.

    .PARAMETER ViewportHeight
        How many rows fit (the page size).

    .PARAMETER Count
        How many rows there are.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Action,
        [Parameter(Mandatory)] [int] $Selected,
        [Parameter(Mandatory)] [int] $ViewportHeight,
        [Parameter(Mandatory)] [int] $Count
    )

    $page = [Math]::Max(1, $ViewportHeight)
    $next = switch ($Action) {
        'Up'       { $Selected - 1 }
        'Down'     { $Selected + 1 }
        'PageUp'   { $Selected - $page }
        'PageDown' { $Selected + $page }
        'Home'     { 0 }
        'End'      { $Count - 1 }
        default    { $Selected }
    }
    [Math]::Max(0, [Math]::Min($next, $Count - 1))
}

function Select-OgPickerRow {
    <#
    .SYNOPSIS
        The picker's key loop: draws the model, moves the selection on Up/Down, PgUp/PgDn, Home/End, keeps
        a mark on Space, and returns an Og.PickerChoice on Enter, h or w, or nothing on Esc or q.

    .DESCRIPTION
        Space marks the selected row, moves the mark there from another row (one mark at a time), or clears
        it when pressed on the marked row. Enter, h and w end the loop with Get-OgPickerChoice's choice;
        Enter on the marked row chooses nothing and the loop goes on (the screen stays as it is).

        Each turn of the loop re-reads the window size (a resize between two keys redraws at the new size,
        with the selection kept visible), renders, draws, and then EITHER resolves one more visible row
        (when no key is waiting) OR reads one key. So the rows appear with an ellipsis first and fill in
        one by one, and a key pressed meanwhile is answered at once.

        Every console access is a one-line seam, so Pester drives the loop with a key list:
          Get-OgPickerConsoleCapability   redirected input/output, VT support
          Enter-OgPickerScreen / Exit-OgPickerScreen   alternate screen, cursor
          Get-OgPickerWindowSize   Write-OgPickerScreen   Test-OgPickerKeyAvailable   Read-OgPickerKey
        Exit-OgPickerScreen runs in `finally`: the cursor and the colours come back after Enter, Esc, an
        exception or Ctrl+C alike. Nothing is written to the pipeline inside the loop: the choice is
        emitted only after the screen is restored, so it (and anything downstream) lands on the user's screen.

    .PARAMETER Model
        Og.PickerModel (New-OgPickerModel).

    .OUTPUTS
        Og.PickerChoice (Get-OgPickerChoice), or nothing (cancelled, or no rows).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Model
    )

    Assert-OgPickerInteractive

    $rows  = $Model.Rows
    $count = $rows.Count
    if ($count -eq 0) { return }

    $selected = 0
    $top      = 0
    $marked   = -1
    $picked   = $null
    $screen   = Enter-OgPickerScreen
    try {
        while ($true) {
            $size   = Get-OgPickerWindowSize
            # One column less than the window: writing the last column makes some terminals wrap the
            # cursor to the next line, which scrolls the bottom line off the screen.
            $width  = [Math]::Max(1, $size.Width - 1)
            $height = [Math]::Max(1, $size.Height)
            $layout = Get-OgPickerLayout -Height $height
            $top    = Get-OgPickerScrollTop -Selected $selected -Top $top -ViewportHeight $layout.ViewportHeight -Count $count

            $lines = @(Format-OgPickerScreen -Rows $rows -Selected $selected -Top $top -Width $width -Height $height `
                -Title $Model.Title -Marked $marked)
            Write-OgPickerScreen -Lines $lines -Highlight ($layout.RowOffset + $selected - $top) -Width $width

            $pending = Get-OgPickerPendingIndex -Model $Model -Selected $selected -Top $top -ViewportHeight $layout.ViewportHeight
            if ($pending -ge 0 -and -not (Test-OgPickerKeyAvailable)) {
                Resolve-OgPickerRowTouch -Model $Model -Index $pending
                continue
            }

            $action = Get-OgPickerKeyAction -Key (Read-OgPickerKey)
            if ($action -eq 'Cancel') { break }
            if ($action -eq 'Mark') {
                $marked = if ($marked -eq $selected) { -1 } else { $selected }
                continue
            }
            if ($action -in 'Pick', 'VsHead', 'VsWorkingTree') {
                # Kept in $picked and emitted after the finally (see below). No choice (Enter on the marked
                # row) is a no-op: the loop simply goes on.
                $picked = Get-OgPickerChoice -Rows $rows -Action $action -Selected $selected -Marked $marked
                if ($null -ne $picked) { break }
                continue
            }
            $selected = Get-OgPickerNextSelection -Action $action -Selected $selected `
                -ViewportHeight $layout.ViewportHeight -Count $count
        }
    } finally {
        Exit-OgPickerScreen -State $screen
    }

    # Emit the choice only HERE, after the finally. Never `return $choice` inside the try: PowerShell writes a
    # returned object downstream at once and runs the finally afterwards, so Out-Default would print it onto the
    # alternate screen (which the exit then discards) and a downstream command would run on that screen too.
    if ($null -ne $picked) { $picked }
}

function Assert-OgPickerInteractive {
    <#
    .SYNOPSIS
        Throws a clear error, naming `oggitdiff -Commit <sha>`, when the console cannot run the picker:
        redirected input (no keys to read), redirected output (the frames would land in a file or pipe), or
        a host without virtual-terminal support (the frames are VT sequences).
    #>
    [CmdletBinding()]
    param()

    $cap = Get-OgPickerConsoleCapability
    $why = if ($cap.InputRedirected) { 'its input is redirected' }
           elseif ($cap.OutputRedirected) { 'its output is redirected' }
           elseif (-not $cap.VirtualTerminal) { 'this host does not support virtual terminal sequences' }
    if ($why) {
        throw "The commit picker needs an interactive console, but $why. Name the commit instead: oggitdiff -Commit <sha>"
    }
}

function Get-OgPickerConsoleCapability {
    <#
    .SYNOPSIS
        Console seam: whether input and output are redirected and whether the host supports VT sequences.
    #>
    [CmdletBinding()]
    param()

    [PSCustomObject]@{
        InputRedirected  = [Console]::IsInputRedirected
        OutputRedirected = [Console]::IsOutputRedirected
        VirtualTerminal  = [bool] $Host.UI.SupportsVirtualTerminal
    }
}

function Enter-OgPickerScreen {
    <#
    .SYNOPSIS
        Console seam: switches to the alternate screen buffer and hides the cursor; returns the state that
        Exit-OgPickerScreen restores.

    .DESCRIPTION
        The cursor's visibility is read before it is hidden, so Exit-OgPickerScreen restores what the user
        had rather than forcing it visible. Reading it is Windows-only in .NET; elsewhere it counts as
        visible.
    #>
    [CmdletBinding()]
    param()

    $state = [PSCustomObject]@{ CursorVisible = $true }
    try { $state.CursorVisible = [Console]::CursorVisible } catch { $state.CursorVisible = $true }
    [Console]::Write("$([char] 27)[?1049h")
    try { [Console]::CursorVisible = $false } catch { Write-Verbose "Cannot hide the cursor: $($_.Exception.Message)" }
    $state
}

function Exit-OgPickerScreen {
    <#
    .SYNOPSIS
        Console seam: resets the colours, leaves the alternate screen buffer (the user's screen comes back)
        and restores the cursor's visibility.

    .PARAMETER State
        What Enter-OgPickerScreen returned.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $State
    )

    [Console]::Write("$([char] 27)[0m$([char] 27)[?1049l")
    try { [Console]::CursorVisible = [bool] $State.CursorVisible } catch { Write-Verbose "Cannot restore the cursor: $($_.Exception.Message)" }
}

function Get-OgPickerWindowSize {
    <#
    .SYNOPSIS
        Console seam: the window's current width and height; 80 x 24 when there is no console window.
    #>
    [CmdletBinding()]
    param()

    try {
        [PSCustomObject]@{ Width = [Console]::WindowWidth; Height = [Console]::WindowHeight }
    } catch {
        [PSCustomObject]@{ Width = 80; Height = 24 }
    }
}

function Write-OgPickerScreen {
    <#
    .SYNOPSIS
        Console seam: draws one frame, the renderer's plain lines with the selected line highlighted
        (Format-OgPickerFrame), in place.

    .PARAMETER Lines
        The renderer's lines.

    .PARAMETER Highlight
        The index in -Lines of the selected row's line.

    .PARAMETER Width
        The usable width.
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()] [string[]] $Lines = @(),
        [int] $Highlight = -1,
        [int] $Width = 0
    )

    [Console]::Write((Format-OgPickerFrame -Lines $Lines -Highlight $Highlight -Width $Width))
}

function Test-OgPickerKeyAvailable {
    <#
    .SYNOPSIS
        Console seam: whether a key press is waiting ([Console]::KeyAvailable).
    #>
    [CmdletBinding()]
    param()

    [Console]::KeyAvailable
}

function Read-OgPickerKey {
    <#
    .SYNOPSIS
        Key seam: reads one key press without echoing it ([Console]::ReadKey($true)).
    #>
    [CmdletBinding()]
    param()

    [Console]::ReadKey($true)
}
