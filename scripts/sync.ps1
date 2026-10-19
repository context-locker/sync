# Context Locker sync, version 2. MIT licence.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File sync.ps1 <app> [-Project <id>] [-Daily]
#   powershell -NoProfile -ExecutionPolicy Bypass -File sync.ps1 signin|plan|doctor|readback <app>
#
# Keeps one AI app's files in step with your playbook at context.locker. <app>
# is claude-code, codex, hermes or openclaw. The script asks for a manifest of
# what the app's files should hold, writes only what changed, and sends any
# edit it finds in a synced file back to Context Locker. It writes only inside
# Context Locker's marked blocks and skill folders, backs up anything it
# replaces that it didn't write, and never deletes a file of yours. When
# Context Locker can't be reached, the app keeps the files it has.
#
# For setup (see context.locker/setup):
#   signin    connects the app with a code you approve in your browser. The
#             first run prints the link and the code and exits 3. Run it again
#             to wait up to -Wait seconds (50) for the approval: it exits 0
#             once connected, and 3 while still waiting.
#   plan      shows what a sync would write, and the hook or daily job to add.
#             It changes nothing.
#   doctor    checks the connection, the files and the hook or daily job
#   readback  prints what Context Locker has put in the app's files
#
# The same steps as sync.sh, for Windows PowerShell 5.1 and PowerShell 7.
# sync.sh's spellings of the options (--daily, --project, --wait) work too.
param(
  [Parameter(Position = 0)][string]$First = '',
  [Parameter(Position = 1)][string]$Second = '',
  [string]$Project = '',
  [switch]$Daily,
  [int]$Wait = 50,
  [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest = @()
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$ScriptVersion = 2
$Utf8 = New-Object System.Text.UTF8Encoding($false)
$Uuid = '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
$Hash = '^[0-9a-f]{64}$'

# Options spelled as sync.sh spells them, when PowerShell didn't bind them.
# Called with & from PowerShell, the first one can land in the second position.
$extra = @($Rest)
if ($Second.StartsWith('-')) {
  $extra = @($Second) + $extra
  $Second = ''
}
$Mode = 'sync'
$Harness = $First
if (@('signin', 'plan', 'doctor', 'readback') -contains $First) {
  $Mode = $First
  $Harness = $Second
} elseif ($Second) {
  $Harness = ''
}
$badOption = $false
for ($i = 0; $i -lt $extra.Count; $i++) {
  $option = $extra[$i]
  $value = if ($i + 1 -lt $extra.Count) { $extra[$i + 1] } else { '' }
  if ($option -eq '--daily') { $Daily = [switch]$true }
  elseif ($option -eq '--project' -and $value) { $Project = $value; $i++ }
  elseif ($option -eq '--wait' -and $value -match '^\d+$') { $Wait = [int]$value; $i++ }
  else { $badOption = $true }
}
if ($badOption -or (@('claude-code', 'codex', 'hermes', 'openclaw') -notcontains $Harness) -or $Wait -lt 0) {
  [Console]::Error.WriteLine("Usage: sync.ps1 <app> [-Project <id>] [-Daily]`n       sync.ps1 signin|plan|doctor|readback <app>`n<app> is claude-code, codex, hermes or openclaw.")
  exit 2
}
$AppName = @{ 'claude-code' = 'Claude Code'; 'codex' = 'Codex'; 'hermes' = 'Hermes'; 'openclaw' = 'OpenClaw' }[$Harness]
$OnWindows = ($PSVersionTable.PSVersion.Major -lt 6) -or $IsWindows
$OnMac = ($PSVersionTable.PSVersion.Major -ge 6) -and $IsMacOS

# On Windows the home folder is the profile folder, as Claude Code and Codex
# use it, even when something such as Git has set HOME
$UserHome = if ($OnWindows -or -not $env:HOME) { [Environment]::GetFolderPath('UserProfile') } else { $env:HOME }
$ClHome = if ($env:CONTEXT_LOCKER_HOME) { $env:CONTEXT_LOCKER_HOME } else { Join-Path $UserHome '.contextlocker' }
$AppDir = Join-Path $ClHome $Harness
$Script:Warnings = New-Object System.Collections.Generic.List[string]
$Script:Failed = $false
$Script:SkillsChanged = $false
$Script:WorkspaceId = ''
$Script:ProjectId = ''
$Script:ProjectRoot = ''
$Script:Layer = ''
$Script:Scope = 'global'
# Dates and times in one fixed form, whatever the computer's region
$Invariant = [Globalization.CultureInfo]::InvariantCulture
$Stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ', $Invariant)

function Warn([string]$Message) { $Script:Warnings.Add("Context Locker: $Message") }

# A session start mustn't fail because of Context Locker; anything else reports it
function Stop-Early([string]$Message) {
  [Console]::Error.WriteLine("Context Locker: $Message")
  if ($Mode -eq 'sync' -and -not $Daily) { exit 0 }
  exit 1
}

function Read-Setting([string]$Name, [string]$File) {
  if (-not (Test-Path -LiteralPath $File -PathType Leaf)) { return '' }
  foreach ($line in [IO.File]::ReadAllLines($File)) {
    if ($line.StartsWith("$Name=")) { return $line.Substring($Name.Length + 1) }
  }
  return ''
}

function Get-Sha256Bytes([byte[]]$Bytes) {
  $sha = [Security.Cryptography.SHA256]::Create()
  try { return (($sha.ComputeHash($Bytes) | ForEach-Object { $_.ToString('x2') }) -join '') }
  finally { $sha.Dispose() }
}
function Get-Sha256Text([string]$Text) { return Get-Sha256Bytes $Utf8.GetBytes($Text) }
function Get-Sha256File([string]$Path) { return Get-Sha256Bytes ([IO.File]::ReadAllBytes($Path)) }

$Api = if ($env:CONTEXT_LOCKER_API) { $env:CONTEXT_LOCKER_API } else { Read-Setting 'api' (Join-Path $ClHome 'config') }
if (-not $Api) { $Api = 'https://api.context.locker' }
$Api = $Api.TrimEnd('/')

if ($Mode -eq 'sync' -and -not (Get-Command tar -ErrorAction SilentlyContinue)) {
  Stop-Early 'sync needs tar, which comes with Windows 10 and later.'
}

$TokenFile = Join-Path $AppDir 'token'
$Script:Token = ''
if (Test-Path -LiteralPath $TokenFile -PathType Leaf) {
  $Script:Token = ([IO.File]::ReadAllText($TokenFile)).Trim()
}

# What's wrong with the saved token, or '' when nothing is
function Get-TokenProblem {
  if (-not $Script:Token.StartsWith('ctxl_at_') -or $Script:Token.Length -le 8) {
    return "$AppName isn't connected on this computer. Set it up at context.locker/setup."
  }
  if ($Script:Token -notmatch '^[A-Za-z0-9_-]+$') {
    return "the saved token for $AppName is damaged. Set it up again at context.locker/setup."
  }
  return ''
}
if ($Mode -eq 'sync' -or $Mode -eq 'plan') {
  $problem = Get-TokenProblem
  if ($problem) { Stop-Early $problem }
}

# Makes a file or folder owner-only on macOS and Linux: 600, or 700 for a folder
function Set-OwnerOnly([string]$Path) {
  if ($OnWindows) { return }
  $folder = Test-Path -LiteralPath $Path -PathType Container
  try { [IO.File]::SetUnixFileMode($Path, $(if ($folder) { 448 } else { 384 })) }
  catch {
    & chmod $(if ($folder) { '700' } else { '600' }) $Path
    if ($LASTEXITCODE -ne 0) { throw "can't make $Path private." }
  }
}

try {
  # Only a sync needs the projects folder, so plan leaves no trace
  $newHome = -not (Test-Path -LiteralPath $ClHome)
  $folder = switch ($Mode) { 'sync' { Join-Path $AppDir 'projects' } 'signin' { $AppDir } default { $ClHome } }
  [void](New-Item -ItemType Directory -Force -Path $folder)
  if ($newHome) { Set-OwnerOnly $ClHome }
  $Tmp = Join-Path $ClHome ('tmp.' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
  [void](New-Item -ItemType Directory -Path $Tmp)
} catch {
  Stop-Early "can't write to $ClHome."
}

# One sync at a time on this computer. A lock older than 10 minutes is stale.
$Lock = Join-Path $ClHome 'sync.lock'
$HaveLock = $false
$tries = 0
while ($Mode -eq 'sync') {
  try {
    [void](New-Item -ItemType Directory -Path $Lock -ErrorAction Stop)
    $HaveLock = $true
    break
  } catch {
    $item = Get-Item -LiteralPath $Lock -ErrorAction SilentlyContinue
    if ($item -and $item.LastWriteTimeUtc -lt [DateTime]::UtcNow.AddMinutes(-10)) {
      Remove-Item -LiteralPath $Lock -Recurse -Force -ErrorAction SilentlyContinue
      continue
    }
    $tries++
    if ($tries -ge 15) {
      Remove-Item -LiteralPath $Tmp -Recurse -Force -ErrorAction SilentlyContinue
      Stop-Early 'another sync is still running, so this one stopped.'
    }
    Start-Sleep -Seconds 1
  }
}

if ($PSVersionTable.PSVersion.Major -lt 6) {
  Add-Type -AssemblyName System.Net.Http
  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}
$Client = New-Object System.Net.Http.HttpClient
$Client.Timeout = [TimeSpan]::FromSeconds(60)
[void]$Client.DefaultRequestHeaders.TryAddWithoutValidation('User-Agent', "context-locker-sync/$ScriptVersion ($Harness; powershell)")

# --- Where targets live --------------------------------------------------

$OpenClawWorkspace = Read-Setting 'workspace' (Join-Path $AppDir 'config')

function Get-RootDir([string]$Root) {
  switch ($Root) {
    'claude' { if ($env:CLAUDE_CONFIG_DIR) { return $env:CLAUDE_CONFIG_DIR } return (Join-Path $UserHome '.claude') }
    'codex' { if ($env:CODEX_HOME) { return $env:CODEX_HOME } return (Join-Path $UserHome '.codex') }
    'agents' { return (Join-Path $UserHome '.agents') }
    'hermes' {
      if ($env:HERMES_HOME) { return $env:HERMES_HOME }
      # Native Hermes keeps its files in %LOCALAPPDATA%\hermes (hermes_constants.py)
      if ($OnWindows) {
        $local = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { Join-Path (Join-Path $UserHome 'AppData') 'Local' }
        return (Join-Path $local 'hermes')
      }
      return (Join-Path $UserHome '.hermes')
    }
    'openclaw' {
      if ($OpenClawWorkspace) { return $OpenClawWorkspace }
      if ($env:OPENCLAW_WORKSPACE_DIR) { return $env:OPENCLAW_WORKSPACE_DIR }
      return (Join-Path (Join-Path $UserHome '.openclaw') 'workspace')
    }
    'project' { return $Script:ProjectRoot }
  }
  return ''
}

# Every file and skills folder each app's sync may write. Anything else in a
# manifest is refused.
$BlockTargets = @{
  'claude-code' = @('{claude}/rules/context-locker.md', '{project}/.claude/rules/context-locker.md')
  'codex'       = @('{codex}/AGENTS.md', '{project}/AGENTS.md')
  'hermes'      = @('{hermes}/SOUL.md', '{project}/AGENTS.md')
  'openclaw'    = @('{openclaw}/USER.md', '{openclaw}/AGENTS.md')
}
$SkillRoots = @{
  'claude-code' = @('{claude}/skills', '{project}/.claude/skills')
  'codex'       = @('{agents}/skills', '{project}/.agents/skills')
  'hermes'      = @('{hermes}/skills')
  'openclaw'    = @('{agents}/skills')
}

function Test-Allowed([string]$Target, [string]$Kind) {
  # Project files belong to a project's sync, the app's own files to the global one
  if ($Target.StartsWith('{project}/')) {
    if ($Script:Scope -ne 'project' -or $Script:Layer -ne 'repo') { return $false }
  } elseif ($Script:Scope -ne 'global') { return $false }
  if ($Kind -eq 'block') { return ($BlockTargets[$Harness] -contains $Target) }
  if ($Kind -ne 'skill' -or $Target.Length -gt 200) { return $false }
  $slash = $Target.LastIndexOf('/')
  if ($slash -lt 1) { return $false }
  $root = $Target.Substring(0, $slash)
  $name = $Target.Substring($slash + 1)
  return (($SkillRoots[$Harness] -contains $root) -and ($name -cmatch '^[a-z0-9]+(-[a-z0-9]+)*$'))
}

# The path on this computer for a target such as {codex}/AGENTS.md
function Resolve-Target([string]$Target) {
  if ($Target -notmatch '^\{([a-z-]+)\}(/.+)$') { return '' }
  $base = Get-RootDir $Matches[1]
  if (-not $base) { return '' }
  $rest = $Matches[2]
  $path = $base + ($rest -replace '/', [IO.Path]::DirectorySeparatorChar)
  # Codex reads AGENTS.override.md instead of AGENTS.md when it has content
  if ($Target -eq '{codex}/AGENTS.md') {
    $override = Join-Path $base 'AGENTS.override.md'
    if ((Test-Path -LiteralPath $override -PathType Leaf) -and ([IO.File]::ReadAllText($override).Trim() -ne '')) {
      $path = $override
    }
  }
  return $path
}

# True when no part of a project target's path below the project folder is a
# link, so a repo can't point a write somewhere else on the computer
function Test-InsideProject([string]$Target) {
  $cur = $Script:ProjectRoot
  foreach ($part in $Target.Substring('{project}/'.Length).Split('/')) {
    $cur = Join-Path $cur $part
    if (Test-Link $cur) { return $false }
  }
  return $true
}

function Test-OwnFile([string]$Target) {
  return @('{claude}/rules/context-locker.md', '{project}/.claude/rules/context-locker.md') -contains $Target
}

function Test-Link([string]$Path) {
  $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
  return ($item -and (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0))
}

# A link whose target doesn't exist. .NET calls a broken link's path present,
# so follow its target by hand, a few links deep at most.
function Test-Dangling([string]$Path, [int]$Depth = 0) {
  $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
  if (-not $item -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) { return $false }
  if ($Depth -ge 8) { return $true }
  $target = @($item.Target)[0]
  if (-not $target) { return $false }
  if (-not [IO.Path]::IsPathRooted($target)) { $target = Join-Path (Split-Path -Parent $Path) $target }
  if (-not (Get-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue)) { return $true }
  return (Test-Dangling $target ($Depth + 1))
}

function Backup-Item([string]$Path, [string]$Target) {
  try {
    $dest = Join-Path (Join-Path (Join-Path $ClHome 'backups') $Stamp) $Harness
    if ($Script:ProjectId -and $Target.StartsWith('{project}/')) { $dest = Join-Path $dest "project-$($Script:ProjectId)" }
    [void](New-Item -ItemType Directory -Force -Path $dest)
    $name = ($Target -replace '[{}]', '') -replace '/', '-'
    Copy-Item -LiteralPath $Path -Destination (Join-Path $dest $name) -Recurse -Force
    return $true
  } catch { return $false }
}

# --- Managed blocks --------------------------------------------------------

$StartLine = '^<!-- context-locker:start( v[0-9]+)? -->[ \t\r]*$'
$EndLine = '^<!-- context-locker:end -->[ \t\r]*$'

# Lines as the file has them, without their newline, keeping any carriage return
function Get-Lines([string]$Text) {
  if ($Text -eq '') { return , @() }
  $lines = $Text.Split("`n")
  if ($lines[$lines.Length - 1] -eq '') { $lines = $lines[0..($lines.Length - 2)] }
  return , @($lines)
}

# "none", "broken", or the first and last line of the block, counting from 1
function Get-BlockPosition([string[]]$Lines) {
  $starts = @(); $ends = @()
  for ($i = 0; $i -lt $Lines.Length; $i++) {
    if ($Lines[$i] -cmatch $StartLine) { $starts += $i + 1 }
    if ($Lines[$i] -cmatch $EndLine) { $ends += $i + 1 }
  }
  if ($starts.Length -eq 0 -and $ends.Length -eq 0) { return 'none' }
  if ($starts.Length -eq 1 -and $ends.Length -eq 1 -and $starts[0] -lt $ends[0]) { return "$($starts[0]) $($ends[0])" }
  return 'broken'
}

function Read-Text([string]$Path) { return $Utf8.GetString([IO.File]::ReadAllBytes($Path)) }

function Get-BlockText([string[]]$Lines, [string]$Position) {
  $s, $e = $Position.Split(' ') | ForEach-Object { [int]$_ }
  return ((($Lines[($s - 1)..($e - 1)]) -join "`n") + "`n").Replace("`r", '')
}

function Write-Into([string]$Path, [string]$Text) {
  $dir = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Force -Path $dir) }
  $bytes = $Utf8.GetBytes($Text)
  if (Test-Link $Path) {
    # Keep a symlinked file a symlink, such as a dotfiles setup's
    [IO.File]::WriteAllBytes($Path, $bytes)
    return
  }
  $tmp = Join-Path $dir ('.' + (Split-Path -Leaf $Path) + '.ctx-tmp.' + $PID)
  [IO.File]::WriteAllBytes($tmp, $bytes)
  if (Test-Path -LiteralPath $Path -PathType Leaf) {
    [IO.File]::Replace($tmp, $Path, [NullString]::Value)
  } else {
    [IO.File]::Move($tmp, $Path)
  }
}

# Puts a block into a file: in place of the old block, or at the end after a
# blank line. Everything outside the markers stays as it was.
function Write-Block([string]$Path, [string]$Block) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { Write-Into $Path $Block; return 0 }
  $text = Read-Text $Path
  $lines = Get-Lines $text
  $pos = Get-BlockPosition $lines
  if ($pos -eq 'broken') { return 2 }
  if ($pos -eq 'none') {
    if ($text.Trim() -eq '') { $new = $Block }
    elseif ($text.EndsWith("`n")) { $new = $text + "`n" + $Block }
    else { $new = $text + "`n`n" + $Block }
  } else {
    $s, $e = $pos.Split(' ') | ForEach-Object { [int]$_ }
    $head = if ($s -gt 1) { (($lines[0..($s - 2)]) -join "`n") + "`n" } else { '' }
    $tail = ''
    if ($e -lt $lines.Length) {
      $tail = ($lines[$e..($lines.Length - 1)]) -join "`n"
      if ($text.EndsWith("`n")) { $tail += "`n" }
    }
    $new = $head + $Block + $tail
  }
  Write-Into $Path $new
  return 0
}

