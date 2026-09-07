#Requires -Version 5.1
<#
.SYNOPSIS
    Three-line Claude Code status line for Windows (PowerShell port of statusline.sh).

.DESCRIPTION
    Line 1  working directory (abbreviated) + git branch, dirty marker
    Line 2  account email, model id, reasoning effort, context window size
    Line 3  context usage bar, 5-hour limit, 7-day limit, each with a reset timer

    Reads the Claude Code session JSON from stdin. Every field is optional:
    rate_limits appears only for Pro/Max accounts and only after the first API
    response, and context_window is null early in a session and again after
    /compact.

.NOTES
    Ported from the bash/jq claude-statusline project (statusline.sh).
    Layout and env-var names follow Andrew Connell's status line:
    https://www.andrewconnell.com/articles/claude-code-cli-statusline/
    MIT licensed, same as the source project.

    Decorative glyphs are built from Unicode code points ([char]0x____) rather
    than typed as literal characters, so the script behaves the same whether
    this file ends up saved as UTF-8, UTF-8 with BOM, or Windows-1252 - only
    the comments would be affected by that, never the rendered status line.
    Output is written as raw UTF-8 bytes directly to the stdout handle for the
    same reason: it must look right regardless of the calling shell's active
    codepage. Needs a truecolor-capable terminal (Windows Terminal) for the
    24-bit ANSI colors.

.ENVIRONMENT
    CLAUDE_STATUSLINE_BAR=0        Hide the bars, show percentages only
    CLAUDE_STATUSLINE_BAR_WIDTH=N  Bar width in characters (default 10)
    CLAUDE_ACCOUNT_EMAIL=...       Skip the `claude auth status` lookup
#>

