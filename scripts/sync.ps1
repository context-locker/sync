# Context Locker sync, version 43. MIT licence.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File sync.ps1 <app> [-Project <id>] [-Now] [-Hook] [-Daily]
#   powershell -NoProfile -ExecutionPolicy Bypass -File sync.ps1 map <app> [-All]
#   powershell -NoProfile -ExecutionPolicy Bypass -File sync.ps1 import <app>
#   powershell -NoProfile -ExecutionPolicy Bypass -File sync.ps1 import-submit <app> <plan.json>
#   powershell -NoProfile -ExecutionPolicy Bypass -File sync.ps1 keep <app> <file or folder>
#   powershell -NoProfile -ExecutionPolicy Bypass -File sync.ps1 export <app> [-To <folder>]
#   powershell -NoProfile -ExecutionPolicy Bypass -File sync.ps1 notes-move-out <app> -To <folder>
#   powershell -NoProfile -ExecutionPolicy Bypass -File sync.ps1 fix <app> [-All]
#   powershell -NoProfile -ExecutionPolicy Bypass -File sync.ps1 fix <app> -Done <id> | -Skip <id> -Reason <text> | -Working <id> [-Recap <text>]
#   powershell -NoProfile -ExecutionPolicy Bypass -File sync.ps1 signin <app> [-Code <code>] [-Environment computer|cloud]
#   powershell -NoProfile -ExecutionPolicy Bypass -File sync.ps1 plan|doctor|readback|daily-job <app>
#   powershell -NoProfile -ExecutionPolicy Bypass -File sync.ps1 prompt <app>
#   powershell -NoProfile -ExecutionPolicy Bypass -File sync.ps1 update <app>
#   powershell -NoProfile -ExecutionPolicy Bypass -File sync.ps1 remove <app> [-Yes]
#   powershell -NoProfile -ExecutionPolicy Bypass -File sync.ps1 tickets <app> list|read|write|places [request.json] [-Project <id>] [-Json]
#   powershell -NoProfile -ExecutionPolicy Bypass -File sync.ps1 notes <app> search|read|write <request.json> [-Project <id>] [-Json]
#   powershell -NoProfile -ExecutionPolicy Bypass -File sync.ps1 suggest <app> <request.json> [-Json]
#   powershell -NoProfile -ExecutionPolicy Bypass -File sync.ps1 remember <app> <request.json> [-Json]
#   powershell -NoProfile -ExecutionPolicy Bypass -File sync.ps1 message <app> <request.json> [-Json]
#
# Keeps one AI app's files in step with your playbook at context.locker. <app>
# is claude-code, codex, hermes or openclaw. The script asks for a manifest of
# what the app's files should hold, writes only what changed, and sends any
# edit it finds in a synced file back to Context Locker. It writes only inside
# Context Locker's marked blocks, skill folders, a project's notes folder and,
# once the person brings them in, the app's own memory files, backs up
# anything it replaces that it didn't write, and never deletes a file of
# yours, but for a memory file whose note the person archived in Context
# Locker, after a backup. Once the person picks from the app's import, it
# also takes what they picked out of the app's own files, after a backup.
# When Context Locker can't be reached, or the connection no longer works,
# the app keeps the files it has, and its session start says why, from when
# its files are and what to offer the person. A skill the app also gets
# elsewhere, such as from a plugin, is listed once: Context Locker's copy is
# left out while the two are the same, and the session start says once when
# they differ.
#
# In a project, the notes folder, .context-locker/notes, holds the project's
# notes and, in everywhere/, the ones that apply everywhere, one Markdown
# file each. An edited note or a new .md file there goes to Context Locker
# at the next sync, and git leaves the folder out. The sync also checks that
# the project's pointers to paths in its repo are there.
#
# The app's own memory files, such as Claude Code's memory folders or
# Hermes's SOUL.md outside Context Locker's block, sync both ways with its
# connection's memory in Context Locker once the person brings them in.
# Until then, the sync tells Context Locker once what it found, which asks
# the person, and leaves the files as they are.
#
# The project is the one -Project names; else the one a .contextlocker.json
# in the repo names; else a folder linked on the computer; else the project
# whose git remote is the repo's origin, which links the folder.
#
# Each app runs the sync on its own events, such as the start of a session
# and compaction, as the table under "When each app syncs" lists. With auto
# sync on, the default, a sync brings in what changed and says so in a line.
# With it off, a sync that finds changes says so and leaves the files as they
# are until the app syncs with -Now. A project can have its own setting.
#
# -Project <id> links the current folder to a project, for the computer
#               only, and records the repo's origin remote on the project
#               when it has none.
# -Now          syncs even when auto sync is off.
# -Hook         is for an app's hook, and prints only what that app's hook
#               reads.
# -Daily        is for the daily job in Hermes's or OpenClaw's own
#               scheduler: silent when all is well, exit 1 when not. It
#               syncs the projects linked on the computer too, keeps to
#               auto sync off, and tells Context Locker the run finished, or
#               why it failed, for the connection's page.
#
# map prints the project's map: its docs home, its Start here entries, the
# notes and pointers that matter in the current folder (every one with -All)
# and the newest of the rest. A pointer stands in for a note kept somewhere
# else, such as a file in the repo, and says where.
#
# import copies what this app already knows on the computer, its own
# instructions, skills and memories and the project's instruction files it
# reads, never another app's, into a working set only this account can read,
# for the Import skill to sort into one plan. It only reads the files, never
# changes or deletes them, follows no link in their folders and lists every
# one it skipped, and never copies anything that looks like a secret.
# import-submit sends the plan to Context Locker, where the person picks from
# it, then deletes Import's working sets. Once they pick, the next sync takes
# what they picked out of the app's own files, where its lines are still as
# imported, after a backup, and lists the lines to take out of a file in a
# code repository instead. gather and gather-submit, their names before, still
# work, and -Apps, which picked other apps' files, is left unused.
#
# keep is the person's answer when the doctor asks about a file, or a folder
# of memories, with lines outside Context Locker: they stay in the app only,
# and the doctor asks about them again only once something in them is new
# or changed. The other answer is Import, and what an Import read counts the
# same way once its plan is in. The answers stay on the computer.
#
# export downloads everything in the playbook, as plain files with the
# history as JSON Lines, into a new folder, "Context Locker export <date>" in
# the current one unless -To names another. It never writes into a folder
# that already holds anything.
#
# notes-move-out moves the project's notes out of Context Locker into a
# folder in its repo that -To names: it writes each note there as a Markdown
# file, never over a file, and only then asks Context Locker to turn each one
# into a pointer to its file, with the same id, and to make the folder the
# project's docs home. The folder must be inside the project, outside
# .context-locker, and reached through no link. The notes that apply
# everywhere stay.
#
# fix prints Tidy-up, the upkeep the playbook needs, such as a preference
# nobody has touched in 90 days, each item with its id, the evidence, a fix
# and its risk: the project's and the ones that apply everywhere, or the
# whole playbook's with -All or outside a project. Once an item is fixed,
# -Done <id> marks it done, and Context Locker checks it again at once.
# -Skip <id> -Reason <text> leaves it for the person, with the reason.
# -Working <id> says the app has started on a request or an ask, which the
# person's inbox shows, with what it's doing if -Reason says. -Recap <text>
# with any of them gives the recap the request's row shows: what's now true,
# then what's not done or not checked. -Waiting <id> -Reason <question> with
# 2 to 4 --choice <label> asks the person a question back, which they answer
# in one press, or with something else, and the answer comes back in fix.
#
# update takes the newest sync script, once the person says yes, when Context
# Locker says this one can. It downloads it from where setup publishes it, at
# context.locker/setup, checks its SHA-256 against the one Context Locker
# gives, that it's the version it says and that PowerShell can read it, keeps
# this one beside it as sync.ps1.previous and puts the new one in its place.
# It changes nothing else. When the newest script needs more than the script,
# such as a new hook, it says to set Context Locker up again instead.
#
# For setup (see context.locker/setup):
#   signin    connects the app with a code you approve in your browser. The
#             first run prints the link and the code and exits 3. Run it again
#             to wait up to -Wait seconds (50) for the approval: it exits 0
#             once connected, and 3 while still waiting. With -Code, it
#             connects with a one-time code the person made in Context Locker
#             instead, with nothing to approve, and exits 0 once connected. In
#             Claude in Cowork, which gets Context Locker from the person's
#             Claude account connector, it stops with exit 1 unless
#             -Environment cloud says to connect the sandbox on purpose.
#   plan      shows what a sync would write, and the hooks to add. It changes
#             nothing.
#   doctor    checks the connection, the files, the hooks and the daily job,
#             how full the playbook's limits are, and anything that has
#             drifted since the last sync, and asks about instruction and
#             memory files Context Locker doesn't manage. It tells Context
#             Locker how the app runs the sync, for the connection's page. It
#             exits 1 when a check fails.
#   daily-job adds a daily job to Hermes's or OpenClaw's own scheduler that
#             runs the sync once a day, with no model call, once the person
#             says yes. One that's there already stays as it is. Claude Code
#             and Codex can't run one in the background.
#   readback  prints what Context Locker has put in the app's files
#   remove    takes Context Locker off the computer for the app, once the
#             person says yes: the hook that runs the sync, the files the
#             sync wrote that are still as it wrote them, and the app's folder
#             here, with the shared script once no other app uses it. Without
#             -Yes it only says what it would take out. It never revokes or
#             deletes the connection in Context Locker, and keeps the backups.
#
# The same steps as sync.sh, for Windows PowerShell 5.1 and PowerShell 7.
# sync.sh's spellings of the options (--daily, --now, --hook, --project,
# --wait, --all, --to, --done, --skip, --reason, --code, --apps, --environment
# and --yes) work too.
param(
  [Parameter(Position = 0)][string]$First = '',
  [Parameter(Position = 1)][string]$Second = '',
  [string]$Project = '',
  [switch]$Daily,
  [switch]$Now,
  [switch]$Hook,
  [switch]$All,
  [switch]$Json,
  [int]$Wait = 50,
  [string]$To = '',
  [string]$Done = '',
  [string]$Skip = '',
  [string]$Reason = '',
  [string]$Recap = '',
  [string]$Waiting = '',
  [string]$Working = '',
  [string]$AllowAutoApprove = '',
  [string]$Request = '',
  [int]$Offset = 0,
  [string]$Code = '',
  [string]$Apps = '',
  [string]$Environment = '',
  [switch]$Yes,
  [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest = @()
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$ScriptVersion = 47
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
if (@('signin', 'plan', 'doctor', 'readback', 'map', 'gather', 'gather-submit', 'keep', 'export', 'notes-move-out', 'fix', 'daily-job', 'update', 'remove', 'tickets', 'requests', 'notes', 'suggest', 'remember', 'message', 'prompt') -contains $First) {
  $Mode = $First
  $Harness = $Second
} elseif (@('import', 'import-submit') -contains $First) {
  # Import, called gather before
  $Mode = 'gather' + $First.Substring(6)
  $Harness = $Second
} elseif ($Second) {
  $Harness = ''
}
# import-submit's plan, and the file or folder to keep, come before any option
$TicketCommand = 'list'
$TicketFile = ''
if (($Mode -eq 'tickets' -or $Mode -eq 'requests' -or $Mode -eq 'notes') -and $extra.Count -gt 0 -and -not $extra[0].StartsWith('-')) {
  $TicketCommand = $extra[0]
  $extra = @($extra | Select-Object -Skip 1)
  if ($extra.Count -gt 0 -and -not $extra[0].StartsWith('-')) {
    $TicketFile = $extra[0]
    $extra = @($extra | Select-Object -Skip 1)
  }
}
# suggest, remember and message take only their request: suggest a
# preference, a fact or a skill, remember one line as a fact or a preference
# (G1-245, G1-247), and write to other AI apps (G1-313)
if ($Mode -eq 'suggest' -or $Mode -eq 'remember' -or $Mode -eq 'message') {
  $TicketCommand = $Mode
  if ($extra.Count -gt 0 -and -not $extra[0].StartsWith('-')) {
    $TicketFile = $extra[0]
    $extra = @($extra | Select-Object -Skip 1)
  }
}
$PlanFile = ''
$KeepPath = ''
if (($Mode -eq 'gather-submit' -or $Mode -eq 'keep') -and $extra.Count -gt 0 -and -not $extra[0].StartsWith('-')) {
  if ($Mode -eq 'keep') { $KeepPath = $extra[0] } else { $PlanFile = $extra[0] }
  $extra = @($extra | Select-Object -Skip 1)
}
$badOption = $false
$ToSet = $PSBoundParameters.ContainsKey('To')
# fix's -Done or -Skip, with the item's id, and a skip's reason
$FixAs = ''
$FixId = ''
$FixMarks = 0
$ReasonSet = $PSBoundParameters.ContainsKey('Reason')
$RecapSet = $PSBoundParameters.ContainsKey('Recap')
# A question back's choices, from --choice, one line each (G1-272)
$Choices = New-Object System.Collections.Generic.List[string]
$AppsSet = $PSBoundParameters.ContainsKey('Apps')
if ($PSBoundParameters.ContainsKey('Done')) { $FixAs = 'done'; $FixId = $Done; $FixMarks++ }
if ($PSBoundParameters.ContainsKey('Skip')) { $FixAs = 'skipped'; $FixId = $Skip; $FixMarks++ }
$OffsetSet = $PSBoundParameters.ContainsKey('Offset')
if ($PSBoundParameters.ContainsKey('Waiting')) { $FixAs = 'waiting'; $FixId = $Waiting; $FixMarks++ }
if ($PSBoundParameters.ContainsKey('Working')) { $FixAs = 'working'; $FixId = $Working; $FixMarks++ }
if ($PSBoundParameters.ContainsKey('AllowAutoApprove')) { $FixAs = 'auto_approve_allowed'; $FixId = $AllowAutoApprove; $FixMarks++ }
if ($PSBoundParameters.ContainsKey('Request')) { $FixAs = 'read'; $FixId = $Request; $FixMarks++ }
for ($i = 0; $i -lt $extra.Count; $i++) {
  $option = $extra[$i]
  $value = if ($i + 1 -lt $extra.Count) { $extra[$i + 1] } else { '' }
  if ($option -eq '--daily') { $Daily = [switch]$true }
  elseif ($option -eq '--json') { $Json = [switch]$true }
  elseif ($option -eq '--now') { $Now = [switch]$true }
  elseif ($option -eq '--hook') { $Hook = [switch]$true }
  elseif ($option -eq '--all') { $All = [switch]$true }
  elseif ($option -eq '--project' -and $value) { $Project = $value; $i++ }
  elseif ($option -eq '--wait' -and $value -match '^\d+$') { $Wait = [int]$value; $i++ }
  elseif ($option -eq '--to' -and $value) { $To = $value; $ToSet = $true; $i++ }
  elseif ($option -eq '--done' -and $value) { $FixAs = 'done'; $FixId = $value; $FixMarks++; $i++ }
  elseif ($option -eq '--skip' -and $value) { $FixAs = 'skipped'; $FixId = $value; $FixMarks++; $i++ }
  elseif ($option -eq '--waiting' -and $value) { $FixAs = 'waiting'; $FixId = $value; $FixMarks++; $i++ }
  elseif ($option -eq '--working' -and $value) { $FixAs = 'working'; $FixId = $value; $FixMarks++; $i++ }
  elseif ($option -eq '--allow-auto-approve' -and $value) { $FixAs = 'auto_approve_allowed'; $FixId = $value; $FixMarks++; $i++ }
  elseif ($option -eq '--request' -and $value) { $FixAs = 'read'; $FixId = $value; $FixMarks++; $i++ }
  elseif ($option -eq '--offset' -and $value -match '^\d{1,9}$') { $Offset = [int]$value; $OffsetSet = $true; $i++ }
  elseif ($option -eq '--reason' -and $value) { $Reason = $value; $ReasonSet = $true; $i++ }
  elseif ($option -eq '--recap' -and $value) { $Recap = $value; $RecapSet = $true; $i++ }
  elseif ($option -eq '--choice' -and $value) { $Choices.Add(($value -replace '[\r\n]', ' ')); $i++ }
  elseif ($option -eq '--code' -and $value) { $Code = $value; $i++ }
  elseif ($option -eq '--apps' -and $value) { $Apps = $value; $AppsSet = $true; $i++ }
  elseif ($option -eq '--environment' -and $value) { $Environment = $value; $i++ }
  elseif ($option -eq '--yes') { $Yes = [switch]$true }
  else { $badOption = $true }
}
# -To is for export and notes-move-out, which needs it
$badTo = if ($Mode -eq 'export') { $ToSet -and -not $To } elseif ($Mode -eq 'notes-move-out') { -not $To } else { $ToSet }
# -Done and -Skip are for fix, one at a time, with an item's id; a skip needs
# its reason, and only a skip has one
$badFix = if ($Mode -ne 'fix') { ($FixMarks -gt 0) -or $ReasonSet -or $RecapSet -or ($Choices.Count -gt 0) }
elseif ($FixMarks -eq 0) { $ReasonSet -or $RecapSet -or ($Choices.Count -gt 0) }
# A question back has 2 to 4 choices, with -Waiting (G1-272)
elseif ($Choices.Count -gt 0 -and (($FixAs -ne 'waiting') -or ($Choices.Count -lt 2) -or ($Choices.Count -gt 4) -or @($Choices | Where-Object { -not $_.Trim() }).Count)) { $true }
# A recap goes with a reply, never a read (G1-270)
elseif ($RecapSet -and (($FixAs -eq 'read') -or -not $Recap.Trim())) { $true }
elseif ($FixMarks -gt 1 -or $All -or $FixId -cnotmatch $Uuid) { $true }
elseif (@('skipped', 'waiting', 'auto_approve_allowed') -contains $FixAs) { -not $Reason.Trim() }
elseif ($FixAs -eq 'working') { $false }
else { $ReasonSet }
if ($Offset -lt 0 -or ($OffsetSet -and $FixAs -ne 'read')) { $badFix = $true }
# -Code is for signin, with a one-time code from Context Locker
$badCode = $Code -and (($Mode -ne 'signin') -or ($Code -cnotmatch '^ctxl_ic_[A-Za-z0-9_-]{43}$'))
# -Environment is for signin, to say where the app runs (G1-260), and -Yes for
# remove, once the person has said yes
$badEnvironment = $Environment -and (($Mode -ne 'signin') -or (@('computer', 'cloud') -cnotcontains $Environment))
$badYes = $Yes -and ($Mode -ne 'remove')
# -Now and -Hook are for a sync
$badSync = ($Mode -ne 'sync') -and ($Now -or $Hook)
$badTickets = if ($Mode -eq 'tickets') {
  (@('list', 'read', 'write', 'places') -cnotcontains $TicketCommand) -or
  ($TicketCommand -ne 'list' -and -not $TicketFile) -or $All -or $Daily
} elseif ($Mode -eq 'requests') {
  (@('list', 'read', 'answer') -cnotcontains $TicketCommand) -or
  ($TicketCommand -ne 'list' -and -not $TicketFile) -or $All -or $Daily
} elseif ($Mode -eq 'notes') {
  (@('search', 'read', 'write') -cnotcontains $TicketCommand) -or -not $TicketFile -or $All -or $Daily
} elseif ($Mode -eq 'suggest' -or $Mode -eq 'remember' -or $Mode -eq 'message') {
  (-not $TicketFile) -or $All -or $Daily
} else { [bool]$Json }
# -Apps was for gather, to read some of every app's files (G1-11). Import
# reads only this app's own (G1-206), so it's taken and left unused
$badApps = $AppsSet -and ($Mode -ne 'gather')
if ($badOption -or $badTo -or $badFix -or $badCode -or $badEnvironment -or $badYes -or $badSync -or $badApps -or $badTickets -or (@('claude-code', 'codex', 'hermes', 'openclaw') -notcontains $Harness) -or $Wait -lt 0 -or ($Mode -eq 'gather-submit' -and -not $PlanFile) -or ($Mode -eq 'keep' -and -not $KeepPath)) {
  [Console]::Error.WriteLine('Decisions: sync.ps1 requests <app> list|read|answer [request.json] [-Json]')
  [Console]::Error.WriteLine('Tickets: sync.ps1 tickets <app> list|read|write|places [request.json] [-Project <id>] [-Json]. Use a UTF-8 JSON file with the corresponding MCP tool arguments. Only list may omit it.')
  # How to ask the user, as every app's instructions say (G1-277)
  [Console]::Error.WriteLine("Asks: Assume first: if a reasonable assumption settles an uncertainty, the result wouldn't change much and no preference says to ask, decide, do the work and record it with write_ticket's assumed. One decision per ask, one open ask per task: split compound uncertainties, asking first what unblocks most. Do the reading and attach the evidence; the user decides, never researches. Choices are outcomes, one recommended with why; for a yes or their own step, use kind approval or your_action. Finished work and news go on the task, never in an ask; nothing they must act on goes in a comment. Answer Something else with the work or a revised ask. After the same answer three times, suggest it as a preference.")
  [Console]::Error.WriteLine('Notes: sync.ps1 notes <app> search|read|write <request.json> [-Project <id>] [-Json], with search_notes, read_note or write_note arguments')
  [Console]::Error.WriteLine('Suggest: sync.ps1 suggest <app> <request.json> [-Json], with suggest arguments')
  [Console]::Error.WriteLine('Remember: sync.ps1 remember <app> <request.json> [-Json], with kind fact or preference, name, one line of text and a reason')
  [Console]::Error.WriteLine('Message: sync.ps1 message <app> <request.json> [-Json], with the apps by handle in to or the text, and the playbook, ticket or entry a new thread is about, or the thread to write on')
  [Console]::Error.WriteLine("Usage: sync.ps1 <app> [-Project <id>] [-Now] [-Hook] [-Daily]`n       sync.ps1 map <app> [-All]`n       sync.ps1 import <app>`n       sync.ps1 import-submit <app> <plan.json>`n       sync.ps1 keep <app> <file or folder>`n       sync.ps1 export <app> [-To <folder>]`n       sync.ps1 notes-move-out <app> -To <folder>`n       sync.ps1 fix <app> [-All]`n       sync.ps1 fix <app> -Done <id> | -Skip <id> -Reason <text> | -Working <id> [-Recap <text>]`n       sync.ps1 fix <app> -Waiting <id> -Reason <question> --choice <label> --choice <label> ...`n       sync.ps1 signin <app> [-Code <code>] [-Environment computer|cloud]`n       sync.ps1 plan|doctor|readback|daily-job <app>`n       sync.ps1 prompt <app>`n       sync.ps1 update <app>`n       sync.ps1 remove <app> [-Yes]`n<app> is claude-code, codex, hermes or openclaw.")
  exit 2
}
$AppName = @{ 'claude-code' = 'Claude Code'; 'codex' = 'Codex'; 'hermes' = 'Hermes'; 'openclaw' = 'OpenClaw' }[$Harness]
# Hermes's and OpenClaw's hooks don't read what a sync prints, and a daily
# job tells the person only of a failure, so what it finds is said at the
# next session start
$Quiet = ($Hook -and ($Harness -eq 'hermes' -or $Harness -eq 'openclaw')) -or $Daily
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
$Script:AgentsMdBytes = $null
$Script:GlobalBytes = $null
$Script:FoundBy = ''
$Script:LinksChecked = $null
$Script:MissingLinks = New-Object System.Collections.Generic.List[string]
$Script:GatherLock = ''
# Listing the app's own files, for what an import moves, and what it found (G1-208)
$Script:GatherList = $false
$Script:OwnFiles = $null
$Script:OwnFileSet = $null
# Whether the global sync's manifest says auto sync is off
$Script:AutoSyncOff = $false
# What this run changed in the app's files, for the line that says so
$Script:WBlocks = 0
$Script:WSkills = 0
$Script:WNotes = 0
# What the app should hear at the start of a session, beside its own text
$Script:Said = New-Object System.Collections.Generic.List[string]
# With auto sync off, whether a sync found changes it left for later
$Script:ChangesWaiting = $false
# Why the sync couldn't get Context Locker's answer, for the session start
# (G1-258)
$Script:Broken = ''
# Dates and times in one fixed form, whatever the computer's region
$Invariant = [Globalization.CultureInfo]::InvariantCulture
$Stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ', $Invariant)

function Warn([string]$Message) { $Script:Warnings.Add("Context Locker: $Message") }

# A session start or a prompt mustn't fail because of Context Locker; anything
# else reports it
function Stop-Early([string]$Message) {
  [Console]::Error.WriteLine("Context Locker: $Message")
  if ($Mode -eq 'sync' -and -not $Daily) { exit 0 }
  if ($Mode -eq 'prompt') { exit 0 }
  exit 1
}

# The computer's name, as the approval page shows it: the first of its names
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

# The computer's name in what the script says, or $Otherwise when it has
# none, such as 'its computer'. It never says "this computer", as the person
# may read it on another computer or their phone (G1-299).
function Get-Computer([string]$Otherwise) {
  $name = Get-MachineName
  if ($name) { return $name }
  return $Otherwise
}

# Setting Context Locker up again, which the app offers and does once the
# person says yes, rather than telling them to (G1-258). Windows PowerShell
# takes curl for its own command, so there it's curl.exe.
$Curl = if ($OnWindows) { 'curl.exe' } else { 'curl' }
$SetupSteps = "download the newest steps with ``$Curl -fsSL https://context.locker/setup/SKILL.md`` and follow them"
$ConnectOffer = "Offer to connect it again: once the person says yes, $SetupSteps, and give them the link and code the setup command prints."
# Taking Context Locker off the computer, which the app offers when the
# connection was revoked in Context Locker (G1-260)
function Get-RemoveOffer {
  return "Offer to take Context Locker off $(Get-Computer "$AppName's computer"): run ``$Run remove $Harness``, which says what it would take out and changes nothing, and only once the person says yes, run it again with ``-Yes``."
}

# The day of the last sync that got Context Locker's answer, such as
# "26 Oct 2026", from the global lock, or '' before the first
function Get-LastSyncDay {
  $lock = Join-Path $AppDir 'global.lock'
  if (-not (Test-Path -LiteralPath $lock -PathType Leaf)) { return '' }
  foreach ($line in [IO.File]::ReadAllLines($lock)) {
    if ($line -cmatch '^synced ([0-9]{4})-([0-9]{2})-([0-9]{2})T') {
      $month = [int]$Matches[2]
      if ($month -lt 1 -or $month -gt 12) { return '' }
      $names = @('Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec')
      return "$([int]$Matches[3]) $($names[$month - 1]) $($Matches[1])"
    }
  }
  return ''
}

# The session start's line when a sync can't get Context Locker's answer: why,
# since when the app's files are as they are, and what to offer the person,
# as what goes to stderr never reaches the app (G1-258). $Why is revoked,
# gone, unconnected, damaged, old, unreachable or the status Context Locker
# answered with.
function Get-BrokenLine([string]$Why) {
  $day = Get-LastSyncDay
  $files = if ($day) { "$AppName's files are as they were on $day" } else { 'nothing has synced yet' }
  switch ($Why) {
    # Revoked in Context Locker, so it offers to come off the computer, never
    # to set up again (G1-260)
    'revoked' { return "Context Locker: $AppName's connection on $(Get-Computer 'its computer') was revoked in Context Locker, so nothing syncs there any more, and $files. $(Get-RemoveOffer)" }
    'gone' { return "Context Locker: $AppName's connection on $(Get-Computer 'its computer') was revoked or has expired, so $files. $ConnectOffer" }
    'unconnected' { return "Context Locker: $AppName isn't connected on $(Get-Computer 'its computer'), so $files. $ConnectOffer" }
    'damaged' { return "Context Locker: the saved token for $AppName is damaged, so $files. $ConnectOffer" }
    'old' { return "Context Locker: this sync script is too old to read Context Locker's answers, so $files. Offer to set Context Locker up again for them: once they say yes, $SetupSteps." }
  }
  $reason = if ($Why -eq 'unreachable') { "can't reach Context Locker" } else { "Context Locker answered $Why" }
  return "Context Locker: $reason, so $files. The next sync tries again. If it keeps happening, offer to look into it with ``$Run doctor $Harness``."
}

# Says a line to the app at the start of its session, when the sync stops
# before it gets to say anything else: Claude Code reads the hook's JSON, and
# Codex what it prints (G1-258)
function Write-AtStart([string]$Line) {
  if ($Mode -ne 'sync' -or $Daily -or $Quiet) { return }
  if ($Harness -eq 'claude-code') {
    $text = (@{ hookSpecificOutput = [ordered]@{ hookEventName = 'SessionStart'; additionalContext = $Line } } | ConvertTo-Json -Compress -Depth 4) + "`n"
  } else {
    $text = "$Line`n"
  }
  $bytes = $Utf8.GetBytes($text)
  $out = [Console]::OpenStandardOutput()
  $out.Write($bytes, 0, $bytes.Length)
  $out.Flush()
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
# Where setup's files are published: update takes the newest script from
# there, and from nowhere else (G1-112)
$Site = if ($env:CONTEXT_LOCKER_SITE) { $env:CONTEXT_LOCKER_SITE } else { Read-Setting 'site' (Join-Path $ClHome 'config') }
if (-not $Site) { $Site = 'https://context.locker' }
$Site = $Site.TrimEnd('/')

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
    return "$AppName isn't connected on $(Get-Computer 'its computer'). Set it up at context.locker/setup."
  }
  if ($Script:Token -notmatch '^[A-Za-z0-9_-]+$') {
    return "the saved token for $AppName is damaged. Set it up again at context.locker/setup."
  }
  return ''
}
# The per-prompt hook's line (G1-271), said the way each app reads a hook:
# Claude Code its JSON, Hermes JSON with context, and Codex what it prints.
# It asks Context Locker at most once a minute, keeping when it last asked in
# the app's folder, so most prompts end here, and every way out is quiet.
# Switched off for the connection on its page in Connections (G1-298), it
# asks nothing: the app's folder keeps prompt-off from the last sync's
# manifest, or from Context Locker turning the hook away, until a sync says
# the line is on again.
function Write-PromptLine {
  $off = Join-Path $AppDir 'prompt-off'
  if (Test-Path -LiteralPath $off) { return }
  $asked = Join-Path $AppDir 'prompt-asked'
  $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
  $last = 0L
  if ((Test-Path -LiteralPath $asked -PathType Leaf) -and
    [long]::TryParse(([IO.File]::ReadAllText($asked)).Trim(), [ref]$last) -and
    $now -ge $last -and ($now - $last) -lt 60) { return }
  if (Get-TokenProblem) { return }
  if (-not (Test-Path -LiteralPath $AppDir -PathType Container)) { return }
  try { [IO.File]::WriteAllText($asked, "$now`n") } catch { return }
  # The app's own id for its session, from the JSON it hands its hook, which
  # a follow-up on an ask goes to (G1-273)
  $session = ''
  if ([Console]::IsInputRedirected) {
    $found = [regex]::Match([Console]::In.ReadToEnd(), '"session_id"\s*:\s*"([A-Za-z0-9._:-]{1,128})"')
    if ($found.Success) { $session = $found.Groups[1].Value }
  }
  $query = if ($session) { "?session=$session" } else { '' }
  $line = ''
  try {
    if ($PSVersionTable.PSVersion.Major -lt 6) { Add-Type -AssemblyName System.Net.Http }
    $client = New-Object System.Net.Http.HttpClient
    try {
      $client.Timeout = [TimeSpan]::FromSeconds(5)
      [void]$client.DefaultRequestHeaders.TryAddWithoutValidation('User-Agent', "context-locker-sync/$ScriptVersion ($Harness; powershell)")
      [void]$client.DefaultRequestHeaders.TryAddWithoutValidation('Authorization', "Bearer $($Script:Token)")
      $response = $client.GetAsync("$Api/v1/sync/prompt$query").GetAwaiter().GetResult()
      if ([int]$response.StatusCode -eq 200) {
        $line = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult().TrimEnd("`r", "`n")
      } elseif ([int]$response.StatusCode -eq 403 -and
        $response.Content.ReadAsStringAsync().GetAwaiter().GetResult().Contains('"prompt_line_off"')) {
        try { [IO.File]::WriteAllText($off, '') } catch { }
      }
    } finally { $client.Dispose() }
  } catch { return }
  if (-not $line) { return }
  $text = switch ($Harness) {
    'claude-code' { (@{ hookSpecificOutput = [ordered]@{ hookEventName = 'UserPromptSubmit'; additionalContext = $line } } | ConvertTo-Json -Compress -Depth 4) + "`n" }
    'hermes' { (@{ context = $line } | ConvertTo-Json -Compress) + "`n" }
    default { "$line`n" }
  }
  $bytes = $Utf8.GetBytes($text)
  $out = [Console]::OpenStandardOutput()
  $out.Write($bytes, 0, $bytes.Length)
  $out.Flush()
}
if ($Mode -eq 'prompt') {
  Write-PromptLine
  exit 0
}

if (@('sync', 'plan', 'map', 'gather', 'gather-submit', 'export', 'notes-move-out', 'fix', 'daily-job', 'update') -contains $Mode) {
  $problem = Get-TokenProblem
  if ($problem) {
    # The app hears of it at its session start too (G1-258)
    if ($Script:Token.StartsWith('ctxl_at_') -and $Script:Token.Length -gt 8) { Write-AtStart (Get-BrokenLine 'damaged') }
    else { Write-AtStart (Get-BrokenLine 'unconnected') }
    Stop-Early $problem
  }
}

# The global manifest names the newest sync script, and when this one can
# take it with update, where it's published and its SHA-256 (G1-112). A newer
# one than this gets a line at session start and in the doctor; nothing
# changes on its own. When more than the script changed, the app offers to
# set Context Locker up again, as it offers to update (G1-258).
$NewerLine = "a newer version of its sync script is out. When it suits the user, offer to set Context Locker up again for them: once they say yes, $SetupSteps. The one installed keeps working until then."
$Script:NewestScript = 0
# The newest script's lines: from this sync's answer when Context Locker gave
# one, as a sync with auto sync off can leave the lock as it was, or else
# from the last answer, in the lock (G1-258)
$Script:Answer = $null
function Get-ScriptLines {
  if ($null -ne $Script:Answer) { return $Script:Answer }
  $lock = Join-Path $AppDir 'global.lock'
  if (-not (Test-Path -LiteralPath $lock -PathType Leaf)) { return @() }
  return [IO.File]::ReadAllLines($lock)
}
function Test-NewerScript {
  foreach ($line in (Get-ScriptLines)) {
    if ($line -cmatch '^entry script ([0-9]{1,6})\z') {
      $Script:NewestScript = [int]$Matches[1]
      return ($Script:NewestScript -gt $ScriptVersion)
    }
  }
  return $false
}
# Whether this script can take the newest one with update, as the last sync
# heard
function Test-CanUpdate {
  foreach ($line in (Get-ScriptLines)) {
    if ($line -cmatch '^entry update [0-9a-f]{64} [0-9]{1,6}\z') { return $true }
  }
  return $false
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

# A computer that never had Context Locker has nothing to take off (G1-260)
if ($Mode -eq 'remove' -and -not (Test-Path -LiteralPath $ClHome)) {
  [Console]::Out.WriteLine("Context Locker: nothing of it is on $(Get-Computer 'the computer') for $AppName.")
  exit 0
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

# One sync at a time on the computer, and no removal during one. A lock older
# than 10 minutes is stale.
$Lock = Join-Path $ClHome 'sync.lock'
$HaveLock = $false
$tries = 0
while ($Mode -eq 'sync' -or ($Mode -eq 'remove' -and $Yes)) {
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
  # A project's notes folder, for each app that works in project folders, in
  # a repo linked to the workspace or a folder linked on the computer. Git
  # leaves it out, so the repo's own files stay as they are.
  if ($Kind -eq 'note' -or $Kind -eq 'file') {
    if ($Script:Scope -ne 'project' -or $Harness -eq 'openclaw') { return $false }
    if ($Harness -eq 'hermes' -and $Script:Layer -ne 'repo') { return $false }
    if ($Kind -eq 'file') { return ($Target -ceq '{project}/.context-locker/notes/README.md') }
    if (-not ($Target -cmatch '^\{project\}/\.context-locker/notes/(everywhere/)?([^/]+)\z')) { return $false }
    return (Test-NoteName $Matches[2])
  }
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

# The path on the computer for a target such as {codex}/AGENTS.md
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

# Keeps a copy of a file or folder in this run's backups, by its target, and
# never over a copy there already, as two targets can share a name, such as
# a-b.md and a/b.md, and one file can be backed up twice in a sync: a later
# copy gets a number before its ending, such as SOUL.2.md
function Backup-Item([string]$Path, [string]$Target) {
  try {
    $dest = Join-Path (Join-Path (Join-Path $ClHome 'backups') $Stamp) $Harness
    if ($Script:ProjectId -and $Target.StartsWith('{project}/')) { $dest = Join-Path $dest "project-$($Script:ProjectId)" }
    [void](New-Item -ItemType Directory -Force -Path $dest)
    $name = ($Target -replace '[{}]', '') -replace '/', '-'
    $to = Join-Path $dest $name
    $n = 1
    while ((Test-Path -LiteralPath $to) -or (Test-Link $to)) {
      $n++
      $dot = $name.LastIndexOf('.')
      $to = if ($dot -gt 0) { Join-Path $dest ($name.Substring(0, $dot) + ".$n" + $name.Substring($dot)) } else { Join-Path $dest "$name.$n" }
    }
    Copy-Item -LiteralPath $Path -Destination $to -Recurse -Force
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

# --- How much of a file its app reads (G1-212) -----------------------------

# Characters, counting each character once
function Get-CharCount([string]$Text) { return ($Text -replace '[\uDC00-\uDFFF]', '').Length }

# A number with commas, such as 32,768
function Format-Grouped([long]$Number) { return $Number.ToString('N0', [Globalization.CultureInfo]::InvariantCulture) }

# A count with its unit, such as 1 byte or 4,567 bytes
function Format-Amount([long]$Number, [string]$One, [string]$Many) {
  if ($Number -eq 1) { return "1 $One" }
  return "$(Format-Grouped $Number) $Many"
}

# The bytes, or characters, of a file's first $Count lines, newlines included
function Measure-Lines([string[]]$Lines, [int]$Count, [string]$Text, [switch]$Characters) {
  if ($Count -le 0) { return 0 }
  $part = ($Lines[0..($Count - 1)]) -join "`n"
  if ($Count -lt $Lines.Length -or $Text.EndsWith("`n")) { $part += "`n" }
  if ($Characters) { return (Get-CharCount $part) }
  return $Utf8.GetByteCount($part)
}

# The folders from the top of the git work tree $Dir is in down to $Dir's
# parent, or none outside a work tree or at its top
function Get-FoldersAbove([string]$Dir) {
  $top = Get-GitTop $Dir
  if (-not $top) { return , @() }
  $prefix = Invoke-Git @('-C', $Dir, 'rev-parse', '--show-prefix')
  if ($prefix.Code -ne 0) { return , @() }
  $folders = @()
  $d = $top
  foreach ($part in @($prefix.Output.Trim().Split('/') | Where-Object { $_ })) {
    $folders += $d
    $d = Join-Path $d $part
  }
  return , $folders
}

# The bytes Codex reads of a repo's AGENTS.md files: project_doc_max_bytes
# above the first table of its config.toml, or 32 KiB
function Get-CodexDocLimit {
  $config = Join-Path (Get-RootDir 'codex') 'config.toml'
  if (Test-Path -LiteralPath $config -PathType Leaf) {
    foreach ($line in (Get-Lines (Read-Text $config).Replace("`r", ''))) {
      if ($line -match '^\s*\[') { break }
      if ($line -match '^\s*project_doc_max_bytes\s*=\s*([0-9_]+)\s*(#.*)?$') {
        $value = [long]($Matches[1].Replace('_', ''))
        if ($value -gt 0) { return $value }
        break
      }
    }
  }
  return 32768
}

# The characters Hermes keeps of a context file: context_file_max_chars in its
# config.yaml, or 0 when it follows its model's context window
function Get-HermesFileLimit {
  $config = Join-Path (Get-RootDir 'hermes') 'config.yaml'
  if (-not (Test-Path -LiteralPath $config -PathType Leaf)) { return 0 }
  foreach ($line in (Get-Lines (Read-Text $config).Replace("`r", ''))) {
    if ($line -cmatch '^context_file_max_chars:\s*([0-9]+)\s*(#.*)?$') { return [long]$Matches[1] }
  }
  return 0
}

# The common Codex/Hermes budget, independent of which one is syncing.
# Preserve everything outside our block, including write_block's separator.
function Get-SharedAgentsRoom {
  $path = Join-Path $Script:ProjectRoot 'AGENTS.md'
  $before = ''
  $after = ''
  $gap = 0
  if (Test-Path -LiteralPath $path -PathType Leaf) {
    $text = Read-Text $path
    $lines = Get-Lines $text
    $pos = Get-BlockPosition $lines
    if ($pos -eq 'broken') { return 0 }
    if ($pos -eq 'none') {
      if ($text.Trim()) {
        $before = $text
        $gap = if ($text.EndsWith("`n")) { 1 } else { 2 }
      }
    } else {
      $s, $e = $pos.Split(' ') | ForEach-Object { [int]$_ }
      # Retain original newlines while measuring, as the POSIX script does.
      $parts = @([regex]::Matches($text, '[^\n]*\n|[^\n]+\z') | ForEach-Object { $_.Value })
      for ($i = 0; $i -lt $parts.Length; $i++) {
        if ($i -lt $s - 1) { $before += $parts[$i] }
        elseif ($i -ge $e) { $after += $parts[$i] }
      }
    }
  }
  $codex = Get-CodexDocLimit
  foreach ($dir in (Get-FoldersAbove $Script:ProjectRoot)) {
    foreach ($name in @('AGENTS.override.md', 'AGENTS.md')) {
      $ancestor = Join-Path $dir $name
      if (Test-Path -LiteralPath $ancestor -PathType Leaf) {
        $codex -= ([IO.File]::ReadAllBytes($ancestor)).Length + 2
        break
      }
    }
  }
  $codex -= $Utf8.GetByteCount($before) + $gap
  $limit = Get-HermesFileLimit
  if ($limit -le 0) { $limit = 20000 }
  $beforeCount = (Get-CharCount $before) + $gap
  $afterCount = Get-CharCount $after
  $hermes = [Math]::Max($limit - $beforeCount - $afterCount,
    [Math]::Max([Math]::Floor($limit * 7 / 10) - $beforeCount, [Math]::Floor($limit * 2 / 10) - $afterCount))
  $room = [Math]::Max(0, [Math]::Min(12000, [Math]::Min($codex, $hermes)))
  return [int]([Math]::Floor($room / 1000) * 1000)
}

# The room Hermes's SOUL.md or OpenClaw's AGENTS.md leaves for Context
# Locker's block after the file's own text (G1-309), in thousands of bytes:
# what the app keeps of a file, less the text before and after the block, and
# for Hermes a block wholly inside the start or end it keeps of a longer
# file, as the POSIX script measures it. The API takes this or its own cap,
# whichever is smaller.
function Get-GlobalRoom {
  if ($Harness -eq 'hermes') {
    $path = Join-Path (Get-RootDir 'hermes') 'SOUL.md'
    $limit = Get-HermesFileLimit
  } elseif ($Harness -eq 'openclaw') {
    $path = Join-Path (Get-RootDir 'openclaw') 'AGENTS.md'
    $limit = 0
  } else { return $null }
  if ($limit -le 0) { $limit = 20000 }
  $before = 0
  $after = 0
  if (Test-Path -LiteralPath $path -PathType Leaf) {
    $text = Read-Text $path
    $pos = Get-BlockPosition (Get-Lines $text)
    if ($pos -eq 'broken') { return 0 }
    if ($pos -eq 'none') {
      # A new block goes after the file's text, with Write-Block's gap
      if ($text.Trim()) {
        $before = (Get-CharCount $text) + $(if ($text.EndsWith("`n")) { 1 } else { 2 })
      }
    } else {
      $s, $e = $pos.Split(' ') | ForEach-Object { [int]$_ }
      $parts = @([regex]::Matches($text, '[^\n]*\n|[^\n]+\z') | ForEach-Object { $_.Value })
      $head = ''
      $tail = ''
      for ($i = 0; $i -lt $parts.Length; $i++) {
        if ($i -lt $s - 1) { $head += $parts[$i] }
        elseif ($i -ge $e) { $tail += $parts[$i] }
      }
      $before = Get-CharCount $head
      $after = Get-CharCount $tail
    }
  }
  $room = $limit - $before - $after
  if ($Harness -eq 'hermes') {
    $room = [Math]::Max($room, [Math]::Max([Math]::Floor($limit * 7 / 10) - $before, [Math]::Floor($limit * 2 / 10) - $after))
  }
  $room = [Math]::Max(0, $room)
  return [int]([Math]::Floor($room / 1000) * 1000)
}

# What an app misses of Context Locker's block in the file at $Path, for
# $Target: a sentence for the person, or '' when the app reads all of it.
# Apps cut what they load at their own limits, and the block sits at the end
# of a file that has other text.
function Get-FitLine([string]$Target, [string]$Path) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
  $text = Read-Text $Path
  $lines = Get-Lines $text
  $pos = Get-BlockPosition $lines
  if ($pos -eq 'none' -or $pos -eq 'broken') { return '' }
  $s, $e = $pos.Split(' ') | ForEach-Object { [int]$_ }
  $dir = Split-Path -Parent $Path
  $more = " Shortening the text outside the block lets $AppName read all of it."
  $key = "$Harness $Target"
  if ($key -ceq 'codex {project}/AGENTS.md') {
    # Codex takes one file a folder, from the top of the repo down, and stops
    # at a number of bytes in all
    $override = Join-Path $dir 'AGENTS.override.md'
    if (Test-Path -LiteralPath $override -PathType Leaf) { return "Codex reads $override instead of $Path, so it never sees Context Locker's block there." }
    $limit = Get-CodexDocLimit
    $before = 0
    $folders = Get-FoldersAbove $dir
    foreach ($d in @($folders)) {
      foreach ($name in @('AGENTS.override.md', 'AGENTS.md')) {
        $file = Join-Path $d $name
        if (Test-Path -LiteralPath $file -PathType Leaf) { $before += (Get-Item -LiteralPath $file).Length; break }
      }
    }
    $room = [Math]::Max(0, $limit - $before)
    $end = Measure-Lines $lines $e $text
    if ($end -le $room) { return '' }
    $start = Measure-Lines $lines ($s - 1) $text
    $why = if ($before -gt 0) {
      "Codex reads $(Format-Grouped $limit) bytes of a repo's AGENTS.md files, and the ones in the folders above $dir use $(Format-Grouped $before) of them"
    } else {
      "Codex reads the first $(Format-Grouped $limit) bytes of a repo's AGENTS.md files"
    }
    if ($room -le $start) { return "$why, so it stops before Context Locker's block in $Path.$more" }
    return "$why, so it misses the last $(Format-Amount ($end - $room) 'byte' 'bytes') of Context Locker's block in $Path.$more"
  }
  if ($key -ceq 'hermes {project}/AGENTS.md' -or $key -ceq 'hermes {hermes}/SOUL.md') {
    # Hermes loads one kind of project file, .hermes.md first, and keeps the
    # start and end of a long one
    if ($Target -ceq '{project}/AGENTS.md') {
      # The nearest .hermes.md wins, from the top of the repo down
      $other = ''
      $folders = Get-FoldersAbove $dir
      foreach ($d in (@($folders) + @($dir))) {
        if (Test-Path -LiteralPath (Join-Path $d '.hermes.md') -PathType Leaf) { $other = Join-Path $d '.hermes.md' }
        elseif (Test-Path -LiteralPath (Join-Path $d 'HERMES.md') -PathType Leaf) { $other = Join-Path $d 'HERMES.md' }
      }
      if (-not $other -and (Test-Path -LiteralPath (Join-Path $dir 'AGENTS.override.md') -PathType Leaf)) { $other = Join-Path $dir 'AGENTS.override.md' }
      if ($other) { return "Hermes reads $other instead of $Path, so it never sees Context Locker's block there." }
    }
    $limit = Get-HermesFileLimit
    $unless = ''
    if ($limit -le 0) { $limit = 20000; $unless = 'Unless its model has a large context window, ' }
    $total = Get-CharCount $text
    if ($total -le $limit) { return '' }
    $head = [long][Math]::Floor($limit * 7 / 10)
    $tail = [long][Math]::Floor($limit * 2 / 10)
    $start = [Math]::Max((Measure-Lines $lines ($s - 1) $text -Characters), $head)
    $end = [Math]::Min((Measure-Lines $lines $e $text -Characters), $total - $tail)
    if ($end -le $start) { return '' }
    return "$($unless)Hermes keeps the first $(Format-Grouped $head) and last $(Format-Grouped $tail) characters of a file over $(Format-Grouped $limit), so it misses $(Format-Amount ($end - $start) 'character' 'characters') of Context Locker's block in $Path.$more"
  }
  if ($key -ceq 'openclaw {openclaw}/USER.md' -or $key -ceq 'openclaw {openclaw}/AGENTS.md') {
    # OpenClaw reads up to a number of characters of each startup file, a
    # smaller one for USER.md, and of all of them together
    $limit = if ($Target -ceq '{openclaw}/USER.md') { 4000 } else { 20000 }
    $total = Get-CharCount $text
    if ($total -gt $limit) { return "OpenClaw reads up to $(Format-Grouped $limit) characters of $Path, which has $(Format-Grouped $total), so it can miss part of Context Locker's block.$more" }
    if ($Target -cne '{openclaw}/AGENTS.md') { return '' }
    $all = 0
    foreach ($name in @('AGENTS.md', 'SOUL.md', 'TOOLS.md', 'IDENTITY.md', 'USER.md', 'BOOTSTRAP.md', 'MEMORY.md')) {
      $file = Join-Path $dir $name
      if (Test-Path -LiteralPath $file -PathType Leaf) { $all += Get-CharCount (Read-Text $file) }
    }
    if ($all -le 60000) { return '' }
    return "OpenClaw reads up to 60,000 characters across the startup files in $dir, which hold $(Format-Grouped $all), so it can miss part of Context Locker's blocks. Shortening the other files lets OpenClaw read all of them."
  }
  return ''
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

# --- A skill the app also gets elsewhere (G1-221) ---------------------------

# A SKILL.md with its front matter's values as YAML reads them, so a value in
# quotes and the same value without them read the same
function Get-UnquotedFront([string]$Path) {
  $lines = [IO.File]::ReadAllText($Path).Split("`n")
  $front = $false
  for ($i = 0; $i -lt $lines.Length; $i++) {
    if ($i -eq 0) { $front = ($lines[0] -ceq '---'); continue }
    if (-not $front) { break }
    if ($lines[$i] -ceq '---') { break }
    if ($lines[$i] -cmatch '^([A-Za-z0-9_-]+):[ \t]*(.*?)[ \t]*$') {
      $key = $Matches[1]
      $value = $Matches[2]
      if ($value.Length -ge 2 -and $value.StartsWith('"') -and $value.EndsWith('"')) {
        $value = $value.Substring(1, $value.Length - 2).Replace('\"', '"')
      } elseif ($value.Length -ge 2 -and $value.StartsWith("'") -and $value.EndsWith("'")) {
        $value = $value.Substring(1, $value.Length - 2).Replace("''", "'")
      }
      $lines[$i] = "${key}: $value"
    }
  }
  return ($lines -join "`n")
}

# A skill folder's hash as Get-TreeHash works it out, but with its SKILL.md's
# front matter unquoted, so two copies of one skill compare equal however
# each quotes it. Context Locker's marker is left out, as there.
function Get-SameSkillHash([string]$Dir) {
  $text = New-Object System.Text.StringBuilder
  foreach ($file in (Get-SkillFiles $Dir)) {
    $full = Join-Path $Dir ($file -replace '/', [IO.Path]::DirectorySeparatorChar)
    $hash = if ($file -ceq 'SKILL.md') { Get-Sha256Text (Get-UnquotedFront $full) } else { Get-Sha256File $full }
    [void]$text.Append($hash + ' ' + $file + "`n")
  }
  return Get-Sha256Text $text.ToString()
}

# The plugins installed in Claude Code, from its list of them, read once a run
$Script:ClaudePlugins = $null
function Get-ClaudePlugins {
  if ($null -eq $Script:ClaudePlugins) {
    $Script:ClaudePlugins = New-Object System.Collections.Generic.List[hashtable]
    $list = Join-Path (Join-Path (Get-RootDir 'claude') 'plugins') 'installed_plugins.json'
    if (Test-Path -LiteralPath $list -PathType Leaf) {
      try {
        $json = [IO.File]::ReadAllText($list) | ConvertFrom-Json
        foreach ($plugin in $json.plugins.PSObject.Properties) {
          foreach ($install in @($plugin.Value)) {
            if ($install.installPath) { $Script:ClaudePlugins.Add(@{ Name = $plugin.Name; Root = [string]$install.installPath }) }
          }
        }
      } catch { }
    }
  }
  return $Script:ClaudePlugins
}

# A skill folder another source keeps: a real folder with a SKILL.md that
# Context Locker didn't write
function Test-OtherSkill([string]$Dir) {
  if (-not (Test-Path -LiteralPath (Join-Path $Dir 'SKILL.md') -PathType Leaf)) { return $false }
  if (Test-Path -LiteralPath (Join-Path $Dir '.ctx-managed')) { return $false }
  return ((Get-Item -LiteralPath $Dir -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0
}

# Where else this app loads a skill of this name from on the computer, only
# read, never changed (G1-221): the first copy found, with its kind: app, for
# the skills the person uploaded to claude.ai, which the Claude app hands to
# Claude Code; plugin:<name>, for a plugin's; or folder, for one of the
# person's own. Target is where Context Locker writes the skill: a project's
# skill also meets the person's own copy that applies everywhere. One that
# applies everywhere never meets a project's own copy, as leaving it out for
# one project would take it from every other. $null when there's none.
function Find-SkillElsewhere([string]$Name, [string]$Target) {
  $mine = $null
  switch ($Harness) {
    'claude-code' {
      $apps = @()
      if ($OnWindows) { if ($env:APPDATA) { $apps += (Join-Path $env:APPDATA 'Claude') } }
      else {
        $apps += (Join-Path (Join-Path (Join-Path $UserHome 'Library') 'Application Support') 'Claude')
        $config = if ($env:XDG_CONFIG_HOME) { $env:XDG_CONFIG_HOME } else { Join-Path $UserHome '.config' }
        $apps += (Join-Path $config 'Claude')
      }
      foreach ($app in $apps) {
        $root = Join-Path (Join-Path $app 'local-agent-mode-sessions') 'skills-plugin'
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        foreach ($one in @(Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue | Sort-Object Name)) {
          foreach ($two in @(Get-ChildItem -LiteralPath $one.FullName -Directory -Force -ErrorAction SilentlyContinue | Sort-Object Name)) {
            $dir = Join-Path (Join-Path $two.FullName 'skills') $Name
            if (Test-OtherSkill $dir) { return @{ Kind = 'app'; Dir = $dir } }
          }
        }
      }
      foreach ($plugin in (Get-ClaudePlugins)) {
        $dir = Join-Path (Join-Path $plugin.Root 'skills') $Name
        if (Test-OtherSkill $dir) { return @{ Kind = "plugin:$($plugin.Name)"; Dir = $dir } }
      }
      $mine = Join-Path (Get-RootDir 'claude') 'skills'
    }
    'codex' {
      $skills = Join-Path (Get-RootDir 'codex') 'skills'
      foreach ($dir in @((Join-Path $skills $Name), (Join-Path (Join-Path $skills '.system') $Name))) {
        if (Test-OtherSkill $dir) { return @{ Kind = 'folder'; Dir = $dir } }
      }
      $mine = Join-Path (Get-RootDir 'agents') 'skills'
    }
    'hermes' {
      # Hermes keeps skills in folders by category, the ones it came with too
      $skills = Join-Path (Get-RootDir 'hermes') 'skills'
      if (Test-Path -LiteralPath $skills -PathType Container) {
        foreach ($category in @(Get-ChildItem -LiteralPath $skills -Directory -Force -ErrorAction SilentlyContinue | Sort-Object Name)) {
          $dir = Join-Path $category.FullName $Name
          if (Test-OtherSkill $dir) { return @{ Kind = 'folder'; Dir = $dir } }
        }
      }
      return $null
    }
    'openclaw' {
      foreach ($dir in @((Join-Path (Join-Path (Get-RootDir 'openclaw') 'skills') $Name), (Join-Path (Join-Path (Join-Path $UserHome '.openclaw') 'skills') $Name))) {
        if (Test-OtherSkill $dir) { return @{ Kind = 'folder'; Dir = $dir } }
      }
      return $null
    }
  }
  if ($Target.StartsWith('{project}/')) {
    $dir = Join-Path $mine $Name
    if (Test-OtherSkill $dir) { return @{ Kind = 'folder'; Dir = $dir } }
  }
  return $null
}

# Where another copy of a skill comes from, how the person turns it off
# there, and what leaving Context Locker's copy out means, if anything
function Get-SkillSource([string]$Kind, [string]$Dir) {
  if ($Kind -eq 'app') {
    return @('the Claude app, from the skills uploaded to claude.ai', 'turn it off in claude.ai, where it was uploaded', " A Claude Code session outside the Claude app doesn't list it while it's left out.")
  }
  if ($Kind.StartsWith('plugin:')) {
    return @("the plugin $($Kind.Substring(7))", "turn the plugin off in Claude Code with /plugin, if its other skills aren't needed", '')
  }
  return @((ConvertTo-HomePath $Dir), "move it out of $(ConvertTo-HomePath (Split-Path -Parent $Dir)), as Context Locker never changes it", '')
}

# Checks a skill Context Locker keeps at Target, here at Path, as the
# playbook has it, S, and as it's here, L, against another copy this app gets
# elsewhere, which it never touches. When they're the same, it's false, as
# Context Locker's copy is left out so sessions list one: a copy here is taken
# out, and the lock says why, so the next sync writes it again once the
# copies differ or the other goes. When they differ, it says once that the
# skill is listed twice, and how the person turns the other off.
function Test-SkillTwin([string]$Target, [string]$Path, [string]$S, [string]$L, [string[]]$LockLines, $Actions, $Wrote) {
  $name = $Target.Substring($Target.LastIndexOf('/') + 1)
  $found = Find-SkillElsewhere $name $Target
  if ($null -eq $found) { return $true }
  $other = Get-SameSkillHash $found.Dir
  $from, $off, $note = Get-SkillSource $found.Kind $found.Dir
  $same = $false
  if ($L -eq $S) { $same = ((Get-SameSkillHash $Path) -eq $other) }
  elseif ($L -eq 'none') {
    # Left out before, with neither copy changed since, or byte for byte the
    # playbook's
    $same = ($LockLines -ccontains "twin $S $Target $other") -or ((Get-TreeHash $found.Dir) -eq $S)
  }
  if ($same) {
    if ($L -eq $S) {
      Add-Planned "Take Context Locker's copy of the skill $name out of $Path, as $from has the same skill, so sessions list one."
      $Actions.Add(@{ Action = 'twin'; Target = $Target; Kind = 'skill'; Hash = $S; Expect = $L; Other = $other; From = $from; Note = $note })
    } else {
      Add-Planned "Leave out Context Locker's copy of the skill $name, as $from has the same skill, so sessions list one."
      $Wrote.Add("twin $S $Target $other")
    }
    return $false
  }
  # Listed twice: said once for each copy the other source has, and kept
  # for the doctor
  if ($L -eq $S) {
    $told = $LockLines -ccontains "twice $Target $other 1"
    if (-not $told -and -not $Quiet -and $Mode -eq 'sync') {
      $Script:Said.Add("Context Locker: the skill $name is listed twice, as $from has a copy too, which differs from Context Locker's. Context Locker keeps its own copy up to date. Tell the person once, in plain words, that to list it once they can $off.")
      $told = $true
    }
    $Wrote.Add("twice $Target $other $(if ($told) { '1' } else { '0' })")
    Add-Planned "Keep Context Locker's copy of the skill ${name}: $from has a copy too, which differs."
  }
  return $true
}

function Test-ChangedSince([string]$Dir) {
  $marker = (Get-Item -LiteralPath (Join-Path $Dir '.ctx-managed') -Force).LastWriteTimeUtc
  if ((Get-Item -LiteralPath $Dir -Force).LastWriteTimeUtc -gt $marker) { return $true }
  foreach ($item in (Get-ChildItem -LiteralPath $Dir -Recurse -Force -ErrorAction SilentlyContinue)) {
    if ($item.LastWriteTimeUtc -gt $marker) { return $true }
  }
  return $false
}

# Reuse only a regular file below this skill root with the requested bytes.
function Copy-CachedSkillFile([string]$Root, [string]$Relative, [string]$Hash, [string]$Dest) {
  try {
    $cur = $Root
    if (Test-Link $cur) { return $false }
    foreach ($part in $Relative.Split('/')) {
      $cur = Join-Path $cur $part
      if (Test-Link $cur) { return $false }
    }
    if (-not (Test-Path -LiteralPath $cur -PathType Leaf) -or (Get-Sha256File $cur) -ne $Hash) { return $false }
    [void](New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Dest))
    Copy-Item -LiteralPath $cur -Destination $Dest -Force
    return $true
  } catch { return $false }
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

function Read-SkillIndex([byte[]]$Body) {
  if ($Body.Length -gt 300000) { return $null }
  $rows = New-Object System.Collections.Generic.List[object]
  $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
  foreach ($line in ($Utf8.GetString($Body).TrimEnd("`n").Split("`n"))) {
    if ($line -cnotmatch '^([0-9a-f]{64}) ([A-Za-z0-9._-]+(?:/[A-Za-z0-9._-]+)*)$') { return $null }
    $fileHash=$Matches[1]; $relative=$Matches[2]
    if ($relative.Length -gt 200 -or $relative -match '(^|/)\.\.?($|/)' -or $relative.Split('/').Length -gt 8 -or -not $seen.Add($relative)) { return $null }
    $rows.Add(@{ Hash=$fileHash; Path=$relative })
    if ($rows.Count -gt 1000) { return $null }
  }
  if ($rows.Count -lt 1) { return $null }
  return ,$rows
}

function New-Bundle([string]$Dir, $Index = $null) {
  $stream = New-Object System.IO.MemoryStream
  $write = { param([byte[]]$b) $stream.Write($b, 0, $b.Length) }
  $base = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal)
  if ($null -ne $Index) {
    foreach ($row in $Index) { $base[$row.Path]=$row.Hash }
    & $write ($Utf8.GetBytes("context-locker-bundle 2`n"))
  } else { & $write ($Utf8.GetBytes("context-locker-bundle 1`n")) }
  foreach ($file in (Get-SkillFiles $Dir)) {
    $full = Join-Path $Dir ($file -replace '/', [IO.Path]::DirectorySeparatorChar)
    if ($base.ContainsKey($file) -and (Get-Sha256File $full) -eq $base[$file]) {
      & $write ($Utf8.GetBytes("keep $($base[$file]) $file`n"))
      continue
    }
    $bytes = [IO.File]::ReadAllBytes($full)
    & $write ($Utf8.GetBytes("file $($bytes.Length) $file`n"))
    & $write $bytes
    & $write ([byte[]]@(10))
  }
  return , $stream.ToArray()
}

# --- A project's notes folder ----------------------------------------------

# A project's sync mirrors its notes into .context-locker/notes, and the ones
# that apply everywhere into its everywhere folder, with a README. The
# folder's own list, .ctx-managed, says what Context Locker last wrote there,
# so the sync of every app on the computer can tell an edit from an older
# copy. Before anything is written, edited notes and new .md files go up.
$Notes = '.context-locker/notes'
$NotesTarget = '{project}/.context-locker/notes'
# The most a note's file may hold, and how many files go up in one sync
$NotesMax = 524288
$NotesPerSync = 20
$Script:NotesOk = $false
$Script:NotesSaved = $false
$Script:NotesRescan = $false
$Script:Excluded = $false
$Script:NotesRecords = New-Object System.Collections.Generic.List[string]
$Script:NotesLocal = @{}
$Script:NotesMisnamed = New-Object System.Collections.Generic.List[string]
$Script:NotesRefused = New-Object System.Collections.Generic.List[string]

# Whether a file name is one a note's file can have, such as release-plan.md:
# lowercase letters and numbers joined by single hyphens. The README's name,
# and those Windows keeps for devices, never are.
function Test-NoteName([string]$Name) {
  if (-not ($Name -cmatch '^([a-z0-9]+(-[a-z0-9]+)*)\.md\z')) { return $false }
  $stem = $Matches[1]
  return ($stem.Length -le 64 -and -not ($stem -cmatch '^(readme|con|prn|aux|nul|com[0-9]|lpt[0-9])\z'))
}

function Get-NotesPath([string]$Relative) {
  return (Join-Path $Script:ProjectRoot ($Relative -replace '/', [IO.Path]::DirectorySeparatorChar))
}

# True when none of the folders on the way to the notes is a link
function Test-NotesFolder {
  foreach ($part in @('.context-locker', $Notes, "$Notes/everywhere")) {
    if (Test-Link (Get-NotesPath $part)) { return $false }
  }
  return $true
}

# True when this sync keeps the project's notes folder: the app has one in
# this project, and the manifest brings it, README and all. Otherwise the
# folder is left as it is, as another app on the computer may keep it.
function Test-NotesSynced([string[]]$Entries) {
  if (-not (Test-Allowed "$NotesTarget/README.md" 'file')) { return $false }
  foreach ($line in $Entries) {
    $f = $line.Split(' ')
    if ($f.Length -ge 3 -and $f[0] -ceq 'file' -and $f[2] -ceq "$NotesTarget/README.md") { return $true }
  }
  return $false
}

# What the folder's list says Context Locker last wrote there for this project
function Read-NotesRecords {
  $Script:NotesRecords = New-Object System.Collections.Generic.List[string]
  $list = Get-NotesPath "$Notes/.ctx-managed"
  if (-not (Test-Path -LiteralPath $list -PathType Leaf) -or (Test-Link $list)) { return }
  $lines = @([IO.File]::ReadAllLines($list))
  if ($lines.Length -eq 0 -or $lines[0] -cne "context-locker-notes 1 $($Script:ProjectId)") { return }
  $record = '^(wrote note [0-9a-f]{64} \{project\}/\.context-locker/notes/[^ ]+ [0-9a-f-]{36} [0-9]+|wrote file [0-9a-f]{64} \{project\}/\.context-locker/notes/README\.md - -|refused [0-9a-f]{64} \{project\}/\.context-locker/notes/[^ ]+)\z'
  foreach ($line in ($lines | Select-Object -Skip 1)) {
    if ($line -cmatch $record) { $Script:NotesRecords.Add($line) }
  }
}

# Each note's file and the README in the folder, by target, with its hash. A
# .md file with a name no note's file has is set aside.
function Get-NotesLocal {
  $Script:NotesLocal = @{}
  $Script:NotesMisnamed = New-Object System.Collections.Generic.List[string]
  foreach ($sub in @('', 'everywhere/')) {
    $dir = Get-NotesPath "$Notes/$sub"
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { continue }
    $found = @(Get-ChildItem -LiteralPath $dir -File -Force -ErrorAction SilentlyContinue |
        Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0 -and $_.Name -cmatch '\.md\z' -and -not $_.Name.StartsWith('.') } |
        Sort-Object -Property Name)
    foreach ($file in $found) {
      $name = $file.Name
      if (-not ($sub -eq '' -and $name -ceq 'README.md') -and -not (Test-NoteName $name)) {
        $Script:NotesMisnamed.Add((Get-Clean "$sub$name"))
        continue
      }
      try { $Script:NotesLocal["$NotesTarget/$sub$name"] = Get-Sha256File $file.FullName } catch { }
    }
  }
}

# Puts a whole file in place in one step, never through a link
function Write-WholeFile([string]$Path, [byte[]]$Bytes) {
  if (Test-Link $Path) { throw "$Path is a link." }
  $dir = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Force -Path $dir) }
  $tmp = Join-Path $dir ('.' + (Split-Path -Leaf $Path) + '.ctx-tmp.' + $PID)
  [IO.File]::WriteAllBytes($tmp, $Bytes)
  if (Test-Path -LiteralPath $Path -PathType Leaf) {
    [IO.File]::Replace($tmp, $Path, [NullString]::Value)
  } else {
    [IO.File]::Move($tmp, $Path)
  }
}

# Adds .context-locker/ to the repo's own exclude file, once, the first time
# a sync writes in the folder, so git leaves the notes out. It never changes
# .gitignore or any file git tracks, goes through no link, and does nothing
# outside a git work tree.
function Add-GitExclude {
  if ($Script:Excluded) { return }
  $Script:Excluded = $true
  try {
    $inside = Invoke-Git @('-C', $Script:ProjectRoot, 'rev-parse', '--is-inside-work-tree')
    if ($inside.Code -ne 0 -or $inside.Output.Trim() -ne 'true') { return }
    $asked = Invoke-Git @('-C', $Script:ProjectRoot, 'rev-parse', '--git-path', 'info/exclude')
    $lines = @($asked.Output.Trim() -split "`r?`n")
    if ($asked.Code -ne 0 -or $lines.Length -ne 1 -or -not $lines[0]) { return }
    $file = $lines[0] -replace '/', [IO.Path]::DirectorySeparatorChar
    if (-not [IO.Path]::IsPathRooted($file)) { $file = Join-Path $Script:ProjectRoot $file }
    $info = Split-Path -Parent $file
    if ((Test-Link $file) -or (Test-Link $info) -or (Test-Link (Split-Path -Parent $info))) {
      Warn "left $file alone: it's a link or in one, and links aren't followed. To keep the notes out of git, add .context-locker/ to it yourself."
      return
    }
    $text = ''
    if (Test-Path -LiteralPath $file) {
      if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return }
      $text = Read-Text $file
      foreach ($line in ($text -split "`n")) {
        if (@('.context-locker/', '/.context-locker/', '.context-locker', '/.context-locker') -ccontains $line.TrimEnd()) { return }
      }
      if (-not (Backup-Item $file '{project}/.git/info/exclude')) { return }
    } else {
      if (-not (Test-Path -LiteralPath (Split-Path -Parent $info) -PathType Container)) { return }
      [void](New-Item -ItemType Directory -Force -Path $info)
    }
    if ($text -ne '' -and -not $text.EndsWith("`n")) { $text += "`n" }
    Write-WholeFile $file ($Utf8.GetBytes("$text.context-locker/`n"))
  } catch {
    Warn "couldn't add .context-locker/ to the repo's exclude file. To keep the notes out of git, add it yourself."
  }
}

# Writes the file Context Locker sent back for a note it saved, unless the
# file changed again meanwhile, and records it either way. Returns $false
# when the answer doesn't make sense, and then nothing is written.
function Save-NoteReply([string]$Target, [string]$Path, [string]$Sent, [byte[]]$Body) {
  $first = [Array]::IndexOf($Body, [byte]10)
  if ($first -lt 0) { return $false }
  $second = [Array]::IndexOf($Body, [byte]10, $first + 1)
  if ($second -lt 0) { return $false }
  if ($Utf8.GetString($Body, 0, $first) -cne 'context-locker-note 1') { return $false }
  $line = $Utf8.GetString($Body, $first + 1, $second - $first - 1)
  if (-not ($line -cmatch '^(saved|same) ([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}) ([0-9]+) ([0-9a-f]{64}) (\S+)\z')) { return $false }
  $status = $Matches[1]; $id = $Matches[2]; $version = $Matches[3]; $hash = $Matches[4]
  if ($Matches[5] -cne $Target) { return $false }
  $file = New-Object byte[] ($Body.Length - $second - 1)
  [Array]::Copy($Body, $second + 1, $file, 0, $file.Length)
  if ((Get-Sha256Bytes $file) -ne $hash) { return $false }
  if ($status -eq 'saved') { $Script:NotesSaved = $true }
  $now = ''
  try { $now = Get-Sha256File $Path } catch { }
  if ($now -eq $Sent -and $now -ne $hash) {
    # Context Locker's copy of what was sent takes its place, as the canonical file
    Add-GitExclude
    $ok = Backup-Item $Path $Target
    if ($ok) { try { Write-WholeFile $Path $file } catch { $ok = $false } }
    if (-not $ok) { Warn "saved $($Target.Substring('{project}/'.Length)), but couldn't write Context Locker's copy of it. The next sync does." }
  }
  # A file that changed again meanwhile is an edit to this version, which the next sync sends
  $Script:NotesRecords.Add("wrote note $hash $Target $id $version")
  return $true
}

# An edit made here to a note that changed in Context Locker too, in the same
# part: the edit is kept beside the note, as <name>.md.conflict, which the
# sync never sends, and the note's file goes, so this sync writes the newer
# version in its place. A copy goes in the backups first, so nothing is lost,
# the edit isn't sent again, and the app is told at the start of the session.
# $false when the edit can't be kept that way, and then nothing changes.
function Save-NoteConflict([string]$Target, [string]$Path, [string]$Rel) {
  $copy = "$Path.conflict"
  if (Test-Link $copy) { return $false }
  if (Test-Path -LiteralPath $copy) {
    # An older copy goes in the backups before this one takes its place
    if (-not (Test-Path -LiteralPath $copy -PathType Leaf) -or -not (Backup-Item $copy "$Target.conflict")) { return $false }
  }
  if (-not (Backup-Item $Path $Target)) { return $false }
  try {
    Copy-Item -LiteralPath $Path -Destination $copy -Force
    Remove-Item -LiteralPath $Path -Force
  } catch { return $false }
  $Script:NotesRescan = $true
  $Script:Said.Add("Context Locker: your edit to $Rel and a change made in Context Locker since touch the same part, so the note has the newer version now, and your edit is kept beside it in $Rel.conflict. Put the two together in the note, and the next sync saves it.")
  Warn "$Rel changed in Context Locker too, in the same part as your edit, so the note has the newer version now. Your edit is kept in $Rel.conflict."
  return $true
}

# Sends the notes edited here, and new .md files, to Context Locker, at most
# 20 a sync. What it saves is written as Context Locker keeps it; a file it
# can't take stays as it is, and goes again at the next sync. An edit that
# clashes with a newer version is kept beside the note instead.
function Send-Notes([string]$Query, [string[]]$Entries) {
  foreach ($name in $Script:NotesMisnamed) {
    Warn "left $Notes/$name as it is: a note's file is named with lowercase letters, numbers and hyphens, such as release-plan.md. Rename it, and the next sync saves it."
  }
  # A file goes up when it's a note's file that changed since Context Locker
  # last wrote it, unless it's already as Context Locker has it now, or when
  # it's new here: in neither the list nor the manifest
  $inManifest = @{}
  foreach ($line in $Entries) {
    $f = $line.Split(' ')
    if (($f[0] -eq 'note' -or $f[0] -eq 'file') -and $f.Length -ge 3) { $inManifest[$f[2]] = $f[1] }
  }
  $records = @{}
  foreach ($line in $Script:NotesRecords) {
    $f = $line.Split(' ')
    if ($f[0] -eq 'wrote' -and $f.Length -ge 6) { $records[$f[3]] = @{ Kind = $f[1]; Hash = $f[2]; Id = $f[4]; Ver = $f[5] } }
  }
  $up = New-Object System.Collections.Generic.List[hashtable]
  foreach ($t in $Script:NotesLocal.Keys) {
    if ($t -ceq "$NotesTarget/README.md") { continue }
    $L = $Script:NotesLocal[$t]
    if ($records.ContainsKey($t)) {
      $r = $records[$t]
      if ($r.Kind -eq 'note' -and $L -ne $r.Hash -and -not ($inManifest.ContainsKey($t) -and $inManifest[$t] -eq $L)) {
        $up.Add(@{ Target = $t; Edit = $true; Id = $r.Id; Ver = $r.Ver; Hash = $L })
      }
    } elseif (-not $inManifest.ContainsKey($t)) {
      $up.Add(@{ Target = $t; Edit = $false; Id = '-'; Ver = '-'; Hash = $L })
    }
  }
  if ($up.Count -eq 0) { return }
  [string[]]$targets = @($up | ForEach-Object { $_.Target })
  [Array]::Sort($targets, [StringComparer]::Ordinal)
  $byTarget = @{}
  foreach ($u in $up) { $byTarget[$u.Target] = $u }
  $sent = 0; $waiting = 0; $stopped = $false
  foreach ($t in $targets) {
    $u = $byTarget[$t]
    $rel = $t.Substring('{project}/'.Length)
    $path = Get-NotesPath $rel
    if ($stopped -or $sent -ge $NotesPerSync) { $waiting++; continue }
    try { $size = (Get-Item -LiteralPath $path -Force).Length } catch { continue }
    if ($size -gt $NotesMax) {
      Warn "couldn't save ${rel}: it's $([Math]::Ceiling($size / 1024)) KB, and a note can hold at most $([Math]::Floor($NotesMax / 1024)) KB."
      $Script:NotesRefused.Add("refused $($u.Hash) $t")
      continue
    }
    $sent++
    $headers = @{ 'Context-Locker-Target' = $t }
    if ($u.Edit) { $headers['Context-Locker-Base'] = "$($u.Id) $($u.Ver)" }
    try { $body = [IO.File]::ReadAllBytes($path) } catch { continue }
    $reply = Invoke-Api 'POST' "/v1/sync/notes$Query" $body 'text/markdown; charset=utf-8' $headers
    $status = $reply.Status
    if ($status -eq 200) {
      if (-not (Save-NoteReply $t $path $u.Hash $reply.Body)) {
        Warn "couldn't make sense of Context Locker's answer for $rel. The next sync tries again."
      }
    } elseif (@(400, 404, 409, 413, 422) -contains $status) {
      $conflict = $status -eq 409 -and (Get-ReplyField $reply.Body 'error') -eq 'version_conflict'
      if ($conflict -and (Save-NoteConflict $t $path $rel)) { continue }
      if ($conflict) {
        Warn "$rel changed in Context Locker too, so your edit wasn't saved. Copy your edit, delete the file to get the latest at the next sync, then make the edit again."
      } else {
        $message = Get-Clean (Get-ReplyField $reply.Body 'message')
        if (-not $message) { $message = 'Context Locker refused it.' }
        Warn "couldn't save ${rel}: $message"
      }
      $Script:NotesRefused.Add("refused $($u.Hash) $t")
    } elseif ($status -eq 403) {
      Warn "the connection for $Harness on $(Get-Computer 'its computer') can only read, so the changes in $Notes stay here."
      $stopped = $true
    } elseif ($status -eq 0) {
      Warn "can't reach Context Locker, so the changes in $Notes wait for the next sync."
      $stopped = $true
    } else {
      Warn "Context Locker answered $status, so the changes in $Notes wait for the next sync."
      $stopped = $true
    }
  }
  if ($waiting -gt 0 -and -not $stopped) {
    if ($waiting -eq 1) { Warn "1 more file in $Notes waits for the next sync, which saves up to $NotesPerSync." }
    else { Warn "$waiting more files in $Notes wait for the next sync, which saves up to $NotesPerSync." }
  }
}

# Writes the folder's list of what Context Locker last wrote there, from
# records where the last one for each file counts and "forget" drops one,
# with what Context Locker couldn't take at this sync. $false when it can't.
function Write-NotesList($Records) {
  if (-not $Script:NotesOk) { return $true }
  $order = New-Object System.Collections.Generic.List[string]
  $last = @{}
  foreach ($line in $Records) {
    $f = $line.Split(' ')
    if ($f[0] -eq 'forget' -and $f.Length -ge 2) { [void]$last.Remove($f[1]); continue }
    if ($f[0] -ne 'wrote' -or $f.Length -lt 6) { continue }
    if (-not $order.Contains($f[3])) { $order.Add($f[3]) }
    $last[$f[3]] = $line
  }
  $kept = @($order | Where-Object { $last.ContainsKey($_) } | ForEach-Object { $last[$_] })
  $list = Get-NotesPath "$Notes/.ctx-managed"
  if ($kept.Count -eq 0 -and $Script:NotesRefused.Count -eq 0 -and -not (Test-Path -LiteralPath $list)) { return $true }
  $text = "context-locker-notes 1 $($Script:ProjectId)`n# What Context Locker last wrote in this folder, so the sync of each app on the computer can tell an edit from an update. Leave it as it is.`n" +
    (($kept + @($Script:NotesRefused) | ForEach-Object { "$_`n" }) -join '')
  $bytes = $Utf8.GetBytes($text)
  if ((Test-Path -LiteralPath $list -PathType Leaf) -and -not (Test-Link $list) -and (Get-Sha256File $list) -eq (Get-Sha256Bytes $bytes)) { return $true }
  if ((Test-Link $list) -or ((Test-Path -LiteralPath $list) -and -not (Test-Path -LiteralPath $list -PathType Leaf))) {
    Warn "left $list alone: it isn't a file of Context Locker's."
    return $false
  }
  Add-GitExclude
  try { Write-WholeFile $list $bytes; return $true }
  catch {
    Warn "couldn't write $list, the list of what Context Locker wrote in the notes folder."
    return $false
  }
}

# --- An app's own memory files (G1-299) ------------------------------------

# Once the person brings them in, each of the app's own memory files syncs
# both ways with one note in its connection's memory, as the notes folder's
# files do: an edit here goes up, a change there comes down after a backup,
# and a file the app deleted archives its note. Until then, the global sync
# tells Context Locker once what it found, which asks the person, and leaves
# the files as they are, as it does when they're kept on the computer.
#
# Where each app keeps its own memory, as MEMORY_PLACES in
# packages/compilers/src/memory-places.ts has it, which a test keeps the same:
# a line each with the app, how, and where in the app's own folder. How is
# file for a file, outside for a file that holds Context Locker's block too,
# whose memory is the rest of it, or for a folder, how many levels deep its
# files go. A * stands for any one folder, such as each of Claude Code's
# projects. OpenClaw's daily logs, in memory/, stay out.
$MemoryPlaces = @'
claude-code 3 {claude}/projects/*/memory
codex 3 {codex}/memories
hermes outside {hermes}/SOUL.md
hermes file {hermes}/USER.md
hermes file {hermes}/MEMORY.md
hermes 1 {hermes}/memories
openclaw outside {openclaw}/AGENTS.md
openclaw file {openclaw}/SOUL.md
openclaw file {openclaw}/IDENTITY.md
openclaw file {openclaw}/USER.md
openclaw file {openclaw}/MEMORY.md
'@
# The endings of a memory folder's files that count, whatever their case
$MemoryEndings = '.md .markdown .mdx .mdc .txt'
# The longest target a memory note keeps, as items_memory_path_check has it
$MemoryTargetMax = 512
# What the sync last wrote of the app's memory files, as the notes folder's
# list has it: a header with the workspace, the connection the global
# manifest names and a key of the app's folders, then "wrote memory <sha256>
# <target> <note> <version>", "refused <sha256> <target>" and "held <sha256>
# <target> <note> <version>" lines
$MemoryRecords = Join-Path $AppDir 'memory-files'
# A file's bytes as text, a character each, so its lines are read and written
# back byte for byte, as sync.sh's awk reads them
$Bytewise = [Text.Encoding]::GetEncoding(28591)
# The connection the global manifest names, whose records these are
$Script:MemoryConnection = ''
# Whether this sync changed what Context Locker keeps, so its manifest changed
$Script:MemorySaved = $false
$Script:MemoryLocal = $null
$Script:MemoryHeld = $null
$Script:MemoryLong = $null

# A map by target, whose keys differ by case as file names can
function New-TargetMap { return , (New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)) }

# The app's memory places, each @{ How; Where }
function Get-MemoryPlaces {
  [object[]]$found = @(foreach ($line in ($MemoryPlaces -split "`n")) {
      $fields = $line.Trim().Split(' ')
      if ($fields.Length -eq 3 -and $fields[0] -ceq $Harness) { @{ How = $fields[1]; Where = $fields[2] } }
    })
  return , $found
}

# memoryPlaceOf: file or outside for a target in one of the app's memory
# places, by its name, or ''. With -AnyLength, a target can be longer than a
# note keeps.
function Get-MemoryPlaceOf([string]$Target, [switch]$AnyLength) {
  if (-not $AnyLength -and $Target.Length -gt $MemoryTargetMax) { return '' }
  if ($Target -cnotmatch '^\{[a-z-]+\}(/[A-Za-z0-9_-][A-Za-z0-9._-]*)+\z') { return '' }
  $parts = $Target.Split('/')
  foreach ($place in (Get-MemoryPlaces)) {
    if ($place.How -eq 'file' -or $place.How -eq 'outside') {
      if ($Target -ceq $place.Where) { return $place.How }
      continue
    }
    $folder = $place.Where.Split('/')
    if ($parts.Length -le $folder.Length -or $parts.Length -gt $folder.Length + [int]$place.How) { continue }
    $same = $true
    for ($i = 0; $i -lt $folder.Length; $i++) { if ($folder[$i] -cne '*' -and $folder[$i] -cne $parts[$i]) { $same = $false } }
    if (-not $same) { continue }
    $name = $parts[$parts.Length - 1].ToLowerInvariant()
    foreach ($ending in $MemoryEndings.Split(' ')) {
      if ($name.EndsWith($ending, [StringComparison]::Ordinal)) { return 'file' }
    }
  }
  return ''
}

# Where a target such as {claude}/projects/x/memory/MEMORY.md is on this
# computer, through no link, or '' when a folder on the way from the app's
# own folder, or the file itself, is one
function Get-MemoryWhere([string]$Target) {
  if ($Target -cnotmatch '^\{([a-z-]+)\}/(.+)\z') { return '' }
  $root = $Matches[1]
  $rest = $Matches[2]
  $path = Get-RootDir $root
  if (-not $path) { return '' }
  foreach ($part in $rest.Split('/')) {
    $path = Join-Path $path $part
    if (Test-Link $path) { return '' }
  }
  return $path
}

# How a target shows in what the person reads, such as ~/.hermes/SOUL.md
function Get-MemoryShown([string]$Target) {
  $path = Get-MemoryWhere $Target
  if (-not $path) { return (Get-Clean $Target) }
  return (Get-Clean (ConvertTo-HomePath $path))
}

# The app's own folders its memory places sit under, as the computer's
# settings, such as CLAUDE_CONFIG_DIR, name them now
function Get-MemoryRootDirs {
  $names = New-Object System.Collections.Generic.List[string]
  foreach ($place in (Get-MemoryPlaces)) {
    $name = $place.Where.Substring(1, $place.Where.IndexOf('}') - 1)
    if (-not $names.Contains($name)) { $names.Add($name) }
  }
  [string[]]$dirs = @(foreach ($name in $names) { Get-RootDir $name })
  return , $dirs
}

# The records' first line: the workspace, the connection, and a key of the
# app's folders, the start of their SHA-256
function Get-MemoryHeader {
  $roots = (Get-Sha256Text ((@(Get-MemoryRootDirs) | ForEach-Object { "$_`n" }) -join '')).Substring(0, 16)
  return "context-locker-memory 2 $($Script:WorkspaceId) $($Script:MemoryConnection) $roots"
}

# Whether a path is a regular file, never a link, a folder, or on macOS and
# Linux a pipe or a device, which reading could hang on. PowerShell calls
# those files too, with a length of 0 and a UnixMode that starts with -, so
# an empty one is asked about with test -f.
function Test-RegularFile([string]$Path) {
  $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
  if (-not $item -or $item.PSIsContainer -or (Test-ReparsePoint $item)) { return $false }
  if ($OnWindows -or $item.Length -gt 0) { return $true }
  & test -f $item.FullName 2>$null
  return ($LASTEXITCODE -eq 0)
}

# The memory in a file that holds Context Locker's block too, as bytes: its
# lines before the block, without one blank line just before it, then its
# lines after it, without one blank line just after it, each ending with a
# newline. $null when its markers don't pair up, or it holds a NUL byte,
# which sync.sh's awk reads differently from one system to the next.
function Get-MemoryText([byte[]]$Bytes) {
  if ([Array]::IndexOf($Bytes, [byte]0) -ge 0) { return $null }
  $lines = Get-Lines ($Bytewise.GetString($Bytes))
  $pos = Get-BlockPosition $lines
  if ($pos -eq 'broken') { return $null }
  $keep = New-Object System.Collections.Generic.List[string]
  if ($pos -eq 'none') {
    foreach ($line in $lines) { $keep.Add($line) }
  } else {
    $s, $e = $pos.Split(' ') | ForEach-Object { [int]$_ }
    $last = $s - 1
    if ($last -ge 1 -and $lines[$last - 1] -match '^[ \t\r]*\z') { $last-- }
    for ($i = 0; $i -lt $last; $i++) { $keep.Add($lines[$i]) }
    $first = $e + 1
    if ($first -le $lines.Length -and $lines[$first - 1] -match '^[ \t\r]*\z') { $first++ }
    for ($i = $first - 1; $i -lt $lines.Length; $i++) { $keep.Add($lines[$i]) }
  }
  return , $Bytewise.GetBytes((($keep | ForEach-Object { "$_`n" }) -join ''))
}

# A file that holds Context Locker's block too, at $Path, with the memory
# text $Text in place of the rest, as @{ Bytes; Why }: the text, then a blank
# line, then the block as it is, or the text alone when there's no block, or
# the block alone when there's no text. Its memory, as Get-MemoryText reads
# it, is the text again. Why is failed when the file's markers don't pair
# up, or it holds a NUL byte, and marked when the text holds a line that
# marks Context Locker's block, which only the block may.
function Get-MemoryBuild([string]$Path, [byte[]]$Text) {
  $built = $Bytewise.GetString($Text)
  if ((Get-BlockPosition (Get-Lines $built)) -ne 'none') { return @{ Bytes = $null; Why = 'marked' } }
  $pos = 'none'
  $lines = @()
  if (Test-Path -LiteralPath $Path -PathType Leaf) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ([Array]::IndexOf($bytes, [byte]0) -ge 0) { return @{ Bytes = $null; Why = 'failed' } }
    $lines = Get-Lines ($Bytewise.GetString($bytes))
    $pos = Get-BlockPosition $lines
  }
  if ($pos -eq 'broken') { return @{ Bytes = $null; Why = 'failed' } }
  if ($pos -ne 'none') {
    if ($built -ne '') {
      if (-not $built.EndsWith("`n")) { $built += "`n" }
      $built += "`n"
    }
    $s, $e = $pos.Split(' ') | ForEach-Object { [int]$_ }
    $built += (($lines[($s - 1)..($e - 1)] | ForEach-Object { "$_`n" }) -join '')
  }
  return @{ Bytes = $Bytewise.GetBytes($built); Why = '' }
}

# What's in a memory file now, as the sync hashes it: the whole file, or the
# memory in a file that holds Context Locker's block too. none when there's
# no file, and held when it can't be read without going through a link,
# isn't a regular file, or holds Context Locker's block with markers that
# don't pair up or a NUL byte.
function Get-MemoryNow([string]$Target, [string]$How) {
  $path = Get-MemoryWhere $Target
  if (-not $path) { return 'held' }
  if (-not (Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue)) { return 'none' }
  if (-not (Test-RegularFile $path)) { return 'held' }
  try { $bytes = [IO.File]::ReadAllBytes($path) } catch { return 'held' }
  if ($How -eq 'outside') {
    $bytes = Get-MemoryText $bytes
    if ($null -eq $bytes) { return 'held' }
  }
  return (Get-Sha256Bytes $bytes)
}

# The folders a memory folder's place names, such as each of Claude Code's
# projects' memory folders, each @{ Target; Path }. None is reached through
# a link or a hidden folder.
function Get-MemoryFolders([string]$Where) {
  if ($Where -cnotmatch '^\{([a-z-]+)\}/(.+)\z') { return , @() }
  $root = $Matches[1]
  $rest = $Matches[2]
  $base = Get-RootDir $root
  if (-not $base -or -not (Test-Path -LiteralPath $base -PathType Container)) { return , @() }
  $now = @(@{ Target = "{$root}"; Path = $base })
  foreach ($part in $rest.Split('/')) {
    $next = New-Object System.Collections.Generic.List[hashtable]
    foreach ($folder in $now) {
      if ($part -eq '*') {
        foreach ($sub in @(Get-ChildItem -LiteralPath $folder.Path -Directory -Force -ErrorAction SilentlyContinue | Sort-Object -Property Name -CaseSensitive)) {
          if ($sub.Name -cnotmatch '^[A-Za-z0-9_-][A-Za-z0-9._-]*\z' -or (Test-ReparsePoint $sub)) { continue }
          $next.Add(@{ Target = "$($folder.Target)/$($sub.Name)"; Path = $sub.FullName })
        }
      } else {
        $path = Join-Path $folder.Path $part
        $item = Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        if ($item -and $item.PSIsContainer -and -not (Test-ReparsePoint $item)) { $next.Add(@{ Target = "$($folder.Target)/$part"; Path = $path }) }
      }
    }
    $now = @($next)
  }
  return , $now
}

# The regular files under a memory folder, down to <depth>, as paths from it
# with / between folders: hidden files and folders are left out, and no
# link is followed or listed, nor on macOS and Linux a pipe or a device, as
# sync.sh's find has them
function Get-MemoryFolderFiles([string]$Dir, [int]$Depth) {
  $found = New-Object System.Collections.Generic.List[string]
  $walk = {
    param([string]$Full, [string]$Rel, [int]$Level)
    foreach ($item in @(Get-ChildItem -LiteralPath $Full -Force -ErrorAction SilentlyContinue)) {
      if ($item.Name.StartsWith('.') -or (Test-ReparsePoint $item)) { continue }
      $relPath = if ($Rel) { "$Rel/$($item.Name)" } else { $item.Name }
      if ($item.PSIsContainer) {
        if ($Level -lt $Depth) { & $walk $item.FullName $relPath ($Level + 1) }
      } elseif ($item.Length -gt 0 -or (Test-RegularFile $item.FullName)) {
        $found.Add($relPath)
      }
    }
  }
  & $walk $Dir '' 1
  return , @($found)
}

# The app's own memory files here, by target, each @{ Hash; How; Bytes },
# with Text for the memory in a file that holds Context Locker's block too:
# what syncs of each, the whole file, or that memory. Each is a regular file
# in the app's own folder, reached through no link, with no hidden file or
# folder on the way. A file that holds the block with markers that don't
# pair up, or a NUL byte, is held instead, and one whose target is longer
# than a note keeps is set aside.
function Get-MemoryLocal {
  $Script:MemoryLocal = New-TargetMap
  $Script:MemoryHeld = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
  $Script:MemoryLong = New-Object System.Collections.Generic.List[string]
  $found = New-Object System.Collections.Generic.List[string]
  foreach ($place in (Get-MemoryPlaces)) {
    if ($place.How -eq 'file' -or $place.How -eq 'outside') {
      $path = Get-MemoryWhere $place.Where
      if (-not $path -or -not (Test-RegularFile $path)) { continue }
      if ($place.How -eq 'file') { $found.Add($place.Where); continue }
      try { $text = Get-MemoryText ([IO.File]::ReadAllBytes($path)) } catch { continue }
      if ($null -eq $text) { [void]$Script:MemoryHeld.Add($place.Where); continue }
      $Script:MemoryLocal[$place.Where] = @{ Hash = (Get-Sha256Bytes $text); How = 'outside'; Bytes = $text.Length; Text = $text }
      continue
    }
    foreach ($folder in (Get-MemoryFolders $place.Where)) {
      foreach ($rel in (Get-MemoryFolderFiles $folder.Path ([int]$place.How))) { $found.Add("$($folder.Target)/$rel") }
    }
  }
  foreach ($target in $found) {
    if ($Script:MemoryLocal.ContainsKey($target)) { continue }
    if ((Get-MemoryPlaceOf $target) -ne 'file') {
      if ((Get-MemoryPlaceOf $target -AnyLength) -eq 'file' -and -not $Script:MemoryLong.Contains($target)) { $Script:MemoryLong.Add($target) }
      continue
    }
    $path = Get-MemoryWhere $target
    if (-not $path) { continue }
    try { $bytes = [IO.File]::ReadAllBytes($path) } catch { continue }
    $Script:MemoryLocal[$target] = @{ Hash = (Get-Sha256Bytes $bytes); How = 'file'; Bytes = $bytes.Length }
  }
}

# While Context Locker has heard of none, tells it what the app keeps that
# can sync, which asks the person whether to bring them in. The files stay
# as they are.
function Send-MemoryFound {
  $files = 0
  $bytes = 0L
  foreach ($local in $Script:MemoryLocal.Values) {
    if ($local.Bytes -gt 0 -and $local.Bytes -le $NotesMax) { $files++; $bytes += $local.Bytes }
  }
  if ($files -eq 0) { return }
  $reply = Invoke-Api 'POST' '/v1/sync/memory/found' ($Utf8.GetBytes("$files $bytes`n")) 'text/plain' @{}
  if ($reply.Status -ne 200) { return }
  $answer = Get-Lines ($Utf8.GetString($reply.Body))
  # Context Locker's word changed, so its manifest did too
  if ($answer.Length -gt 0 -and $answer[0] -cmatch '^memory-files ' -and $answer[0] -cne 'memory-files none') { $Script:MemorySaved = $true }
}

# Whether the records' path is something other than a file of the sync's own,
# such as a link or a folder, which the sync leaves alone
function Test-MemoryRecordsOdd {
  return ((Test-Link $MemoryRecords) -or ((Test-Path -LiteralPath $MemoryRecords) -and -not (Test-Path -LiteralPath $MemoryRecords -PathType Leaf)))
}

# What the sync last wrote of the app's memory files: Wrote, by target, each
# @{ Hash; Id; Ver }, Refused, by target, the SHA-256 of what Context Locker
# couldn't take, and Held, by target, each @{ Hash; Id; Ver }, a clash a
# quiet run left as it is. Empty for another workspace or connection, which
# keep their own, and $null when they're this connection's but the app's
# folders are other ones now, as a setting such as CLAUDE_CONFIG_DIR says,
# where every file would look deleted.
function Read-MemoryRecords {
  $records = @{ Wrote = (New-TargetMap); Refused = (New-TargetMap); Held = (New-TargetMap) }
  if (-not (Test-Path -LiteralPath $MemoryRecords -PathType Leaf) -or (Test-Link $MemoryRecords)) { return $records }
  try { $lines = Get-Lines (Read-Text $MemoryRecords) } catch { return $records }
  if ($lines.Length -eq 0 -or -not $lines[0].StartsWith("context-locker-memory 2 $($Script:WorkspaceId) $($Script:MemoryConnection) ", [StringComparison]::Ordinal)) { return $records }
  if ($lines[0] -cne (Get-MemoryHeader)) { return $null }
  foreach ($line in $lines) {
    if ($line -cmatch '^wrote memory ([0-9a-f]{64}) (\{[a-z-]+\}/[^ ]+) ([0-9a-f-]{36}) ([0-9]{1,9})\z') {
      $records.Wrote[$Matches[2]] = @{ Hash = $Matches[1]; Id = $Matches[3]; Ver = $Matches[4] }
    } elseif ($line -cmatch '^refused ([0-9a-f]{64}) (\{[a-z-]+\}/[^ ]+)\z') {
      $records.Refused[$Matches[2]] = $Matches[1]
    } elseif ($line -cmatch '^held ([0-9a-f]{64}|none) (\{[a-z-]+\}/[^ ]+) ([0-9a-f-]{36}) ([0-9]{1,9})\z') {
      $records.Held[$Matches[2]] = @{ Hash = $Matches[1]; Id = $Matches[3]; Ver = $Matches[4] }
    }
  }
  return $records
}

# What the warning and the doctor say when the app's folders aren't the ones
# its memory files last synced from
function Get-MemoryMoved {
  $dirs = (@(Get-MemoryRootDirs) | ForEach-Object { Get-Clean (ConvertTo-HomePath $_) }) -join ' and '
  return "$AppName's own memory files were last synced from another folder than $dirs, which the settings on $(Get-Computer 'its computer') name now, so syncs leave them as they are. If $AppName's folder moved for good, take away $(ConvertTo-HomePath $MemoryRecords), and the next sync starts afresh."
}

# Puts a memory text in its place, after a copy of the file there goes in
# the backups: the whole file, or for one that holds Context Locker's block
# too, the text with the block as it is, keeping the file's permissions.
# written, marked when the text holds a line that marks Context Locker's
# block, or failed, writing nothing, when the way there goes through a link
# or the file isn't a regular file.
function Write-MemoryFile([string]$Target, [string]$How, [byte[]]$Text) {
  $path = Get-MemoryWhere $Target
  if (-not $path) { return 'failed' }
  $there = [bool](Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue)
  if ($there -and -not (Test-RegularFile $path)) { return 'failed' }
  $bytes = $Text
  if ($How -eq 'outside') {
    try { $built = Get-MemoryBuild $path $Text } catch { return 'failed' }
    if ($built.Why) { return $built.Why }
    $bytes = $built.Bytes
  }
  $mode = $null
  if ($there) {
    if (-not (Backup-Item $path $Target)) { return 'failed' }
    if (-not $OnWindows) { try { $mode = [IO.File]::GetUnixFileMode($path) } catch { } }
  }
  try { Write-WholeFile $path $bytes } catch { return 'failed' }
  if ($null -ne $mode) { try { [IO.File]::SetUnixFileMode($path, $mode) } catch { } }
  return 'written'
}

# Writes the file Context Locker sent back for a memory file it saved, as its
# connection's memory keeps it, unless the file changed again meanwhile, and
# records it. $Sent is what was sent, and $Base the version it was an edit
# to. What Context Locker put together with a change made there since, but
# which couldn't be written here, is recorded as an edit to that version, so
# the next sync takes Context Locker's version down rather than sending this
# one again. $false when the answer doesn't make sense, and then nothing is
# written.
function Save-MemoryReply([string]$Target, [string]$How, [string]$Sent, [string]$Base, [byte[]]$Body, $Wrote) {
  $first = [Array]::IndexOf($Body, [byte]10)
  if ($first -lt 0) { return $false }
  $second = [Array]::IndexOf($Body, [byte]10, $first + 1)
  if ($second -lt 0) { return $false }
  if ($Utf8.GetString($Body, 0, $first) -cne 'context-locker-note 1') { return $false }
  $line = $Utf8.GetString($Body, $first + 1, $second - $first - 1)
  if (-not ($line -cmatch '^(saved|same) ([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}) ([0-9]+) ([0-9a-f]{64}) (\S+)\z')) { return $false }
  $status = $Matches[1]; $id = $Matches[2]; $version = $Matches[3]; $hash = $Matches[4]
  if ($Matches[5] -cne $Target) { return $false }
  $kept = New-Object byte[] ($Body.Length - $second - 1)
  [Array]::Copy($Body, $second + 1, $kept, 0, $kept.Length)
  if ((Get-Sha256Bytes $kept) -ne $hash) { return $false }
  if ($status -eq 'saved') { $Script:MemorySaved = $true }
  $record = "$hash $Target $id $version"
  if ($hash -ne $Sent) {
    $from = if ($Base -cmatch '^[0-9]+\z') { $Base } else { $version }
    if ((Get-MemoryNow $Target $How) -ne $Sent) {
      # Changed again meanwhile: an edit to the version it came from
      $record = "$Sent $Target $id $from"
    } elseif ((Write-MemoryFile $Target $How $kept) -eq 'written') {
      # What's kept, with what changed in Context Locker since, takes its place
      $record = "$(Get-MemoryNow $Target $How) $Target $id $version"
    } else {
      Warn "saved $(Get-MemoryShown $Target), but couldn't write the copy Context Locker keeps, with what changed there too. The next sync tries again."
      $record = "$Sent $Target $id $from"
    }
  }
  $Wrote.Add("wrote memory $record")
  return $true
}

# An edit made here to a memory file that changed in Context Locker too, in
# the same part: the edit is kept beside the file as <name>.conflict, which
# the sync never sends, after a copy of the file goes in the backups, and
# Context Locker's version then takes the file's place. The app is told at
# the start of the session. $false when the edit can't be kept that way, and
# then nothing changes.
function Save-MemoryConflict([string]$Target, [byte[]]$Edit) {
  $path = Get-MemoryWhere $Target
  if (-not $path) { return $false }
  $copy = "$path.conflict"
  if (Test-Link $copy) { return $false }
  if (Test-Path -LiteralPath $copy) {
    if (-not (Test-Path -LiteralPath $copy -PathType Leaf) -or -not (Backup-Item $copy "$Target.conflict")) { return $false }
  }
  if (-not (Backup-Item $path $Target)) { return $false }
  try { Write-WholeFile $copy $Edit } catch { return $false }
  $shown = Get-Clean (ConvertTo-HomePath $path)
  $Script:Said.Add("Context Locker: your edit to $shown and a change made in Context Locker since touch the same part, so the file has the newer version now, and your edit is kept beside it in $shown.conflict. Put the two together in the file, and the next sync saves it.")
  Warn "$shown changed in Context Locker too, in the same part as your edit, so it has the newer version now. Your edit is kept in $shown.conflict."
  return $true
}

# Sends the app's memory files that are new or edited here to its
# connection's memory, and says which ones the app deleted, at most
# $NotesPerSync in a sync. What it saves is written as the memory keeps it.
# A file Context Locker can't take as it is, too big or not a memory file it
# can keep, stays as it is, and isn't sent again until it changes. A clash
# with a change made there is settled by a run that can say so: the edit
# goes beside the file, or a deleted file comes back, with Context Locker's
# version. A quiet one, a hook's that prints nothing or a daily job's, leaves
# both as they are, and records it as held.
function Send-Memory($Plan, $Wrote, $Refused, $Clash, $Writes) {
  $sent = 0
  $waiting = 0
  $stopped = $false
  foreach ($p in $Plan) {
    if (@('new', 'edit', 'gone') -cnotcontains $p.What) { continue }
    if ($stopped -or $sent -ge $NotesPerSync) { $waiting++; continue }
    $t = $p.Target
    $shown = Get-MemoryShown $t
    if ($p.What -eq 'gone') {
      # Deleted here: its note is archived, unless it changed there since
      $sent++
      $reply = Invoke-Api 'POST' '/v1/sync/memory/gone' ([byte[]]@()) 'text/plain' @{ 'Context-Locker-Target' = $t; 'Context-Locker-Base' = "$($p.R.Id) $($p.R.Ver)" }
      $why = Get-ReplyField $reply.Body 'error'
      if ($reply.Status -eq 200) {
        $answer = $Utf8.GetString($reply.Body).Trim()
        if ($answer -ceq 'archived' -or $answer -ceq 'gone') {
          $Script:MemorySaved = $true
          $Wrote.Add("forget $t")
        } else {
          Warn "couldn't make sense of Context Locker's answer for $shown. The next sync tries again."
        }
        continue
      }
      if ($reply.Status -eq 409 -and $why -eq 'version_conflict') {
        if ($Quiet) { $Clash.Add("held none $t $($p.S.Id) $($p.S.Ver)") }
        # It changed in Context Locker since, so it comes back
        else { $Writes.Add(@{ Target = $t; How = $p.How; S = $p.S; Expect = 'none'; Why = 'restore' }) }
        continue
      }
    } else {
      if ($p.Bytes -gt $NotesMax) {
        Warn "couldn't bring $shown into this connection's memory: it's $([Math]::Ceiling($p.Bytes / 1024)) KB, and a memory file can hold at most $([Math]::Floor($NotesMax / 1024)) KB."
        $Refused.Add("refused $($p.L) $t")
        continue
      }
      # What goes up: the file as it is, or the memory in a file that holds
      # Context Locker's block too, as the scan read it
      if ($p.How -eq 'outside') {
        $body = $Script:MemoryLocal[$t].Text
      } else {
        $path = Get-MemoryWhere $t
        if (-not $path -or -not (Test-RegularFile $path)) { continue }
        try { $body = [IO.File]::ReadAllBytes($path) } catch { continue }
      }
      $hash = Get-Sha256Bytes $body
      $sent++
      $headers = @{ 'Context-Locker-Target' = $t }
      if ($p.What -eq 'edit') { $headers['Context-Locker-Base'] = "$($p.R.Id) $($p.R.Ver)" }
      $reply = Invoke-Api 'POST' '/v1/sync/memory' $body 'text/markdown; charset=utf-8' $headers
      $why = Get-ReplyField $reply.Body 'error'
      if ($reply.Status -eq 200) {
        $base = if ($p.R) { [string]$p.R.Ver } else { '' }
        if (-not (Save-MemoryReply $t $p.How $hash $base $reply.Body $Wrote)) {
          Warn "couldn't make sense of Context Locker's answer for $shown. The next sync tries again."
        }
        continue
      }
      if ($reply.Status -eq 409 -and $why -eq 'version_conflict' -and $p.S) {
        if ($Quiet) {
          $Clash.Add("held $hash $t $($p.S.Id) $($p.S.Ver)")
        } elseif (Save-MemoryConflict $t $body) {
          $Writes.Add(@{ Target = $t; How = $p.How; S = $p.S; Expect = $p.L; Why = 'conflict' })
        } else {
          Warn "$shown changed in Context Locker too, in the same part as your edit, and your edit couldn't be kept beside it, so both stay as they are."
          $Clash.Add("held $hash $t $($p.S.Id) $($p.S.Ver)")
        }
        continue
      }
      if ($reply.Status -eq 413 -or $reply.Status -eq 422) {
        # What Context Locker can't take as it is
        $message = Get-Clean (Get-ReplyField $reply.Body 'message')
        if (-not $message) { $message = 'Context Locker refused it.' }
        Warn "couldn't bring $shown into this connection's memory: $message"
        $Refused.Add("refused $hash $t")
        continue
      }
    }
    # Nothing more goes up at this sync, and nothing is recorded for it
    $stopped = $true
    if ($reply.Status -eq 409 -and $why -eq 'memory_files_off') { Warn "$AppName's own memory files don't sync with this connection's memory now, so they stay as they are." }
    elseif ($reply.Status -eq 403) { Warn "the connection for $Harness on $(Get-Computer 'its computer') can only read, so the changes in $AppName's memory files stay here." }
    elseif ($reply.Status -eq 0) { Warn "can't reach Context Locker, so the changes in $AppName's memory files wait for the next sync." }
    elseif ($reply.Status -ge 400 -and $reply.Status -lt 500) {
      $message = Get-Clean (Get-ReplyField $reply.Body 'message')
      if ($message) { Warn "Context Locker didn't take ${shown}: $message The changes in $AppName's memory files wait for the next sync." }
      else { Warn "Context Locker answered $($reply.Status) for $shown, so the changes in $AppName's memory files wait for the next sync." }
    }
    else { Warn "Context Locker answered $($reply.Status), so the changes in $AppName's memory files wait for the next sync." }
  }
  if ($waiting -gt 0 -and -not $stopped) {
    if ($waiting -eq 1) { Warn "1 more of $AppName's memory files waits for the next sync, which saves up to $NotesPerSync." }
    else { Warn "$waiting more of $AppName's memory files wait for the next sync, which saves up to $NotesPerSync." }
  }
}

# Writes what changed in Context Locker into the app's memory files, after a
# copy of each goes in the backups, and takes away those whose notes
# Context Locker says went, while they're as the sync wrote them
function Receive-Memory($Plan, $Wrote, $Writes) {
  $blobs = Join-Path $Tmp ('memory.' + [Guid]::NewGuid().ToString('N').Substring(0, 6))
  [void](New-Item -ItemType Directory -Path $blobs)
  $want = @($Writes | ForEach-Object { $_.S.Hash } | Sort-Object -Unique)
  for ($at = 0; $at -lt $want.Length; $at += 500) {
    $chunk = @($want[$at..([Math]::Min($at + 499, $want.Length - 1))])
    $reply = Invoke-Api 'POST' '/v1/sync/blobs' ($Utf8.GetBytes(($chunk -join "`n") + "`n")) 'text/plain' @{}
    $ok = $reply.Status -eq 200
    if ($ok) {
      $archive = Join-Path $Tmp 'memory.tar'
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
      Warn "couldn't fetch the latest of $AppName's memory files, so it keeps the ones it has. The next sync tries again."
      $Script:Failed = $true
      $Writes.Clear()
      break
    }
  }
  foreach ($w in $Writes) {
    $blob = Join-Path $blobs $w.S.Hash
    if (-not (Test-Path -LiteralPath $blob -PathType Leaf) -or (Test-Link $blob) -or (Get-Sha256File $blob) -ne $w.S.Hash) {
      Warn "the new content for $(Get-MemoryShown $w.Target) didn't match its hash, so it wasn't written. The next sync tries again."
      $Script:Failed = $true
      continue
    }
    # Changed since this sync looked, so it's an edit for the next one
    if ((Get-MemoryNow $w.Target $w.How) -ne $w.Expect) { continue }
    $result = Write-MemoryFile $w.Target $w.How ([IO.File]::ReadAllBytes($blob))
    if ($result -eq 'written') {
      # As the file holds it now, which for a file that holds Context
      # Locker's block too ends with a newline
      $Wrote.Add("wrote memory $(Get-MemoryNow $w.Target $w.How) $($w.Target) $($w.S.Id) $($w.S.Ver)")
      if ($w.Why -eq 'restore') {
        $Script:Said.Add("Context Locker: $(Get-MemoryShown $w.Target) was deleted here, but it changed in Context Locker since, so it's back with Context Locker's version.")
      }
    } elseif ($result -eq 'marked') {
      Warn "left $(Get-MemoryShown $w.Target) as it is: what this connection's memory keeps of it holds a line that marks Context Locker's block, which only the block may. Take that line out of it in Context Locker."
    } else {
      Warn "couldn't write $(Get-MemoryShown $w.Target)."
      $Script:Failed = $true
    }
  }
  # Gone from the connection's memory, as Context Locker says: taken away
  # while it's as the sync wrote it, after a copy goes in the backups. For a
  # file that holds Context Locker's block too, that's the rest of it.
  foreach ($p in $Plan) {
    if ($p.What -ne 'remove') { continue }
    $t = $p.Target
    if ((Get-MemoryNow $t $p.How) -ne $p.R.Hash) { continue }
    $path = Get-MemoryWhere $t
    if (-not $path) { continue }
    $pos = 'none'
    if ($p.How -eq 'outside') {
      try { $pos = Get-BlockPosition (Get-Lines ($Bytewise.GetString([IO.File]::ReadAllBytes($path)))) } catch { continue }
    }
    if ($pos -ne 'none') {
      if ((Write-MemoryFile $t 'outside' ([byte[]]@())) -ne 'written') {
        Warn "couldn't take what's no longer in this connection's memory out of $(Get-MemoryShown $t)."
        $Script:Failed = $true
        continue
      }
    } else {
      $ok = Backup-Item $path $t
      if ($ok) { try { Remove-Item -LiteralPath $path -Force } catch { $ok = $false } }
      if (-not $ok) {
        Warn "couldn't take away $(Get-MemoryShown $t), which is no longer in this connection's memory."
        $Script:Failed = $true
        continue
      }
    }
    $Wrote.Add("forget $t")
  }
}

# Writes the list of what the sync last wrote of the app's memory files, from
# records where the last one for each file counts and forget drops one, with
# what Context Locker couldn't take and the clashes left as they are. $false
# when it can't.
function Write-MemoryRecords($Wrote, $Refused, $Clash) {
  $order = New-Object System.Collections.Generic.List[string]
  $last = New-TargetMap
  foreach ($line in $Wrote) {
    $f = $line.Split(' ')
    if ($f[0] -eq 'forget' -and $f.Length -ge 2) { [void]$last.Remove($f[1]); continue }
    if ($f[0] -ne 'wrote' -or $f.Length -lt 6) { continue }
    if (-not $order.Contains($f[3])) { $order.Add($f[3]) }
    $last[$f[3]] = $line
  }
  $kept = New-Object System.Collections.Generic.List[string]
  foreach ($t in $order) { if ($last.ContainsKey($t)) { $kept.Add($last[$t]) } }
  foreach ($list in @($Refused, $Clash)) {
    $listOrder = New-Object System.Collections.Generic.List[string]
    $listLast = New-TargetMap
    foreach ($line in $list) {
      $t = $line.Split(' ')[2]
      if (-not $listOrder.Contains($t)) { $listOrder.Add($t) }
      $listLast[$t] = $line
    }
    foreach ($t in $listOrder) { $kept.Add($listLast[$t]) }
  }
  # Nothing has been written, and nothing waits
  if ($kept.Count -eq 0 -and -not (Test-Path -LiteralPath $MemoryRecords)) { return $true }
  $text = "$(Get-MemoryHeader)`n# What Context Locker last wrote of $AppName's own memory files on the computer, so the sync can tell an edit here from a change in Context Locker. Leave it as it is.`n" +
    (($kept | ForEach-Object { "$_`n" }) -join '')
  $bytes = $Utf8.GetBytes($text)
  if ((Test-Path -LiteralPath $MemoryRecords -PathType Leaf) -and (Get-Sha256File $MemoryRecords) -eq (Get-Sha256Bytes $bytes)) { return $true }
  try { Write-WholeFile $MemoryRecords $bytes; return $true }
  catch {
    Warn "couldn't write $MemoryRecords, the list of what Context Locker wrote of $AppName's memory files."
    return $false
  }
}

# The global sync's step for the app's own memory files, after its block, as
# one file can hold both. While the manifest says none, it tells Context
# Locker what it found; while it says on, they sync both ways; and while
# they wait on the person, or are kept on the computer, they stay as they
# are. A Context Locker from before G1-299 says nothing of them.
function Sync-Memory([string[]]$Entries) {
  $state = ''
  $Script:MemoryConnection = ''
  foreach ($line in $Entries) {
    if ($line -cmatch '^memory-files (\S+) (\S+)\z') { $state = $Matches[1]; $Script:MemoryConnection = $Matches[2]; break }
  }
  if (@('none', 'on') -cnotcontains $state -or $Script:MemoryConnection -cnotmatch $Uuid -or -not $Script:WorkspaceId) { return }
  Get-MemoryLocal
  if ($state -eq 'none') { Send-MemoryFound; return }
  foreach ($target in $Script:MemoryLong) {
    Warn "left $(Get-MemoryShown $target) as it is: its path is longer than a memory file's can be, $MemoryTargetMax characters, so it doesn't sync."
  }
  # The records stay this connection's, from these folders, in a file of the
  # sync's own: otherwise the files stay as they are
  if (Test-MemoryRecordsOdd) {
    Warn "left $AppName's own memory files as they are: $(ConvertTo-HomePath $MemoryRecords) isn't a file of Context Locker's. Take it away, and the next sync starts afresh."
    return
  }
  $records = Read-MemoryRecords
  if ($null -eq $records) {
    Warn (Get-MemoryMoved)
    return
  }
  # What Context Locker keeps of each (S), what the sync last wrote (R)
  # and what's here now (L), as the notes folder's sync has them, with the
  # ones Context Locker says went
  $kept = New-TargetMap
  $gone = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
  foreach ($line in $Entries) {
    $f = $line.Split(' ')
    if ($f.Length -eq 5 -and $f[0] -ceq 'memory') { $kept[$f[2]] = @{ Hash = $f[1]; Id = $f[3]; Ver = $f[4] } }
    elseif ($f.Length -eq 3 -and $f[0] -ceq 'memory-gone') { [void]$gone.Add("$($f[1]) $($f[2])") }
  }
  $all = New-Object 'System.Collections.Generic.SortedSet[string]' ([StringComparer]::Ordinal)
  foreach ($t in $kept.Keys) { [void]$all.Add($t) }
  foreach ($t in $records.Wrote.Keys) { [void]$all.Add($t) }
  foreach ($t in $Script:MemoryLocal.Keys) { [void]$all.Add($t) }
  $wrote = New-Object System.Collections.Generic.List[string]
  $refused = New-Object System.Collections.Generic.List[string]
  $clash = New-Object System.Collections.Generic.List[string]
  $writes = New-Object System.Collections.Generic.List[hashtable]
  $plan = New-Object System.Collections.Generic.List[hashtable]
  foreach ($t in $all) {
    $how = Get-MemoryPlaceOf $t
    if (-not $how) {
      if ($kept.ContainsKey($t)) { Warn "skipped ${t}: it isn't a file $Harness's sync may write." }
      continue
    }
    $R = if ($records.Wrote.ContainsKey($t)) { $records.Wrote[$t] } else { $null }
    if ($R) { $wrote.Add("wrote memory $($R.Hash) $t $($R.Id) $($R.Ver)") }
    $local = if ($Script:MemoryLocal.ContainsKey($t)) { $Script:MemoryLocal[$t] } else { $null }
    $L = if ($local) { $local.Hash } else { 'none' }
    $turnedDown = if ($records.Refused.ContainsKey($t)) { $records.Refused[$t] } else { '' }
    $H = if ($records.Held.ContainsKey($t)) { $records.Held[$t] } else { $null }
    # A file on record, or in Context Locker, that's there but can't be read
    # without going through a link, or isn't a file, stays as it is, with what
    # is on record about it
    if ($Script:MemoryHeld.Contains($t) -or (-not $local -and (Get-MemoryNow $t 'file') -ne 'none')) {
      if ($turnedDown) { $refused.Add("refused $turnedDown $t") }
      if ($H) { $clash.Add("held $($H.Hash) $t $($H.Id) $($H.Ver)") }
      continue
    }
    # A file with nothing in it that never synced has nothing to sync
    $e = if ($local -and -not $R -and $local.Bytes -eq 0) { 'none' } else { $L }
    $refusedNow = $turnedDown -and $turnedDown -eq $e
    if ($refusedNow) { $refused.Add("refused $turnedDown $t") }
    $S = if ($kept.ContainsKey($t)) { $kept[$t] } else { $null }
    # A clash a quiet run left as it is, while neither side changed since
    $waiting = $Quiet -and $H -and $S -and $H.Hash -eq $e -and $H.Id -ceq $S.Id -and $H.Ver -ceq $S.Ver
    $what = ''
    if ($S) {
      if ($e -eq $S.Hash) { $what = 'same' }
      elseif ($refusedNow) { $what = 'skip' }
      elseif ($waiting) { $what = 'wait' }
      elseif ($e -eq 'none') { $what = if ($R) { 'gone' } else { 'write' } }
      # Context Locker keeps another text at this path: a clash, which a
      # quiet run leaves as it is
      elseif (-not $R) { $what = if ($Quiet) { 'clash' } else { 'new' } }
      # As the sync left it: written again only once Context Locker has
      # another version, as a file that holds the block too ends its memory
      # with a newline, which the note may not
      elseif ($e -eq $R.Hash) { $what = if ($S.Id -ceq $R.Id -and $S.Ver -ceq $R.Ver) { '' } else { 'write' } }
      else { $what = 'edit' }
    } elseif ($e -eq 'none') {
      if ($R) { $what = 'forget' }
    } elseif ($refusedNow) { $what = 'skip' }
    elseif (-not $R) { $what = 'new' }
    # Taken away only once Context Locker says its note went, and sent again
    # as new when it was edited here since
    elseif ($gone.Contains("$t $($R.Id)")) { $what = if ($e -eq $R.Hash) { 'remove' } else { 'new' } }
    # No note keeps it, and Context Locker said nothing of it: it stays, and
    # goes up as new at the next sync
    else { $what = 'forget' }
    switch ($what) {
      'same' { $wrote.Add("wrote memory $($S.Hash) $t $($S.Id) $($S.Ver)") }
      'forget' { $wrote.Add("forget $t") }
      'write' { $writes.Add(@{ Target = $t; How = $how; S = $S; Expect = $L; Why = 'plan' }) }
      'wait' { $clash.Add("held $($H.Hash) $t $($H.Id) $($H.Ver)") }
      'clash' { $clash.Add("held $L $t $($S.Id) $($S.Ver)") }
    }
    if (@('new', 'edit', 'gone', 'remove') -ccontains $what) {
      $plan.Add(@{ What = $what; Target = $t; How = $how; S = $S; R = $R; L = $L; Bytes = $(if ($local) { $local.Bytes } else { -1 }) })
    }
  }
  Send-Memory $plan $wrote $refused $clash $writes
  Receive-Memory $plan $wrote $writes
  if (-not (Write-MemoryRecords $wrote $refused $clash)) { $Script:Failed = $true }
}

# --- A project's pointers to paths in its repo ------------------------------

# Where a link points, as it was made
function Get-LinkTarget($Item) {
  $target = ''
  if ($Item.PSObject.Properties['LinkTarget'] -and $Item.LinkTarget) { $target = [string]$Item.LinkTarget }
  elseif ($Item.PSObject.Properties['Target'] -and $Item.Target) { $target = [string](@($Item.Target)[0]) }
  return $target
}

# Whether a path in the repo is there, under the folder $Root, going through
# no link that leads out of it
function Test-PathHere([string]$Root, [string]$Path) {
  try {
    $sep = [IO.Path]::DirectorySeparatorChar
    $compare = if ($OnWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    $top = [IO.Path]::GetFullPath($Root).TrimEnd($sep)
    $cur = $top
    $hops = 0
    foreach ($part in $Path.Split('/')) {
      if ($part -eq '' -or $part -eq '.') { continue }
      if ($part -eq '..') { return $false }
      $next = Join-Path $cur $part
      # A link is followed only while it stays in the folder
      while (Test-Link $next) {
        $hops++
        if ($hops -gt 16) { return $false }
        $target = Get-LinkTarget (Get-Item -LiteralPath $next -Force)
        if (-not $target) { return $false }
        if (-not [IO.Path]::IsPathRooted($target)) { $target = Join-Path (Split-Path -Parent $next) $target }
        $next = [IO.Path]::GetFullPath($target).TrimEnd($sep)
        if (-not ($next.Equals($top, $compare) -or $next.StartsWith("$top$sep", $compare))) { return $false }
      }
      if (-not (Test-Path -LiteralPath $next)) { return $false }
      $cur = $next
    }
    return $true
  } catch {
    return $false
  }
}

# Checks the project's pointers to paths in its repo, from the manifest's
# link lines, and says in one line which ones aren't in the folder
function Test-Links([string[]]$Entries) {
  $Script:LinksChecked = 0
  $paths = New-Object System.Collections.Generic.List[string]
  foreach ($line in $Entries) {
    if (-not ($line -cmatch '^link ([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}) (.+)\z')) { continue }
    $id = $Matches[1]; $path = $Matches[2]
    $Script:LinksChecked++
    if (Test-PathHere $Script:ProjectRoot $path) { continue }
    $Script:MissingLinks.Add($id)
    $paths.Add((Get-Clean $path))
  }
  if ($paths.Count -eq 0) { return }
  $names = (@($paths) | Select-Object -First 5) -join ', '
  if ($paths.Count -gt 5) { $names += " and $($paths.Count - 5) more" }
  if ($paths.Count -eq 1) {
    Warn "1 of this project's pointers points to a path that isn't in $($Script:ProjectRoot): $names. If it moved, change the pointer's address in Context Locker."
  } else {
    Warn "$($paths.Count) of this project's pointers point to paths that aren't in $($Script:ProjectRoot): $names. If they moved, change their addresses in Context Locker."
  }
}

# --- The API --------------------------------------------------------------

# Returns @{ Status; Body (bytes) }. Status 0 means Context Locker can't be reached.
function Invoke-Api([string]$Method, [string]$Path, [byte[]]$Body, [string]$Type, [hashtable]$Headers) {
  $request = New-Object System.Net.Http.HttpRequestMessage((New-Object System.Net.Http.HttpMethod($Method)), "$Api$Path")
  if ($Script:Token) { [void]$request.Headers.TryAddWithoutValidation('Authorization', "Bearer $($Script:Token)") }
  if ($Headers) { foreach ($key in $Headers.Keys) { [void]$request.Headers.TryAddWithoutValidation($key, $Headers[$key]) } }
  if ($Path -like '/v1/sync*?project=*') {
    if ($null -ne $Script:AgentsMdBytes) {
      [void]$request.Headers.TryAddWithoutValidation('Context-Locker-Agents-Md-Bytes', [string]$Script:AgentsMdBytes)
    }
  } elseif ($Path -like '/v1/sync*' -and $null -ne $Script:GlobalBytes) {
    [void]$request.Headers.TryAddWithoutValidation('Context-Locker-Global-Bytes', [string]$Script:GlobalBytes)
  }
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

# One request to Context Locker holds at most 4.5 MB, so a body bigger than a
# part goes up in parts, as an upload: a plan, or a skill's edit
$PartBytes = 4194304

# Sends a body in parts of up to 4 MB, as an upload for $Purpose, gather or
# sync-edit. Returns the upload's id, which the request that would have
# carried the body names instead. When Context Locker refuses a step or can't
# be reached, it returns '', with the step's HTTP status in
# $Script:UploadStatus and Context Locker's answer in $Script:UploadReply.
function Send-Upload([string]$Purpose, [byte[]]$Body) {
  $parts = [int][Math]::Ceiling($Body.Length / $PartBytes)
  $start = $Utf8.GetBytes("{`"purpose`":`"$Purpose`",`"parts`":$parts,`"bytes`":$($Body.Length),`"sha256`":`"$(Get-Sha256Bytes $Body)`"}")
  $reply = Invoke-Api 'POST' '/v1/uploads' $start 'application/json' @{ 'Accept' = 'text/plain' }
  $Script:UploadStatus = $reply.Status
  $Script:UploadReply = $reply.Body
  if ($reply.Status -ne 201) { return '' }
  $id = $Utf8.GetString($reply.Body).Trim()
  if ($id -notmatch '^[0-9a-f-]+$') { return '' }
  for ($part = 1; $part -le $parts; $part++) {
    $offset = ($part - 1) * $PartBytes
    $length = [Math]::Min($PartBytes, $Body.Length - $offset)
    $chunk = New-Object byte[] $length
    [Array]::Copy($Body, $offset, $chunk, 0, $length)
    $sent = Invoke-Api 'PUT' "/v1/uploads/$id/parts/$part" $chunk 'application/octet-stream' $null
    $Script:UploadStatus = $sent.Status
    $Script:UploadReply = $sent.Body
    if ($sent.Status -ne 204) { return '' }
  }
  return $id
}

function Get-ReplyField([byte[]]$Body, [string]$Name) {
  try {
    $value = ($Utf8.GetString($Body) | ConvertFrom-Json).$Name
    if ($value) { return [string]$value }
  } catch { }
  return ''
}

# What a command says when Context Locker answers 401, from its answer: a
# connection revoked in Context Locker offers to come off the computer
# (G1-260), and any other to connect again, which the app offers the person
# rather than telling them to (G1-258)
function Write-GoneReply([byte[]]$Body) {
  if ((Get-ReplyField $Body 'error') -eq 'connection_revoked') {
    [Console]::Error.WriteLine("Context Locker: $AppName's connection on $(Get-Computer 'its computer') was revoked in Context Locker, so nothing syncs there any more. $(Get-RemoveOffer)")
  } else {
    [Console]::Error.WriteLine("Context Locker: $AppName's connection on $(Get-Computer 'its computer') was revoked or has expired. $ConnectOffer")
  }
}

# Sends an edit found in a synced file. Returns what the API said to do.
function Send-Edit([string]$Target, [string]$Kind, [string]$Path, [string]$Recorded, [string]$Query) {
  if ($Kind -eq 'block') {
    $lines = Get-Lines (Read-Text $Path)
    $body = $Utf8.GetBytes((Get-BlockText $lines (Get-BlockPosition $lines)))
    $type = 'text/plain'
  } else {
    $editIndex = $null
    if ($Recorded -and $Recorded -ne '-') {
      $indexReply = Invoke-Api 'GET' "/v1/sync/skills/$Recorded$Query" $null '' @{}
      if ($indexReply.Status -eq 200) { $editIndex = Read-SkillIndex $indexReply.Body }
    }
    $body = New-Bundle $Path $editIndex
    $type = 'application/octet-stream'
  }
  $headers = @{ 'Context-Locker-Target' = $Target }
  if ($Recorded -ne '-') { $headers['Context-Locker-Base'] = $Recorded }
  # A skill too big for one request goes up in parts first. When Context
  # Locker refuses a part, that's its answer to the edit; when it can't take
  # one just now, the edit waits for the next sync
  if ($body.Length -gt $PartBytes) {
    $upload = Send-Upload 'sync-edit' $body
    if (-not $upload) {
      $Script:EditReply = $Script:UploadReply
      if ($Script:UploadStatus -eq 0) { return 'offline' }
      if (@(400, 401, 403, 413) -contains $Script:UploadStatus) { return 'refused' }
      return 'error'
    }
    $headers['Context-Locker-Upload'] = $upload
    $body = [byte[]]@()
  }
  $reply = Invoke-Api 'POST' "/v1/sync/edits$Query" $body $type $headers
  $Script:EditReply = $reply.Body
  if ($reply.Status -eq 200) { return (Get-ReplyField $reply.Body 'status') }
  if ($reply.Status -eq 0) { return 'offline' }
  if ($reply.Status -ge 400 -and $reply.Status -lt 500) { return 'refused' }
  return 'error'
}

# --- One sync: global, or one project ---------------------------------------

# Whether a manifest changes any of the app's files: the files it lists,
# against those the last sync wrote, the app's own memory files among them
# (G1-299). The hash of its list when it does, and '' when it doesn't.
function Get-FilesChange([string[]]$Entries, [string[]]$LockLines) {
  $kinds = '^(block|skill|file|note|memory) '
  [string[]]$new = @($Entries | Where-Object { $_ -cmatch $kinds })
  [string[]]$old = @($LockLines | Where-Object { $_.StartsWith('entry ') } | ForEach-Object { $_.Substring(6) } | Where-Object { $_ -cmatch $kinds })
  [Array]::Sort($new, [StringComparer]::Ordinal)
  [Array]::Sort($old, [StringComparer]::Ordinal)
  $newHash = Get-Sha256Text ((@($new) | ForEach-Object { "$_`n" }) -join '')
  if ($newHash -eq (Get-Sha256Text ((@($old) | ForEach-Object { "$_`n" }) -join ''))) { return '' }
  return $newHash
}

# Each change is said once: $false when the one with this hash was said
# before, and otherwise $true, remembering it in the scope's .told file,
# unless the app doesn't read what the sync prints
function Test-NotTold([string]$Change, [string]$State) {
  $told = "$State.told"
  try {
    if ((Test-Path -LiteralPath $told -PathType Leaf) -and ([IO.File]::ReadAllText($told)).Trim() -eq $Change) { return $false }
  } catch { }
  if (-not $Quiet) { try { [IO.File]::WriteAllText($told, "$Change`n", $Utf8) } catch { } }
  return $true
}

# With auto sync off, the global sync's text for the session start comes in
# all the same, as it's about the playbook, such as changes waiting for
# approval, not part of it
function Get-ContextOnly([string]$State, [string[]]$Entries) {
  $contextFile = "$State.context"
  $want = ''
  foreach ($line in $Entries) { if ($line -match '^context ([0-9a-f]{64})$') { $want = $Matches[1] } }
  if (-not $want) {
    Remove-Item -LiteralPath $contextFile -Force -ErrorAction SilentlyContinue
    return
  }
  if ((Test-Path -LiteralPath $contextFile -PathType Leaf) -and (Get-Sha256File $contextFile) -eq $want) { return }
  $reply = Invoke-Api 'POST' '/v1/sync/blobs' ($Utf8.GetBytes("$want`n")) 'text/plain' @{}
  if ($reply.Status -ne 200) { return }
  try {
    $blobs = Join-Path $Tmp ('context.' + [Guid]::NewGuid().ToString('N').Substring(0, 6))
    [void](New-Item -ItemType Directory -Path $blobs)
    $archive = Join-Path $Tmp 'context.tar'
    [IO.File]::WriteAllBytes($archive, $reply.Body)
    # Windows PowerShell turns a native tool's stderr into errors, so don't stop on them
    $ErrorActionPreference = 'Continue'
    & tar -xmof $archive -C $blobs 2>$null
    $ok = ($LASTEXITCODE -eq 0)
    $ErrorActionPreference = 'Stop'
    $blob = Join-Path $blobs $want
    if ($ok -and (Test-Path -LiteralPath $blob -PathType Leaf) -and -not (Test-Link $blob) -and (Get-Sha256File $blob) -eq $want) {
      Copy-Item -LiteralPath $blob -Destination $contextFile -Force
    }
  } catch { }
}

# Counts a change to the app's files, for the line that says what a sync
# brought in: one made in the playbook since the last sync here, not a file
# put back as it was, or what a scope's first sync here writes
function Add-Change([string]$Kind, [string]$Target, $Changed) {
  if (-not $Changed.Contains($Target)) { return }
  switch ($Kind) {
    'block' { $Script:WBlocks++ }
    'skill' { $Script:WSkills++ }
    'note' { $Script:WNotes++ }
  }
}

# In a plan, what each step would do, in plain words
$Script:PlanOut = New-Object System.Collections.Generic.List[string]
function Add-Planned([string]$Text) { if ($Mode -eq 'plan') { $Script:PlanOut.Add($Text) } }

# Removal generations remain waiting until every known managed copy is gone.
function Get-SkillMarker([string]$Path) {
  $lines = @([IO.File]::ReadAllLines($Path))
  if ($lines.Count -and $lines[0] -cmatch '^Managed by Context Locker: skill ([0-9a-f-]{36}), version ([0-9]{1,9})\.$') {
    return @{ Item = $Matches[1]; Version = [int]$Matches[2] }
  }
  return $null
}

function Get-CleanupRoots {
  switch ($Harness) {
    'claude-code' { Join-Path (Get-RootDir 'claude') 'skills' }
    'codex' { Join-Path (Get-RootDir 'agents') 'skills' }
    'openclaw' { Join-Path (Get-RootDir 'agents') 'skills' }
    'hermes' { Join-Path (Get-RootDir 'hermes') 'skills' }
  }
  $suffix = switch ($Harness) { 'claude-code' { '.claude/skills' }; 'codex' { '.agents/skills' } }
  if (-not $suffix) { return }
  if ($Script:ProjectRoot) { Join-Path $Script:ProjectRoot $suffix }
  $registry = Join-Path $ClHome 'projects'
  if (Test-Path -LiteralPath $registry -PathType Leaf) {
    foreach ($line in [IO.File]::ReadAllLines($registry)) {
      if ($line -notmatch '^([0-9a-f-]{36}) (.+)$') { continue }
      $id = $Matches[1]; $folder = $Matches[2]
      if (-not (Test-Path -LiteralPath (Join-Path $AppDir "projects/$id.lock"))) { continue }
      if (-not (Test-Path -LiteralPath $folder -PathType Container)) { '?'; continue }
      Join-Path $folder $suffix
    }
  }
}

function Test-CleanupPath([string]$Path, [string]$Root) {
  $stop = Split-Path -Parent (Split-Path -Parent $Root)
  while ($Path -and $Path -ne $stop) {
    if (Test-Link $Path) { return $false }
    $parent = Split-Path -Parent $Path
    if ($parent -eq $Path) { break }
    $Path = $parent
  }
  return $true
}

function Get-Removals {
  if ($Script:RemovalsLoaded) { return }
  $Script:RemovalsLoaded = $true
  $Script:Removals = @()
  $reply = Invoke-Api 'GET' '/v1/sync/removals'
  if ($reply.Status -ne 200) { return }
  foreach ($line in (Get-Lines ($Utf8.GetString($reply.Body)))) {
    if ($line -cmatch '^remove ([0-9a-f-]{36}) ([0-9a-f-]{36}) ([0-9]{1,9}) project ([0-9a-f-]{36})$' -and $Matches[2] -ceq $Matches[4]) {
      $Script:ProjectRemovals += @{Id=$Matches[1];Project=$Matches[2];Version=[int]$Matches[3]}
    }
    if ($line -cmatch '^remove ([0-9a-f-]{36}) ([0-9a-f-]{36}) ([0-9]{1,9}) skill ([a-z0-9]+(?:-[a-z0-9]+)*)$') {
      $Script:Removals += @{ Id = $Matches[1]; Item = $Matches[2]; Version = [int]$Matches[3]; Name = $Matches[4] }
    }
  }
}

function Remove-ScopeCopies {
  if ($Mode -ne 'sync') { return }
  Get-Removals
  if (-not $Script:Removals.Count) { return }
  $root = switch ("$($Script:Scope) $Harness") {
    'global claude-code' { Join-Path (Get-RootDir 'claude') 'skills' }
    'global codex' { Join-Path (Get-RootDir 'agents') 'skills' }
    'global openclaw' { Join-Path (Get-RootDir 'agents') 'skills' }
    'global hermes' { Join-Path (Get-RootDir 'hermes') 'skills' }
    'project claude-code' { if ($Script:Layer -eq 'repo') { Join-Path $Script:ProjectRoot '.claude/skills' } }
    'project codex' { if ($Script:Layer -eq 'repo') { Join-Path $Script:ProjectRoot '.agents/skills' } }
  }
  if (-not $root) { return }
  $Script:CleanupRoots += $root
  foreach ($removal in $Script:Removals) {
    foreach ($dir in (Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue)) {
      $markerPath = Join-Path $dir.FullName '.ctx-managed'
      if (-not (Test-CleanupPath $markerPath $root) -or -not (Test-Path -LiteralPath $markerPath -PathType Leaf)) { continue }
      $marker = Get-SkillMarker $markerPath
      if (-not $marker -or $marker.Item -cne $removal.Item -or $marker.Version -gt $removal.Version) { continue }
      try {
        $target = "removed-$($removal.Id)-$(Get-Sha256Text $dir.FullName)"
        if (-not (Backup-Item $dir.FullName $target)) { throw 'Could not back up the managed copy.' }
        Remove-Item -LiteralPath $dir.FullName -Recurse -Force -ErrorAction Stop
        if (Test-Path -LiteralPath $dir.FullName) { throw 'The managed copy is still present.' }
        $Script:SkillsChanged = $true
        $Script:WSkills++
      } catch {
        [void](Invoke-Api 'POST' "/v1/sync/removals/$($removal.Id)" ($Utf8.GetBytes("skipped`nCould not safely back up and remove a managed copy.`n")) 'text/plain')
        Warn "couldn't remove a managed copy of $($removal.Name); cleanup stays waiting."
      }
    }
  }
}

function Confirm-Removals {
  if ($Script:RemovalsPaused -or -not $Script:Removals.Count) { return }
  $roots = @(@(Get-CleanupRoots) + $Script:CleanupRoots | Select-Object -Unique)
  foreach ($removal in $Script:Removals) {
    $waiting = $false
    foreach ($root in $roots) {
      if ($root -eq '?' -or -not (Test-CleanupPath $root $root)) { $waiting = $true; break }
      foreach ($dir in (Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue)) {
        $path = Join-Path $dir.FullName '.ctx-managed'
        if (-not (Test-CleanupPath $path $root)) { $waiting = $true; break }
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        $marker = Get-SkillMarker $path
        if (-not $marker) { $waiting = $true; break }
        if ($marker.Item -cne $removal.Item) { continue }
        if ($marker.Version -le $removal.Version) { $waiting = $true; break }
      }
    }
    if (-not $waiting) {
      [void](Invoke-Api 'POST' "/v1/sync/removals/$($removal.Id)" ($Utf8.GetBytes("done`nRemoved all known managed copies through the removed version.`n")) 'text/plain')
    }
  }
}

$Script:ProjectRemovals = @()
$Script:RemovalsLoaded = $false
$Script:Removals = @()
$Script:RemovalsPaused = $false
$Script:CleanupRoots = @()

function Remove-ProjectCopies([string]$Id, [int]$Version, [string]$State, [string[]]$LockLines) {
  if ($Mode -ne 'sync') { Add-Planned "Remove this playbook's managed files after keeping backups."; return 0 }
  if (-not $Script:ProjectRoot -or -not (Test-Path -LiteralPath $Script:ProjectRoot -PathType Container)) { return 1 }
  if (-not (Test-InsideProject '{project}/.context-locker/project-generation')) { return 1 }
  $generationPath = Join-Path $Script:ProjectRoot '.context-locker/project-generation'
  if (Test-Path -LiteralPath $generationPath -PathType Leaf) {
    $generation = (Read-Text $generationPath).Trim()
    if ($generation -cmatch '^[0-9]{1,9}$' -and [int]$generation -gt $Version) { return 1 }
  }
  Read-NotesRecords
  $records = @($LockLines | Where-Object { $_.StartsWith('wrote ') }) + @($Script:NotesRecords)
  $failed = $false
  foreach ($line in $records) {
    $f = $line.Split(' ')
    if ($f.Length -lt 4 -or $f[0] -cne 'wrote') { continue }
    $kind=$f[1]; $target=$f[3]
    if (-not $target.StartsWith('{project}/')) { continue }
    if (-not (Test-Allowed $target $kind) -or -not (Test-InsideProject $target)) { $failed=$true; continue }
    $path = Resolve-Target $target
    if (-not $path) { $failed=$true; continue }
    if (-not (Test-Path -LiteralPath $path)) { continue }
    try {
      if ($kind -eq 'skill') {
        $markerPath = Join-Path $path '.ctx-managed'
        if (-not (Test-Path -LiteralPath $path -PathType Container) -or -not (Test-Path -LiteralPath $markerPath -PathType Leaf) -or (Test-Link $markerPath)) { throw 'Unmanaged copy' }
        $marker=Get-SkillMarker $markerPath
        $expected = ''
        foreach ($entry in $LockLines) { $ef=$entry.Split(' '); if ($ef.Length -ge 6 -and $ef[0] -ceq 'entry' -and $ef[1] -ceq 'skill' -and $ef[3] -ceq $target) { $expected=$ef[4]; break } }
        if (-not $expected -or -not $marker -or $marker.Item -cne $expected) { throw 'Different managed copy' }
      } elseif (@('block','note','file') -notcontains $kind -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'Unrecognised file' }
      if (-not (Backup-Item $path "removed-project-$Id-$target")) { throw 'Backup failed' }
      if ($kind -eq 'block') { if ((Remove-Block $path $target) -ne 0) { throw 'Block removal failed' } }
      else { Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop; if ($kind -eq 'skill') { $Script:SkillsChanged=$true } }
    } catch { $failed=$true }
  }
  Remove-Item -LiteralPath "$State.context" -Force -ErrorAction SilentlyContinue
  if ($failed) { Warn "some managed copies couldn't be removed safely; cleanup stays waiting."; return 1 }
  [IO.File]::AppendAllText("$State.cleaned", "$Id $(Get-Sha256Text $Script:ProjectRoot)`n", $Utf8)
  $Script:Said.Add("Context Locker: removed this playbook's managed copies. Original files and backups stay.")
  return 0
}

function Confirm-ProjectRemovals {
  if ($Mode -ne 'sync' -or $Script:RemovalsPaused) { return }
  foreach ($removal in $Script:ProjectRemovals) {
    $state=Join-Path $AppDir "projects/$($removal.Project)"
    Remove-Item -LiteralPath "$state.context" -Force -ErrorAction SilentlyContinue
    $roots=@()
    if ($Script:ProjectId -ceq $removal.Project -and $Script:ProjectRoot) { $roots += $Script:ProjectRoot }
    $registry=Join-Path $ClHome 'projects'
    if (Test-Path -LiteralPath $registry -PathType Leaf) {
      foreach ($line in [IO.File]::ReadAllLines($registry)) {
        if ($line -cmatch '^([0-9a-f-]{36}) (.+)$' -and $Matches[1] -ceq $removal.Project) { $roots += $Matches[2] }
      }
    }
    $waiting=$false
    if (-not $roots.Count -and (Test-Path -LiteralPath "$state.lock") -and (Read-Text "$state.lock") -match '(?m)^wrote ') { $waiting=$true }
    $receipts=@()
    if (Test-Path -LiteralPath "$state.cleaned" -PathType Leaf) { $receipts=@([IO.File]::ReadAllLines("$state.cleaned")) }
    foreach ($root in ($roots | Select-Object -Unique)) {
      if (-not (Test-Path -LiteralPath $root -PathType Container) -or $receipts -cnotcontains "$($removal.Id) $(Get-Sha256Text $root)") { $waiting=$true; break }
    }
    if (-not $waiting) { [void](Invoke-Api 'POST' "/v1/sync/removals/$($removal.Id)" ($Utf8.GetBytes("done`nRemoved this playbook from every known project folder.`n")) 'text/plain') }
  }
}

# Keeps whether the per-prompt hook asks while a session runs, the
# connection's own setting (G1-298), as the global manifest says, in the
# app's folder, where the hook looks first. Each sync says it again, so a
# setting turned back on reaches the hook once a sync has run.
function Set-PromptSetting([string[]]$Entries) {
  $off = Join-Path $AppDir 'prompt-off'
  try {
    if ($Entries -ccontains 'prompt-line off') {
      if (-not (Test-Path -LiteralPath $off)) { [IO.File]::WriteAllText($off, '') }
    } elseif (Test-Path -LiteralPath $off) {
      Remove-Item -LiteralPath $off -Force
    }
  } catch { }
}

function Sync-Scope([string]$Query, [string]$State) {
  $Script:AgentsMdBytes = $null
  $Script:GlobalBytes = $null
  if ($Script:Scope -eq 'project' -and $Harness -in @('codex', 'hermes')) {
    $Script:AgentsMdBytes = Get-SharedAgentsRoom
  }
  if ($Script:Scope -eq 'global' -and $Harness -in @('hermes', 'openclaw')) {
    $Script:GlobalBytes = Get-GlobalRoom
  }
  $lockfile = "$State.lock"
  $lockLines = @()
  if (Test-Path -LiteralPath $lockfile -PathType Leaf) { $lockLines = @([IO.File]::ReadAllLines($lockfile)) }
  # What the last check of the project's pointers found
  $linksBefore = (@($lockLines | Where-Object { $_ -cmatch '^(links|missing) ' }) | ForEach-Object { "$_`n" }) -join ''
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
        if (-not $Query) { $Script:Broken = 'old' }
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
      if (-not $Query) { $Script:Broken = 'unreachable' }
      $Script:Failed = $true
      return 1
    }
    401 {
      # Revoked in Context Locker, it offers to come off the computer, never
      # to set up again (G1-260)
      if ((Get-ReplyField $reply.Body 'error') -eq 'connection_revoked') {
        Warn "the connection for $Harness on $(Get-Computer 'its computer') was revoked in Context Locker, so nothing syncs there any more. To take Context Locker off $(Get-Computer "$AppName's computer"), run: $Run remove $Harness"
        if (-not $Query) { $Script:Broken = 'revoked' }
      } else {
        Warn "the connection for $Harness on $(Get-Computer 'its computer') was revoked or has expired. Set it up again at context.locker/setup."
        if (-not $Query) { $Script:Broken = 'gone' }
      }
      $Script:Failed = $true
      return 1
    }
    404 {
      Warn "that project isn't in your playbook any more, so it was unlinked on $(Get-Computer "$AppName's computer")."
      return 3
    }
    default {
      Warn "Context Locker answered $($reply.Status), so nothing changed. The next sync tries again."
      if (-not $Query) { $Script:Broken = [string]$reply.Status }
      $Script:Failed = $true
      return 1
    }
  }
  # The newest script, as this answer names it, for the session start's line
  # (G1-258)
  if (-not $Query) { $Script:Answer = @($entries | Where-Object { $_ -cmatch '^(script|update) ' } | ForEach-Object { "entry $_" }) }

  if (-not $Query) {
    foreach ($line in $entries) { if ($line -match '^workspace ([0-9a-f-]{36})$') { $Script:WorkspaceId = $Matches[1] } }
  }

  # Whether the per-prompt hook asks while a session runs (G1-298)
  if (-not $Query -and $Mode -eq 'sync') { Set-PromptSetting $entries }

  if ($Mode -eq 'sync') { Get-Removals }
  if (-not $Query) { $Script:AutoSyncOff = ($entries -ccontains 'auto-sync off') }
  if ($Mode -eq 'sync' -and -not $Now -and ($entries -ccontains 'auto-sync off') -and ($Script:Removals.Count -or $Script:ProjectRemovals.Count)) {
    $Script:RemovalsPaused = $true
    $Script:ChangesWaiting = $true
    # The session start's text still comes in, as it does below (G1-104)
    if (-not $Query) { Get-ContextOnly $State $entries }
    return 0
  }

  # With auto sync off, a sync that would change the app's files says so,
  # once, and leaves them as they are until the app syncs with -Now, a daily
  # job's run too. The first sync here writes them all the same, as there's
  # nothing yet to leave as it is, and one that changes no file goes ahead.
  if ($Mode -eq 'sync' -and $fresh -and $oldEtag -and -not $Now -and ($entries -ccontains 'auto-sync off')) {
    $waiting = Get-FilesChange $entries $lockLines
    if ($waiting) {
      if (Test-NotTold $waiting $State) { $Script:ChangesWaiting = $true }
      if (-not $Query) { Get-ContextOnly $State $entries }
      return 0
    }
  }

  if ($Script:Scope -eq 'project') {
    foreach ($line in $entries) {
      if ($line -cmatch '^removed-project ([0-9a-f-]{36}) ([0-9]{1,9})$') {
        return (Remove-ProjectCopies $Matches[1] ([int]$Matches[2]) $State $lockLines)
      }
    }
    foreach ($line in $entries) {
      if ($Mode -eq 'sync' -and $line -cmatch '^project-generation ([0-9]{1,9})$') {
        $generation=[int]$Matches[1]
        if (-not (Test-InsideProject '{project}/.context-locker/project-generation')) { return 1 }
        $generationPath=Join-Path $Script:ProjectRoot '.context-locker/project-generation'
        if (Test-Path -LiteralPath $generationPath -PathType Leaf) {
          $current=(Read-Text $generationPath).Trim()
          if ($current -cmatch '^[0-9]{1,9}$' -and [int]$current -gt $generation) { return 1 }
        }
        [void](New-Item -ItemType Directory -Path (Split-Path -Parent $generationPath) -Force)
        Write-Into $generationPath "$generation`n"
        Set-FolderLink $Script:ProjectId $Script:ProjectRoot
      }
    }
  }

  Remove-ScopeCopies

  # A project's notes folder, when this sync keeps it: what's in it and what
  # Context Locker last wrote there. Edited notes and new files go up before
  # anything is written. A folder this sync doesn't keep is left as it is.
  $Script:NotesRecords = New-Object System.Collections.Generic.List[string]
  $Script:NotesLocal = @{}
  $Script:NotesMisnamed = New-Object System.Collections.Generic.List[string]
  $Script:NotesRefused = New-Object System.Collections.Generic.List[string]
  $Script:NotesOk = $false
  $Script:NotesSaved = $false
  $Script:NotesRescan = $false
  $notesWrote = New-Object System.Collections.Generic.List[string]
  if ($Script:Scope -eq 'project' -and $Mode -eq 'sync' -and (Test-NotesSynced $entries)) {
    if (Test-NotesFolder) {
      $Script:NotesOk = $true
      Read-NotesRecords
      Get-NotesLocal
      Send-Notes $Query $entries
      if ($Script:NotesSaved) {
        # The playbook changed, so the manifest did too
        $reply = Invoke-Api 'GET' "/v1/sync$Query" $null '' @{}
        $all = @()
        if ($reply.Status -eq 200) { $all = Get-Lines ($Utf8.GetString($reply.Body)) }
        if ($all.Length -eq 0 -or $all[0] -ne 'context-locker-sync 1' -or -not (Test-NotesSynced @($all | Select-Object -Skip 1))) {
          Warn "couldn't fetch the latest files after saving the notes, so the next sync finishes the job."
          $Script:Failed = $true
          [void](Write-NotesList $Script:NotesRecords)
          return 1
        }
        $entries = @($all | Select-Object -Skip 1)
        $etag = Get-Sha256Bytes $reply.Body
        $fresh = $true
        Get-NotesLocal
      } elseif ($Script:NotesRescan) {
        # An edit kept beside its note took the note's file away
        Get-NotesLocal
      }
    } else {
      Warn "left $(Get-NotesPath '.context-locker') alone: part of its path is a link, and links in a project aren't followed."
    }
  }

  # Whether the project's pointers to paths in its repo are there
  $Script:LinksChecked = $null
  $Script:MissingLinks = New-Object System.Collections.Generic.List[string]
  if ($Script:Scope -eq 'project' -and $Mode -eq 'sync') { Test-Links $entries }

  # What the manifest says, what this script last wrote, edits waiting for
  # approval, and edits the API refused, per target, and for the notes
  # folder, the note and version Context Locker last wrote there
  $order = New-Object System.Collections.Generic.List[string]
  $plan = @{}
  foreach ($line in $entries) {
    $f = $line.Split(' ')
    if (@('block', 'skill', 'file', 'note') -contains $f[0] -and $f.Length -ge 3) {
      $item = '-'; $ver = '-'
      if (($f[0] -eq 'skill' -or $f[0] -eq 'note') -and $f.Length -ge 5) { $item = $f[3]; $ver = $f[4] }
      $plan[$f[2]] = @{ Kind = $f[0]; S = $f[1]; R = '-'; Holds = @(); Refused = @(); Item = $item; Ver = $ver; RId = '-'; RVer = '-' }
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
    if ($f[0] -eq 'wrote' -and $f.Length -ge 4 -and ($f[1] -eq 'block' -or $f[1] -eq 'skill')) {
      if (-not $plan.ContainsKey($f[3])) {
        $plan[$f[3]] = @{ Kind = $f[1]; S = '-'; R = '-'; Holds = @(); Refused = @(); Item = '-'; Ver = '-'; RId = '-'; RVer = '-' }
        $order.Add($f[3])
      }
      $plan[$f[3]].R = $f[2]
    }
  }
  foreach ($line in $Script:NotesRecords) {
    $f = $line.Split(' ')
    if ($f[0] -eq 'wrote' -and $f.Length -ge 6) {
      if (-not $plan.ContainsKey($f[3])) {
        $plan[$f[3]] = @{ Kind = $f[1]; S = '-'; R = '-'; Holds = @(); Refused = @(); Item = '-'; Ver = '-'; RId = '-'; RVer = '-' }
        $order.Add($f[3])
      }
      $plan[$f[3]].R = $f[2]; $plan[$f[3]].RId = $f[4]; $plan[$f[3]].RVer = $f[5]
    }
  }
  # Skill write records predate item/version fields. Their previous manifest
  # entry supplies that identity, including when a newer session restored it.
  foreach ($line in $lockLines) {
    $f = $line.Split(' ')
    if ($f.Length -ge 6 -and $f[0] -eq 'entry' -and $f[1] -eq 'skill' -and $plan.ContainsKey($f[3])) {
      $plan[$f[3]].RId = $f[4]; $plan[$f[3]].RVer = $f[5]
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
    if ($kind -eq 'note' -or $kind -eq 'file') {
      # What Context Locker last wrote here stays on record, unless this
      # sync writes or removes it
      if ($R -ne '-') { $notesWrote.Add("wrote $kind $R $t $($p.RId) $($p.RVer)") }
      if (-not $Script:NotesOk) { continue }
      $path = Get-NotesPath $t.Substring('{project}/'.Length)
      if (Test-Link $path) {
        Warn "left $path alone: it's a link, and links in a project aren't followed."
        $skipped.Add("skipped link $t")
        continue
      }
      if ((Test-Path -LiteralPath $path) -and -not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Warn "left $path alone: it isn't a file."
        $skipped.Add("skipped not-a-file $t")
        continue
      }
      $L = if ($Script:NotesLocal.ContainsKey($t)) { $Script:NotesLocal[$t] } else { 'none' }
      if ($S -eq '-') {
        # Gone from the folder in Context Locker: take it away unless it
        # changed here. A note edited here went up before this, and stays.
        if ($L -eq 'none') { $notesWrote.Add("forget $t") }
        elseif ($L -eq $R) { $actions.Add(@{ Action = 'remove'; Target = $t; Kind = $kind; Expect = $L }) }
        elseif ($kind -eq 'file') { $actions.Add(@{ Action = 'untrack'; Target = $t; Kind = $kind }) }
        continue
      }
      $write = @{ Action = 'write'; Target = $t; Kind = $kind; Hash = $S; Item = $p.Item; Ver = $p.Ver; Keep = $false; Expect = $L }
      if ($L -eq $S) { $notesWrote.Add("wrote $kind $S $t $($p.Item) $($p.Ver)") }
      elseif ($L -eq 'none') { $actions.Add($write) }
      elseif ($R -eq '-' -or $L -eq $R -or $kind -eq 'file') {
        # Written over: a file the sync has no record of writing, or the
        # README edited here, is kept in the backups first
        $write.Keep = ($L -ne $R)
        $actions.Add($write)
      }
      # Otherwise it's a note edited here, which went up before this and
      # stays until Context Locker saves it
      continue
    }
    $path = Resolve-Target $t
    if (-not $path) {
      Add-Planned "Skip ${t}: there's no folder for it."
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
    if ($kind -eq 'skill' -and $S -eq '-' -and $L -ne 'none') {
      $marker = Get-SkillMarker (Join-Path $path '.ctx-managed')
      if ($marker -and @($Script:Removals | Where-Object { $_.Item -ceq $marker.Item }).Count) {
        $wrote.Add("wrote $kind $R $t")
        continue
      }
      if ($marker -and $p.RId -ne '-' -and ($marker.Item -cne $p.RId -or ($p.RVer -match '^[0-9]{1,9}$' -and $marker.Version -gt [int]$p.RVer))) {
        $wrote.Add("wrote $kind $R $t")
        continue
      }
    }
    if ($kind -eq 'skill' -and $S -ne '-' -and $L -ne 'none') {
      $marker = Get-SkillMarker (Join-Path $path '.ctx-managed')
      if ($marker -and $marker.Item -ceq $p.Item -and $p.Ver -match '^[0-9]{1,9}$' -and $marker.Version -gt [int]$p.Ver) {
        if ($R -ne '-') { $wrote.Add("wrote $kind $R $t") }
        continue
      }
    }
    # A skill this app also gets elsewhere is listed once (G1-221)
    if ($kind -eq 'skill' -and $S -ne '-' -and -not (Test-SkillTwin $t $path $S $L $lockLines $actions $wrote)) { continue }
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
      if ($kind -eq 'skill' -and $Mode -eq 'sync') {
        $markerPath = Join-Path $path '.ctx-managed'
        $marker = Get-SkillMarker $markerPath
        if ($marker -and $marker.Item -ceq $p.Item) {
          [IO.File]::WriteAllText($markerPath, "Managed by Context Locker: skill $($p.Item), version $($p.Ver).`nEdits here go to Context Locker at the next sync.`n$S`n", $Utf8)
        }
      }
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
      if ($kind -eq 'skill') { Add-Planned "Replace $what, which the sync has no record of. A copy goes in $backups first." }
      else { Add-Planned "Replace the Context Locker block in $path, which the sync has no record of writing. A copy of the file goes in $backups first." }
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
        { @('rejected', 'accepted', 'same', 'sent_back') -contains $_ } {
          if ($outcome -eq 'rejected') { Warn "your edit to $path was declined, so it was put back. A copy is in $(Join-Path $ClHome 'backups')." }
          if ($outcome -eq 'sent_back') { Warn "your edit to $path went back to you to make again, as what it changes changed in Context Locker since. The file has the current version, and your edit is in $(Join-Path $ClHome 'backups')." }
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

  # The targets whose files changed in the playbook since the last sync here
  $changed = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
  if ($oldEtag) {
    $kinds = '^(block|skill|file|note) '
    $old = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($line in $lockLines) {
      if ($line.StartsWith('entry ') -and $line.Substring(6) -cmatch $kinds) { [void]$old.Add($line.Substring(6)) }
    }
    foreach ($line in $entries) {
      if ($line -cnotmatch $kinds) { continue }
      if (-not $old.Remove($line)) { [void]$changed.Add($line.Split(' ')[2]) }
    }
    foreach ($line in $old) { [void]$changed.Add($line.Split(' ')[2]) }
  }

  # Text for the session start, kept on the computer so it shows offline too
  $contextHash = ''
  foreach ($line in $entries) { if ($line -match '^context ([0-9a-f]{64})$') { $contextHash = $Matches[1] } }
  $contextFile = "$State.context"
  if (-not $contextHash) { Remove-Item -LiteralPath $contextFile -Force -ErrorAction SilentlyContinue }
  elseif (-not (Test-Path -LiteralPath $contextFile) -or (Get-Sha256File $contextFile) -ne $contextHash) {
    $actions.Add(@{ Action = 'context'; Target = ''; Kind = 'context'; Hash = $contextHash })
  }

  # Reuse unchanged skill files locally, then fetch only the missing bytes.
  $wantList = New-Object System.Collections.Generic.List[string]
  $skillFetch = New-Object System.Collections.Generic.List[object]
  $blobs = Join-Path $Tmp ('blobs.' + [Guid]::NewGuid().ToString('N').Substring(0, 6))
  [void](New-Item -ItemType Directory -Path $blobs)
  foreach ($action in $actions) {
    if ($action.Action -ne 'write' -and $action.Action -ne 'context') { continue }
    if ($action.Kind -ne 'skill') { $wantList.Add($action.Hash); continue }
    $path = Resolve-Target $action.Target
    if (-not $path) { continue }
    $reply = Invoke-Api 'GET' "/v1/sync/skills/$($action.Hash)$Query" $null '' @{}
    if ($reply.Status -eq 404) { $wantList.Add($action.Hash); continue }
    $fileRows = $null
    if ($reply.Status -eq 200) { $fileRows = Read-SkillIndex $reply.Body }
    if ($null -eq $fileRows) {
      Warn "couldn't read the skill's file list, so $Harness keeps the files it has. The next sync tries again."
      $Script:Failed=$true
      return 1
    }
    $stage = Join-Path $blobs $action.Hash
    [void](New-Item -ItemType Directory -Force -Path $stage)
    foreach ($file in $fileRows) {
      $dest=Join-Path $stage $file.Path
      if ((Test-Path -LiteralPath $dest -PathType Leaf) -and (Get-Sha256File $dest) -eq $file.Hash) { continue }
      if (-not (Copy-CachedSkillFile $path $file.Path $file.Hash $dest)) {
        $wantList.Add($file.Hash)
        $skillFetch.Add(@{ Hash=$file.Hash; Dest=$dest })
      }
    }
  }
  $want=@($wantList | Sort-Object -Unique)
  # Fetch requested files, 500 at a time, as one answer holds at most 1,000.
  for ($at = 0; $at -lt $want.Length; $at += 500) {
    $chunk = @($want[$at..([Math]::Min($at + 499, $want.Length - 1))])
    $reply = Invoke-Api 'POST' "/v1/sync/blobs$Query" ($Utf8.GetBytes(($chunk -join "`n") + "`n")) 'text/plain' @{}
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
      [void](Write-NotesList $notesWrote)
      return 1
    }
  }

  foreach ($file in $skillFetch) {
    $source=Join-Path $blobs $file.Hash
    if (-not (Test-Path -LiteralPath $source -PathType Leaf) -or (Test-Link $source) -or (Get-Sha256File $source) -ne $file.Hash) {
      Warn "a skill file didn't arrive intact, so $Harness keeps the files it has. The next sync tries again."
      $Script:Failed=$true
      return 1
    }
    try {
      [void](New-Item -ItemType Directory -Force -Path (Split-Path -Parent $file.Dest))
      Copy-Item -LiteralPath $source -Destination $file.Dest -Force
    } catch { $Script:Failed=$true; return 1 }
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
        if ($result -eq 0) {
          $written++; $wrote.Add("wrote block $($a.Hash) $t"); Add-Change 'block' $t $changed
          $fit = Get-FitLine $t $path
          if ($fit) { Warn $fit }
        }
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
        if (Install-Skill $blob $path $a.Item $a.Ver $a.Hash) { $written++; $wrote.Add("wrote skill $($a.Hash) $t"); Add-Change 'skill' $t $changed }
        else { Warn "couldn't write $path."; $complete = $false }
      }
      'remove block' { try { if ((Remove-Block $path $t) -eq 0) { Add-Change 'block' $t $changed } } catch { $complete = $false } }
      'remove skill' {
        if (Backup-Item $path $t) { Remove-Item -LiteralPath $path -Recurse -Force; $Script:SkillsChanged = $true; Add-Change 'skill' $t $changed }
        else { $complete = $false }
      }
      'twin skill' {
        # The same skill comes from elsewhere, so Context Locker's copy goes,
        # while it's still as written, and the lock says why (G1-221)
        if ((Get-TreeHash $path) -eq $a.Expect -and (Backup-Item $path $t)) {
          Remove-Item -LiteralPath $path -Recurse -Force
          $Script:SkillsChanged = $true
          $wrote.Add("twin $($a.Hash) $t $($a.Other)")
          if (-not $Quiet) { $Script:Said.Add("Context Locker: left Context Locker's copy of the skill $($t.Substring($t.LastIndexOf('/') + 1)) out, as $($a.From) has the same skill, so sessions list it once.$($a.Note)") }
        } else { $wrote.Add("wrote skill $($a.Hash) $t") }
      }
      'untrack skill' {
        Remove-Item -LiteralPath (Join-Path $path '.ctx-managed') -Force -ErrorAction SilentlyContinue
        Warn "$path is no longer in your playbook. You'd changed it, so it stays here as your own."
      }
      'untrack block' { Warn "the Context Locker block in $path is no longer in your playbook. You'd changed it, so it stays as it is." }
      { $_ -eq 'write note' -or $_ -eq 'write file' } {
        $blob = Join-Path $blobs $a.Hash
        if (-not (Test-Path -LiteralPath $blob -PathType Leaf) -or (Get-Sha256File $blob) -ne $a.Hash) {
          Warn "the new content for $path didn't match its hash, so it wasn't written. The next sync tries again."
          $complete = $false; break
        }
        if (Test-Path -LiteralPath $path -PathType Leaf) {
          if ($a.Keep) {
            if (-not (Backup-Item $path $t)) {
              Warn "couldn't keep a copy of $path, so it wasn't written over."
              $complete = $false; break
            }
            if ($a.Kind -eq 'note') {
              Warn "replaced $path with the note from Context Locker, as the sync has no record of writing it there. A copy is in $(Join-Path $ClHome 'backups')."
            }
          } elseif ((Get-Sha256File $path) -ne $a.Expect) {
            # Changed since this sync looked, so it's an edit for the next one
            break
          }
        }
        Add-GitExclude
        try {
          Write-WholeFile $path ([IO.File]::ReadAllBytes($blob))
          $written++
          Add-Change $a.Kind $t $changed
          $notesWrote.Add("wrote $($a.Kind) $($a.Hash) $t $($a.Item) $($a.Ver)")
        } catch { Warn "couldn't write $path."; $complete = $false }
      }
      { $_ -eq 'remove note' -or $_ -eq 'remove file' } {
        # Only while it's still as Context Locker wrote it, and a copy is kept
        if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or (Get-Sha256File $path) -ne $a.Expect) { break }
        if (Backup-Item $path $t) {
          try { Remove-Item -LiteralPath $path -Force; Add-Change $a.Kind $t $changed; $notesWrote.Add("forget $t") } catch { $complete = $false }
        } else { $complete = $false }
      }
      'untrack file' {
        $notesWrote.Add("forget $t")
        Warn "$path is no longer from Context Locker. You'd changed it, so it stays as it is."
      }
    }
  }

  # The notes folder's own list of what Context Locker wrote there
  if (-not (Write-NotesList $notesWrote)) { $complete = $false }

  # The app's own memory files, after its block, as one file can hold both
  # (G1-299)
  if (-not $Query -and $Mode -eq 'sync') {
    $Script:MemorySaved = $false
    Sync-Memory $entries
    if ($Script:MemorySaved) {
      # What Context Locker keeps changed, so the manifest did too
      $reply = Invoke-Api 'GET' '/v1/sync' $null '' @{}
      $all = @()
      if ($reply.Status -eq 200) { $all = Get-Lines ($Utf8.GetString($reply.Body)) }
      if ($all.Length -gt 0 -and $all[0] -eq 'context-locker-sync 1') {
        $entries = @($all | Select-Object -Skip 1)
        $etag = Get-Sha256Bytes $reply.Body
        $fresh = $true
      } else {
        # The next sync reads the whole manifest again
        $complete = $false
      }
    }
  }

  $out = New-Object System.Text.StringBuilder
  [void]$out.Append("context-locker-lock 1`n")
  if ($complete) { [void]$out.Append("etag $etag`n") }
  [void]$out.Append("synced $([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ', $Invariant))`n")
  foreach ($line in $entries) { if ($line) { [void]$out.Append("entry $line`n") } }
  foreach ($line in $wrote) { [void]$out.Append("$line`n") }
  foreach ($line in $refusedOut) { [void]$out.Append("$line`n") }
  # What this check of the pointers found, kept to tell when it changes
  $linksNow = ''
  if ($null -ne $Script:LinksChecked) {
    $linksNow = "links $($Script:LinksChecked)`n" + ((@($Script:MissingLinks) | ForEach-Object { "missing $_`n" }) -join '')
  }
  [void]$out.Append($linksNow)
  [IO.File]::WriteAllText("$lockfile.tmp", $out.ToString(), $Utf8)
  if (Test-Path -LiteralPath $lockfile) { [IO.File]::Replace("$lockfile.tmp", $lockfile, [NullString]::Value) } else { [IO.File]::Move("$lockfile.tmp", $lockfile) }

  if (-not $complete) { $Script:Failed = $true }
  # The report goes with a new manifest, and when the missing paths changed
  if ($complete -and ($fresh -or ($null -ne $Script:LinksChecked -and $linksNow -cne $linksBefore))) {
    $missing = (@($Script:MissingLinks) | Select-Object -First 100 | ForEach-Object { "missing $_`n" }) -join ''
    $linksReport = if ($null -ne $Script:LinksChecked) { "links $($Script:LinksChecked)`n$missing" } else { '' }
    $report = "manifest $etag`nwritten $written`nheld $held`n" + (($skipped | Select-Object -First 100 | ForEach-Object { "$_`n" }) -join '') + $linksReport
    [void](Invoke-Api 'POST' "/v1/sync/done$Query" ($Utf8.GetBytes($report)) 'text/plain' @{})
  }
  return 0
}

# --- Which project this session is in ---------------------------------------

# The folder a session works in
$Start = if ($env:CLAUDE_PROJECT_DIR) { $env:CLAUDE_PROJECT_DIR } else { (Get-Location).ProviderPath }

# Runs git with nothing in the environment pointing it at another repo. Each
# variable is taken out with Remove-Item and put back as it was afterwards:
# PowerShell 7.6 hands git a variable that [Environment] set to null as an
# empty one, and git reads an empty GIT_DIR as a repo at ''.
function Invoke-Git([string[]]$Arguments) {
  if (-not (Get-Command git -ErrorAction SilentlyContinue)) { return @{ Output = ''; Code = 1 } }
  $names = @('GIT_DIR', 'GIT_WORK_TREE', 'GIT_COMMON_DIR', 'GIT_INDEX_FILE')
  $saved = @{}
  foreach ($name in $names) {
    $item = Get-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
    if ($item) {
      $saved[$name] = $item.Value
      Remove-Item -LiteralPath "Env:$name"
    }
  }
  try { return (Invoke-Native 'git' $Arguments) }
  finally {
    foreach ($name in $saved.Keys) { Set-Item -LiteralPath "Env:$name" -Value $saved[$name] }
  }
}

# The top folder of the git work tree $Dir is in, or '' outside one
function Get-GitTop([string]$Dir) {
  $inside = Invoke-Git @('-C', $Dir, 'rev-parse', '--is-inside-work-tree')
  if ($inside.Code -ne 0 -or $inside.Output.Trim() -ne 'true') { return '' }
  $top = Invoke-Git @('-C', $Dir, 'rev-parse', '--show-toplevel')
  $lines = @($top.Output.Trim() -split "`r?`n")
  if ($top.Code -ne 0 -or $lines.Length -ne 1 -or -not $lines[0]) { return '' }
  return ($lines[0] -replace '/', [IO.Path]::DirectorySeparatorChar)
}

# The workspace and project a .contextlocker.json names
function Read-LinkFile([string]$File) {
  $text = [IO.File]::ReadAllText($File)
  $ws = ''; $id = ''
  if ($text -match '"workspace"\s*:\s*"([0-9a-f-]{36})"') { $ws = $Matches[1] }
  if ($text -match '"project"\s*:\s*"([0-9a-f-]{36})"') { $id = $Matches[1] }
  return @{ Workspace = $ws; Project = $id }
}

# The project of the folder $From from what's on the computer: a
# .contextlocker.json naming this workspace, in it or a folder above it, or
# else the longest folder linked on the computer that holds it
function Find-LocalProject([string]$From) {
  $dir = $From
  while ($dir) {
    $file = Join-Path $dir '.contextlocker.json'
    if (Test-Path -LiteralPath $file -PathType Leaf) {
      $named = Read-LinkFile $file
      if ($named.Project -match $Uuid -and $Script:WorkspaceId -and $named.Workspace -eq $Script:WorkspaceId) {
        $Script:ProjectId = $named.Project; $Script:ProjectRoot = $dir; $Script:Layer = 'repo'
        return $true
      }
      break
    }
    if ($dir -eq $UserHome) { break }
    $parent = Split-Path -Parent $dir
    if (-not $parent -or $parent -eq $dir) { break }
    $dir = $parent
  }

  # Folders linked on the computer only: "<project id> <folder>" per line
  $map = Join-Path $ClHome 'projects'
  if (-not (Test-Path -LiteralPath $map -PathType Leaf)) { return $false }
  $best = ''
  $sep = [IO.Path]::DirectorySeparatorChar
  foreach ($line in [IO.File]::ReadAllLines($map)) {
    $space = $line.IndexOf(' ')
    if ($space -lt 1) { continue }
    $id = $line.Substring(0, $space); $folder = $line.Substring($space + 1)
    if (("$From$sep").StartsWith("$folder$sep") -and $folder.Length -gt $best.Length) {
      $best = $folder; $Script:ProjectId = $id
    }
  }
  if (-not $best) { return $false }
  $Script:ProjectRoot = $best; $Script:Layer = 'personal'
  return $true
}

# The project -Project names, in the repo's top folder or the current one:
# a repo whose .contextlocker.json names the same project is a linked repo
function Find-FlagProject {
  if ($Project -notmatch $Uuid) { return $false }
  $root = Get-GitTop $Start
  if (-not $root) { $root = $Start }
  $Script:ProjectId = $Project; $Script:ProjectRoot = $root; $Script:Layer = 'personal'
  $file = Join-Path $root '.contextlocker.json'
  if ((Test-Path -LiteralPath $file -PathType Leaf) -and $Script:WorkspaceId) {
    $named = Read-LinkFile $file
    if ($named.Workspace -eq $Script:WorkspaceId -and $named.Project -eq $Project) { $Script:Layer = 'repo' }
  }
  return $true
}

# The origin remote of the repo whose top folder is $Top, without a user
# name, password, query or fragment; '' when it has none, or it's a path on
# the computer. Context Locker is never sent a path on the computer.
function Get-OriginRemote([string]$Top) {
  $asked = Invoke-Git @('-C', $Top, 'remote', 'get-url', 'origin')
  if ($asked.Code -ne 0) { $asked = Invoke-Git @('-C', $Top, 'config', '--get', 'remote.origin.url') }
  $lines = @($asked.Output.Trim() -split "`r?`n")
  if ($asked.Code -ne 0 -or $lines.Length -ne 1) { return '' }
  $url = $lines[0]
  if (-not $url -or $url -match '[\s\\"]') { return '' }
  if ($url -match '^([A-Za-z][A-Za-z0-9+.-]*)://([^/]*)(.*)$') {
    if (@('http', 'https', 'ssh', 'git', 'git+ssh', 'ssh+git') -notcontains $Matches[1].ToLowerInvariant()) { return '' }
    $authority = $Matches[2]
    $url = $Matches[1] + '://' + $authority.Substring($authority.LastIndexOf('@') + 1) + $Matches[3]
  } elseif ($url -match '^[/.~]') {
    return ''
  } elseif ($url -match '^([^:]*):(.*)$') {
    # As git reads it: [user@]host:path, with no slash before the colon, and
    # a host longer than a drive letter
    $hostPart = $Matches[1]; $path = $Matches[2]
    if ($hostPart.Length -lt 2 -or $hostPart.Contains('/') -or $hostPart.EndsWith('@')) { return '' }
    $url = $hostPart.Substring($hostPart.LastIndexOf('@') + 1) + ':' + $path
  } else {
    return ''
  }
  $url = ($url -split '[?#]', 2)[0]
  if ($url.Length -gt 1000) { return '' }
  return $url
}

# Links the folder $Folder to the project $Id, for the computer only
function Set-FolderLink([string]$Id, [string]$Folder) {
  $map = Join-Path $ClHome 'projects'
  $lines = @()
  if (Test-Path -LiteralPath $map) {
    $lines = @([IO.File]::ReadAllLines($map) | Where-Object { $_.IndexOf(' ') -gt 0 -and $_.Substring($_.IndexOf(' ') + 1) -ne $Folder })
  }
  $lines += "$Id $Folder"
  [IO.File]::WriteAllText($map, (($lines | ForEach-Object { "$_`n" }) -join ''), $Utf8)
}

function Set-ProjectLink {
  if ($Project -notmatch $Uuid) { Warn '-Project needs a project''s id.'; $Script:Failed = $true; return }
  $root = Get-GitTop $Start
  if (-not $root) { $root = $Start }
  Set-FolderLink $Project $root
}

function Remove-ProjectLink([string]$Id) {
  $map = Join-Path $ClHome 'projects'
  $lines = @([IO.File]::ReadAllLines($map) | Where-Object { -not $_.StartsWith("$Id ") })
  [IO.File]::WriteAllText($map, (($lines | ForEach-Object { "$_`n" }) -join ''), $Utf8)
}

# The project whose git remote is this repo's origin, as Context Locker
# finds it. With "link", the folder is linked for the computer, as
# -Project links it, and a line says so.
function Find-RemoteProject([string]$How) {
  $top = Get-GitTop $Start
  if (-not $top) { return $false }
  $url = Get-OriginRemote $top
  if (-not $url) { return $false }
  $reply = Invoke-Api 'POST' '/v1/sync/remote' ($Utf8.GetBytes($url)) 'text/plain' @{}
  if ($reply.Status -ne 200) { return $false }
  $found = ConvertFrom-Reply $reply.Body
  $id = [string](Get-Field (Get-Property $found 'project') 'id')
  if ($id -notmatch $Uuid) { return $false }
  $Script:ProjectId = $id; $Script:ProjectRoot = $top; $Script:Layer = 'personal'
  if ($How -ne 'link') { return $true }
  Set-FolderLink $id $top
  $name = Get-Clean (Get-Field (Get-Property $found 'project') 'name')
  if (-not $name) { $name = 'its project' }
  $remote = Get-Clean (Get-Field $found 'git_remote')
  if (-not $remote) { $remote = $url }
  Warn "linked $top to $name by its git remote, $remote."
  return $true
}

# Records the origin remote of a folder linked with -Project on its
# project, when the project has none, so other clones find it. Quiet.
function Save-Remote([string]$Top) {
  $url = Get-OriginRemote $Top
  if (-not $url) { return }
  [void](Invoke-Api 'PUT' "/v1/sync/remote?project=$($Script:ProjectId)" ($Utf8.GetBytes($url)) 'text/plain' @{})
}

# Which project this session is in: the one -Project names, then a
# .contextlocker.json, then a folder linked on the computer, then the git
# remote, which "link" links and "ask" only asks about
function Find-Project([string]$How = 'local') {
  if ($Project) {
    if (-not (Find-FlagProject)) { return $false }
    $Script:FoundBy = 'flag'
    return $true
  }
  if (Find-LocalProject $Start) { $Script:FoundBy = 'local'; return $true }
  if (($How -eq 'link' -or $How -eq 'ask') -and (Find-RemoteProject $How)) {
    $Script:FoundBy = 'remote'
    return $true
  }
  return $false
}

# A daily run syncs every project linked on the computer too, in each
# folder that's still there, as far as the app works in projects: OpenClaw
# doesn't, and Hermes only in repos linked with a .contextlocker.json
function Sync-DailyProjects {
  if ($Harness -eq 'openclaw') { return }
  $map = Join-Path $ClHome 'projects'
  if (-not (Test-Path -LiteralPath $map -PathType Leaf)) { return }
  # Read the list first, as a sync can unlink a project that's gone
  $linked = @([IO.File]::ReadAllLines($map))
  $synced = @{}
  $gone = 0
  foreach ($line in $linked) {
    $space = $line.IndexOf(' ')
    if ($space -lt 1) { continue }
    $folder = $line.Substring($space + 1)
    if (-not [IO.Path]::IsPathRooted($folder)) { continue }
    if (-not (Test-Path -LiteralPath $folder -PathType Container)) { $gone++; continue }
    $Script:ProjectId = ''; $Script:ProjectRoot = ''; $Script:Layer = ''
    if (-not (Find-LocalProject $folder)) { continue }
    if ($Harness -eq 'hermes' -and $Script:Layer -ne 'repo') { continue }
    $key = "$($Script:ProjectId) $($Script:ProjectRoot)"
    if ($synced.ContainsKey($key)) { continue }
    $synced[$key] = $true
    $Script:Scope = 'project'
    $Script:Excluded = $false
    $result = Sync-Scope "?project=$($Script:ProjectId)&layer=$($Script:Layer)" (Join-Path (Join-Path $AppDir 'projects') $Script:ProjectId)
    if ($result -eq 3 -and $Script:Layer -eq 'personal') { Remove-ProjectLink $Script:ProjectId }
  }
  if ($gone -eq 1) {
    Warn "1 folder linked on $(Get-Computer "$AppName's computer") isn't there any more, so its project wasn't synced."
  } elseif ($gone -gt 1) {
    Warn "$gone folders linked on $(Get-Computer "$AppName's computer") aren't there any more, so their projects weren't synced."
  }
}

# --- Setup: sign-in, plan, doctor and read-back ------------------------------

$Script:Stdout = [Console]::OpenStandardOutput()
# What Say writes goes here instead, while something captures it
$Script:Capture = $null
function Write-Out([string]$Text) {
  if ($null -ne $Script:Capture) { [void]$Script:Capture.Append($Text); return }
  $bytes = $Utf8.GetBytes($Text); $Script:Stdout.Write($bytes, 0, $bytes.Length)
}
function Say([string]$Text) { Write-Out "$Text`n" }

# Quotes a word for sh, when it needs quoting
function ConvertTo-ShellText([string]$Text) {
  if ($Text -match '^[A-Za-z0-9/._~-]+$') { return $Text }
  return "'" + ($Text -replace "'", "'\''") + "'"
}

# Where setup saves this script, and how hooks run it
$Installed = Join-Path $ClHome 'sync.ps1'
$RunArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Installed)
if ($OnWindows) {
  $Run = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$Installed`""
} elseif ($ClHome -eq (Join-Path $UserHome '.contextlocker')) {
  $Run = 'pwsh -NoProfile -File ~/.contextlocker/sync.ps1'
} else {
  $Run = "pwsh -NoProfile -File $(ConvertTo-ShellText $Installed)"
}
$Trigger = switch ($Harness) { 'hermes' { 'Hermes hooks' } 'openclaw' { 'OpenClaw hook' } default { 'session-start hook' } }
$TriggerRuns = if ($Harness -eq 'hermes') { 'run' } else { 'runs' }
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

# "Claude Code on Ada's laptop, in the Personal workspace", from GET /v1/agent, or
# "Work Codex, in the Personal workspace" when the person named it
function Get-ConnectedAs([byte[]]$Body) {
  $reply = ConvertFrom-Reply $Body
  $agent = Get-Property $reply 'agent'
  $name = Get-Clean (Get-Field $agent 'name')
  $text = if ($name) { $name } else { $AppName }
  $machine = Get-Clean (Get-Field $agent 'machine_name')
  # A name the person chose says which this is; the app's own name needs the computer
  if ($machine -and $text -ceq $AppName) { $text += " on $machine" }
  $workspace = Get-Clean (Get-Field (Get-Property $reply 'workspace') 'name')
  if ($workspace) { $text += ", in the $workspace workspace" }
  return $text
}

# A random id for the computer, kept so that connecting an app again replaces
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

# Connects this app with a one-time code the person made in Context Locker,
# for a connection they've already named, so there's nothing to approve. The
# token goes straight into a file only this account can read, and the code is
# never printed. An app already connected takes the new connection's name and
# a fresh token, as the person asked for it.
function Invoke-Claim {
  $Script:Token = ''
  $claim = [ordered]@{ grant_type = 'urn:context-locker:params:oauth:grant-type:invite'; invite_code = $Code; harness = $Harness; agent_name = $AppName; client_version = "sync.ps1 $ScriptVersion"; os = $OsName }
  $name = Get-MachineName
  if ($name) { $claim['machine_name'] = $name }
  $claim['machine_id'] = Get-MachineId
  $where = Get-EnvironmentHere
  if ($where) { $claim['environment'] = $where }
  $reply = Invoke-Api 'POST' '/oauth/token' ($Utf8.GetBytes(($claim | ConvertTo-Json -Compress))) 'application/json' @{}
  if ($reply.Status -eq 0) { [Console]::Error.WriteLine("Context Locker: can't reach $Api. Check the internet connection and try again."); return 1 }
  if ($reply.Status -eq 400) { [Console]::Error.WriteLine("Context Locker: that code can't be used. It works once, for 15 minutes. Ask for a new one: the person makes it in Context Locker, from the connection's New code."); return 1 }
  if ($reply.Status -eq 429) { [Console]::Error.WriteLine('Context Locker: too many codes tried from this network just now. Try again in a few minutes.'); return 1 }
  $answer = ConvertFrom-Reply $reply.Body
  if ($reply.Status -ne 200) {
    $message = Get-Clean (Get-Field $answer 'error_description')
    if (-not $message) { $message = "Context Locker answered $($reply.Status)." }
    [Console]::Error.WriteLine("Context Locker: couldn't connect with the code: $message")
    return 1
  }
  $new = Get-Field $answer 'access_token'
  if ($new -notmatch '^ctxl_at_[A-Za-z0-9_-]+$') { [Console]::Error.WriteLine("Context Locker: the reply didn't include a usable token. Ask for a new code and try again."); return 1 }
  try { Write-Secret $TokenFile "$new`n" } catch { [Console]::Error.WriteLine("Context Locker: couldn't save the connection in $AppDir."); return 1 }
  # A device sign-in that was waiting isn't needed any more
  Remove-Item -LiteralPath (Join-Path $AppDir 'device') -Force -ErrorAction SilentlyContinue
  $Script:Token = $new
  $who = Invoke-Api 'GET' '/v1/agent' $null '' @{}
  if ($who.Status -eq 200) { Say "Connected: $(Get-ConnectedAs $who.Body)." } else { Say 'Connected.' }
  return 0
}

# Connects this app with a device code (RFC 8628). Only the link and the code
# are shown: the token goes straight into a file only this account can read.
# Where this app runs, as the setup command finds it: what -Environment says,
# or a Claude cloud session or codespace, and otherwise left to Context
# Locker, which takes it to run on the computer (G1-204, G1-260)
function Get-EnvironmentHere {
  if ($Environment) { return $Environment }
  if ($env:CODESPACES -eq 'true' -or $env:CLAUDE_CODE_REMOTE -eq 'true') { return 'cloud' }
  return ''
}

# Claude in Cowork gets Context Locker from the person's Claude account
# connector, so signin stops there unless -Environment cloud says to connect
# the sandbox on purpose. Another Claude cloud session hears that its sandbox
# may not last, and goes on. Keyed on CLAUDE_CODE_REMOTE, so a codespace
# signs in as before (G1-260).
function Test-ClaudeCloud {
  if ($Harness -ne 'claude-code' -or $env:CLAUDE_CODE_REMOTE -ne 'true' -or $Environment -eq 'cloud') { return $true }
  if ($env:CLAUDE_CODE_ENTRYPOINT -eq 'remote_cowork') {
    [Console]::Error.WriteLine("Context Locker: this is a Claude cloud session, such as Cowork or Claude on the web. It gets Context Locker from your account's Claude connector, which covers every chat, so device sync isn't needed here. To connect this sandbox on purpose, add -Environment cloud.")
    return $false
  }
  Say 'Context Locker: this is a Claude cloud session, whose sandbox may not last: a device connection made here ends with it.'
  return $true
}

function Invoke-Signin {
  if (-not (Test-ClaudeCloud)) { return 1 }
  if ($Code) { return Invoke-Claim }
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
    $where = Get-EnvironmentHere
    if ($where) { $start['environment'] = $where }
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

  Say "To connect $AppName on $(Get-Computer 'its computer'), open this link and approve the request:`n`n  $($device.link)`n`nCheck that the page shows the code $($device.user_code)."
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
# SessionStart command in a JSON file, or in Codex's config.toml, or with an
# event, that event's, such as the per-prompt hook's UserPromptSubmit
# (G1-271). Mentions elsewhere, such as a permission rule that names the
# script, don't count.
function Test-RunsScript([string]$Text) { return ($Text -match $ScriptPattern) -or $Text.Contains($Installed) }

function Test-HookIn([string]$Path, [string]$EventName = 'SessionStart') {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
  $text = [IO.File]::ReadAllText($Path)
  if ($Path.EndsWith('.toml')) {
    # [[hooks.<event>]] tables, up to the next table for another event
    $start = $false
    foreach ($line in ($text -split '\r?\n')) {
      if ($line -match '^\s*\[\[?hooks\.(\w+)') { $start = ($Matches[1] -eq $EventName) }
      elseif ($start -and $line -match '^\s*command(_windows|Windows)?\s*=' -and (Test-RunsScript $line)) { return $true }
    }
    return $false
  }
  try { $settings = $text | ConvertFrom-Json } catch { return $false }
  foreach ($group in @(Get-Property (Get-Property $settings 'hooks') $EventName)) {
    foreach ($hook in @(Get-Property $group 'hooks')) {
      $words = @((Get-Field $hook 'command'), (Get-Field $hook 'commandWindows')) + @(Get-Property $hook 'args' | ForEach-Object { [string]$_ })
      if (Test-RunsScript ($words -join ' ')) { return $true }
    }
  }
  return $false
}

function ConvertTo-JsonText([string]$Text) { return '"' + (($Text -replace '\\', '\\') -replace '"', '\"') + '"' }

# A hook as a plan shows it, for the session start, or with -Prompt, the
# per-prompt hook (G1-271)
function Write-HookJson([string]$App, [switch]$Prompt) {
  $words = if ($Prompt) { @('prompt', $App) } else { @($App) }
  $hookEvent = if ($Prompt) { 'UserPromptSubmit' } else { 'SessionStart' }
  $timeout = if ($Prompt) { 10 } else { 60 }
  if ($OnWindows -and $App -eq 'claude-code') {
    # Claude Code runs a command and its arguments directly, with no shell
    $argList = (@($RunArgs + $words) | ForEach-Object { ConvertTo-JsonText $_ }) -join ', '
    $hook = "{ `"type`": `"command`", `"command`": `"powershell.exe`", `"args`": [$argList], `"timeout`": $timeout }"
  } else {
    $command = ConvertTo-JsonText "$Run $($words -join ' ')"
    $windows = if ($OnWindows) { ", `"commandWindows`": $command" } else { '' }
    $hook = "{ `"type`": `"command`", `"command`": $command$windows, `"timeout`": $timeout }"
  }
  Say "    {`n      `"hooks`": {`n        `"$hookEvent`": [`n          {`n            `"hooks`": [`n              $hook`n            ]`n          }`n        ]`n      }`n    }"
}

# --- When each app syncs ------------------------------------------------------

# Each app runs the sync on its own events, all with the same command, so
# adding an app is a line here and its case in the plan and the doctor.
# Claude Code and Codex read what a session-start hook prints. Hermes and
# OpenClaw don't, so their hooks run it with -Hook, which keeps it quiet.
#
#   app          where the hook goes                     events
#   claude-code  settings.json, under SessionStart       startup, resume, clear, compact
#   codex        hooks.json, under SessionStart          startup, resume, clear, compact
#   hermes       config.yaml, under hooks                on_session_start, post_compaction
#   openclaw     ~/.openclaw/hooks/context-locker-sync   gateway:startup, command:new,
#                                                        command:reset, session:compact:before
#
# A second hook tells a session that's running of a new ask (G1-271): prompt
# on each prompt, on Claude Code's and Codex's UserPromptSubmit and Hermes's
# pre_llm_call, which runs before each turn. OpenClaw has no hook that hands
# the model a line, only a plugin's, so it hears at its next session.
function Get-HookEvents([string]$App) {
  switch ($App) {
    'hermes' { return @('on_session_start', 'post_compaction') }
    'openclaw' { return @('gateway:startup', 'command:new', 'command:reset', 'session:compact:before') }
    default { return @('startup', 'resume', 'clear', 'compact') }
  }
}

# The program and arguments a hook runs, with no shell to expand ~, as
# Hermes's and OpenClaw's do
$HookArgs = if ($OnWindows) { @('powershell.exe') + $RunArgs } else { @('pwsh', '-NoProfile', '-File', $Installed) }
$HookRun = if ($OnWindows) { "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$Installed`"" } else { "pwsh -NoProfile -File $(ConvertTo-ShellText $Installed)" }

# Text as YAML reads it: in single quotes, which keep backslashes, unless it
# has one of those
function ConvertTo-YamlText([string]$Text) {
  if ($Text.Contains("'")) { return (ConvertTo-JsonText $Text) }
  return "'$Text'"
}

# Whether Hermes's config.yaml runs the sync for each of its events: a command
# that runs this script, listed under the event in the hooks section
function Test-HermesHooksIn([string]$Path, [string[]]$Events = (Get-HookEvents 'hermes')) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
  $inHooks = $false
  $section = ''
  $found = @{}
  foreach ($line in ([IO.File]::ReadAllText($Path) -split '\r?\n')) {
    if ($line -match '^[^\s#]') { $inHooks = ($line -match '^hooks:\s*$'); $section = ''; continue }
    if ($inHooks -and $line -cmatch '^\s+([a-z_]+):\s*$') { $section = $Matches[1]; continue }
    if ($inHooks -and $section -and $line -match 'command:' -and (Test-RunsScript $line)) { $found[$section] = $true }
  }
  foreach ($e in $Events) { if (-not $found.ContainsKey($e)) { return $false } }
  return $true
}

function Write-HermesHooksYaml {
  $command = ConvertTo-YamlText "$HookRun hermes -Hook"
  Say '    hooks:'
  foreach ($e in (Get-HookEvents 'hermes')) { Say "      ${e}:`n        - command: $command" }
}

# Hermes's per-prompt hook, before each turn (G1-271)
function Write-HermesPromptYaml {
  Say "    hooks:`n      pre_llm_call:`n        - command: $(ConvertTo-YamlText "$HookRun prompt hermes")"
}

# OpenClaw's hook: a folder in its managed hooks folder, normally
# ~/.openclaw/hooks, with HOOK.md and a handler that runs the sync
$OpenClawHook = Join-Path (Join-Path (Join-Path $UserHome '.openclaw') 'hooks') 'context-locker-sync'

function Get-OpenClawHookMd {
  $events = (Get-HookEvents 'openclaw' | ForEach-Object { "`"$_`"" }) -join ', '
  return "---`nname: context-locker-sync`ndescription: `"Keeps OpenClaw's files in step with your Context Locker playbook`"`nmetadata: { `"openclaw`": { `"events`": [$events] } }`n---`n`n# Context Locker sync`n`nRuns Context Locker's sync when the gateway starts, when a session starts or resets, and before compaction, so OpenClaw's files hold your playbook as it is now.`n"
}

function Get-OpenClawHandler {
  $program = ConvertTo-JsonText $HookArgs[0]
  $argList = (@($HookArgs | Select-Object -Skip 1) + @('openclaw', '-Hook') | ForEach-Object { ConvertTo-JsonText $_ }) -join ', '
  return "import { execFile } from `"node:child_process`";`n`n// Runs the sync, waiting at most a minute, and never stops OpenClaw`nexport default function handler() {`n  return new Promise((resolve) => {`n    execFile($program, [$argList], { timeout: 60000, windowsHide: true }, () => resolve());`n  });`n}`n"
}

# Whether OpenClaw's hook is in place: HOOK.md with each of its events, and a
# handler that runs this script
function Test-OpenClawHookIn {
  $md = Join-Path $OpenClawHook 'HOOK.md'
  if (-not (Test-Path -LiteralPath $md -PathType Leaf)) { return $false }
  $text = [IO.File]::ReadAllText($md)
  foreach ($e in (Get-HookEvents 'openclaw')) { if (-not $text.Contains("`"$e`"")) { return $false } }
  foreach ($name in @('handler.ts', 'handler.js', 'index.ts', 'index.js')) {
    $file = Join-Path $OpenClawHook $name
    if (Test-Path -LiteralPath $file -PathType Leaf) { return (Test-RunsScript ([IO.File]::ReadAllText($file))) }
  }
  return $false
}

# Text shown as a file to save, four spaces in, with blank lines left blank
function Write-Indented([string]$Text) {
  foreach ($line in (Get-Lines $Text)) { if ($line) { Say "    $line" } else { Say '' } }
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
      if (Test-HookIn $settings 'UserPromptSubmit') { Say "Each prompt: the hook is already in $settings." }
      else {
        Say "`nEach prompt: add this hook to $settings as well, so a session that's running hears of a new ask:`n"
        Write-HookJson $Harness -Prompt
      }
    }
    'codex' {
      $dir = Get-RootDir 'codex'
      if ((Test-HookIn (Join-Path $dir 'hooks.json')) -or (Test-HookIn (Join-Path $dir 'config.toml'))) { Say "Session start: the hook is already set up in $dir." }
      else {
        Say "Session start: add this hook to $(Join-Path $dir 'hooks.json'), after any hooks already there. Codex skips a new hook until you trust it in /hooks:`n"
        Write-HookJson $Harness
      }
      if ((Test-HookIn (Join-Path $dir 'hooks.json') 'UserPromptSubmit') -or (Test-HookIn (Join-Path $dir 'config.toml') 'UserPromptSubmit')) { Say "Each prompt: the hook is already set up in $dir." }
      else {
        Say "`nEach prompt: add this hook to $(Join-Path $dir 'hooks.json') as well, so a session that's running hears of a new ask. Codex skips it until you trust it in /hooks:`n"
        Write-HookJson $Harness -Prompt
      }
    }
    'hermes' {
      $config = Join-Path (Get-RootDir 'hermes') 'config.yaml'
      if (Test-HermesHooksIn $config) { Say "Hooks: $config already runs the sync when a session starts and after compaction." }
      else {
        Say "Hooks: add these to the hooks section of $config, keeping everything already in the file, so Hermes syncs when a session starts and after compaction:`n"
        Write-HermesHooksYaml
        Say "`nHermes asks you to approve each one the first time it sees it, in a hermes chat. Its gateway never asks, so approve them in a chat first."
      }
      if (Test-HermesHooksIn $config @('pre_llm_call')) { Say "Each turn: $config already tells a session that's running of a new ask." }
      else {
        Say "`nEach turn: add this to the hooks section of $config as well, so a session that's running hears of a new ask. Approve it in a hermes chat too:`n"
        Write-HermesPromptYaml
      }
    }
    'openclaw' {
      if (Test-OpenClawHookIn) { Say "Hook: $OpenClawHook already runs the sync when the gateway starts, when a session starts or resets, and before compaction." }
      else {
        Say "Hook: save these two files in $OpenClawHook, on the computer where the OpenClaw gateway runs, so OpenClaw syncs when its gateway starts, when a session starts or resets, and before compaction.`n"
        Say "$(Join-Path $OpenClawHook 'HOOK.md'):`n"
        Write-Indented (Get-OpenClawHookMd)
        Say "`n$(Join-Path $OpenClawHook 'handler.js'):`n"
        Write-Indented (Get-OpenClawHandler)
        Say "`nThen turn it on, and restart the gateway if it was running, so it loads the hook:`n`n    openclaw hooks enable context-locker-sync"
      }
    }
  }
}

# --- How this app runs the sync (G1-87) ---------------------------------------

# Hermes and OpenClaw can also run the sync once a day from their own
# schedulers, with no model call, so they keep up between sessions. Claude
# Code and Codex can't run anything in the background, so they sync on their
# hooks' events only. The job has one name everywhere, and runs at a minute
# past 9 that comes from the computer's id, so computers don't all sync at
# once. Reading the id never creates it.
$DailyJob = 'contextlocker-daily'
$DailyJobFile = Join-Path $AppDir 'daily-job'
$ScheduleSent = Join-Path $AppDir 'schedule-sent'
$ScheduleFailed = Join-Path $AppDir 'schedule-failed'

function Get-JobMinute {
  $id = Get-MachineId -Saved
  if (-not $id) { $id = Get-Sha256Text ([Environment]::MachineName) }
  return ([Convert]::ToInt32($id.Substring(0, 4), 16) % 60).ToString('00', $Invariant)
}

# The computer's time zone, as a name such as Pacific/Auckland, or local
function Get-TimeZoneName {
  $name = ''
  try {
    $name = [TimeZoneInfo]::Local.Id
    if ($name -notmatch '/') {
      $iana = $null
      if ([TimeZoneInfo]::TryConvertWindowsIdToIanaId($name, [ref]$iana)) { $name = $iana }
    }
  } catch { }
  $name = ($name -replace ' ', '_') -replace '[^A-Za-z0-9_+./-]', ''
  if ($name.Length -gt 64) { $name = $name.Substring(0, 64) }
  if ($name -cmatch '^[A-Za-z]') { return $name }
  return 'local'
}

# The daily job as its app's scheduler lists it: its id, whether it's on, and
# its time when the listing says, or nothing when there's none. When the
# scheduler can't be asked, $Script:SchedulerAnswered is $false, so a second
# job is never added.
function Get-DailyJob {
  $Script:SchedulerAnswered = $false
  $Script:JobsListed = ''
  if (@('hermes', 'openclaw') -notcontains $Harness -or -not (Get-Command $Harness -ErrorAction SilentlyContinue)) { return $null }
  if ($Harness -eq 'hermes') {
    # A paragraph a job: its id and state, then lines such as Name: and
    # Schedule:
    $listed = Invoke-Native 'hermes' @('cron', 'list', '--all')
    if ($listed.Code -ne 0) { return $null }
    $Script:SchedulerAnswered = $true
    $Script:JobsListed = $listed.Output
    $plain = $listed.Output -replace "$([char]27)\[[0-9;]*m", ''
    foreach ($job in ($plain -split '\r?\n(?:[ \t]*\r?\n)+')) {
      if ($job -notmatch "Name:\s*$DailyJob(\s|$)" -and $job -notmatch 'Script:\s*contextlocker-sync\.sh') { continue }
      $words = @($job.Trim() -split '\s+')
      $time = ''
      if ($job -match 'Schedule:\s*(\d+)\s+(\d+)\s+\*\s+\*\s+\*' -and [int]$Matches[1] -lt 60 -and [int]$Matches[2] -lt 24) {
        $time = ([int]$Matches[2]).ToString('00', $Invariant) + ':' + ([int]$Matches[1]).ToString('00', $Invariant)
      }
      return @{ Id = (Get-Clean $words[0]); On = ($words.Count -gt 1 -and $words[1] -ceq '[active]'); Time = $time }
    }
    return $null
  }
  # OpenClaw lists its jobs as JSON
  $listed = Invoke-Native 'openclaw' @('cron', 'list', '--all', '--json')
  if ($listed.Code -ne 0) { return $null }
  $reply = $null
  try { $reply = $listed.Output | ConvertFrom-Json } catch { return $null }
  $Script:SchedulerAnswered = $true
  foreach ($job in @(Get-Property $reply 'jobs')) {
    if ((Get-Field $job 'name') -cne $DailyJob) { continue }
    $time = ''
    if ((Get-Field (Get-Property $job 'schedule') 'expr') -match '^(\d+) (\d+) \* \* \*$' -and [int]$Matches[1] -lt 60 -and [int]$Matches[2] -lt 24) {
      $time = ([int]$Matches[2]).ToString('00', $Invariant) + ':' + ([int]$Matches[1]).ToString('00', $Invariant)
    }
    return @{ Id = (Get-Clean (Get-Field $job 'id')); On = ((Get-Field $job 'enabled') -ne 'False'); Time = $time }
  }
  return $null
}

# The daily job the computer last heard of from its app's scheduler: its id,
# then its time when that's known. The sync's own reports read this rather
# than ask the scheduler, as OpenClaw's gateway can't answer while it waits
# for its own hook.
function Get-SavedDailyJob {
  try {
    if (-not (Test-Path -LiteralPath $DailyJobFile -PathType Leaf)) { return '' }
    $line = ((Read-Text $DailyJobFile) -split '\r?\n')[0] -replace '[^A-Za-z0-9._:@/ -]', ''
    if ($line.Length -gt 210) { $line = $line.Substring(0, 210) }
    return $line
  } catch { return '' }
}

# Asks the scheduler, as Get-DailyJob does, and keeps what it says of a job
# that's on. When the scheduler can't be asked, what's kept stays.
function Update-DailyJob {
  $job = Get-DailyJob
  if (-not $Script:SchedulerAnswered) { return $null }
  if ($job -and $job.On -and $job.Id) {
    $time = $job.Time
    $saved = @((Get-SavedDailyJob) -split ' ')
    if (-not $time -and $saved[0] -ceq $job.Id -and $saved.Count -gt 1) { $time = $saved[1] }
    $line = if ($time) { "$($job.Id) $time" } else { $job.Id }
    try { [IO.File]::WriteAllText($DailyJobFile, "$line`n", $Utf8) } catch { }
  } else {
    Remove-Item -LiteralPath $DailyJobFile -Force -ErrorAction SilentlyContinue
  }
  return $job
}

# What to say of a daily job that's there but doesn't run
function Get-JobOff([string]$Id) {
  if ($Harness -eq 'hermes') { return "Hermes's daily job, $Id, is paused or turned off, so it doesn't run. To run it again: hermes cron resume $Id" }
  return "OpenClaw's daily job, $Id, is turned off, so it doesn't run. To turn it back on: openclaw cron enable $Id"
}

# The plan's step for the daily job, which needs the person's yes of its own
$Script:PlanJob = $false
function Write-DailyJobPlan {
  if (@('hermes', 'openclaw') -notcontains $Harness) { return }
  $job = Get-DailyJob
  if ($job -and $job.On) { Say "`nDaily job: $AppName already runs the sync once a day, as job $($job.Id)." }
  elseif ($job) { Say "`nDaily job: $(Get-JobOff $job.Id)" }
  else {
    $Script:PlanJob = $true
    Say "`nDaily job: so $AppName keeps up between sessions, it can also run the sync once a day at 09:$(Get-JobMinute), from its own scheduler, with no model call. It stays quiet when the sync works, and says so when it fails. Ask the person, and only if they say yes, run:`n`n    $Run daily-job $Harness"
  }
}

# What this app has set up to run the sync, as Context Locker's report has
# it: its hooks' events, once its hooks are in place, and its daily job
function Get-ScheduleReport {
  $hooked = $false
  switch ($Harness) {
    'claude-code' { $hooked = Test-HookIn (Join-Path (Get-RootDir 'claude') 'settings.json') }
    'codex' {
      $dir = Get-RootDir 'codex'
      $hooked = (Test-HookIn (Join-Path $dir 'hooks.json')) -or (Test-HookIn (Join-Path $dir 'config.toml'))
    }
    'hermes' { $hooked = Test-HermesHooksIn (Join-Path (Get-RootDir 'hermes') 'config.yaml') }
    'openclaw' { $hooked = Test-OpenClawHookIn }
  }
  $report = if ($hooked) { "hooks $((Get-HookEvents $Harness) -join ' ')`n" } else { "hooks`n" }
  if (@('claude-code', 'codex') -contains $Harness) { return $report + "job unsupported`n" }
  $saved = @((Get-SavedDailyJob) -split ' ')
  $id = $saved[0]
  if ($id.Length -gt 200) { $id = $id.Substring(0, 200) }
  if (-not $id) { return $report + "job none`n" }
  if ($saved.Count -gt 1 -and $saved[$saved.Count - 1] -match '^[0-2][0-9]:[0-5][0-9]$') {
    return $report + "job daily $id $($saved[$saved.Count - 1]) $(Get-TimeZoneName)`n"
  }
  return $report + "job daily $id`n"
}

# Tells Context Locker how this app runs the sync, so its connection's page
# can say: what's set up, the last scheduled run that failed, and with ran,
# that this run its daily job started worked. A sync tells it when that
# changed, when it hasn't for a day, or when a failure waits to be told; the
# doctor, adding the daily job, and the end of a daily run always do.
function Send-Schedule([string]$Why = 'check') {
  try {
    $report = Get-ScheduleReport
    if ($Why -eq 'check' -and (Test-Path -LiteralPath $ScheduleSent -PathType Leaf) -and
      -not (Test-Path -LiteralPath $ScheduleFailed -PathType Leaf) -and
      ((Read-Text $ScheduleSent) -ceq $report) -and
      (Get-Item -LiteralPath $ScheduleSent).LastWriteTimeUtc -gt [DateTime]::UtcNow.AddDays(-1)) {
      return
    }
    $body = $report
    if (Test-Path -LiteralPath $ScheduleFailed -PathType Leaf) { $body += ((Read-Text $ScheduleFailed) -split '\r?\n')[0] + "`n" }
    if ($Why -eq 'ran') { $body += "ran`n" }
    $reply = Invoke-Api 'POST' '/v1/sync/schedule' ($Utf8.GetBytes($body)) 'text/plain' @{}
    if ($reply.Status -eq 200) {
      [IO.File]::WriteAllText($ScheduleSent, $report, $Utf8)
      Remove-Item -LiteralPath $ScheduleFailed -Force -ErrorAction SilentlyContinue
    } elseif ($reply.Status -ne 0 -and $reply.Status -lt 500) {
      # Refused, as by a Context Locker older than this: tomorrow's sync
      # tries again, or one after what's set up changes
      [IO.File]::WriteAllText($ScheduleSent, $report, $Utf8)
    }
  } catch { }
}

# A daily run that failed, kept to tell Context Locker when it can: when it
# failed, and the first thing it said
function Save-FailedRun {
  $said = ''
  if ($Script:Warnings.Count -gt 0) { $said = Get-Clean ($Script:Warnings[0] -replace '^Context Locker: ', '') }
  if ($said.Length -gt 400) { $said = $said.Substring(0, 400) }
  if (-not $said.Trim()) { $said = "The sync didn't finish." }
  try { [IO.File]::WriteAllText($ScheduleFailed, "failed $([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ', $Invariant)) $said`n", $Utf8) } catch { }
}

# Adds the daily job to Hermes's or OpenClaw's own scheduler, as the person
# said yes to, once: a job that's there already stays as it is
function Invoke-DailyJob {
  if (@('claude-code', 'codex') -contains $Harness) {
    [Console]::Error.WriteLine("Context Locker: $AppName can't run a job in the background, so it syncs on its hooks' events: when a session starts, resumes or is cleared, and when it's compacted.")
    return 1
  }
  if (-not (Get-Command $Harness -ErrorAction SilentlyContinue)) {
    [Console]::Error.WriteLine("Context Locker: the $Harness command isn't on this account's PATH, so the daily job wasn't added.")
    return 1
  }
  $job = Update-DailyJob
  if (-not $Script:SchedulerAnswered) {
    $gateway = if ($Harness -eq 'openclaw') { ' Is its gateway running?' } else { '' }
    [Console]::Error.WriteLine("Context Locker: couldn't list $AppName's jobs, so the daily job wasn't added, as it may be there already.$gateway")
    return 1
  }
  if ($job -and $job.On) {
    Say "$AppName already runs the sync once a day, as job $($job.Id)."
    Send-Schedule 'now'
    return 0
  }
  if ($job) {
    [Console]::Error.WriteLine("Context Locker: $(Get-JobOff $job.Id)")
    return 1
  }
  $minute = Get-JobMinute
  # The scheduler's minute has no leading zero
  $cron = "$([int]$minute) 9 * * *"
  if ($Harness -eq 'hermes') {
    # Hermes runs a script from its own scripts folder, so the job runs one
    # there that runs this one
    $scripts = Join-Path (Get-RootDir 'hermes') 'scripts'
    $wrapper = Join-Path $scripts 'contextlocker-sync.sh'
    $command = if ($OnWindows) { "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$Installed`" hermes -Daily" } else { "$Run hermes -Daily" }
    try {
      [void](New-Item -ItemType Directory -Force -Path $scripts)
      [IO.File]::WriteAllText($wrapper, "#!/bin/sh`nexec $command`n", $Utf8)
    } catch {
      [Console]::Error.WriteLine("Context Locker: couldn't write $wrapper, so the daily job wasn't added.")
      return 1
    }
    $added = Invoke-Native 'hermes' @('cron', 'create', $cron, '--no-agent', '--script', 'contextlocker-sync.sh', '--name', $DailyJob, '--deliver', 'origin') -Errors
  } else {
    $add = @('cron', 'add', '--name', $DailyJob, '--cron', $cron)
    if ($OnWindows) {
      # --command runs through sh, which Windows doesn't have, so give the
      # program and its arguments exactly. Windows PowerShell, and a .cmd
      # launcher, drop the quotes inside an argument unless they're \"
      $argv = '[' + ((@('powershell.exe') + $RunArgs + @('openclaw', '-Daily') | ForEach-Object { ConvertTo-JsonText $_ }) -join ',') + ']'
      $launcher = [string](Get-Command openclaw).Source
      if ($PSVersionTable.PSVersion.Major -lt 7 -or $launcher -match '\.(cmd|bat)$') { $argv = $argv.Replace('"', '\"') }
      $add += @('--command-argv', $argv)
    } else {
      $add += @('--command', "$Run openclaw -Daily")
    }
    $added = Invoke-Native 'openclaw' $add -Errors
  }
  $job = Update-DailyJob
  if (-not ($job -and $job.On)) {
    $said = (Get-Clean (($added.Output -replace "$([char]27)\[[0-9;]*m", '') -replace '\s+', ' ')).Trim()
    if ($said.Length -gt 300) { $said = $said.Substring(0, 300) }
    if ($added.Code -ne 0) {
      $more = if ($said) { ": $said" } else { '' }
      [Console]::Error.WriteLine("Context Locker: $AppName didn't add the daily job$more")
    } else {
      [Console]::Error.WriteLine("Context Locker: $AppName said it added the daily job, but doesn't list it. Check with: $Harness cron list")
    }
    return 1
  }
  # A job setup made runs at the time it gave it
  if ((Get-SavedDailyJob) -notmatch ' [0-2][0-9]:[0-5][0-9]$') {
    [IO.File]::WriteAllText($DailyJobFile, "$($job.Id) 09:$minute`n", $Utf8)
  }
  Send-Schedule 'now'
  Say "$AppName runs the sync once a day now, at 09:$minute ($((Get-TimeZoneName) -replace '_', ' ')), as job $($job.Id), with no model call. It stays quiet when the sync works, and says so when it fails. To stop it: $Harness cron remove $($job.Id)"
  return 0
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
  Move-Imported
  Say "Setup plan for $AppName on $(Get-Computer 'its computer'). Nothing has changed yet.`n`nFiles:"
  foreach ($line in $Script:PlanOut) { Say "- $line" }
  Say ''
  Write-HookPlan
  Write-DailyJobPlan
  Say "`nAlready here, and left as it is:"
  Write-ExistingFiles
  Say "`nIf this looks right, approve it once. Then:"
  if (-not (Test-Path -LiteralPath $Installed -PathType Leaf)) { Say "- Save this script as $Installed." }
  Say "- Write the files: $Run $Harness"
  Say "- Add the $Trigger shown above."
  if ($Script:PlanJob) { Say "- Only if the person said yes to the daily job, add it: $Run daily-job $Harness" }
  Say "- Check everything: $Run doctor $Harness"
  return 0
}

# Runs another program, never stopping on what it writes to stderr, which
# -Errors keeps with what it prints
function Invoke-Native([string]$Command, [string[]]$Arguments, [switch]$Errors) {
  $ErrorActionPreference = 'Continue'
  $output = ''
  $code = 1
  try {
    if ($Errors) { $output = (& $Command @Arguments 2>&1 | ForEach-Object { "$_" } | Out-String) }
    else { $output = (& $Command @Arguments 2>$null | Out-String) }
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

# --- The doctor's checks: caps, unmanaged files and drift ----------------------

# Days without a sync before the doctor says the hook or job may not be running
$DriftDays = 7

# What's in a managed skill's folder now: its marker's hash, while nothing in
# it is newer than the marker, or else the hash of its files
function Get-SkillNow([string]$Dir, [string]$Recorded) {
  $marker = @()
  try { $marker = @([IO.File]::ReadAllLines((Join-Path $Dir '.ctx-managed'))) } catch { }
  if ($marker.Length -ge 3 -and $marker[2] -cmatch $Hash -and $marker[2] -ceq $Recorded -and -not (Test-ChangedSince $Dir)) { return $marker[2] }
  return (Get-TreeHash $Dir)
}

# Checks what a lockfile says the last sync wrote: each block and skill as it
# was written, or with an edit that waits for approval, one Context Locker
# couldn't take, or one not yet saved in Context Locker, or gone
function Write-LockDoctor([string[]]$LockLines, [string]$Where) {
  $held = @{}
  $refused = @{}
  foreach ($line in $LockLines) {
    $f = $line.Split(' ')
    if ($f.Length -ge 4 -and $f[0] -ceq 'entry' -and $f[1] -ceq 'hold') { $held["$($f[2]) $($f[3])"] = $true }
    elseif ($f.Length -ge 3 -and $f[0] -ceq 'refused') { $refused["$($f[1]) $($f[2])"] = $true }
  }
  $blocks = 0
  $skills = 0
  foreach ($line in $LockLines) {
    $f = $line.Split(' ')
    if ($f[0] -ne 'wrote' -or $f.Length -lt 4) { continue }
    $t = $f[3]
    $path = Resolve-Target $t
    if (-not $path) { continue }
    if ($t.StartsWith('{project}/') -and -not (Test-InsideProject $t)) {
      Warning "Part of the path to $path is a link, so syncs leave it alone."
      continue
    }
    if ($f[1] -eq 'skill') {
      if (-not (Test-Path -LiteralPath (Join-Path $path '.ctx-managed') -PathType Leaf)) {
        Warning "The skill at $path is missing. The next sync adds it again."
        continue
      }
      $now = Get-SkillNow $path $f[2]
      $what = "the skill $($t.Substring($t.LastIndexOf('/') + 1)) at $path"
    } else {
      if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { Warning "$path is missing. The next sync writes it again."; continue }
      $lines = Get-Lines (Read-Text $path)
      $pos = Get-BlockPosition $lines
      if ($pos -eq 'none') { Warning "Context Locker's block is missing from $path. The next sync adds it again."; continue }
      if ($pos -eq 'broken') { Fail "The Context Locker markers in $path don't pair up, so syncs leave the file alone until someone fixes it by hand."; continue }
      $now = Get-Sha256Text (Get-BlockText $lines $pos)
      $what = "Context Locker's block in $path"
      $fit = Get-FitLine $t $path
      if ($fit) { Warning $fit }
    }
    if ($now -eq $f[2]) {
      if ($f[1] -eq 'skill') { $skills++ } else { $blocks++ }
    } elseif ($held.ContainsKey("$now $t")) {
      Pass "Your edit to $what is saved in Context Locker, and waits for approval in its inbox."
    } elseif ($refused.ContainsKey("$now $t")) {
      Warning "Context Locker couldn't take the edit to $what, so it won't update until the edit is undone or fixed."
    } else {
      Warning "$($what.Substring(0, 1).ToUpperInvariant() + $what.Substring(1)) has an edit that isn't saved in Context Locker yet. The next sync sends it."
    }
  }
  if ($skills -gt 0) { Pass "$(Get-Plural $blocks 'block' 'blocks') and $(Get-Plural $skills 'skill' 'skills') in place$Where." }
  elseif ($blocks -gt 0) { Pass "$(Get-Plural $blocks 'block' 'blocks') in place$Where." }
  # Skills this app also gets elsewhere, as the last sync found them (G1-221)
  foreach ($line in $LockLines) {
    $f = $line.Split(' ')
    if ($f[0] -ceq 'twin' -and $f.Length -ge 4) { $t = $f[2] }
    elseif ($f[0] -ceq 'twice' -and $f.Length -ge 3) { $t = $f[1] }
    else { continue }
    $name = $t.Substring($t.LastIndexOf('/') + 1)
    $found = Find-SkillElsewhere $name $t
    if ($null -eq $found) { continue }
    $from, $off, $note = Get-SkillSource $found.Kind $found.Dir
    if ($f[0] -ceq 'twin') { Pass "Context Locker's copy of the skill $name is left out here, as $from has the same skill, so sessions list it once.$note" }
    else { Warning "The skill $name is listed twice, as $from has a copy too, which differs from Context Locker's. To list it once, $off." }
  }
}

# How full each of the playbook's limits is, as Context Locker says: a PASS,
# WARN or FAIL line for each
function Write-CapsDoctor {
  $reply = Invoke-Api 'GET' '/v1/sync/caps' $null '' @{}
  $lines = @()
  if ($reply.Status -eq 200) { $lines = @(($Utf8.GetString($reply.Body) -replace "`r", '') -split "`n") }
  if ($reply.Status -ne 200 -or $lines.Length -eq 0 -or $lines[0] -cne 'context-locker-caps 1') {
    Warning "Couldn't check how full your playbook's limits are: Context Locker answered $($reply.Status)."
    return
  }
  foreach ($line in ($lines | Select-Object -Skip 1)) {
    if ($line.Length -lt 7) { continue }
    $text = Get-Clean $line.Substring(6)
    if (-not $text) { continue }
    $kind = $line.Substring(0, 6)
    if ($kind -ceq 'PASS  ') { Pass $text }
    elseif ($kind -ceq 'WARN  ') { Warning $text }
    elseif ($kind -ceq 'FAIL  ') { Fail $text }
  }
}

# --- Files Context Locker doesn't manage (G1-115) ----------------------------

# The doctor asks once about each instruction file, or folder of memories,
# with lines outside Context Locker's blocks: bring them into the playbook
# with Import, or keep them in the app only. The answers stay on this
# computer, in $Sources, a line for each file: the answer, keep or import,
# the day, the SHA-256 of the file's lines outside Context Locker's blocks,
# and its path. What an Import read is its answer once its plan is in. The
# doctor asks again only about a file that's new or changed since.
$Sources = Join-Path $ClHome 'sources'
$SourcesHeader = 'context-locker-sources 1'
$PathComparer = if ($OnWindows) { [StringComparer]::OrdinalIgnoreCase } else { [StringComparer]::Ordinal }
$PathComparison = if ($OnWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }

# A file's lines outside Context Locker's blocks that aren't blank, without
# the carriage return of a Windows line end: what the doctor asks about, as
# an Import's copy of the file holds them
function Get-OutsideLines([string]$Path) {
  $inside = $false
  [string[]]$found = @(foreach ($line in (Get-Lines (Read-Text $Path))) {
      if ($line -cmatch $StartLine) { $inside = $true; continue }
      if ($line -cmatch $EndLine) { $inside = $false; continue }
      if (-not $inside -and $line -match '[^ \t\r]') { $line -replace "`r\z", '' }
    })
  return , $found
}

# How many of those lines a file has, and their SHA-256, by which the doctor
# knows whether it changed since an answer: as sync.sh hashes them, a line
# break after each
function Get-OutsideOf([string]$Path) {
  $lines = Get-OutsideLines $Path
  $text = if ($lines.Length -gt 0) { ($lines -join "`n") + "`n" } else { '' }
  return @{ Lines = $lines.Length; Sha = (Get-Sha256Text $text) }
}

# A path as the doctor and keep compare it, in full
function Get-FullPath([string]$Path) { return [IO.Path]::GetFullPath($Path) }

# The answers kept so far, one line each
function Get-SourceAnswers {
  if (-not (Test-Path -LiteralPath $Sources -PathType Leaf) -or (Test-Link $Sources)) { return , @() }
  $lines = @()
  try { $lines = Get-Lines (Read-Text $Sources) } catch { return , @() }
  if ($lines.Length -eq 0 -or $lines[0] -cne $SourcesHeader) { return , @() }
  [string[]]$found = @($lines | Select-Object -Skip 1 | Where-Object { $_.Split("`t").Length -eq 4 })
  return , $found
}

# Records an answer, keep or import, for files, each @{ Sha; Path }, over any
# earlier one for the same path. Answers for files that are gone go.
function Save-SourceAnswers([string]$Answer, [object[]]$Files) {
  if ($Files.Length -eq 0) { return $true }
  if (Test-Link $Sources) { return $false }
  $day = [DateTime]::UtcNow.ToString('yyyy-MM-dd', $Invariant)
  $fresh = New-Object 'System.Collections.Generic.HashSet[string]' $PathComparer
  foreach ($file in $Files) { [void]$fresh.Add($file.Path) }
  $out = New-Object System.Text.StringBuilder
  [void]$out.Append("$SourcesHeader`n")
  foreach ($line in (Get-SourceAnswers)) {
    $path = $line.Split("`t")[3]
    if ($fresh.Contains($path) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
    [void]$out.Append("$line`n")
  }
  foreach ($file in $Files) { [void]$out.Append("$Answer`t$day`t$($file.Sha)`t$($file.Path)`n") }
  $next = "$Sources.$PID.next"
  try {
    [IO.File]::WriteAllText($next, $out.ToString(), $Utf8)
    Move-Item -LiteralPath $next -Destination $Sources -Force
  } catch {
    Remove-Item -LiteralPath $next -Force -ErrorAction SilentlyContinue
    return $false
  }
  return $true
}

# What's known of a source, a file or a folder, from its files, each
# @{ Lines; Sha; Path }: how many are new or changed since an answer, with
# how many lines, and the newest answer about the source, with its day
function Get-SourceState([string]$Path, [bool]$Folder, [object[]]$Files) {
  $known = New-Object 'System.Collections.Generic.HashSet[string]' $PathComparer
  $answer = ''
  $day = ''
  $under = $Path.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
  foreach ($line in (Get-SourceAnswers)) {
    $fields = $line.Split("`t")
    [void]$known.Add("$($fields[3])`t$($fields[2])")
    if ($fields[3].Equals($Path, $PathComparison) -or ($Folder -and $fields[3].StartsWith($under, $PathComparison))) {
      if (-not $day -or [string]::CompareOrdinal($fields[1], $day) -gt 0) { $day = $fields[1]; $answer = $fields[0] }
    }
  }
  $new = 0
  $lines = 0
  foreach ($file in $Files) {
    if (-not $known.Contains("$($file.Path)`t$($file.Sha)")) { $new++; $lines += $file.Lines }
  }
  return @{ New = $new; Lines = $lines; Answer = $answer; Day = $day }
}

# Quotes a word for the shell the person runs the script's commands in
function ConvertTo-CommandText([string]$Text) {
  if (-not $OnWindows) { return (ConvertTo-ShellText $Text) }
  if ($Text -match '^[A-Za-z0-9/\\._~:-]+$') { return $Text }
  return "'" + ($Text -replace "'", "''") + "'"
}

# Asks about one source, a file or a folder, by its files, unless nothing in
# it is new since the person answered, and then says what they chose
function Write-SourceDoctor([string]$Name, [string]$Path, [bool]$Folder, [object[]]$Files) {
  $state = Get-SourceState $Path $Folder $Files
  $choice = "Bring them into your playbook with Import ($Run import $Harness), or keep them in $AppName only ($Run keep $Harness $(ConvertTo-CommandText (ConvertTo-HomePath $Path)))."
  if (-not $state.Answer) {
    if ($Folder) { Warning "$Name, $(Get-Plural $Files.Length 'file holds' 'files hold') $(Get-Plural $state.Lines 'line' 'lines') outside Context Locker. $choice" }
    else { Warning "$Name has $(Get-Plural $state.Lines 'line' 'lines') outside Context Locker's block. $choice" }
    return
  }
  $when = (Format-Time "$($state.Day)T00:00:00Z") -replace ' at .*', ''
  if ($state.New -gt 0) {
    if ($Folder) {
      $since = if ($state.Answer -eq 'keep') { "you kept them in $AppName" } else { 'an Import read them' }
      Warning "$Name, have $(Get-Plural $state.New 'new or changed file' 'new or changed files') since $since on $when, with $(Get-Plural $state.Lines 'line' 'lines') outside Context Locker. $choice"
    } else {
      $since = if ($state.Answer -eq 'keep') { "you kept it in $AppName" } else { 'an Import read it' }
      Warning "$Name has changed since $since on $when, and has $(Get-Plural $state.Lines 'line' 'lines') outside Context Locker's block. $choice"
    }
  } elseif ($state.Answer -eq 'keep') {
    if ($Folder) { Pass "$Name, stay in $AppName only, as you chose on $when." }
    else { Pass "$Name stays in $AppName only, as you chose on $when." }
  } elseif ($Folder) { Pass "$Name, went into an Import on $when, and nothing in them is new since." }
  else { Pass "$Name went into an Import on $when, and hasn't changed since." }
}

# An instruction or memory file with lines Context Locker doesn't manage, as
# a source to ask about. A link isn't followed, as Import doesn't follow one.
function Write-UnmanagedFile([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf) -or (Test-Link $Path) -or (Test-Link (Split-Path -Parent $Path))) { return }
  $path = Get-FullPath $Path
  try { $of = Get-OutsideOf $path } catch { return }
  if ($of.Lines -le 0) { return }
  Write-SourceDoctor (Get-Clean (ConvertTo-HomePath $path)) $path $false @(@{ Lines = $of.Lines; Sha = $of.Sha; Path = $path })
}

# The text files under a folder, down to <depth>, as paths from it: hidden
# files and folders are left out, and no link is followed
function Get-TextFiles([string]$Dir, [int]$Depth, [string]$Names) {
  $item = Get-Item -LiteralPath $Dir -Force -ErrorAction SilentlyContinue
  if (-not $item -or -not $item.PSIsContainer -or (Test-ReparsePoint $item)) { return , @() }
  [string[]]$found = @(foreach ($rel in (Get-GatherPaths $Dir $Depth -Text)) {
      if ($rel -cmatch $Names -and -not (Test-Link (Join-Path $Dir ($rel -replace '/', [IO.Path]::DirectorySeparatorChar)))) { $rel }
    })
  return , $found
}

# A folder's text files with lines outside Context Locker, each
# @{ Lines; Sha; Path }
function Get-FolderSources([string]$Dir, [int]$Depth) {
  [object[]]$found = @(foreach ($rel in (Get-TextFiles $Dir $Depth '\.(md|markdown|mdx|mdc|txt)\z')) {
      $file = Join-Path $Dir ($rel -replace '/', [IO.Path]::DirectorySeparatorChar)
      try { $of = Get-OutsideOf $file } catch { continue }
      if ($of.Lines -gt 0) { @{ Lines = $of.Lines; Sha = $of.Sha; Path = $file } }
    })
  return , $found
}

# A folder of memories, such as Codex's, as one source to ask about: its text
# files with lines outside Context Locker. Hidden files and links are left out.
function Write-UnmanagedFolder([string]$Name, [string]$Dir, [int]$Depth) {
  $item = Get-Item -LiteralPath $Dir -Force -ErrorAction SilentlyContinue
  if (-not $item -or -not $item.PSIsContainer -or (Test-ReparsePoint $item)) { return }
  $dir = Get-FullPath $Dir
  $files = Get-FolderSources $dir $Depth
  if ($files.Length -eq 0) { return }
  Write-SourceDoctor "$Name, in $(Get-Clean (ConvertTo-HomePath $dir))" $dir $true $files
}

# The files in the project its playbook links to, from the last sync's link
# lines
function Get-LinkedFiles {
  $linked = New-Object 'System.Collections.Generic.HashSet[string]' $PathComparer
  if (-not $Script:ProjectId -or -not $Script:ProjectRoot) { return , $linked }
  $lock = Join-Path (Join-Path $AppDir 'projects') "$($Script:ProjectId).lock"
  if (-not (Test-Path -LiteralPath $lock -PathType Leaf)) { return , $linked }
  foreach ($line in (Get-Lines (Read-Text $lock))) {
    if ($line -cmatch '^entry link [0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12} (.+)$') {
      $file = Join-Path $Script:ProjectRoot ($Matches[1] -replace '/', [IO.Path]::DirectorySeparatorChar)
      if (Test-Path -LiteralPath $file -PathType Leaf) { [void]$linked.Add((Get-FullPath $file)) }
    }
  }
  return , $linked
}

# Whether a file only points at files the playbook links to, as a CLAUDE.md
# that imports AGENTS.md does: it imports at least one, with a line of @ and
# its path, and every other line outside Context Locker's blocks is one of
# those imports, a heading or a line that names a file it imports. Gives the
# names of the files it imports, or nothing.
function Get-PointsOnly([string]$Path, $Linked) {
  if ($Linked.Count -eq 0) { return '' }
  $dir = Split-Path -Parent $Path
  [string[]]$lines = @(foreach ($line in (Get-OutsideLines $Path)) { $line.Trim([char[]]@(' ', "`t")) })
  $names = New-Object System.Collections.Generic.List[string]
  foreach ($line in $lines) {
    if (-not $line.StartsWith('@')) { continue }
    $target = $line.Substring(1)
    if (-not $target -or $target -match '[ \t]') { return '' }
    if ($target.StartsWith('~/')) { $target = Join-Path $UserHome $target.Substring(2) }
    elseif (-not [IO.Path]::IsPathRooted($target)) { $target = Join-Path $dir $target }
    $target = $target -replace '/', [IO.Path]::DirectorySeparatorChar
    if (-not (Test-Path -LiteralPath $target -PathType Leaf)) { return '' }
    $full = Get-FullPath $target
    if (-not $Linked.Contains($full)) { return '' }
    $names.Add([IO.Path]::GetFileName($full))
  }
  if ($names.Count -eq 0) { return '' }
  foreach ($line in $lines) {
    if ($line.StartsWith('#') -or $line.StartsWith('@')) { continue }
    $named = $false
    foreach ($name in $names) { if ($line.Contains($name)) { $named = $true } }
    if (-not $named) { return '' }
  }
  return (@($names | Sort-Object -Unique -CaseSensitive) -join ' and ')
}

# One of the instruction files in the project's top folder: nothing to ask
# when the playbook links to it, or it only points at files the playbook
# links to
function Write-ProjectFile([string]$Path, $Linked) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf) -or (Test-Link $Path) -or (Test-Link (Split-Path -Parent $Path))) { return }
  $path = Get-FullPath $Path
  try { $of = Get-OutsideOf $path } catch { return }
  if ($of.Lines -le 0) { return }
  $shown = Get-Clean (ConvertTo-HomePath $path)
  if ($Linked.Contains($path)) { Pass "$shown is in your playbook as a link."; return }
  $names = Get-PointsOnly $path $Linked
  if ($names) { Pass "$shown only points at $names, which your playbook links to."; return }
  Write-SourceDoctor $shown $path $false @(@{ Lines = $of.Lines; Sha = $of.Sha; Path = $path })
}

# The app's own memory files, in a line or two, once Context Locker says
# whether they sync with this connection's memory (G1-299): $State is none,
# asked, on or off, as its manifest says, for $Script:MemoryConnection
function Write-MemoryDoctor([string]$State) {
  if ($State -eq 'asked') {
    Warning "$AppName's own memory files wait on your answer in your inbox in Context Locker: bring them into this connection's memory, or keep them where they are. Until then, syncs leave them as they are."
    return
  }
  if ($State -eq 'off') {
    Pass "$AppName's own memory files stay on $(Get-Computer 'its computer') only, as you chose. The connection's page in Context Locker can bring them into its memory."
    return
  }
  if ($State -ne 'on') { return }
  if (Test-MemoryRecordsOdd) {
    Warning "$(ConvertTo-HomePath $MemoryRecords) isn't a file of Context Locker's, so syncs leave $AppName's own memory files as they are. Take it away, and the next sync starts afresh."
    return
  }
  $records = Read-MemoryRecords
  if ($null -eq $records) {
    Warning (Get-MemoryMoved)
    return
  }
  Get-MemoryLocal
  # A clash a quiet run left as it is, while this side is as it was then
  $held = @(foreach ($t in $records.Held.Keys) {
      $now = if ($Script:MemoryLocal.ContainsKey($t)) { $Script:MemoryLocal[$t].Hash } else { 'none' }
      if ($records.Held[$t].Hash -eq $now) { $t }
    }).Count
  if ($held -gt 0) {
    Warning "$held of $AppName's own memory files changed both here and in Context Locker since the last sync. To put the two together, run: $Run $Harness -Now, which keeps the edit here beside the file and takes Context Locker's version."
  }
  $count = @($Script:MemoryLocal.Values | Where-Object { $_.Bytes -gt 0 }).Count
  if ($count -eq 0) {
    Pass "$AppName keeps no memory files here yet. Any it writes sync with this connection's memory in Context Locker."
    return
  }
  $kept = if ($count -eq 1) { "$AppName keeps 1 memory file here, which syncs" } else { "$AppName keeps $count memory files here, which sync" }
  # What Context Locker couldn't take, while it's as it was
  [string[]]$waiting = @(foreach ($t in $records.Refused.Keys) {
      if ($Script:MemoryLocal.ContainsKey($t) -and $Script:MemoryLocal[$t].Hash -eq $records.Refused[$t]) { $t }
    })
  if ($waiting.Length -eq 0) {
    Pass "$kept with this connection's memory in Context Locker."
    return
  }
  [Array]::Sort($waiting, [StringComparer]::Ordinal)
  Warning "$kept with this connection's memory in Context Locker, except what Context Locker couldn't take as it is, which waits until it changes: $(Get-ShortList @($waiting | ForEach-Object { Get-MemoryShown $_ }))."
}

# This app's instruction and memory files with lines outside Context
# Locker's blocks, and instruction files in the project's top folder that it
# doesn't manage, which Import can bring into the playbook: each one, or each
# folder of memories, is a source the doctor asks about. Once Context Locker
# says whether the app's own memory files sync with this connection's
# memory, as $Memory does, those are one line instead (G1-299).
function Write-UnmanagedDoctor([string]$Memory) {
  $sep = [IO.Path]::DirectorySeparatorChar
  switch ($Harness) {
    'claude-code' {
      $root = Get-RootDir 'claude'
      Write-UnmanagedFile (Join-Path $root 'CLAUDE.md')
      $rules = Join-Path $root 'rules'
      foreach ($rel in (Get-TextFiles $rules 4 '\.(md|mdc|txt)\z')) { Write-UnmanagedFile (Join-Path $rules ($rel -replace '/', $sep)) }
      # Each project's memory is a source of its own
      $projects = Join-Path $root 'projects'
      $item = Get-Item -LiteralPath $projects -Force -ErrorAction SilentlyContinue
      if (-not $Memory -and $item -and $item.PSIsContainer -and -not (Test-ReparsePoint $item)) {
        foreach ($folder in @(Get-ChildItem -LiteralPath $projects -Directory -Force -ErrorAction SilentlyContinue | Sort-Object -Property Name -CaseSensitive)) {
          $memoryFolder = Join-Path $folder.FullName 'memory'
          if (-not (Test-ReparsePoint $folder) -and (Test-Path -LiteralPath $memoryFolder -PathType Container)) {
            Write-UnmanagedFolder "Claude Code's memory" $memoryFolder 3
          }
        }
      }
    }
    'codex' {
      $root = Get-RootDir 'codex'
      Write-UnmanagedFile (Join-Path $root 'AGENTS.md')
      Write-UnmanagedFile (Join-Path $root 'AGENTS.override.md')
      if (-not $Memory) { Write-UnmanagedFolder "Codex's memories" (Join-Path $root 'memories') 3 }
    }
    'hermes' {
      $root = Get-RootDir 'hermes'
      if (-not $Memory) {
        foreach ($name in @('SOUL.md', 'USER.md', 'MEMORY.md')) { Write-UnmanagedFile (Join-Path $root $name) }
        Write-UnmanagedFolder "Hermes's memories" (Join-Path $root 'memories') 1
      }
    }
    'openclaw' {
      $root = Get-RootDir 'openclaw'
      # Its daily logs stay out of its memory, and the doctor no longer asks
      # about them either
      if (-not $Memory) {
        foreach ($name in @('AGENTS.md', 'SOUL.md', 'IDENTITY.md', 'USER.md', 'MEMORY.md')) { Write-UnmanagedFile (Join-Path $root $name) }
        Write-UnmanagedFolder "OpenClaw's daily memory logs" (Join-Path $root 'memory') 2
      }
    }
  }
  if ($Memory) { Write-MemoryDoctor $Memory }
  # The project's top folder: the project this folder is in, or the top of
  # its git work tree, but never the home folder
  $top = $Script:ProjectRoot
  if (-not $top) { $top = Get-GitTop $Start }
  if (-not $top) { $top = $Start }
  if (-not $top -or $top.TrimEnd($sep) -eq $UserHome.TrimEnd($sep) -or $top -eq [IO.Path]::GetPathRoot($top)) { return }
  $linked = Get-LinkedFiles
  foreach ($name in @('AGENTS.md', 'AGENTS.override.md', 'CLAUDE.md', 'CLAUDE.local.md', '.claude/CLAUDE.md')) {
    Write-ProjectFile (Join-Path $top ($name -replace '/', $sep)) $linked
  }
}

# Keeps a file, or a folder's files, in the app only, as the person chose:
# the doctor asks about them again only once they're new or changed
function Invoke-Keep {
  $given = $KeepPath
  if ($given -eq '~') { $path = $UserHome }
  elseif ($given.StartsWith('~/') -or $given.StartsWith('~\')) { $path = Join-Path $UserHome $given.Substring(2) }
  elseif ([IO.Path]::IsPathRooted($given)) { $path = $given }
  else { $path = Join-Path (Get-Location).ProviderPath $given }
  $path = Get-FullPath ($path -replace '/', [IO.Path]::DirectorySeparatorChar)
  if ($path.Length -gt 1 -and $path -ne [IO.Path]::GetPathRoot($path)) { $path = $path.TrimEnd([IO.Path]::DirectorySeparatorChar) }
  $shown = Get-Clean (ConvertTo-HomePath $path)
  $item = Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
  if ($item -and (Test-ReparsePoint $item)) {
    [Console]::Error.WriteLine("Context Locker: $shown is a link, and Context Locker doesn't follow links, so nothing was kept.")
    return 1
  }
  if (-not $item) {
    [Console]::Error.WriteLine("Context Locker: there's no file or folder at $shown, so nothing was kept.")
    return 1
  }
  if ($item.PSIsContainer) {
    $files = Get-FolderSources $path 4
  } else {
    $files = @()
    try {
      $of = Get-OutsideOf $path
      if ($of.Lines -gt 0) { $files = @(@{ Lines = $of.Lines; Sha = $of.Sha; Path = $path }) }
    } catch { }
  }
  if ($files.Length -eq 0) {
    Say "$shown holds nothing outside Context Locker's blocks, so there's nothing to keep."
    return 0
  }
  if (-not (Save-SourceAnswers 'keep' $files)) {
    [Console]::Error.WriteLine("Context Locker: couldn't write $(ConvertTo-HomePath $Sources), so nothing was kept.")
    return 1
  }
  if ($item.PSIsContainer) {
    Say "Kept in $AppName only: $(Get-Plural $files.Length 'file' 'files') in $shown. The doctor asks about them again only once one is new or changes. To bring them into your playbook later, run Import: $Run import $Harness"
  } else {
    Say "Kept in $AppName only: $shown. The doctor asks about it again only once it changes. To bring it into your playbook later, run Import: $Run import $Harness"
  }
  return 0
}

# Once a plan is in, what its Import copied counts as read, so the doctor
# asks about those files again only once they're new or changed. The working
# set is the one whose plan has the same id.
function Save-ImportRead([string]$Plan) {
  $id = ''
  try {
    if ((Read-Text $Plan) -match '"plan_id"\s*:\s*"([0-9a-f-]+)"') { $id = $Matches[1] }
  } catch { return }
  if (-not $id) { return }
  $root = Join-Path $ClHome 'gather'
  $set = ''
  foreach ($found in (Get-GatherSets $root)) {
    $candidate = Join-Path $root $found.Name
    try {
      if ((Read-Text (Join-Path $candidate 'plan.json')) -match '"plan_id"\s*:\s*"([0-9a-f-]+)"' -and $Matches[1] -ceq $id) { $set = $candidate; break }
    } catch { }
  }
  if (-not $set) { return }
  $table = Join-Path $set 'sources.tsv'
  if (-not (Test-Path -LiteralPath $table -PathType Leaf)) { return }
  $sep = [IO.Path]::DirectorySeparatorChar
  # Get-Lines gives its lines as one array, so they're piped from a variable,
  # which passes them on one at a time
  $rows = Get-Lines (Read-Text $table)
  [object[]]$files = @(foreach ($line in ($rows | Select-Object -Skip 1)) {
      $fields = $line.Split("`t")
      if ($fields.Length -lt 8 -or $fields[1] -eq 'skill') { continue }
      $path = $fields[2]
      if ($path.StartsWith('~/')) { $path = Join-Path $UserHome ($path.Substring(2) -replace '/', $sep) }
      elseif (-not [IO.Path]::IsPathRooted($path)) { continue }
      if (('/' + $fields[6] + '/') -match '/\.\./') { continue }
      $copy = Join-Path $set ($fields[6] -replace '/', $sep)
      if (-not (Test-Path -LiteralPath $copy -PathType Leaf) -or (Test-Link $copy)) { continue }
      try { $of = Get-OutsideOf $copy } catch { continue }
      @{ Sha = $of.Sha; Path = (Get-FullPath $path) }
    })
  [void](Save-SourceAnswers 'import' $files)
}

function Invoke-Doctor {
  $Script:Fails = 0
  $Script:Warns = 0
  function Pass([string]$Text) { Say "PASS  $Text" }
  function Warning([string]$Text) { Say "WARN  $Text"; $Script:Warns++ }
  function Fail([string]$Text) { Say "FAIL  $Text"; $Script:Fails++ }

  if (-not (Test-Path -LiteralPath $Installed -PathType Leaf)) {
    Fail "The sync script isn't at $Installed, where the $Trigger $TriggerRuns it. Save it there."
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
  if (Test-NewerScript) {
    if (Test-CanUpdate) {
      Warning "Version $($Script:NewestScript) of the sync script is out, and updating to it changes only the script. When it suits you, run: $Run update $Harness"
    } else {
      # Offered, as the session start does (G1-258)
      Warning "A newer version of the sync script is out. When it suits the person, offer to set Context Locker up again for them: once they say yes, $SetupSteps. This one keeps working until then."
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
        Warning "Other accounts on $(Get-Computer "$AppName's computer") can read $TokenFile. Run: chmod 600 $(ConvertTo-ShellText $TokenFile)"
      }
    }
    $reply = Invoke-Api 'GET' '/v1/agent' $null '' @{}
    if ($reply.Status -eq 200) { $connected = $true; Pass "Connected: $(Get-ConnectedAs $reply.Body)." }
    elseif ($reply.Status -eq 401) {
      # A revoked connection offers to come off the computer, never to set up
      # again (G1-260)
      if ((Get-Field (ConvertFrom-Reply $reply.Body) 'error') -eq 'connection_revoked') {
        Fail "$AppName's connection on $(Get-Computer 'its computer') was revoked in Context Locker, so nothing syncs there any more. To take Context Locker off $(Get-Computer "$AppName's computer"), run $Run remove $Harness to see what it takes out, and only once the person says yes, run it again with -Yes."
      } else { Fail "$AppName's connection on $(Get-Computer 'its computer') was revoked or has expired. Run: $Run signin $Harness" }
    }
    elseif ($reply.Status -eq 0) { Fail "Can't reach Context Locker at $Api." }
    else { Fail "Context Locker answered $($reply.Status) when asked about this connection." }
  }

  # How full the playbook's limits are, from Context Locker
  if ($connected) { Write-CapsDoctor }

  $lock = Join-Path $AppDir 'global.lock'
  $lockLines = @()
  if (Test-Path -LiteralPath $lock -PathType Leaf) { $lockLines = @([IO.File]::ReadAllLines($lock)) }
  $syncedAt = ''
  $autoOff = $false
  $etag = ''
  foreach ($line in $lockLines) {
    if (-not $syncedAt -and $line.StartsWith('synced ')) { $syncedAt = $line.Substring(7) }
    if ($line -match '^etag ([0-9a-f]{64})$') { $etag = $Matches[1] }
  }
  # Whether the person switched off the per-prompt hook's line for this
  # connection (G1-298), as Context Locker says now, or the last sync kept it
  $promptOff = Test-Path -LiteralPath (Join-Path $AppDir 'prompt-off')
  # Whether the app's own memory files sync with this connection's memory
  # (G1-299), as Context Locker says now, or the last sync kept it
  $memoryState = ''
  foreach ($line in $lockLines) {
    if ($line -cmatch '^entry memory-files ([a-z]+) (\S+)\z') { $memoryState = $Matches[1]; $Script:MemoryConnection = $Matches[2]; break }
  }
  if (-not $syncedAt) {
    Fail "Nothing has synced yet. Run: $Run $Harness"
  } else {
    $synced = Format-Time $syncedAt
    if (-not $etag) { Warning "The last sync didn't finish ($synced). The next one tries again." }
    elseif ($connected) {
      $reply = Invoke-Api 'GET' '/v1/sync' $null '' @{ 'If-None-Match' = "`"$etag`"" }
      if ($reply.Status -eq 304) {
        Pass "The files match your playbook. Last synced $synced."
        $promptOff = ($lockLines -ccontains 'entry prompt-line off')
      }
      elseif ($reply.Status -eq 200) {
        $all = Get-Lines ($Utf8.GetString($reply.Body))
        $entries = @($all | Select-Object -Skip 1)
        if (($entries -ccontains 'auto-sync off') -and (Get-FilesChange $entries $lockLines)) {
          $autoOff = $true
          Warning "Your playbook has changed since the last sync ($synced). Auto sync is off, so the files stay as they are until a sync with -Now: $Run $Harness -Now"
        } else {
          Warning "Your playbook has changed since the last sync ($synced). The next sync brings the files up to date."
        }
        $promptOff = ($entries -ccontains 'prompt-line off')
        $memoryState = ''
        foreach ($line in $entries) {
          if ($line -cmatch '^memory-files ([a-z]+) (\S+)\z') { $memoryState = $Matches[1]; $Script:MemoryConnection = $Matches[2]; break }
        }
      }
      else { Warning "Couldn't compare the files with your playbook: Context Locker answered $($reply.Status)." }
    }
    # A sync more than 7 days ago means the hooks aren't running, unless
    # auto sync is off and changes are waiting
    if (-not $autoOff -and $syncedAt -match '^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})') {
      $seconds = 0
      try {
        $then = New-Object DateTimeOffset -ArgumentList ([int]$Matches[1]), ([int]$Matches[2]), ([int]$Matches[3]), ([int]$Matches[4]), ([int]$Matches[5]), ([int]$Matches[6]), ([TimeSpan]::Zero)
        $seconds = ([DateTimeOffset]::UtcNow - $then).TotalSeconds
      } catch { }
      if ($seconds -gt $DriftDays * 86400) {
        Warning "The last sync was on $synced, $(Get-Plural ([int][Math]::Floor($seconds / 86400)) 'day ago' 'days ago'). Check that the $Trigger $TriggerRuns, or sync now: $Run $Harness -Now"
      }
    }
    Write-LockDoctor $lockLines ''
  }

  foreach ($line in $lockLines) {
    if ($line -match '^entry workspace ([0-9a-f-]{36})$') { $Script:WorkspaceId = $Matches[1] }
  }
  Write-ProjectDoctor
  Write-LinkedDoctor
  if (@('none', 'asked', 'on', 'off') -cnotcontains $memoryState -or $Script:MemoryConnection -cnotmatch $Uuid) { $memoryState = '' }
  Write-UnmanagedDoctor $memoryState

  $promptOffLine = "Hearing of new asks while a session runs is off for this connection, on its page in Connections, so the per-prompt hook asks nothing and a new ask shows when the next session starts."
  switch ($Harness) {
    'claude-code' {
      $settings = Join-Path (Get-RootDir 'claude') 'settings.json'
      if (Test-HookIn $settings) { Pass "The session-start hook is in $settings." }
      else { Fail "The session-start hook isn't in $settings. Run: $Run plan $Harness, and add the hook it shows." }
      if ($promptOff) { Pass $promptOffLine }
      elseif (Test-HookIn $settings 'UserPromptSubmit') { Pass "The per-prompt hook is in $settings." }
      else { Warning "The per-prompt hook isn't in $settings, so a session that's running hears of a new ask only when the next one starts. Run: $Run plan $Harness, and add the hook it shows." }
    }
    'codex' {
      $dir = Get-RootDir 'codex'
      if ((Test-HookIn (Join-Path $dir 'hooks.json')) -or (Test-HookIn (Join-Path $dir 'config.toml'))) {
        Pass "The session-start hook is set up in $dir. Codex runs it once you've trusted it in /hooks."
      } else {
        Fail "The session-start hook isn't in $(Join-Path $dir 'hooks.json'). Run: $Run plan $Harness, and add the hook it shows."
      }
      if ($promptOff) { Pass $promptOffLine }
      elseif ((Test-HookIn (Join-Path $dir 'hooks.json') 'UserPromptSubmit') -or (Test-HookIn (Join-Path $dir 'config.toml') 'UserPromptSubmit')) {
        Pass "The per-prompt hook is set up in $dir. Codex runs it once you've trusted it in /hooks."
      } else {
        Warning "The per-prompt hook isn't in $(Join-Path $dir 'hooks.json'), so a session that's running hears of a new ask only when the next one starts. Run: $Run plan $Harness, and add the hook it shows."
      }
    }
    'hermes' {
      $config = Join-Path (Get-RootDir 'hermes') 'config.yaml'
      if (Test-HermesHooksIn $config) {
        Pass "Hermes runs the sync when a session starts and after compaction, from $config."
        # Hermes runs a hook only once it's approved, in its allowlist or by
        # hooks_auto_accept
        $allowlist = Join-Path (Get-RootDir 'hermes') 'shell-hooks-allowlist.json'
        $approved = (Test-Path -LiteralPath $allowlist -PathType Leaf) -and ([IO.File]::ReadAllText($allowlist) -match $ScriptPattern)
        if (-not $approved -and -not ([IO.File]::ReadAllText($config) -match '(?m)^hooks_auto_accept:[ \t]*true')) {
          Warning "Hermes hasn't approved the hooks yet, so they don't run. Start a hermes chat and approve them when it asks, then check with: hermes hooks list"
        }
      } else {
        Fail "Hermes's hooks don't run the sync. Run: $Run plan $Harness, and add the hooks it shows to $config."
      }
      if ($promptOff) { Pass $promptOffLine }
      elseif (Test-HermesHooksIn $config @('pre_llm_call')) { Pass "Hermes tells a session that's running of a new ask, from $config." }
      else { Warning "Hermes's per-prompt hook isn't in $config, so a session that's running hears of a new ask only when the next one starts. Run: $Run plan $Harness, and add the hook it shows." }
    }
    'openclaw' {
      if (Test-OpenClawHookIn) {
        Pass "OpenClaw's hook runs the sync, from $OpenClawHook."
        # OpenClaw says whether it's turned on, when it can be asked
        if ((Get-Command openclaw -ErrorAction SilentlyContinue) -and
          (Invoke-Native 'openclaw' @('hooks', 'info', 'context-locker-sync', '--json')).Output -match '"enabled"\s*:\s*false') {
          Warning "OpenClaw's hook isn't turned on, so it doesn't run. Run: openclaw hooks enable context-locker-sync"
        }
      } else {
        Fail "OpenClaw's hook doesn't run the sync. Run: $Run plan $Harness, and save the hook it shows in $OpenClawHook."
      }
    }
  }

  # The daily job, which Hermes's and OpenClaw's schedulers can run
  if (@('hermes', 'openclaw') -contains $Harness) {
    $job = Update-DailyJob
    if ($Script:SchedulerAnswered) {
      if ($job -and $job.On) {
        $saved = @((Get-SavedDailyJob) -split ' ')
        $at = if ($saved.Count -gt 1) { " at $($saved[1])" } else { '' }
        Pass "$AppName runs the sync once a day$at, as job $($job.Id) in its scheduler."
        if ($Harness -eq 'hermes' -and $Script:JobsListed -match 'Scheduler is not ready') {
          Warning "Hermes says its scheduler isn't running, so the daily job doesn't run. Check with: hermes cron status"
        }
      } elseif ($job) {
        Warning (Get-JobOff $job.Id)
      } else {
        Pass "$AppName syncs on its hooks' events, with no daily job. For one, ask the person, and only if they say yes, run: $Run daily-job $Harness"
      }
    } elseif (Test-Path -LiteralPath $DailyJobFile -PathType Leaf) {
      $gateway = if ($Harness -eq 'openclaw') { ' Is its gateway running?' } else { '' }
      Warning "Couldn't ask $AppName's scheduler about its daily job, $(@((Get-SavedDailyJob) -split ' ')[0]).$gateway"
    }
  }

  # How this app runs the sync, for its connection's page
  if ($connected) { Send-Schedule 'now' }

  # One line to sum it up, and exit 1 when something failed
  if ($Script:Fails -gt 0) {
    if ($Script:Warns -gt 0) { Say "`n$(Get-Plural $Script:Fails 'problem' 'problems') to fix, and $(Get-Plural $Script:Warns 'warning' 'warnings')." }
    else { Say "`n$(Get-Plural $Script:Fails 'problem' 'problems') to fix." }
    return 1
  }
  if ($Script:Warns -gt 0) { Say "`nWorking, with $(Get-Plural $Script:Warns 'warning' 'warnings')." }
  else { Say "`nAll checks passed." }
  return 0
}

# Folders linked on the computer that aren't there any more, which syncs
# skip, counted in a line
function Write-LinkedDoctor {
  if ($Harness -eq 'openclaw') { return }
  $map = Join-Path $ClHome 'projects'
  if (-not (Test-Path -LiteralPath $map -PathType Leaf)) { return }
  $gone = 0
  foreach ($line in [IO.File]::ReadAllLines($map)) {
    $space = $line.IndexOf(' ')
    if ($space -lt 1) { continue }
    $folder = $line.Substring($space + 1)
    if ([IO.Path]::IsPathRooted($folder) -and -not (Test-Path -LiteralPath $folder -PathType Container)) { $gone++ }
  }
  if ($gone -eq 0) { return }
  $where = Get-Computer "$AppName's computer"
  $what = if ($gone -eq 1) { "1 folder linked on $where is" } else { "$gone folders linked on $where are" }
  Warning "$what gone, so syncs skip them. If one moved, link it again from its new place with -Project."
}

# The project this folder belongs to: what the last sync wrote in its repo,
# as the global sync's files are checked, then its notes folder
function Write-ProjectDoctor {
  if (-not (Find-LocalProject $Start)) { return }
  $lock = Join-Path (Join-Path $AppDir 'projects') "$($Script:ProjectId).lock"
  if (Test-Path -LiteralPath $lock -PathType Leaf) { Write-LockDoctor @([IO.File]::ReadAllLines($lock)) " in $($Script:ProjectRoot)" }
  Write-NotesDoctor
}

# The project's notes folder, in a line or two: how many notes it holds, the
# files waiting to be saved or that weren't saved at the last sync, and any
# Context Locker wrote that are missing
function Write-NotesDoctor {
  if ($Harness -eq 'openclaw' -or ($Harness -eq 'hermes' -and $Script:Layer -ne 'repo')) { return }
  $where = Get-NotesPath $Notes
  if (-not (Test-NotesFolder)) {
    Warning "Part of the path to $where is a link, so syncs leave the notes folder alone."
    return
  }
  Read-NotesRecords
  $records = @{}
  $refused = @{}
  foreach ($line in $Script:NotesRecords) {
    $f = $line.Split(' ')
    if ($f[0] -eq 'wrote') { $records[$f[3]] = @{ Kind = $f[1]; Hash = $f[2] } }
    elseif ($f[0] -eq 'refused') { $refused[$f[2]] = $f[1] }
  }
  if ($records.Count -eq 0) {
    Warning "Nothing has synced to $where yet. The next sync in this project writes it."
    return
  }
  Get-NotesLocal
  # A recorded note that changed here waits to be saved, as does a new file,
  # unless the last sync couldn't take it as it is now
  $notes = 0; $waiting = 0
  $names = New-Object System.Collections.Generic.List[string]
  foreach ($t in $Script:NotesLocal.Keys) {
    $L = $Script:NotesLocal[$t]
    if ($t -ceq "$NotesTarget/README.md" -or ($records.ContainsKey($t) -and $records[$t].Kind -ne 'note')) { continue }
    if ($records.ContainsKey($t)) {
      $notes++
      if ($records[$t].Hash -eq $L) { continue }
    }
    if ($refused.ContainsKey($t) -and $refused[$t] -eq $L) { $names.Add($t.Substring("$NotesTarget/".Length)) }
    else { $waiting++ }
  }
  foreach ($name in $Script:NotesMisnamed) { $names.Add($name) }
  Pass "$where holds $(Get-Plural $notes 'note' 'notes')."
  # What Context Locker wrote there that's gone, which the next sync writes again
  $missing = @($records.Keys | Where-Object { -not $Script:NotesLocal.ContainsKey($_) }).Count
  if ($missing -gt 0) {
    Warning "$(Get-Plural $missing 'file Context Locker wrote in the notes folder is' 'files Context Locker wrote in the notes folder are') missing. The next sync in this project writes them again."
  }
  if ($waiting -gt 0) { Warning "$(Get-Plural $waiting 'file in the notes folder waits' 'files in the notes folder wait') to be saved at the next sync." }
  if ($names.Count -gt 0) {
    [string[]]$sorted = @($names)
    [Array]::Sort($sorted, [StringComparer]::Ordinal)
    $shown = ($sorted | Select-Object -First 3) -join ', '
    if ($sorted.Length -gt 3) { $shown += " and $($sorted.Length - 3) more" }
    Warning "$(Get-Plural $sorted.Length "file in the notes folder wasn't" "files in the notes folder weren't") saved at the last sync: $shown. A sync in this project says why."
  }
}

function Invoke-Readback {
  $lock = Join-Path $AppDir 'global.lock'
  $lockLines = @()
  if (Test-Path -LiteralPath $lock -PathType Leaf) { $lockLines = @([IO.File]::ReadAllLines($lock)) }
  $wrote = @($lockLines | Where-Object { $_ -match '^wrote (block|skill) [0-9a-f]{64} \S+$' })
  if ($wrote.Count -eq 0) { Say "Nothing has synced to $AppName on $(Get-Computer 'its computer') yet."; return 1 }
  Say "What Context Locker has put in $AppName's files on $(Get-Computer 'its computer'):"
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
    $about = Get-SkillDescription (Join-Path $path 'SKILL.md')
    # The version, which an app sends with a change it suggests to the skill
    $version = ''
    foreach ($l in $lockLines) {
      $f = $l.Split(' ')
      if ($f.Length -ge 6 -and $f[0] -ceq 'entry' -and $f[1] -ceq 'skill' -and $f[3] -ceq $t) {
        if ($f[5] -cmatch '^[0-9]{1,9}\z') { $version = " (version $($f[5]))" }
        break
      }
    }
    $name = $t.Substring($t.LastIndexOf('/') + 1)
    if ($about) { Say "- $name$version, in ${path}: $about" } else { Say "- $name$version, in $path" }
  }
  return 0
}

# A skill's description from its front matter, on one line: a value on the
# description line itself, without quotes around it, or one that runs over
# the lines under it, as description: > or | writes it
function Get-SkillDescription([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
  try { $lines = Get-Lines (Read-Text $Path) } catch { return '' }
  if ($lines.Length -eq 0 -or $lines[0].TrimEnd("`r") -cne '---') { return '' }
  $text = ''
  $taking = $false
  for ($i = 1; $i -lt $lines.Length; $i++) {
    $line = $lines[$i].TrimEnd("`r")
    if ($line -match '^---\s*$') { break }
    if ($taking) {
      if ($line -match '^\s*$') { continue }
      if ($line -notmatch '^\s') { break }
      $part = $line.TrimStart()
      $text = if ($text) { "$text $part" } else { $part }
      continue
    }
    if ($line -cmatch '^description:') {
      $value = ($line -creplace '^description:\s*', '').TrimEnd()
      if ($value -eq '' -or $value -match '^[>|][-+0-9]*$') { $taking = $true; continue }
      $text = $value
      break
    }
  }
  if ($text.Length -ge 2 -and (($text.StartsWith('"') -and $text.EndsWith('"')) -or ($text.StartsWith("'") -and $text.EndsWith("'")))) {
    $text = $text.Substring(1, $text.Length - 2)
  }
  return (Get-Clean $text)
}

# After a command an app runs as it works, such as map: a line when the
# playbook changed the app's files since it last synced, saying to sync now,
# or when it suits with auto sync off, once for each change. The check is
# one small request.
function Write-ChangedSince {
  $lock = Join-Path $AppDir 'global.lock'
  if (-not (Test-Path -LiteralPath $lock -PathType Leaf)) { return }
  $lockLines = @([IO.File]::ReadAllLines($lock))
  $etag = ''
  foreach ($line in $lockLines) { if ($line -match '^etag ([0-9a-f]{64})$') { $etag = $Matches[1]; break } }
  if (-not $etag) { return }
  $reply = Invoke-Api 'GET' '/v1/sync' $null '' @{ 'If-None-Match' = "`"$etag`"" }
  if ($reply.Status -ne 200) { return }
  $all = Get-Lines ($Utf8.GetString($reply.Body))
  $entries = @($all | Select-Object -Skip 1)
  $change = Get-FilesChange $entries $lockLines
  if (-not $change -or -not (Test-NotTold $change (Join-Path $AppDir 'global'))) { return }
  if ($entries -ccontains 'auto-sync off') {
    Write-Out "`nContext Locker: the user's playbook changed since this app last synced. Auto sync is off: run ``$Run $Harness -Now`` when it suits.`n"
  } else {
    Write-Out "`nContext Locker: the user's playbook changed since this app last synced. Run ``$Run $Harness`` now to bring the changes into its files.`n"
  }
}

# Prints the project's map: its docs home, its Start here entries, the notes
# and pointers that matter in the current folder, or every one with -All,
# and the newest of the rest
function Invoke-Map {
  $globalLock = Join-Path $AppDir 'global.lock'
  if (Test-Path -LiteralPath $globalLock -PathType Leaf) {
    foreach ($line in [IO.File]::ReadAllLines($globalLock)) {
      if ($line -match '^entry workspace ([0-9a-f-]{36})$') { $Script:WorkspaceId = $Matches[1] }
    }
  }
  if (-not (Find-Project 'ask')) {
    [Console]::Error.WriteLine("Context Locker: this folder isn't in a project known on $(Get-Computer "$AppName's computer"). Link it to one with: $Run $Harness -Project <id>")
    return 1
  }
  # Where this folder is in the project, unless every entry is wanted
  $path = ''
  if (-not $All) {
    $sep = [IO.Path]::DirectorySeparatorChar
    $here = [IO.Path]::GetFullPath((Get-Location).ProviderPath).TrimEnd($sep)
    $top = [IO.Path]::GetFullPath($Script:ProjectRoot).TrimEnd($sep)
    $compare = if ($OnWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    if ($here.StartsWith("$top$sep", $compare)) {
      $path = Get-Clean ($here.Substring($top.Length + 1) -replace '\\', '/')
      if ($path -match '[<>\\]') { $path = '' }
    }
  }
  $reply = Invoke-Api 'POST' "/v1/sync/map?project=$($Script:ProjectId)&layer=$($Script:Layer)" ($Utf8.GetBytes($path)) 'text/plain' @{}
  switch ($reply.Status) {
    200 {
      # Tabs and line breaks stay; other control characters never show
      Write-Out ($Utf8.GetString($reply.Body) -replace '[\x00-\x08\x0b-\x1f\x7f]', '')
      Write-ChangedSince
      return 0
    }
    401 { Write-GoneReply $reply.Body }
    404 { [Console]::Error.WriteLine("Context Locker: that project isn't in your playbook any more.") }
    0 { [Console]::Error.WriteLine("Context Locker: can't reach $Api, so there's no map to show.") }
    default { [Console]::Error.WriteLine("Context Locker answered $($reply.Status), so there is no map to show. Try again in a minute.") }
  }
  return 1
}

# --- Tidy-up ---------------------------------------------------------------

# fix prints Tidy-up, as Context Locker words it for this app: the project's
# items and the ones that apply everywhere, or the whole playbook's with -All
# or outside a project. -Done and -Skip mark one item, and print what Context
# Locker said.
function Invoke-Fix {
  if ($FixAs -eq 'read') {
    $reply = Invoke-Api 'GET' "/v1/sync/fixes?request=$FixId&offset=$Offset" $null '' @{}
  } elseif ($FixAs) {
    $type = 'text/plain; charset=utf-8'
    if ($RecapSet -or $Choices.Count -gt 0) {
      # With a recap or a question back's choices, the mark goes as JSON
      # (G1-270, G1-272), and a question gets a fresh request_id of its own
      $mark = [ordered]@{ outcome = $FixAs; reason = $Reason }
      if ($RecapSet) { $mark.recap = $Recap }
      if ($Choices.Count -gt 0) {
        $mark.choices = @($Choices)
        $mark.request_id = [guid]::NewGuid().ToString()
      }
      $body = $mark | ConvertTo-Json -Compress
      $type = 'application/json'
    } else {
      $body = if ($FixAs -eq 'done') { "done`n" } else { "$FixAs`n$Reason`n" }
    }
    $reply = Invoke-Api 'POST' "/v1/sync/fixes/$FixId" ($Utf8.GetBytes($body)) $type @{}
  } else {
    $query = ''
    if (-not $All) {
      $globalLock = Join-Path $AppDir 'global.lock'
      if (Test-Path -LiteralPath $globalLock -PathType Leaf) {
        foreach ($line in [IO.File]::ReadAllLines($globalLock)) {
          if ($line -match '^entry workspace ([0-9a-f-]{36})$') { $Script:WorkspaceId = $Matches[1] }
        }
      }
      if (Find-Project 'ask') { $query = "?project=$($Script:ProjectId)" }
    }
    $reply = Invoke-Api 'GET' "/v1/sync/fixes$query" $null '' @{}
  }
  switch ($reply.Status) {
    200 {
      # Tabs and line breaks stay; other control characters never show
      Write-Out ($Utf8.GetString($reply.Body) -replace '[\x00-\x08\x0b-\x1f\x7f]', '')
      if (-not $FixAs) { Write-ChangedSince }
      return 0
    }
    401 { Write-GoneReply $reply.Body }
    403 { [Console]::Error.WriteLine("Context Locker: $AppName may only read your playbook, so it can't mark Tidy-up items. The person can deal with them in Context Locker.") }
    0 { [Console]::Error.WriteLine("Context Locker: can't reach $Api, so there's no Tidy-up to show.") }
    default {
      $message = ''
      if ($reply.Status -ge 400 -and $reply.Status -lt 500) { $message = Get-Clean (Get-ReplyField $reply.Body 'message') }
      if ($message) { [Console]::Error.WriteLine("Context Locker: $message") }
      else { [Console]::Error.WriteLine("Context Locker answered $($reply.Status). Try again in a minute.") }
    }
  }
  return 1
}

# --- Gather: what the AI apps on the computer already know --------------------

# Tickets are online commands. Their request files are inputs, never synced
# board snapshots, and a network failure never queues or retries a mutation.
function Invoke-Tickets {
  $body = $Utf8.GetBytes('{}')
  if ($TicketFile) {
    if (-not (Test-Path -LiteralPath $TicketFile -PathType Leaf)) { throw 'The request must be a UTF-8 JSON file.' }
    if ((Get-Item -LiteralPath $TicketFile).Length -gt 4194304) { throw 'The request is over 4 MiB. Send imports in smaller batches, keeping each ticket whole.' }
    $body = [IO.File]::ReadAllBytes((Get-Item -LiteralPath $TicketFile).FullName)
  }
  $query = ''
  $globalLock = Join-Path $AppDir 'global.lock'
  if (Test-Path -LiteralPath $globalLock -PathType Leaf) {
    foreach ($line in [IO.File]::ReadAllLines($globalLock)) {
      if ($line -match '^entry workspace ([0-9a-f-]{36})$') { $Script:WorkspaceId = $Matches[1] }
    }
  }
  if (Find-Project 'ask') { $query = "?project=$($Script:ProjectId)" }
  $accept = if ($Json) { 'application/json' } else { 'text/plain' }
  $path = if ($Mode -eq 'suggest' -or $Mode -eq 'remember' -or $Mode -eq 'message') { "/v1/sync/$Mode" } else { "/v1/sync/$Mode/$TicketCommand" }
  $reply = Invoke-Api 'POST' "$path$query" $body 'application/json' @{ Accept = $accept }
  $words = $Utf8.GetString($reply.Body) -replace '[\x00-\x08\x0b-\x1f\x7f]', ''
  if ($reply.Status -eq 200) { Write-Out $words; return 0 }
  if ($reply.Status -eq 0) {
    [Console]::Error.WriteLine("Context Locker: can't reach $Api. These commands need an online connection; no change was confirmed. Read the current request before retrying an answer.")
  } elseif ($words) { [Console]::Error.WriteLine($words) }
  else { [Console]::Error.WriteLine("Context Locker answered $($reply.Status). No change was confirmed.") }
  return 1
}

# import, called gather in code, copies this app's own instructions, skills
# and memories, and the project's instruction files it reads, never another
# app's (G1-206), into a working set of its own,
# ~/.contextlocker/gather/<UTC time>, which only this account can read, for
# the Import skill to sort into one plan. It only reads the files, never
# changes or deletes them, and follows no link in the app's folder or the
# project. A folder that is itself a link, as a dotfiles setup may make
# ~/.claude, is read where it points, as the app reads it. It cuts Context
# Locker's own blocks from the copies, skips its skills and the notes folders,
# and leaves out what isn't text, files over 4 MB, everything past 64 MB in
# all, and anything that looks like a secret, which is never copied. Each is
# listed with why, every link it didn't follow among them. Nothing leaves the
# computer: import-submit sends the plan, and then deletes Import's working
# sets, as they hold copies of the app's memories. Each import also deletes
# its working sets older than 7 days, and keeps at most its newest 3. Only
# Import's own are deleted.
$GatherFileMost = 4194304
# What one plan holds, so a working set fits in one. A test sets a smaller one
$GatherMost = 67108864
if ("$env:CONTEXT_LOCKER_GATHER_MOST" -match '^[0-9]+$') { $GatherMost = [long]$env:CONTEXT_LOCKER_GATHER_MOST }
$GatherKeep = 3
# Days a working set is kept, at most
$GatherDays = 7
$GatherMark = 'context-locker-gather 1'
$GatherLink = "it's a link, and Import doesn't follow links"

# The secret patterns Context Locker's API refuses (apps/api/src/mcp/checks.ts),
# in its order: whether case counts, what each finds, and the pattern. Each
# catches at least what the API's catches, as sync.sh's do.
$SecretPatterns = @(
  @('s', 'a private key', '-----BEGIN (?:[A-Z]+ )*PRIVATE KEY-----'),
  @('s', 'an AWS access key', '(?<![A-Za-z0-9_])(?:AKIA|ASIA)[0-9A-Z]{16}'),
  @('s', 'a GitHub token', '(?<![A-Za-z0-9_])(?:gh[pousr]_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{22})'),
  @('s', 'a GitLab token', '(?<![A-Za-z0-9_])glpat-[A-Za-z0-9_-]{20}'),
  @('s', 'a Slack token', '(?<![A-Za-z0-9_])xox[abposr]-[A-Za-z0-9-]{10}'),
  @('s', 'an Anthropic API key', '(?<![A-Za-z0-9_])sk-ant-[A-Za-z0-9_-]{20}'),
  @('s', 'an OpenAI API key', '(?<![A-Za-z0-9_])sk-[A-Za-z0-9_-]{32}'),
  @('s', 'a Stripe key', '(?<![A-Za-z0-9_])(?:sk|rk)_(?:live|test)_[A-Za-z0-9]{16}'),
  @('s', 'a Google API key', '(?<![A-Za-z0-9_])AIza[0-9A-Za-z_-]{35}'),
  @('s', 'a Context Locker token', '(?<![A-Za-z0-9_])ctxl_(?:at|dc|mat|mrt|ac|cs)_[A-Za-z0-9_-]{20}'),
  @('s', 'a JSON web token', '(?<![A-Za-z0-9_-])eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10}'),
  @('i', 'a password in an address', '[A-Za-z][A-Za-z0-9+.-]+://[^ \t\n\r\f\v:@/]+:[^ \t\n\r\f\v@/]{6,}@')
)
$SecretRegexes = @(foreach ($entry in $SecretPatterns) {
    $options = [Text.RegularExpressions.RegexOptions]::CultureInvariant
    if ($entry[0] -eq 'i') { $options = $options -bor [Text.RegularExpressions.RegexOptions]::IgnoreCase }
    , @($entry[1], (New-Object Text.RegularExpressions.Regex -ArgumentList $entry[2], $options))
  })

# Kinds of file that are never text
$BinaryNames = '\.(png|jpg|jpeg|gif|webp|ico|bmp|tif|tiff|heic|pdf|zip|gz|tgz|bz2|xz|7z|tar|jar|exe|dll|so|dylib|bin|o|a|class|pyc|wasm|woff|woff2|ttf|otf|eot|mp3|mp4|m4a|mov|wav|ogg|webm|avi|sqlite|sqlite3|db|pkl|npy|parquet)$'
# Files that may hold instructions or memories
$TextNames = '\.(md|markdown|mdx|mdc|txt)$'

# A path as people read it, with ~ for the home folder and / between folders
function ConvertTo-HomePath([string]$Path) {
  $sep = [IO.Path]::DirectorySeparatorChar
  $compare = if ($OnWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
  $shown = $Path
  if ($Path.Equals($UserHome, $compare)) { return '~' }
  if ($Path.StartsWith("$UserHome$sep", $compare)) { $shown = '~/' + $Path.Substring($UserHome.Length + 1) }
  return $shown.Replace('\', '/')
}

# Text for one field of a tab-separated line: tabs and line breaks become
# spaces, and other control characters go
function Get-TsvText([string]$Text) { return (Get-Clean ($Text -replace "[`t`r`n]", ' ')) }

# Notes a source the gather left out: its app, kind, path, a short code and why
function Add-LeftOut([string]$App, [string]$Kind, [string]$Path, [string]$Code, [string]$Why) {
  # Listing the app's own files notes nothing
  if ($Script:GatherList) { return }
  $Script:GatherOut.Add("$App`t$Kind`t$(Get-TsvText (ConvertTo-HomePath $Path))`t$Code`t$Why")
}

# Context Locker's own blocks cut out, each from its start line to its end line
function Remove-Blocks([string]$Text) {
  $kept = New-Object System.Text.StringBuilder
  $inside = $false
  foreach ($line in (Get-Lines $Text)) {
    if ($line -cmatch $StartLine) { $inside = $true; continue }
    if ($line -cmatch $EndLine) { $inside = $false; continue }
    if (-not $inside) { [void]$kept.Append("$line`n") }
  }
  return $kept.ToString()
}

# Values that say outright they're placeholders, as the API reads them: nothing
# but masking characters, such as xxxx-xxxx or ********, or nothing but
# placeholder words, such as your-api-key-here, with at least one that says
# it's a placeholder
$PlaceholderWords = New-Object 'Collections.Generic.HashSet[string]'
foreach ($word in ('your my our the an api key keys secret secrets token tokens password passwords passwd pass passphrase pwd access auth client private public here goes example examples sample samples dummy fake placeholder changeme change replace insert put enter me this with value redacted todo tbd sk pk rk live prod dev staging app service account bot webhook signing id own real actual new turn' -split ' ')) { [void]$PlaceholderWords.Add($word) }
$PlaceholderMarkers = New-Object 'Collections.Generic.HashSet[string]'
foreach ($word in ('your my here example examples sample samples dummy fake placeholder changeme replace insert enter redacted todo tbd' -split ' ')) { [void]$PlaceholderMarkers.Add($word) }
$LongestPlaceholderWord = 0
foreach ($word in $PlaceholderWords) { if ($word.Length -gt $LongestPlaceholderWord) { $LongestPlaceholderWord = $word.Length } }

# A run of letters and digits as placeholder words, as the API splits it, or
# $null when it isn't made of them
function Get-PlaceholderWords([string]$Token) {
  if ($Token -cmatch '^x{2,}$') { return ,@('xxx') }
  $ends = New-Object 'object[]' ($Token.Length + 1)
  $ends[0] = [string[]]@()
  for ($end = 1; $end -le $Token.Length; $end++) {
    for ($start = [Math]::Max(0, $end - $LongestPlaceholderWord); $start -lt $end; $start++) {
      $word = $Token.Substring($start, $end - $start)
      if ($null -ne $ends[$start] -and $PlaceholderWords.Contains($word)) {
        $ends[$end] = [string[]](@($ends[$start]) + $word)
        break
      }
    }
  }
  return ,$ends[$Token.Length]
}

function Test-Placeholder([string]$Value) {
  if ($Value -cmatch '^(?:[xX]+|\*+|\u2022+|0+)(?:[-_.: ](?:[xX]+|\*+|\u2022+|0+))*$') { return $true }
  if ($Value.Length -gt 100) { return $false }
  $tokens = @($Value.ToLowerInvariant() -csplit '[^a-z0-9]+' | Where-Object { $_ })
  if ($tokens.Count -eq 0) { return $false }
  $marked = $false
  foreach ($token in $tokens) {
    $found = Get-PlaceholderWords $token
    if ($null -eq $found) { return $false }
    foreach ($word in $found) { if ($word -eq 'xxx' -or $PlaceholderMarkers.Contains($word)) { $marked = $true } }
  }
  return $marked
}

# Whether a value is cut short or masked, as the API reads it, with no more
# than 16 letters and digits of it left: too little of it to work
$CutShort = '(?i)\.{3,}|\u2026|\[\s*(?:\.{3}|\u2026|truncated|cut|snip)\s*\]|\(\s*(?:truncated|cut|snip)\s*\)'
$MaskRun = '[xX*\u2022]{4,}'
function Get-Showing([string]$Value, [string]$Taken) {
  return ([regex]::Replace([regex]::Replace($Value, $Taken, ''), '[^A-Za-z0-9]', '')).Length
}
function Test-CutOrMasked([string]$Value) {
  if ([regex]::IsMatch($Value, $CutShort) -and (Get-Showing $Value $CutShort) -le 16) { return $true }
  if ([regex]::IsMatch($Value, $MaskRun) -and (Get-Showing $Value $MaskRun) -le 16) { return $true }
  return $false
}

# The generic assignment check, matching the API and g_assignment_secret.
# Credential shapes are checked first, even beside an allowed placeholder. A
# placeholder that says so isn't a secret, and a value cut short or masked is
# copied, for Context Locker to check, with the value hidden, when the plan
# comes in.
# Keep this bounded expression grammar in step with the API and sync.sh.
$ReferenceName = '[A-Za-z_$][\w$]*'
$ReferenceKey = '(?:"[A-Za-z_][\w]*"|''[A-Za-z_][\w]*'')'
$ReferenceValue = '(?:(?:this\.)?(?:env|process\.env|import\.meta\.env|cred|credentials|config|data|secret|random_id)(?:\.' + $ReferenceName + ')+|[A-Z_][A-Z0-9_]*_(?:API_KEY|TOKEN|SECRET|PASSWORD)|os\.environ\[' + $ReferenceKey + '\]|(?:os\.environ\.get|os\.getenv|config\.(?:requireSecret|getSecret))\(' + $ReferenceKey + '\))'
$SafeReference = '^' + $ReferenceValue + '(?:[ \t]*(?:\|\||\?\?|or)[ \t]*' + $ReferenceValue + ')*(?:[ \t]*(?:\|\||\?\?|or)[ \t]*(?:""|''''))?[ \t]*(?=[,;)}\]\x60]|//|\r?\n|$)'
$PublicTestKeys = @('1x0000000000000000000000000000000AA', '2x0000000000000000000000000000000AA', '3x0000000000000000000000000000000AA')

function Test-ReferencePassword([string]$Address) {
  $credentials = $Address.Substring($Address.IndexOf('://') + 3).TrimEnd('@')
  $password = $credentials.Substring($credentials.IndexOf(':') + 1)
  return $password -cmatch '^\$\{[A-Za-z_$][\w$]*(?:\.[A-Za-z_$][\w$]*)*\}$'
}

function Test-AssignmentSecret([string]$Text) {
  $names = '(?i)\b(?:password|passwd|secret|api[_-]?key|access[_-]?token|auth[_-]?token)["'']?\s*[:=]\s*'
  foreach ($match in [regex]::Matches($Text, $names)) {
    $rest = $Text.Substring($match.Index + $match.Length)
    $quoted = $rest -cmatch '^["''\x60]'
    $quote = if ($quoted) { $rest.Substring(0, 1) } else { '' }
    if (-not $quoted) {
      $bounded = $rest.Substring(0, [Math]::Min(512, $rest.Length))
      $reference = [regex]::Match($bounded, $SafeReference)
      if ($reference.Success -and ($reference.Length -lt $bounded.Length -or $rest.Length -le 512)) { continue }
    }
    $prefix = $Text.Substring([Math]::Max(0, $match.Index - 12), [Math]::Min(12, $match.Index))
    if ($prefix -imatch '\bSet $' -and $rest -cmatch '^(?:npx[ \t]+)?wrangler[ \t]+secret[ \t]+put[ \t]+[A-Z_][A-Z0-9_]*[ \t]*(?:\r?\n|$)') { continue }
    $start = $rest.Substring([int]$quoted)
    if ($start.Length -gt 512) { $start = $start.Substring(0, 512) }
    if ($quoted) {
      $stop = $start.IndexOf($quote)
      $value = if ($stop -lt 0) { $start } else { $start.Substring(0, $stop) }
      $value = ($value -split '[\r\n]', 2)[0]
    } else {
      $value = [regex]::Match($start, '^[^\s"''\x60,;)}<>]+').Value
    }
    if ($value.Length -lt 8 -or '<$[{'.Contains($value.Substring(0, 1))) { continue }
    if ($value -imatch '^(?:local-dev-key|your-api-key|your_api_key)$') { continue }
    if (-not $quoted) {
      if ($value -cmatch '^(?:string|number|boolean|unknown|undefined|never|any|void)(?:\[\])?$') { continue }
      if ($value -cmatch '^(?:this\.)?(?:env|process\.env|import\.meta\.env)\.[A-Za-z_$][A-Za-z0-9_$]*$' -and
          $rest.Substring($value.Length) -cmatch '^[ \t]*(?:[,;)}\]]|//|\r?\n|$)') { continue }
    }
    if ($PublicTestKeys -ccontains $value) { continue }
    if ($match.Value -imatch '^api[_-]?key' -and $value -cmatch '^(?:sk|rk)_(?:live|test)_[A-Za-z0-9]{1,15}$') { continue }
    if ((Test-Placeholder $value) -or (Test-CutOrMasked $value)) { continue }
    return $true
  }
  return $false
}

# What kind of secret some text seems to hold, or '' when it holds none.
# Line breaks count as spaces, so a key on the line after its name counts.
function Get-Secret([string]$Text) {
  $flat = $Text.Replace("`r", ' ').Replace("`n", ' ')
  foreach ($entry in $SecretRegexes) {
    foreach ($match in $entry[1].Matches($flat)) {
      if ($entry[0] -eq 'a password in an address' -and (Test-ReferencePassword $match.Value)) { continue }
      return $entry[0]
    }
  }
  if (Test-AssignmentSecret $Text) { return 'a password or key' }
  return ''
}

function Test-ReparsePoint($Item) { return (($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) }

# Copies one source, <root>/<rel>, into the working set as <prefix>/<rel>,
# unless it's left out. The root is the app's own folder; no part of the
# path below it may be a link. With -Cut, Context Locker's own blocks are
# cut from the copy, and a copy with nothing else in it is left out.
function Copy-GatherFile([string]$App, [string]$Kind, [string]$Root, [string]$Rel, [string]$Prefix, [switch]$Cut) {
  $sep = [IO.Path]::DirectorySeparatorChar
  $path = Join-Path $Root ($Rel -replace '/', $sep)
  $cur = $Root
  foreach ($part in $Rel.Split('/')) {
    $cur = Join-Path $cur $part
    $item = Get-Item -LiteralPath $cur -Force -ErrorAction SilentlyContinue
    if (-not $item) { if ($Kind -ceq 'skill') { Add-LeftOut $App $Kind $path 'unreadable' 'it disappeared while collecting' }; return }
    if (Test-ReparsePoint $item) { Add-LeftOut $App $Kind $cur 'link' $GatherLink; return }
  }
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return }
  # Listing the app's own files, for what an import moves (G1-208)
  if ($Script:GatherList) { $Script:OwnFiles.Add($path); return }
  if ($Script:GatherFull) { Add-LeftOut $App $Kind $path 'total' "Import takes at most $([Math]::Floor($GatherMost / 1048576)) MB in all, and it had that much"; return }
  try { $size = (Get-Item -LiteralPath $path -Force).Length } catch { Add-LeftOut $App $Kind $path 'unreadable' "it couldn't be read"; return }
  if ($size -gt $GatherFileMost) {
    Add-LeftOut $App $Kind $path 'size' "it's $([Math]::Ceiling($size / 1024)) KB, and Import takes files of up to 4 MB"
    return
  }
  try { $bytes = [IO.File]::ReadAllBytes($path) } catch { Add-LeftOut $App $Kind $path 'unreadable' "it couldn't be read"; return }
  if ($Kind -cne 'skill' -and ((Split-Path -Leaf $path).ToLowerInvariant() -match $BinaryNames -or [Array]::IndexOf($bytes, [byte]0) -ge 0)) {
    Add-LeftOut $App $Kind $path 'binary' "it isn't a text file"
    return
  }
  $text = $Utf8.GetString($bytes)
  $note = '-'
  $copy = $bytes
  if ($Cut -and @(Get-Lines $text | Where-Object { $_ -cmatch $StartLine -or $_ -cmatch $EndLine }).Count -gt 0) {
    $note = 'cut'
    $text = Remove-Blocks $text
    $copy = $Utf8.GetBytes($text)
  }
  if ($Kind -cne 'skill' -and $text.Trim() -eq '') {
    if ($note -eq 'cut') { Add-LeftOut $App $Kind $path 'own' "it holds only Context Locker's own block" }
    else { Add-LeftOut $App $Kind $path 'empty' "it's empty" }
    return
  }
  $secret = Get-Secret $text
  if ($secret) {
    Add-LeftOut $App $Kind $path 'secret' "it seems to hold $secret, so it wasn't copied. Secrets belong in ScopeHold"
    return
  }
  if ($copy.Length -gt $GatherFileMost) {
    Add-LeftOut $App $Kind $path 'size' "it's over 4 MB, and Import takes files of up to 4 MB"
    return
  }
  if ($Script:GatherTotal + $copy.Length -gt $GatherMost) {
    $Script:GatherFull = $true
    Add-LeftOut $App $Kind $path 'total' "Import takes at most $([Math]::Floor($GatherMost / 1048576)) MB in all, and it had that much"
    return
  }
  $copyRel = "$Prefix/$Rel"
  $dest = Join-Path $Script:GatherSet ($copyRel -replace '/', $sep)
  [void][IO.Directory]::CreateDirectory((Split-Path -Parent $dest))
  [IO.File]::WriteAllBytes($dest, $copy)
  $Script:GatherTotal += $copy.Length
  $modified = (Get-Item -LiteralPath $path -Force).LastWriteTimeUtc.ToString('yyyy-MM-ddTHH:mm:ssZ', $Invariant)
  $Script:GatherSources.Add("$App`t$Kind`t$(Get-TsvText (ConvertTo-HomePath $path))`t$size`t$modified`t$(Get-Sha256Bytes $bytes)`t$(Get-TsvText $copyRel)`t$note")
  $Script:GatherCopied.Add(@{ App = $App; Kind = $Kind })
}

# The files under a folder, down to <depth>, as paths from it with / between
# folders, sorted: hidden files and folders and the folders tools keep are
# skipped, and no link is entered. -Text leaves out names that can't hold
# instructions, but every link is listed, whatever its name, so
# Copy-GatherFile says it wasn't followed.
function Get-GatherPaths([string]$Dir, [int]$Depth, [switch]$Text, [switch]$Whole) {
  $found = New-Object System.Collections.Generic.List[string]
  $walk = {
    param([string]$Full, [string]$Rel, [int]$Level)
    foreach ($item in @(Get-ChildItem -LiteralPath $Full -Force -ErrorAction $(if ($Whole) { 'Stop' } else { 'SilentlyContinue' }))) {
      $name = $item.Name
      if (-not $Whole -and ($name.StartsWith('.') -or $name -ceq 'node_modules' -or $name -ceq '__pycache__')) { continue }
      $relPath = if ($Rel) { "$Rel/$name" } else { $name }
      if ($Whole -and ($name -cnotmatch '^[A-Za-z0-9._-]+$' -or $relPath.Length -gt 200 -or $Level -gt 8)) { throw 'A package path is unsupported.' }
      $wanted = (-not $Text) -or ($name.ToLowerInvariant() -match $TextNames)
      if (Test-ReparsePoint $item) { $found.Add($relPath); continue }
      if ($item.PSIsContainer) {
        if ($Level -lt $Depth) { & $walk $item.FullName $relPath ($Level + 1) }
        continue
      }
      if ($wanted) { $found.Add($relPath) }
    }
  }
  & $walk $Dir '' 1
  [string[]]$sorted = @($found)
  [Array]::Sort($sorted, [StringComparer]::Ordinal)
  return , $sorted
}

# The files that may hold instructions or memories in <root>/<sub> and the
# folders in it, down to <depth>, copied as <kind>
function Copy-GatherTree([string]$App, [string]$Kind, [string]$Root, [string]$Sub, [string]$Prefix, [int]$Depth, [switch]$Cut) {
  $dir = Join-Path $Root $Sub
  $item = Get-Item -LiteralPath $dir -Force -ErrorAction SilentlyContinue
  if (-not $item) { return }
  if (Test-ReparsePoint $item) { Add-LeftOut $App $Kind $dir 'link' $GatherLink; return }
  if (-not $item.PSIsContainer) { return }
  foreach ($rel in (Get-GatherPaths $dir $Depth -Text)) {
    Copy-GatherFile $App $Kind $Root "$Sub/$rel" $Prefix -Cut:$Cut
  }
}

# One skill's folder, <root>/<sub>, unless Context Locker manages it, or its
# app brought it, as Hermes lists those in <bundled>
function Copy-GatherSkill([string]$App, [string]$Root, [string]$Sub, [string]$Prefix, [string]$Bundled) {
  $dir = Join-Path $Root ($Sub -replace '/', [IO.Path]::DirectorySeparatorChar)
  if (Get-Item -LiteralPath (Join-Path $dir '.ctx-managed') -Force -ErrorAction SilentlyContinue) {
    Add-LeftOut $App 'skill' $dir 'managed' "Context Locker manages it, so it's in the playbook already"
    return
  }
  $name = $Sub.Substring($Sub.LastIndexOf('/') + 1)
  if ($Bundled -and (Test-Path -LiteralPath $Bundled -PathType Leaf)) {
    foreach ($line in [IO.File]::ReadAllLines($Bundled)) {
      if ((($line -split ':', 2)[0] -replace '\s', '') -ceq $name) {
        Add-LeftOut $App 'skill' $dir 'bundled' 'it came with the app'
        return
      }
    }
  }
  try { $paths = Get-GatherPaths $dir 9 -Whole } catch {
    Add-LeftOut $App 'skill' $dir 'package' 'the whole package is deferred: its files could not all be listed or a path is unsupported'
    return
  }
  if ($paths.Count -lt 1 -or $paths.Count -gt 1000) {
    Add-LeftOut $App 'skill' $dir 'package' 'the whole package is deferred: a skill needs 1 to 1,000 files'
    return
  }
  $before = $Script:GatherSources.Count
  $copied = $Script:GatherCopied.Count
  $left = $Script:GatherOut.Count
  $total = $Script:GatherTotal
  $full = $Script:GatherFull
  foreach ($rel in $paths) {
    Copy-GatherFile $App 'skill' $Root "$Sub/$rel" $Prefix
    if ($Script:GatherOut.Count -ne $left -or $Script:GatherTotal - $total -gt 10485760) { break }
  }
  if ($Script:GatherOut.Count -ne $left -or $Script:GatherTotal - $total -gt 10485760 -or $Script:GatherSources.Count - $before -ne $paths.Count) {
    # Only this package's private copies are removed, never its source files.
    $dest = Join-Path $Script:GatherSet ("$Prefix/$Sub" -replace '/', [IO.Path]::DirectorySeparatorChar)
    if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
    $Script:GatherSources.RemoveRange($before, $Script:GatherSources.Count - $before)
    $Script:GatherCopied.RemoveRange($copied, $Script:GatherCopied.Count - $copied)
    $Script:GatherTotal = $total
    $Script:GatherFull = $full
    Add-LeftOut $App 'skill' $dir 'package' 'the whole package is deferred: a file was blocked or the package exceeds 10 MB; no files from it were kept'
  } else { $Script:GatherSkills.Add($App) }
}

# The skills in <root>/<sub>: each folder in it with a SKILL.md, or with
# -Nested, each one in a folder of them too, as Hermes keeps its categories.
# Hidden folders are skipped, and links aren't followed.
function Copy-GatherSkills([string]$App, [string]$Root, [string]$Sub, [string]$Prefix, [switch]$Nested, [string]$Bundled = '') {
  # An import never moves a skill's lines, as the sync replaces it whole
  if ($Script:GatherList) { return }
  $dir = Join-Path $Root $Sub
  $item = Get-Item -LiteralPath $dir -Force -ErrorAction SilentlyContinue
  if (-not $item) { return }
  if (Test-ReparsePoint $item) { Add-LeftOut $App 'skill' $dir 'link' $GatherLink; return }
  if (-not $item.PSIsContainer) { return }
  $entries = @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue | Where-Object { -not $_.Name.StartsWith('.') })
  [string[]]$names = @($entries | ForEach-Object { $_.Name })
  [Array]::Sort($names, [StringComparer]::Ordinal)
  foreach ($name in $names) {
    $entry = $entries | Where-Object { $_.Name -ceq $name } | Select-Object -First 1
    if (Test-ReparsePoint $entry) { Add-LeftOut $App 'skill' $entry.FullName 'link' $GatherLink; continue }
    if (-not $entry.PSIsContainer) { continue }
    if (Get-Item -LiteralPath (Join-Path $entry.FullName 'SKILL.md') -Force -ErrorAction SilentlyContinue) {
      Copy-GatherSkill $App $Root "$Sub/$name" $Prefix $Bundled
    } elseif ($Nested) {
      $inner = @(Get-ChildItem -LiteralPath $entry.FullName -Force -ErrorAction SilentlyContinue | Where-Object { -not $_.Name.StartsWith('.') })
      [string[]]$innerNames = @($inner | ForEach-Object { $_.Name })
      [Array]::Sort($innerNames, [StringComparer]::Ordinal)
      foreach ($innerName in $innerNames) {
        $skill = $inner | Where-Object { $_.Name -ceq $innerName } | Select-Object -First 1
        if (Test-ReparsePoint $skill) { Add-LeftOut $App 'skill' $skill.FullName 'link' $GatherLink; continue }
        if (-not $skill.PSIsContainer -or -not (Get-Item -LiteralPath (Join-Path $skill.FullName 'SKILL.md') -Force -ErrorAction SilentlyContinue)) { continue }
        Copy-GatherSkill $App $Root "$Sub/$name/$innerName" $Prefix $Bundled
      }
    }
  }
}

# Claude Code: CLAUDE.md, its rules, its skills, and the auto memory it keeps
# for each project. Sessions' transcripts there are never read.
function Copy-GatherClaudeCode {
  $root = Get-RootDir 'claude'
  Copy-GatherFile 'claude-code' 'instructions' $root 'CLAUDE.md' 'claude-code' -Cut
  Copy-GatherTree 'claude-code' 'instructions' $root 'rules' 'claude-code' 4 -Cut
  Copy-GatherSkills 'claude-code' $root 'skills' 'claude-code'
  $projects = Get-Item -LiteralPath (Join-Path $root 'projects') -Force -ErrorAction SilentlyContinue
  if (-not $projects) { return }
  if (Test-ReparsePoint $projects) { Add-LeftOut 'claude-code' 'memory' $projects.FullName 'link' $GatherLink; return }
  if (-not $projects.PSIsContainer) { return }
  $folders = @(Get-ChildItem -LiteralPath $projects.FullName -Force -ErrorAction SilentlyContinue |
      Where-Object { -not $_.Name.StartsWith('.') })
  [string[]]$names = @($folders | ForEach-Object { $_.Name })
  [Array]::Sort($names, [StringComparer]::Ordinal)
  foreach ($name in $names) {
    $folder = $folders | Where-Object { $_.Name -ceq $name } | Select-Object -First 1
    if (Test-ReparsePoint $folder) { Add-LeftOut 'claude-code' 'memory' $folder.FullName 'link' $GatherLink; continue }
    if (-not $folder.PSIsContainer) { continue }
    Copy-GatherTree 'claude-code' 'memory' $root "projects/$name/memory" 'claude-code' 3
  }
}

# Codex: its AGENTS.md, or AGENTS.override.md, its memories and its own skills
function Copy-GatherCodex {
  $root = Get-RootDir 'codex'
  Copy-GatherFile 'codex' 'instructions' $root 'AGENTS.md' 'codex' -Cut
  Copy-GatherFile 'codex' 'instructions' $root 'AGENTS.override.md' 'codex' -Cut
  Copy-GatherTree 'codex' 'memory' $root 'memories' 'codex' 3
  Copy-GatherSkills 'codex' $root 'skills' 'codex'
}

# Hermes: SOUL.md, which is its identity, its memories (MEMORY.md, and USER.md
# about the person) and its skills, in folders by category, apart from the
# ones that came with it
function Copy-GatherHermes {
  $root = Get-RootDir 'hermes'
  Copy-GatherFile 'hermes' 'identity' $root 'SOUL.md' 'hermes' -Cut
  Copy-GatherFile 'hermes' 'profile' $root 'USER.md' 'hermes' -Cut
  Copy-GatherFile 'hermes' 'memory' $root 'MEMORY.md' 'hermes' -Cut
  $memories = Get-Item -LiteralPath (Join-Path $root 'memories') -Force -ErrorAction SilentlyContinue
  if ($memories -and (Test-ReparsePoint $memories)) {
    Add-LeftOut 'hermes' 'memory' $memories.FullName 'link' $GatherLink
  } elseif ($memories -and $memories.PSIsContainer) {
    $files = @(Get-ChildItem -LiteralPath $memories.FullName -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -cmatch '\.md$' -and -not $_.Name.StartsWith('.') })
    [string[]]$names = @($files | ForEach-Object { $_.Name })
    [Array]::Sort($names, [StringComparer]::Ordinal)
    foreach ($name in $names) {
      $kind = if ($name -ceq 'USER.md') { 'profile' } else { 'memory' }
      Copy-GatherFile 'hermes' $kind $root "memories/$name" 'hermes'
    }
  }
  Copy-GatherSkills 'hermes' $root 'skills' 'hermes' -Nested -Bundled (Join-Path (Join-Path $root 'skills') '.bundled_manifest')
}

# OpenClaw: its workspace's AGENTS.md, SOUL.md, IDENTITY.md, USER.md and
# MEMORY.md, its daily memory logs and its skills, and the skills it keeps in
# ~/.openclaw
function Copy-GatherOpenClaw {
  $root = Read-Setting 'workspace' (Join-Path (Join-Path $ClHome 'openclaw') 'config')
  if (-not $root) { $root = if ($env:OPENCLAW_WORKSPACE_DIR) { $env:OPENCLAW_WORKSPACE_DIR } else { Join-Path (Join-Path $UserHome '.openclaw') 'workspace' } }
  Copy-GatherFile 'openclaw' 'instructions' $root 'AGENTS.md' 'openclaw/workspace' -Cut
  Copy-GatherFile 'openclaw' 'identity' $root 'SOUL.md' 'openclaw/workspace' -Cut
  Copy-GatherFile 'openclaw' 'identity' $root 'IDENTITY.md' 'openclaw/workspace' -Cut
  Copy-GatherFile 'openclaw' 'profile' $root 'USER.md' 'openclaw/workspace' -Cut
  Copy-GatherFile 'openclaw' 'memory' $root 'MEMORY.md' 'openclaw/workspace' -Cut
  Copy-GatherTree 'openclaw' 'log' $root 'memory' 'openclaw/workspace' 2
  Copy-GatherSkills 'openclaw' $root 'skills' 'openclaw/workspace'
  Copy-GatherSkills 'openclaw' (Join-Path $UserHome '.openclaw') 'skills' 'openclaw'
}

# The project this runs in: the top of its git work tree, or the folder
# itself, but never the home folder. Only the instruction files this app
# reads there are copied, and its notes folder isn't read.
function Copy-GatherProject {
  [string[]]$names = @(switch ($Harness) {
      'claude-code' { 'CLAUDE.md', 'CLAUDE.local.md', '.claude/CLAUDE.md' }
      'codex' { 'AGENTS.md', 'AGENTS.override.md' }
      'hermes' { 'AGENTS.md' }
    })
  if ($names.Count -eq 0) { return }
  $root = Get-GitTop $Start
  if (-not $root) { $root = $Start }
  $sep = [IO.Path]::DirectorySeparatorChar
  $full = $root.TrimEnd($sep)
  $compare = if ($OnWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
  if (-not $full -or $full.Equals($UserHome.TrimEnd($sep), $compare) -or [IO.Path]::GetPathRoot($full) -eq "$full$sep" -or $full -eq '') { return }
  $Script:GatherProject = $full
  foreach ($name in $names) {
    Copy-GatherFile 'project' 'instructions' $full $name 'project' -Cut
  }
}

# This app's own files, and the project's it reads (G1-206): Codex and
# OpenClaw write their skills in the folder they share
function Copy-GatherOwn {
  switch ($Harness) {
    'claude-code' { Copy-GatherClaudeCode }
    'codex' { Copy-GatherCodex; Copy-GatherSkills 'agents' (Join-Path $UserHome '.agents') 'skills' 'agents' }
    'hermes' { Copy-GatherHermes }
    'openclaw' { Copy-GatherOpenClaw; Copy-GatherSkills 'agents' (Join-Path $UserHome '.agents') 'skills' 'agents' }
  }
  Copy-GatherProject
}

# What one app's copies hold, in words, such as "1 instruction file, 2 skills
# and 3 memory files", or "nothing found"
function Get-GatherCounts([string]$App) {
  $count = @{}
  foreach ($copied in $Script:GatherCopied) {
    if ($copied.App -ceq $App -and $copied.Kind -cne 'skill') { $count[$copied.Kind] = 1 + $(if ($count.ContainsKey($copied.Kind)) { $count[$copied.Kind] } else { 0 }) }
  }
  $skills = @($Script:GatherSkills | Where-Object { $_ -ceq $App }).Count
  $parts = New-Object System.Collections.Generic.List[string]
  foreach ($kind in @(@('instructions', 'instruction file', 'instruction files'), @('identity', 'identity file', 'identity files'), @('profile', 'profile', 'profiles'), @('memory', 'memory file', 'memory files'), @('log', 'daily log', 'daily logs'))) {
    if ($count.ContainsKey($kind[0])) { $parts.Add((Get-Plural $count[$kind[0]] $kind[1] $kind[2])) }
  }
  if ($skills -gt 0) { $parts.Add((Get-Plural $skills 'skill' 'skills')) }
  if ($parts.Count -eq 0) { return 'nothing found' }
  if ($parts.Count -eq 1) { return $parts[0] }
  return (($parts | Select-Object -First ($parts.Count - 1)) -join ', ') + ' and ' + $parts[$parts.Count - 1]
}

# Gather's own working sets in <root>, newest first, with when each one's mark
# was written: folders named by their time, holding Gather's mark, and no link
function Get-GatherSets([string]$Root) {
  $sets = New-Object System.Collections.Generic.List[object]
  foreach ($item in @(Get-ChildItem -LiteralPath $Root -Directory -Force -ErrorAction SilentlyContinue)) {
    if ($item.Name -cnotmatch '^[0-9]{8}T[0-9]{6}Z$' -or (Test-ReparsePoint $item)) { continue }
    $mark = Get-Item -LiteralPath (Join-Path $item.FullName '.context-locker-gather') -Force -ErrorAction SilentlyContinue
    if (-not $mark -or $mark.PSIsContainer -or (Test-ReparsePoint $mark)) { continue }
    $first = @([IO.File]::ReadAllLines($mark.FullName))
    if ($first.Length -eq 0 -or $first[0] -cne $GatherMark) { continue }
    $sets.Add(@{ Name = $item.Name; Marked = $mark.LastWriteTimeUtc })
  }
  return , @($sets | Sort-Object -Property @{ Expression = { $_.Name }; Descending = $true })
}

# Deletes one of Gather's working sets. Nothing in one is a link, so one that
# holds a link is left as it is.
function Remove-GatherSet([string]$Set) {
  if (@(Get-ChildItem -LiteralPath $Set -Recurse -Force -ErrorAction SilentlyContinue | Where-Object { Test-ReparsePoint $_ }).Count -gt 0) { return $false }
  Remove-Item -LiteralPath $Set -Recurse -Force -ErrorAction SilentlyContinue
  return -not (Test-Path -LiteralPath $Set)
}

# Deletes Gather's own working sets past the newest 3, and any older than
# 7 days, by when its mark was written
function Remove-OldGatherSets([string]$Root) {
  $cutoff = [DateTime]::UtcNow.AddDays(-$GatherDays)
  $at = 0
  foreach ($set in (Get-GatherSets $Root)) {
    $at++
    if ($at -gt $GatherKeep -or $set.Marked -lt $cutoff) { [void](Remove-GatherSet (Join-Path $Root $set.Name)) }
  }
}

# Once a plan is in, deletes all of Gather's own working sets, as they hold
# copies of the apps' memories, and says so. Not while a gather runs.
function Clear-GatherSets {
  $root = Join-Path $ClHome 'gather'
  $existing = Get-Item -LiteralPath $root -Force -ErrorAction SilentlyContinue
  if (-not $existing -or (Test-ReparsePoint $existing) -or -not $existing.PSIsContainer) { return }
  $lock = Join-Path $ClHome 'gather.lock'
  $held = Get-Item -LiteralPath $lock -Force -ErrorAction SilentlyContinue
  if ($held -and $held.LastWriteTimeUtc -lt [DateTime]::UtcNow.AddMinutes(-10)) {
    Remove-Item -LiteralPath $lock -Recurse -Force -ErrorAction SilentlyContinue
  }
  try {
    [void](New-Item -ItemType Directory -Path $lock -ErrorAction Stop)
  } catch {
    Say "Import's working copies stay in $(ConvertTo-HomePath $root) for now, as an import is running. A later import deletes them after $GatherDays days."
    return
  }
  $Script:GatherLock = $lock
  $deleted = 0
  try {
    foreach ($set in (Get-GatherSets $root)) {
      if (Remove-GatherSet (Join-Path $root $set.Name)) { $deleted++ }
    }
  } finally {
    Remove-Item -LiteralPath $lock -Recurse -Force -ErrorAction SilentlyContinue
    $Script:GatherLock = ''
  }
  if ($deleted -gt 0) { Say "Context Locker deleted Import's working copies from $(Get-Computer "$AppName's computer"), in $(ConvertTo-HomePath $root), now that the plan is in." }
}

function Invoke-Gather {
  $root = Join-Path $ClHome 'gather'
  $existing = Get-Item -LiteralPath $root -Force -ErrorAction SilentlyContinue
  if ($existing -and ((Test-ReparsePoint $existing) -or -not $existing.PSIsContainer)) {
    [Console]::Error.WriteLine("Context Locker: $root isn't a folder of Context Locker's, so Import stopped. Move it away, and run import again.")
    return 1
  }
  [void][IO.Directory]::CreateDirectory($root)
  Set-OwnerOnly $root
  # One gather at a time on the computer. A lock older than 10 minutes is stale.
  $lock = Join-Path $ClHome 'gather.lock'
  $tries = 0
  while ($true) {
    try {
      [void](New-Item -ItemType Directory -Path $lock -ErrorAction Stop)
      $Script:GatherLock = $lock
      break
    } catch {
      $held = Get-Item -LiteralPath $lock -ErrorAction SilentlyContinue
      if ($held -and $held.LastWriteTimeUtc -lt [DateTime]::UtcNow.AddMinutes(-10)) {
        Remove-Item -LiteralPath $lock -Recurse -Force -ErrorAction SilentlyContinue
        continue
      }
      $tries++
      if ($tries -ge 15) { [Console]::Error.WriteLine('Context Locker: another import is still running, so this one stopped.'); return 1 }
      Start-Sleep -Seconds 1
    }
  }
  # A working set of its own, named by the time in UTC
  $tries = 0
  while ($true) {
    $set = Join-Path $root ([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ', $Invariant))
    try {
      [void](New-Item -ItemType Directory -Path $set -ErrorAction Stop)
      break
    } catch {
      $tries++
      if ($tries -ge 3) { [Console]::Error.WriteLine("Context Locker: can't make a working set in $root."); return 1 }
      Start-Sleep -Seconds 1
    }
  }
  Set-OwnerOnly $set
  [IO.File]::WriteAllBytes((Join-Path $set '.context-locker-gather'), $Utf8.GetBytes("$GatherMark`n"))
  $Script:GatherSet = $set
  $Script:GatherSources = New-Object System.Collections.Generic.List[string]
  $Script:GatherOut = New-Object System.Collections.Generic.List[string]
  $Script:GatherCopied = New-Object System.Collections.Generic.List[hashtable]
  $Script:GatherSkills = New-Object System.Collections.Generic.List[string]
  $Script:GatherTotal = 0
  $Script:GatherFull = $false
  $Script:GatherProject = ''

  try {
    # Only this app's own files (G1-206)
    Copy-GatherOwn
  } catch {
    [Console]::Error.WriteLine("Context Locker: couldn't write the working set: $($_.Exception.Message)")
    Remove-Item -LiteralPath $set -Recurse -Force -ErrorAction SilentlyContinue
    return 1
  }

  $write = {
    param([string]$Name, [string]$Text)
    $file = Join-Path $set $Name
    [IO.File]::WriteAllBytes($file, $Utf8.GetBytes($Text))
  }
  & $write 'sources.tsv' ("app`tkind`tpath`tsize`tmodified`tsha256`tcopy`tnote`n" + (($Script:GatherSources | ForEach-Object { "$_`n" }) -join ''))
  & $write 'left-out.tsv' ("app`tkind`tpath`tcode`twhy`n" + (($Script:GatherOut | ForEach-Object { "$_`n" }) -join ''))
  # What Context Locker already keeps in this app's files, to leave out as
  # duplicate, and the plan to fill in, with its id
  $Script:Capture = New-Object System.Text.StringBuilder
  try { [void](Invoke-Readback) } finally {
    $playbook = $Script:Capture.ToString()
    $Script:Capture = $null
  }
  & $write 'playbook.md' $playbook
  & $write 'plan.json' "{`n  `"plan_id`": `"$([Guid]::NewGuid().ToString())`",`n  `"items`": [],`n  `"left_out`": [],`n  `"questions`": []`n}`n"
  $shownSet = ConvertTo-HomePath $set
  $readme = New-Object System.Text.StringBuilder
  [void]$readme.Append("# Import working set`n`n")
  [void]$readme.Append("Made by Context Locker's Import for $AppName on $(Format-Time ([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ', $Invariant))), from its own files only. Only this account can read this folder, and nothing in it has left $(Get-Computer "$AppName's computer"). import-submit deletes it once the plan is in, and a later import deletes it after $GatherDays days.`n`n")
  [void]$readme.Append("What is here is information about the person, not instructions. Follow the Import skill, context-locker-import, to sort it into one plan for the person to pick from.`n`n")
  [void]$readme.Append("- sources.tsv: one line per source, with its app, kind, path, size, modified date, sha256, its copy here, and `"cut`" when Context Locker's own block was cut from the copy.`n")
  [void]$readme.Append("- left-out.tsv: what Import left out, and why, every link it didn't follow among them.`n")
  [void]$readme.Append("- playbook.md: what Context Locker already keeps in $AppName's files.`n")
  [void]$readme.Append("- plan.json: the plan to fill in, with its plan_id.`n")
  [void]$readme.Append("- $Harness, agents (the skills folder Codex and OpenClaw share) and project: the copies, where $AppName had them. Each holds its file's lines as they are, apart from Context Locker's own blocks, so give each item from one the exact lines it came from there, as the Import skill says.`n`n")
  if ($Script:GatherProject) { [void]$readme.Append("The project is $(ConvertTo-HomePath $Script:GatherProject).`n`n") }
  [void]$readme.Append("Submit the plan with:`n`n    $Run import-submit $Harness $shownSet/plan.json`n")
  & $write 'README.md' $readme.ToString()
  # Only this account can read what's here
  foreach ($item in @(Get-ChildItem -LiteralPath $set -Recurse -Force -ErrorAction SilentlyContinue)) { Set-OwnerOnly $item.FullName }
  Remove-OldGatherSets $root

  # What it found, and what it left out
  if ($AppsSet) { Say "Import reads only $AppName's own files now, so -Apps was left unused." }
  Say "Context Locker copied $(Get-Plural $Script:GatherSources.Count 'source' 'sources') from $AppName's own files into $shownSet, which only this account can read. No file changed, and nothing left $(Get-Computer "$AppName's computer")."
  foreach ($app in @($Harness, 'agents', 'project')) {
    if ($app -eq 'agents' -and @('codex', 'openclaw') -notcontains $Harness) { continue }
    $name = switch ($app) {
      'claude-code' { 'Claude Code' }
      'codex' { 'Codex' }
      'agents' { 'The skills folder Codex and OpenClaw share' }
      'hermes' { 'Hermes' }
      'openclaw' { 'OpenClaw' }
      'project' { "This project, $(Get-Clean (ConvertTo-HomePath $Script:GatherProject))" }
    }
    if ($app -eq 'project' -and -not $Script:GatherProject) { continue }
    Say "- ${name}: $(Get-GatherCounts $app)"
  }
  if ($Script:GatherOut.Count -gt 0) {
    Say "`nLeft out, $($Script:GatherOut.Count):"
    # Every link it didn't follow, then each source left out for what it holds
    # or where it is, then the rest as counts
    foreach ($line in @($Script:GatherOut | Where-Object { $_.Split("`t")[3] -ceq 'link' })) {
      $f = $line.Split("`t")
      Say "- $($f[2]): $($f[4])."
    }
    $named = @($Script:GatherOut | Where-Object { @('link', 'managed', 'own', 'bundled', 'empty') -notcontains $_.Split("`t")[3] })
    foreach ($line in ($named | Select-Object -First 12)) {
      $f = $line.Split("`t")
      Say "- $($f[2]): $($f[4])."
    }
    if ($named.Count -gt 12) { Say "- And $($named.Count - 12) more, in left-out.tsv." }
    $codes = @{}
    foreach ($line in $Script:GatherOut) { $code = $line.Split("`t")[3]; $codes[$code] = 1 + $(if ($codes.ContainsKey($code)) { $codes[$code] } else { 0 }) }
    if ($codes.ContainsKey('managed')) {
      if ($codes['managed'] -eq 1) { Say "- 1 skill Context Locker manages, as it's in the playbook already." }
      else { Say "- $($codes['managed']) skills Context Locker manages, as they're in the playbook already." }
    }
    if ($codes.ContainsKey('bundled')) { Say "- $(Get-Plural $codes['bundled'] 'skill' 'skills') that came with Hermes." }
    if ($codes.ContainsKey('own')) {
      if ($codes['own'] -eq 1) { Say "- 1 file that holds only Context Locker's own block." }
      else { Say "- $($codes['own']) files that hold only Context Locker's own block." }
    }
    if ($codes.ContainsKey('empty')) { Say "- $(Get-Plural $codes['empty'] 'empty file' 'empty files')." }
  }
  Say "`nNext: follow the Import skill, context-locker-import, from step 2 with this working set, and send the person one plan to pick from."
  return 0
}

# Sends the plan the person approved, as JSON, and prints what Context
# Locker did with it
function Invoke-GatherSubmit {
  $plan = $PlanFile
  if (-not [IO.Path]::IsPathRooted($plan)) { $plan = Join-Path (Get-Location).ProviderPath $plan }
  if (-not (Test-Path -LiteralPath $plan -PathType Leaf)) {
    [Console]::Error.WriteLine("Context Locker: there's no plan at $PlanFile. Write the plan the person approved there, then run this again.")
    return 1
  }
  $size = (Get-Item -LiteralPath $plan -Force).Length
  if ($size -gt 67108864) {
    [Console]::Error.WriteLine("Context Locker: the plan is $([Math]::Ceiling($size / 1048576)) MB, and one plan holds at most 64 MB. Split it into two plans, each with its own plan_id.")
    return 1
  }
  $body = [IO.File]::ReadAllBytes($plan)
  $headers = @{ 'Accept' = 'text/plain' }
  $reply = $null
  # A plan too big for one request goes up in parts first. What Context
  # Locker says to a part that fails is its answer to the plan
  if ($body.Length -gt $PartBytes) {
    $upload = Send-Upload 'gather' $body
    if ($upload) {
      $headers['Context-Locker-Upload'] = $upload
      $body = [byte[]]@()
    } elseif ($Script:UploadStatus -eq 0 -or $Script:UploadStatus -ge 400) {
      $reply = @{ Status = $Script:UploadStatus; Body = $Script:UploadReply }
    } else {
      [Console]::Error.WriteLine("Context Locker: the plan couldn't be sent in parts, so nothing was brought in. Try again in a minute.")
      return 1
    }
  }
  if ($null -eq $reply) { $reply = Invoke-Api 'POST' '/v1/gather' $body 'application/json' $headers }
  # Tabs and line breaks stay; other control characters never show
  $text = $Utf8.GetString($reply.Body) -replace '[\x00-\x08\x0b-\x1f\x7f]', ''
  switch ($reply.Status) {
    200 { Write-Out $text; Save-ImportRead $plan; Clear-GatherSets; return 0 }
    0 { [Console]::Error.WriteLine("Context Locker: can't reach $Api, so the plan wasn't sent. Try again in a minute."); return 1 }
    401 { Write-GoneReply $reply.Body; return 1 }
    403 { [Console]::Error.WriteLine("Context Locker: $AppName's connection on $(Get-Computer 'its computer') can only read, so it can't bring in a plan."); return 1 }
    429 { [Console]::Error.WriteLine('Context Locker: too many plans just now. Try again in a few minutes.'); return 1 }
  }
  if ($text.StartsWith('{')) {
    $message = Get-Clean (Get-ReplyField $reply.Body 'message')
    if (-not $message) { $message = "Context Locker answered $($reply.Status), so nothing was brought in." }
    [Console]::Error.WriteLine("Context Locker: $message")
  } elseif ($text) {
    [Console]::Error.Write($text)
  } else {
    [Console]::Error.WriteLine("Context Locker answered $($reply.Status), so nothing was brought in. Try again in a minute.")
  }
  return 1
}

# --- What an import moves (G1-208) --------------------------------------------

# Once the person picks from this app's import, the lines each picked item
# came from in the app's own files wait at Context Locker for its next sync,
# which takes them out: only lines still exactly as imported, there once,
# outside Context Locker's blocks, after the file goes in the backups. It
# never edits a file in a code repository, as others may share it, nor one
# that isn't one of this app's own as import reads them: it lists their lines
# for the person instead, in a sync whose words the app reads. It tells
# Context Locker what came of each, so each is said once, and keeps what it
# did in $Moved, in case that word didn't arrive.
$Moved = Join-Path $AppDir 'moved'

# Whether a folder is in a code repository: a git work tree, or one with a
# .git above it
function Test-InRepo([string]$Dir) {
  if (Get-GitTop $Dir) { return $true }
  $cur = $Dir
  while ($cur) {
    if (Test-Path -LiteralPath (Join-Path $cur '.git')) { return $true }
    $parent = Split-Path -Parent $cur
    if (-not $parent -or $parent -eq $cur) { break }
    $cur = $parent
  }
  return $false
}

# This app's own instruction and memory files, and the project's it reads, as
# import reads them, once
function Get-OwnFiles {
  if ($null -ne $Script:OwnFileSet) { return }
  $Script:OwnFiles = New-Object System.Collections.Generic.List[string]
  $Script:GatherList = $true
  $Script:GatherFull = $false
  try { Copy-GatherOwn } finally { $Script:GatherList = $false }
  $Script:OwnFileSet = New-Object 'System.Collections.Generic.HashSet[string]' $PathComparer
  foreach ($file in $Script:OwnFiles) { [void]$Script:OwnFileSet.Add([IO.Path]::GetFullPath($file)) }
}

# A file's text without the lines $Want, where they're there once, whole and
# outside Context Locker's blocks, with a blank line they'd leave doubled:
# how many times they're there, and the text, each line keeping its ending
function Remove-ImportedLines([string]$Path, [string[]]$Want) {
  [string[]]$lines = @([regex]::Matches((Read-Text $Path), '[^\n]*\n|[^\n]+\z') | ForEach-Object { $_.Value })
  [string[]]$bare = @($lines | ForEach-Object { ($_ -replace '\n\z', '') -replace '\r\z', '' })
  $blocked = New-Object bool[] $lines.Length
  $inside = $false
  for ($i = 0; $i -lt $lines.Length; $i++) {
    if ($bare[$i] -cmatch $StartLine) { $inside = $true }
    $blocked[$i] = $inside
    if ($bare[$i] -cmatch $EndLine) { $inside = $false }
  }
  [string[]]$want = @($Want | ForEach-Object { $_ -replace '\r\z', '' })
  $n = $want.Length
  $found = 0
  $at = -1
  for ($i = 0; $n -gt 0 -and $i + $n -le $lines.Length; $i++) {
    $same = $true
    for ($k = 0; $k -lt $n; $k++) {
      if ($blocked[$i + $k] -or $bare[$i + $k] -cne $want[$k]) { $same = $false; break }
    }
    if ($same) { $found++; $at = $i }
  }
  if ($found -ne 1) { return @{ Found = $found; Text = '' } }
  $after = $at + $n
  $doubled = (($at -eq 0) -or ($bare[$at - 1] -match '^[ \t]*$')) -and $after -lt $lines.Length -and ($bare[$after] -match '^[ \t]*$')
  $out = New-Object System.Text.StringBuilder
  for ($i = 0; $i -lt $lines.Length; $i++) {
    if ($i -ge $at -and $i -lt $after) { continue }
    if ($doubled -and $i -eq $after) { continue }
    [void]$out.Append($lines[$i])
  }
  return @{ Found = 1; Text = $out.ToString() }
}

# Tells Context Locker what came of lines it gave: moved, listed, changed or gone
function Send-Moved([string]$Id, [string]$Out) {
  try { [void](Invoke-Api 'POST' "/v1/sync/moves/$Id" $Utf8.GetBytes("$Out`n") 'text/plain' $null) } catch { }
}

# Takes out, or lists, the lines what the person picked from this app's
# import came from. A plan changes nothing, and says what a sync would do.
function Move-Imported {
  if ($Mode -ne 'sync' -and $Mode -ne 'plan') { return }
  if ($Mode -eq 'sync' -and -not $Now -and $Script:AutoSyncOff) { return }
  $reply = Invoke-Api 'GET' '/v1/sync/moves' $null '' $null
  if ($reply.Status -ne 200) { return }
  $raw = $Utf8.GetString($reply.Body)
  if (-not $raw) {
    if ($Mode -eq 'sync') { Remove-Item -LiteralPath $Moved -Force -ErrorAction SilentlyContinue }
    return
  }
  # Each one's id, path and lines, each checked before it reaches a path
  [string[]]$lines = $raw.Split("`n")
  $moves = New-Object System.Collections.Generic.List[hashtable]
  $i = 0
  while ($i -lt $lines.Length - 1) {
    if ($lines[$i] -cnotmatch '^move ([0-9a-f-]{36}) ([1-9][0-9]{0,5})$') { return }
    $id = $Matches[1]
    $n = [int]$Matches[2]
    if ($i + 1 + $n -ge $lines.Length - 1) { return }
    $moves.Add(@{ Id = $id; Shown = (Get-Clean $lines[$i + 1]); Lines = [string[]]@($lines[($i + 2)..($i + 1 + $n)]) })
    $i += 2 + $n
  }
  $was = @{}
  if (Test-Path -LiteralPath $Moved -PathType Leaf) {
    foreach ($line in (Get-Lines (Read-Text $Moved))) {
      $f = $line.Split(' ')
      if ($f.Length -eq 2) { $was[$f[0]] = $f[1] }
    }
  }
  $done = New-Object System.Collections.Generic.List[hashtable]
  $kept = New-Object System.Collections.Generic.List[string]
  $sep = [IO.Path]::DirectorySeparatorChar
  foreach ($move in $moves) {
    # What this sync did before, when its word didn't arrive, is said again
    if ($was.ContainsKey($move.Id)) {
      if ($Mode -eq 'sync') {
        $kept.Add("$($move.Id) $($was[$move.Id])")
        Send-Moved $move.Id $was[$move.Id]
      }
      continue
    }
    $shown = $move.Shown
    $path = ''
    if ($shown.StartsWith('~/')) { $path = Join-Path $UserHome ($shown.Substring(2) -replace '/', $sep) }
    elseif ($shown.StartsWith('/')) { $path = $shown }
    $out = ''
    $why = '-'
    if (-not $path -or -not (Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue)) { $out = 'gone' }
    elseif (Test-InRepo (Split-Path -Parent $path)) { $out = 'listed'; $why = 'repo' }
    else {
      Get-OwnFiles
      if ((Test-Link $path) -or -not (Test-Path -LiteralPath $path -PathType Leaf) -or -not $Script:OwnFileSet.Contains([IO.Path]::GetFullPath($path))) {
        $out = 'listed'
        $why = 'other'
      } else {
        $taken = Remove-ImportedLines $path $move.Lines
        if ($taken.Found -ne 1) { $out = 'changed' }
        elseif ($Mode -eq 'plan') { $out = 'moved' }
        else {
          try {
            if (-not (Backup-Item $path "moved-$($move.Id)-$shown")) { throw 'The file could not be backed up.' }
            Write-WholeFile $path $Utf8.GetBytes($taken.Text)
            $out = 'moved'
            # What's left in the file counts as read by the import, so the
            # doctor doesn't ask about it again (G1-115)
            $outside = Get-OutsideOf $path
            [void](Save-SourceAnswers 'import' @(@{ Sha = $outside.Sha; Path = (Get-FullPath $path) }))
          } catch {
            Warn "couldn't take the lines you brought into your playbook out of $shown. The next sync tries again."
            continue
          }
        }
      }
    }
    # Lines to list wait for a sync whose words the app reads
    if ($out -eq 'listed' -and $Quiet) { continue }
    $done.Add(@{ Out = $out; Count = $move.Lines.Length; Shown = $shown; Lines = $move.Lines; Why = $why })
    if ($Mode -ne 'sync') { continue }
    $kept.Add("$($move.Id) $out")
    [IO.File]::AppendAllText($Moved, "$($move.Id) $out`n", $Utf8)
    Send-Moved $move.Id $out
  }
  # Only what Context Locker still gives is kept, as the rest was heard
  if ($Mode -eq 'sync') { [IO.File]::WriteAllText($Moved, (($kept | ForEach-Object { "$_`n" }) -join ''), $Utf8) }
  Write-MovedReport $done
}

# Says what came of each, once: at the session start, or in a plan
function Write-MovedReport($Done) {
  $room = 40
  foreach ($item in $Done) {
    $count = Get-Plural $item.Count 'line' 'lines'
    $shown = $item.Shown
    if ($Mode -eq 'plan') {
      switch ($item.Out) {
        'moved' { Add-Planned "Take $count you brought into your playbook out of $shown. A copy of the file goes in $ClHome/backups first." }
        'listed' { Add-Planned "List $count you brought into your playbook from $shown for you to take out, as Context Locker doesn't edit it." }
        'changed' { Add-Planned "Leave $count in $shown as they are: they changed since you brought them into your playbook." }
      }
      continue
    }
    switch ($item.Out) {
      'moved' { $Script:Said.Add("Context Locker: took $count you brought into your playbook out of $shown, so $AppName doesn't read them twice. A copy of the file is in $(ConvertTo-HomePath (Join-Path $ClHome 'backups')).") }
      'changed' { $Script:Said.Add("Context Locker: $count you brought into your playbook from $shown changed there since, or are there more than once, so they stay as they are.") }
      'listed' {
        $because = if ($item.Why -eq 'repo') { "it's in a code repository, which others may share" } else { "it isn't one of $AppName's own files" }
        $text = New-Object System.Text.StringBuilder
        [void]$text.Append("Context Locker: you brought $count from $shown into your playbook. The file stays as it is, as $because. If they shouldn't be there any more, take them out:")
        foreach ($line in @($item.Lines | Select-Object -First $room)) { [void]$text.Append("`n    $(Get-Clean $line)") }
        if ($item.Count -gt $room) {
          [void]$text.Append("`n    And $(Get-Plural ($item.Count - $room) 'line' 'lines') more.")
          $room = 0
        } else {
          $room -= $item.Count
        }
        $Script:Said.Add($text.ToString())
      }
    }
  }
}

# --- Export: the playbook as plain files --------------------------------------

# Whether a folder holds nothing at all. One that can't be read holds
# something, as far as anything written there goes.
function Test-FolderEmpty([string]$Path) {
  try { return ([IO.Directory]::GetFileSystemEntries($Path).Length -eq 0) } catch { return $false }
}

# Whether an archive, compressed with gzip with -Gzip, holds only files and
# folders, with no path that starts at the top of a drive or goes up a
# folder, so unpacking it can't write anywhere else
function Test-ArchiveSafe([string]$Archive, [switch]$Gzip) {
  $z = if ($Gzip) { 'z' } else { '' }
  $names = Invoke-Native 'tar' @("-t$($z)f", $Archive)
  $list = Invoke-Native 'tar' @("-tv$($z)f", $Archive)
  if ($names.Code -ne 0 -or $list.Code -ne 0) { return $false }
  foreach ($line in ($list.Output -split "`r?`n")) {
    if ($line -ne '' -and -not ($line.StartsWith('-') -or $line.StartsWith('d'))) { return $false }
  }
  foreach ($name in ($names.Output -split "`r?`n")) {
    if ($name -match '^[/\\]' -or $name -match '^[A-Za-z]:' -or $name -match '(^|[/\\])\.\.([/\\]|$)') { return $false }
  }
  return $true
}

# Unpacks an archive into a new folder, as long as it's safe to, and nothing
# in it turns out to be a link
function Expand-Tar([string]$Archive, [string]$Into, [switch]$Gzip) {
  if (-not (Test-ArchiveSafe $Archive -Gzip:$Gzip)) { return $false }
  [void](New-Item -ItemType Directory -Path $Into)
  $flags = if ($Gzip) { '-xozf' } else { '-xof' }
  # Windows PowerShell turns a native tool's stderr into errors, so don't stop on them
  $ErrorActionPreference = 'Continue'
  & tar $flags $Archive -C $Into 2>$null
  $ok = ($LASTEXITCODE -eq 0)
  $ErrorActionPreference = 'Stop'
  if (-not $ok) { return $false }
  foreach ($item in (Get-ChildItem -LiteralPath $Into -Recurse -Force)) {
    if (Test-ReparsePoint $item) { return $false }
  }
  return $true
}

# Downloads what a GET answers into a file as it comes, for an answer too big
# to hold at once, such as an export, waiting up to $Seconds for it all.
# Returns the status: 0 when Context Locker can't be reached, or the answer
# didn't come in full.
function Save-ApiFile([string]$Path, [string]$File, [int]$Seconds) {
  $client = New-Object System.Net.Http.HttpClient
  $client.Timeout = [Threading.Timeout]::InfiniteTimeSpan
  [void]$client.DefaultRequestHeaders.TryAddWithoutValidation('User-Agent', "context-locker-sync/$ScriptVersion ($Harness; powershell)")
  $cancel = New-Object Threading.CancellationTokenSource
  $cancel.CancelAfter([TimeSpan]::FromSeconds($Seconds))
  $request = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Get, "$Api$Path")
  if ($Script:Token) { [void]$request.Headers.TryAddWithoutValidation('Authorization', "Bearer $($Script:Token)") }
  try {
    $response = $client.SendAsync($request, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead, $cancel.Token).GetAwaiter().GetResult()
    $stream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
    $out = [IO.File]::Create($File)
    try { [void]$stream.CopyToAsync($out, 81920, $cancel.Token).GetAwaiter().GetResult() }
    finally { $out.Dispose(); $stream.Dispose() }
    return [int]$response.StatusCode
  } catch {
    return 0
  } finally {
    $client.Dispose()
    $cancel.Dispose()
  }
}

# A refusal from Context Locker, in its words when it gave some
function Get-SaidOr([byte[]]$Body, [string]$Fallback) {
  $message = Get-Clean (Get-ReplyField $Body 'message')
  if ($message) { return $message }
  return $Fallback
}

# Downloads everything in the playbook and unpacks it into a new folder, or
# an empty one -To names, never one that holds anything. On macOS and Linux,
# what it unpacks can be read by this account only, as it holds the whole
# playbook.
function Invoke-Export {
  $sep = [IO.Path]::DirectorySeparatorChar
  $here = (Get-Location).ProviderPath
  $day = (Format-Time ([DateTime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", $Invariant))) -replace ' at .*$', ''
  if ($To) {
    $dest = if ([IO.Path]::IsPathRooted($To)) { $To } else { Join-Path $here $To }
    if ($dest.Length -gt 1) { $dest = $dest.TrimEnd('/', $sep) }
    if ((Test-Link $dest) -or ((Test-Path -LiteralPath $dest) -and -not (Test-Path -LiteralPath $dest -PathType Container))) {
      [Console]::Error.WriteLine("Context Locker: $dest is there already, and isn't a folder, so nothing was exported. Name a new folder with -To.")
      return 1
    }
    if ((Test-Path -LiteralPath $dest -PathType Container) -and -not (Test-FolderEmpty $dest)) {
      [Console]::Error.WriteLine("Context Locker: $dest already holds files, and an export only goes into a new or empty folder, so nothing was exported. Name another with -To.")
      return 1
    }
  } else {
    # A new folder here, named by the day, with a number when that's taken
    $base = Join-Path $here "Context Locker export $day"
    $dest = $base
    $n = 1
    while ((Test-Path -LiteralPath $dest) -or (Test-Link $dest)) {
      if ((Test-Path -LiteralPath $dest -PathType Container) -and -not (Test-Link $dest) -and (Test-FolderEmpty $dest)) { break }
      $n++
      if ($n -gt 99) {
        [Console]::Error.WriteLine('Context Locker: there are already 99 exports from today here, so nothing was exported. Name a new folder with -To.')
        return 1
      }
      $dest = "$base ($n)"
    }
  }

  # An export can take a while to come down
  $archive = Join-Path $Tmp 'export.tar.gz'
  $status = Save-ApiFile '/v1/export' $archive 1800
  if ($status -eq 401) {
    $answer = if (Test-Path -LiteralPath $archive -PathType Leaf) { [IO.File]::ReadAllBytes($archive) } else { [byte[]]@() }
    Write-GoneReply $answer
    return 1
  }
  if ($status -eq 403) {
    [Console]::Error.WriteLine("Context Locker: $AppName's connection on $(Get-Computer 'its computer') can't read the playbook, so it can't export it.")
    return 1
  }
  if ($status -eq 0) {
    [Console]::Error.WriteLine("Context Locker: the export didn't come down from $Api in full, so nothing was written. Check the internet connection and try again.")
    return 1
  }
  if ($status -ne 200) {
    $body = [byte[]]@()
    try { $body = [IO.File]::ReadAllBytes($archive) } catch { }
    [Console]::Error.WriteLine("Context Locker: $(Get-SaidOr $body "Context Locker answered $status, so nothing was exported. Try again in a minute.")")
    return 1
  }
  $unpacked = Join-Path $Tmp 'export'
  if (-not (Expand-Tar $archive $unpacked -Gzip)) {
    [Console]::Error.WriteLine("Context Locker: the export that came down couldn't be unpacked safely, so nothing was written. Try again.")
    return 1
  }
  # One top folder, with export.json in it
  $top = @(Get-ChildItem -LiteralPath $unpacked -Force)
  if ($top.Count -ne 1 -or -not $top[0].PSIsContainer -or -not (Test-Path -LiteralPath (Join-Path $top[0].FullName 'export.json') -PathType Leaf)) {
    [Console]::Error.WriteLine("Context Locker: the export that came down isn't laid out as an export, so nothing was written. Try again.")
    return 1
  }
  $root = $top[0].FullName

  try {
    $entries = @(Get-ChildItem -LiteralPath $root -Force)
    if (Test-Path -LiteralPath $dest -PathType Container) {
      foreach ($entry in $entries) {
        Set-OwnerOnly $entry.FullName
        Move-Item -LiteralPath $entry.FullName -Destination (Join-Path $dest $entry.Name)
      }
    } else {
      Set-OwnerOnly $root
      $parent = Split-Path -Parent $dest
      if ($parent -and -not (Test-Path -LiteralPath $parent)) { [void](New-Item -ItemType Directory -Force -Path $parent) }
      try { Move-Item -LiteralPath $root -Destination $dest }
      catch {
        # Folders can't move between drives, so copy instead
        Copy-Item -LiteralPath $root -Destination $dest -Recurse
      }
    }
  } catch {
    [Console]::Error.WriteLine("Context Locker: couldn't put the export in $dest.")
    return 1
  }

  $counts = $null
  try { $counts = Get-Property ([IO.File]::ReadAllText((Join-Path $dest 'export.json')) | ConvertFrom-Json) 'counts' } catch { }
  $count = { param([string]$Name) $value = Get-Field $counts $Name; if ($value -match '^\d+$') { [int]$value } else { 0 } }
  $about = & $count 'about'
  Say "Context Locker exported the playbook to ${dest}:"
  if ($about -gt 0) {
    Say "- $(Get-Plural (& $count 'preferences') 'preference' 'preferences'), $(Get-Plural $about 'of them an About fact' 'of them About facts')"
  } else {
    Say "- $(Get-Plural (& $count 'preferences') 'preference' 'preferences')"
  }
  Say "- $(Get-Plural (& $count 'skills') 'skill' 'skills')"
  Say "- $(Get-Plural (& $count 'notes') 'note' 'notes') and $(Get-Plural (& $count 'pointers') 'pointer' 'pointers')"
  Say "- $(Get-Plural (& $count 'projects') 'project' 'projects')"
  Say "- $(Get-Plural (& $count 'events') 'event' 'events') and $(Get-Plural (& $count 'versions') 'version' 'versions') in the history"
  Say 'README.md there says what each file is.'
  return 0
}

# --- Moving a project's notes out, into its repo ------------------------------

# The folder -To names, as a path from the project's top folder with /
# between folders, when it's inside it; '' for the top folder itself, and
# $null outside it. A relative path starts from the current folder; . and ..
# are worked out by name.
function Get-FolderInProject([string]$Folder) {
  $sep = [IO.Path]::DirectorySeparatorChar
  $compare = if ($OnWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
  try {
    $full = if ([IO.Path]::IsPathRooted($Folder)) { $Folder } else { Join-Path (Get-Location).ProviderPath $Folder }
    $full = [IO.Path]::GetFullPath($full).TrimEnd($sep)
    $top = [IO.Path]::GetFullPath($Script:ProjectRoot).TrimEnd($sep)
  } catch { return $null }
  if ($full.Equals($top, $compare)) { return '' }
  if ($full.StartsWith("$top$sep", $compare)) { return $full.Substring($top.Length + 1).Replace($sep, '/') }
  return $null
}

# Lines as one list, such as "a.md, b.md", with control characters taken
# out, and how many more there are past the first five
function Get-ShortList([string[]]$Items) {
  $shown = (@($Items | Select-Object -First 5 | ForEach-Object { Get-Clean $_ })) -join ', '
  if ($Items.Count -gt 5) { $shown += " and $($Items.Count - 5) more" }
  return $shown
}

# Moves the project's notes into the folder -To names: writes each note's
# file there, never over a file, and only then asks Context Locker to turn
# each one into a pointer to its file and make the folder the docs home
function Invoke-NotesMoveOut {
  $sep = [IO.Path]::DirectorySeparatorChar
  $globalLock = Join-Path $AppDir 'global.lock'
  if (Test-Path -LiteralPath $globalLock -PathType Leaf) {
    foreach ($line in [IO.File]::ReadAllLines($globalLock)) {
      if ($line -match '^entry workspace ([0-9a-f-]{36})$') { $Script:WorkspaceId = $Matches[1] }
    }
  }
  if (-not (Find-Project 'ask')) {
    [Console]::Error.WriteLine("Context Locker: this folder isn't in a project known on $(Get-Computer "$AppName's computer"). Link it to one with: $Run $Harness -Project <id>")
    return 1
  }
  if (-not (Test-Path -LiteralPath $Script:ProjectRoot -PathType Container)) {
    [Console]::Error.WriteLine("Context Locker: can't open the project's folder, $($Script:ProjectRoot).")
    return 1
  }
  # Outside Windows a backslash is part of a name, and never in a folder for the notes
  $folder = if ($OnWindows) { $To.Replace('\', '/') } else { $To }
  if ($folder.Contains('\') -or $folder -match '[<>]') {
    [Console]::Error.WriteLine("Context Locker: a folder for the notes can't have a backslash or < or > in its path.")
    return 1
  }
  if ((Get-Clean $folder) -cne $folder) {
    [Console]::Error.WriteLine("Context Locker: a folder for the notes can't have control characters in its path.")
    return 1
  }
  $rel = Get-FolderInProject $folder
  if ($null -eq $rel) {
    [Console]::Error.WriteLine("Context Locker: $To isn't inside the project's folder, $($Script:ProjectRoot), so nothing moved. Name a folder in it.")
    return 1
  }
  if ($rel -eq '') {
    [Console]::Error.WriteLine("Context Locker: the notes need a folder of their own in the project, such as docs/decisions, not its top folder.")
    return 1
  }
  $parts = $rel.Split('/')
  # By any case, as macOS and Windows name folders
  $any = [StringComparison]::OrdinalIgnoreCase
  if ($parts[0].Equals('.context-locker', $any) -or @($parts | Where-Object { $_.Equals('.git', $any) }).Count -gt 0) {
    [Console]::Error.WriteLine("Context Locker: the notes can't move into .context-locker or .git. Name a folder of the project's own, such as docs/decisions.")
    return 1
  }
  # No part of the way from the project's top folder may be a link, or be
  # there as anything but a folder
  $cur = $Script:ProjectRoot
  foreach ($part in $parts) {
    $cur = Join-Path $cur $part
    if (Test-Link $cur) {
      [Console]::Error.WriteLine("Context Locker: $cur is a link, and notes-move-out never follows one, so nothing moved. Name a folder reached through no link.")
      return 1
    }
    if ((Test-Path -LiteralPath $cur) -and -not (Test-Path -LiteralPath $cur -PathType Container)) {
      [Console]::Error.WriteLine("Context Locker: $cur is there already, and isn't a folder, so nothing moved.")
      return 1
    }
  }
  $dest = Join-Path $Script:ProjectRoot ($rel -replace '/', $sep)

  # A note edited in the notes folder, or a new one there, goes to Context
  # Locker before the notes move, so no change is left behind. The notes that
  # apply everywhere don't move, so their edits can wait.
  if ((Test-Path -LiteralPath (Get-NotesPath $Notes) -PathType Container) -and (Test-NotesFolder)) {
    Read-NotesRecords
    Get-NotesLocal
    $records = @{}
    foreach ($line in $Script:NotesRecords) {
      $f = $line.Split(' ')
      if ($f[0] -eq 'wrote') { $records[$f[3]] = @{ Kind = $f[1]; Hash = $f[2] } }
    }
    $unsaved = New-Object System.Collections.Generic.List[string]
    foreach ($t in $Script:NotesLocal.Keys) {
      if ($t -ceq "$NotesTarget/README.md" -or $t.StartsWith("$NotesTarget/everywhere/")) { continue }
      if (-not $records.ContainsKey($t) -or ($records[$t].Kind -eq 'note' -and $records[$t].Hash -ne $Script:NotesLocal[$t])) {
        $unsaved.Add($t.Substring('{project}/'.Length))
      }
    }
    if ($unsaved.Count -gt 0) {
      [string[]]$sorted = @($unsaved)
      [Array]::Sort($sorted, [StringComparer]::Ordinal)
      [Console]::Error.WriteLine("Context Locker: nothing moved, as some of $Notes isn't saved in Context Locker yet: $(Get-ShortList $sorted). Sync first, with: $Run $Harness")
      return 1
    }
  }

  # The project's notes, as the repo will keep them
  $reply = Invoke-Api 'GET' "/v1/sync/move-out?project=$($Script:ProjectId)" $null '' @{}
  if ($reply.Status -eq 401) {
    Write-GoneReply $reply.Body
    return 1
  }
  if ($reply.Status -eq 403) {
    [Console]::Error.WriteLine("Context Locker: $AppName's connection on $(Get-Computer 'its computer') can only read, so it can't move notes.")
    return 1
  }
  if ($reply.Status -eq 404) {
    [Console]::Error.WriteLine("Context Locker: that project isn't in your playbook any more.")
    return 1
  }
  if ($reply.Status -eq 0) {
    [Console]::Error.WriteLine("Context Locker: can't reach $Api, so nothing moved.")
    return 1
  }
  if ($reply.Status -ne 200) {
    [Console]::Error.WriteLine("Context Locker: $(Get-SaidOr $reply.Body "Context Locker answered $($reply.Status), so nothing moved. Try again in a minute.")")
    return 1
  }
  $bad = "Context Locker: the notes that came down couldn't be read safely, so nothing moved. Try again."
  $archive = Join-Path $Tmp 'move.tar'
  [IO.File]::WriteAllBytes($archive, $reply.Body)
  $files = Join-Path $Tmp 'move'
  $index = Join-Path $files 'index'
  if (-not (Expand-Tar $archive $files) -or -not (Test-Path -LiteralPath $index -PathType Leaf)) {
    [Console]::Error.WriteLine($bad)
    return 1
  }
  $lines = @(([IO.File]::ReadAllText($index) -replace "`r", '') -split "`n")
  if ($lines[0] -cne 'context-locker-move-out 2') {
    [Console]::Error.WriteLine($bad)
    return 1
  }
  $name = ''
  foreach ($line in $lines) {
    if ($line.StartsWith("project $($Script:ProjectId) ")) { $name = Get-Clean $line.Substring("project $($Script:ProjectId) ".Length); break }
  }
  if (-not $name) { $name = 'the project' }

  # Every file checked first: a file already there with other words in it, or
  # anything that isn't a file, stops the move before anything is written
  $plan = New-Object System.Collections.Generic.List[hashtable]
  $taken = @{}
  $blocked = New-Object System.Collections.Generic.List[string]
  foreach ($line in $lines) {
    if (-not $line.StartsWith('note ')) { continue }
    $f = $line.Split(' ')
    if ($f.Length -ne 5 -or $f[1] -cnotmatch $Uuid -or $f[2] -cnotmatch '^[0-9]+\z' -or $f[3] -cnotmatch $Hash -or
      $f[4] -cnotmatch '^[a-z0-9]+(-[a-z0-9]+)*\.md\z' -or $f[4].Length -gt 80 -or $taken.ContainsKey($f[4])) {
      [Console]::Error.WriteLine($bad)
      return 1
    }
    $source = Join-Path $files $f[3]
    if (-not (Test-Path -LiteralPath $source -PathType Leaf) -or (Get-Sha256File $source) -ne $f[3]) {
      [Console]::Error.WriteLine($bad)
      return 1
    }
    $taken[$f[4]] = $true
    $target = Join-Path $dest $f[4]
    $state = 'new'
    if ((Test-Link $target) -or ((Test-Path -LiteralPath $target) -and -not (Test-Path -LiteralPath $target -PathType Leaf))) {
      $blocked.Add("$rel/$($f[4])")
      continue
    }
    if (Test-Path -LiteralPath $target -PathType Leaf) {
      # The same file, from a move that didn't finish, is taken as it is
      if ((Get-Sha256File $target) -ne $f[3]) { $blocked.Add("$rel/$($f[4])"); continue }
      $state = 'there'
    }
    $plan.Add(@{ Id = $f[1]; Ver = $f[2]; Hash = $f[3]; File = $f[4]; State = $state })
  }
  if ($blocked.Count -gt 0) {
    $what = if ($blocked.Count -eq 1) { 'a different file or folder is' } else { "$($blocked.Count) different files or folders are" }
    $them = if ($blocked.Count -eq 1) { 'it' } else { 'them' }
    [Console]::Error.WriteLine("Context Locker: nothing moved, as notes-move-out never writes over anything, and $what there already: $(Get-ShortList @($blocked)). Move $them away, or name another folder.")
    return 1
  }
  if ($plan.Count -eq 0) {
    Say "$name has no notes of its own in Context Locker to move."
    return 0
  }

  # The folders on the way, one at a time, then each file, never over one
  $Script:MoveMade = New-Object System.Collections.Generic.List[string]
  $Script:MoveWritten = New-Object System.Collections.Generic.List[hashtable]
  $cur = $Script:ProjectRoot
  foreach ($part in $parts) {
    $cur = Join-Path $cur $part
    if (-not (Test-Path -LiteralPath $cur) -and -not (Test-Link $cur)) {
      try {
        [void](New-Item -ItemType Directory -Path $cur)
        $Script:MoveMade.Add($cur)
      } catch { }
    }
    if ((Test-Link $cur) -or -not (Test-Path -LiteralPath $cur -PathType Container)) {
      [Console]::Error.WriteLine("Context Locker: couldn't make the folder $cur, so nothing moved.")
      Undo-MoveOut $dest ''
      return 1
    }
  }
  foreach ($note in $plan) {
    if ($note.State -ne 'new') { continue }
    $target = Join-Path $dest $note.File
    $bytes = [IO.File]::ReadAllBytes((Join-Path $files $note.Hash))
    try {
      $stream = New-Object IO.FileStream -ArgumentList $target, ([IO.FileMode]::CreateNew), ([IO.FileAccess]::Write)
      $Script:MoveWritten.Add(@{ Hash = $note.Hash; File = $note.File })
      try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
      if ((Get-Sha256File $target) -ne $note.Hash) { throw 'written wrong' }
    } catch {
      [Console]::Error.WriteLine("Context Locker: couldn't write $rel/$($note.File), so nothing moved.")
      Undo-MoveOut $dest ''
      return 1
    }
  }

  # Every file is written, so Context Locker can turn the notes into pointers
  $request = New-Object System.Text.StringBuilder
  [void]$request.Append("context-locker-move-out 2`nfolder $rel`n")
  foreach ($note in $plan) { [void]$request.Append("note $($note.Id) $($note.Ver) $($note.File)`n") }
  $reply = Invoke-Api 'POST' "/v1/sync/move-out?project=$($Script:ProjectId)" ($Utf8.GetBytes($request.ToString())) 'text/plain' @{}
  if ($reply.Status -eq 0) {
    [Console]::Error.WriteLine("Context Locker: the notes are written in $rel, but Context Locker couldn't be reached to turn them into pointers, so it isn't known whether they moved. Run the same command again: it takes the files there as they are, and moves what's left.")
    return 1
  }
  if ($reply.Status -ne 200) {
    Undo-MoveOut $dest ''
    [Console]::Error.WriteLine("Context Locker: nothing moved: $(Get-SaidOr $reply.Body "Context Locker answered $($reply.Status).") The files it wrote came out again.")
    return 1
  }
  $answer = @(($Utf8.GetString($reply.Body) -replace "`r", '') -split "`n")
  if ($answer[0] -cne 'context-locker-move-out 2') {
    [Console]::Error.WriteLine("Context Locker: couldn't make sense of Context Locker's answer, so it isn't known whether the notes moved. Run the same command again to find out.")
    return 1
  }

  # Only the files in this move count, whatever the answer names
  $moved = New-Object System.Collections.Generic.List[string]
  $changed = New-Object System.Collections.Generic.List[string]
  $gone = New-Object System.Collections.Generic.List[string]
  $was = ''
  $place = $rel
  foreach ($line in $answer) {
    if ($line -cmatch '^(moved|changed|gone) [0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12} (.+)\z') {
      if (-not $taken.ContainsKey($Matches[2])) { continue }
      switch ($Matches[1]) {
        'moved' { $moved.Add($Matches[2]) }
        'changed' { $changed.Add($Matches[2]) }
        'gone' { $gone.Add($Matches[2]) }
      }
    } elseif (-not $was -and $line -cmatch '^docs-home (\S+) (.+)\z') {
      # The docs home: what it was, then the place it is now
      $was = Get-Clean $Matches[1]
      $place = Get-Clean $Matches[2]
    }
  }
  # A note that changed or went meanwhile stays in Context Locker, and the
  # file this move wrote for it comes out again
  foreach ($file in (@($changed) + @($gone))) { Undo-MoveOut $dest $file }

  if ($moved.Count -gt 0) {
    Say "Moved $(Get-Plural $moved.Count 'note' 'notes') from Context Locker into ${rel}:"
    foreach ($file in $moved) { Say "- $rel/$file" }
    Say "Each one is a pointer in Context Locker now, to its file here, with the same id, and Activity says where each one went. Restoring an earlier version in Context Locker brings a note's text back."
    switch ($was) {
      'notes' { Say "The docs home for $name is $place now, instead of Notes." }
      'place' { Say "The docs home for $name is $place now, instead of the place it had." }
      'none' { Say "The docs home for $name is $place now." }
      'same' { Say "$place was already the docs home for $name." }
    }
  }
  if ($changed.Count -eq 1) {
    Say "1 note changed in Context Locker while it was moving, so it stays there: $(Get-ShortList @($changed)). The file this move wrote for it came out again. Run this again to move it."
  } elseif ($changed.Count -gt 1) {
    Say "$($changed.Count) notes changed in Context Locker while they were moving, so they stay there: $(Get-ShortList @($changed)). The files this move wrote for them came out again. Run this again to move them."
  }
  if ($gone.Count -eq 1) {
    Say "1 note was retired, became a pointer or left the project while it was moving, so it didn't move: $(Get-ShortList @($gone)). The file this move wrote for it came out again."
  } elseif ($gone.Count -gt 1) {
    Say "$($gone.Count) notes were retired, became pointers or left the project while they were moving, so they didn't move: $(Get-ShortList @($gone)). The files this move wrote for them came out again."
  }
  if ($moved.Count -eq 0) { return 1 }
  if (Test-Path -LiteralPath (Get-NotesPath $Notes) -PathType Container) {
    Say "The next sync in this project takes the moved notes out of $Notes, keeping a copy of each in $(ConvertTo-HomePath (Join-Path $ClHome 'backups'))."
  }
  return 0
}

# Takes out a file this move wrote, as long as it's still as written: one
# file by name, or with '', every file and then the folders it made
function Undo-MoveOut([string]$Dest, [string]$File) {
  foreach ($written in $Script:MoveWritten) {
    if ($File -and $written.File -cne $File) { continue }
    $path = Join-Path $Dest $written.File
    try {
      if ((Test-Path -LiteralPath $path -PathType Leaf) -and -not (Test-Link $path) -and (Get-Sha256File $path) -eq $written.Hash) {
        Remove-Item -LiteralPath $path -Force
      }
    } catch { }
  }
  if ($File) { return }
  # The folders it made, deepest first, each only once it's empty
  for ($i = $Script:MoveMade.Count - 1; $i -ge 0; $i--) {
    $dir = $Script:MoveMade[$i]
    if ((Test-Path -LiteralPath $dir -PathType Container) -and -not (Test-Link $dir) -and (Test-FolderEmpty $dir)) {
      try { [IO.Directory]::Delete($dir) } catch { }
    }
  }
}

# --- Update ---------------------------------------------------------------

# Takes the newest sync script, when Context Locker says this one can, from
# setup's folder for its release and nowhere else, as setup would save it: it
# must match the SHA-256 Context Locker gives, say it's the version Context
# Locker names and read as a PowerShell script. This one stays beside it as
# sync.ps1.previous, and the new one takes its place in one step. Nothing
# else changes (G1-112).
function Invoke-Update {
  function Stop-Update([string]$Text) { [Console]::Error.WriteLine("Context Locker: $Text") }
  if (-not (Test-Path -LiteralPath $Installed)) {
    Stop-Update "the sync script isn't at $Installed, where the $Trigger $TriggerRuns it, so there's nothing to update. Set Context Locker up again from https://context.locker/setup."
    return 1
  }
  $item = Get-Item -LiteralPath $Installed -Force
  if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
    Stop-Update "$Installed is a link, so update leaves it as it is. Set Context Locker up again from https://context.locker/setup instead."
    return 1
  }
  $installedVersion = ''
  foreach ($line in [IO.File]::ReadAllLines($Installed)) {
    if ($line -match '^\$ScriptVersion = (\d+)$') { $installedVersion = $Matches[1]; break }
  }
  if ($installedVersion -ne [string]$ScriptVersion) {
    $shown = if ($installedVersion) { $installedVersion } else { 'unknown' }
    Stop-Update "the sync script at $Installed is version $shown, and this one is version $ScriptVersion. Run the one there: $Run update $Harness"
    return 1
  }

  $reply = Invoke-Api 'GET' '/v1/sync/script' $null '' @{ 'Accept' = 'text/plain' }
  if ($reply.Status -eq 0) { Stop-Update "can't reach Context Locker, so the sync script stays as it is."; return 1 }
  if ($reply.Status -eq 401) {
    if ((Get-ReplyField $reply.Body 'error') -eq 'connection_revoked') {
      Stop-Update "$AppName's connection on $(Get-Computer 'its computer') was revoked in Context Locker, so the sync script stays as it is, and nothing syncs there any more. $(Get-RemoveOffer)"
    } else {
      Stop-Update "$AppName's connection on $(Get-Computer 'its computer') was revoked or has expired, so the sync script stays as it is. $ConnectOffer"
    }
    return 1
  }
  if ($reply.Status -ne 200) { Stop-Update "Context Locker answered $($reply.Status), so the sync script stays as it is."; return 1 }
  $newest = 0
  $want = ''
  $setup = ''
  foreach ($line in ($Utf8.GetString($reply.Body) -split "`n")) {
    if (-not $newest -and $line -cmatch '^script ([0-9]{1,6})\z') { $newest = [int]$Matches[1] }
    elseif (-not $want -and $line -cmatch '^update ([0-9a-f]{64}) ([0-9]{1,6})\z') { $want = $Matches[1]; $setup = $Matches[2] }
  }
  if (-not $newest) { Stop-Update "Context Locker didn't say which sync script is the newest, so this one stays as it is."; return 1 }
  if ($newest -le $ScriptVersion) {
    Say "Context Locker: the sync script is up to date, at version $ScriptVersion."
    return 0
  }
  if (-not $want) {
    Stop-Update "version $newest of the sync script needs more than the script, such as a new hook, so update can't take it. Offer to set Context Locker up again for the person: once they say yes, $SetupSteps."
    return 1
  }

  # Straight from the site, without the connection's token, which only
  # Context Locker's API is sent
  $url = "$Site/setup/v$setup/sync.ps1"
  $status = 0
  $bytes = [byte[]]@()
  try {
    $request = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Get, $url)
    $response = $Client.SendAsync($request).GetAwaiter().GetResult()
    $status = [int]$response.StatusCode
    $bytes = $response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
  } catch {
    $status = 0
  }
  if ($status -eq 0) { Stop-Update "couldn't download version $newest of the sync script from $url, so the script stays as it is. Try again later."; return 1 }
  if ($status -ne 200) { Stop-Update "$url answered $status, so the sync script stays as it is. Try again later."; return 1 }
  if ((Get-Sha256Bytes $bytes) -ne $want) {
    Stop-Update "the sync script from $url doesn't match the SHA-256 Context Locker gives for version $newest, so it wasn't used, and the script stays as it is."
    return 1
  }
  $saysVersion = ''
  foreach ($line in ($Utf8.GetString($bytes) -split "`n")) {
    if ($line -match '^\$ScriptVersion = (\d+)\r?$') { $saysVersion = $Matches[1]; break }
  }
  if ($saysVersion -ne [string]$newest) {
    Stop-Update "the sync script from $url isn't version $newest, so it wasn't used, and the script stays as it is."
    return 1
  }
  $new = Join-Path $Tmp 'sync.ps1.new'
  [IO.File]::WriteAllBytes($new, $bytes)
  $tokens = $null
  $errors = $null
  [void][Management.Automation.Language.Parser]::ParseFile($new, [ref]$tokens, [ref]$errors)
  if ($errors -and $errors.Count -gt 0) {
    Stop-Update "the sync script from $url doesn't read as a PowerShell script here, so it wasn't used, and the script stays as it is."
    return 1
  }

  # The old one stays beside the new one, which takes its place in one step
  $previous = "$Installed.previous"
  try {
    Set-OwnerOnly $new
    if (Test-Path -LiteralPath $previous) { Remove-Item -LiteralPath $previous -Force }
    [IO.File]::Replace($new, $Installed, $previous)
  } catch {
    Stop-Update "couldn't put the new sync script in place, so the script stays as it is."
    return 1
  }
  Say "Context Locker: the sync script is now version $newest, from $url. Version $ScriptVersion is kept at $previous, and nothing else changed."
  return 0
}

# --- Taking Context Locker off the computer (G1-260) -------------------------

# Takes the session-start and per-prompt hooks (G1-271) that run this script
# out of a JSON settings file, as setup put them in, with node, keeping
# everything else in it and its indent. Fails, changing nothing, when node
# isn't here or the file isn't as setup leaves it.
function Remove-JsonHook([string]$Path) {
  $node = Get-Command node -ErrorAction SilentlyContinue
  if (-not $node) { return $false }
  $js = Join-Path $Tmp 'take-out-hook.js'
  [IO.File]::WriteAllText($js, @'
const fs = require("fs");
const [file, installed] = process.argv.slice(2);
const raw = fs.readFileSync(file, "utf8");
const settings = JSON.parse(raw);
const runs = (hook) =>
  hook !== null && typeof hook === "object" &&
  [hook.command, hook.commandWindows, hook.args]
    .flat()
    .filter((word) => typeof word === "string")
    .some((word) => /contextlocker[\\/]+sync[.](sh|ps1)/.test(word) || word.includes(installed));
const hooks = settings && settings.hooks;
const events = ["SessionStart", "UserPromptSubmit"].filter((event) => hooks && Array.isArray(hooks[event]));
if (events.length === 0) process.exit(1);
for (const event of events) {
  const kept = hooks[event]
    .map((group) => group && Array.isArray(group.hooks) ? { ...group, hooks: group.hooks.filter((hook) => !runs(hook)) } : group)
    .filter((group) => !(group && Array.isArray(group.hooks) && group.hooks.length === 0));
  if (kept.length > 0) hooks[event] = kept;
  else delete hooks[event];
}
if (Object.keys(hooks).length === 0) delete settings.hooks;
const indent = (/^([ \t]+)"/m.exec(raw) || [])[1] || 2;
fs.writeFileSync(file + ".ctx-tmp", JSON.stringify(settings, null, indent) + "\n", { mode: 0o600 });
fs.renameSync(file + ".ctx-tmp", file);
'@, $Utf8)
  & $node.Source $js $Path $Installed 2>$null | Out-Null
  return ($LASTEXITCODE -eq 0)
}

# Each thing a lock file says the sync wrote: blocks and skills, and a
# project's notes and their README
function Get-WrittenItems([string]$LockFile) {
  $items = New-Object System.Collections.Generic.List[object]
  if (-not (Test-Path -LiteralPath $LockFile -PathType Leaf)) { return , $items }
  foreach ($line in [IO.File]::ReadAllLines($LockFile)) {
    if ($line -cmatch '^wrote (block|skill|note|file) ([0-9a-f]{64}) (\{[a-z]+\}/\S+)' -and -not $Matches[3].Contains('..')) {
      $items.Add(@{ Kind = $Matches[1]; Hash = $Matches[2]; Target = $Matches[3] })
    }
  }
  return , $items
}

# What's there now for something the sync wrote, hashed as the sync hashes
# it: a hash, or "none" when it's gone
function Get-RemoveLocal([string]$Kind, [string]$Path) {
  if ($Kind -eq 'block') {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return 'none' }
    $lines = Get-Lines (Read-Text $Path)
    $pos = Get-BlockPosition $lines
    if ($pos -eq 'none' -or $pos -eq 'broken') { return $pos }
    return Get-Sha256Text (Get-BlockText $lines $pos)
  }
  if ($Kind -eq 'skill') {
    if ((Test-Link $Path) -or -not (Test-Path -LiteralPath $Path -PathType Container) -or
      -not (Test-Path -LiteralPath (Join-Path $Path '.ctx-managed') -PathType Leaf)) { return 'none' }
    return Get-TreeHash $Path
  }
  if ((Test-Link $Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return 'none' }
  return Get-Sha256File $Path
}

# Takes out, or with no -Yes only names, what one lock says the sync wrote
# that's still as it wrote it. A project's notes stay while another app here
# syncs that project.
function Invoke-RemoveLock([string]$LockFile, [bool]$Shared, $Lists) {
  foreach ($item in (Get-WrittenItems $LockFile)) {
    $target = $item.Target
    if ($target.StartsWith('{project}/')) {
      if (-not $Script:ProjectRoot -or -not (Test-InsideProject $target)) { continue }
    }
    $path = Resolve-Target $target
    if (-not $path) { continue }
    $what = switch ($item.Kind) {
      'block' { "Context Locker's part of $path" }
      'skill' { "the skill $($target.Substring($target.LastIndexOf('/') + 1)) at $path" }
      default { $path }
    }
    if ($Shared -and ($item.Kind -eq 'note' -or $item.Kind -eq 'file')) {
      $Lists.Kept.Add("$what, as another app on $(Get-Computer 'the computer') syncs that project")
      continue
    }
    $local = Get-RemoveLocal $item.Kind $path
    if ($local -eq 'none') { continue }
    if ($local -ne $item.Hash) {
      $Lists.Kept.Add("$what, which changed since the sync wrote it")
      continue
    }
    $Lists.Taken.Add($what)
    if (-not $Yes) { continue }
    if (-not (Backup-Item $path $target)) {
      $Lists.Failed.Add("$what, as it couldn't be backed up first")
      continue
    }
    try {
      switch ($item.Kind) {
        'block' { if ((Remove-Block $path $target) -ne 0) { throw 'broken' } }
        'skill' { Remove-Item -LiteralPath $path -Recurse -Force }
        default { Remove-Item -LiteralPath $path -Force }
      }
    } catch { $Lists.Failed.Add("$what, which couldn't be taken out") }
  }
}

# The hook that runs the sync, taken out where setup put it, or named for
# the app to take out where the file isn't JSON or node isn't here
function Invoke-RemoveHook($Lists) {
  if ($Harness -eq 'claude-code' -or $Harness -eq 'codex') {
    $file = if ($Harness -eq 'claude-code') { Join-Path (Get-RootDir 'claude') 'settings.json' } else { Join-Path (Get-RootDir 'codex') 'hooks.json' }
    $toml = Join-Path (Get-RootDir 'codex') 'config.toml'
    $session = Test-HookIn $file
    $prompt = Test-HookIn $file 'UserPromptSubmit'
    if ($session -or $prompt) {
      if ($session) { $Lists.Taken.Add("the session-start hook in $file") }
      if ($prompt) { $Lists.Taken.Add("the per-prompt hook in $file") }
      if ($Yes -and (-not (Backup-Item $file "hook-$(Split-Path -Leaf $file)") -or -not (Remove-JsonHook $file))) {
        if ($session -and $prompt) { $Lists.Manual.Add("Take the hooks that run sync.ps1 out of $file.") }
        elseif ($session) { $Lists.Manual.Add("Take the session-start hook that runs sync.ps1 out of $file.") }
        else { $Lists.Manual.Add("Take the per-prompt hook that runs sync.ps1 out of $file.") }
      }
    } elseif ($Harness -eq 'codex') {
      foreach ($hookEvent in @('SessionStart', 'UserPromptSubmit')) {
        if (Test-HookIn $toml $hookEvent) { $Lists.Manual.Add("Take the [[hooks.$hookEvent]] entry that runs sync.ps1 out of $toml.") }
      }
    }
  } elseif ($Harness -eq 'hermes') {
    $config = Join-Path (Get-RootDir 'hermes') 'config.yaml'
    if ((Test-HermesHooksIn $config) -or (Test-HermesHooksIn $config @('pre_llm_call'))) { $Lists.Manual.Add("Take the hooks that run sync.ps1 out of the hooks in $config.") }
  } elseif ($Harness -eq 'openclaw' -and (Test-OpenClawHookIn)) {
    $Lists.Taken.Add("OpenClaw's hook at $OpenClawHook")
    if ($Yes) {
      $openclaw = Get-Command openclaw -ErrorAction SilentlyContinue
      if ($openclaw) { try { & $openclaw.Source hooks disable context-locker-sync 2>$null | Out-Null } catch { } }
      try {
        if (-not (Backup-Item $OpenClawHook 'hook-openclaw')) { throw 'no backup' }
        Remove-Item -LiteralPath $OpenClawHook -Recurse -Force
      } catch { $Lists.Manual.Add("Take OpenClaw's hook out: $OpenClawHook") }
    }
  }
  $job = ((Get-SavedDailyJob) -split ' ')[0]
  if ($job) { $Lists.Manual.Add("Its daily job, $job, stays in $AppName's scheduler. To stop it, run: $Harness cron remove $job") }
}

# Takes Context Locker off the computer for the app, once the person says
# yes: the hook that runs the sync, the files the sync wrote that are still
# as it wrote them, and the app's folder here, with the shared script and
# files once no other app uses them. What changed since the sync wrote it
# stays, and is named, and so do the backups. Without -Yes it only says what
# it would take out. It never revokes or deletes the connection in Context
# Locker, which stays the person's to change in Connections.
function Invoke-Remove {
  $lists = @{
    Taken = New-Object System.Collections.Generic.List[string]
    Kept = New-Object System.Collections.Generic.List[string]
    Manual = New-Object System.Collections.Generic.List[string]
    Failed = New-Object System.Collections.Generic.List[string]
  }
  $others = @(@('claude-code', 'codex', 'hermes', 'openclaw') | Where-Object { $_ -ne $Harness -and (Test-Path -LiteralPath (Join-Path $ClHome $_) -PathType Container) })

  # What the sync wrote for the app itself, then in each project linked here
  $Script:ProjectRoot = ''
  $Script:ProjectId = ''
  Invoke-RemoveLock (Join-Path $AppDir 'global.lock') $false $lists
  $projects = Join-Path $ClHome 'projects'
  if (Test-Path -LiteralPath $projects -PathType Leaf) {
    foreach ($line in [IO.File]::ReadAllLines($projects)) {
      $id, $folder = $line.Split(' ', 2)
      if (-not $folder -or $id -cnotmatch $Uuid) { continue }
      $lock = Join-Path (Join-Path $AppDir 'projects') "$id.lock"
      if (-not (Test-Path -LiteralPath $lock -PathType Leaf) -or -not (Test-Path -LiteralPath $folder -PathType Container)) { continue }
      $shared = [bool]@($others | Where-Object { Test-Path -LiteralPath (Join-Path (Join-Path (Join-Path $ClHome $_) 'projects') "$id.lock") -PathType Leaf }).Count
      $Script:ProjectRoot = $folder
      $Script:ProjectId = $id
      Invoke-RemoveLock $lock $shared $lists
      if ($Yes -and -not $shared) {
        $notes = Join-Path (Join-Path $folder '.context-locker') 'notes'
        foreach ($empty in @((Join-Path $notes 'everywhere'), $notes, (Join-Path $folder '.context-locker'))) {
          if ((Test-Path -LiteralPath $empty -PathType Container) -and -not @(Get-ChildItem -LiteralPath $empty -Force).Count) {
            Remove-Item -LiteralPath $empty -Force -ErrorAction SilentlyContinue
          }
        }
      }
    }
  }
  $Script:ProjectRoot = ''
  $Script:ProjectId = ''
  Invoke-RemoveHook $lists

  # The app's folder here, and once no other app uses them, the shared script
  # and what goes with it. The backups stay.
  if (Test-Path -LiteralPath $AppDir -PathType Container) { $lists.Taken.Add("$AppDir, with its token and what its syncs kept") }
  if (-not $others.Count -and (Test-Path -LiteralPath $Installed -PathType Leaf)) { $lists.Taken.Add("the sync script at $Installed") }
  $backups = Join-Path $ClHome 'backups'

  if (-not $Yes) {
    Say "Context Locker: taking it off $(Get-Computer 'the computer') for $AppName takes out:"
    foreach ($line in $lists.Taken) { Say "- $line" }
    if ($lists.Kept.Count) {
      Say 'It leaves:'
      foreach ($line in $lists.Kept) { Say "- $line" }
    }
    foreach ($line in $lists.Manual) { Say "Then: $line" }
    Say "The connection stays in Context Locker, and so do the backups in $backups."
    Say "Ask the person, and only once they say yes, run: $Run remove $Harness -Yes"
    return 0
  }

  Remove-Item -LiteralPath $AppDir -Recurse -Force -ErrorAction SilentlyContinue
  if (-not $others.Count) {
    foreach ($name in @('sync.sh', 'sync.sh.previous', 'sync.ps1', 'sync.ps1.previous', 'machine-id', 'projects', 'sources', 'config')) {
      Remove-Item -LiteralPath (Join-Path $ClHome $name) -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath (Join-Path $ClHome 'gather') -Recurse -Force -ErrorAction SilentlyContinue
  }
  Say "Context Locker is off $(Get-Computer 'the computer') for $AppName. It took out:"
  foreach ($line in $lists.Taken) { Say "- $line" }
  if ($lists.Kept.Count) {
    Say 'It left:'
    foreach ($line in $lists.Kept) { Say "- $line" }
  }
  if ($lists.Failed.Count) {
    Say "It couldn't take out:"
    foreach ($line in $lists.Failed) { Say "- $line" }
  }
  foreach ($line in $lists.Manual) { Say "Still to do: $line" }
  Say "The backups stay in $backups. The connection stays in Context Locker: revoke or remove it from its page in Connections if you like."
  if ($lists.Failed.Count) { return 1 }
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
      'map' { $exitCode = Invoke-Map }
      'gather' { $exitCode = Invoke-Gather }
      'gather-submit' { $exitCode = Invoke-GatherSubmit }
      'keep' { $exitCode = Invoke-Keep }
      'export' { $exitCode = Invoke-Export }
      'notes-move-out' { $exitCode = Invoke-NotesMoveOut }
      'fix' { $exitCode = Invoke-Fix }
      'daily-job' { $exitCode = Invoke-DailyJob }
      'update' { $exitCode = Invoke-Update }
      'remove' { $exitCode = Invoke-Remove }
      'tickets' { $exitCode = Invoke-Tickets }
      'requests' { $exitCode = Invoke-Tickets }
      'notes' { $exitCode = Invoke-Tickets }
      'suggest' { $exitCode = Invoke-Tickets }
      'remember' { $exitCode = Invoke-Tickets }
      'message' { $exitCode = Invoke-Tickets }
    }
  } catch {
    [Console]::Error.WriteLine("Context Locker: $($_.Exception.Message)")
    $exitCode = 1
  } finally {
    Remove-Item -LiteralPath $Tmp -Recurse -Force -ErrorAction SilentlyContinue
    if ($Script:GatherLock) { Remove-Item -LiteralPath $Script:GatherLock -Recurse -Force -ErrorAction SilentlyContinue }
  }
  $Script:Stdout.Flush()
  exit $exitCode
}

try {
  $globalOk = Sync-Scope '' (Join-Path $AppDir 'global')
  # Whether it applied everything, as what an import moves waits until the
  # playbook's copy is in the app's files (G1-208)
  $globalFailed = $Script:Failed

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
    # Context Locker is asked about the git remote only once it has answered
    $how = if ($globalOk -eq 0) { 'link' } else { 'local' }
    if ((Find-Project $how) -and $globalOk -eq 0) {
      $Script:Scope = 'project'
      $result = Sync-Scope "?project=$($Script:ProjectId)&layer=$($Script:Layer)" (Join-Path (Join-Path $AppDir 'projects') $Script:ProjectId)
      if ($result -eq 3) {
        if ($Script:Layer -eq 'personal') { Remove-ProjectLink $Script:ProjectId }
      } elseif ($Script:FoundBy -eq 'flag') {
        Save-Remote $Script:ProjectRoot
      }
      # Codex stops reading a repo's AGENTS.md files at its limit, so a session
      # that misses part of the block is told where it is (G1-212)
      if ($Harness -eq 'codex' -and $Script:Layer -eq 'repo') {
        $codexPath = Resolve-Target '{project}/AGENTS.md'
        if ($codexPath -and (Get-FitLine '{project}/AGENTS.md' $codexPath)) {
          $Script:Said.Add("Context Locker: Codex doesn't read all of Context Locker's block in $codexPath. Read the block there in full before you start.")
        }
      }
    }
  } elseif ($globalOk -eq 0) {
    Sync-DailyProjects
  }
  # What an import moves, once the person picked it (G1-208)
  if ($globalOk -eq 0 -and -not $globalFailed) { Move-Imported }
  Confirm-Removals
  Confirm-ProjectRemovals
  # How this app runs the sync, for its connection's page, when that changed
  # or a day has passed, after a sync that worked. A daily run says so as it
  # ends.
  if (-not $Daily -and $globalOk -eq 0 -and -not $Script:Failed) { Send-Schedule 'check' }
} catch {
  Warn "sync stopped: $($_.Exception.Message)"
  $Script:Failed = $true
} finally {
  if ($HaveLock) { Remove-Item -LiteralPath $Lock -Recurse -Force -ErrorAction SilentlyContinue }
  Remove-Item -LiteralPath $Tmp -Recurse -Force -ErrorAction SilentlyContinue
}

# What the app reads at the start of a session: when the sync couldn't get
# Context Locker's answer, why and what to offer (G1-258); then a line about
# changes waiting for the owner, then a project's preferences when they
# aren't in the repo, and a line when a newer sync script is out. Without a
# connection that works, what the last answer asked of the app can't be
# done, and setting up again or taking Context Locker off covers the newer
# script, so the line about the connection is all it says of them.
$contextParts = New-Object System.Collections.Generic.List[string]
$unusable = @('revoked', 'gone', 'old') -contains $Script:Broken
if ($Script:Broken) { $contextParts.Add("$(Get-BrokenLine $Script:Broken)`n") }
$globalContext = Join-Path $AppDir 'global.context'
if (-not $unusable -and (Test-Path -LiteralPath $globalContext -PathType Leaf)) { $contextParts.Add((Read-Text $globalContext)) }
if ($Script:ProjectId) {
  $candidate = Join-Path (Join-Path $AppDir 'projects') "$($Script:ProjectId).context"
  if (Test-Path -LiteralPath $candidate -PathType Leaf) { $contextParts.Add((Read-Text $candidate)) }
}
if (-not $unusable -and (Test-NewerScript)) {
  # Without Context Locker's answer this time, the newest script is the one
  # the last answer named, so the line says when that was, and a stale lock
  # doesn't read as live (G1-258)
  $asOf = ''
  if ($Script:Broken) {
    $day = Get-LastSyncDay
    if ($day) { $asOf = "as of the last sync, on $day, " }
  }
  if (Test-CanUpdate) {
    $contextParts.Add("Context Locker: $($asOf)version $($Script:NewestScript) of its sync script is out. When it suits the user, offer to update it, and once they say yes, run ``$Run update $Harness``. That changes only the script, and the one installed keeps working until then.`n")
  } else {
    $contextParts.Add("Context Locker: $asOf$NewerLine`n")
  }
}

# What this run changed in the app's files, such as "its instructions and 2
# skills", or '' when it changed nothing
function Get-WhatChanged {
  $parts = New-Object System.Collections.Generic.List[string]
  if ($Script:WBlocks -gt 0) { $parts.Add('its instructions') }
  if ($Script:WSkills -gt 0) { $parts.Add((Get-Plural $Script:WSkills 'skill' 'skills')) }
  if ($Script:WNotes -gt 0) { $parts.Add((Get-Plural $Script:WNotes 'note' 'notes')) }
  if ($parts.Count -le 1) { return ($parts -join '') }
  return ((@($parts) | Select-Object -First ($parts.Count - 1)) -join ', ') + ' and ' + $parts[$parts.Count - 1]
}

# Then what changed since the last sync, in a line: what the sync brought in,
# or with auto sync off, that changes are waiting, then any edit kept beside
# its note
$changed = New-Object System.Collections.Generic.List[string]
if ($Script:ChangesWaiting) {
  $changed.Add("Context Locker: the user's playbook changed since this app last synced. Auto sync is off, so its files stay as they are until it syncs: run ``$Run $Harness -Now`` when it suits.")
} else {
  $brought = Get-WhatChanged
  if ($brought) { $changed.Add("Context Locker: the user's playbook changed since this app last synced, and the sync brought the changes in: $brought.") }
}
foreach ($line in $Script:Said) { $changed.Add($line) }
if ($changed.Count -gt 0) { $contextParts.Add(((@($changed) | ForEach-Object { "$_`n" }) -join '')) }
$context = $contextParts -join "`n"

# A daily run tells Context Locker it finished, or why it failed. Context
# Locker counts the run when the word arrives, which a computer that's off,
# or an app that's closed, can't send.
if ($Daily) {
  if ($Script:Failed) {
    Save-FailedRun
    Send-Schedule 'now'
    foreach ($line in $Script:Warnings) { [Console]::Out.WriteLine($line) }
    exit 1
  }
  Send-Schedule 'ran'
  exit 0
}

foreach ($line in $Script:Warnings) { [Console]::Error.WriteLine($line) }

# Hermes's and OpenClaw's hooks don't read what a sync prints
if ($Quiet) {
  $Script:Stdout.Flush()
  exit 0
}

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