# Takes a block out, with one blank line beside it
function Remove-Block([string]$Path, [string]$Target) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return 0 }
  $text = Read-Text $Path
  $lines = Get-Lines $text
  $pos = Get-BlockPosition $lines
  if ($pos -eq 'none') { return 0 }
  if ($pos -eq 'broken') { return 2 }
  $s, $e = $pos.Split(' ') | ForEach-Object { [int]$_ }
  if ($s -gt 1 -and $lines[$s - 2].Trim() -eq '') { $s-- }
  elseif ($e -lt $lines.Length -and $lines[$e].Trim() -eq '') { $e++ }
  $head = if ($s -gt 1) { (($lines[0..($s - 2)]) -join "`n") + "`n" } else { '' }
  $tail = ''
  if ($e -lt $lines.Length) {
    $tail = ($lines[$e..($lines.Length - 1)]) -join "`n"
    if ($text.EndsWith("`n")) { $tail += "`n" }
  }
  $new = $head + $tail
  if ((Test-OwnFile $Target) -and $new.Trim() -eq '') {
    Remove-Item -LiteralPath $Path -Force
  } else {
    Write-Into $Path $new
  }
  return 0
}

# --- Skill folders --------------------------------------------------------

# Folder settings and editor backup, lock and swap files, which never count as
# part of a skill. The API skips the same names.
function Test-Ignored([string]$RelativePath) {
  if ($RelativePath -ceq '.ctx-managed') { return $true }
  $name = $RelativePath.Substring($RelativePath.LastIndexOf('/') + 1)
  return (@('.DS_Store', 'Thumbs.db', 'desktop.ini', '4913') -ccontains $name) -or
    $name.EndsWith('~') -or $name.StartsWith('.#') -or ($name -cmatch '^\..+\.sw[a-p]$')
}