[System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::InvariantCulture
$ErrorActionPreference = 'SilentlyContinue'

# ---------- decorative glyphs (codepage-safe) ----------
$BLOCK_FULL  = [char]0x2588   # full block, bar "filled" cell
$BLOCK_LIGHT = [char]0x2591   # light shade, bar "empty" cell
$ELLIPSIS    = [char]0x2026   # elided-path marker
$VBAR        = [char]0x2502   # line-3 segment separator
$MIDDOT      = [char]0x00B7   # line-2 segment separator
$REFRESH     = [char]0x21BB   # reset-timer arrow

# ---------- read session JSON from stdin ----------
$rawInput = [Console]::In.ReadToEnd()
$data = $null
if (-not [string]::IsNullOrWhiteSpace($rawInput)) {
    try { $data = $rawInput | ConvertFrom-Json -ErrorAction Stop } catch { $data = $null }
}

# Path-aware field access, mirroring the bash script's g(p) helper: returns ''
# for missing/null values and for objects/arrays rather than a stringified blob.
function Get-Field {
    param([Parameter(Mandatory)][string[]]$Path)
    $cur = $data
    foreach ($p in $Path) {
        if ($null -eq $cur) { return '' }
        $prop = $cur.PSObject.Properties[$p]
        if ($null -eq $prop) { return '' }
        $cur = $prop.Value
    }
    if ($null -eq $cur) { return '' }
    if ($cur -is [System.Management.Automation.PSCustomObject]) { return '' }
    if (($cur -is [System.Collections.IEnumerable]) -and -not ($cur -is [string])) { return '' }
    return [string]$cur
}

$DIR = Get-Field workspace, current_dir
if ([string]::IsNullOrEmpty($DIR)) { $DIR = Get-Field cwd }
$MODEL = Get-Field model, id
if ([string]::IsNullOrEmpty($MODEL)) { $MODEL = Get-Field model, display_name }

$CW_PCT  = Get-Field context_window, used_percentage
$CW_IN   = Get-Field context_window, total_input_tokens
$CW_OUT  = Get-Field context_window, total_output_tokens
$CW_SIZE = Get-Field context_window, context_window_size
$R5_PCT  = Get-Field rate_limits, five_hour, used_percentage
$R5_AT   = Get-Field rate_limits, five_hour, resets_at
$R7_PCT  = Get-Field rate_limits, seven_day, used_percentage
$R7_AT   = Get-Field rate_limits, seven_day, resets_at
$EFFORT  = Get-Field effort, level

# ---------- colors ----------
$ESC   = [char]27
$RST   = "$ESC[0m"
$DIM   = "$ESC[2m"
$BOLD  = "$ESC[1m"
$CYAN  = "$ESC[38;2;90;180;220m"
$MAUVE = "$ESC[38;2;170;140;220m"
$GREY  = "$ESC[38;2;130;130;140m"

# Green -> yellow -> red across 0..100.
function Get-Grad {
    param([double]$P)
    if ($P -lt 0) { $P = 0 }
    if ($P -gt 100) { $P = 100 }
    if ($P -le 50) { $r = [int](60 + (180 * $P) / 50); $g = 200 }
    else            { $r = 235; $g = [int](200 - (165 * ($P - 50)) / 50) }
    return "$ESC[38;2;$r;$g;60m"
}

$BarWidth = 10
if ($env:CLAUDE_STATUSLINE_BAR_WIDTH) { $BarWidth = [int]$env:CLAUDE_STATUSLINE_BAR_WIDTH }

function Get-Bar {
    param([double]$P)
    if ($env:CLAUDE_STATUSLINE_BAR -eq '0') { return '' }
    if ($P -lt 0) { $P = 0 }
    if ($P -gt 100) { $P = 100 }
    $filled = [int](($P * $BarWidth + 50) / 100)
    return ([string]$BLOCK_FULL * $filled) + ([string]$BLOCK_LIGHT * ($BarWidth - $filled)) + ' '
}

# ---------- formatting helpers ----------
function ConvertTo-IntSafe {
    # Substitute on failure, never append (a stray parse artifact silently
    # turning "50" into "500" was a real bug in the bash version).
    param($Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return 0 }
    $d = 0.0
    $ok = [double]::TryParse(
        $Value,
        [System.Globalization.NumberStyles]::Float,
        [System.Globalization.CultureInfo]::InvariantCulture,
        [ref]$d)
    if ($ok) { return [int][math]::Round($d, [MidpointRounding]::AwayFromZero) }
    return 0
}

function Format-Tokens {
    param([long]$N)
    if ($N -ge 1000000) { return '{0}.{1}M' -f [math]::Floor($N / 1000000), [math]::Floor(($N % 1000000) / 100000) }
    if ($N -ge 1000)    { return '{0}.{1}k' -f [math]::Floor($N / 1000), [math]::Floor(($N % 1000) / 100) }
    return "$N"
}

function Get-Rel {
    # seconds-until, from a unix epoch timestamp
    param([long]$T)
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $d = $T - $now
    if ($d -le 0) { return 'now' }
    $h = [math]::Floor($d / 3600)
    $m = [math]::Floor(($d % 3600) / 60)
    if ($h -ge 24) { return '{0}d{1}h' -f [math]::Floor($h / 24), ($h % 24) }
    if ($h -gt 0)  { return "${h}h${m}m" }
    return "${m}m"
}

function Get-ShortDir {
    # Keep the last three path segments; elide the rest. Paths are normalized
    # to forward slashes for display, matching the original's ~/a/b/c look.
    param([string]$D)
    if ([string]::IsNullOrEmpty($D)) { return '?' }

    $homeNorm = ($HOME -replace '\\', '/').TrimEnd('/')
    $norm = $D -replace '\\', '/'

    if ($norm -eq $homeNorm) { return '~' }
    if ($norm.StartsWith("$homeNorm/", [StringComparison]::OrdinalIgnoreCase)) {
        $norm = '~/' + $norm.Substring($homeNorm.Length + 1)
    }

    $rest = $norm.TrimStart('/')
    if ($rest.StartsWith('~/')) { $rest = $rest.Substring(2) }

    $segments = $rest.Split('/') | Where-Object { $_ -ne '' }
    if ($segments.Count -ge 4) {
        $tail = $segments[($segments.Count - 3)..($segments.Count - 1)] -join '/'
        return "$ELLIPSIS/$tail"
    }
    return $norm
}

# ---------- account email (cached; refreshed in the background) ----------
$EMAIL = $env:CLAUDE_ACCOUNT_EMAIL
$claudeDir = Join-Path $HOME '.claude'
$cachePath = Join-Path $claudeDir '.statusline-email'

if ([string]::IsNullOrEmpty($EMAIL)) {
    if (Test-Path -LiteralPath $cachePath -PathType Leaf) {
        $cached = Get-Content -LiteralPath $cachePath -Raw -ErrorAction SilentlyContinue
        if ($cached) { $EMAIL = $cached.Trim() }
    }

    $ageSeconds = [double]::MaxValue
    if (Test-Path -LiteralPath $cachePath -PathType Leaf) {
        $ageSeconds = ((Get-Date).ToUniversalTime() - (Get-Item -LiteralPath $cachePath).LastWriteTimeUtc).TotalSeconds
    }

    if (($ageSeconds -gt 86400) -and (Get-Command claude -ErrorAction SilentlyContinue)) {
        # Never block the status line on this: refresh in a fully detached
        # process, use the stale value now. Mirrors the bash version's
        # `... & disown`.
        if (-not (Test-Path -LiteralPath $claudeDir)) {
            New-Item -ItemType Directory -Path $claudeDir -Force | Out-Null
        }
        $escapedCache = $cachePath.Replace("'", "''")
        $refreshScript = @"
try {
    `$out = & claude auth status 2>`$null
    if (`$out -match '"email"\s*:\s*"([^"]*)"') {
        Set-Content -LiteralPath '$escapedCache' -Value `$Matches[1] -NoNewline -Encoding UTF8
    }
} catch {}
"@
        $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($refreshScript))
        Start-Process -FilePath 'powershell' -WindowStyle Hidden `
            -ArgumentList @('-NoProfile', '-EncodedCommand', $encoded) | Out-Null
    }
}

# ---------- line 1: directory + branch ----------
$L1 = "$CYAN$BOLD$(Get-ShortDir $DIR)$RST"
if ($DIR -and (Get-Command git -ErrorAction SilentlyContinue)) {
    $branch = & git -C $DIR rev-parse --abbrev-ref HEAD 2>$null
    if ($LASTEXITCODE -eq 0 -and $branch) {
        $dirty = ''
        & git -C $DIR diff --quiet --ignore-submodules HEAD 2>$null
        if ($LASTEXITCODE -ne 0) { $dirty = '*' }
        $L1 += " ${GREY}on${RST} ${MAUVE}$branch$dirty${RST}"
    }
}

# ---------- line 2: account, model, window size ----------
$l2Parts = New-Object System.Collections.Generic.List[string]
if ($EMAIL)   { $l2Parts.Add("${GREY}${EMAIL}${RST}") }
if ($MODEL)   { $l2Parts.Add("${MAUVE}${MODEL}${RST}") }
# effort is absent for models without the reasoning-effort parameter
if ($EFFORT)  { $l2Parts.Add("${MAUVE}${EFFORT}${RST}") }
if ($CW_SIZE) { $l2Parts.Add("${GREY}$(Format-Tokens (ConvertTo-IntSafe $CW_SIZE)) ctx${RST}") }
$L2 = [string]::Join("${DIM} $MIDDOT ${RST}", $l2Parts)

# ---------- line 3: context + rate limits ----------
$l3Parts = New-Object System.Collections.Generic.List[string]
if ($CW_PCT) {
    $p = ConvertTo-IntSafe $CW_PCT
    $c = Get-Grad $p
    $seg = "${c}$(Get-Bar $p)${p}%${RST}"
    if ($CW_IN -or $CW_OUT) {
        $tot = (ConvertTo-IntSafe $CW_IN) + (ConvertTo-IntSafe $CW_OUT)
        $seg += " ${DIM}$(Format-Tokens $tot)${RST}"
    }
    $l3Parts.Add("${GREY}ctx${RST} $seg")
}
if ($R5_PCT) {
    $p = ConvertTo-IntSafe $R5_PCT
    $c = Get-Grad $p
    $seg = "${c}$(Get-Bar $p)${p}%${RST}"
    if ($R5_AT) { $seg += " ${DIM}$REFRESH$(Get-Rel (ConvertTo-IntSafe $R5_AT))${RST}" }
    $l3Parts.Add("${GREY}5h${RST} $seg")
}
if ($R7_PCT) {
    $p = ConvertTo-IntSafe $R7_PCT
    $c = Get-Grad $p
    $seg = "${c}$(Get-Bar $p)${p}%${RST}"
    if ($R7_AT) { $seg += " ${DIM}$REFRESH$(Get-Rel (ConvertTo-IntSafe $R7_AT))${RST}" }
    $l3Parts.Add("${GREY}7d${RST} $seg")
}
$L3 = [string]::Join("${DIM}  $VBAR  ${RST}", $l3Parts)

# ---------- emit ----------
# Write raw UTF-8 bytes straight to the stdout handle so the block/box glyphs
# render correctly no matter what codepage the calling shell is in.
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$stdout = [Console]::OpenStandardOutput()
$writer = New-Object System.IO.StreamWriter($stdout, $utf8NoBom)
try {
    $writer.WriteLine($L1)
    if ($L2) { $writer.WriteLine($L2) }
    if ($L3) { $writer.WriteLine($L3) }
}
finally {
    $writer.Flush()
}