# Files under a folder as relative paths with forward slashes, sorted byte by byte
function Get-SkillFiles([string]$Dir) {
  $root = (Resolve-Path -LiteralPath $Dir).ProviderPath.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
  # Typed, so Array.Sort sorts this array rather than a converted copy
  [string[]]$paths = @(Get-ChildItem -LiteralPath $Dir -Recurse -Force -File -ErrorAction SilentlyContinue |
      Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0 } |
      ForEach-Object { $_.FullName.Substring($root.Length).Replace('\', '/') } |
      Where-Object { -not (Test-Ignored $_) })
  [Array]::Sort($paths, [StringComparer]::Ordinal)
  return , $paths
}

function Get-TreeHash([string]$Dir) {
  $text = New-Object System.Text.StringBuilder
  foreach ($file in (Get-SkillFiles $Dir)) {
    $full = Join-Path $Dir ($file -replace '/', [IO.Path]::DirectorySeparatorChar)
    [void]$text.Append((Get-Sha256File $full) + ' ' + $file + "`n")
  }
  return Get-Sha256Text $text.ToString()
}

function Test-ChangedSince([string]$Dir) {
  $marker = (Get-Item -LiteralPath (Join-Path $Dir '.ctx-managed') -Force).LastWriteTimeUtc
  if ((Get-Item -LiteralPath $Dir -Force).LastWriteTimeUtc -gt $marker) { return $true }
  foreach ($item in (Get-ChildItem -LiteralPath $Dir -Recurse -Force -ErrorAction SilentlyContinue)) {
    if ($item.LastWriteTimeUtc -gt $marker) { return $true }
  }
  return $false
}

function Install-Skill([string]$Source, [string]$Dest, [string]$Item, [string]$Version, [string]$TreeHash) {
  try {
    $parent = Split-Path -Parent $Dest
    $name = Split-Path -Leaf $Dest
    [void](New-Item -ItemType Directory -Force -Path $parent)
    $stage = Join-Path $Tmp "stage.$name"
    $old = Join-Path $Tmp "old.$name"
    Remove-Item -LiteralPath $stage, $old -Recurse -Force -ErrorAction SilentlyContinue
    Copy-Item -LiteralPath $Source -Destination $stage -Recurse -Force
    [IO.File]::WriteAllText((Join-Path $stage '.ctx-managed'),
      "Managed by Context Locker: skill $Item, version $Version.`nEdits here go to Context Locker at the next sync.`n$TreeHash`n", $Utf8)
    if (Test-Path -LiteralPath $Dest) { Move-Item -LiteralPath $Dest -Destination $old }
    try { Move-Item -LiteralPath $stage -Destination $Dest }
    catch {
      # Folders can't move between drives, so copy instead
      try { Copy-Item -LiteralPath $stage -Destination $Dest -Recurse -Force }
      catch {
        if (Test-Path -LiteralPath $old) { Move-Item -LiteralPath $old -Destination $Dest }
        return $false
      }
    }
    if (Test-Path -LiteralPath $old) { Remove-Item -LiteralPath $old -Recurse -Force }
    # The marker is the newest thing in the folder, so later edits show as newer
    (Get-Item -LiteralPath (Join-Path $Dest '.ctx-managed') -Force).LastWriteTimeUtc = [DateTime]::UtcNow
    $Script:SkillsChanged = $true
    return $true
  } catch { return $false }
}

function New-Bundle([string]$Dir) {
  $stream = New-Object System.IO.MemoryStream
  $write = { param([byte[]]$b) $stream.Write($b, 0, $b.Length) }
  & $write ($Utf8.GetBytes("context-locker-bundle 1`n"))
  foreach ($file in (Get-SkillFiles $Dir)) {
    $bytes = [IO.File]::ReadAllBytes((Join-Path $Dir ($file -replace '/', [IO.Path]::DirectorySeparatorChar)))
    & $write ($Utf8.GetBytes("file $($bytes.Length) $file`n"))
    & $write $bytes
    & $write ([byte[]]@(10))
  }
  return , $stream.ToArray()
}

# --- The API --------------------------------------------------------------

# Returns @{ Status; Body (bytes) }. Status 0 means Context Locker can't be reached.
function Invoke-Api([string]$Method, [string]$Path, [byte[]]$Body, [string]$Type, [hashtable]$Headers) {
  $request = New-Object System.Net.Http.HttpRequestMessage((New-Object System.Net.Http.HttpMethod($Method)), "$Api$Path")
  if ($Script:Token) { [void]$request.Headers.TryAddWithoutValidation('Authorization', "Bearer $($Script:Token)") }
  if ($Headers) { foreach ($key in $Headers.Keys) { [void]$request.Headers.TryAddWithoutValidation($key, $Headers[$key]) } }
  if ($null -ne $Body) {
    $content = New-Object System.Net.Http.ByteArrayContent(, $Body)
    $content.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse($Type)
    $request.Content = $content
  }
  try {
    $response = $Client.SendAsync($request).GetAwaiter().GetResult()
    $bytes = $response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
    return @{ Status = [int]$response.StatusCode; Body = $bytes }
  } catch {
    return @{ Status = 0; Body = [byte[]]@() }
  }
}

function Get-ReplyField([byte[]]$Body, [string]$Name) {
  try {
    $value = ($Utf8.GetString($Body) | ConvertFrom-Json).$Name
    if ($value) { return [string]$value }
  } catch { }
  return ''
}

# Sends an edit found in a synced file. Returns what the API said to do.
function Send-Edit([string]$Target, [string]$Kind, [string]$Path, [string]$Recorded, [string]$Query) {
  if ($Kind -eq 'block') {
    $lines = Get-Lines (Read-Text $Path)
    $body = $Utf8.GetBytes((Get-BlockText $lines (Get-BlockPosition $lines)))
    $type = 'text/plain'
  } else {
    $body = New-Bundle $Path
    $type = 'application/octet-stream'
  }
  $headers = @{ 'Context-Locker-Target' = $Target }
  if ($Recorded -ne '-') { $headers['Context-Locker-Base'] = $Recorded }
  $reply = Invoke-Api 'POST' "/v1/sync/edits$Query" $body $type $headers
  $Script:EditReply = $reply.Body
  if ($reply.Status -eq 200) { return (Get-ReplyField $reply.Body 'status') }
  if ($reply.Status -eq 0) { return 'offline' }
  if ($reply.Status -ge 400 -and $reply.Status -lt 500) { return 'refused' }
  return 'error'
}

# --- One sync: global, or one project ---------------------------------------

# In a plan, what each step would do, in plain words
$Script:PlanOut = New-Object System.Collections.Generic.List[string]
function Add-Planned([string]$Text) { if ($Mode -eq 'plan') { $Script:PlanOut.Add($Text) } }

function Sync-Scope([string]$Query, [string]$State) {
  $lockfile = "$State.lock"
  $lockLines = @()
  if (Test-Path -LiteralPath $lockfile -PathType Leaf) { $lockLines = @([IO.File]::ReadAllLines($lockfile)) }
  $oldEtag = ''
  foreach ($line in $lockLines) { if ($line -match '^etag ([0-9a-f]{64})$') { $oldEtag = $Matches[1] } }
  # A plan always looks at the whole manifest
  if ($Mode -eq 'plan') { $oldEtag = '' }

  $headers = @{}
  if ($oldEtag) { $headers['If-None-Match'] = "`"$oldEtag`"" }
  $reply = Invoke-Api 'GET' "/v1/sync$Query" $null '' $headers
  $fresh = $false
  switch ($reply.Status) {
    200 {
      $text = $Utf8.GetString($reply.Body)
      $all = Get-Lines $text
      if ($all.Length -eq 0 -or $all[0] -ne 'context-locker-sync 1') {
        Warn 'this sync script is out of date. Set it up again at context.locker/setup.'
        $Script:Failed = $true
        return 1
      }
      $entries = @($all | Select-Object -Skip 1)
      $etag = Get-Sha256Bytes $reply.Body
      $fresh = $true
    }
    304 {
      $entries = @($lockLines | Where-Object { $_.StartsWith('entry ') } | ForEach-Object { $_.Substring(6) })
      $etag = $oldEtag
    }
    0 {
      Warn "can't reach Context Locker, so $Harness keeps the files from the last sync."
      $Script:Failed = $true
      return 1
    }
    401 {
      Warn "this computer's connection for $Harness was revoked or has expired. Set it up again at context.locker/setup."
      $Script:Failed = $true
      return 1
    }
    404 {
      Warn "that project isn't in your playbook any more, so it was unlinked here."
      return 3
    }
    default {
      Warn "Context Locker answered $($reply.Status), so nothing changed. The next sync tries again."
      $Script:Failed = $true
      return 1
    }
  }

  if (-not $Query) {
    foreach ($line in $entries) { if ($line -match '^workspace ([0-9a-f-]{36})$') { $Script:WorkspaceId = $Matches[1] } }
  }

  # What the manifest says, what this script last wrote, edits waiting for
  # approval, and edits the API refused, per target
  $order = New-Object System.Collections.Generic.List[string]
  $plan = @{}
  foreach ($line in $entries) {
    $f = $line.Split(' ')
    if (($f[0] -eq 'block' -or $f[0] -eq 'skill') -and $f.Length -ge 3) {
      $item = '-'; $ver = '-'
      if ($f[0] -eq 'skill' -and $f.Length -ge 5) { $item = $f[3]; $ver = $f[4] }
      $plan[$f[2]] = @{ Kind = $f[0]; S = $f[1]; R = '-'; Holds = @(); Refused = @(); Item = $item; Ver = $ver }
      $order.Add($f[2])
    }
  }
  $holds = @{}
  foreach ($line in $entries) {
    $f = $line.Split(' ')
    if ($f[0] -eq 'hold' -and $f.Length -ge 3) { $holds[$f[2]] = @($holds[$f[2]]) + $f[1] }
  }
  foreach ($line in $lockLines) {
    $f = $line.Split(' ')
    if ($f[0] -eq 'wrote' -and $f.Length -ge 4) {
      if (-not $plan.ContainsKey($f[3])) {
        $plan[$f[3]] = @{ Kind = $f[1]; S = '-'; R = '-'; Holds = @(); Refused = @(); Item = '-'; Ver = '-' }
        $order.Add($f[3])
      }
      $plan[$f[3]].R = $f[2]
    }
  }
  foreach ($line in $lockLines) {
    $f = $line.Split(' ')
    if ($f[0] -eq 'refused' -and $f.Length -ge 3 -and $plan.ContainsKey($f[2])) { $plan[$f[2]].Refused += $f[1] }
  }
  foreach ($t in $order) { if ($holds.ContainsKey($t)) { $plan[$t].Holds = @($holds[$t] | Where-Object { $_ }) } }

  $actions = New-Object System.Collections.Generic.List[hashtable]
  $wrote = New-Object System.Collections.Generic.List[string]
  $refusedOut = New-Object System.Collections.Generic.List[string]
  $skipped = New-Object System.Collections.Generic.List[string]
  $complete = $true
  $written = 0
  $held = 0

  foreach ($t in $order) {
    $p = $plan[$t]
    $kind = $p.Kind; $S = $p.S; $R = $p.R
    if (-not (Test-Allowed $t $kind)) {
      Warn "skipped ${t}: it isn't a file $Harness's sync may write."
      Add-Planned "Skip ${t}: it isn't a file $AppName's sync may write."
      $skipped.Add("skipped not-allowed $t")
      continue
    }
    $path = Resolve-Target $t
    if (-not $path) {
      Add-Planned "Skip ${t}: it has no folder on this computer."
      $skipped.Add("skipped no-folder $t")
      continue
    }
    $skillName = $t.Substring($t.LastIndexOf('/') + 1)
    $what = if ($kind -eq 'skill') { "the skill $skillName at $path" } else { $path }
    if ($t.StartsWith('{project}/')) {
      if (-not (Test-InsideProject $t)) {
        Warn "left $path alone: part of its path is a link, and links in a project aren't followed."
        Add-Planned "Leave $path alone: part of its path is a link, and links in a project aren't followed."
        $skipped.Add("skipped link $t")
        if ($R -ne '-') { $wrote.Add("wrote $kind $R $t") }
        continue
      }
    } elseif (Test-Dangling $path) {
      Warn "left $path alone: it's a link to something that doesn't exist."
      Add-Planned "Leave $path alone: it's a link to something that doesn't exist."
      $skipped.Add("skipped link $t")
      if ($R -ne '-') { $wrote.Add("wrote $kind $R $t") }
      continue
    }

    if ($kind -eq 'block') {
      if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { $L = 'none' }
      else {
        $lines = Get-Lines (Read-Text $path)
        $pos = Get-BlockPosition $lines
        if ($pos -eq 'none' -or $pos -eq 'broken') { $L = $pos } else { $L = Get-Sha256Text (Get-BlockText $lines $pos) }
      }
    } else {
      if (-not (Test-Path -LiteralPath $path)) { $L = 'none' }
      elseif ((Test-Link $path) -or -not (Test-Path -LiteralPath $path -PathType Container) -or
        -not (Test-Path -LiteralPath (Join-Path $path '.ctx-managed') -PathType Leaf)) { $L = 'foreign' }
      else {
        # Nothing newer than the marker: the folder is as its marker says,
        # whichever app's sync wrote it
        # Before anything is written over it, hash it anyway, as an edit in the
        # same second wouldn't show as newer
        $L = ''
        $marker = @([IO.File]::ReadAllLines((Join-Path $path '.ctx-managed')))
        if ($marker.Length -ge 3 -and $marker[2] -match $Hash -and $marker[2] -eq $S -and -not (Test-ChangedSince $path)) { $L = $marker[2] }
        if (-not $L) { $L = Get-TreeHash $path }
      }
    }

    if ($L -eq 'broken') {
      Warn "left $path alone: its Context Locker markers don't pair up. Fix or remove them and sync again."
      Add-Planned "Leave $path alone: its Context Locker markers don't pair up. Fix or remove them first."
      $skipped.Add("skipped broken-markers $t")
      if ($R -ne '-') { $wrote.Add("wrote $kind $R $t") }
      continue
    }
    if ($L -eq 'foreign') {
      if ($S -ne '-') {
        Warn "left $path alone: there's already a skill of yours there with that name."
        Add-Planned "Leave $path alone: there's already a skill of yours there with that name."
        $skipped.Add("skipped conflict $t")
      }
      continue
    }
    $isHeld = $p.Holds -contains $L
    $backups = Join-Path $ClHome 'backups'

    if ($S -eq '-') {
      # Gone from the playbook: take it away, unless it holds an edit
      if ($isHeld) {
        $held++; $wrote.Add("wrote $kind $R $t")
        Add-Planned "Keep your edit in $what while it waits for approval."
      } elseif ($L -eq 'none') {
      } elseif ($L -eq $R) {
        if ($kind -eq 'block') { Add-Planned "Take Context Locker's block out of $path, as it's no longer in your playbook." }
        else { Add-Planned "Remove $what, as it's no longer in your playbook. A copy goes in $backups first." }
        $actions.Add(@{ Action = 'remove'; Target = $t; Kind = $kind })
      } else {
        Add-Planned "Leave $what as yours: it's no longer in your playbook, and it was changed here."
        $actions.Add(@{ Action = 'untrack'; Target = $t; Kind = $kind })
      }
      continue
    }

    $write = @{ Action = 'write'; Target = $t; Kind = $kind; Hash = $S; Item = $p.Item; Ver = $p.Ver; Keep = $false }
    if ($L -eq $S) {
      Add-Planned "Up to date: $what."
      $wrote.Add("wrote $kind $S $t")
    } elseif ($isHeld) {
      Add-Planned "Keep your edit in $what while it waits for approval."
      $held++; if ($R -ne '-') { $wrote.Add("wrote $kind $R $t") }
    } elseif ($L -eq 'none') {
      if ($kind -eq 'skill') { Add-Planned "Add $what." }
      elseif (Test-Path -LiteralPath $path -PathType Leaf) { Add-Planned "Add Context Locker's block to the end of $path. The rest of the file stays as it is." }
      else { Add-Planned "Create $path with Context Locker's block." }
      $actions.Add($write)
    } elseif ($R -eq '-') {
      if ($kind -eq 'skill') { Add-Planned "Replace $what, which this computer has no record of syncing. A copy goes in $backups first." }
      else { Add-Planned "Replace the Context Locker block in $path, which this computer has no record of writing. A copy of the file goes in $backups first." }
      $write.Keep = $true; $actions.Add($write)
    } elseif ($L -eq $R) {
      if ($kind -eq 'skill') { Add-Planned "Update $what." } else { Add-Planned "Update Context Locker's block in $path." }
      $actions.Add($write)
    } elseif ($p.Refused -contains $L) {
      Warn "$path has an edit Context Locker couldn't take, so it won't update until you undo or fix the edit."
      Add-Planned "Keep your edit in $what. Context Locker couldn't take it, so this won't update until the edit is undone or fixed."
      $refusedOut.Add("refused $L $t"); $wrote.Add("wrote $kind $R $t"); $skipped.Add("skipped refused $t")
    } elseif ($Mode -eq 'plan') {
      # A plan sends nothing
      Add-Planned "Send your edit in $what to Context Locker, which applies it unless it needs approval first."
    } else {
      # An edit made here since the last sync
      $outcome = Send-Edit $t $kind $path $R $Query
      switch ($outcome) {
        'pending' { $held++; $wrote.Add("wrote $kind $R $t") }
        { @('rejected', 'accepted', 'same') -contains $_ } {
          if ($outcome -eq 'rejected') { Warn "your edit to $path was declined, so it was put back. A copy is in $(Join-Path $ClHome 'backups')." }
          $write.Keep = $true; $actions.Add($write)
        }
        'gone' { $actions.Add(@{ Action = 'untrack'; Target = $t; Kind = $kind }) }
        'refused' {
          $message = Get-ReplyField $Script:EditReply 'message'
          if (-not $message) { $message = 'it was refused' }
          Warn "Context Locker couldn't take your edit to ${path}: $message"
          $refusedOut.Add("refused $L $t"); $wrote.Add("wrote $kind $R $t"); $skipped.Add("skipped refused $t")
        }
        default { $complete = $false; $wrote.Add("wrote $kind $R $t") }
      }
    }
  }

  # A plan stops here: it fetches, writes and reports nothing
  if ($Mode -eq 'plan') { return 0 }

  # Text for the session start, kept on this computer so it shows offline too
  $contextHash = ''
  foreach ($line in $entries) { if ($line -match '^context ([0-9a-f]{64})$') { $contextHash = $Matches[1] } }
  $contextFile = "$State.context"
  if (-not $contextHash) { Remove-Item -LiteralPath $contextFile -Force -ErrorAction SilentlyContinue }
  elseif (-not (Test-Path -LiteralPath $contextFile) -or (Get-Sha256File $contextFile) -ne $contextHash) {
    $actions.Add(@{ Action = 'context'; Target = ''; Kind = 'context'; Hash = $contextHash })
  }

  # Fetch everything that needs writing in one request
  $want = @($actions | Where-Object { $_.Action -eq 'write' -or $_.Action -eq 'context' } | ForEach-Object { $_.Hash } | Sort-Object -Unique)
  $blobs = Join-Path $Tmp ('blobs.' + [Guid]::NewGuid().ToString('N').Substring(0, 6))
  [void](New-Item -ItemType Directory -Path $blobs)
  if ($want.Length -gt 0) {
    $reply = Invoke-Api 'POST' "/v1/sync/blobs$Query" ($Utf8.GetBytes(($want -join "`n") + "`n")) 'text/plain' @{}
    $ok = $reply.Status -eq 200
    if ($ok) {
      $archive = Join-Path $Tmp 'blobs.tar'
      [IO.File]::WriteAllBytes($archive, $reply.Body)
      # Windows PowerShell turns a native tool's stderr into errors, so don't stop on them
      $ErrorActionPreference = 'Continue'
      & tar -xmof $archive -C $blobs 2>$null
      $ok = ($LASTEXITCODE -eq 0)
      $ErrorActionPreference = 'Stop'
    }
    if ($ok) {
      foreach ($item in (Get-ChildItem -LiteralPath $blobs -Recurse -Force)) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { $ok = $false }
      }
    }
    if (-not $ok) {
      Warn "couldn't fetch the latest files, so $Harness keeps the ones it has. The next sync tries again."
      $Script:Failed = $true
      return 1
    }
  }

  foreach ($a in $actions) {
    if ($a.Action -eq 'context') {
      $blob = Join-Path $blobs $a.Hash
      if ((Test-Path -LiteralPath $blob -PathType Leaf) -and (Get-Sha256File $blob) -eq $a.Hash) {
        Copy-Item -LiteralPath $blob -Destination $contextFile -Force
      } else { $complete = $false }
      continue
    }
    $t = $a.Target
    $path = Resolve-Target $t
    if (-not $path) { continue }
    switch ("$($a.Action) $($a.Kind)") {
      'write block' {
        $blob = Join-Path $blobs $a.Hash
        if (-not (Test-Path -LiteralPath $blob -PathType Leaf) -or (Get-Sha256File $blob) -ne $a.Hash) {
          Warn "the new content for $path didn't match its hash, so it wasn't written. The next sync tries again."
          $complete = $false; break
        }
        if ($a.Keep -and (Test-Path -LiteralPath $path -PathType Leaf)) { [void](Backup-Item $path $t) }
        try { $result = Write-Block $path (Read-Text $blob) } catch { $result = 1 }
        if ($result -eq 0) { $written++; $wrote.Add("wrote block $($a.Hash) $t") }
        elseif ($result -eq 2) { Warn "left $path alone: its Context Locker markers don't pair up."; $skipped.Add("skipped broken-markers $t") }
        else { Warn "couldn't write $path."; $complete = $false }
      }
      'write skill' {
        $blob = Join-Path $blobs $a.Hash
        if (-not (Test-Path -LiteralPath $blob -PathType Container) -or (Get-TreeHash $blob) -ne $a.Hash) {
          Warn "the new content for $path didn't match its hash, so it wasn't written. The next sync tries again."
          $complete = $false; break
        }
        if ($a.Keep -and (Test-Path -LiteralPath $path)) { [void](Backup-Item $path $t) }
        if (Install-Skill $blob $path $a.Item $a.Ver $a.Hash) { $written++; $wrote.Add("wrote skill $($a.Hash) $t") }
        else { Warn "couldn't write $path."; $complete = $false }
      }
      'remove block' { try { [void](Remove-Block $path $t) } catch { $complete = $false } }
      'remove skill' {
        if (Backup-Item $path $t) { Remove-Item -LiteralPath $path -Recurse -Force; $Script:SkillsChanged = $true }
        else { $complete = $false }
      }
      'untrack skill' {
        Remove-Item -LiteralPath (Join-Path $path '.ctx-managed') -Force -ErrorAction SilentlyContinue
        Warn "$path is no longer in your playbook. You'd changed it, so it stays here as your own."
      }
      'untrack block' { Warn "the Context Locker block in $path is no longer in your playbook. You'd changed it, so it stays as it is." }
    }
  }

  $out = New-Object System.Text.StringBuilder
  [void]$out.Append("context-locker-lock 1`n")
  if ($complete) { [void]$out.Append("etag $etag`n") }
  [void]$out.Append("synced $([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ', $Invariant))`n")
  foreach ($line in $entries) { if ($line) { [void]$out.Append("entry $line`n") } }
  foreach ($line in $wrote) { [void]$out.Append("$line`n") }
  foreach ($line in $refusedOut) { [void]$out.Append("$line`n") }
  [IO.File]::WriteAllText("$lockfile.tmp", $out.ToString(), $Utf8)
  if (Test-Path -LiteralPath $lockfile) { [IO.File]::Replace("$lockfile.tmp", $lockfile, [NullString]::Value) } else { [IO.File]::Move("$lockfile.tmp", $lockfile) }

  if (-not $complete) { $Script:Failed = $true }
  if ($fresh -and $complete) {
    $report = "manifest $etag`nwritten $written`nheld $held`n" + (($skipped | Select-Object -First 100 | ForEach-Object { "$_`n" }) -join '')
    [void](Invoke-Api 'POST' "/v1/sync/done$Query" ($Utf8.GetBytes($report)) 'text/plain' @{})
  }
  return 0
}

# --- Which project this session is in ---------------------------------------

function Find-Project {
  $start = if ($env:CLAUDE_PROJECT_DIR) { $env:CLAUDE_PROJECT_DIR } else { (Get-Location).ProviderPath }
  $dir = $start
  while ($dir) {
    $file = Join-Path $dir '.contextlocker.json'
    if (Test-Path -LiteralPath $file -PathType Leaf) {
      $text = [IO.File]::ReadAllText($file)
      $ws = ''; $id = ''
      if ($text -match '"workspace"\s*:\s*"([0-9a-f-]{36})"') { $ws = $Matches[1] }
      if ($text -match '"project"\s*:\s*"([0-9a-f-]{36})"') { $id = $Matches[1] }
      if ($id -match $Uuid -and $Script:WorkspaceId -and $ws -eq $Script:WorkspaceId) {
        $Script:ProjectId = $id; $Script:ProjectRoot = $dir; $Script:Layer = 'repo'
        return $true
      }
      break
    }
    if ($dir -eq $UserHome) { break }
    $parent = Split-Path -Parent $dir
    if (-not $parent -or $parent -eq $dir) { break }
    $dir = $parent
  }

  # Folders linked on this computer only: "<project id> <folder>" per line
  $map = Join-Path $ClHome 'projects'
  if (-not (Test-Path -LiteralPath $map -PathType Leaf)) { return $false }
  $best = ''
  foreach ($line in [IO.File]::ReadAllLines($map)) {
    $space = $line.IndexOf(' ')
    if ($space -lt 1) { continue }
    $id = $line.Substring(0, $space); $folder = $line.Substring($space + 1)
    $sep = [IO.Path]::DirectorySeparatorChar
    if (("$start$sep").StartsWith("$folder$sep") -and $folder.Length -gt $best.Length) {
      $best = $folder; $Script:ProjectId = $id
    }
  }
  if (-not $best) { return $false }
  $Script:ProjectRoot = $best; $Script:Layer = 'personal'
  return $true
}

function Set-ProjectLink {
  if ($Project -notmatch $Uuid) { Warn '-Project needs a project''s id.'; $Script:Failed = $true; return }
  $start = if ($env:CLAUDE_PROJECT_DIR) { $env:CLAUDE_PROJECT_DIR } else { (Get-Location).ProviderPath }
  $root = $start
  $ErrorActionPreference = 'Continue'
  try {
    $top = & git -C $start rev-parse --show-toplevel 2>$null
    if ($LASTEXITCODE -eq 0 -and $top) { $root = ($top | Select-Object -First 1) -replace '/', [IO.Path]::DirectorySeparatorChar }
  } catch { }
  $ErrorActionPreference = 'Stop'
  $map = Join-Path $ClHome 'projects'
  $lines = @()
  if (Test-Path -LiteralPath $map) {
    $lines = @([IO.File]::ReadAllLines($map) | Where-Object { $_.IndexOf(' ') -gt 0 -and $_.Substring($_.IndexOf(' ') + 1) -ne $root })
  }
  $lines += "$Project $root"
  [IO.File]::WriteAllText($map, (($lines | ForEach-Object { "$_`n" }) -join ''), $Utf8)
}

function Remove-ProjectLink([string]$Id) {
  $map = Join-Path $ClHome 'projects'
  $lines = @([IO.File]::ReadAllLines($map) | Where-Object { -not $_.StartsWith("$Id ") })
  [IO.File]::WriteAllText($map, (($lines | ForEach-Object { "$_`n" }) -join ''), $Utf8)
}

# --- Setup: sign-in, plan, doctor and read-back ------------------------------

$Script:Stdout = [Console]::OpenStandardOutput()
function Write-Out([string]$Text) { $bytes = $Utf8.GetBytes($Text); $Script:Stdout.Write($bytes, 0, $bytes.Length) }
function Say([string]$Text) { Write-Out "$Text`n" }

# Quotes a word for sh, when it needs quoting
function ConvertTo-ShellText([string]$Text) {
  if ($Text -match '^[A-Za-z0-9/._~-]+$') { return $Text }
  return "'" + ($Text -replace "'", "'\''") + "'"
}

# Where setup saves this script, and how hooks and daily jobs run it
$Installed = Join-Path $ClHome 'sync.ps1'
$RunArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Installed)
if ($OnWindows) {
  $Run = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$Installed`""
} elseif ($ClHome -eq (Join-Path $UserHome '.contextlocker')) {
  $Run = 'pwsh -NoProfile -File ~/.contextlocker/sync.ps1'
} else {
  $Run = "pwsh -NoProfile -File $(ConvertTo-ShellText $Installed)"
}
$Trigger = if ($Harness -eq 'hermes' -or $Harness -eq 'openclaw') { 'daily job' } else { 'session-start hook' }
$OsName = if ($OnWindows) { 'Windows' } elseif ($OnMac) { 'macOS' } else { 'Linux' }

function Get-Plural([int]$Count, [string]$One, [string]$Many) { if ($Count -eq 1) { "1 $One" } else { "$Count $Many" } }

function ConvertFrom-Reply([byte[]]$Body) {
  try { return ($Utf8.GetString($Body) | ConvertFrom-Json) } catch { return $null }
}

function Get-Field($Object, [string]$Name) {
  if ($null -eq $Object) { return '' }
  $property = $Object.PSObject.Properties[$Name]
  if ($property -and $null -ne $property.Value) { return [string]$property.Value }
  return ''
}

function Get-Property($Object, [string]$Name) {
  if ($null -eq $Object) { return $null }
  $property = $Object.PSObject.Properties[$Name]
  if ($property) { return $property.Value }
  return $null
}

# Text from a reply, with any control characters taken out before it's shown
function Get-Clean([string]$Text) { return ($Text -replace '[\x00-\x1f\x7f]', '') }

# "Claude Code on Ada's laptop, in the Personal workspace", from GET /v1/agent
function Get-ConnectedAs([byte[]]$Body) {
  $reply = ConvertFrom-Reply $Body
  $agent = Get-Property $reply 'agent'
  $name = Get-Clean (Get-Field $agent 'name')
  $text = if ($name) { $name } else { $AppName }
  $machine = Get-Clean (Get-Field $agent 'machine_name')
  if ($machine) { $text += " on $machine" }
  $workspace = Get-Clean (Get-Field (Get-Property $reply 'workspace') 'name')
  if ($workspace) { $text += ", in the $workspace workspace" }
  return $text
}

# This computer's name, as the approval page shows it: the first of its names
# with a letter or digit left once it's cut down to plain characters, or nothing
function Get-MachineName {
  $names = @()
  if ($OnMac) {
    $ErrorActionPreference = 'Continue'
    try { $names += [string](& scutil --get ComputerName 2>$null) } catch { }
  }
  $names += [Environment]::MachineName
  foreach ($name in $names) {
    # macOS names use a curly apostrophe; keep it readable as a straight one
    $name = ($name -replace [string][char]0x2019, "'") -replace "[^A-Za-z0-9 ._'-]", ''
    if ($name.Length -gt 120) { $name = $name.Substring(0, 120) }
    $name = $name.Trim()
    if ($name -match '[A-Za-z0-9]') { return $name }
  }
  return ''
}

# A random id for this computer, kept so that connecting an app again replaces
# its old connection instead of adding another. -Saved only reads it.
function Get-MachineId([switch]$Saved) {
  $file = Join-Path $ClHome 'machine-id'
  $id = ''
  if (Test-Path -LiteralPath $file -PathType Leaf) { $id = ([IO.File]::ReadAllText($file)).Trim() }
  if ($id -notmatch '^[0-9a-f]{32}$') {
    if ($Saved) { return '' }
    $id = [Guid]::NewGuid().ToString('N')
    [IO.File]::WriteAllText($file, "$id`n", $Utf8)
  }
  return $id
}

# Writes a secret only this account can read. On macOS and Linux the file is
# owner-only (600) from the moment it exists, before it takes its name.
function Write-Secret([string]$Path, [string]$Text) {
  $tmp = "$Path.tmp"
  $bytes = $Utf8.GetBytes($Text)
  if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }
  if ($OnWindows) {
    [IO.File]::WriteAllBytes($tmp, $bytes)
  } else {
    try {
      $options = New-Object IO.FileStreamOptions
      $options.Mode = [IO.FileMode]::CreateNew
      $options.Access = [IO.FileAccess]::Write
      $options.UnixCreateMode = 384
      $stream = New-Object IO.FileStream -ArgumentList $tmp, $options
    } catch {
      # Before .NET 7: make the empty file owner-only, then write into it
      [IO.File]::WriteAllBytes($tmp, [byte[]]@())
      Set-OwnerOnly $tmp
      $stream = New-Object IO.FileStream -ArgumentList $tmp, ([IO.FileMode]::Truncate), ([IO.FileAccess]::Write)
    }
    try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
    Set-OwnerOnly $tmp
  }
  if (Test-Path -LiteralPath $Path -PathType Leaf) { [IO.File]::Replace($tmp, $Path, [NullString]::Value) } else { [IO.File]::Move($tmp, $Path) }
}

function Save-DeviceState([string]$Path, [hashtable]$Device) {
  Write-Secret $Path ("device_code=$($Device.device_code)`nuser_code=$($Device.user_code)`nlink=$($Device.link)`n" +
    "expires=$($Device.expires)`ninterval=$($Device.interval)`nlast=$($Device.last)`n")
}

function Get-Now { return [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }

# Connects this app with a device code (RFC 8628). Only the link and the code
# are shown: the token goes straight into a file only this account can read.
function Invoke-Signin {
  if (-not (Get-TokenProblem)) {
    $reply = Invoke-Api 'GET' '/v1/agent' $null '' @{}
    if ($reply.Status -eq 200) { Say "$AppName is already connected: $(Get-ConnectedAs $reply.Body)."; return 0 }
    if ($reply.Status -eq 0) { [Console]::Error.WriteLine("Context Locker: can't reach $Api. Check the internet connection and try again."); return 1 }
    if ($reply.Status -ne 401) { [Console]::Error.WriteLine("Context Locker answered $($reply.Status). Try again in a minute."); return 1 }
  }
  # A revoked or damaged token is replaced, never sent along
  $Script:Token = ''

  $state = Join-Path $AppDir 'device'
  $now = Get-Now
  $device = @{
    device_code = Read-Setting 'device_code' $state
    user_code = Read-Setting 'user_code' $state
    link = Read-Setting 'link' $state
    expires = Read-Setting 'expires' $state
    interval = Read-Setting 'interval' $state
    last = Read-Setting 'last' $state
  }
  $usable = $device.device_code -and ($device.expires -match '^\d+$') -and ($device.interval -match '^\d+$') -and
    ($device.last -match '^\d+$') -and ([long]$device.expires -gt $now)
  if (-not $usable) {
    Remove-Item -LiteralPath $state -Force -ErrorAction SilentlyContinue
    $start = [ordered]@{ harness = $Harness; agent_name = $AppName; client_version = "sync.ps1 $ScriptVersion"; os = $OsName }
    $name = Get-MachineName
    if ($name) { $start['machine_name'] = $name }
    $start['machine_id'] = Get-MachineId
    $reply = Invoke-Api 'POST' '/oauth/device_authorization' ($Utf8.GetBytes(($start | ConvertTo-Json -Compress))) 'application/json' @{}
    if ($reply.Status -eq 0) { [Console]::Error.WriteLine("Context Locker: can't reach $Api. Check the internet connection and try again."); return 1 }
    if ($reply.Status -eq 429) { [Console]::Error.WriteLine('Context Locker: too many sign-ins from this network just now. Try again in a few minutes.'); return 1 }
    $started = ConvertFrom-Reply $reply.Body
    if ($reply.Status -ne 200) {
      $message = Get-Clean (Get-Field $started 'error_description')
      if (-not $message) { $message = "Context Locker answered $($reply.Status)." }
      [Console]::Error.WriteLine("Context Locker: couldn't start the sign-in: $message")
      return 1
    }
    $device.device_code = Get-Field $started 'device_code'
    $device.user_code = Get-Field $started 'user_code'
    $device.link = Get-Field $started 'verification_uri_complete'
    $device.interval = Get-Field $started 'interval'
    $expiresIn = Get-Field $started 'expires_in'
    if ($device.device_code -notmatch '^ctxl_dc_[A-Za-z0-9_-]+$' -or $device.user_code -notmatch '^[A-Z0-9]{4}-[A-Z0-9]{4}$' -or
      $device.link -notmatch '^https?://[A-Za-z0-9:/.?=_-]+$' -or $expiresIn -notmatch '^\d+$' -or $device.interval -notmatch '^\d+$') {
      [Console]::Error.WriteLine("Context Locker: the sign-in reply didn't make sense, so nothing was saved. Try again.")
      return 1
    }
    $device.expires = [string]($now + [long]$expiresIn)
    $device.last = '0'
    Save-DeviceState $state $device
  }

  Say "To connect $AppName on this computer, open this link and approve the request:`n`n  $($device.link)`n`nCheck that the page shows the code $($device.user_code)."
  # Nobody can have approved a code that was only just shown, so the first run
  # hands the link straight back instead of waiting
  if (-not $usable) {
    Say "`nWaiting for approval. Once it's approved, run this command again."
    return 3
  }

  $interval = [long]$device.interval
  $last = [long]$device.last
  $deadline = (Get-Now) + $Wait
  $polled = $false
  while ($true) {
    # Never poll faster than the interval, even across runs of this command.
    # Times are whole seconds, so wait one more to be sure.
    $interval = [Math]::Min([Math]::Max($interval, 5), 60)
    $now = Get-Now
    $pause = $last + $interval + 1 - $now
    if ($pause -gt 0) {
      if ($polled -and ($now + $pause) -gt $deadline) { break }
      Start-Sleep -Seconds $pause
    }
    $poll = '{"grant_type":"urn:ietf:params:oauth:grant-type:device_code","device_code":"' + $device.device_code + '"}'
    $reply = Invoke-Api 'POST' '/oauth/token' ($Utf8.GetBytes($poll)) 'application/json' @{}
    $polled = $true
    $last = Get-Now
    $answer = ConvertFrom-Reply $reply.Body
    $code = if ($reply.Status -eq 400) { Get-Field $answer 'error' } else { '' }
    if ($reply.Status -eq 200) {
      $new = Get-Field $answer 'access_token'
      Remove-Item -LiteralPath $state -Force -ErrorAction SilentlyContinue
      if ($new -notmatch '^ctxl_at_[A-Za-z0-9_-]+$') { Say "`nThe reply didn't include a usable token. Run this command again to start over."; return 1 }
      try { Write-Secret $TokenFile "$new`n" } catch { [Console]::Error.WriteLine("Context Locker: couldn't save the connection in $AppDir."); return 1 }
      $Script:Token = $new
      $who = Invoke-Api 'GET' '/v1/agent' $null '' @{}
      if ($who.Status -eq 200) { Say "`nConnected: $(Get-ConnectedAs $who.Body)." } else { Say "`nConnected." }
      return 0
    }
    if ($code -eq 'slow_down') {
      $interval += 5
    } elseif ($code -eq 'access_denied') {
      Remove-Item -LiteralPath $state -Force -ErrorAction SilentlyContinue
      Say "`nThe request was turned down, so $AppName isn't connected. Run this command again to start over."
      return 1
    } elseif ($code -eq 'expired_token') {
      Remove-Item -LiteralPath $state -Force -ErrorAction SilentlyContinue
      Say "`nThe code expired before it was approved. Run this command again for a new one."
      return 1
    } elseif ($code -eq 'invalid_grant') {
      Remove-Item -LiteralPath $state -Force -ErrorAction SilentlyContinue
      Say "`nThis code can't be used any more. Run this command again for a new one."
      return 1
    } elseif ($reply.Status -ne 0 -and $code -ne 'authorization_pending') {
      $device.interval = [string]$interval; $device.last = [string]$last
      Save-DeviceState $state $device
      Say "`nContext Locker answered $($reply.Status). Run this command again to keep waiting."
      return 1
    }
    $device.interval = [string]$interval; $device.last = [string]$last
    Save-DeviceState $state $device
    if ((Get-Now) -ge $deadline) { break }
  }
  Say "`nStill waiting for approval. Once it's approved, run this command again."
  return 3
}

$ScriptPattern = 'contextlocker[/\\]+sync\.(sh|ps1)'

# Whether a settings file has a session-start hook that runs this script: a
# SessionStart command in a JSON file, or in Codex's config.toml. Mentions
# elsewhere, such as a permission rule that names the script, don't count.
function Test-RunsScript([string]$Text) { return ($Text -match $ScriptPattern) -or $Text.Contains($Installed) }

function Test-HookIn([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
  $text = [IO.File]::ReadAllText($Path)
  if ($Path.EndsWith('.toml')) {
    # [[hooks.SessionStart]] tables, up to the next table for another event
    $start = $false
    foreach ($line in ($text -split '\r?\n')) {
      if ($line -match '^\s*\[\[?hooks\.(\w+)') { $start = ($Matches[1] -eq 'SessionStart') }
      elseif ($start -and $line -match '^\s*command(_windows|Windows)?\s*=' -and (Test-RunsScript $line)) { return $true }
    }
    return $false
  }
  try { $settings = $text | ConvertFrom-Json } catch { return $false }
  foreach ($group in @(Get-Property (Get-Property $settings 'hooks') 'SessionStart')) {
    foreach ($hook in @(Get-Property $group 'hooks')) {
      $words = @((Get-Field $hook 'command'), (Get-Field $hook 'commandWindows')) + @(Get-Property $hook 'args' | ForEach-Object { [string]$_ })
      if (Test-RunsScript ($words -join ' ')) { return $true }
    }
  }
  return $false
}

function ConvertTo-JsonText([string]$Text) { return '"' + (($Text -replace '\\', '\\') -replace '"', '\"') + '"' }

function Write-HookJson([string]$App) {
  if ($OnWindows -and $App -eq 'claude-code') {
    # Claude Code runs a command and its arguments directly, with no shell
    $argList = (@($RunArgs + $App) | ForEach-Object { ConvertTo-JsonText $_ }) -join ', '
    $hook = "{ `"type`": `"command`", `"command`": `"powershell.exe`", `"args`": [$argList], `"timeout`": 60 }"
  } else {
    $command = ConvertTo-JsonText "$Run $App"
    $windows = if ($OnWindows) { ", `"commandWindows`": $command" } else { '' }
    $hook = "{ `"type`": `"command`", `"command`": $command$windows, `"timeout`": 60 }"
  }
  Say "    {`n      `"hooks`": {`n        `"SessionStart`": [`n          {`n            `"hooks`": [`n              $hook`n            ]`n          }`n        ]`n      }`n    }"
}

# Daily jobs run at a minute past 9 that comes from this computer's id, so
# computers don't all sync at once. Reading the id never creates it.
function Get-JobMinute {
  $id = Get-MachineId -Saved
  if (-not $id) { $id = Get-Sha256Text ([Environment]::MachineName) }
  return ([Convert]::ToInt32($id.Substring(0, 4), 16) % 60)
}

function Write-HookPlan {
  switch ($Harness) {
    'claude-code' {
      $settings = Join-Path (Get-RootDir 'claude') 'settings.json'
      if (Test-HookIn $settings) { Say "Session start: the hook is already in $settings." }
      else {
        Say "Session start: add this hook to $settings, keeping everything already in the file. Claude Code may ask you to approve the edit:`n"
        Write-HookJson $Harness
      }
    }
    'codex' {
      $dir = Get-RootDir 'codex'
      if ((Test-HookIn (Join-Path $dir 'hooks.json')) -or (Test-HookIn (Join-Path $dir 'config.toml'))) { Say "Session start: the hook is already set up in $dir." }
      else {
        Say "Session start: add this hook to $(Join-Path $dir 'hooks.json'), after any hooks already there. Codex skips a new hook until you trust it in /hooks:`n"
        Write-HookJson $Harness
      }
    }
    'hermes' {
      $command = if ($OnWindows) { "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$Installed`" hermes -Daily" } else { "$Run hermes -Daily" }
      Say "Daily job: save this as $(Join-Path (Join-Path (Get-RootDir 'hermes') 'scripts') 'contextlocker-sync.sh'), the script Hermes runs:`n"
      Say "    #!/bin/sh`n    exec $command`n"
      Say "Then add a daily job that runs it with no model call. From this chat, use your cron tool with no agent, the script contextlocker-sync.sh and the name contextlocker-daily. Or run:`n"
      Say "    hermes cron create `"$(Get-JobMinute) 9 * * *`" --no-agent --script contextlocker-sync.sh --name contextlocker-daily --deliver origin`n"
      Say 'It stays quiet when the sync works, and tells you when it fails.'
    }
    'openclaw' {
      $shell = if ($OnWindows) { ' in PowerShell' } else { '' }
      Say "Daily job: add an OpenClaw automation that runs the sync with no model call. Run this$shell on the computer where the OpenClaw gateway runs:`n"
      $add = "openclaw cron add --name contextlocker-daily --cron `"$(Get-JobMinute) 9 * * *`""
      if ($OnWindows) {
        # --command runs through sh, which Windows doesn't have, so give the
        # program and its arguments exactly. Windows PowerShell, and a .cmd
        # launcher, drop the quotes inside an argument unless they're \"
        $argv = '[' + ((@('powershell.exe') + $RunArgs + @('openclaw', '-Daily') | ForEach-Object { ConvertTo-JsonText $_ }) -join ',') + ']'
        Say "    `$job = '$($argv -replace "'", "''")'"
        Say "    if (`$PSVersionTable.PSVersion.Major -lt 7 -or (Get-Command openclaw).Path -match '\.(cmd|bat)`$') { `$job = `$job.Replace('`"', '\`"') }"
        Say "    $add --command-argv `$job`n"
      } else {
        Say "    $add --command $(ConvertTo-ShellText "$Run openclaw -Daily")`n"
      }
      Say 'It stays quiet when the sync works, and posts the problem to your usual chat when it fails. With more than one chat set up, add --channel and the chat to use.'
    }
  }
}

# What's already there that setup leaves alone
function Write-ExistingFiles {
  $found = $false
  $skillsRoot = Join-Path (Get-RootDir 'agents') 'skills'
  switch ($Harness) {
    'claude-code' {
      $root = Get-RootDir 'claude'
      $claudeMd = Join-Path $root 'CLAUDE.md'
      if (Test-Path -LiteralPath $claudeMd -PathType Leaf) {
        Say "- Your own instructions in $claudeMd. Claude Code reads them as well as Context Locker's file."
        $found = $true
      }
      $skillsRoot = Join-Path $root 'skills'
    }
    'codex' {
      $override = Join-Path (Get-RootDir 'codex') 'AGENTS.override.md'
      if ((Test-Path -LiteralPath $override -PathType Leaf) -and ([IO.File]::ReadAllText($override).Trim() -ne '')) {
        Say "- $override, which Codex reads instead of AGENTS.md, so Context Locker's block goes there."
        $found = $true
      }
    }
    'hermes' { $skillsRoot = Join-Path (Get-RootDir 'hermes') 'skills' }
  }
  $own = 0
  if (Test-Path -LiteralPath $skillsRoot -PathType Container) {
    foreach ($dir in @(Get-ChildItem -LiteralPath $skillsRoot -Directory -Force -ErrorAction SilentlyContinue)) {
      if ((Test-Path -LiteralPath (Join-Path $dir.FullName 'SKILL.md') -PathType Leaf) -and
        -not (Test-Path -LiteralPath (Join-Path $dir.FullName '.ctx-managed') -PathType Leaf)) { $own++ }
    }
  }
  if ($own -gt 0) {
    Say "- $(Get-Plural $own 'skill' 'skills') of your own in $skillsRoot."
    $found = $true
  }
  if (-not $found) { Say '- Nothing.' }
}

function Invoke-Plan {
  $result = Sync-Scope '' (Join-Path $AppDir 'global')
  if ($result -ne 0) {
    foreach ($line in $Script:Warnings) { [Console]::Error.WriteLine($line) }
    return 1
  }
  Say "Setup plan for $AppName on this computer. Nothing has changed yet.`n`nFiles:"
  foreach ($line in $Script:PlanOut) { Say "- $line" }
  Say ''
  Write-HookPlan
  Say "`nAlready here, and left as it is:"
  Write-ExistingFiles
  Say "`nIf this looks right, approve it once. Then:"
  if (-not (Test-Path -LiteralPath $Installed -PathType Leaf)) { Say "- Save this script as $Installed." }
  Say "- Write the files: $Run $Harness"
  Say "- Add the $Trigger shown above."
  Say "- Check everything: $Run doctor $Harness"
  return 0
}

# Runs another program, never stopping on what it writes to stderr
function Invoke-Native([string]$Command, [string[]]$Arguments) {
  $ErrorActionPreference = 'Continue'
  $output = ''
  $code = 1
  try {
    $output = (& $Command @Arguments 2>$null | Out-String)
    $code = $LASTEXITCODE
  } catch { }
  return @{ Output = $output; Code = $code }
}

# "2026-10-18T09:05:00Z" as "18 Oct 2026 at 09:05 UTC"
function Format-Time([string]$Text) {
  if ($Text -notmatch '^(\d{4})-(\d{2})-(\d{2})T(\d{2}:\d{2})') { return $Text }
  $month = [int]$Matches[2]
  if ($month -lt 1 -or $month -gt 12) { return $Text }
  $name = @('Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec')[$month - 1]
  return "$([int]$Matches[3]) $name $($Matches[1]) at $($Matches[4]) UTC"
}

function Invoke-Doctor {
  $Script:Fails = 0
  $Script:Warns = 0
  function Pass([string]$Text) { Say "PASS  $Text" }
  function Warning([string]$Text) { Say "WARN  $Text"; $Script:Warns++ }
  function Fail([string]$Text) { Say "FAIL  $Text"; $Script:Fails++ }

  if (-not (Test-Path -LiteralPath $Installed -PathType Leaf)) {
    Fail "The sync script isn't at $Installed, where the $Trigger runs it. Save it there."
  } else {
    $installedVersion = ''
    foreach ($line in [IO.File]::ReadAllLines($Installed)) {
      if ($line -match '^\$ScriptVersion = (\d+)$') { $installedVersion = $Matches[1]; break }
    }
    if ($installedVersion -eq [string]$ScriptVersion) { Pass "The sync script is at $Installed." }
    else {
      $shown = if ($installedVersion) { $installedVersion } else { 'unknown' }
      Warning "The sync script at $Installed is version $shown, and this one is version $ScriptVersion."
    }
  }

  $connected = $false
  $problem = Get-TokenProblem
  if ($problem) {
    Fail "$problem Run: $Run signin $Harness"
  } else {
    if (-not $OnWindows) {
      $item = Get-Item -LiteralPath $TokenFile -Force
      if ($item.PSObject.Properties['UnixMode'] -and $item.UnixMode -notmatch '^-rw-------') {
        Warning "Other accounts on this computer can read $TokenFile. Run: chmod 600 $(ConvertTo-ShellText $TokenFile)"
      }
    }
    $reply = Invoke-Api 'GET' '/v1/agent' $null '' @{}
    if ($reply.Status -eq 200) { $connected = $true; Pass "Connected: $(Get-ConnectedAs $reply.Body)." }
    elseif ($reply.Status -eq 401) { Fail "This computer's connection was revoked or has expired. Run: $Run signin $Harness" }
    elseif ($reply.Status -eq 0) { Fail "Can't reach Context Locker at $Api." }
    else { Fail "Context Locker answered $($reply.Status) when asked about this connection." }
  }

  $lock = Join-Path $AppDir 'global.lock'
  $lockLines = @()
  if (Test-Path -LiteralPath $lock -PathType Leaf) { $lockLines = @([IO.File]::ReadAllLines($lock)) }
  $synced = ''
  $etag = ''
  foreach ($line in $lockLines) {
    if (-not $synced -and $line.StartsWith('synced ')) { $synced = Format-Time $line.Substring(7) }
    if ($line -match '^etag ([0-9a-f]{64})$') { $etag = $Matches[1] }
  }
  if (-not $synced) {
    Fail "Nothing has synced yet. Run: $Run $Harness"
  } else {
    if (-not $etag) { Warning "The last sync didn't finish ($synced). The next one tries again." }
    elseif ($connected) {
      $reply = Invoke-Api 'GET' '/v1/sync' $null '' @{ 'If-None-Match' = "`"$etag`"" }
      if ($reply.Status -eq 304) { Pass "The files match your playbook. Last synced $synced." }
      elseif ($reply.Status -eq 200) { Warning "Your playbook has changed since the last sync ($synced). The next sync brings the files up to date." }
      else { Warning "Couldn't compare the files with your playbook: Context Locker answered $($reply.Status)." }
    }
    $blocks = 0
    $skills = 0
    foreach ($line in $lockLines) {
      $f = $line.Split(' ')
      if ($f[0] -ne 'wrote' -or $f.Length -lt 4) { continue }
      $path = Resolve-Target $f[3]
      if (-not $path) { continue }
      if ($f[1] -eq 'skill') {
        if (Test-Path -LiteralPath (Join-Path $path '.ctx-managed') -PathType Leaf) { $skills++ }
        else { Warning "The skill at $path is missing. The next sync adds it again." }
        continue
      }
      if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { Warning "$path is missing. The next sync writes it again."; continue }
      $lines = Get-Lines (Read-Text $path)
      $pos = Get-BlockPosition $lines
      if ($pos -eq 'none') { Warning "Context Locker's block is missing from $path. The next sync adds it again." }
      elseif ($pos -eq 'broken') { Fail "The Context Locker markers in $path don't pair up, so syncs leave the file alone until someone fixes it by hand." }
      elseif ((Get-Sha256Text (Get-BlockText $lines $pos)) -eq $f[2]) { $blocks++ }
      else { Warning "Context Locker's block in $path has an edit that isn't in your playbook. It goes to Context Locker at the next sync, if it hasn't already." }
    }
    if ($skills -gt 0) { Pass "$(Get-Plural $blocks 'block' 'blocks') and $(Get-Plural $skills 'skill' 'skills') in place." }
    elseif ($blocks -gt 0) { Pass "$(Get-Plural $blocks 'block' 'blocks') in place." }
  }

  switch ($Harness) {
    'claude-code' {
      $settings = Join-Path (Get-RootDir 'claude') 'settings.json'
      if (Test-HookIn $settings) { Pass "The session-start hook is in $settings." }
      else { Fail "The session-start hook isn't in $settings. Run: $Run plan $Harness, and add the hook it shows." }
    }
    'codex' {
      $dir = Get-RootDir 'codex'
      if ((Test-HookIn (Join-Path $dir 'hooks.json')) -or (Test-HookIn (Join-Path $dir 'config.toml'))) {
        Pass "The session-start hook is set up in $dir. Codex runs it once you've trusted it in /hooks."
      } else {
        Fail "The session-start hook isn't in $(Join-Path $dir 'hooks.json'). Run: $Run plan $Harness, and add the hook it shows."
      }
    }
    'hermes' {
      $wrapper = Join-Path (Join-Path (Get-RootDir 'hermes') 'scripts') 'contextlocker-sync.sh'
      if ((Test-Path -LiteralPath $wrapper -PathType Leaf) -and (Test-RunsScript ([IO.File]::ReadAllText($wrapper)))) { Pass "The daily job's script is at $wrapper." }
      else { Fail "The daily job's script isn't at $wrapper. Run: $Run plan $Harness, and save the script it shows." }
      # `hermes cron list --all` prints a paragraph per job: its id and state
      # ([active], [paused], ...), then lines such as "Script: <name>"
      if (-not (Get-Command hermes -ErrorAction SilentlyContinue)) {
        Warning "The hermes command isn't on this account's PATH, so the daily job wasn't checked."
      } else {
        $listed = Invoke-Native 'hermes' @('cron', 'list', '--all')
        $plain = $listed.Output -replace "$([char]27)\[[0-9;]*m", ''
        $jobs = @($plain -split '(?:\r?\n){2,}' | Where-Object { $_ -match 'contextlocker-sync\.sh' })
        if ($listed.Code -ne 0) { Warning "Couldn't list Hermes's jobs, so the daily job wasn't checked." }
        elseif ($jobs.Count -eq 0) { Fail "Hermes has no job that runs contextlocker-sync.sh. Run: $Run plan $Harness, and add the job it shows." }
        elseif (@($jobs | Where-Object { $_ -match '\[active\]' }).Count -gt 0) { Pass 'Hermes has a job that runs contextlocker-sync.sh.' }
        else {
          $id = Get-Clean (($jobs[0].Trim() -split '\s+')[0])
          Warning "Hermes's job that runs contextlocker-sync.sh is paused or turned off. Run: hermes cron resume $id"
        }
        if ($listed.Code -eq 0 -and $plain -match 'Scheduler is not ready') {
          Warning "Hermes says its scheduler isn't running, so the daily job won't run. Run: hermes cron status"
        }
      }
    }
    'openclaw' {
      # Without --all, OpenClaw lists only the jobs that are turned on
      $ours = "contextlocker-daily|$ScriptPattern"
      if (-not (Get-Command openclaw -ErrorAction SilentlyContinue)) {
        Warning "The openclaw command isn't on this account's PATH, so the daily job wasn't checked."
      } else {
        $listed = Invoke-Native 'openclaw' @('cron', 'list', '--json')
        if ($listed.Code -ne 0) { Warning "Couldn't list OpenClaw's jobs. Is its gateway running?" }
        elseif ($listed.Output -match $ours) { Pass 'OpenClaw has a job that runs the sync.' }
        elseif ((Invoke-Native 'openclaw' @('cron', 'list', '--all', '--json')).Output -match $ours) {
          Warning "OpenClaw's job that runs the sync is turned off. Turn it back on in OpenClaw."
        }
        else { Fail "OpenClaw has no job that runs the sync. Run: $Run plan $Harness, and add the job it shows." }
      }
    }
  }

  if ($Script:Fails -gt 0) {
    Say "`n$(Get-Plural $Script:Fails 'problem' 'problems') to fix."
    return 1
  }
  if ($Script:Warns -gt 0) { Say "`nWorking, with $(Get-Plural $Script:Warns 'warning' 'warnings')." }
  else { Say "`nAll checks passed." }
  return 0
}

function Invoke-Readback {
  $lock = Join-Path $AppDir 'global.lock'
  $wrote = @()
  if (Test-Path -LiteralPath $lock -PathType Leaf) {
    $wrote = @([IO.File]::ReadAllLines($lock) | Where-Object { $_ -match '^wrote (block|skill) [0-9a-f]{64} \S+$' })
  }
  if ($wrote.Count -eq 0) { Say "Nothing has synced to $AppName on this computer yet."; return 1 }
  Say "What Context Locker has put in $AppName's files on this computer:"
  foreach ($line in $wrote) {
    $f = $line.Split(' ')
    if ($f[1] -ne 'block') { continue }
    $path = Resolve-Target $f[3]
    if (-not $path -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
    $lines = Get-Lines (Read-Text $path)
    $pos = Get-BlockPosition $lines
    if ($pos -eq 'none' -or $pos -eq 'broken') { continue }
    $s, $e = $pos.Split(' ') | ForEach-Object { [int]$_ }
    Say "`nIn ${path}:`n"
    for ($i = $s; $i -le $e - 2; $i++) { Say ($lines[$i].TrimEnd("`r")) }
  }
  $skillLines = @($wrote | Where-Object { $_.Split(' ')[1] -eq 'skill' })
  if ($skillLines.Count -gt 0) { Say "`nSkills:" }
  foreach ($line in $skillLines) {
    $t = $line.Split(' ')[3]
    $path = Resolve-Target $t
    if (-not $path -or -not (Test-Path -LiteralPath (Join-Path $path '.ctx-managed') -PathType Leaf)) { continue }
    $about = ''
    $skillMd = Join-Path $path 'SKILL.md'
    if (Test-Path -LiteralPath $skillMd -PathType Leaf) {
      foreach ($l in [IO.File]::ReadAllLines($skillMd)) { if ($l -match '^description:\s*(.*)$') { $about = Get-Clean $Matches[1]; break } }
    }
    $name = $t.Substring($t.LastIndexOf('/') + 1)
    if ($about) { Say "- $name, in ${path}: $about" } else { Say "- $name, in $path" }
  }
  return 0
}

# --- Run ------------------------------------------------------------------

if ($Mode -ne 'sync') {
  $exitCode = 1
  try {
    switch ($Mode) {
      'signin' { $exitCode = Invoke-Signin }
      'plan' { $exitCode = Invoke-Plan }
      'doctor' { $exitCode = Invoke-Doctor }
      'readback' { $exitCode = Invoke-Readback }
    }
  } catch {
    [Console]::Error.WriteLine("Context Locker: $($_.Exception.Message)")
    $exitCode = 1
  } finally {
    Remove-Item -LiteralPath $Tmp -Recurse -Force -ErrorAction SilentlyContinue
  }
  $Script:Stdout.Flush()
  exit $exitCode
}

try {
  $globalOk = Sync-Scope '' (Join-Path $AppDir 'global')

  if (-not $Daily) {
    if ($Project) { Set-ProjectLink }
    if (-not $Script:WorkspaceId) {
      $globalLock = Join-Path $AppDir 'global.lock'
      if (Test-Path -LiteralPath $globalLock) {
        foreach ($line in [IO.File]::ReadAllLines($globalLock)) {
          if ($line -match '^entry workspace ([0-9a-f-]{36})$') { $Script:WorkspaceId = $Matches[1] }
        }
      }
    }
    if (Find-Project) {
      if ($globalOk -eq 0) {
        $Script:Scope = 'project'
        $result = Sync-Scope "?project=$($Script:ProjectId)&layer=$($Script:Layer)" (Join-Path (Join-Path $AppDir 'projects') $Script:ProjectId)
        if ($result -eq 3 -and $Script:Layer -eq 'personal') { Remove-ProjectLink $Script:ProjectId }
      }
    }
  }
} catch {
  Warn "sync stopped: $($_.Exception.Message)"
  $Script:Failed = $true
} finally {
  if ($HaveLock) { Remove-Item -LiteralPath $Lock -Recurse -Force -ErrorAction SilentlyContinue }
  Remove-Item -LiteralPath $Tmp -Recurse -Force -ErrorAction SilentlyContinue
}

# What the app reads at the start of a session: a line about changes waiting
# for the owner, then a project's preferences when they aren't in the repo
$contextParts = New-Object System.Collections.Generic.List[string]
$globalContext = Join-Path $AppDir 'global.context'
if (Test-Path -LiteralPath $globalContext -PathType Leaf) { $contextParts.Add((Read-Text $globalContext)) }
if ($Script:ProjectId) {
  $candidate = Join-Path (Join-Path $AppDir 'projects') "$($Script:ProjectId).context"
  if (Test-Path -LiteralPath $candidate -PathType Leaf) { $contextParts.Add((Read-Text $candidate)) }
}
$context = $contextParts -join "`n"

if ($Daily) {
  if ($Script:Failed) {
    foreach ($line in $Script:Warnings) { [Console]::Out.WriteLine($line) }
    exit 1
  }
  exit 0
}

foreach ($line in $Script:Warnings) { [Console]::Error.WriteLine($line) }

if ($Harness -eq 'claude-code' -and ($Script:SkillsChanged -or $context)) {
  $output = [ordered]@{ hookEventName = 'SessionStart' }
  if ($context) { $output['additionalContext'] = $context }
  if ($Script:SkillsChanged) { $output['reloadSkills'] = $true }
  Write-Out ((@{ hookSpecificOutput = $output } | ConvertTo-Json -Compress -Depth 4) + "`n")
} elseif ($context) {
  Write-Out $context
}
$Script:Stdout.Flush()
exit 0
