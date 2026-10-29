#!/bin/sh
# Context Locker sync, version 18. MIT licence.
#
#   sh sync.sh <app> [--project <id>] [--now] [--hook] [--daily]
#   sh sync.sh map <app> [--all]
#   sh sync.sh gather <app>
#   sh sync.sh gather-submit <app> <plan.json>
#   sh sync.sh export <app> [--to <folder>]
#   sh sync.sh notes-move-out <app> --to <folder>
#   sh sync.sh fix <app> [--all]
#   sh sync.sh fix <app> --done <id> | --skip <id> --reason <text>
#   sh sync.sh signin <app> [--code <code>]
#   sh sync.sh plan|doctor|readback|daily-job <app>
#
# Keeps one AI app's files in step with your playbook at context.locker. <app>
# is claude-code, codex, hermes or openclaw. The script asks for a manifest of
# what the app's files should hold, writes only what changed, and sends any
# edit it finds in a synced file back to Context Locker. It writes only inside
# Context Locker's marked blocks, skill folders and a project's notes folder,
# backs up anything it replaces that it didn't write, and never deletes a
# file of yours. When Context Locker can't be reached, the app keeps the
# files it has.
#
# In a project, the notes folder, .context-locker/notes, holds the project's
# notes and, in everywhere/, the ones that apply everywhere, one Markdown
# file each. An edited note or a new .md file there goes to Context Locker
# at the next sync, and git leaves the folder out. The sync also checks that
# the project's pointers to paths in its repo are there.
#
# The project is the one --project names; else the one a .contextlocker.json
# in the repo names; else a folder linked on this computer; else the project
# whose git remote is the repo's origin, which links the folder.
#
# Each app runs the sync on its own events, such as the start of a session
# and compaction, as the table under "When each app syncs" lists. With auto
# sync on, the default, a sync brings in what changed and says so in a line.
# With it off, a sync that finds changes says so and leaves the files as they
# are until the app syncs with --now. A project can have its own setting.
#
# --project <id> links the current folder to a project, for this computer
#                only, and records the repo's origin remote on the project
#                when it has none.
# --now          syncs even when auto sync is off.
# --hook         is for an app's hook, and prints only what that app's hook
#                reads.
# --daily        is for the daily job in Hermes's or OpenClaw's own
#                scheduler: silent when all is well, exit 1 when not. It
#                syncs the projects linked on this computer too, keeps to
#                auto sync off, and tells Context Locker the run finished, or
#                why it failed, for the connection's page.
#
# map prints the project's map: its docs home, its Start here entries, the
# notes and pointers that matter in the current folder (every one with --all)
# and the newest of the rest. A pointer stands in for a note kept somewhere
# else, such as a file in the repo, and says where.
#
# gather copies what every AI app on this computer already knows, their
# instructions, skills and memories, into a working set only this account can
# read, for the Gather skill to sort into one plan. It only reads the apps'
# files, never changes or deletes them, follows no link in their folders and
# lists every one it skipped, and never copies anything that looks like a
# secret. gather-submit sends the plan the person approved to Context Locker,
# then deletes Gather's working sets.
#
# export downloads everything in the playbook, as plain files with the
# history as JSON Lines, into a new folder, "Context Locker export <date>" in
# the current one unless --to names another. It never writes into a folder
# that already holds anything.
#
# notes-move-out moves the project's notes out of Context Locker into a
# folder in its repo that --to names: it writes each note there as a Markdown
# file, never over a file, and only then asks Context Locker to turn each one
# into a pointer to its file, with the same id, and to make the folder the
# project's docs home. The folder must be inside the project, outside
# .context-locker, and reached through no link. The notes that apply
# everywhere stay.
#
# fix prints Tidy-up, the upkeep the playbook needs, such as a preference
# nobody has touched in 90 days, each item with its id, the evidence, a fix
# and its risk: the project's and the ones that apply everywhere, or the
# whole playbook's with --all or outside a project. Once an item is fixed,
# --done <id> marks it done, and Context Locker checks it again at once.
# --skip <id> --reason <text> leaves it for the person, with the reason.
#
# For setup (see context.locker/setup):
#   signin    connects the app with a code you approve in your browser. The
#             first run prints the link and the code and exits 3. Run it again
#             to wait up to --wait seconds (50) for the approval: it exits 0
#             once connected, and 3 while still waiting. With --code, it
#             connects with a one-time code the person made in Context Locker
#             instead, with nothing to approve, and exits 0 once connected.
#   plan      shows what a sync would write, and the hooks to add. It changes
#             nothing.
#   doctor    checks the connection, the files, the hooks and the daily job,
#             how full the playbook's limits are, instruction files Context
#             Locker doesn't manage, and anything that has drifted since the
#             last sync. It tells Context Locker how the app runs the sync,
#             for the connection's page. It exits 1 when a check fails.
#   daily-job adds a daily job to Hermes's or OpenClaw's own scheduler that
#             runs the sync once a day, with no model call, once the person
#             says yes. One that's there already stays as it is. Claude Code
#             and Codex can't run one in the background.
#   readback  prints what Context Locker has put in the app's files
set -u
# What the script writes is this account's alone, apart from notes moved out
# into a repo, which get the permissions the repo's files usually have
UMASK_WAS=$(umask)
umask 077

SCRIPT_VERSION=18
MODE=sync
case ${1:-} in
  signin | plan | doctor | readback | map | gather | gather-submit | export | notes-move-out | fix | daily-job)
    MODE=$1
    shift
    ;;
esac
HARNESS=${1:-}
[ $# -gt 0 ] && shift
DAILY=0
NOW=0
HOOK=0
ALL=0
PROJECT_FLAG=
PLAN_FILE=
WAIT=50
TO=
TO_SET=0
FIX_AS=
FIX_ID=
FIX_MARKS=0
REASON=
REASON_SET=0
CODE=
# gather-submit's plan comes before any option
if [ "$MODE" = gather-submit ] && [ $# -gt 0 ]; then
  case $1 in
    -*) ;;
    *)
      PLAN_FILE=$1
      shift
      ;;
  esac
fi
while [ $# -gt 0 ]; do
  case $1 in
    --daily) DAILY=1 ;;
    --now) NOW=1 ;;
    --hook) HOOK=1 ;;
    --all) ALL=1 ;;
    --project)
      PROJECT_FLAG=${2:-}
      [ $# -gt 1 ] && shift
      ;;
    --wait)
      WAIT=${2:-}
      [ $# -gt 1 ] && shift
      ;;
    --to)
      TO=${2:-}
      TO_SET=1
      [ $# -gt 1 ] && shift
      ;;
    --done)
      FIX_AS=done FIX_ID=${2:-}
      FIX_MARKS=$((FIX_MARKS + 1))
      [ $# -gt 1 ] && shift
      ;;
    --skip)
      FIX_AS=skipped FIX_ID=${2:-}
      FIX_MARKS=$((FIX_MARKS + 1))
      [ $# -gt 1 ] && shift
      ;;
    --reason)
      REASON=${2:-}
      REASON_SET=1
      [ $# -gt 1 ] && shift
      ;;
    --code)
      CODE=${2:-}
      [ $# -gt 1 ] && shift
      ;;
    *)
      printf 'Context Locker: unknown option %s\n' "$1" >&2
      exit 2
      ;;
  esac
  shift
done

usage() {
  printf 'Usage: sh sync.sh <app> [--project <id>] [--now] [--hook] [--daily]\n       sh sync.sh map <app> [--all]\n       sh sync.sh gather <app>\n       sh sync.sh gather-submit <app> <plan.json>\n       sh sync.sh export <app> [--to <folder>]\n       sh sync.sh notes-move-out <app> --to <folder>\n       sh sync.sh fix <app> [--all]\n       sh sync.sh fix <app> --done <id> | --skip <id> --reason <text>\n       sh sync.sh signin <app> [--code <code>]\n       sh sync.sh plan|doctor|readback|daily-job <app>\n<app> is claude-code, codex, hermes or openclaw.\n' >&2
  exit 2
}
case $HARNESS in
  claude-code | codex | hermes | openclaw) ;;
  *) usage ;;
esac
[ "$MODE" = gather-submit ] && [ -z "$PLAN_FILE" ] && usage
# --now and --hook are for a sync
[ "$MODE" != sync ] && { [ "$NOW" = 1 ] || [ "$HOOK" = 1 ]; } && usage
# Hermes's and OpenClaw's hooks don't read what a sync prints, and a daily
# job tells the person only of a failure, so what it finds is said at the
# next session start
QUIET=0
[ "$HOOK" = 1 ] && { [ "$HARNESS" = hermes ] || [ "$HARNESS" = openclaw ]; } && QUIET=1
[ "$DAILY" = 1 ] && QUIET=1
case $WAIT in '' | *[!0-9]*) usage ;; esac
# --code is for signin, with a one-time code from Context Locker
if [ -n "$CODE" ]; then
  [ "$MODE" = signin ] || usage
  case $CODE in ctxl_ic_*) ;; *) usage ;; esac
  case $CODE in *[!A-Za-z0-9_-]*) usage ;; esac
  [ "${#CODE}" = 51 ] || usage
fi
# --to is for export and notes-move-out, which needs it
case $MODE in
  export) [ "$TO_SET" = 1 ] && [ -z "$TO" ] && usage ;;
  notes-move-out) [ -n "$TO" ] || usage ;;
  *) [ "$TO_SET" = 1 ] && usage ;;
esac
# --done and --skip are for fix, one at a time, with an item's id; a skip
# needs its reason, and only a skip has one
if [ "$MODE" = fix ]; then
  case $FIX_MARKS in
    0) [ "$REASON_SET" = 1 ] && usage ;;
    1)
      [ "$ALL" = 1 ] && usage
      case $FIX_ID in
        [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
        *) usage ;;
      esac
      if [ "$FIX_AS" = skipped ]; then
        [ -n "$(printf '%s' "$REASON" | tr -d '[:space:]')" ] || usage
      else
        [ "$REASON_SET" = 1 ] && usage
      fi
      ;;
    *) usage ;;
  esac
elif [ "$FIX_MARKS" -gt 0 ] || [ "$REASON_SET" = 1 ]; then
  usage
fi

case $HARNESS in
  claude-code) APP_NAME='Claude Code' ;;
  codex) APP_NAME=Codex ;;
  hermes) APP_NAME=Hermes ;;
  openclaw) APP_NAME=OpenClaw ;;
esac

CL_HOME=${CONTEXT_LOCKER_HOME:-$HOME/.contextlocker}
APP_DIR=$CL_HOME/$HARNESS
UUID='[0-9a-f]\{8\}-[0-9a-f]\{4\}-[0-9a-f]\{4\}-[0-9a-f]\{4\}-[0-9a-f]\{12\}'
HASH='[0-9a-f]\{64\}'
TMP=
WRITTEN=0
HELD=0
# What this run changed in the app's files, for the line that says so
W_BLOCKS=0
W_SKILLS=0
W_NOTES=0
FAILED=0
SKILLS_CHANGED=0
STAMP=$(date -u +%Y%m%dT%H%M%SZ)

have() { command -v "$1" >/dev/null 2>&1; }

# Warnings go to the end of the run: stderr in a session, stdout for a daily job
warn() { printf 'Context Locker: %s\n' "$*" >>"$TMP/warnings"; }

# A session start mustn't fail because of Context Locker; anything else reports it
finish_early() {
  printf 'Context Locker: %s\n' "$1" >&2
  [ "$MODE" = sync ] && [ "$DAILY" = 0 ] && exit 0
  exit 1
}

for tool in curl tar awk sed find mkdir mktemp xargs; do
  have "$tool" || finish_early "sync needs $tool, which isn't installed."
done
if have sha256sum; then
  HASHER=sha256sum
elif have openssl; then
  HASHER=openssl
elif have shasum; then
  HASHER=shasum
else
  finish_early "sync needs sha256sum, openssl or shasum."
fi

sha_stdin() {
  case $HASHER in
    sha256sum) sha256sum | cut -d ' ' -f 1 ;;
    openssl) openssl dgst -sha256 -r | cut -d ' ' -f 1 ;;
    *) shasum -a 256 | cut -d ' ' -f 1 ;;
  esac
}
sha_file() { sha_stdin <"$1"; }

read_setting() { [ -f "$2" ] && sed -n "s/^$1=//p" "$2" | head -n 1; }

API=${CONTEXT_LOCKER_API:-$(read_setting api "$CL_HOME/config")}
API=${API:-https://api.context.locker}
API=${API%/}
TOKEN=$(head -n 1 "$APP_DIR/token" 2>/dev/null | tr -d ' \r\n')

# Prints what's wrong with the saved token, or fails when nothing is
token_problem() {
  case $TOKEN in
    ctxl_at_?*) ;;
    *)
      printf '%s' "$APP_NAME isn't connected on this computer. Set it up at context.locker/setup."
      return 0
      ;;
  esac
  case $TOKEN in
    *[!A-Za-z0-9_-]*)
      printf '%s' "the saved token for $APP_NAME is damaged. Set it up again at context.locker/setup."
      return 0
      ;;
  esac
  return 1
}
case $MODE in
  sync | plan | map | gather | gather-submit | export | notes-move-out | fix | daily-job) problem=$(token_problem) && finish_early "$problem" ;;
esac

# The global manifest names the newest sync script. A newer one than this
# gets a line at session start and in the doctor; nothing changes on its own.
NEWER_LINE="Context Locker: a newer version of its sync script is out. When it suits the user, offer to set Context Locker up again from https://context.locker/setup. The one installed keeps working until then."
newer_script() {
  sv_newest=$(sed -n 's/^entry script \([0-9]\{1,6\}\)$/\1/p' "$APP_DIR/global.lock" 2>/dev/null | head -n 1)
  [ -n "$sv_newest" ] && [ "$sv_newest" -gt "$SCRIPT_VERSION" ]
}

# Only a sync needs the projects folder, so plan leaves no trace
case $MODE in
  sync) mkdir -p "$APP_DIR/projects" ;;
  signin) mkdir -p "$APP_DIR" ;;
  *) mkdir -p "$CL_HOME" ;;
esac || finish_early "can't write to $CL_HOME."
TMP=$(mktemp -d "$CL_HOME/tmp.XXXXXX") || finish_early "can't write to $CL_HOME."
: >"$TMP/warnings"
# What the app should hear at the start of a session, beside its own text
: >"$TMP/said"
LOCK=
trap 'rm -rf "$TMP"; [ -z "$LOCK" ] || rm -rf "$LOCK"' EXIT
trap 'exit 1' HUP INT TERM

# One sync at a time on this computer. A lock older than 10 minutes is stale.
if [ "$MODE" = sync ]; then
  tries=0
  while ! mkdir "$CL_HOME/sync.lock" 2>/dev/null; do
    if [ -n "$(find "$CL_HOME/sync.lock" -maxdepth 0 -mmin +10 2>/dev/null)" ]; then
      rm -rf "$CL_HOME/sync.lock"
      continue
    fi
    tries=$((tries + 1))
    [ "$tries" -ge 15 ] && finish_early "another sync is still running, so this one stopped."
    sleep 1
  done
  LOCK=$CL_HOME/sync.lock
fi

# --- Where targets live --------------------------------------------------

OPENCLAW_WORKSPACE=$(read_setting workspace "$APP_DIR/config")
PROJECT_ROOT=
PROJECT_ID=
LAYER=
SCOPE=global

root_dir() {
  case $1 in
    claude) printf '%s' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" ;;
    codex) printf '%s' "${CODEX_HOME:-$HOME/.codex}" ;;
    agents) printf '%s' "$HOME/.agents" ;;
    hermes) printf '%s' "${HERMES_HOME:-$HOME/.hermes}" ;;
    openclaw) printf '%s' "${OPENCLAW_WORKSPACE:-${OPENCLAW_WORKSPACE_DIR:-$HOME/.openclaw/workspace}}" ;;
    project) [ -n "$PROJECT_ROOT" ] && printf '%s' "$PROJECT_ROOT" ;;
    *) return 1 ;;
  esac
}

# Every file and skills folder each app's sync may write. Anything else in a
# manifest is refused.
allowed() {
  # A project's notes folder, for each app that works in project folders, in
  # a repo linked to the workspace or a folder linked on this computer. Git
  # leaves it out, so the repo's own files stay as they are.
  case $2 in
    note | file)
      [ "$SCOPE" = project ] || return 1
      case $HARNESS in
        openclaw) return 1 ;;
        hermes) [ "$LAYER" = repo ] || return 1 ;;
      esac
      if [ "$2" = file ]; then
        [ "$1" = '{project}/.context-locker/notes/README.md' ]
        return
      fi
      case $1 in
        '{project}/.context-locker/notes/everywhere/'*) an_rest=${1#\{project\}/.context-locker/notes/everywhere/} ;;
        '{project}/.context-locker/notes/'*) an_rest=${1#\{project\}/.context-locker/notes/} ;;
        *) return 1 ;;
      esac
      case $an_rest in */*) return 1 ;; esac
      note_name_ok "$an_rest"
      return
      ;;
  esac
  # Project files belong to a project's sync, the app's own files to the global one
  case $1 in
    '{project}/'*) [ "$SCOPE" = project ] && [ "$LAYER" = repo ] || return 1 ;;
    *) [ "$SCOPE" = global ] || return 1 ;;
  esac
  case "$HARNESS $1" in
    'claude-code {claude}/rules/context-locker.md' | 'claude-code {project}/.claude/rules/context-locker.md' | \
      'codex {codex}/AGENTS.md' | 'codex {project}/AGENTS.md' | \
      'hermes {hermes}/SOUL.md' | 'hermes {project}/AGENTS.md' | \
      'openclaw {openclaw}/USER.md' | 'openclaw {openclaw}/AGENTS.md')
      [ "$2" = block ]
      ;;
    'claude-code {claude}/skills/'* | 'claude-code {project}/.claude/skills/'* | \
      'codex {agents}/skills/'* | 'codex {project}/.agents/skills/'* | \
      'hermes {hermes}/skills/'* | 'openclaw {agents}/skills/'*)
      case ${1#*/skills/} in */*) return 1 ;; esac
      [ "$2" = skill ] && printf '%s\n' "${1##*/}" | grep -Eq '^[a-z0-9]+(-[a-z0-9]+)*$' &&
        [ "${#1}" -le 200 ]
      ;;
    *) return 1 ;;
  esac
}

# The path on this computer for a target such as {codex}/AGENTS.md
resolve() {
  root=${1%%\}*}
  root=${root#\{}
  rest=${1#*\}}
  base=$(root_dir "$root") || return 1
  [ -n "$base" ] || return 1
  path=$base$rest
  # Codex reads AGENTS.override.md instead of AGENTS.md when it has content
  if [ "$1" = '{codex}/AGENTS.md' ] && [ -f "$base/AGENTS.override.md" ] &&
    grep -q '[^[:space:]]' "$base/AGENTS.override.md"; then
    path=$base/AGENTS.override.md
  fi
  printf '%s' "$path"
}

# True when no part of a project target's path below the project folder is a
# link, so a repo can't point a write somewhere else on the computer
inside_project() {
  cur=$PROJECT_ROOT
  rest=${1#\{project\}/}
  while [ -n "$rest" ]; do
    part=${rest%%/*}
    case $rest in
      */*) rest=${rest#*/} ;;
      *) rest= ;;
    esac
    cur=$cur/$part
    [ -L "$cur" ] && return 1
  done
  return 0
}

is_own_file() {
  case $1 in
    '{claude}/rules/context-locker.md' | '{project}/.claude/rules/context-locker.md') return 0 ;;
  esac
  return 1
}

safe_name() { printf '%s' "$1" | sed 's/[{}]//g; s|/|-|g'; }

backup() {
  dest=$CL_HOME/backups/$STAMP/$HARNESS
  [ -n "$PROJECT_ID" ] && case $2 in '{project}/'*) dest=$dest/project-$PROJECT_ID ;; esac
  mkdir -p "$dest" && cp -R -p "$1" "$dest/$(safe_name "$2")" 2>/dev/null
}

# --- Managed blocks --------------------------------------------------------

# "none", "broken", or the first and last line of the block
block_position() {
  awk '
    /^<!-- context-locker:start( v[0-9]+)? -->[ \t\r]*$/ { s++; if (!sl) sl = NR }
    /^<!-- context-locker:end -->[ \t\r]*$/ { e++; if (!el) el = NR }
    END {
      if (s == 0 && e == 0) print "none"
      else if (s == 1 && e == 1 && sl < el) print sl " " el
      else print "broken"
    }' "$1"
}

block_lines() { awk -v s="$2" -v e="$3" 'NR >= s && NR <= e { print } NR > e { exit }' "$1" | tr -d '\r'; }

ends_with_newline() { [ -z "$(tail -c 1 "$1")" ]; }

move_into_place() {
  if [ -L "$2" ]; then
    # Keep a symlinked file a symlink, such as a dotfiles setup's
    cat "$1" >"$2" && rm -f "$1"
  else
    mv -f "$1" "$2"
  fi
}

# Puts a block into a file: in place of the old block, or at the end after a
# blank line. Everything outside the markers stays as it was.
write_block() {
  file=$1 block=$2
  dir=$(dirname "$file")
  mkdir -p "$dir" || return 1
  tmp=$dir/.$(basename "$file").ctx-tmp.$$
  if [ -f "$file" ]; then
    pos=$(block_position "$file")
    [ "$pos" = broken ] && return 2
    cp -p "$file" "$tmp" 2>/dev/null
    if [ "$pos" = none ]; then
      if grep -q '[^[:space:]]' "$file"; then
        {
          cat "$file"
          if ends_with_newline "$file"; then printf '\n'; else printf '\n\n'; fi
          cat "$block"
        } >"$tmp"
      else
        cat "$block" >"$tmp"
      fi
    else
      s=${pos% *} e=${pos#* }
      {
        [ "$s" -gt 1 ] && head -n $((s - 1)) "$file"
        cat "$block"
        tail -n +$((e + 1)) "$file"
      } >"$tmp"
    fi
  else
    cat "$block" >"$tmp"
  fi
  move_into_place "$tmp" "$file" || { rm -f "$tmp"; return 1; }
}

# Takes a block out, with one blank line beside it
remove_block() {
  file=$1
  [ -f "$file" ] || return 0
  pos=$(block_position "$file")
  case $pos in
    none) return 0 ;;
    broken) return 2 ;;
  esac
  s=${pos% *} e=${pos#* }
  if [ "$s" -gt 1 ] && sed -n "$((s - 1))p" "$file" | grep -q '^[[:space:]]*$'; then
    s=$((s - 1))
  elif sed -n "$((e + 1))p" "$file" | grep -q '^[[:space:]]*$'; then
    e=$((e + 1))
  fi
  tmp=$(dirname "$file")/.$(basename "$file").ctx-tmp.$$
  cp -p "$file" "$tmp" 2>/dev/null
  {
    [ "$s" -gt 1 ] && head -n $((s - 1)) "$file"
    tail -n +$((e + 1)) "$file"
  } >"$tmp"
  if is_own_file "$2" && ! grep -q '[^[:space:]]' "$tmp"; then
    rm -f "$tmp" "$file"
  else
    move_into_place "$tmp" "$file" || { rm -f "$tmp"; return 1; }
  fi
}

# --- Skill folders --------------------------------------------------------

# A skill folder's files, sorted byte by byte. Folder settings and editor
# backup, lock and swap files are skipped, as the API skips them.
skill_files() {
  (cd "$1" 2>/dev/null && find . -type f ! -path ./.ctx-managed ! -name .DS_Store \
    ! -name Thumbs.db ! -name desktop.ini ! -name 4913 ! -name '*~' ! -name '.#*' \
    ! -name '.?*.sw[a-p]') | sed 's|^\./||' | LC_ALL=C sort
}

# One line per file, "<sha256> <path>", then hashed
tree_hash() {
  skill_files "$1" | while IFS= read -r f; do
    printf '%s %s\n' "$(sha_file "$1/$f")" "$f"
  done | sha_stdin
}

install_skill() {
  src=$1 dest=$2 item=$3 version=$4 hash=$5
  parent=$(dirname "$dest") name=$(basename "$dest")
  mkdir -p "$parent" || return 1
  stage=$TMP/stage.$name old=$TMP/old.$name
  rm -rf "$stage" "$old"
  cp -R "$src" "$stage" || return 1
  printf 'Managed by Context Locker: skill %s, version %s.\nEdits here go to Context Locker at the next sync.\n%s\n' \
    "$item" "$version" "$hash" >"$stage/.ctx-managed"
  if [ -e "$dest" ]; then
    mv "$dest" "$old" || return 1
  fi
  if ! mv "$stage" "$dest"; then
    [ -e "$old" ] && mv "$old" "$dest"
    return 1
  fi
  rm -rf "$old"
  # The marker is the newest thing in the folder, so later edits show as newer
  touch "$dest/.ctx-managed"
  SKILLS_CHANGED=1
}

make_bundle() {
  {
    printf 'context-locker-bundle 1\n'
    skill_files "$1" |
      while IFS= read -r f; do
        printf 'file %s %s\n' "$(wc -c <"$1/$f" | tr -d ' ')" "$f"
        cat "$1/$f"
        printf '\n'
      done
  } >"$2"
}

# --- A project's notes folder ----------------------------------------------

# A project's sync mirrors its notes into .context-locker/notes, and the ones
# that apply everywhere into its everywhere folder, with a README. The
# folder's own list, .ctx-managed, says what Context Locker last wrote there,
# so the sync of every app on this computer can tell an edit from an older
# copy. Before anything is written, edited notes and new .md files go up.
NOTES=.context-locker/notes
NOTES_TARGET='{project}/.context-locker/notes'
# The most a note's file may hold, and how many files go up in one sync
NOTES_MAX=524288
NOTES_PER_SYNC=20
NOTES_OK=0
NOTES_SAVED=0
EXCLUDED=0

# Whether a file name is one a note's file can have, such as release-plan.md:
# lowercase letters and numbers joined by single hyphens. The README's name,
# and those Windows keeps for devices, never are.
note_name_ok() {
  case $1 in *.md) ;; *) return 1 ;; esac
  nn_stem=${1%.md}
  case $nn_stem in
    '' | *[!abcdefghijklmnopqrstuvwxyz0123456789-]* | -* | *- | *--*) return 1 ;;
    readme | con | prn | aux | nul | com[0123456789] | lpt[0123456789]) return 1 ;;
  esac
  [ "${#nn_stem}" -le 64 ]
}

# True when none of the folders on the way to the notes is a link
notes_folder_ok() {
  for nf_part in .context-locker "$NOTES" "$NOTES/everywhere"; do
    [ -L "$PROJECT_ROOT/$nf_part" ] && return 1
  done
  return 0
}

# True when this sync keeps the project's notes folder: the app has one in
# this project, and the manifest brings it, README and all. Otherwise the
# folder is left as it is, as another app on this computer may keep it.
notes_synced() {
  allowed "$NOTES_TARGET/README.md" file || return 1
  awk -v t="$NOTES_TARGET/README.md" '$1 == "file" && $3 == t { found = 1 } END { exit !found }' "$TMP/entries"
}

# What the folder's list says Context Locker last wrote there for this project
notes_records() {
  : >"$TMP/notes-records"
  nr_list=$PROJECT_ROOT/$NOTES/.ctx-managed
  [ -f "$nr_list" ] && [ ! -L "$nr_list" ] || return 0
  [ "$(head -n 1 "$nr_list")" = "context-locker-notes 1 $PROJECT_ID" ] || return 0
  grep -E '^(wrote note [0-9a-f]{64} \{project\}/\.context-locker/notes/[^ ]+ [0-9a-f-]{36} [0-9]+|wrote file [0-9a-f]{64} \{project\}/\.context-locker/notes/README\.md - -|refused [0-9a-f]{64} \{project\}/\.context-locker/notes/[^ ]+)$' \
    "$nr_list" >"$TMP/notes-records"
}

hash_files() {
  case $HASHER in
    sha256sum) xargs sha256sum ;;
    openssl) xargs openssl dgst -sha256 -r ;;
    *) xargs shasum -a 256 ;;
  esac
}

# Each note's file and the README in the folder, as "<sha256> <target>", in
# one pass. A .md file with a name no note's file has is set aside.
notes_scan() {
  : >"$TMP/notes-local"
  : >"$TMP/notes-names"
  : >"$TMP/notes-misnamed"
  for ns_sub in '' everywhere/; do
    [ -d "$PROJECT_ROOT/$NOTES/$ns_sub" ] || continue
    for ns_file in "$PROJECT_ROOT/$NOTES/$ns_sub"*.md; do
      [ -f "$ns_file" ] && [ ! -L "$ns_file" ] || continue
      ns_name=${ns_file##*/}
      if [ -z "$ns_sub" ] && [ "$ns_name" = README.md ]; then
        :
      elif ! note_name_ok "$ns_name"; then
        { printf '%s%s' "$ns_sub" "$ns_name" | clean; printf '\n'; } >>"$TMP/notes-misnamed"
        continue
      fi
      printf '%s%s\n' "$ns_sub" "$ns_name" >>"$TMP/notes-names"
    done
  done
  [ -s "$TMP/notes-names" ] || return 0
  (cd "$PROJECT_ROOT/$NOTES" && hash_files <"$TMP/notes-names") |
    awk -v root="$NOTES_TARGET/" 'NF >= 2 { f = $2; sub(/^\*/, "", f); print $1, root f }' >"$TMP/notes-local"
}

# Puts a whole file in place from a copy, in one step, keeping the old
# file's permissions
write_file() {
  wf_dir=${1%/*}
  mkdir -p "$wf_dir" || return 1
  wf_tmp=$wf_dir/.${1##*/}.ctx-tmp.$$
  [ -f "$1" ] && cp -p "$1" "$wf_tmp" 2>/dev/null
  if cat "$2" >"$wf_tmp" && mv -f "$wf_tmp" "$1"; then
    return 0
  fi
  rm -f "$wf_tmp"
  return 1
}

# Adds .context-locker/ to the repo's own exclude file, once, the first time
# a sync writes in the folder, so git leaves the notes out. It never changes
# .gitignore or any file git tracks, goes through no link, and does nothing
# outside a git work tree.
keep_out_of_git() {
  [ "$EXCLUDED" = 1 ] && return 0
  EXCLUDED=1
  have git || return 0
  kg_file=$(
    unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE
    cd "$PROJECT_ROOT" 2>/dev/null || exit 1
    [ "$(git rev-parse --is-inside-work-tree 2>/dev/null)" = true ] || exit 1
    git rev-parse --git-path info/exclude 2>/dev/null
  ) || return 0
  case $kg_file in
    '' | *'
'*) return 0 ;;
    /*) ;;
    *) kg_file=$PROJECT_ROOT/$kg_file ;;
  esac
  kg_info=${kg_file%/*}
  if [ -L "$kg_file" ] || [ -L "$kg_info" ] || [ -L "${kg_info%/*}" ]; then
    warn "left $kg_file alone: it's a link or in one, and links aren't followed. To keep the notes out of git, add .context-locker/ to it yourself."
    return 0
  fi
  if [ -e "$kg_file" ]; then
    [ -f "$kg_file" ] || return 0
    awk '{ sub(/\r$/, ""); sub(/[ \t]+$/, "") }
      $0 == ".context-locker/" || $0 == "/.context-locker/" || $0 == ".context-locker" || $0 == "/.context-locker" { found = 1 }
      END { exit !found }' "$kg_file" && return 0
    backup "$kg_file" '{project}/.git/info/exclude' || return 0
  else
    [ -d "${kg_info%/*}" ] || return 0
    mkdir -p "$kg_info" 2>/dev/null || return 0
  fi
  kg_tmp=$kg_info/.exclude.ctx-tmp.$$
  [ -f "$kg_file" ] && cp -p "$kg_file" "$kg_tmp" 2>/dev/null
  if {
    if [ -s "$kg_file" ]; then
      cat "$kg_file"
      ends_with_newline "$kg_file" || printf '\n'
    fi
    printf '%s\n' '.context-locker/'
  } >"$kg_tmp" && mv -f "$kg_tmp" "$kg_file"; then
    return 0
  fi
  rm -f "$kg_tmp"
  warn "couldn't add .context-locker/ to $kg_file. To keep the notes out of git, add it yourself."
}

# Writes the file Context Locker sent back for a note it saved, unless the
# file changed again meanwhile, and records it either way. Fails when the
# answer doesn't make sense, and then nothing is written.
note_saved() {
  ns_t=$1 ns_path=$2 ns_sent=$3
  { read -r ns_head && read -r ns_status ns_id ns_ver ns_hash ns_target ns_rest; } <"$TMP/note-reply" || return 1
  [ "$ns_head" = 'context-locker-note 1' ] && [ -z "$ns_rest" ] && [ "$ns_target" = "$ns_t" ] || return 1
  case $ns_status in saved | same) ;; *) return 1 ;; esac
  case $ns_ver in '' | *[!0123456789]*) return 1 ;; esac
  printf '%s\n' "$ns_id" | grep -q "^$UUID\$" || return 1
  printf '%s\n' "$ns_hash" | grep -q "^$HASH\$" || return 1
  tail -n +3 "$TMP/note-reply" >"$TMP/note-file"
  [ "$(sha_file "$TMP/note-file")" = "$ns_hash" ] || return 1
  [ "$ns_status" = saved ] && NOTES_SAVED=1
  ns_now=$(sha_file "$ns_path" 2>/dev/null)
  if [ "$ns_now" = "$ns_sent" ] && [ "$ns_now" != "$ns_hash" ]; then
    # Context Locker's copy of what was sent takes its place, as the canonical file
    keep_out_of_git
    { backup "$ns_path" "$ns_t" && write_file "$ns_path" "$TMP/note-file"; } ||
      warn "saved ${ns_t#\{project\}/}, but couldn't write Context Locker's copy of it. The next sync does."
  fi
  # A file that changed again meanwhile is an edit to this version, which the next sync sends
  printf 'wrote note %s %s %s %s\n' "$ns_hash" "$ns_t" "$ns_id" "$ns_ver" >>"$TMP/notes-records"
}

# An edit made here to a note that changed in Context Locker too, in the same
# part: the edit is kept beside the note, as <name>.md.conflict, which the
# sync never sends, and the note's file goes, so this sync writes the newer
# version in its place. A copy goes in the backups first, so nothing is lost,
# the edit isn't sent again, and the app is told at the start of the session.
# Fails when the edit can't be kept that way, and then nothing changes.
note_conflict() {
  nc_t=$1 nc_path=$2 nc_rel=$3
  nc_copy=$nc_path.conflict
  [ -L "$nc_copy" ] && return 1
  if [ -e "$nc_copy" ]; then
    # An older copy goes in the backups before this one takes its place
    { [ -f "$nc_copy" ] && backup "$nc_copy" "$nc_t.conflict"; } || return 1
  fi
  backup "$nc_path" "$nc_t" || return 1
  cp "$nc_path" "$nc_copy" 2>/dev/null || return 1
  rm -f "$nc_path" || return 1
  NOTES_RESCAN=1
  printf 'Context Locker: your edit to %s and a change made in Context Locker since touch the same part, so the note has the newer version now, and your edit is kept beside it in %s. Put the two together in the note, and the next sync saves it.\n' \
    "$nc_rel" "$nc_rel.conflict" >>"$TMP/said"
  warn "$nc_rel changed in Context Locker too, in the same part as your edit, so the note has the newer version now. Your edit is kept in $nc_rel.conflict."
  return 0
}

# Sends the notes edited here, and new .md files, to Context Locker, at most
# 20 a sync. What it saves is written as Context Locker keeps it; a file it
# can't take stays as it is, and goes again at the next sync. An edit that
# clashes with a newer version is kept beside the note instead.
notes_up() {
  nu_query=$1
  while IFS= read -r nu_name; do
    warn "left $NOTES/$nu_name as it is: a note's file is named with lowercase letters, numbers and hyphens, such as release-plan.md. Rename it, and the next sync saves it."
  done <"$TMP/notes-misnamed"
  # A file goes up when it's a note's file that changed since Context Locker
  # last wrote it, unless it's already as Context Locker has it now, or when
  # it's new here: in neither the list nor the manifest
  awk -v readme="$NOTES_TARGET/README.md" '
    FILENAME == ARGV[1] && ($1 == "note" || $1 == "file") { S[$3] = $2; next }
    FILENAME == ARGV[2] && $1 == "entry" && $2 == "skill" { ri[$4] = $5; rv[$4] = $6; next }
    FILENAME == ARGV[2] && $1 == "wrote" { R[$4] = $3; rk[$4] = $2; ri[$4] = $5; rv[$4] = $6; next }
    FILENAME == ARGV[3] { L[$2] = $1; next }
    END {
      for (t in L) {
        if (t == readme) continue
        if (t in R) {
          if (rk[t] == "note" && L[t] != R[t] && !((t in S) && S[t] == L[t])) print t, "edit", ri[t], rv[t], L[t]
        } else if (!(t in S)) print t, "new", "-", "-", L[t]
      }
    }' "$TMP/entries" "$TMP/notes-records" "$TMP/notes-local" | LC_ALL=C sort >"$TMP/notes-up"
  [ -s "$TMP/notes-up" ] || return 0
  nu_sent=0 nu_waiting=0 nu_stopped=0
  while read -r nu_t nu_what nu_id nu_ver nu_hash <&4; do
    nu_rel=${nu_t#\{project\}/}
    nu_path=$PROJECT_ROOT/$nu_rel
    if [ "$nu_stopped" = 1 ] || [ "$nu_sent" -ge "$NOTES_PER_SYNC" ]; then
      nu_waiting=$((nu_waiting + 1))
      continue
    fi
    nu_size=$(wc -c <"$nu_path" 2>/dev/null | tr -d ' ')
    case $nu_size in '' | *[!0123456789]*) continue ;; esac
    if [ "$nu_size" -gt "$NOTES_MAX" ]; then
      warn "couldn't save $nu_rel: it's $(((nu_size + 1023) / 1024)) KB, and a note can hold at most $((NOTES_MAX / 1024)) KB."
      printf 'refused %s %s\n' "$nu_hash" "$nu_t" >>"$TMP/notes-refused"
      continue
    fi
    nu_sent=$((nu_sent + 1))
    nu_base=
    [ "$nu_what" = edit ] && nu_base="$nu_id $nu_ver"
    rm -f "$TMP/note-reply"
    nu_code=$(status_of "$(http POST "/v1/sync/notes$nu_query" "$TMP/note-reply" "$nu_path" 'text/markdown; charset=utf-8' '' "$nu_t" "$nu_base")")
    case $nu_code in
      200)
        note_saved "$nu_t" "$nu_path" "$nu_hash" ||
          warn "couldn't make sense of Context Locker's answer for $nu_rel. The next sync tries again."
        ;;
      409 | 400 | 404 | 413 | 422)
        if [ "$nu_code" = 409 ] && [ "$(reply_field error "$TMP/note-reply")" = version_conflict ] &&
          note_conflict "$nu_t" "$nu_path" "$nu_rel"; then
          continue
        fi
        if [ "$nu_code" = 409 ] && [ "$(reply_field error "$TMP/note-reply")" = version_conflict ]; then
          warn "$nu_rel changed in Context Locker too, so your edit wasn't saved. Copy your edit, delete the file to get the latest at the next sync, then make the edit again."
        else
          nu_message=$(reply_field message "$TMP/note-reply" | clean)
          warn "couldn't save $nu_rel: ${nu_message:-Context Locker refused it.}"
        fi
        printf 'refused %s %s\n' "$nu_hash" "$nu_t" >>"$TMP/notes-refused"
        ;;
      403)
        warn "this computer's connection for $HARNESS can only read, so the changes in $NOTES stay here."
        nu_stopped=1
        ;;
      000)
        warn "can't reach Context Locker, so the changes in $NOTES wait for the next sync."
        nu_stopped=1
        ;;
      *)
        warn "Context Locker answered $nu_code, so the changes in $NOTES wait for the next sync."
        nu_stopped=1
        ;;
    esac
  done 4<"$TMP/notes-up"
  if [ "$nu_waiting" -gt 0 ] && [ "$nu_stopped" = 0 ]; then
    if [ "$nu_waiting" = 1 ]; then
      warn "1 more file in $NOTES waits for the next sync, which saves up to $NOTES_PER_SYNC."
    else
      warn "$nu_waiting more files in $NOTES wait for the next sync, which saves up to $NOTES_PER_SYNC."
    fi
  fi
}

# Writes the folder's list of what Context Locker last wrote there, from
# records where the last one for each file counts and "forget" drops one,
# with what Context Locker couldn't take at this sync
notes_write_list() {
  [ "$NOTES_OK" = 1 ] || return 0
  awk '$1 == "forget" { gone[$2] = 1; next }
    $1 == "wrote" { if (!($4 in seen)) { seen[$4] = 1; order[++n] = $4 } last[$4] = $0; gone[$4] = 0 }
    END { for (i = 1; i <= n; i++) if (!gone[order[i]]) print last[order[i]] }' "$1" >"$TMP/notes-final"
  nw_list=$PROJECT_ROOT/$NOTES/.ctx-managed
  {
    printf 'context-locker-notes 1 %s\n' "$PROJECT_ID"
    printf '%s\n' "# What Context Locker last wrote in this folder, so the sync of each app on this computer can tell an edit from an update. Leave it as it is."
    cat "$TMP/notes-final" "$TMP/notes-refused"
  } >"$TMP/notes-list"
  # Nothing has been written here, and nothing waits
  [ -s "$TMP/notes-final" ] || [ -s "$TMP/notes-refused" ] || [ -f "$nw_list" ] || return 0
  [ -f "$nw_list" ] && [ "$(sha_file "$nw_list")" = "$(sha_file "$TMP/notes-list")" ] && return 0
  if [ -L "$nw_list" ] || { [ -e "$nw_list" ] && [ ! -f "$nw_list" ]; }; then
    warn "left $nw_list alone: it isn't a file of Context Locker's."
    return 1
  fi
  keep_out_of_git
  write_file "$nw_list" "$TMP/notes-list" && return 0
  warn "couldn't write $nw_list, the list of what Context Locker wrote in the notes folder."
  return 1
}

# --- A project's pointers to paths in its repo ------------------------------

# Whether a path in the repo is there, under the folder $1 (with no link in
# its own path), going through no link that leads out of it
path_here() {
  ph_root=$1 ph_rest=$2 ph_cur=$1 ph_hops=0
  while [ -n "$ph_rest" ]; do
    ph_part=${ph_rest%%/*}
    case $ph_rest in */*) ph_rest=${ph_rest#*/} ;; *) ph_rest= ;; esac
    case $ph_part in
      '' | .) continue ;;
      ..) return 1 ;;
    esac
    ph_next=$ph_cur/$ph_part
    # A link is followed only while it stays in the folder
    while [ -L "$ph_next" ]; do
      ph_hops=$((ph_hops + 1))
      [ "$ph_hops" -le 16 ] && have readlink || return 1
      ph_to=$(readlink "$ph_next") || return 1
      case $ph_to in /*) ;; *) ph_to=${ph_next%/*}/$ph_to ;; esac
      if [ -d "$ph_to" ]; then
        ph_next=$(cd -P "$ph_to" 2>/dev/null && pwd -P) || return 1
      else
        ph_dir=$(cd -P "${ph_to%/*}/" 2>/dev/null && pwd -P) || return 1
        ph_next=${ph_dir%/}/${ph_to##*/}
      fi
      case $ph_next/ in "$ph_root"/*) ;; *) return 1 ;; esac
    done
    [ -e "$ph_next" ] || return 1
    ph_cur=$ph_next
  done
  return 0
}

# Checks the project's pointers to paths in its repo, from the manifest's
# link lines, and says in one line which ones aren't in the folder
check_links() {
  LINKS_CHECKED=0
  : >"$TMP/missing"
  : >"$TMP/missing-paths"
  cl_root=$(cd -P "$PROJECT_ROOT" 2>/dev/null && pwd -P) || return 0
  while IFS= read -r cl_line; do
    case $cl_line in 'link '*) ;; *) continue ;; esac
    cl_rest=${cl_line#link }
    cl_id=${cl_rest%% *}
    cl_path=${cl_rest#* }
    printf '%s\n' "$cl_id" | grep -q "^$UUID\$" || continue
    [ "$cl_path" != "$cl_rest" ] && [ -n "$cl_path" ] || continue
    LINKS_CHECKED=$((LINKS_CHECKED + 1))
    path_here "$cl_root" "$cl_path" && continue
    printf 'missing %s\n' "$cl_id" >>"$TMP/missing"
    { printf '%s' "$cl_path" | clean; printf '\n'; } >>"$TMP/missing-paths"
  done <"$TMP/entries"
  [ -s "$TMP/missing-paths" ] || return 0
  cl_count=$(wc -l <"$TMP/missing-paths" | tr -d ' ')
  cl_names=$(head -n 5 "$TMP/missing-paths" | awk '{ printf "%s%s", (NR > 1 ? ", " : ""), $0 }')
  [ "$cl_count" -gt 5 ] && cl_names="$cl_names and $((cl_count - 5)) more"
  if [ "$cl_count" = 1 ]; then
    warn "1 of this project's pointers points to a path that isn't in $PROJECT_ROOT: $cl_names. If it moved, change the pointer's address in Context Locker."
  else
    warn "$cl_count of this project's pointers point to paths that aren't in $PROJECT_ROOT: $cl_names. If they moved, change their addresses in Context Locker."
  fi
}

# --- The API --------------------------------------------------------------

# Prints the HTTP status, or 000 when Context Locker can't be reached. The
# token goes to curl on stdin, never on the command line. A request may take
# a minute, or HTTP_MAX_TIME seconds, as an export can take longer.
HTTP_MAX_TIME=60
http() {
  method=$1 path=$2 out=$3 body=${4:-} type=${5:-} etag=${6:-} target=${7:-} base=${8:-} accept=${9:-} upload=${10:-}
  set -- -K - -sS --connect-timeout 5 --max-time "$HTTP_MAX_TIME" -o "$out" -w '%{http_code}' \
    -A "context-locker-sync/$SCRIPT_VERSION ($HARNESS; sh)" -X "$method"
  [ -n "$etag" ] && set -- "$@" -H "If-None-Match: \"$etag\""
  [ -n "$type" ] && set -- "$@" -H "Content-Type: $type"
  [ -n "$target" ] && set -- "$@" -H "Context-Locker-Target: $target"
  [ -n "$base" ] && set -- "$@" -H "Context-Locker-Base: $base"
  [ -n "$accept" ] && set -- "$@" -H "Accept: $accept"
  [ -n "$upload" ] && set -- "$@" -H "Context-Locker-Upload: $upload"
  [ -n "$body" ] && set -- "$@" --data-binary "@$body"
  { [ -z "$TOKEN" ] || printf 'header = "Authorization: Bearer %s"\n' "$TOKEN"; } |
    curl "$@" "$API$path" 2>>"$TMP/curl-errors" || printf '000'
}

status_of() {
  code=$1
  case $code in
    *000) printf '000' ;;
    *) printf '%s' "$code" ;;
  esac
}

# One request to Context Locker holds at most 4.5 MB, so a body bigger than a
# part goes up in parts, as an upload: a plan, or a skill's edit
PART_BYTES=4194304

# Sends a file in parts of up to 4 MB, as an upload for $1, gather or
# sync-edit, and prints the upload's id, which the request that would have
# carried the file names instead. When Context Locker refuses a step or
# can't be reached, it fails, with the step's HTTP status in
# $TMP/upload-status and Context Locker's answer in $TMP/upload-reply.
upload_parts() {
  up_purpose=$1 up_file=$2
  up_bytes=$(wc -c <"$up_file" | tr -d ' ')
  up_parts=$(((up_bytes + PART_BYTES - 1) / PART_BYTES))
  : >"$TMP/upload-reply"
  printf '{"purpose":"%s","parts":%s,"bytes":%s,"sha256":"%s"}' \
    "$up_purpose" "$up_parts" "$up_bytes" "$(sha_file "$up_file")" >"$TMP/upload-start"
  up_code=$(status_of "$(http POST /v1/uploads "$TMP/upload-reply" "$TMP/upload-start" application/json '' '' '' text/plain)")
  printf '%s' "$up_code" >"$TMP/upload-status"
  [ "$up_code" = 201 ] || return 1
  up_id=$(tr -d ' \r\n' <"$TMP/upload-reply")
  case $up_id in '' | *[!0-9a-f-]*) return 1 ;; esac
  up_part=1
  while [ "$up_part" -le "$up_parts" ]; do
    dd if="$up_file" of="$TMP/upload-part" bs=$PART_BYTES skip=$((up_part - 1)) count=1 2>/dev/null || return 1
    up_code=$(status_of "$(http PUT "/v1/uploads/$up_id/parts/$up_part" "$TMP/upload-reply" "$TMP/upload-part" application/octet-stream)")
    printf '%s' "$up_code" >"$TMP/upload-status"
    [ "$up_code" = 204 ] || return 1
    up_part=$((up_part + 1))
  done
  printf '%s' "$up_id"
}

reply_field() {
  sed -nE 's/.*"'"$1"'":"(([^"\\]|\\.)*)".*/\1/p' "$2" | head -n 1 | sed 's/\\"/"/g; s/\\\\/\\/g'
}

# Sends an edit found in a synced file. Prints what the API said to do.
send_edit() {
  t=$1 kind=$2 file=$3 recorded=$4 query=$5
  [ "$recorded" = - ] && recorded=
  if [ "$kind" = block ]; then
    pos=$(block_position "$file")
    block_lines "$file" "${pos% *}" "${pos#* }" >"$TMP/edit"
    type=text/plain
  else
    make_bundle "$file" "$TMP/edit"
    type=application/octet-stream
  fi
  # A skill too big for one request goes up in parts first. When Context
  # Locker refuses a part, that's its answer to the edit; when it can't take
  # one just now, the edit waits for the next sync
  upload=
  if [ "$(wc -c <"$TMP/edit" | tr -d ' ')" -gt "$PART_BYTES" ]; then
    if ! upload=$(upload_parts sync-edit "$TMP/edit"); then
      cp "$TMP/upload-reply" "$TMP/edit-reply" 2>/dev/null
      case $(cat "$TMP/upload-status" 2>/dev/null) in
        000) printf 'offline' ;;
        400 | 401 | 403 | 413) printf 'refused' ;;
        *) printf 'error' ;;
      esac
      return 0
    fi
    : >"$TMP/edit"
  fi
  code=$(status_of "$(http POST "/v1/sync/edits$query" "$TMP/edit-reply" "$TMP/edit" "$type" '' "$t" "$recorded" '' "$upload")")
  case $code in
    200) reply_field status "$TMP/edit-reply" ;;
    000) printf 'offline' ;;
    4??) printf 'refused' ;;
    *) printf 'error' ;;
  esac
}

# --- One sync: global, or one project ---------------------------------------

# Whether a manifest changes any of the app's files: the files it lists,
# against those the last sync wrote. Prints the hash of its list when it
# does, and fails when it doesn't.
files_change() {
  grep -E '^(block|skill|file|note) ' "$1" | LC_ALL=C sort >"$TMP/fc-new"
  sed -n 's/^entry //p' "$2" 2>/dev/null | grep -E '^(block|skill|file|note) ' | LC_ALL=C sort >"$TMP/fc-old"
  fc_new=$(sha_file "$TMP/fc-new")
  [ "$fc_new" != "$(sha_file "$TMP/fc-old")" ] || return 1
  printf '%s' "$fc_new"
}

# Each change is said once: fails when the one with this hash was said
# before, and otherwise remembers it in the scope's .told file, unless the
# app doesn't read what the sync prints
not_told() {
  [ "$1" != "$(cat "$2.told" 2>/dev/null)" ] || return 1
  [ "$QUIET" = 1 ] || printf '%s\n' "$1" >"$2.told" 2>/dev/null
  return 0
}

# With auto sync off, whether a sync left changes to the app's files for
# later, to say once
CHANGES_WAITING=0

# With auto sync off, the global sync's text for the session start comes in
# all the same, as it's about the playbook, such as changes waiting for
# approval, not part of it
context_only() {
  co_state=$1
  co_hash=$(sed -n "s/^context \\($HASH\\)\$/\\1/p" "$TMP/entries" | head -n 1)
  if [ -z "$co_hash" ]; then
    rm -f "$co_state.context"
    return 0
  fi
  [ -f "$co_state.context" ] && [ "$(sha_file "$co_state.context")" = "$co_hash" ] && return 0
  printf '%s\n' "$co_hash" >"$TMP/co-want"
  rm -rf "$TMP/co-blobs"
  mkdir "$TMP/co-blobs"
  co_code=$(status_of "$(http POST /v1/sync/blobs "$TMP/co.tar" "$TMP/co-want" text/plain '' '' '')")
  if [ "$co_code" = 200 ] && tar -xmof "$TMP/co.tar" -C "$TMP/co-blobs" 2>/dev/null &&
    [ -f "$TMP/co-blobs/$co_hash" ] && [ ! -L "$TMP/co-blobs/$co_hash" ] &&
    [ "$(sha_file "$TMP/co-blobs/$co_hash")" = "$co_hash" ]; then
    cp "$TMP/co-blobs/$co_hash" "$co_state.context"
  fi
  return 0
}

# Counts a change to the app's files, for the line that says what a sync
# brought in: one made in the playbook since the last sync here, not a file
# put back as it was, or what a scope's first sync here writes
count_change() {
  grep -qxF "$2" "$TMP/playbook-changed" || return 0
  case $1 in
    block) W_BLOCKS=$((W_BLOCKS + 1)) ;;
    skill) W_SKILLS=$((W_SKILLS + 1)) ;;
    note) W_NOTES=$((W_NOTES + 1)) ;;
  esac
}

# In a plan, what each step would do, in plain words
planned() { [ "$MODE" = plan ] && printf '%s\n' "$*" >>"$TMP/plan-out"; return 0; }

# A removal is separate from a missing manifest entry: it remains waiting
# until every known managed copy is gone. Original skills are never removed.
marker_item() { sed -n "1s/^Managed by Context Locker: skill \($UUID\), version [0-9][0-9]*\.$/\1/p" "$1"; }
marker_version() { sed -n "1s/^Managed by Context Locker: skill $UUID, version \([0-9][0-9]*\)\.$/\1/p" "$1"; }

cleanup_roots() {
  case $HARNESS in
    claude-code) printf '%s\n' "$(root_dir claude)/skills" ;;
    codex | openclaw) printf '%s\n' "$(root_dir agents)/skills" ;;
    hermes) printf '%s\n' "$(root_dir hermes)/skills" ;;
  esac
  case $HARNESS in
    claude-code) cr_suffix=.claude/skills ;;
    codex) cr_suffix=.agents/skills ;;
    *) return ;;
  esac
  [ -z "$PROJECT_ROOT" ] || printf '%s\n' "$PROJECT_ROOT/$cr_suffix"
  if [ -f "$CL_HOME/projects" ]; then
    while read -r cr_id cr_folder; do
      [ -f "$APP_DIR/projects/$cr_id.lock" ] || continue
      if [ ! -d "$cr_folder" ]; then
        printf '%s\n' '?' # An offline folder is not proof of cleanup.
      else
        printf '%s\n' "$cr_folder/$cr_suffix"
      fi
    done <"$CL_HOME/projects"
  fi
}

cleanup_safe_path() {
  cs_path=$1 cs_stop=$(dirname "${2%/skills}")
  while [ "$cs_path" != "$cs_stop" ] && [ "$cs_path" != / ] && [ -n "$cs_path" ]; do
    [ ! -L "$cs_path" ] || return 1
    cs_path=${cs_path%/*}
  done
}

load_removals() {
  [ -f "$TMP/removals" ] && return
  if [ "$(status_of "$(http GET /v1/sync/removals "$TMP/removals-raw")")" = 200 ]; then
    awk '$1 == "remove" && $2 ~ /^[0-9a-f-]+$/ && length($2) == 36 && $3 ~ /^[0-9a-f-]+$/ && length($3) == 36 && $4 ~ /^[0-9]+$/ && length($4) < 10 && $5 == "project" && $6 == $3 && NF == 6' "$TMP/removals-raw" >"$TMP/project-removals"
    # Each field is validated before it reaches a path or a comparison.
    awk '$1 == "remove" && $2 ~ /^[0-9a-f-]+$/ && length($2) == 36 && $3 ~ /^[0-9a-f-]+$/ && length($3) == 36 && $4 ~ /^[0-9]+$/ && length($4) < 10 && $5 == "skill" && $6 ~ /^[a-z0-9]+(-[a-z0-9]+)*$/ && NF == 6' "$TMP/removals-raw" >"$TMP/removals"
  else
    : >"$TMP/removals"
  fi
}

cleanup_scope() {
  [ "$MODE" = sync ] || return 0
  load_removals
  [ -s "$TMP/removals" ] || return 0
  if [ "$NOW" = 0 ] && grep -qx 'auto-sync off' "$TMP/entries"; then
    REMOVALS_PAUSED=1
    return 0
  fi
  case "$SCOPE $HARNESS" in
    'global claude-code') cl_root=$(root_dir claude)/skills ;;
    'global codex' | 'global openclaw') cl_root=$(root_dir agents)/skills ;;
    'global hermes') cl_root=$(root_dir hermes)/skills ;;
    'project claude-code') [ "$LAYER" = repo ] || return 0; cl_root=$PROJECT_ROOT/.claude/skills ;;
    'project codex') [ "$LAYER" = repo ] || return 0; cl_root=$PROJECT_ROOT/.agents/skills ;;
    *) return 0 ;;
  esac
  printf '%s\n' "$cl_root" >>"$TMP/cleanup-roots"
  while read -r cl_type cl_request cl_item cl_version cl_kind cl_name; do
    for cl_path in "$cl_root"/*; do
      [ -d "$cl_path" ] || continue
      cleanup_safe_path "$cl_path/.ctx-managed" "$cl_root" || continue
      [ -f "$cl_path/.ctx-managed" ] || continue
      [ "$(marker_item "$cl_path/.ctx-managed")" = "$cl_item" ] || continue
      cl_local=$(marker_version "$cl_path/.ctx-managed")
      case $cl_local in '' | *[!0-9]*) continue ;; esac
      [ "${#cl_local}" -lt 10 ] && [ "$cl_local" -le "$cl_version" ] || continue
      # The backup is outside all active skill paths. Keep edited files too.
      if backup "$cl_path" "removed-$cl_request-$(printf '%s' "$cl_path" | sha_stdin)" && rm -rf "$cl_path" && [ ! -e "$cl_path" ]; then
        SKILLS_CHANGED=1
        W_SKILLS=$((W_SKILLS + 1))
      else
        printf 'skipped\nCould not safely back up and remove a managed copy.\n' >"$TMP/cleanup-reply"
        http POST "/v1/sync/removals/$cl_request" "$TMP/cleanup-answer" "$TMP/cleanup-reply" text/plain >/dev/null
        warn "couldn't remove a managed copy of $cl_name; cleanup stays waiting."
      fi
    done
  done <"$TMP/removals"
}

ack_removals() {
  [ -s "$TMP/removals" ] && [ "${REMOVALS_PAUSED:-0}" = 0 ] || return 0
  { cleanup_roots; cat "$TMP/cleanup-roots" 2>/dev/null; } | sort -u >"$TMP/cleanup-all-roots"
  while read -r ca_type ca_request ca_item ca_version ca_kind ca_name; do
    ca_wait=0
    while IFS= read -r ca_root; do
      if [ "$ca_root" = '?' ] || ! cleanup_safe_path "$ca_root" "$ca_root"; then ca_wait=1; break; fi
      for ca_path in "$ca_root"/*; do
        [ -e "$ca_path/.ctx-managed" ] || continue
        if ! cleanup_safe_path "$ca_path/.ctx-managed" "$ca_root"; then ca_wait=1; break; fi
        ca_id=$(marker_item "$ca_path/.ctx-managed")
        if [ -z "$ca_id" ]; then ca_wait=1; break; fi
        [ "$ca_id" = "$ca_item" ] || continue
        ca_local=$(marker_version "$ca_path/.ctx-managed")
        case $ca_local in '' | *[!0-9]*) ca_wait=1; break ;; esac
        if [ "${#ca_local}" -ge 10 ] || [ "$ca_local" -le "$ca_version" ]; then ca_wait=1; break; fi
      done
    done <"$TMP/cleanup-all-roots"
    if [ "$ca_wait" = 0 ]; then
      printf 'done\nRemoved all known managed copies through the removed version.\n' >"$TMP/cleanup-reply"
      http POST "/v1/sync/removals/$ca_request" "$TMP/cleanup-answer" "$TMP/cleanup-reply" text/plain >/dev/null
    fi
  done <"$TMP/removals"
}

# A removed playbook is a command to remove only tracked project copies,
# including local edits after backing them up. Unknown files stay untouched.
cleanup_project() {
  cp_request=$1 cp_version=$2 cp_state=$3 cp_failed=0
  [ "$MODE" = sync ] || { planned "Remove this playbook's managed files after keeping backups."; return 0; }
  [ -n "$PROJECT_ROOT" ] && [ -d "$PROJECT_ROOT" ] || return 1
  inside_project '{project}/.context-locker/project-generation' || return 1
  cp_generation=$PROJECT_ROOT/.context-locker/project-generation
  cp_local=$(cat "$cp_generation" 2>/dev/null)
  case $cp_local in '' | *[!0-9]*) ;; *) [ "${#cp_local}" -lt 10 ] && [ "$cp_local" -gt "$cp_version" ] && return 1 ;; esac
  # Keep records for other clones. The same relative targets can exist in each.
  notes_records
  { sed -n '/^wrote /p' "$cp_state.lock"; cat "$TMP/notes-records"; } >"$TMP/project-copy-records"
  while read -r cp_tag cp_kind cp_hash cp_target cp_item cp_item_version <&7; do
    [ "$cp_tag" = wrote ] || continue
    case $cp_target in '{project}/'*) ;; *) continue ;; esac
    allowed "$cp_target" "$cp_kind" || { cp_failed=1; continue; }
    inside_project "$cp_target" || { cp_failed=1; continue; }
    cp_path=$(resolve "$cp_target") || { cp_failed=1; continue; }
    [ -e "$cp_path" ] || continue
    case $cp_kind in
      skill)
        [ -d "$cp_path" ] && [ -f "$cp_path/.ctx-managed" ] && [ ! -L "$cp_path/.ctx-managed" ] || { cp_failed=1; continue; }
        cp_marker=$(marker_item "$cp_path/.ctx-managed")
        cp_expected=$(awk -v t="$cp_target" '$1=="entry" && $2=="skill" && $4==t {print $5; exit}' "$cp_state.lock")
        [ -n "$cp_expected" ] && [ "$cp_marker" = "$cp_expected" ] || { cp_failed=1; continue; }
        ;;
      block | note | file) [ -f "$cp_path" ] || { cp_failed=1; continue; } ;;
      *) cp_failed=1; continue ;;
    esac
    backup "$cp_path" "removed-project-$cp_request-$cp_target" || { cp_failed=1; continue; }
    case $cp_kind in
      block) remove_block "$cp_path" "$cp_target" || cp_failed=1 ;;
      skill) rm -rf "$cp_path" || cp_failed=1; SKILLS_CHANGED=1 ;;
      note | file) rm -f "$cp_path" || cp_failed=1 ;;
    esac
  done 7<"$TMP/project-copy-records"
  rm -f "$cp_state.context"
  if [ "$cp_failed" = 0 ]; then
    cp_root_hash=$(printf '%s' "$PROJECT_ROOT" | sha_stdin)
    printf '%s %s\n' "$cp_request" "$cp_root_hash" >>"$cp_state.cleaned"
    printf 'Context Locker: removed this playbook\047s managed copies. Original files and backups stay.\n' >>"$TMP/said"
    return 0
  fi
  warn "some managed copies couldn't be removed safely; cleanup stays waiting."
  return 1
}

ack_project_removals() {
  [ "$MODE" = sync ] && [ "${REMOVALS_PAUSED:-0}" = 0 ] && [ -s "$TMP/project-removals" ] || return 0
  while read -r pa_type pa_request pa_project pa_version pa_kind pa_name; do
    pa_wait=0
    # Session text must not continue to supply a removed playbook offline.
    rm -f "$APP_DIR/projects/$pa_project.context"
    { [ "$PROJECT_ID" != "$pa_project" ] || printf '%s\n' "$PROJECT_ROOT";
      [ ! -f "$CL_HOME/projects" ] || awk -v id="$pa_project" '$1==id {sub(/^[^ ]+ /,"");print}' "$CL_HOME/projects";
    } | sort -u >"$TMP/project-cleanup-roots"
    if [ ! -s "$TMP/project-cleanup-roots" ] && grep -q '^wrote ' "$APP_DIR/projects/$pa_project.lock" 2>/dev/null; then pa_wait=1; fi
    while IFS= read -r pa_root; do
      [ -n "$pa_root" ] || continue
      pa_hash=$(printf '%s' "$pa_root" | sha_stdin)
      if [ ! -d "$pa_root" ] || ! grep -qxF "$pa_request $pa_hash" "$APP_DIR/projects/$pa_project.cleaned" 2>/dev/null; then pa_wait=1; break; fi
    done <"$TMP/project-cleanup-roots"
    if [ "$pa_wait" = 0 ]; then
      printf 'done\nRemoved this playbook from every known project folder.\n' >"$TMP/cleanup-reply"
      http POST "/v1/sync/removals/$pa_request" "$TMP/cleanup-answer" "$TMP/cleanup-reply" text/plain >/dev/null
    fi
  done <"$TMP/project-removals"
}

sync_scope() {
  query=$1 state=$2
  lockfile=$state.lock
  WRITTEN=0 HELD=0
  if [ ! -f "$lockfile" ]; then
    # A plan writes nothing, not even an empty lockfile
    [ "$MODE" = plan ] && lockfile=$TMP/new.lock
    : >"$lockfile"
  fi
  old_etag=$(sed -n "s/^etag \\($HASH\\)\$/\\1/p" "$lockfile" | head -n 1)
  # A plan always looks at the whole manifest
  [ "$MODE" = plan ] && old_etag=
  # What the last check of the project's pointers found
  grep -E '^(links|missing) ' "$lockfile" >"$TMP/links-before" 2>/dev/null

  code=$(status_of "$(http GET "/v1/sync$query" "$TMP/manifest" '' '' "$old_etag" '' '')")
  fresh=0
  case $code in
    200)
      header=$(head -n 1 "$TMP/manifest")
      if [ "$header" != 'context-locker-sync 1' ]; then
        warn "this sync script is out of date. Set it up again at context.locker/setup."
        FAILED=1
        return 1
      fi
      tail -n +2 "$TMP/manifest" >"$TMP/entries"
      etag=$(sha_file "$TMP/manifest")
      fresh=1
      ;;
    304)
      sed -n 's/^entry //p' "$lockfile" >"$TMP/entries"
      etag=$old_etag
      ;;
    000)
      warn "can't reach Context Locker, so $HARNESS keeps the files from the last sync."
      FAILED=1
      return 1
      ;;
    401)
      warn "this computer's connection for $HARNESS was revoked or has expired. Set it up again at context.locker/setup."
      FAILED=1
      return 1
      ;;
    404)
      warn "that project isn't in your playbook any more, so it was unlinked here."
      return 3
      ;;
    *)
      warn "Context Locker answered $code, so nothing changed. The next sync tries again."
      FAILED=1
      return 1
      ;;
  esac

  [ -z "$query" ] && WORKSPACE_ID=$(sed -n "s/^workspace \\($UUID\\)\$/\\1/p" "$TMP/entries" | head -n 1)

  [ "$MODE" != sync ] || load_removals
  if [ "$MODE" = sync ] && [ "$NOW" = 0 ] && grep -qx 'auto-sync off' "$TMP/entries" && { [ -s "$TMP/removals" ] || [ -s "$TMP/project-removals" ]; }; then
    REMOVALS_PAUSED=1 CHANGES_WAITING=1
    return 0
  fi

  # With auto sync off, a sync that would change the app's files says so,
  # once, and leaves them as they are until the app syncs with --now, a
  # daily job's run too. The first sync here writes them all the same, as
  # there's nothing yet to leave as it is, and one that changes no file goes
  # ahead.
  if [ "$MODE" = sync ] && [ "$fresh" = 1 ] && [ -n "$old_etag" ] && [ "$NOW" = 0 ] &&
    grep -qx 'auto-sync off' "$TMP/entries" && fc_waiting=$(files_change "$TMP/entries" "$lockfile"); then
    REMOVALS_PAUSED=1
    not_told "$fc_waiting" "$state" && CHANGES_WAITING=1
    [ -n "$query" ] || context_only "$state"
    return 0
  fi

  if [ "$SCOPE" = project ]; then
    pr_removed=$(sed -n "s/^removed-project \\($UUID\\) \\([0-9][0-9]*\\)$/\\1 \\2/p" "$TMP/entries" | head -n 1)
    if [ -n "$pr_removed" ]; then
      # Nothing is uploaded or synced back into a removed playbook.
      cleanup_project "${pr_removed% *}" "${pr_removed#* }" "$state"
      return $?
    fi
    pr_generation=$(sed -n 's/^project-generation \([0-9]\{1,9\}\)$/\1/p' "$TMP/entries" | head -n 1)
    if [ "$MODE" = sync ] && [ -n "$pr_generation" ]; then
      link_folder "$PROJECT_ID" "$PROJECT_ROOT"
      inside_project '{project}/.context-locker/project-generation' || return 1
      mkdir -p "$PROJECT_ROOT/.context-locker" || return 1
      pr_current=$(cat "$PROJECT_ROOT/.context-locker/project-generation" 2>/dev/null)
      if is_number "$pr_current" && [ "$pr_current" -gt "$pr_generation" ]; then return 1; fi
      printf '%s\n' "$pr_generation" >"$PROJECT_ROOT/.context-locker/project-generation"
    fi
  fi

  cleanup_scope

  # A project's notes folder, when this sync keeps it: what's in it and what
  # Context Locker last wrote there. Edited notes and new files go up before
  # anything is written. A folder this sync doesn't keep is left as it is.
  : >"$TMP/notes-records"
  : >"$TMP/notes-local"
  : >"$TMP/notes-wrote"
  : >"$TMP/notes-refused"
  NOTES_OK=0 NOTES_SAVED=0 NOTES_RESCAN=0
  if [ "$SCOPE" = project ] && [ "$MODE" = sync ] && notes_synced; then
    if notes_folder_ok; then
      NOTES_OK=1
      notes_records
      notes_scan
      notes_up "$query"
      if [ "$NOTES_SAVED" = 1 ]; then
        # The playbook changed, so the manifest did too
        code=$(status_of "$(http GET "/v1/sync$query" "$TMP/manifest" '' '' '' '' '')")
        if [ "$code" = 200 ] && [ "$(head -n 1 "$TMP/manifest")" = 'context-locker-sync 1' ]; then
          tail -n +2 "$TMP/manifest" >"$TMP/entries"
        else
          : >"$TMP/entries"
        fi
        if ! notes_synced; then
          warn "couldn't fetch the latest files after saving the notes, so the next sync finishes the job."
          FAILED=1
          notes_write_list "$TMP/notes-records"
          return 1
        fi
        etag=$(sha_file "$TMP/manifest")
        fresh=1
        notes_scan
      elif [ "$NOTES_RESCAN" = 1 ]; then
        # An edit kept beside its note took the note's file away
        notes_scan
      fi
    else
      warn "left $PROJECT_ROOT/.context-locker alone: part of its path is a link, and links in a project aren't followed."
    fi
  fi

  # Whether the project's pointers to paths in its repo are there
  LINKS_CHECKED=
  : >"$TMP/missing"
  [ "$SCOPE" = project ] && [ "$MODE" = sync ] && check_links

  # One line per target: what the manifest says, what this script last wrote,
  # edits waiting for approval, edits the API refused, and for the notes
  # folder, the note and version last written and the file's hash now
  awk '
    function here(t, k) { return (k == "note" || k == "file") ? (t in L ? L[t] : "none") : "?" }
    FILENAME == ARGV[1] && ($1 == "block" || $1 == "skill" || $1 == "file" || $1 == "note") {
      kind[$3] = $1; S[$3] = $2; order[++n] = $3
      item[$3] = ($1 == "skill" || $1 == "note" ? $4 : "-"); ver[$3] = ($1 == "skill" || $1 == "note" ? $5 : "-")
      next
    }
    FILENAME == ARGV[1] && $1 == "hold" { H[$3] = (H[$3] == "" ? $2 : H[$3] "," $2); next }
    FILENAME == ARGV[2] && $1 == "wrote" && ($2 == "block" || $2 == "skill") { R[$4] = $3; rk[$4] = $2; next }
    FILENAME == ARGV[2] && $1 == "refused" { F[$3] = (F[$3] == "" ? $2 : F[$3] "," $2); next }
    FILENAME == ARGV[3] && $1 == "wrote" { R[$4] = $3; rk[$4] = $2; ri[$4] = $5; rv[$4] = $6; next }
    FILENAME == ARGV[4] { L[$2] = $1; next }
    END {
      for (i = 1; i <= n; i++) {
        t = order[i]; seen[t] = 1
        print t, kind[t], S[t], (t in R ? R[t] : "-"), (t in H ? H[t] : "-"), (t in F ? F[t] : "-"), item[t], ver[t],
          (t in ri ? ri[t] : "-"), (t in rv ? rv[t] : "-"), here(t, kind[t])
      }
      for (t in R) if (!(t in seen)) print t, rk[t], "-", R[t], (t in H ? H[t] : "-"), (t in F ? F[t] : "-"), "-", "-",
        (t in ri ? ri[t] : "-"), (t in rv ? rv[t] : "-"), here(t, rk[t])
    }' "$TMP/entries" "$lockfile" "$TMP/notes-records" "$TMP/notes-local" >"$TMP/plan"

  : >"$TMP/actions"
  : >"$TMP/wrote"
  : >"$TMP/refused"
  : >"$TMP/skipped"
  complete=1

  while read -r t kind S R holds refused item ver rid rver L <&3; do
    if ! allowed "$t" "$kind"; then
      warn "skipped $t: it isn't a file $HARNESS's sync may write."
      planned "Skip $t: it isn't a file $APP_NAME's sync may write."
      printf 'skipped not-allowed %s\n' "$t" >>"$TMP/skipped"
      continue
    fi
    if [ "$kind" = note ] || [ "$kind" = file ]; then
      # What Context Locker last wrote here stays on record, unless this
      # sync writes or removes it
      [ "$R" != - ] && printf 'wrote %s %s %s %s %s\n' "$kind" "$R" "$t" "$rid" "$rver" >>"$TMP/notes-wrote"
      [ "$NOTES_OK" = 1 ] || continue
      path=$PROJECT_ROOT${t#\{project\}}
      if [ -L "$path" ]; then
        warn "left $path alone: it's a link, and links in a project aren't followed."
        printf 'skipped link %s\n' "$t" >>"$TMP/skipped"
        continue
      fi
      if [ -e "$path" ] && [ ! -f "$path" ]; then
        warn "left $path alone: it isn't a file."
        printf 'skipped not-a-file %s\n' "$t" >>"$TMP/skipped"
        continue
      fi
      if [ "$S" = - ]; then
        # Gone from the folder in Context Locker: take it away unless it
        # changed here. A note edited here went up before this, and stays.
        if [ "$L" = none ]; then
          printf 'forget %s\n' "$t" >>"$TMP/notes-wrote"
        elif [ "$L" = "$R" ]; then
          printf 'remove %s %s - - - 0 %s\n' "$t" "$kind" "$L" >>"$TMP/actions"
        elif [ "$kind" = file ]; then
          printf 'untrack %s %s - - - 0 -\n' "$t" "$kind" >>"$TMP/actions"
        fi
        continue
      fi
      if [ "$L" = "$S" ]; then
        printf 'wrote %s %s %s %s %s\n' "$kind" "$S" "$t" "$item" "$ver" >>"$TMP/notes-wrote"
      elif [ "$L" = none ]; then
        # New here, or deleted here: it comes back
        printf 'write %s %s %s %s %s 0 none\n' "$t" "$kind" "$S" "$item" "$ver" >>"$TMP/actions"
      elif [ "$R" = - ] || [ "$L" = "$R" ] || [ "$kind" = file ]; then
        # Written over: a file this computer has no record of writing, or the
        # README edited here, is kept in the backups first
        if [ "$L" = "$R" ]; then keep=0; else keep=1; fi
        printf 'write %s %s %s %s %s %s %s\n' "$t" "$kind" "$S" "$item" "$ver" "$keep" "$L" >>"$TMP/actions"
      fi
      # Otherwise it's a note edited here, which went up before this and
      # stays until Context Locker saves it
      continue
    fi
    if ! path=$(resolve "$t"); then
      planned "Skip $t: it has no folder on this computer."
      printf 'skipped no-folder %s\n' "$t" >>"$TMP/skipped"
      continue
    fi
    if [ "$kind" = skill ]; then what="the skill ${t##*/} at $path"; else what=$path; fi
    case $t in
      '{project}/'*)
        if ! inside_project "$t"; then
          warn "left $path alone: part of its path is a link, and links in a project aren't followed."
          planned "Leave $path alone: part of its path is a link, and links in a project aren't followed."
          printf 'skipped link %s\n' "$t" >>"$TMP/skipped"
          [ "$R" != - ] && printf 'wrote %s %s %s\n' "$kind" "$R" "$t" >>"$TMP/wrote"
          continue
        fi
        ;;
      *)
        if [ -L "$path" ] && [ ! -e "$path" ]; then
          warn "left $path alone: it's a link to something that doesn't exist."
          planned "Leave $path alone: it's a link to something that doesn't exist."
          printf 'skipped link %s\n' "$t" >>"$TMP/skipped"
          [ "$R" != - ] && printf 'wrote %s %s %s\n' "$kind" "$R" "$t" >>"$TMP/wrote"
          continue
        fi
        ;;
    esac

    # What's there now: a hash, "none", "broken", or "foreign" for a folder that isn't ours
    if [ "$kind" = block ]; then
      if [ ! -f "$path" ]; then
        L=none
      else
        pos=$(block_position "$path")
        case $pos in
          none | broken) L=$pos ;;
          *) L=$(block_lines "$path" "${pos% *}" "${pos#* }" | sha_stdin) ;;
        esac
      fi
    else
      if [ ! -e "$path" ] && [ ! -L "$path" ]; then
        L=none
      elif [ -L "$path" ] || [ ! -d "$path" ] || [ ! -f "$path/.ctx-managed" ]; then
        L=foreign
      else
        # Nothing newer than the marker: the folder is as its marker says,
        # whichever app's sync wrote it. Before anything is written over it,
        # hash it anyway, as an edit in the same second wouldn't show as newer.
        L=$(sed -n "3s/^\($HASH\)\$/\1/p" "$path/.ctx-managed")
        if [ -z "$L" ] || [ "$L" != "$S" ] ||
          [ -n "$(find "$path" -newer "$path/.ctx-managed" 2>/dev/null | head -n 1)" ]; then
          L=$(tree_hash "$path")
        fi
      fi
    fi

    if [ "$L" = broken ]; then
      warn "left $path alone: its Context Locker markers don't pair up. Fix or remove them and sync again."
      planned "Leave $path alone: its Context Locker markers don't pair up. Fix or remove them first."
      printf 'skipped broken-markers %s\n' "$t" >>"$TMP/skipped"
      [ "$R" != - ] && printf 'wrote %s %s %s\n' "$kind" "$R" "$t" >>"$TMP/wrote"
      continue
    fi
    if [ "$L" = foreign ]; then
      if [ "$S" != - ]; then
        warn "left $path alone: there's already a skill of yours there with that name."
        planned "Leave $path alone: there's already a skill of yours there with that name."
        printf 'skipped conflict %s\n' "$t" >>"$TMP/skipped"
      fi
      continue
    fi

    if [ "$kind" = skill ] && [ "$S" = - ] && [ "$L" != none ]; then
      local_item=$(marker_item "$path/.ctx-managed")
      local_version=$(marker_version "$path/.ctx-managed")
      # If explicit cleanup could not finish, keep tracking the copy for retry.
      if [ -f "$TMP/removals" ] && awk -v id="$local_item" '$3 == id { found=1 } END { exit !found }' "$TMP/removals"; then
        printf 'wrote %s %s %s\n' "$kind" "$R" "$t" >>"$TMP/wrote"
        continue
      fi
      if [ "$rid" != - ] && { [ "$local_item" != "$rid" ] || { is_number "$local_version" && is_number "$rver" && [ "$local_version" -gt "$rver" ]; }; }; then
        printf 'wrote %s %s %s\n' "$kind" "$R" "$t" >>"$TMP/wrote"
        continue
      fi
    fi

    if [ "$kind" = skill ] && [ "$S" != - ] && [ "$L" != none ] && [ "$(marker_item "$path/.ctx-managed")" = "$item" ]; then
      local_version=$(marker_version "$path/.ctx-managed")
      if is_number "$local_version" && is_number "$ver" && [ "$local_version" -gt "$ver" ]; then
        [ "$R" = - ] || printf 'wrote %s %s %s\n' "$kind" "$R" "$t" >>"$TMP/wrote"
        continue
      fi
    fi

    held=0
    case ",$holds," in *",$L,"*) held=1 ;; esac

    if [ "$S" = - ]; then
      # Gone from the playbook: take it away, unless it holds an edit
      if [ "$held" = 1 ]; then
        HELD=$((HELD + 1))
        planned "Keep your edit in $what while it waits for approval."
        printf 'wrote %s %s %s\n' "$kind" "$R" "$t" >>"$TMP/wrote"
      elif [ "$L" = none ]; then
        :
      elif [ "$L" = "$R" ]; then
        if [ "$kind" = block ]; then
          planned "Take Context Locker's block out of $path, as it's no longer in your playbook."
        else
          planned "Remove $what, as it's no longer in your playbook. A copy goes in $CL_HOME/backups first."
        fi
        printf 'remove %s %s - - - 0\n' "$t" "$kind" >>"$TMP/actions"
      else
        # Changed here and gone there: it stays, as the person's own
        planned "Leave $what as yours: it's no longer in your playbook, and it was changed here."
        printf 'untrack %s %s - - - 0\n' "$t" "$kind" >>"$TMP/actions"
      fi
      continue
    fi

    if [ "$L" = "$S" ]; then
      if [ "$kind" = skill ] && [ "$MODE" = sync ] && [ "$(marker_item "$path/.ctx-managed")" = "$item" ]; then
        printf 'Managed by Context Locker: skill %s, version %s.\nEdits here go to Context Locker at the next sync.\n%s\n' "$item" "$ver" "$S" >"$TMP/skill-marker"
        mv "$TMP/skill-marker" "$path/.ctx-managed"
      fi
      planned "Up to date: $what."
      printf 'wrote %s %s %s\n' "$kind" "$S" "$t" >>"$TMP/wrote"
    elif [ "$held" = 1 ]; then
      HELD=$((HELD + 1))
      planned "Keep your edit in $what while it waits for approval."
      [ "$R" != - ] && printf 'wrote %s %s %s\n' "$kind" "$R" "$t" >>"$TMP/wrote"
    elif [ "$L" = none ]; then
      if [ "$kind" = skill ]; then
        planned "Add $what."
      elif [ -f "$path" ]; then
        planned "Add Context Locker's block to the end of $path. The rest of the file stays as it is."
      else
        planned "Create $path with Context Locker's block."
      fi
      printf 'write %s %s %s %s %s 0\n' "$t" "$kind" "$S" "$item" "$ver" >>"$TMP/actions"
    elif [ "$R" = - ]; then
      # Something we have no record of writing: keep a copy, then replace it
      if [ "$kind" = skill ]; then
        planned "Replace $what, which this computer has no record of syncing. A copy goes in $CL_HOME/backups first."
      else
        planned "Replace the Context Locker block in $path, which this computer has no record of writing. A copy of the file goes in $CL_HOME/backups first."
      fi
      printf 'write %s %s %s %s %s 1\n' "$t" "$kind" "$S" "$item" "$ver" >>"$TMP/actions"
    elif [ "$L" = "$R" ]; then
      if [ "$kind" = skill ]; then planned "Update $what."; else planned "Update Context Locker's block in $path."; fi
      printf 'write %s %s %s %s %s 0\n' "$t" "$kind" "$S" "$item" "$ver" >>"$TMP/actions"
    else
      # An edit made here since the last sync
      case ",$refused," in
        *",$L,"*)
          warn "$path has an edit Context Locker couldn't take, so it won't update until you undo or fix the edit."
          planned "Keep your edit in $what. Context Locker couldn't take it, so this won't update until the edit is undone or fixed."
          printf 'refused %s %s\n' "$L" "$t" >>"$TMP/refused"
          printf 'wrote %s %s %s\n' "$kind" "$R" "$t" >>"$TMP/wrote"
          printf 'skipped refused %s\n' "$t" >>"$TMP/skipped"
          continue
          ;;
      esac
      if [ "$MODE" = plan ]; then
        # A plan sends nothing
        planned "Send your edit in $what to Context Locker, which applies it unless it needs approval first."
        continue
      fi
      outcome=$(send_edit "$t" "$kind" "$path" "$R" "$query")
      case $outcome in
        pending)
          HELD=$((HELD + 1))
          printf 'wrote %s %s %s\n' "$kind" "$R" "$t" >>"$TMP/wrote"
          ;;
        rejected | accepted | same)
          [ "$outcome" = rejected ] && warn "your edit to $path was declined, so it was put back. A copy is in $CL_HOME/backups."
          printf 'write %s %s %s %s %s 1\n' "$t" "$kind" "$S" "$item" "$ver" >>"$TMP/actions"
          ;;
        gone)
          printf 'untrack %s %s - - - 0\n' "$t" "$kind" >>"$TMP/actions"
          ;;
        refused)
          message=$(reply_field message "$TMP/edit-reply")
          warn "Context Locker couldn't take your edit to $path: ${message:-it was refused}"
          printf 'refused %s %s\n' "$L" "$t" >>"$TMP/refused"
          printf 'wrote %s %s %s\n' "$kind" "$R" "$t" >>"$TMP/wrote"
          printf 'skipped refused %s\n' "$t" >>"$TMP/skipped"
          ;;
        *)
          # Offline or an error: keep the edit and try again next time
          complete=0
          printf 'wrote %s %s %s\n' "$kind" "$R" "$t" >>"$TMP/wrote"
          ;;
      esac
    fi
  done 3<"$TMP/plan"

  # A plan stops here: it fetches, writes and reports nothing
  [ "$MODE" = plan ] && return 0

  # The targets whose files changed in the playbook since the last sync here
  : >"$TMP/playbook-changed"
  if [ -n "$old_etag" ]; then
    sed -n 's/^entry //p' "$lockfile" >"$TMP/old-entries"
    awk '
      $1 != "block" && $1 != "skill" && $1 != "file" && $1 != "note" { next }
      FILENAME == ARGV[1] { old[$0] = $3; next }
      { if ($0 in old) delete old[$0]; else print $3 }
      END { for (line in old) print old[line] }' "$TMP/old-entries" "$TMP/entries" >"$TMP/playbook-changed"
  fi

  # Text for the session start, kept on this computer so it shows offline too
  context_hash=$(sed -n "s/^context \\($HASH\\)\$/\\1/p" "$TMP/entries" | head -n 1)
  if [ -z "$context_hash" ]; then
    rm -f "$state.context"
  elif [ ! -f "$state.context" ] || [ "$(sha_file "$state.context")" != "$context_hash" ]; then
    printf 'context %s - %s - - 0\n' "$context_hash" "$context_hash" >>"$TMP/actions"
  fi

  # Fetch everything that needs writing, 500 at a time, as one answer holds
  # at most 1,000
  awk '$1 == "write" || $1 == "context" { print $4 }' "$TMP/actions" | sort -u >"$TMP/want"
  rm -rf "$TMP/blobs" "$TMP"/want.*
  mkdir "$TMP/blobs"
  if [ -s "$TMP/want" ]; then
    awk -v dir="$TMP" '{ file = dir "/want." int((NR - 1) / 500); if (file != last && last != "") close(last); last = file; print > file }' "$TMP/want"
    for chunk in "$TMP"/want.*; do
      code=$(status_of "$(http POST "/v1/sync/blobs$query" "$TMP/blobs.tar" "$chunk" text/plain '' '' '')")
      if [ "$code" != 200 ] || ! tar -xmof "$TMP/blobs.tar" -C "$TMP/blobs" 2>/dev/null ||
        [ -n "$(find "$TMP/blobs" ! -type f ! -type d | head -n 1)" ]; then
        warn "couldn't fetch the latest files, so $HARNESS keeps the ones it has. The next sync tries again."
        FAILED=1
        [ "$NOTES_OK" = 1 ] && notes_write_list "$TMP/notes-wrote"
        return 1
      fi
    done
  fi

  while read -r action t kind hash item ver keep expect <&3; do
    case $action in
      context)
        if [ "$(sha_file "$TMP/blobs/$hash")" = "$hash" ]; then
          cp "$TMP/blobs/$hash" "$state.context"
        else
          complete=0
        fi
        continue
        ;;
    esac
    path=$(resolve "$t") || continue
    case "$action $kind" in
      'write block')
        if [ "$(sha_file "$TMP/blobs/$hash")" != "$hash" ]; then
          warn "the new content for $path didn't match its hash, so it wasn't written. The next sync tries again."
          complete=0
          continue
        fi
        [ "$keep" = 1 ] && [ -f "$path" ] && backup "$path" "$t"
        write_block "$path" "$TMP/blobs/$hash"
        result=$?
        if [ "$result" = 0 ]; then
          WRITTEN=$((WRITTEN + 1))
          count_change block "$t"
          printf 'wrote block %s %s\n' "$hash" "$t" >>"$TMP/wrote"
        elif [ "$result" = 2 ]; then
          warn "left $path alone: its Context Locker markers don't pair up."
          printf 'skipped broken-markers %s\n' "$t" >>"$TMP/skipped"
        else
          warn "couldn't write $path."
          complete=0
        fi
        ;;
      'write skill')
        if [ ! -d "$TMP/blobs/$hash" ] || [ "$(tree_hash "$TMP/blobs/$hash")" != "$hash" ]; then
          warn "the new content for $path didn't match its hash, so it wasn't written. The next sync tries again."
          complete=0
          continue
        fi
        [ "$keep" = 1 ] && [ -e "$path" ] && backup "$path" "$t"
        if install_skill "$TMP/blobs/$hash" "$path" "$item" "$ver" "$hash"; then
          WRITTEN=$((WRITTEN + 1))
          count_change skill "$t"
          printf 'wrote skill %s %s\n' "$hash" "$t" >>"$TMP/wrote"
        else
          warn "couldn't write $path."
          complete=0
        fi
        ;;
      'remove block')
        if remove_block "$path" "$t"; then
          count_change block "$t"
        else
          complete=0
        fi
        ;;
      'remove skill')
        if backup "$path" "$t"; then
          rm -rf "$path"
          SKILLS_CHANGED=1
          count_change skill "$t"
        else
          complete=0
        fi
        ;;
      'untrack skill')
        rm -f "$path/.ctx-managed"
        warn "$path is no longer in your playbook. You'd changed it, so it stays here as your own."
        ;;
      'untrack block')
        warn "the Context Locker block in $path is no longer in your playbook. You'd changed it, so it stays as it is."
        ;;
      'write note' | 'write file')
        if [ "$(sha_file "$TMP/blobs/$hash")" != "$hash" ]; then
          warn "the new content for $path didn't match its hash, so it wasn't written. The next sync tries again."
          complete=0
          continue
        fi
        if [ -f "$path" ]; then
          if [ "$keep" = 1 ]; then
            if ! backup "$path" "$t"; then
              warn "couldn't keep a copy of $path, so it wasn't written over."
              complete=0
              continue
            fi
            [ "$kind" = note ] &&
              warn "replaced $path with the note from Context Locker, as this computer has no record of writing it there. A copy is in $CL_HOME/backups."
          elif [ "$(sha_file "$path")" != "$expect" ]; then
            # Changed since this sync looked, so it's an edit for the next one
            continue
          fi
        fi
        keep_out_of_git
        if write_file "$path" "$TMP/blobs/$hash"; then
          WRITTEN=$((WRITTEN + 1))
          count_change "$kind" "$t"
          printf 'wrote %s %s %s %s %s\n' "$kind" "$hash" "$t" "$item" "$ver" >>"$TMP/notes-wrote"
        else
          warn "couldn't write $path."
          complete=0
        fi
        ;;
      'remove note' | 'remove file')
        # Only while it's still as Context Locker wrote it, and a copy is kept
        [ -f "$path" ] && [ "$(sha_file "$path")" = "$expect" ] || continue
        if backup "$path" "$t" && rm -f "$path"; then
          count_change "$kind" "$t"
          printf 'forget %s\n' "$t" >>"$TMP/notes-wrote"
        else
          complete=0
        fi
        ;;
      'untrack file')
        printf 'forget %s\n' "$t" >>"$TMP/notes-wrote"
        warn "$path is no longer from Context Locker. You'd changed it, so it stays as it is."
        ;;
    esac
  done 3<"$TMP/actions"

  # The notes folder's own list of what Context Locker wrote there
  if [ "$NOTES_OK" = 1 ]; then
    notes_write_list "$TMP/notes-wrote" || complete=0
  fi

  # What this check of the pointers found, kept to tell when it changes
  : >"$TMP/links-now"
  [ -n "$LINKS_CHECKED" ] && { printf 'links %s\n' "$LINKS_CHECKED"; cat "$TMP/missing"; } >"$TMP/links-now"

  {
    printf 'context-locker-lock 1\n'
    [ "$complete" = 1 ] && printf 'etag %s\n' "$etag"
    printf 'synced %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    sed 's/^/entry /' "$TMP/entries"
    cat "$TMP/wrote" "$TMP/refused" "$TMP/links-now"
  } >"$lockfile.tmp" && mv -f "$lockfile.tmp" "$lockfile"

  [ "$complete" = 1 ] || FAILED=1
  # The report goes with a new manifest, and when the missing paths changed
  if [ "$complete" = 1 ] && { [ "$fresh" = 1 ] ||
    { [ -n "$LINKS_CHECKED" ] && [ "$(sha_file "$TMP/links-now")" != "$(sha_file "$TMP/links-before")" ]; }; }; then
    {
      printf 'manifest %s\nwritten %s\nheld %s\n' "$etag" "$WRITTEN" "$HELD"
      head -n 100 "$TMP/skipped"
      head -n 101 "$TMP/links-now"
    } >"$TMP/report"
    http POST "/v1/sync/done$query" "$TMP/done-reply" "$TMP/report" text/plain '' '' '' >/dev/null
  fi
  return 0
}

# --- Which project this session is in ---------------------------------------

WORKSPACE_ID=
# How this session's project was found: flag, local or remote
FOUND_BY=
# The folder the session works in
START=${CLAUDE_PROJECT_DIR:-$PWD}

# The top folder of the git work tree $1 is in, or nothing outside one
git_top() {
  have git || return 1
  (
    unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE
    cd "$1" 2>/dev/null || exit 1
    [ "$(git rev-parse --is-inside-work-tree 2>/dev/null)" = true ] || exit 1
    git rev-parse --show-toplevel 2>/dev/null
  )
}

# The project of the folder $1 from what's on this computer: a
# .contextlocker.json naming this workspace, in it or a folder above it, or
# else the longest folder linked on this computer that holds it
detect_project() {
  start=${1:-$START}
  dir=$start
  while :; do
    if [ -f "$dir/.contextlocker.json" ]; then
      linked_ws=$(sed -n "s/.*\"workspace\"[[:space:]]*:[[:space:]]*\"\\($UUID\\)\".*/\\1/p" "$dir/.contextlocker.json" | head -n 1)
      linked=$(sed -n "s/.*\"project\"[[:space:]]*:[[:space:]]*\"\\($UUID\\)\".*/\\1/p" "$dir/.contextlocker.json" | head -n 1)
      if [ -n "$linked" ] && [ -n "$WORKSPACE_ID" ] && [ "$linked_ws" = "$WORKSPACE_ID" ]; then
        PROJECT_ID=$linked PROJECT_ROOT=$dir LAYER=repo
        return 0
      fi
      break
    fi
    [ "$dir" = / ] || [ "$dir" = "$HOME" ] || [ -z "$dir" ] && break
    dir=$(dirname "$dir")
  done

  # Folders linked on this computer only: "<project id> <folder>" per line.
  # A folder matches by the path it was linked with or the one with no links.
  [ -f "$CL_HOME/projects" ] || return 1
  real=$(cd -P "$start" 2>/dev/null && pwd -P) || real=$start
  best=
  while IFS= read -r line; do
    id=${line%% *} folder=${line#* }
    case $start/ in
      "$folder"/*) ;;
      *) case $real/ in "$folder"/*) ;; *) continue ;; esac ;;
    esac
    if [ "${#folder}" -gt "${#best}" ]; then
      best=$folder PROJECT_ID=$id
    fi
  done <"$CL_HOME/projects"
  [ -n "$best" ] || return 1
  PROJECT_ROOT=$best LAYER=personal
}

# The project --project names, in the repo's top folder or the current one:
# a repo whose .contextlocker.json names the same project is a linked repo
flag_project() {
  printf '%s\n' "$PROJECT_FLAG" | grep -q "^$UUID\$" || return 1
  PROJECT_ID=$PROJECT_FLAG
  PROJECT_ROOT=$(git_top "$START") || PROJECT_ROOT=$START
  LAYER=personal
  fp_json=$PROJECT_ROOT/.contextlocker.json
  if [ -f "$fp_json" ] && [ -n "$WORKSPACE_ID" ] &&
    [ "$(sed -n "s/.*\"workspace\"[[:space:]]*:[[:space:]]*\"\\($UUID\\)\".*/\\1/p" "$fp_json" | head -n 1)" = "$WORKSPACE_ID" ] &&
    [ "$(sed -n "s/.*\"project\"[[:space:]]*:[[:space:]]*\"\\($UUID\\)\".*/\\1/p" "$fp_json" | head -n 1)" = "$PROJECT_ID" ]; then
    LAYER=repo
  fi
  return 0
}

# The origin remote of the repo whose top folder is $1, without a user name,
# password, query or fragment; nothing when it has none, or it's a path on
# this computer. Context Locker is never sent a path on this computer.
origin_remote() {
  have git || return 1
  or_url=$(
    unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE
    cd "$1" 2>/dev/null || exit 1
    git remote get-url origin 2>/dev/null || git config --get remote.origin.url 2>/dev/null
  ) || return 1
  case $or_url in
    '' | *[[:space:]]* | *\\* | *'"'*) return 1 ;;
  esac
  case $or_url in
    [A-Za-z]*://*)
      case ${or_url%%://*} in
        [Hh][Tt][Tt][Pp] | [Hh][Tt][Tt][Pp][Ss] | [Ss][Ss][Hh] | [Gg][Ii][Tt] | [Gg][Ii][Tt]+[Ss][Ss][Hh] | [Ss][Ss][Hh]+[Gg][Ii][Tt]) ;;
        *) return 1 ;;
      esac
      or_rest=${or_url#*://}
      or_auth=${or_rest%%/*}
      or_url=${or_url%%://*}://${or_auth##*@}${or_rest#"$or_auth"}
      ;;
    /* | .* | '~'*) return 1 ;;
    *:*)
      # As git reads it: [user@]host:path, with no slash before the colon,
      # and a host longer than a drive letter
      or_host=${or_url%%:*}
      case $or_host in '' | */* | ? | *@) return 1 ;; esac
      or_url=${or_host##*@}:${or_url#*:}
      ;;
    *) return 1 ;;
  esac
  or_url=${or_url%%[?#]*}
  [ "${#or_url}" -le 1000 ] || return 1
  printf '%s' "$or_url"
}

# Links the folder $2 to the project $1, for this computer only
link_folder() {
  touch "$CL_HOME/projects"
  FOLDER=$2 awk '{ f = $0; sub(/^[^ ]* /, "", f); if (f != ENVIRON["FOLDER"]) print }' \
    "$CL_HOME/projects" >"$CL_HOME/projects.tmp"
  printf '%s %s\n' "$1" "$2" >>"$CL_HOME/projects.tmp"
  mv -f "$CL_HOME/projects.tmp" "$CL_HOME/projects"
}

link_project() {
  printf '%s\n' "$PROJECT_FLAG" | grep -q "^$UUID\$" || {
    warn "--project needs a project's id."
    FAILED=1
    return 1
  }
  root=$(git_top "$START") || root=$START
  link_folder "$PROJECT_FLAG" "$root"
}

unlink_project() {
  awk -v id="$1" '$1 != id' "$CL_HOME/projects" >"$CL_HOME/projects.tmp" &&
    mv -f "$CL_HOME/projects.tmp" "$CL_HOME/projects"
}

# The project whose git remote is this repo's origin, as Context Locker
# finds it. With "link", the folder is linked for this computer, as
# --project links it, and a line says so.
remote_project() {
  rp_top=$(git_top "$START") || return 1
  rp_url=$(origin_remote "$rp_top") || return 1
  printf '%s' "$rp_url" >"$TMP/remote"
  [ "$(status_of "$(http POST /v1/sync/remote "$TMP/remote-reply" "$TMP/remote" text/plain '' '' '')")" = 200 ] || return 1
  rp_id=$(reply_field id "$TMP/remote-reply")
  printf '%s\n' "$rp_id" | grep -q "^$UUID\$" || return 1
  PROJECT_ID=$rp_id PROJECT_ROOT=$rp_top LAYER=personal
  [ "${1:-}" = link ] || return 0
  link_folder "$rp_id" "$rp_top"
  rp_name=$(reply_field name "$TMP/remote-reply" | clean)
  rp_remote=$(reply_field git_remote "$TMP/remote-reply" | clean)
  warn "linked $rp_top to ${rp_name:-its project} by its git remote, ${rp_remote:-$rp_url}."
}

# Records the origin remote of a folder linked with --project on its project,
# when the project has none, so other clones find it. Quiet either way.
record_remote() {
  rr_url=$(origin_remote "$1") || return 0
  printf '%s' "$rr_url" >"$TMP/remote"
  http PUT "/v1/sync/remote?project=$PROJECT_ID" "$TMP/remote-reply" "$TMP/remote" text/plain '' '' '' >/dev/null
  return 0
}

# Which project this session is in: the one --project names, then a
# .contextlocker.json, then a folder linked on this computer, then the git
# remote, which "link" links and "ask" only asks about
find_project() {
  if [ -n "$PROJECT_FLAG" ]; then
    flag_project || return 1
    FOUND_BY=flag
  elif detect_project; then
    FOUND_BY=local
  elif [ "${1:-}" = link ] || [ "${1:-}" = ask ]; then
    remote_project "$1" || return 1
    FOUND_BY=remote
  else
    return 1
  fi
}

# A daily run syncs every project linked on this computer too, in each
# folder that's still there, as far as the app works in projects: OpenClaw
# doesn't, and Hermes only in repos linked with a .contextlocker.json
daily_projects() {
  [ "$HARNESS" = openclaw ] && return 0
  [ -f "$CL_HOME/projects" ] || return 0
  # Read the list first, as a sync can unlink a project that's gone
  cp "$CL_HOME/projects" "$TMP/linked"
  : >"$TMP/linked-done"
  gone=0
  while IFS= read -r dp_line <&5; do
    dp_folder=${dp_line#* }
    case $dp_folder in /*) ;; *) continue ;; esac
    if [ ! -d "$dp_folder" ]; then
      gone=$((gone + 1))
      continue
    fi
    PROJECT_ID= PROJECT_ROOT= LAYER=
    detect_project "$dp_folder" || continue
    [ "$HARNESS" = hermes ] && [ "$LAYER" != repo ] && continue
    grep -qxF "$PROJECT_ID $PROJECT_ROOT" "$TMP/linked-done" && continue
    printf '%s %s\n' "$PROJECT_ID" "$PROJECT_ROOT" >>"$TMP/linked-done"
    SCOPE=project EXCLUDED=0
    sync_scope "?project=$PROJECT_ID&layer=$LAYER" "$APP_DIR/projects/$PROJECT_ID"
    [ $? = 3 ] && [ "$LAYER" = personal ] && unlink_project "$PROJECT_ID"
  done 5<"$TMP/linked"
  if [ "$gone" = 1 ]; then
    warn "1 folder linked on this computer isn't there any more, so its project wasn't synced."
  elif [ "$gone" -gt 1 ]; then
    warn "$gone folders linked on this computer aren't there any more, so their projects weren't synced."
  fi
  return 0
}

# --- Setup: sign-in, plan, doctor and read-back ------------------------------

# Quotes a word for sh, when it needs quoting
shell_quote() {
  case $1 in
    '' | *[!A-Za-z0-9/._~-]*) printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")" ;;
    *) printf '%s' "$1" ;;
  esac
}

# Where setup saves this script, and how hooks run it
INSTALLED=$CL_HOME/sync.sh
if [ "$CL_HOME" = "$HOME/.contextlocker" ]; then
  RUN='sh ~/.contextlocker/sync.sh'
else
  RUN="sh $(shell_quote "$INSTALLED")"
fi
case $HARNESS in
  hermes) TRIGGER='Hermes hooks' TRIGGER_RUNS=run ;;
  openclaw) TRIGGER='OpenClaw hook' TRIGGER_RUNS=runs ;;
  *) TRIGGER='session-start hook' TRIGGER_RUNS=runs ;;
esac
case $(uname -s 2>/dev/null) in
  Darwin) OS_NAME=macOS ;;
  Linux) OS_NAME=Linux ;;
  MINGW* | MSYS* | CYGWIN*) OS_NAME=Windows ;;
  *) OS_NAME=$(uname -s 2>/dev/null | tr -cd 'A-Za-z0-9 ._-' | cut -c 1-40) ;;
esac

is_number() { case $1 in '' | *[!0-9]*) return 1 ;; esac; }
plural() { if [ "$1" = 1 ]; then printf '1 %s' "$2"; else printf '%s %s' "$1" "$3"; fi; }
reply_number() { sed -nE 's/.*"'"$1"'":[[:space:]]*([0-9]+).*/\1/p' "$2" | head -n 1; }
# Text from a reply, with any control characters taken out before it's shown
clean() { tr -d '\000-\037\177'; }
json_value() {
  sed -nE 's/.*"'"$1"'":\{[^}]*"'"$2"'":"(([^"\\]|\\.)*)".*/\1/p' "$3" | head -n 1 | sed 's/\\"/"/g; s/\\\\/\\/g' | clean
}

# "Claude Code on Ada's laptop, in the Personal workspace", from GET /v1/agent, or
# "Work Codex, in the Personal workspace" when the person named it
connected_as() {
  name=$(json_value agent name "$TMP/agent")
  machine=$(json_value agent machine_name "$TMP/agent")
  workspace=$(json_value workspace name "$TMP/agent")
  name=${name:-$APP_NAME}
  printf '%s' "$name"
  # A name the person chose says which this is; the app's own name needs the computer
  [ -n "$machine" ] && [ "$name" = "$APP_NAME" ] && printf ' on %s' "$machine"
  [ -n "$workspace" ] && printf ', in the %s workspace' "$workspace"
  return 0
}

# This computer's name, as the approval page shows it: the first of its names
# with a letter or digit left once it's cut down to plain characters, or nothing
machine_name() {
  found=
  for source in computer host node; do
    case $source in
      computer) { have scutil && name=$(scutil --get ComputerName 2>/dev/null); } || continue ;;
      host) name=$(hostname 2>/dev/null) ;;
      node) name=$(uname -n 2>/dev/null) ;;
    esac
    # macOS names use a curly apostrophe; keep it readable as a straight one
    name=$(printf '%s' "$name" | sed "s/$(printf '\342\200\231')/'/g" | tr -cd "A-Za-z0-9 ._'-" |
      cut -c 1-120 | sed 's/^ *//; s/ *$//')
    case $name in *[A-Za-z0-9]*)
      found=$name
      break
      ;;
    esac
  done
  printf '%s' "$found"
}

# A random id for this computer, kept so that connecting an app again replaces
# its old connection instead of adding another. "saved" only reads it.
machine_id() {
  id=$(head -n 1 "$CL_HOME/machine-id" 2>/dev/null | tr -cd 'a-f0-9')
  if [ "${#id}" != 32 ]; then
    [ "${1:-}" = saved ] && return 0
    id=$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -cd 'a-f0-9')
    [ "${#id}" = 32 ] || return 0
    printf '%s\n' "$id" >"$CL_HOME/machine-id"
  fi
  printf '%s' "$id"
}

save_device_state() {
  printf 'device_code=%s\nuser_code=%s\nlink=%s\nexpires=%s\ninterval=%s\nlast=%s\n' \
    "$device_code" "$user_code" "$link" "$expires" "$interval" "$last" >"$state.tmp" &&
    mv -f "$state.tmp" "$state"
}

# Connects this app with a one-time code the person made in Context Locker,
# for a connection they've already named, so there's nothing to approve. The
# token goes straight into a file only this account can read, and the code is
# never printed. An app already connected takes the new connection's name and
# a fresh token, as the person asked for it.
claim_code() {
  TOKEN=
  name=$(machine_name)
  id=$(machine_id)
  {
    printf '{"grant_type":"urn:context-locker:params:oauth:grant-type:invite","invite_code":"%s","harness":"%s","agent_name":"%s","client_version":"sync.sh %s"' \
      "$CODE" "$HARNESS" "$APP_NAME" "$SCRIPT_VERSION"
    [ -n "$name" ] && printf ',"machine_name":"%s"' "$name"
    [ -n "$id" ] && printf ',"machine_id":"%s"' "$id"
    [ -n "$OS_NAME" ] && printf ',"os":"%s"' "$OS_NAME"
    printf '}\n'
  } >"$TMP/claim"
  code=$(status_of "$(http POST /oauth/token "$TMP/claimed" "$TMP/claim" application/json '' '' '')")
  rm -f "$TMP/claim"
  case $code in
    200) ;;
    000)
      printf "Context Locker: can't reach %s. Check the internet connection and try again.\n" "$API" >&2
      return 1
      ;;
    400)
      rm -f "$TMP/claimed"
      printf "Context Locker: that code can't be used. It works once, for 15 minutes. Ask for a new one: the person makes it in Context Locker, from the connection's New code.\n" >&2
      return 1
      ;;
    429)
      rm -f "$TMP/claimed"
      printf 'Context Locker: too many codes tried from this network just now. Try again in a few minutes.\n' >&2
      return 1
      ;;
    *)
      message=$(reply_field error_description "$TMP/claimed" | clean)
      rm -f "$TMP/claimed"
      printf "Context Locker: couldn't connect with the code: %s\n" "${message:-Context Locker answered $code.}" >&2
      return 1
      ;;
  esac
  new=$(reply_field access_token "$TMP/claimed")
  rm -f "$TMP/claimed"
  case $new in ctxl_at_?*) ;; *) new= ;; esac
  case $new in *[!A-Za-z0-9_-]*) new= ;; esac
  if [ -z "$new" ]; then
    printf "Context Locker: the reply didn't include a usable token. Ask for a new code and try again.\n" >&2
    return 1
  fi
  if ! { printf '%s\n' "$new" >"$APP_DIR/token.tmp" && mv -f "$APP_DIR/token.tmp" "$APP_DIR/token"; }; then
    printf "Context Locker: couldn't save the connection in %s.\n" "$APP_DIR" >&2
    return 1
  fi
  # A device sign-in that was waiting isn't needed any more
  rm -f "$APP_DIR/device"
  TOKEN=$new
  if [ "$(status_of "$(http GET /v1/agent "$TMP/agent" '' '' '' '' '')")" = 200 ]; then
    printf 'Connected: %s.\n' "$(connected_as)"
  else
    printf 'Connected.\n'
  fi
  return 0
}

# Connects this app with a device code (RFC 8628). Only the link and the code
# are shown: the token goes straight into a file only this account can read.
signin() {
  if [ -n "$CODE" ]; then
    claim_code
    return
  fi
  if ! token_problem >/dev/null; then
    code=$(status_of "$(http GET /v1/agent "$TMP/agent" '' '' '' '' '')")
    case $code in
      200)
        printf '%s is already connected: %s.\n' "$APP_NAME" "$(connected_as)"
        return 0
        ;;
      401) ;;
      000)
        printf "Context Locker: can't reach %s. Check the internet connection and try again.\n" "$API" >&2
        return 1
        ;;
      *)
        printf 'Context Locker answered %s. Try again in a minute.\n' "$code" >&2
        return 1
        ;;
    esac
  fi
  # A revoked or damaged token is replaced, never sent along
  TOKEN=

  state=$APP_DIR/device
  now=$(date +%s)
  device_code=$(read_setting device_code "$state")
  user_code=$(read_setting user_code "$state")
  link=$(read_setting link "$state")
  expires=$(read_setting expires "$state")
  interval=$(read_setting interval "$state")
  last=$(read_setting last "$state")
  if [ -z "$device_code" ] || ! is_number "$expires" || ! is_number "$interval" ||
    ! is_number "$last" || [ "$expires" -le "$now" ]; then
    rm -f "$state"
    name=$(machine_name)
    id=$(machine_id)
    {
      printf '{"harness":"%s","agent_name":"%s","client_version":"sync.sh %s"' "$HARNESS" "$APP_NAME" "$SCRIPT_VERSION"
      [ -n "$name" ] && printf ',"machine_name":"%s"' "$name"
      [ -n "$id" ] && printf ',"machine_id":"%s"' "$id"
      [ -n "$OS_NAME" ] && printf ',"os":"%s"' "$OS_NAME"
      printf '}\n'
    } >"$TMP/start"
    code=$(status_of "$(http POST /oauth/device_authorization "$TMP/started" "$TMP/start" application/json '' '' '')")
    case $code in
      200) ;;
      000)
        printf "Context Locker: can't reach %s. Check the internet connection and try again.\n" "$API" >&2
        return 1
        ;;
      429)
        printf 'Context Locker: too many sign-ins from this network just now. Try again in a few minutes.\n' >&2
        return 1
        ;;
      *)
        message=$(reply_field error_description "$TMP/started" | clean)
        printf "Context Locker: couldn't start the sign-in: %s\n" "${message:-Context Locker answered $code.}" >&2
        return 1
        ;;
    esac
    device_code=$(reply_field device_code "$TMP/started")
    user_code=$(reply_field user_code "$TMP/started")
    link=$(reply_field verification_uri_complete "$TMP/started")
    expires=$(reply_number expires_in "$TMP/started")
    interval=$(reply_number interval "$TMP/started")
    case $device_code in ctxl_dc_?*) ;; *) device_code= ;; esac
    case $device_code in *[!A-Za-z0-9_-]*) device_code= ;; esac
    case $user_code in ????-????) ;; *) user_code= ;; esac
    case $user_code in *[!A-Z0-9-]*) user_code= ;; esac
    case $link in https://* | http://*) ;; *) link= ;; esac
    case $link in *[!A-Za-z0-9:/.?=_-]*) link= ;; esac
    if [ -z "$device_code" ] || [ -z "$user_code" ] || [ -z "$link" ] ||
      ! is_number "$expires" || ! is_number "$interval"; then
      printf "Context Locker: the sign-in reply didn't make sense, so nothing was saved. Try again.\n" >&2
      return 1
    fi
    expires=$((now + expires))
    last=0
    save_device_state
    started=1
  else
    started=0
  fi

  printf 'To connect %s on this computer, open this link and approve the request:\n\n  %s\n\nCheck that the page shows the code %s.\n' \
    "$APP_NAME" "$link" "$user_code"
  # Nobody can have approved a code that was only just shown, so the first run
  # hands the link straight back instead of waiting
  if [ "$started" = 1 ]; then
    printf "\nWaiting for approval. Once it's approved, run this command again.\n"
    return 3
  fi

  deadline=$(($(date +%s) + WAIT))
  polled=0
  while :; do
    # Never poll faster than the interval, even across runs of this command.
    # Times are whole seconds, so wait one more to be sure.
    [ "$interval" -lt 5 ] && interval=5
    [ "$interval" -gt 60 ] && interval=60
    now=$(date +%s)
    pause=$((last + interval + 1 - now))
    if [ "$pause" -gt 0 ]; then
      [ "$polled" = 1 ] && [ $((now + pause)) -gt "$deadline" ] && break
      sleep "$pause"
    fi
    printf '{"grant_type":"urn:ietf:params:oauth:grant-type:device_code","device_code":"%s"}\n' \
      "$device_code" >"$TMP/poll"
    code=$(status_of "$(http POST /oauth/token "$TMP/polled" "$TMP/poll" application/json '' '' '')")
    polled=1
    last=$(date +%s)
    error=
    [ "$code" = 400 ] && error=$(reply_field error "$TMP/polled")
    case "$code $error" in
      '200 ')
        new=$(reply_field access_token "$TMP/polled")
        rm -f "$TMP/polled"
        case $new in ctxl_at_?*) ;; *) new= ;; esac
        case $new in *[!A-Za-z0-9_-]*) new= ;; esac
        rm -f "$state"
        if [ -z "$new" ]; then
          printf "\nThe reply didn't include a usable token. Run this command again to start over.\n"
          return 1
        fi
        if ! { printf '%s\n' "$new" >"$APP_DIR/token.tmp" && mv -f "$APP_DIR/token.tmp" "$APP_DIR/token"; }; then
          printf "\nContext Locker: couldn't save the connection in %s.\n" "$APP_DIR" >&2
          return 1
        fi
        TOKEN=$new
        if [ "$(status_of "$(http GET /v1/agent "$TMP/agent" '' '' '' '' '')")" = 200 ]; then
          printf '\nConnected: %s.\n' "$(connected_as)"
        else
          printf '\nConnected.\n'
        fi
        return 0
        ;;
      '400 authorization_pending') ;;
      '400 slow_down') interval=$((interval + 5)) ;;
      '400 access_denied')
        rm -f "$state"
        printf "\nThe request was turned down, so %s isn't connected. Run this command again to start over.\n" "$APP_NAME"
        return 1
        ;;
      '400 expired_token')
        rm -f "$state"
        printf '\nThe code expired before it was approved. Run this command again for a new one.\n'
        return 1
        ;;
      '400 invalid_grant')
        rm -f "$state"
        printf "\nThis code can't be used any more. Run this command again for a new one.\n"
        return 1
        ;;
      000*) ;;
      *)
        save_device_state
        printf '\nContext Locker answered %s. Run this command again to keep waiting.\n' "$code"
        return 1
        ;;
    esac
    save_device_state
    [ "$(date +%s)" -ge "$deadline" ] && break
  done
  printf "\nStill waiting for approval. Once it's approved, run this command again.\n"
  return 3
}

# Whether a settings file has a session-start hook that runs this script: a
# command in the SessionStart part of a JSON settings file, or of Codex's
# config.toml. Mentions elsewhere, such as a permission rule that names the
# script, don't count. Another event's key ("PreToolUse": [, or
# [[hooks.PreToolUse]]) ends the SessionStart part.
hook_in() {
  [ -f "$1" ] || return 1
  awk -v installed="$INSTALLED" '
    /"SessionStart"|hooks[.]SessionStart/ { start = 1 }
    !/SessionStart/ && (/"[A-Z][A-Za-z]*"[[:space:]]*:[[:space:]]*\[/ || /^[[:space:]]*\[\[?hooks[.][A-Z]/) { start = 0 }
    start && (/"(command|commandWindows)"[[:space:]]*:/ || /^[[:space:]]*command(_windows|Windows)?[[:space:]]*=/) &&
      ($0 ~ /contextlocker\/+sync[.](sh|ps1)/ || index($0, installed)) { found = 1; exit }
    END { exit !found }' "$1"
}

hook_json() {
  cmd=$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')
  printf '    {\n      "hooks": {\n        "SessionStart": [\n          {\n            "hooks": [\n              { "type": "command", "command": "%s", "timeout": 60 }\n            ]\n          }\n        ]\n      }\n    }\n' "$cmd"
}

# --- When each app syncs ------------------------------------------------------

# Each app runs the sync on its own events, all with the same command, so
# adding an app is a line here and its case in the plan and the doctor.
# Claude Code and Codex read what a session-start hook prints. Hermes and
# OpenClaw don't, so their hooks run it with --hook, which keeps it quiet.
#
#   app          where the hook goes                     events
#   claude-code  settings.json, under SessionStart       startup, resume, clear, compact
#   codex        hooks.json, under SessionStart          startup, resume, clear, compact
#   hermes       config.yaml, under hooks                on_session_start, post_compaction
#   openclaw     ~/.openclaw/hooks/context-locker-sync   gateway:startup, command:new,
#                                                        command:reset, session:compact:before
hook_events() {
  case $1 in
    claude-code | codex) printf 'startup resume clear compact' ;;
    hermes) printf 'on_session_start post_compaction' ;;
    openclaw) printf 'gateway:startup command:new command:reset session:compact:before' ;;
  esac
}

# The command a hook runs with no shell to expand ~, as Hermes's and
# OpenClaw's do
HOOK_RUN="sh $(shell_quote "$INSTALLED")"

# Whether Hermes's config.yaml runs the sync for each of its events: a command
# that runs this script, listed under the event in the hooks section
hermes_hooks_in() {
  [ -f "$1" ] || return 1
  awk -v installed="$INSTALLED" -v events="$(hook_events hermes)" '
    { sub(/\r$/, "") }
    /^[^[:space:]#]/ { inhooks = ($0 ~ /^hooks:[[:space:]]*$/); event = ""; next }
    inhooks && /^[[:space:]]+[a-z_]+:[[:space:]]*$/ { event = $0; gsub(/[[:space:]:]/, "", event); next }
    inhooks && event != "" && /command:/ && ($0 ~ /contextlocker\/+sync[.](sh|ps1)/ || index($0, installed)) { found[event] = 1 }
    END {
      n = split(events, want, " ")
      for (i = 1; i <= n; i++) if (!(want[i] in found)) exit 1
    }' "$1"
}

hermes_hooks_yaml() {
  hy_cmd=$(printf '%s' "$HOOK_RUN hermes --hook" | sed 's/\\/\\\\/g; s/"/\\"/g')
  printf '    hooks:\n'
  for hy_event in $(hook_events hermes); do
    printf '      %s:\n        - command: "%s"\n' "$hy_event" "$hy_cmd"
  done
}

# OpenClaw's hook: a folder in its managed hooks folder, normally
# ~/.openclaw/hooks, with HOOK.md and a handler that runs the sync
OPENCLAW_HOOK=$HOME/.openclaw/hooks/context-locker-sync

openclaw_hook_md() {
  printf -- '---\nname: context-locker-sync\ndescription: "Keeps OpenClaw'"'"'s files in step with your Context Locker playbook"\nmetadata: { "openclaw": { "events": ['
  oh_first=1
  for oh_event in $(hook_events openclaw); do
    [ "$oh_first" = 1 ] || printf ', '
    printf '"%s"' "$oh_event"
    oh_first=0
  done
  printf '] } }\n---\n\n# Context Locker sync\n\nRuns Context Locker'"'"'s sync when the gateway starts, when a session starts or resets, and before compaction, so OpenClaw'"'"'s files hold your playbook as it is now.\n'
}

openclaw_handler() {
  oh_path=$(printf '%s' "$INSTALLED" | sed 's/\\/\\\\/g; s/"/\\"/g')
  printf 'import { execFile } from "node:child_process";\n\n// Runs the sync, waiting at most a minute, and never stops OpenClaw\nexport default function handler() {\n  return new Promise((resolve) => {\n    execFile("sh", ["%s", "openclaw", "--hook"], { timeout: 60000 }, () => resolve());\n  });\n}\n' "$oh_path"
}

# Whether OpenClaw's hook is in place: HOOK.md with each of its events, and a
# handler that runs this script
openclaw_hook_in() {
  [ -f "$OPENCLAW_HOOK/HOOK.md" ] || return 1
  for oh_event in $(hook_events openclaw); do
    grep -Fq "\"$oh_event\"" "$OPENCLAW_HOOK/HOOK.md" || return 1
  done
  for oh_file in handler.ts handler.js index.ts index.js; do
    [ -f "$OPENCLAW_HOOK/$oh_file" ] || continue
    grep -Eq 'contextlocker[/\\]+sync\.(sh|ps1)' "$OPENCLAW_HOOK/$oh_file" && return 0
    grep -Fq "$INSTALLED" "$OPENCLAW_HOOK/$oh_file" && return 0
    return 1
  done
  return 1
}

hook_plan() {
  case $HARNESS in
    claude-code)
      settings=${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json
      if hook_in "$settings"; then
        printf 'Session start: the hook is already in %s.\n' "$settings"
      else
        printf 'Session start: add this hook to %s, keeping everything already in the file. Claude Code may ask you to approve the edit:\n\n' "$settings"
        hook_json "$RUN claude-code"
      fi
      ;;
    codex)
      dir=${CODEX_HOME:-$HOME/.codex}
      if hook_in "$dir/hooks.json" || hook_in "$dir/config.toml"; then
        printf 'Session start: the hook is already set up in %s.\n' "$dir"
      else
        printf 'Session start: add this hook to %s/hooks.json, after any hooks already there. Codex skips a new hook until you trust it in /hooks:\n\n' "$dir"
        hook_json "$RUN codex"
      fi
      ;;
    hermes)
      config=$(root_dir hermes)/config.yaml
      if hermes_hooks_in "$config"; then
        printf 'Hooks: %s already runs the sync when a session starts and after compaction.\n' "$config"
      else
        printf 'Hooks: add these to the hooks section of %s, keeping everything already in the file, so Hermes syncs when a session starts and after compaction:\n\n' "$config"
        hermes_hooks_yaml
        printf '\nHermes asks you to approve each one the first time it sees it, in a hermes chat. Its gateway never asks, so approve them in a chat first.\n'
      fi
      ;;
    openclaw)
      if openclaw_hook_in; then
        printf 'Hook: %s already runs the sync when the gateway starts, when a session starts or resets, and before compaction.\n' "$OPENCLAW_HOOK"
      else
        printf 'Hook: save these two files in %s, on the computer where the OpenClaw gateway runs, so OpenClaw syncs when its gateway starts, when a session starts or resets, and before compaction.\n\n%s/HOOK.md:\n\n' "$OPENCLAW_HOOK" "$OPENCLAW_HOOK"
        openclaw_hook_md | sed 's/^/    /; s/^    $//'
        printf '\n%s/handler.js:\n\n' "$OPENCLAW_HOOK"
        openclaw_handler | sed 's/^/    /; s/^    $//'
        printf '\nThen turn it on, and restart the gateway if it was running, so it loads the hook:\n\n    openclaw hooks enable context-locker-sync\n'
      fi
      ;;
  esac
}

# --- How this app runs the sync (G1-87) ---------------------------------------

# Hermes and OpenClaw can also run the sync once a day from their own
# schedulers, with no model call, so they keep up between sessions. Claude
# Code and Codex can't run anything in the background, so they sync on their
# hooks' events only. The job has one name everywhere, and runs at a minute
# past 9 that comes from this computer's id, so computers don't all sync at
# once. Reading the id never creates it.
DAILY_JOB=contextlocker-daily

job_minute() {
  jm_id=$(machine_id saved)
  jm_sum=$(printf '%s' "${jm_id:-$(uname -n 2>/dev/null)}" | cksum | cut -d ' ' -f 1)
  printf '%02d' $((jm_sum % 60))
}

# This computer's time zone, as a name such as Pacific/Auckland, or local
time_zone() {
  tz_name=${TZ:-}
  tz_name=${tz_name#:}
  if [ -z "$tz_name" ] && [ -L /etc/localtime ]; then
    tz_name=$(readlink /etc/localtime 2>/dev/null | sed -n 's|.*zoneinfo/||p')
  fi
  [ -z "$tz_name" ] && [ -f /etc/timezone ] && tz_name=$(head -n 1 /etc/timezone)
  tz_name=$(printf '%s' "$tz_name" | tr ' ' '_' | tr -cd 'A-Za-z0-9_+./-' | cut -c 1-64)
  case $tz_name in
    [A-Za-z]*) printf '%s' "$tz_name" ;;
    *) printf 'local' ;;
  esac
}

# The daily job as its app's scheduler lists it, in a line: its id, on or
# off, and its time when the listing says, such as "3f2a9c1b7d4e on 09:17".
# It prints nothing when there's none, and fails when the scheduler can't be
# asked, so a second job is never added.
list_daily_job() {
  case $HARNESS in
    hermes)
      # A paragraph a job: its id and state, then lines such as Name: and
      # Schedule:
      have hermes && hermes cron list --all >"$TMP/jobs" 2>/dev/null || return 1
      tr -d '\033' <"$TMP/jobs" | sed 's/\[[0-9;]*m//g' |
        awk -v name="$DAILY_JOB" 'BEGIN { RS = "" }
          $0 ~ ("Name:[[:space:]]*" name "([[:space:]]|$)") || /Script:[[:space:]]*contextlocker-sync\.sh/ {
            when = ""
            if (match($0, /Schedule:[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]+\*[[:space:]]+\*[[:space:]]+\*/)) {
              split(substr($0, RSTART, RLENGTH), part, /[[:space:]]+/)
              if (part[2] < 60 && part[3] < 24) when = sprintf(" %02d:%02d", part[3], part[2])
            }
            print $1, ($2 == "[active]" ? "on" : "off") when
            exit
          }' | clean_lines
      ;;
    openclaw)
      # JSON over many lines, where a job's own fields come before its
      # schedule's
      have openclaw && openclaw cron list --all --json >"$TMP/jobs" 2>/dev/null || return 1
      tr -d '\r\n' <"$TMP/jobs" | tr '{' '\n' |
        awk -v name="$DAILY_JOB" '
          /"id"[[:space:]]*:/ {
            if (found) exit
            if ($0 !~ ("\"name\"[[:space:]]*:[[:space:]]*\"" name "\"")) next
            found = 1
            id = $0
            sub(/.*"id"[[:space:]]*:[[:space:]]*"/, "", id)
            sub(/".*/, "", id)
            state = ($0 ~ /"enabled"[[:space:]]*:[[:space:]]*false/) ? "off" : "on"
            next
          }
          found && when == "" && /"expr"[[:space:]]*:[[:space:]]*"[0-9]+ [0-9]+ \* \* \*"/ {
            expr = $0
            sub(/.*"expr"[[:space:]]*:[[:space:]]*"/, "", expr)
            split(expr, part, " ")
            if (part[1] < 60 && part[2] < 24) when = sprintf(" %02d:%02d", part[2], part[1])
          }
          END { if (found && id != "") print id, state when }' | clean_lines
      ;;
    *) return 1 ;;
  esac
}

# The daily job this computer last heard of from its app's scheduler: its id,
# then its time when that's known. The sync's own reports read this rather
# than ask the scheduler, as OpenClaw's gateway can't answer while it waits
# for its own hook.
saved_daily_job() { head -n 1 "$APP_DIR/daily-job" 2>/dev/null | tr -cd 'A-Za-z0-9._:@/ -' | cut -c 1-210; }

# Asks the scheduler, as list_daily_job does, and keeps what it says of a job
# that's on. When the scheduler can't be asked, what's kept stays.
check_daily_job() {
  cj=$(list_daily_job) || return 1
  cj_id=${cj%% *}
  cj_time=
  case $cj in
    "$cj_id on "[0-2][0-9]:[0-5][0-9]) cj_time=${cj##* } ;;
    "$cj_id on") cj_time=$(saved_daily_job | awk -v id="$cj_id" '$1 == id { print $2 }') ;;
    *) cj_id= ;;
  esac
  if [ -z "$cj_id" ]; then
    rm -f "$APP_DIR/daily-job"
  elif [ -d "$APP_DIR" ]; then
    printf '%s%s\n' "$cj_id" "${cj_time:+ $cj_time}" >"$APP_DIR/daily-job"
  fi
  printf '%s' "$cj"
}

# What to say of a daily job that's there but doesn't run
job_off() {
  if [ "$HARNESS" = hermes ]; then
    printf "Hermes's daily job, %s, is paused or turned off, so it doesn't run. To run it again: hermes cron resume %s" "$1" "$1"
  else
    printf "OpenClaw's daily job, %s, is turned off, so it doesn't run. To turn it back on: openclaw cron enable %s" "$1" "$1"
  fi
}

# The plan's step for the daily job, which needs the person's yes of its own
PLAN_JOB=0
daily_job_plan() {
  case $HARNESS in
    hermes | openclaw) ;;
    *) return 0 ;;
  esac
  dp=$(list_daily_job) || dp=
  case $dp in
    *" on"*) printf '\nDaily job: %s already runs the sync once a day, as job %s.\n' "$APP_NAME" "${dp%% *}" ;;
    ?*) printf '\nDaily job: %s\n' "$(job_off "${dp%% *}")" ;;
    *)
      PLAN_JOB=1
      printf '\nDaily job: so %s keeps up between sessions, it can also run the sync once a day at 09:%s, from its own scheduler, with no model call. It stays quiet when the sync works, and says so when it fails. Ask the person, and only if they say yes, run:\n\n    %s daily-job %s\n' "$APP_NAME" "$(job_minute)" "$RUN" "$HARNESS"
      ;;
  esac
}

# What this app has set up to run the sync, as Context Locker's report has
# it: its hooks' events, once its hooks are in place, and its daily job
schedule_report() {
  sr_events=
  case $HARNESS in
    claude-code) hook_in "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json" && sr_events=$(hook_events claude-code) ;;
    codex)
      sr_dir=${CODEX_HOME:-$HOME/.codex}
      { hook_in "$sr_dir/hooks.json" || hook_in "$sr_dir/config.toml"; } && sr_events=$(hook_events codex)
      ;;
    hermes) hermes_hooks_in "$(root_dir hermes)/config.yaml" && sr_events=$(hook_events hermes) ;;
    openclaw) openclaw_hook_in && sr_events=$(hook_events openclaw) ;;
  esac
  printf 'hooks%s\n' "${sr_events:+ $sr_events}"
  case $HARNESS in
    claude-code | codex) printf 'job unsupported\n' ;;
    *)
      sr_job=$(saved_daily_job)
      sr_id=$(printf '%s' "${sr_job%% *}" | cut -c 1-200)
      if [ -z "$sr_id" ]; then
        printf 'job none\n'
      else
        sr_time=
        case $sr_job in *" "[0-2][0-9]:[0-5][0-9]) sr_time=${sr_job##* } ;; esac
        printf 'job daily %s%s\n' "$sr_id" "${sr_time:+ $sr_time $(time_zone)}"
      fi
      ;;
  esac
}

# Tells Context Locker how this app runs the sync, so its connection's page
# can say: what's set up, the last scheduled run that failed, and with ran,
# that this run its daily job started worked. A sync tells it when that
# changed, when it hasn't for a day, or when a failure waits to be told; the
# doctor, adding the daily job, and the end of a daily run always do.
report_schedule() {
  rs_why=${1:-check}
  rs_sent=$APP_DIR/schedule-sent
  schedule_report >"$TMP/schedule"
  if [ "$rs_why" = check ] && [ -f "$rs_sent" ] && [ ! -f "$APP_DIR/schedule-failed" ] &&
    [ "$(sha_file "$TMP/schedule")" = "$(sha_file "$rs_sent")" ] &&
    [ -z "$(find "$rs_sent" -mmin +1440 2>/dev/null)" ]; then
    return 0
  fi
  cp "$TMP/schedule" "$TMP/schedule-body"
  [ -f "$APP_DIR/schedule-failed" ] && head -n 1 "$APP_DIR/schedule-failed" >>"$TMP/schedule-body"
  [ "$rs_why" = ran ] && printf 'ran\n' >>"$TMP/schedule-body"
  rs_code=$(status_of "$(http POST /v1/sync/schedule "$TMP/schedule-reply" "$TMP/schedule-body" text/plain)")
  case $rs_code in
    200)
      cp "$TMP/schedule" "$rs_sent"
      rm -f "$APP_DIR/schedule-failed"
      ;;
    # Out of reach or a passing fault: the next sync tries again
    000 | 5??) ;;
    # Refused, as by a Context Locker older than this: tomorrow's sync tries
    # again, or one after what's set up changes
    *) cp "$TMP/schedule" "$rs_sent" ;;
  esac
  return 0
}

# A daily run that failed, kept to tell Context Locker when it can: when it
# failed, and the first thing it said
note_failed_run() {
  nf_said=$(head -n 1 "$TMP/warnings" 2>/dev/null | sed 's/^Context Locker: //' | clean_lines | cut -c 1-400)
  [ -n "$nf_said" ] || nf_said="The sync didn't finish."
  printf 'failed %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$nf_said" >"$APP_DIR/schedule-failed"
}

# Adds the daily job to Hermes's or OpenClaw's own scheduler, as the person
# said yes to, once: a job that's there already stays as it is
daily_job_mode() {
  case $HARNESS in
    claude-code | codex)
      printf "Context Locker: %s can't run a job in the background, so it syncs on its hooks' events: when a session starts, resumes or is cleared, and when it's compacted.\n" "$APP_NAME" >&2
      return 1
      ;;
  esac
  if ! have "$HARNESS"; then
    printf "Context Locker: the %s command isn't on this account's PATH, so the daily job wasn't added.\n" "$HARNESS" >&2
    return 1
  fi
  if ! dm=$(check_daily_job); then
    dm_gateway=
    [ "$HARNESS" = openclaw ] && dm_gateway=" Is its gateway running?"
    printf "Context Locker: couldn't list %s's jobs, so the daily job wasn't added, as it may be there already.%s\n" "$APP_NAME" "$dm_gateway" >&2
    return 1
  fi
  case $dm in
    *" on"*)
      printf '%s already runs the sync once a day, as job %s.\n' "$APP_NAME" "${dm%% *}"
      report_schedule now
      return 0
      ;;
    ?*)
      printf 'Context Locker: %s\n' "$(job_off "${dm%% *}")" >&2
      return 1
      ;;
  esac
  dm_minute=$(job_minute)
  # The scheduler's minute has no leading zero
  dm_cron="${dm_minute#0} 9 * * *"
  if [ "$HARNESS" = hermes ]; then
    # Hermes runs a script from its own scripts folder, so the job runs one
    # there that runs this one
    dm_scripts=$(root_dir hermes)/scripts
    if ! mkdir -p "$dm_scripts" || ! printf '#!/bin/sh\nexec %s hermes --daily\n' "$RUN" >"$dm_scripts/contextlocker-sync.sh"; then
      printf "Context Locker: couldn't write %s/contextlocker-sync.sh, so the daily job wasn't added.\n" "$dm_scripts" >&2
      return 1
    fi
    hermes cron create "$dm_cron" --no-agent --script contextlocker-sync.sh --name "$DAILY_JOB" --deliver origin >"$TMP/job-added" 2>&1
  else
    openclaw cron add --name "$DAILY_JOB" --cron "$dm_cron" --command "$RUN openclaw --daily" >"$TMP/job-added" 2>&1
  fi
  dm_added=$?
  dm=$(check_daily_job) || dm=
  case $dm in
    *" on"*) ;;
    *)
      dm_said=$(tr -d '\033' <"$TMP/job-added" | sed 's/\[[0-9;]*m//g' | clean_lines | grep -v '^[[:space:]]*$' | head -n 3 | awk '{ $1 = $1; printf "%s%s", (NR > 1 ? " " : ""), $0 }')
      if [ "$dm_added" != 0 ]; then
        printf "Context Locker: %s didn't add the daily job%s\n" "$APP_NAME" "${dm_said:+: $dm_said}" >&2
      else
        printf "Context Locker: %s said it added the daily job, but doesn't list it. Check with: %s cron list\n" "$APP_NAME" "$HARNESS" >&2
      fi
      return 1
      ;;
  esac
  dm_id=${dm%% *}
  # A job setup made runs at the time it gave it
  grep -q ' [0-2][0-9]:[0-5][0-9]$' "$APP_DIR/daily-job" 2>/dev/null ||
    printf '%s 09:%s\n' "$dm_id" "$dm_minute" >"$APP_DIR/daily-job"
  report_schedule now
  printf '%s runs the sync once a day now, at 09:%s (%s), as job %s, with no model call. It stays quiet when the sync works, and says so when it fails. To stop it: %s cron remove %s\n' \
    "$APP_NAME" "$dm_minute" "$(time_zone | tr '_' ' ')" "$dm_id" "$HARNESS" "$dm_id"
}

# What's already there that setup leaves alone
existing_files() {
  found=0
  case $HARNESS in
    claude-code)
      root=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
      if [ -f "$root/CLAUDE.md" ]; then
        printf -- '- Your own instructions in %s. Claude Code reads them as well as Context Locker'"'"'s file.\n' "$root/CLAUDE.md"
        found=1
      fi
      skills_root=$root/skills
      ;;
    codex)
      root=${CODEX_HOME:-$HOME/.codex}
      if [ -f "$root/AGENTS.override.md" ] && grep -q '[^[:space:]]' "$root/AGENTS.override.md"; then
        printf -- '- %s, which Codex reads instead of AGENTS.md, so Context Locker'"'"'s block goes there.\n' "$root/AGENTS.override.md"
        found=1
      fi
      skills_root=$HOME/.agents/skills
      ;;
    hermes) skills_root=$(root_dir hermes)/skills ;;
    openclaw) skills_root=$HOME/.agents/skills ;;
  esac
  own=0
  for d in "$skills_root"/*/; do
    [ -f "${d}SKILL.md" ] && [ ! -f "${d}.ctx-managed" ] && own=$((own + 1))
  done
  if [ "$own" -gt 0 ]; then
    printf -- '- %s of your own in %s.\n' "$(plural "$own" skill skills)" "$skills_root"
    found=1
  fi
  [ "$found" = 1 ] || printf -- '- Nothing.\n'
}

plan() {
  : >"$TMP/plan-out"
  if ! sync_scope '' "$APP_DIR/global"; then
    cat "$TMP/warnings" >&2
    return 1
  fi
  printf 'Setup plan for %s on this computer. Nothing has changed yet.\n\nFiles:\n' "$APP_NAME"
  sed 's/^/- /' "$TMP/plan-out"
  printf '\n'
  hook_plan
  daily_job_plan
  printf '\nAlready here, and left as it is:\n'
  existing_files
  printf '\nIf this looks right, approve it once. Then:\n'
  [ -f "$INSTALLED" ] || printf -- '- Save this script as %s.\n' "$INSTALLED"
  printf -- '- Write the files: %s %s\n' "$RUN" "$HARNESS"
  printf -- '- Add the %s shown above.\n' "$TRIGGER"
  [ "$PLAN_JOB" = 1 ] && printf -- '- Only if the person said yes to the daily job, add it: %s daily-job %s\n' "$RUN" "$HARNESS"
  printf -- '- Check everything: %s doctor %s\n' "$RUN" "$HARNESS"
}

# "2026-10-18T09:05:00Z" as "18 Oct 2026 at 09:05 UTC"
nice_time() {
  case $1 in
    [0-9][0-9][0-9][0-9]-[01][0-9]-[0-3][0-9]T[0-2][0-9]:[0-5][0-9]*) ;;
    *)
      printf '%s' "$1"
      return 0
      ;;
  esac
  year=${1%%-*}
  rest=${1#*-}
  month=${rest%%-*}
  month=${month#0}
  rest=${rest#*-}
  day=${rest%%T*}
  clock=${rest#*T}
  if [ "$month" -lt 1 ] || [ "$month" -gt 12 ]; then
    printf '%s' "$1"
    return 0
  fi
  set -- Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec
  shift $((month - 1))
  printf '%s %s %s at %s UTC' "${day#0}" "$1" "$year" "$(printf '%s' "$clock" | cut -c 1-5)"
}

# --- The doctor's checks: caps, unmanaged files and drift ----------------------

# Days without a sync before the doctor says the hook or job may not be running
DRIFT_DAYS=7

# Seconds since 1970 for a UTC time such as 2026-10-18T09:05:00Z, worked out
# by hand, as date can't read a time the same way on every system
utc_seconds() {
  case $1 in
    [0-9][0-9][0-9][0-9]-[01][0-9]-[0-3][0-9]T[0-2][0-9]:[0-5][0-9]:[0-5][0-9]*) ;;
    *) return 1 ;;
  esac
  us_y=${1%%-*}
  us_rest=${1#*-}
  us_m=${us_rest%%-*}
  us_rest=${us_rest#*-}
  us_d=${us_rest%%T*}
  us_rest=${us_rest#*T}
  us_h=${us_rest%%:*}
  us_rest=${us_rest#*:}
  us_min=${us_rest%%:*}
  us_s=$(printf '%s' "${us_rest#*:}" | cut -c 1-2)
  # A leading zero would make a number octal
  us_m=${us_m#0} us_d=${us_d#0} us_h=${us_h#0} us_min=${us_min#0} us_s=${us_s#0}
  # Days from 1970-01-01, by the civil calendar's 400-year cycle
  [ "$us_m" -le 2 ] && us_y=$((us_y - 1))
  us_era=$((us_y / 400))
  us_yoe=$((us_y - us_era * 400))
  if [ "$us_m" -gt 2 ]; then us_mp=$((us_m - 3)); else us_mp=$((us_m + 9)); fi
  us_doy=$(((153 * us_mp + 2) / 5 + us_d - 1))
  us_doe=$((us_yoe * 365 + us_yoe / 4 - us_yoe / 100 + us_doy))
  printf '%s' $(((us_era * 146097 + us_doe - 719468) * 86400 + us_h * 3600 + us_min * 60 + us_s))
}

# What's in a managed skill's folder now: its marker's hash, while nothing in
# it is newer than the marker, or else the hash of its files
skill_now() {
  sn_marked=$(sed -n "3s/^\($HASH\)\$/\1/p" "$1/.ctx-managed" 2>/dev/null)
  if [ -n "$sn_marked" ] && [ "$sn_marked" = "$2" ] &&
    [ -z "$(find "$1" -newer "$1/.ctx-managed" 2>/dev/null | head -n 1)" ]; then
    printf '%s' "$sn_marked"
  else
    tree_hash "$1"
  fi
}

# Checks what a lockfile says the last sync wrote: each block and skill as it
# was written, or with an edit that waits for approval, one Context Locker
# couldn't take, or one not yet saved in Context Locker, or gone
lock_doctor() {
  ld_lock=$1 ld_where=$2
  grep '^wrote ' "$ld_lock" 2>/dev/null >"$TMP/wrote-lines"
  sed -n 's/^entry hold //p' "$ld_lock" >"$TMP/held-lines"
  sed -n 's/^refused //p' "$ld_lock" >"$TMP/refused-lines"
  ld_blocks=0 ld_skills=0
  while read -r _ ld_kind ld_hash ld_t; do
    ld_path=$(resolve "$ld_t") || continue
    case $ld_t in
      '{project}/'*)
        if ! inside_project "$ld_t"; then
          check_warn "Part of the path to $ld_path is a link, so syncs leave it alone."
          continue
        fi
        ;;
    esac
    if [ "$ld_kind" = skill ]; then
      if [ ! -f "$ld_path/.ctx-managed" ]; then
        check_warn "The skill at $ld_path is missing. The next sync adds it again."
        continue
      fi
      ld_now=$(skill_now "$ld_path" "$ld_hash")
      ld_what="the skill ${ld_t##*/} at $ld_path"
    else
      if [ ! -f "$ld_path" ]; then
        check_warn "$ld_path is missing. The next sync writes it again."
        continue
      fi
      ld_pos=$(block_position "$ld_path")
      case $ld_pos in
        none)
          check_warn "Context Locker's block is missing from $ld_path. The next sync adds it again."
          continue
          ;;
        broken)
          check_fail "The Context Locker markers in $ld_path don't pair up, so syncs leave the file alone until someone fixes it by hand."
          continue
          ;;
      esac
      ld_now=$(block_lines "$ld_path" "${ld_pos% *}" "${ld_pos#* }" | sha_stdin)
      ld_what="Context Locker's block in $ld_path"
    fi
    if [ "$ld_now" = "$ld_hash" ]; then
      if [ "$ld_kind" = skill ]; then ld_skills=$((ld_skills + 1)); else ld_blocks=$((ld_blocks + 1)); fi
    elif grep -qxF "$ld_now $ld_t" "$TMP/held-lines"; then
      check_pass "Your edit to $ld_what is saved in Context Locker, and waits for approval in its inbox."
    elif grep -qxF "$ld_now $ld_t" "$TMP/refused-lines"; then
      check_warn "Context Locker couldn't take the edit to $ld_what, so it won't update until the edit is undone or fixed."
    else
      check_warn "$(printf '%s' "$ld_what" | sed 's/^t/T/') has an edit that isn't saved in Context Locker yet. The next sync sends it."
    fi
  done <"$TMP/wrote-lines"
  if [ "$ld_skills" -gt 0 ]; then
    check_pass "$(plural "$ld_blocks" block blocks) and $(plural "$ld_skills" skill skills) in place$ld_where."
  elif [ "$ld_blocks" -gt 0 ]; then
    check_pass "$(plural "$ld_blocks" block blocks) in place$ld_where."
  fi
}

# How full each of the playbook's limits is, as Context Locker says: a PASS,
# WARN or FAIL line for each
caps_doctor() {
  code=$(status_of "$(http GET /v1/sync/caps "$TMP/caps" '' '' '' '' '')")
  if [ "$code" != 200 ] || [ "$(head -n 1 "$TMP/caps" | tr -d '\r')" != 'context-locker-caps 1' ]; then
    check_warn "Couldn't check how full your playbook's limits are: Context Locker answered $code."
    return 0
  fi
  tail -n +2 "$TMP/caps" | tr -d '\r' >"$TMP/caps-lines"
  while IFS= read -r cd_line; do
    cd_text=$(printf '%s' "${cd_line#????  }" | clean)
    [ -n "$cd_text" ] || continue
    case $cd_line in
      'PASS  '?*) check_pass "$cd_text" ;;
      'WARN  '?*) check_warn "$cd_text" ;;
      'FAIL  '?*) check_fail "$cd_text" ;;
    esac
  done <"$TMP/caps-lines"
}

# How many lines of a file that aren't blank sit outside Context Locker's blocks
lines_outside() {
  awk '
    /^<!-- context-locker:start( v[0-9]+)? -->[ \t\r]*$/ { inside = 1; next }
    /^<!-- context-locker:end -->[ \t\r]*$/ { inside = 0; next }
    !inside && /[^ \t\r]/ { lines++ }
    END { print lines + 0 }' "$1" 2>/dev/null
}

# An instruction or memory file with lines Context Locker doesn't manage: a
# warning with where it is, how many lines, and how to bring them in. A link
# isn't followed, as Gather doesn't follow one.
unmanaged_file() {
  [ -f "$1" ] && [ ! -L "$1" ] && [ ! -L "${1%/*}" ] || return 0
  uf_lines=$(lines_outside "$1")
  case $uf_lines in '' | 0 | *[!0-9]*) return 0 ;; esac
  check_warn "$(home_path "$1" | clean) has $(plural "$uf_lines" line lines) outside Context Locker's block. To bring them into your playbook, run Import: $RUN gather $HARNESS"
}

# A folder of memories, such as Codex's: one warning for the lines its text
# files hold outside Context Locker, and how many files hold them. Hidden
# files and links are left out.
unmanaged_folder() {
  ufo_name=$1 ufo_shown=$2 ufo_depth=$3
  shift 3
  ufo_files=0 ufo_lines=0
  for ufo_dir in "$@"; do
    [ -d "$ufo_dir" ] && [ ! -L "$ufo_dir" ] || continue
    (cd "$ufo_dir" 2>/dev/null && find . -maxdepth "$ufo_depth" \( ! -name . -name '.*' \) -prune -o \
      -type f \( -name '*.md' -o -name '*.markdown' -o -name '*.mdx' -o -name '*.mdc' -o -name '*.txt' \) -print) \
      >"$TMP/unmanaged-files"
    while IFS= read -r ufo_rel; do
      ufo_count=$(lines_outside "$ufo_dir/${ufo_rel#./}")
      case $ufo_count in '' | 0 | *[!0-9]*) continue ;; esac
      ufo_files=$((ufo_files + 1))
      ufo_lines=$((ufo_lines + ufo_count))
    done <"$TMP/unmanaged-files"
  done
  [ "$ufo_lines" -gt 0 ] || return 0
  check_warn "$ufo_name, in $(home_path "$ufo_shown" | clean), $(plural "$ufo_files" 'file holds' 'files hold') $(plural "$ufo_lines" line lines) outside Context Locker. To bring them into your playbook, run Import: $RUN gather $HARNESS"
}

# This app's instruction and memory files with lines outside Context
# Locker's blocks, and instruction files in the project's top folder that it
# doesn't manage, which Gather can bring into the playbook
unmanaged_doctor() {
  case $HARNESS in
    claude-code)
      ud_root=$(root_dir claude)
      unmanaged_file "$ud_root/CLAUDE.md"
      if [ -d "$ud_root/rules" ] && [ ! -L "$ud_root/rules" ]; then
        (cd "$ud_root/rules" 2>/dev/null && find . -maxdepth 4 \( ! -name . -name '.*' \) -prune -o \
          -type f \( -name '*.md' -o -name '*.mdc' -o -name '*.txt' \) -print) | sed 's|^\./||' | LC_ALL=C sort >"$TMP/rule-files"
        while IFS= read -r ud_rule; do
          unmanaged_file "$ud_root/rules/$ud_rule"
        done <"$TMP/rule-files"
      fi
      set --
      if [ -d "$ud_root/projects" ] && [ ! -L "$ud_root/projects" ]; then
        for ud_memory in "$ud_root/projects"/*/memory; do
          [ -d "$ud_memory" ] && [ ! -L "${ud_memory%/memory}" ] && set -- "$@" "$ud_memory"
        done
      fi
      [ $# -gt 0 ] && unmanaged_folder "Claude Code's memory" "$ud_root/projects" 3 "$@"
      ;;
    codex)
      ud_root=$(root_dir codex)
      unmanaged_file "$ud_root/AGENTS.md"
      unmanaged_file "$ud_root/AGENTS.override.md"
      unmanaged_folder "Codex's memories" "$ud_root/memories" 3 "$ud_root/memories"
      ;;
    hermes)
      ud_root=$(root_dir hermes)
      for ud_name in SOUL.md USER.md MEMORY.md; do unmanaged_file "$ud_root/$ud_name"; done
      unmanaged_folder "Hermes's memories" "$ud_root/memories" 1 "$ud_root/memories"
      ;;
    openclaw)
      ud_root=$(root_dir openclaw)
      for ud_name in AGENTS.md SOUL.md IDENTITY.md USER.md MEMORY.md; do unmanaged_file "$ud_root/$ud_name"; done
      unmanaged_folder "OpenClaw's daily memory logs" "$ud_root/memory" 2 "$ud_root/memory"
      ;;
  esac
  # The project's top folder: the project this folder is in, or the top of
  # its git work tree, but never the home folder
  ud_project=$PROJECT_ROOT
  [ -n "$ud_project" ] || ud_project=$(git_top "$START") || ud_project=$START
  case $ud_project in '' | / | "$HOME") return 0 ;; esac
  for ud_name in AGENTS.md AGENTS.override.md CLAUDE.md CLAUDE.local.md .claude/CLAUDE.md; do
    unmanaged_file "$ud_project/$ud_name"
  done
}

doctor() {
  fails=0 warns=0 auto_off=0
  check_pass() { printf 'PASS  %s\n' "$*"; }
  check_warn() {
    printf 'WARN  %s\n' "$*"
    warns=$((warns + 1))
  }
  check_fail() {
    printf 'FAIL  %s\n' "$*"
    fails=$((fails + 1))
  }

  if [ ! -f "$INSTALLED" ]; then
    check_fail "The sync script isn't at $INSTALLED, where the $TRIGGER $TRIGGER_RUNS it. Save it there."
  else
    installed=$(sed -n 's/^SCRIPT_VERSION=\([0-9]*\)$/\1/p' "$INSTALLED" | head -n 1)
    if [ "$installed" = "$SCRIPT_VERSION" ]; then
      check_pass "The sync script is at $INSTALLED."
    else
      check_warn "The sync script at $INSTALLED is version ${installed:-unknown}, and this one is version $SCRIPT_VERSION."
    fi
  fi
  newer_script &&
    check_warn "A newer version of the sync script is out. When it suits you, set Context Locker up again from context.locker/setup. This one keeps working until then."

  connected=0
  if problem=$(token_problem); then
    check_fail "$problem Run: $RUN signin $HARNESS"
  else
    perms=$(ls -l "$APP_DIR/token" 2>/dev/null | cut -c 5-10)
    [ "$perms" = ------ ] ||
      check_warn "Other accounts on this computer can read $APP_DIR/token. Run: chmod 600 $(shell_quote "$APP_DIR/token")"
    code=$(status_of "$(http GET /v1/agent "$TMP/agent" '' '' '' '' '')")
    case $code in
      200)
        connected=1
        check_pass "Connected: $(connected_as)."
        ;;
      401) check_fail "This computer's connection was revoked or has expired. Run: $RUN signin $HARNESS" ;;
      000) check_fail "Can't reach Context Locker at $API." ;;
      *) check_fail "Context Locker answered $code when asked about this connection." ;;
    esac
  fi

  # How full the playbook's limits are, from Context Locker
  [ "$connected" = 1 ] && caps_doctor

  lock=$APP_DIR/global.lock
  if ! grep -q '^synced ' "$lock" 2>/dev/null; then
    check_fail "Nothing has synced yet. Run: $RUN $HARNESS"
  else
    synced_at=$(sed -n 's/^synced //p' "$lock" | head -n 1)
    synced=$(nice_time "$synced_at")
    etag=$(sed -n "s/^etag \\($HASH\\)\$/\\1/p" "$lock" | head -n 1)
    if [ -z "$etag" ]; then
      check_warn "The last sync didn't finish ($synced). The next one tries again."
    elif [ "$connected" = 1 ]; then
      code=$(status_of "$(http GET /v1/sync "$TMP/manifest" '' '' "$etag" '' '')")
      case $code in
        304) check_pass "The files match your playbook. Last synced $synced." ;;
        200)
          if grep -qx 'auto-sync off' "$TMP/manifest" && files_change "$TMP/manifest" "$lock" >/dev/null; then
            auto_off=1
            check_warn "Your playbook has changed since the last sync ($synced). Auto sync is off, so the files stay as they are until a sync with --now: $RUN $HARNESS --now"
          else
            check_warn "Your playbook has changed since the last sync ($synced). The next sync brings the files up to date."
          fi
          ;;
        *) check_warn "Couldn't compare the files with your playbook: Context Locker answered $code." ;;
      esac
    fi
    # A sync more than 7 days ago means the hooks aren't running, unless
    # auto sync is off and changes are waiting
    if [ "$auto_off" = 0 ] && then_at=$(utc_seconds "$synced_at") && now_at=$(utc_seconds "$(date -u +%Y-%m-%dT%H:%M:%SZ)") &&
      [ $((now_at - then_at)) -gt $((DRIFT_DAYS * 86400)) ]; then
      check_warn "The last sync was on $synced, $(plural $(((now_at - then_at) / 86400)) 'day ago' 'days ago'). Check that the $TRIGGER $TRIGGER_RUNS, or sync now: $RUN $HARNESS --now"
    fi
    lock_doctor "$lock" ""
  fi

  project_doctor
  linked_doctor
  unmanaged_doctor

  case $HARNESS in
    claude-code)
      settings=${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json
      if hook_in "$settings"; then
        check_pass "The session-start hook is in $settings."
      else
        check_fail "The session-start hook isn't in $settings. Run: $RUN plan $HARNESS, and add the hook it shows."
      fi
      ;;
    codex)
      dir=${CODEX_HOME:-$HOME/.codex}
      if hook_in "$dir/hooks.json" || hook_in "$dir/config.toml"; then
        check_pass "The session-start hook is set up in $dir. Codex runs it once you've trusted it in /hooks."
      else
        check_fail "The session-start hook isn't in $dir/hooks.json. Run: $RUN plan $HARNESS, and add the hook it shows."
      fi
      ;;
    hermes)
      config=$(root_dir hermes)/config.yaml
      if hermes_hooks_in "$config"; then
        check_pass "Hermes runs the sync when a session starts and after compaction, from $config."
        # Hermes runs a hook only once it's approved, in its allowlist or by
        # hooks_auto_accept
        allowlist=$(root_dir hermes)/shell-hooks-allowlist.json
        if ! grep -Eq 'contextlocker[/\\]+sync\.(sh|ps1)' "$allowlist" 2>/dev/null &&
          ! grep -Eq '^hooks_auto_accept:[[:space:]]*true' "$config" 2>/dev/null; then
          check_warn "Hermes hasn't approved the hooks yet, so they don't run. Start a hermes chat and approve them when it asks, then check with: hermes hooks list"
        fi
      else
        check_fail "Hermes's hooks don't run the sync. Run: $RUN plan $HARNESS, and add the hooks it shows to $config."
      fi
      ;;
    openclaw)
      if openclaw_hook_in; then
        check_pass "OpenClaw's hook runs the sync, from $OPENCLAW_HOOK."
        # OpenClaw says whether it's turned on, when it can be asked
        have openclaw && openclaw hooks info context-locker-sync --json 2>/dev/null |
          grep -Eq '"enabled"[[:space:]]*:[[:space:]]*false' &&
          check_warn "OpenClaw's hook isn't turned on, so it doesn't run. Run: openclaw hooks enable context-locker-sync"
      else
        check_fail "OpenClaw's hook doesn't run the sync. Run: $RUN plan $HARNESS, and save the hook it shows in $OPENCLAW_HOOK."
      fi
      ;;
  esac

  # The daily job, which Hermes's and OpenClaw's schedulers can run
  case $HARNESS in
    hermes | openclaw)
      if dj=$(check_daily_job); then
        case $dj in
          *" on"*)
            dj_time=$(saved_daily_job | awk '{ print $2 }')
            check_pass "$APP_NAME runs the sync once a day${dj_time:+ at $dj_time}, as job ${dj%% *} in its scheduler."
            [ "$HARNESS" = hermes ] && grep -q 'Scheduler is not ready' "$TMP/jobs" 2>/dev/null &&
              check_warn "Hermes says its scheduler isn't running, so the daily job doesn't run. Check with: hermes cron status"
            ;;
          ?*) check_warn "$(job_off "${dj%% *}")" ;;
          *) check_pass "$APP_NAME syncs on its hooks' events, with no daily job. For one, ask the person, and only if they say yes, run: $RUN daily-job $HARNESS" ;;
        esac
      elif [ -f "$APP_DIR/daily-job" ]; then
        dj_gateway=
        [ "$HARNESS" = openclaw ] && dj_gateway=" Is its gateway running?"
        check_warn "Couldn't ask $APP_NAME's scheduler about its daily job, $(saved_daily_job | awk '{ print $1 }').$dj_gateway"
      fi
      ;;
  esac

  # How this app runs the sync, for its connection's page
  [ "$connected" = 1 ] && report_schedule now

  # One line to sum it up, and exit 1 when something failed
  if [ "$fails" -gt 0 ]; then
    if [ "$warns" -gt 0 ]; then
      printf '\n%s to fix, and %s.\n' "$(plural "$fails" problem problems)" "$(plural "$warns" warning warnings)"
    else
      printf '\n%s to fix.\n' "$(plural "$fails" problem problems)"
    fi
    return 1
  fi
  if [ "$warns" -gt 0 ]; then
    printf '\nWorking, with %s.\n' "$(plural "$warns" warning warnings)"
  else
    printf '\nAll checks passed.\n'
  fi
  return 0
}

# Folders linked on this computer that aren't there any more, which syncs
# skip, counted in a line
linked_doctor() {
  [ "$HARNESS" = openclaw ] && return 0
  [ -f "$CL_HOME/projects" ] || return 0
  ld_gone=0
  while IFS= read -r ld_line; do
    ld_folder=${ld_line#* }
    case $ld_folder in /*) [ -d "$ld_folder" ] || ld_gone=$((ld_gone + 1)) ;; esac
  done <"$CL_HOME/projects"
  [ "$ld_gone" -gt 0 ] || return 0
  check_warn "$(plural "$ld_gone" 'folder linked on this computer is' 'folders linked on this computer are') gone, so syncs skip them. If one moved, link it again from its new place with --project."
}

# The project this folder belongs to: what the last sync wrote in its repo,
# as the global sync's files are checked, then its notes folder
project_doctor() {
  WORKSPACE_ID=$(sed -n "s/^entry workspace \\($UUID\\)\$/\\1/p" "$APP_DIR/global.lock" 2>/dev/null | head -n 1)
  detect_project || return 0
  pd_lock=$APP_DIR/projects/$PROJECT_ID.lock
  [ -f "$pd_lock" ] && lock_doctor "$pd_lock" " in $PROJECT_ROOT"
  notes_doctor
}

# The project's notes folder, in a line or two: how many notes it holds, the
# files waiting to be saved or that weren't saved at the last sync, and any
# Context Locker wrote that are missing
notes_doctor() {
  case $HARNESS in
    openclaw) return 0 ;;
    hermes) [ "$LAYER" = repo ] || return 0 ;;
  esac
  nd_where=$PROJECT_ROOT/$NOTES
  if ! notes_folder_ok; then
    check_warn "Part of the path to $nd_where is a link, so syncs leave the notes folder alone."
    return 0
  fi
  notes_records
  if ! grep -q '^wrote ' "$TMP/notes-records"; then
    check_warn "Nothing has synced to $nd_where yet. The next sync in this project writes it."
    return 0
  fi
  notes_scan
  # A recorded note that changed here waits to be saved, as does a new file,
  # unless the last sync couldn't take it as it is now
  awk -v readme="$NOTES_TARGET/README.md" '
    FILENAME == ARGV[1] && $1 == "wrote" { R[$4] = $3; rk[$4] = $2; next }
    FILENAME == ARGV[1] && $1 == "refused" { F[$3] = $2; next }
    FILENAME == ARGV[2] { L[$2] = $1; next }
    END {
      for (t in L) {
        if (t == readme || ((t in R) && rk[t] != "note")) continue
        if (t in R) notes++
        if ((t in R) && L[t] == R[t]) continue
        print ((t in F) && F[t] == L[t] ? "refused" : "waiting"), t
      }
      print "notes", notes + 0
    }' "$TMP/notes-records" "$TMP/notes-local" >"$TMP/notes-doctor"
  while IFS= read -r nd_name; do
    printf 'refused %s/%s\n' "$NOTES_TARGET" "$nd_name" >>"$TMP/notes-doctor"
  done <"$TMP/notes-misnamed"
  check_pass "$nd_where holds $(plural "$(sed -n 's/^notes //p' "$TMP/notes-doctor")" note notes)."
  # What Context Locker wrote there that's gone, which the next sync writes again
  nd_missing=$(awk '
    FILENAME == ARGV[1] && $1 == "wrote" { R[$4] = 1; next }
    FILENAME == ARGV[2] { L[$2] = 1; next }
    END { for (t in R) if (!(t in L)) n++; print n + 0 }' "$TMP/notes-records" "$TMP/notes-local")
  [ "$nd_missing" -gt 0 ] &&
    check_warn "$(plural "$nd_missing" 'file Context Locker wrote in the notes folder is' 'files Context Locker wrote in the notes folder are') missing. The next sync in this project writes them again."
  nd_waiting=$(grep -c '^waiting ' "$TMP/notes-doctor")
  [ "$nd_waiting" -gt 0 ] &&
    check_warn "$(plural "$nd_waiting" 'file in the notes folder waits' 'files in the notes folder wait') to be saved at the next sync."
  nd_refused=$(grep -c '^refused ' "$TMP/notes-doctor")
  if [ "$nd_refused" -gt 0 ]; then
    nd_names=$(sed -n "s|^refused {project}/$NOTES/||p" "$TMP/notes-doctor" | LC_ALL=C sort | head -n 3 |
      awk '{ printf "%s%s", (NR > 1 ? ", " : ""), $0 }')
    [ "$nd_refused" -gt 3 ] && nd_names="$nd_names and $((nd_refused - 3)) more"
    check_warn "$(plural "$nd_refused" "file in the notes folder wasn't" 'files in the notes folder weren'"'"'t') saved at the last sync: $nd_names. A sync in this project says why."
  fi
  return 0
}

readback() {
  grep '^wrote ' "$APP_DIR/global.lock" 2>/dev/null >"$TMP/wrote-lines"
  if [ ! -s "$TMP/wrote-lines" ]; then
    printf 'Nothing has synced to %s on this computer yet.\n' "$APP_NAME"
    return 1
  fi
  printf 'What Context Locker has put in %s'"'"'s files on this computer:\n' "$APP_NAME"
  while read -r _ kind hash t; do
    [ "$kind" = block ] || continue
    path=$(resolve "$t") || continue
    [ -f "$path" ] || continue
    pos=$(block_position "$path")
    case $pos in none | broken) continue ;; esac
    printf '\nIn %s:\n\n' "$path"
    block_lines "$path" "${pos% *}" "${pos#* }" | sed '1d;$d'
  done <"$TMP/wrote-lines"
  grep -q '^wrote skill ' "$TMP/wrote-lines" && printf '\nSkills:\n'
  while read -r _ kind hash t; do
    [ "$kind" = skill ] || continue
    path=$(resolve "$t") || continue
    [ -f "$path/.ctx-managed" ] || continue
    about=$(skill_description "$path/SKILL.md")
    # The version, which an app sends with a change it suggests to the skill
    version=$(awk -v t="$t" '$1 == "entry" && $2 == "skill" && $4 == t { print $6; exit }' "$APP_DIR/global.lock" |
      grep -E '^[0-9]{1,9}$')
    printf -- '- %s%s, in %s%s\n' "${t##*/}" "${version:+ (version $version)}" "$path" "${about:+: $about}"
  done <"$TMP/wrote-lines"
  return 0
}

# A skill's description from its front matter, on one line: a value on the
# description line itself, without quotes around it, or one that runs over
# the lines under it, as description: > or | writes it
skill_description() {
  awk '
    { sub(/\r$/, "") }
    NR == 1 { if ($0 != "---") exit; next }
    /^---[[:space:]]*$/ { exit }
    taking {
      if ($0 ~ /^[[:space:]]*$/) next
      if ($0 !~ /^[[:space:]]/) exit
      line = $0
      sub(/^[[:space:]]+/, "", line)
      text = text (text == "" ? "" : " ") line
      next
    }
    /^description:/ {
      value = $0
      sub(/^description:[[:space:]]*/, "", value)
      sub(/[[:space:]]+$/, "", value)
      if (value == "" || value ~ /^[>|][-+0-9]*$/) { taking = 1; next }
      text = value
      exit
    }
    END {
      if (length(text) >= 2 && (text ~ /^".*"$/ || text ~ /^\047.*\047$/)) text = substr(text, 2, length(text) - 2)
      print text
    }' "$1" 2>/dev/null | head -n 1 | clean
}

# After a command an app runs as it works, such as map: a line when the
# playbook changed the app's files since it last synced, saying to sync now,
# or when it suits with auto sync off, once for each change. The check is
# one small request.
changed_since() {
  cs_etag=$(sed -n "s/^etag \\($HASH\\)\$/\\1/p" "$APP_DIR/global.lock" 2>/dev/null | head -n 1)
  [ -n "$cs_etag" ] || return 0
  cs_code=$(status_of "$(http GET /v1/sync "$TMP/cs-manifest" '' '' "$cs_etag" '' '')")
  [ "$cs_code" = 200 ] || return 0
  cs_new=$(files_change "$TMP/cs-manifest" "$APP_DIR/global.lock") && not_told "$cs_new" "$APP_DIR/global" || return 0
  if grep -qx 'auto-sync off' "$TMP/cs-manifest"; then
    printf "\nContext Locker: the user's playbook changed since this app last synced. Auto sync is off: run \`%s %s --now\` when it suits.\n" "$RUN" "$HARNESS"
  else
    printf "\nContext Locker: the user's playbook changed since this app last synced. Run \`%s %s\` now to bring the changes into its files.\n" "$RUN" "$HARNESS"
  fi
}

# Prints the project's map: its docs home, its Start here entries, the notes
# and pointers that matter in the current folder, or every one with --all,
# and the newest of the rest
map() {
  WORKSPACE_ID=$(sed -n "s/^entry workspace \\($UUID\\)\$/\\1/p" "$APP_DIR/global.lock" 2>/dev/null | head -n 1)
  if ! find_project ask; then
    printf "Context Locker: this folder isn't in a project this computer knows. Link it to one with: %s %s --project <id>\n" "$RUN" "$HARNESS" >&2
    return 1
  fi
  # Where this folder is in the project, unless every entry is wanted
  : >"$TMP/map-path"
  if [ "$ALL" = 0 ]; then
    mp_here=$(cd -P "$PWD" 2>/dev/null && pwd -P)
    mp_root=$(cd -P "$PROJECT_ROOT" 2>/dev/null && pwd -P)
    case $mp_here in
      "$mp_root"/?*)
        mp_rel=${mp_here#"$mp_root"/}
        case $mp_rel in *[\\\<\>]*) ;; *) printf '%s' "$mp_rel" | clean >"$TMP/map-path" ;; esac
        ;;
    esac
  fi
  code=$(status_of "$(http POST "/v1/sync/map?project=$PROJECT_ID&layer=$LAYER" "$TMP/map" "$TMP/map-path" text/plain '' '' '')")
  case $code in
    200)
      # Tabs and line breaks stay; other control characters never show
      tr -d '\000-\010\013-\037\177' <"$TMP/map"
      changed_since
      return 0
      ;;
    401) printf "Context Locker: this computer's connection for %s was revoked or has expired. Set it up again at context.locker/setup.\n" "$APP_NAME" >&2 ;;
    404) printf "Context Locker: that project isn't in your playbook any more.\n" >&2 ;;
    000) printf "Context Locker: can't reach %s, so there's no map to show.\n" "$API" >&2 ;;
    *) printf 'Context Locker answered %s, so there is no map to show. Try again in a minute.\n' "$code" >&2 ;;
  esac
  return 1
}

# --- Gather: what the AI apps on this computer already know -------------------

# gather copies the instructions, skills and memories of every AI app on this
# computer into a working set of its own, ~/.contextlocker/gather/<UTC time>,
# which only this account can read, for the Gather skill to sort into one
# plan. It only reads the apps' files, never changes or deletes them, and
# follows no link in an app's folder or the project. A folder that is itself a
# link, as a dotfiles setup may make ~/.claude, is read where it points, as the
# app reads it. It cuts Context Locker's own blocks from the copies, skips its
# skills and the notes folders, and leaves out what isn't text, files over
# 4 MB, everything past 64 MB in all, and anything that looks like a secret,
# which is never copied. Each is listed with why, every link it didn't follow
# among them. Nothing leaves the computer: gather-submit sends the plan once
# the person approves it, and then deletes Gather's working sets, as they hold
# copies of the apps' memories. Each gather also deletes its working sets older
# than 7 days, and keeps at most its newest 3. Only Gather's own are deleted.
GATHER_FILE_MOST=4194304
# What one plan holds, so a working set fits in one. A test sets a smaller one
GATHER_MOST=67108864
case ${CONTEXT_LOCKER_GATHER_MOST:-} in
  '' | *[!0-9]*) ;;
  *) GATHER_MOST=$CONTEXT_LOCKER_GATHER_MOST ;;
esac
GATHER_KEEP=3
# Days a working set is kept, at most
GATHER_DAYS=7
GATHER_MARK='context-locker-gather 1'
G_LINK="it's a link, and Import doesn't follow links"

# A path as people read it, with ~ for the home folder
# --- Tidy-up ---------------------------------------------------------------

# fix prints Tidy-up, as Context Locker words it for this app: the project's
# items and the ones that apply everywhere, or the whole playbook's with --all
# or outside a project. --done and --skip mark one item, and print what
# Context Locker said.
fix_mode() {
  if [ -n "$FIX_AS" ]; then
    if [ "$FIX_AS" = done ]; then
      printf 'done\n' >"$TMP/fix-body"
    else
      printf 'skipped\n%s\n' "$REASON" >"$TMP/fix-body"
    fi
    code=$(status_of "$(http POST "/v1/sync/fixes/$FIX_ID" "$TMP/fix" "$TMP/fix-body" 'text/plain; charset=utf-8' '' '' '')")
  else
    fx_query=
    if [ "$ALL" = 0 ]; then
      WORKSPACE_ID=$(sed -n "s/^entry workspace \\($UUID\\)\$/\\1/p" "$APP_DIR/global.lock" 2>/dev/null | head -n 1)
      find_project ask && fx_query="?project=$PROJECT_ID"
    fi
    code=$(status_of "$(http GET "/v1/sync/fixes$fx_query" "$TMP/fix" '' '' '' '' '')")
  fi
  case $code in
    200)
      # Tabs and line breaks stay; other control characters never show
      tr -d '\000-\010\013-\037\177' <"$TMP/fix"
      [ -z "$FIX_AS" ] && changed_since
      return 0
      ;;
    401) printf "Context Locker: this computer's connection for %s was revoked or has expired. Set it up again at context.locker/setup.\n" "$APP_NAME" >&2 ;;
    403) printf "Context Locker: %s may only read your playbook, so it can't mark Tidy-up items. The person can deal with them in Context Locker.\n" "$APP_NAME" >&2 ;;
    000) printf "Context Locker: can't reach %s, so there's no Tidy-up to show.\n" "$API" >&2 ;;
    4??)
      fx_message=$(reply_field message "$TMP/fix" | clean)
      if [ -n "$fx_message" ]; then
        printf 'Context Locker: %s\n' "$fx_message" >&2
      else
        printf 'Context Locker answered %s. Try again in a minute.\n' "$code" >&2
      fi
      ;;
    *) printf 'Context Locker answered %s. Try again in a minute.\n' "$code" >&2 ;;
  esac
  return 1
}

home_path() {
  case $1 in
    "$HOME") printf '~' ;;
    "$HOME"/*) printf '~/%s' "${1#"$HOME"/}" ;;
    *) printf '%s' "$1" ;;
  esac
}

# Text for one field of a tab-separated line: tabs and line breaks become
# spaces, and other control characters go
tsv() { printf '%s' "$1" | tr '\t\n\r' '   ' | clean; }

# A new random UUID, version 4, for the plan's id
new_uuid() {
  nu=$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -cd 'a-f0-9')
  [ "${#nu}" = 32 ] || return 1
  case $(printf '%s' "$nu" | cut -c 17) in
    [0123]) nu_v=8 ;;
    [4567]) nu_v=9 ;;
    [89ab]) nu_v=a ;;
    *) nu_v=b ;;
  esac
  printf '%s-%s-4%s-%s%s-%s' "$(printf '%s' "$nu" | cut -c 1-8)" "$(printf '%s' "$nu" | cut -c 9-12)" \
    "$(printf '%s' "$nu" | cut -c 14-16)" "$nu_v" "$(printf '%s' "$nu" | cut -c 18-20)" "$(printf '%s' "$nu" | cut -c 21-32)"
}

# Notes a source the gather left out: its app, kind, path, a short code and why
g_out() {
  printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$(tsv "$(home_path "$3")")" "$4" "$5" >>"$G_WS/left-out.tsv"
}

# Context Locker's own blocks cut out, each from its start line to its end line
cut_blocks() {
  awk '
    /^<!-- context-locker:start( v[0-9]+)? -->[ \t\r]*$/ { inside = 1; next }
    /^<!-- context-locker:end -->[ \t\r]*$/ { inside = 0; next }
    !inside { print }'
}

# Whether a file isn't text: a kind of file that never is, or one that holds
# a NUL byte
g_binary() {
  case $(printf '%s' "${1##*/}" | tr 'ABCDEFGHIJKLMNOPQRSTUVWXYZ' 'abcdefghijklmnopqrstuvwxyz') in
    *.png | *.jpg | *.jpeg | *.gif | *.webp | *.ico | *.bmp | *.tif | *.tiff | *.heic | *.pdf | \
      *.zip | *.gz | *.tgz | *.bz2 | *.xz | *.7z | *.tar | *.jar | *.exe | *.dll | *.so | *.dylib | \
      *.bin | *.o | *.a | *.class | *.pyc | *.wasm | *.woff | *.woff2 | *.ttf | *.otf | *.eot | \
      *.mp3 | *.mp4 | *.m4a | *.mov | *.wav | *.ogg | *.webm | *.avi | *.sqlite | *.sqlite3 | *.db | \
      *.pkl | *.npy | *.parquet)
      return 0
      ;;
  esac
  [ "$(tr -d '\000' <"$1" | wc -c | tr -d ' ')" != "$(wc -c <"$1" | tr -d ' ')" ]
}

# The secret patterns Context Locker's API refuses (apps/api/src/mcp/checks.ts),
# written for grep, in its order: whether case counts, what each finds, and
# the pattern. Each catches at least what the API's catches.
g_secret_patterns() {
  cat <<'EOF' >"$TMP/g-secret-list"
s	a private key	-----BEGIN ([A-Z]+ )*PRIVATE KEY-----
s	an AWS access key	(^|[^A-Za-z0-9_])(AKIA|ASIA)[0-9A-Z]{16}
s	a GitHub token	(^|[^A-Za-z0-9_])(gh[pousr]_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{22})
s	a GitLab token	(^|[^A-Za-z0-9_])glpat-[A-Za-z0-9_-]{20}
s	a Slack token	(^|[^A-Za-z0-9_])xox[abposr]-[A-Za-z0-9-]{10}
s	an Anthropic API key	(^|[^A-Za-z0-9_])sk-ant-[A-Za-z0-9_-]{20}
s	an OpenAI API key	(^|[^A-Za-z0-9_])sk-[A-Za-z0-9_-]{32}
s	a Stripe key	(^|[^A-Za-z0-9_])(sk|rk)_(live|test)_[A-Za-z0-9]{16}
s	a Google API key	(^|[^A-Za-z0-9_])AIza[0-9A-Za-z_-]{35}
s	a Context Locker token	(^|[^A-Za-z0-9_])ctxl_(at|dc|mat|mrt|ac|cs)_[A-Za-z0-9_-]{20}
s	a JSON web token	(^|[^A-Za-z0-9_-])eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10}
i	a password in an address	[A-Za-z][A-Za-z0-9+.-]+://[^[:space:]:@/]+:[^[:space:]@/]{6,}@
EOF
  awk -F '\t' '$1 == "s" { print $3 }' "$TMP/g-secret-list" >"$TMP/g-secrets"
  awk -F '\t' '$1 == "i" { print $3 }' "$TMP/g-secret-list" >"$TMP/g-secrets-i"
}

# The generic assignment check from the API, kept separate from credential
# shapes so an environment reference or an explicit placeholder cannot hide
# a recognisable token elsewhere in the same file. It reads a line at a
# time, so a big file takes no longer than its size: a name whose = or :, or
# whose value, is on a later line carries over to the next line. Each text
# it checks starts with a line break, so a name counts at the start of a
# line too, without the ^ that macOS's awk can't match inside a group. And
# match() is given a variable, as macOS's awk places a match in what a
# function returned at -1. As the API does, it takes a value that says
# outright it's a placeholder, such as your-api-key-here or ********, for
# none, and copies one cut short or masked, such as sk-live-abc..., with too
# little of it left to work: Context Locker checks that when the plan comes
# in, with the value hidden.
g_assignment_secret() {
  LC_ALL=C awk -v bullet="$(printf '\342\200\242')" -v ellipsis="$(printf '\342\200\246')" '
    function reference(v,   tail) {
      if (!match(substr(v, 1, 512), safe_ref)) return 0
      if (length(v) > 512 && RLENGTH >= 512) return 0
      tail = substr(v, RLENGTH + 1)
      sub(/^[ \t]*/, "", tail)
      return tail == "" || tail ~ /^\r?\n/ || substr(tail, 1, 2) == "//" || index(",;)}]" bt, substr(tail, 1, 1))
    }
    function placeholder_words(   n, i, w) {
      n = split("your my our the an api key keys secret secrets token tokens password passwords passwd pass passphrase pwd access auth client private public here goes example examples sample samples dummy fake placeholder changeme change replace insert put enter me this with value redacted todo tbd sk pk rk live prod dev staging app service account bot webhook signing id own real actual new turn", w, " ")
      for (i = 1; i <= n; i++) {
        ph_words[w[i]] = 1
        if (length(w[i]) > ph_longest) ph_longest = length(w[i])
      }
      n = split("your my here example examples sample samples dummy fake placeholder changeme replace insert enter redacted todo tbd", w, " ")
      for (i = 1; i <= n; i++) ph_markers[w[i]] = 1
    }
    # A run of letters and digits split into placeholder words, as the API
    # splits it, noting any word that says it is a placeholder
    function placeholder_token(t,   len, e, s, from) {
      if (t ~ /^xx+$/) { ph_marked = 1; return 1 }
      len = length(t)
      split("", ph_ok); split("", ph_prev)
      ph_ok[0] = 1
      for (e = 1; e <= len; e++) {
        ph_ok[e] = 0
        from = e - ph_longest
        if (from < 0) from = 0
        for (s = from; s < e; s++) {
          if (ph_ok[s] && (substr(t, s + 1, e - s) in ph_words)) { ph_ok[e] = 1; ph_prev[e] = s; break }
        }
      }
      if (!ph_ok[len]) return 0
      for (e = len; e > 0; e = ph_prev[e]) {
        if (substr(t, ph_prev[e] + 1, e - ph_prev[e]) in ph_markers) ph_marked = 1
      }
      return 1
    }
    function placeholder(v,   n, i, part, any) {
      if (v ~ mask_only) return 1
      if (length(v) > 100) return 0
      n = split(tolower(v), part, /[^a-z0-9]+/)
      ph_marked = 0
      any = 0
      for (i = 1; i <= n; i++) {
        if (part[i] == "") continue
        any = 1
        if (!placeholder_token(part[i])) return 0
      }
      return any && ph_marked
    }
    # Letters and digits left in a value once some parts of it are taken out
    function showing(v, taken) {
      gsub(taken, "", v)
      gsub(/[^A-Za-z0-9]/, "", v)
      return length(v)
    }
    function cut_or_masked(v,   lowered) {
      lowered = tolower(v)
      if (lowered ~ cut && showing(lowered, cut) <= 16) return 1
      if (v ~ mask && showing(v, mask) <= 16) return 1
      return 0
    }
    BEGIN {
      placeholder_words()
      run = "([xX]+|\\*+|(" bullet ")+|0+)"
      mask_only = "^" run "([-_.: ]" run ")*$"
      mark = "(x|X|\\*|" bullet ")"
      mask = mark mark mark mark "+"
      cut = "\\.\\.\\.+|" ellipsis "|\\[[[:space:]]*(\\.\\.\\.|" ellipsis "|truncated|cut|snip)[[:space:]]*\\]|\\([[:space:]]*(truncated|cut|snip)[[:space:]]*\\)"
    }
    BEGIN {
      sq = sprintf("%c", 39); bt = sprintf("%c", 96)
      id = "[A-Za-z_$][A-Za-z0-9_$]*"
      qname = "(\"[A-Za-z_][A-Za-z0-9_]*\"|" sq "[A-Za-z_][A-Za-z0-9_]*" sq ")"
      ref = "((this\\.)?(env|process\\.env|import\\.meta\\.env|cred|credentials|config|data|secret|random_id)(\\." id ")+|[A-Z_][A-Z0-9_]*_(API_KEY|TOKEN|SECRET|PASSWORD)|os\\.environ\\[" qname "\\]|(os\\.environ\\.get|os\\.getenv|config\\.(requireSecret|getSecret))\\(" qname "\\))"
      op = "[[:blank:]]*(\\|\\||\\?\\?|or)[[:blank:]]*"
      safe_ref = "^" ref "(" op ref ")*(" op "(\"\"|" sq sq "))?"

      key = "[^A-Za-z0-9_](password|passwd|secret|api[_-]?key|access[_-]?token|auth[_-]?token)[\"" sq "]?[[:space:]]*"
      names = key "[:=][[:space:]]*"
      ends = key "$"
    }
    {
      line = (carry == "" ? "" : carry "\n") $0
      carry = ""
      text = "\n" line "\n"
      while (match(lower = tolower(text), names)) {
        assignment = substr(text, RSTART, RLENGTH)
        prefix = substr(text, 1, RSTART)
        rest = substr(text, RSTART + RLENGTH)
        text = "\n" rest
        # The value is on a later line
        if (rest == "") {
          carry = "password="
          break
        }
        quote = substr(rest, 1, 1)
        quoted = quote == "\"" || quote == sq || quote == bt
        if (!quoted && reference(rest)) continue
        if (tolower(prefix) ~ /set $/ && rest ~ /^(npx[ \t]+)?wrangler[ \t]+secret[ \t]+put[ \t]+[A-Z_][A-Z0-9_]*[ \t]*(\r?\n|$)/) continue
        start = substr(rest, quoted ? 2 : 1, 512)
        if (quoted) {
          stop = index(start, quote)
          value = substr(start, 1, stop ? stop - 1 : 512)
          sub(/[\r\n].*$/, "", value)
        } else {
          value = start
          sub("[[:space:]\"" sq bt ",;)}<>].*$", "", value)
        }
        first = substr(value, 1, 1)
        if (length(value) < 8 || index("<$[{", first)) continue
        if (tolower(value) ~ /^(local-dev-key|your-api-key|your_api_key)$/) continue
        if (!quoted) {
          if (value ~ /^(string|number|boolean|unknown|undefined|never|any|void)(\[\])?$/) continue
          tail = substr(rest, length(value) + 1)
          sub(/^[ \t]*/, "", tail)
          if (value ~ /^(this\.)?(env|process\.env|import\.meta\.env)\.[A-Za-z_$][A-Za-z0-9_$]*$/ &&
              (tail == "" || tail ~ /^\r?\n/ || substr(tail, 1, 2) == "//" || index(",;)}]", substr(tail, 1, 1)))) continue
        }
        if (value == "1x0000000000000000000000000000000AA" || value == "2x0000000000000000000000000000000AA" || value == "3x0000000000000000000000000000000AA") continue
        if (tolower(assignment) ~ /api[_-]?key/ && value ~ /^(sk|rk)_(live|test)_[A-Za-z0-9]{1,15}$/) continue
        if (placeholder(value) || cut_or_masked(value)) continue
        found = 1
        exit
      }
      # A name at the end of the line, with its = or : on a later line
      if (carry == "" && match(lower = tolower("\n" line), ends)) {
        carry = substr("\n" line, RSTART)
        sub(/[[:space:]]+$/, "", carry)
      }
    }
    END { exit !found }' "$1"
}

# A URL password made entirely from a variable is a reference. A literal
# prefix, suffix or fallback still counts; other token shapes are checked
# against the original file independently.
g_address_secret() {
  LC_ALL=C awk '
    {
      text = $0
      pattern = "[A-Za-z][A-Za-z0-9+.-]+://[^[:space:]:@/]+:[^[:space:]@/]{6,}@"
      while (match(text, pattern)) {
        value = substr(text, RSTART, RLENGTH)
        text = substr(text, RSTART + RLENGTH)
        sub(/^[^:]+:\/\//, "", value)
        sub(/^[^:]+:/, "", value)
        sub(/@$/, "", value)
        if (value !~ /^\$\{[A-Za-z_$][A-Za-z0-9_$]*(\.[A-Za-z_$][A-Za-z0-9_$]*)*\}$/) { found = 1; exit }
      }
    }
    END { exit !found }' "$1"
}

# What kind of secret a file seems to hold, or failure when it holds none.
# Line breaks count as spaces, so a key on the line after its name counts.
g_secret() {
  tr '\n\r' '  ' <"$1" >"$TMP/g-flat"
  if LC_ALL=C grep -Eq -f "$TMP/g-secrets" "$TMP/g-flat" ||
    LC_ALL=C grep -Eiq -f "$TMP/g-secrets-i" "$TMP/g-flat"; then
    while IFS='	' read -r gs_case gs_kind gs_pattern; do
      if [ "$gs_case" = i ]; then gs_flags=-Eiq; else gs_flags=-Eq; fi
      if LC_ALL=C grep "$gs_flags" -e "$gs_pattern" "$TMP/g-flat"; then
        if [ "$gs_kind" = "a password in an address" ] && ! g_address_secret "$TMP/g-flat"; then continue; fi
        printf '%s' "$gs_kind"
        return 0
      fi
    done <"$TMP/g-secret-list"
  fi
  if g_assignment_secret "$1"; then
    printf 'a password or key'
    return 0
  fi
  return 1
}

# Copies one source, <root>/<rel>, into the working set as <prefix>/<rel>,
# unless it's left out. The root is the app's own folder; no part of the
# path below it may be a link. With "cut", Context Locker's own blocks are
# cut from the copy, and a copy with nothing else in it is left out.
g_file() {
  gf_app=$1 gf_kind=$2 gf_root=$3 gf_rel=$4 gf_copy=$5/$4 gf_cut=${6:-}
  gf_path=$gf_root/$gf_rel
  gf_cur=$gf_root gf_rest=$gf_rel
  while [ -n "$gf_rest" ]; do
    gf_part=${gf_rest%%/*}
    case $gf_rest in */*) gf_rest=${gf_rest#*/} ;; *) gf_rest= ;; esac
    gf_cur=$gf_cur/$gf_part
    if [ -L "$gf_cur" ]; then
      g_out "$gf_app" "$gf_kind" "$gf_cur" link "$G_LINK"
      return 0
    fi
    [ -e "$gf_cur" ] || { [ "$gf_kind" != skill ] || g_out "$gf_app" "$gf_kind" "$gf_path" unreadable "it disappeared while collecting"; return 0; }
  done
  [ -f "$gf_path" ] || { [ "$gf_kind" != skill ] || g_out "$gf_app" "$gf_kind" "$gf_path" unreadable "it is not a regular file"; return 0; }
  if [ "$G_FULL" = 1 ]; then
    g_out "$gf_app" "$gf_kind" "$gf_path" total "Import takes at most $((GATHER_MOST / 1048576)) MB in all, and it had that much"
    return 0
  fi
  gf_size=$(wc -c <"$gf_path" 2>/dev/null | tr -d ' ')
  case $gf_size in
    '' | *[!0-9]*)
      g_out "$gf_app" "$gf_kind" "$gf_path" unreadable "it couldn't be read"
      return 0
      ;;
  esac
  if [ "$gf_size" -gt "$GATHER_FILE_MOST" ]; then
    g_out "$gf_app" "$gf_kind" "$gf_path" size "it's $(((gf_size + 1023) / 1024)) KB, and Import takes files of up to 4 MB"
    return 0
  fi
  if [ "$gf_kind" != skill ] && g_binary "$gf_path"; then
    g_out "$gf_app" "$gf_kind" "$gf_path" binary "it isn't a text file"
    return 0
  fi
  gf_note=-
  if [ -n "$gf_cut" ] && LC_ALL=C grep -Eq '^<!-- context-locker:(start( v[0-9]+)?|end) -->' "$gf_path" 2>/dev/null; then
    gf_note=cut
    cut_blocks <"$gf_path" >"$TMP/g-copy" 2>/dev/null
  else
    cat "$gf_path" >"$TMP/g-copy" 2>/dev/null
  fi || {
    g_out "$gf_app" "$gf_kind" "$gf_path" unreadable "it couldn't be read"
    return 0
  }
  if [ "$gf_kind" != skill ] && ! LC_ALL=C grep -q '[^[:space:]]' "$TMP/g-copy"; then
    if [ "$gf_note" = cut ]; then
      g_out "$gf_app" "$gf_kind" "$gf_path" own "it holds only Context Locker's own block"
    else
      g_out "$gf_app" "$gf_kind" "$gf_path" empty "it's empty"
    fi
    return 0
  fi
  if gf_secret=$(g_secret "$TMP/g-copy"); then
    g_out "$gf_app" "$gf_kind" "$gf_path" secret "it seems to hold $gf_secret, so it wasn't copied. Secrets belong in ScopeHold"
    return 0
  fi
  gf_bytes=$(wc -c <"$TMP/g-copy" | tr -d ' ')
  if [ "$gf_bytes" -gt "$GATHER_FILE_MOST" ]; then
    g_out "$gf_app" "$gf_kind" "$gf_path" size "it's over 4 MB, and Import takes files of up to 4 MB"
    return 0
  fi
  if [ $((G_TOTAL + gf_bytes)) -gt "$GATHER_MOST" ]; then
    G_FULL=1
    g_out "$gf_app" "$gf_kind" "$gf_path" total "Import takes at most $((GATHER_MOST / 1048576)) MB in all, and it had that much"
    return 0
  fi
  mkdir -p "$G_WS/${gf_copy%/*}" && cat "$TMP/g-copy" >"$G_WS/$gf_copy" || {
    printf "Context Locker: couldn't write %s.\n" "$G_WS/$gf_copy" >&2
    G_BROKE=1
    return 1
  }
  G_TOTAL=$((G_TOTAL + gf_bytes))
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$gf_app" "$gf_kind" "$(tsv "$(home_path "$gf_path")")" "$gf_size" \
    "$(date -u -r "$gf_path" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf -)" "$(sha_file "$gf_path")" \
    "$(tsv "$gf_copy")" "$gf_note" >>"$G_WS/sources.tsv"
  printf '%s\t%s\n' "$gf_app" "$gf_kind" >>"$TMP/g-copied"
}

# The files that may hold instructions or memories in <root>/<sub> and the
# folders in it, down to <depth>, copied as <kind>. Hidden files and folders,
# and the folders tools keep, are skipped. Every link is listed, whatever its
# name, so g_file says it wasn't followed.
g_tree() {
  gt_app=$1 gt_kind=$2 gt_root=$3 gt_sub=$4 gt_copy=$5 gt_depth=$6 gt_cut=${7:-}
  gt_dir=$gt_root/$gt_sub
  if [ -L "$gt_dir" ]; then
    g_out "$gt_app" "$gt_kind" "$gt_dir" link "$G_LINK"
    return 0
  fi
  [ -d "$gt_dir" ] || return 0
  (cd "$gt_dir" 2>/dev/null && find . -maxdepth "$gt_depth" \( ! -name . \( -name '.*' -o -name node_modules -o -name __pycache__ \) \) -prune -o \
    -type l -print -o \
    -type f \( -name '*.md' -o -name '*.markdown' -o -name '*.mdx' -o -name '*.mdc' -o -name '*.txt' \) -print) |
    sed 's|^\./||' | LC_ALL=C sort >"$TMP/g-tree"
  while IFS= read -r gt_rel <&7; do
    [ -n "$gt_rel" ] || continue
    g_file "$gt_app" "$gt_kind" "$gt_root" "$gt_sub/$gt_rel" "$gt_copy" "$gt_cut"
  done 7<"$TMP/g-tree"
}

# One skill's folder, <root>/<sub>, unless Context Locker manages it, or its
# app brought it, as Hermes lists those in <bundled>
g_skill() {
  gk_app=$1 gk_root=$2 gk_sub=$3 gk_copy=$4 gk_bundled=${5:-}
  gk_dir=$gk_root/$gk_sub
  if [ -e "$gk_dir/.ctx-managed" ] || [ -L "$gk_dir/.ctx-managed" ]; then
    g_out "$gk_app" skill "$gk_dir" managed "Context Locker manages it, so it's in the playbook already"
    return 0
  fi
  if [ -n "$gk_bundled" ] && [ -f "$gk_bundled" ] &&
    sed 's/:.*//; s/[[:space:]]//g' "$gk_bundled" | grep -Fqx "${gk_sub##*/}"; then
    g_out "$gk_app" skill "$gk_dir" bundled "it came with the app"
    return 0
  fi
  # Enumerate the whole package, including hidden files and assets. Do not
  # follow links. Unrepresentable names defer it before line-based traversal.
  if ! (cd "$gk_dir" && LC_ALL=C find . ! -name . -name '*[!A-Za-z0-9._-]*' -print) >"$TMP/g-bad-paths" 2>/dev/null || [ -s "$TMP/g-bad-paths" ]; then
    g_out "$gk_app" skill "$gk_dir" package "the whole package is deferred: a path is unreadable or has unsupported characters"
    return 0
  fi
  if ! (cd "$gk_dir" && find . ! -type d -print) >"$TMP/g-skill-raw" 2>/dev/null; then
    g_out "$gk_app" skill "$gk_dir" package "the whole package is deferred: its files could not all be listed"
    return 0
  fi
  sed 's|^\./||' "$TMP/g-skill-raw" | LC_ALL=C sort >"$TMP/g-skill"
  gk_count=$(wc -l <"$TMP/g-skill")
  if [ "$gk_count" -gt 1000 ] || [ "$gk_count" -eq 0 ]; then
    g_out "$gk_app" skill "$gk_dir" package "the whole package is deferred: a skill needs 1 to 1,000 files"
    return 0
  fi
  cp "$G_WS/sources.tsv" "$TMP/g-skill-sources"
  cp "$TMP/g-copied" "$TMP/g-skill-copied"
  gk_before=$(wc -l <"$G_WS/sources.tsv")
  gk_out=$(wc -l <"$G_WS/left-out.tsv")
  gk_total=$G_TOTAL gk_full=$G_FULL
  while IFS= read -r gk_rel <&6; do
    [ -n "$gk_rel" ] || continue
    gk_depth=$(printf '%s' "$gk_rel" | awk -F/ '{print NF}')
    if [ "$gk_depth" -gt 8 ] || [ "${#gk_rel}" -gt 200 ]; then
      g_out "$gk_app" skill "$gk_dir/$gk_rel" path "the path is longer or deeper than a skill can hold"
      break
    fi
    g_file "$gk_app" skill "$gk_root" "$gk_sub/$gk_rel" "$gk_copy"
    [ "$(wc -l <"$G_WS/left-out.tsv")" -eq "$gk_out" ] || break
    [ $((G_TOTAL - gk_total)) -le 10485760 ] || break
  done 6<"$TMP/g-skill"
  if [ "$(wc -l <"$G_WS/left-out.tsv")" -ne "$gk_out" ] ||
    [ $((G_TOTAL - gk_total)) -gt 10485760 ] ||
    [ $(( $(wc -l <"$G_WS/sources.tsv") - gk_before )) -ne "$gk_count" ]; then
    # Delete only copies made in this private working set, never the source.
    rm -rf "${G_WS:?}/$gk_copy/$gk_sub"
    cp "$TMP/g-skill-sources" "$G_WS/sources.tsv"
    cp "$TMP/g-skill-copied" "$TMP/g-copied"
    G_TOTAL=$gk_total G_FULL=$gk_full
    g_out "$gk_app" skill "$gk_dir" package "the whole package is deferred: a file was blocked or the package exceeds 10 MB; no files from it were kept"
  else
    printf '%s\n' "$gk_app" >>"$TMP/g-skills"
  fi
  return 0
}

# The skills in <root>/<sub>: each folder in it with a SKILL.md, or with
# "nested", each one in a folder of them too, as Hermes keeps its categories.
# Hidden folders are skipped, and links aren't followed.
g_skills() {
  gs_app=$1 gs_root=$2 gs_sub=$3 gs_copy=$4 gs_nested=${5:-} gs_bundled=${6:-}
  gs_dir=$gs_root/$gs_sub
  if [ -L "$gs_dir" ]; then
    g_out "$gs_app" skill "$gs_dir" link "$G_LINK"
    return 0
  fi
  [ -d "$gs_dir" ] || return 0
  for gs_path in "$gs_dir"/*; do
    [ -e "$gs_path" ] || [ -L "$gs_path" ] || continue
    gs_name=${gs_path##*/}
    if [ -L "$gs_path" ]; then
      g_out "$gs_app" skill "$gs_path" link "$G_LINK"
      continue
    fi
    [ -d "$gs_path" ] || continue
    if [ -f "$gs_path/SKILL.md" ] || [ -L "$gs_path/SKILL.md" ]; then
      g_skill "$gs_app" "$gs_root" "$gs_sub/$gs_name" "$gs_copy" "$gs_bundled"
    elif [ -n "$gs_nested" ]; then
      for gs_inner in "$gs_path"/*; do
        if [ -L "$gs_inner" ]; then
          g_out "$gs_app" skill "$gs_inner" link "$G_LINK"
          continue
        fi
        [ -d "$gs_inner" ] && { [ -f "$gs_inner/SKILL.md" ] || [ -L "$gs_inner/SKILL.md" ]; } || continue
        g_skill "$gs_app" "$gs_root" "$gs_sub/$gs_name/${gs_inner##*/}" "$gs_copy" "$gs_bundled"
      done
    fi
  done
}

# Claude Code: CLAUDE.md, its rules, its skills, and the auto memory it keeps
# for each project. Sessions' transcripts there are never read.
g_claude_code() {
  gc_root=$(root_dir claude)
  g_file claude-code instructions "$gc_root" CLAUDE.md claude-code cut
  g_tree claude-code instructions "$gc_root" rules claude-code 4 cut
  g_skills claude-code "$gc_root" skills claude-code
  [ -L "$gc_root/projects" ] && g_out claude-code memory "$gc_root/projects" link "$G_LINK"
  [ -d "$gc_root/projects" ] && [ ! -L "$gc_root/projects" ] || return 0
  for gc_project in "$gc_root/projects"/*; do
    if [ -L "$gc_project" ]; then
      g_out claude-code memory "$gc_project" link "$G_LINK"
      continue
    fi
    [ -d "$gc_project" ] || continue
    g_tree claude-code memory "$gc_root" "projects/${gc_project##*/}/memory" claude-code 3
  done
}

# Codex: its AGENTS.md, or AGENTS.override.md, its memories and its own skills
g_codex() {
  gx_root=$(root_dir codex)
  g_file codex instructions "$gx_root" AGENTS.md codex cut
  g_file codex instructions "$gx_root" AGENTS.override.md codex cut
  g_tree codex memory "$gx_root" memories codex 3
  g_skills codex "$gx_root" skills codex
}

# Hermes: SOUL.md, which is its identity, its memories (MEMORY.md, and USER.md
# about the person) and its skills, in folders by category, apart from the
# ones that came with it
g_hermes() {
  gh_root=$(root_dir hermes)
  g_file hermes identity "$gh_root" SOUL.md hermes cut
  g_file hermes profile "$gh_root" USER.md hermes cut
  g_file hermes memory "$gh_root" MEMORY.md hermes cut
  if [ -L "$gh_root/memories" ]; then
    g_out hermes memory "$gh_root/memories" link "$G_LINK"
  elif [ -d "$gh_root/memories" ]; then
    for gh_file in "$gh_root/memories"/*.md; do
      [ -e "$gh_file" ] || [ -L "$gh_file" ] || continue
      case ${gh_file##*/} in USER.md) gh_kind=profile ;; *) gh_kind=memory ;; esac
      g_file hermes "$gh_kind" "$gh_root" "memories/${gh_file##*/}" hermes
    done
  fi
  g_skills hermes "$gh_root" skills hermes nested "$gh_root/skills/.bundled_manifest"
}

# OpenClaw: its workspace's AGENTS.md, SOUL.md, IDENTITY.md, USER.md and
# MEMORY.md, its daily memory logs and its skills, and the skills it keeps in
# ~/.openclaw
g_openclaw() {
  go_root=$(read_setting workspace "$CL_HOME/openclaw/config")
  go_root=${go_root:-${OPENCLAW_WORKSPACE_DIR:-$HOME/.openclaw/workspace}}
  g_file openclaw instructions "$go_root" AGENTS.md openclaw/workspace cut
  g_file openclaw identity "$go_root" SOUL.md openclaw/workspace cut
  g_file openclaw identity "$go_root" IDENTITY.md openclaw/workspace cut
  g_file openclaw profile "$go_root" USER.md openclaw/workspace cut
  g_file openclaw memory "$go_root" MEMORY.md openclaw/workspace cut
  g_tree openclaw log "$go_root" memory openclaw/workspace 2
  g_skills openclaw "$go_root" skills openclaw/workspace
  g_skills openclaw "$HOME/.openclaw" skills openclaw
}

# Grok Build: the rules and skills in ~/.grok, when it's there
g_grok() {
  gg_root=$HOME/.grok
  [ -d "$gg_root" ] || return 0
  for gg_file in "$gg_root"/*.md; do
    [ -e "$gg_file" ] || [ -L "$gg_file" ] || continue
    g_file grok-build instructions "$gg_root" "${gg_file##*/}" grok-build cut
  done
  g_tree grok-build instructions "$gg_root" rules grok-build 4 cut
  g_skills grok-build "$gg_root" skills grok-build
}

# The project this runs in: the top of its git work tree, or the folder
# itself, but never the home folder. Its notes folder isn't read.
g_project() {
  gp_root=$(git_top "$START") || gp_root=$START
  case $gp_root in '' | / | "$HOME") return 0 ;; esac
  G_PROJECT=$gp_root
  for gp_name in AGENTS.md AGENTS.override.md CLAUDE.md CLAUDE.local.md .claude/CLAUDE.md; do
    g_file project instructions "$gp_root" "$gp_name" project cut
  done
}

# What one app's copies hold, in words, such as "CLAUDE.md, 2 skills and 3
# memory files", or "nothing found"
g_counts() {
  awk -F '\t' -v app="$1" '
    function noun(n, one, many) { return n == 1 ? "1 " one : n " " many }
    FILENAME == ARGV[1] && $1 == app && $2 != "skill" { count[$2]++ }
    FILENAME == ARGV[2] && $1 == app { skills++ }
    END {
      if (count["instructions"]) parts[++n] = noun(count["instructions"], "instruction file", "instruction files")
      if (count["identity"]) parts[++n] = noun(count["identity"], "identity file", "identity files")
      if (count["profile"]) parts[++n] = noun(count["profile"], "profile", "profiles")
      if (count["memory"]) parts[++n] = noun(count["memory"], "memory file", "memory files")
      if (count["log"]) parts[++n] = noun(count["log"], "daily log", "daily logs")
      if (skills) parts[++n] = noun(skills, "skill", "skills")
      if (n == 0) { printf "nothing found"; exit }
      for (i = 1; i <= n; i++) printf "%s%s", (i == 1 ? "" : (i == n ? " and " : ", ")), parts[i]
    }' "$TMP/g-copied" "$TMP/g-skills"
}

# Gather's own working sets in $G_ROOT, newest first, into $TMP/g-sets:
# folders named by their time, holding Gather's mark, and no link
g_sets() {
  : >"$TMP/g-found"
  for gs_set in "$G_ROOT"/*; do
    case ${gs_set##*/} in
      [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z) ;;
      *) continue ;;
    esac
    [ -d "$gs_set" ] && [ ! -L "$gs_set" ] && [ -f "$gs_set/.context-locker-gather" ] &&
      [ ! -L "$gs_set/.context-locker-gather" ] || continue
    [ "$(head -n 1 "$gs_set/.context-locker-gather")" = "$GATHER_MARK" ] || continue
    printf '%s\n' "${gs_set##*/}" >>"$TMP/g-found"
  done
  LC_ALL=C sort -r "$TMP/g-found" >"$TMP/g-sets"
}

# Deletes Gather's own working sets past the newest 3, and any older than
# 7 days, by when its mark was written
g_prune() {
  g_sets
  gp_at=0
  while IFS= read -r gp_name; do
    gp_at=$((gp_at + 1))
    if [ "$gp_at" -gt "$GATHER_KEEP" ] ||
      [ -n "$(find "$G_ROOT/$gp_name/.context-locker-gather" -mtime +$((GATHER_DAYS - 1)) 2>/dev/null)" ]; then
      rm -rf "${G_ROOT:?}/$gp_name"
    fi
  done <"$TMP/g-sets"
}

# Once a plan is in, deletes all of Gather's own working sets, as they hold
# copies of the apps' memories, and says so. Not while a gather runs.
g_clear() {
  G_ROOT=$CL_HOME/gather
  [ -d "$G_ROOT" ] && [ ! -L "$G_ROOT" ] || return 0
  if ! mkdir "$CL_HOME/gather.lock" 2>/dev/null; then
    if [ -n "$(find "$CL_HOME/gather.lock" -maxdepth 0 -mmin +10 2>/dev/null)" ]; then
      rm -rf "$CL_HOME/gather.lock"
    fi
    if ! mkdir "$CL_HOME/gather.lock" 2>/dev/null; then
      printf "Import's working copies stay in %s for now, as an import is running. A later import deletes them after %s days.\n" \
        "$(home_path "$G_ROOT")" "$GATHER_DAYS"
      return 0
    fi
  fi
  LOCK=$CL_HOME/gather.lock
  g_sets
  gc_count=0
  while IFS= read -r gc_name; do
    rm -rf "${G_ROOT:?}/$gc_name" && gc_count=$((gc_count + 1))
  done <"$TMP/g-sets"
  rm -rf "$LOCK"
  LOCK=
  [ "$gc_count" -gt 0 ] &&
    printf "Context Locker deleted Import's working copies from this computer, in %s, now that the plan is in.\n" "$(home_path "$G_ROOT")"
  return 0
}

gather() {
  G_ROOT=$CL_HOME/gather
  if [ -L "$G_ROOT" ] || { [ -e "$G_ROOT" ] && [ ! -d "$G_ROOT" ]; }; then
    printf "Context Locker: %s isn't a folder of Context Locker's, so Import stopped. Move it away, and run gather again.\n" "$G_ROOT" >&2
    return 1
  fi
  if ! mkdir -p "$G_ROOT" || ! chmod 700 "$G_ROOT"; then
    printf "Context Locker: can't write to %s.\n" "$G_ROOT" >&2
    return 1
  fi
  # One gather at a time on this computer. A lock older than 10 minutes is stale.
  gl_tries=0
  while ! mkdir "$CL_HOME/gather.lock" 2>/dev/null; do
    if [ -n "$(find "$CL_HOME/gather.lock" -maxdepth 0 -mmin +10 2>/dev/null)" ]; then
      rm -rf "$CL_HOME/gather.lock"
      continue
    fi
    gl_tries=$((gl_tries + 1))
    if [ "$gl_tries" -ge 15 ]; then
      printf 'Context Locker: another gather is still running, so this one stopped.\n' >&2
      return 1
    fi
    sleep 1
  done
  LOCK=$CL_HOME/gather.lock
  # A working set of its own, named by the time in UTC
  gw_tries=0
  while :; do
    G_WS=$G_ROOT/$(date -u +%Y%m%dT%H%M%SZ)
    mkdir "$G_WS" 2>/dev/null && break
    gw_tries=$((gw_tries + 1))
    if [ "$gw_tries" -ge 3 ]; then
      printf "Context Locker: can't make a working set in %s.\n" "$G_ROOT" >&2
      return 1
    fi
    sleep 1
  done
  chmod 700 "$G_WS"
  printf '%s\n' "$GATHER_MARK" >"$G_WS/.context-locker-gather"
  printf 'app\tkind\tpath\tsize\tmodified\tsha256\tcopy\tnote\n' >"$G_WS/sources.tsv"
  printf 'app\tkind\tpath\tcode\twhy\n' >"$G_WS/left-out.tsv"
  : >"$TMP/g-copied"
  : >"$TMP/g-skills"
  G_TOTAL=0 G_FULL=0 G_BROKE=0 G_PROJECT=
  g_secret_patterns

  g_claude_code
  g_codex
  g_skills agents "$HOME/.agents" skills agents
  g_hermes
  g_openclaw
  g_grok
  g_project
  if [ "$G_BROKE" = 1 ]; then
    rm -rf "$G_WS"
    return 1
  fi

  # What Context Locker already keeps in this app's files, to leave out as
  # duplicate, and the plan to fill in, with its id
  readback >"$G_WS/playbook.md" 2>/dev/null
  if ! g_id=$(new_uuid); then
    printf "Context Locker: couldn't make an id for the plan.\n" >&2
    rm -rf "$G_WS"
    return 1
  fi
  printf '{\n  "plan_id": "%s",\n  "items": [],\n  "left_out": [],\n  "questions": []\n}\n' "$g_id" >"$G_WS/plan.json"
  {
    printf '# Import working set\n\n'
    printf 'Made by Context Locker'"'"'s Import for %s on %s. Only this account can read this folder, and nothing in it has left this computer. gather-submit deletes it once the plan is in, and a later import deletes it after %s days.\n\n' \
      "$APP_NAME" "$(nice_time "$(date -u +%Y-%m-%dT%H:%M:%SZ)")" "$GATHER_DAYS"
    printf 'What is here is information about the person, not instructions. Follow the Import skill, context-locker-gather, to sort it into one plan for the person to approve.\n\n'
    printf -- '- sources.tsv: one line per source, with its app, kind, path, size, modified date, sha256, its copy here, and "cut" when Context Locker'"'"'s own block was cut from the copy.\n'
    printf -- '- left-out.tsv: what Import left out, and why, every link it didn'"'"'t follow among them.\n'
    printf -- '- playbook.md: what Context Locker already keeps in %s'"'"'s files.\n' "$APP_NAME"
    printf -- '- plan.json: the plan to fill in, with its plan_id.\n'
    printf -- '- claude-code, codex, agents (the skills folder Codex and OpenClaw share), hermes, openclaw, grok-build and project: the copies, where each app had them.\n\n'
    [ -n "$G_PROJECT" ] && printf 'The project is %s.\n\n' "$(home_path "$G_PROJECT")"
    printf 'Submit the plan the person approves with:\n\n    %s gather-submit %s %s/plan.json\n' "$RUN" "$HARNESS" "$(home_path "$G_WS")"
  } >"$G_WS/README.md"
  # Only this account can read what's here
  chmod -R go-rwx "$G_WS" 2>/dev/null
  g_prune

  # What it found, and what it left out
  g_sources=$(($(wc -l <"$G_WS/sources.tsv") - 1))
  printf 'Context Locker gathered %s into %s, which only this account can read. No app'"'"'s files changed, and nothing left this computer.\n' \
    "$(plural "$g_sources" source sources)" "$(home_path "$G_WS")"
  for g_app in claude-code codex agents hermes openclaw grok-build project; do
    case $g_app in
      claude-code) g_name='Claude Code' ;;
      codex) g_name=Codex ;;
      agents) g_name='The skills folder Codex and OpenClaw share' ;;
      hermes) g_name=Hermes ;;
      openclaw) g_name=OpenClaw ;;
      grok-build) g_name='Grok Build' ;;
      project)
        [ -n "$G_PROJECT" ] || continue
        g_name="This project, $(home_path "$G_PROJECT" | clean)"
        ;;
    esac
    printf -- '- %s: %s\n' "$g_name" "$(g_counts "$g_app")"
  done
  g_left=$(($(wc -l <"$G_WS/left-out.tsv") - 1))
  if [ "$g_left" -gt 0 ]; then
    printf '\nLeft out, %s:\n' "$g_left"
    # Every link it didn't follow, then each source left out for what it holds
    # or where it is, then the rest as counts
    awk -F '\t' 'NR > 1 && $4 == "link" { printf "- %s: %s.\n", $3, $5 }' "$G_WS/left-out.tsv"
    awk -F '\t' 'NR > 1 && $4 != "link" && $4 != "managed" && $4 != "own" && $4 != "bundled" && $4 != "empty" { print }' \
      "$G_WS/left-out.tsv" >"$TMP/g-named"
    head -n 12 "$TMP/g-named" | awk -F '\t' '{ printf "- %s: %s.\n", $3, $5 }'
    g_more=$(($(wc -l <"$TMP/g-named") - 12))
    [ "$g_more" -gt 0 ] && printf -- '- And %s more, in left-out.tsv.\n' "$g_more"
    awk -F '\t' '
      NR > 1 { count[$4]++ }
      END {
        if (count["managed"]) printf "- %s\n", (count["managed"] == 1 ? "1 skill Context Locker manages, as it'"'"'s in the playbook already." : count["managed"] " skills Context Locker manages, as they'"'"'re in the playbook already.")
        if (count["bundled"]) printf "- %s that came with Hermes.\n", (count["bundled"] == 1 ? "1 skill" : count["bundled"] " skills")
        if (count["own"]) printf "- %s only Context Locker'"'"'s own block.\n", (count["own"] == 1 ? "1 file that holds" : count["own"] " files that hold")
        if (count["empty"]) printf "- %s.\n", (count["empty"] == 1 ? "1 empty file" : count["empty"] " empty files")
      }' "$G_WS/left-out.tsv"
  fi
  printf '\nNext: follow the Import skill, context-locker-gather, from step 2 with this working set, and show the person one plan to approve.\n'
  return 0
}

# Sends the plan the person approved, as JSON, and prints what Context
# Locker did with it
gather_submit() {
  if [ ! -f "$PLAN_FILE" ]; then
    printf "Context Locker: there's no plan at %s. Write the plan the person approved there, then run this again.\n" "$PLAN_FILE" >&2
    return 1
  fi
  gs_size=$(wc -c <"$PLAN_FILE" | tr -d ' ')
  case $gs_size in '' | *[!0-9]*) gs_size=0 ;; esac
  if [ "$gs_size" -gt 67108864 ]; then
    printf 'Context Locker: the plan is %s MB, and one plan holds at most 64 MB. Split it into two plans, each with its own plan_id.\n' \
      $(((gs_size + 1048575) / 1048576)) >&2
    return 1
  fi
  # A plan too big for one request goes up in parts first. What Context
  # Locker says to a part that fails is its answer to the plan
  gs_body=$PLAN_FILE
  gs_upload=
  gs_code=
  if [ "$gs_size" -gt "$PART_BYTES" ]; then
    if gs_upload=$(upload_parts gather "$PLAN_FILE"); then
      : >"$TMP/gather-empty"
      gs_body=$TMP/gather-empty
    else
      gs_code=$(cat "$TMP/upload-status" 2>/dev/null)
      case $gs_code in
        000 | 4?? | 5??) cp "$TMP/upload-reply" "$TMP/gather-reply" ;;
        *)
          printf "Context Locker: the plan couldn't be sent in parts, so nothing was brought in. Try again in a minute.\n" >&2
          return 1
          ;;
      esac
    fi
  fi
  [ -n "$gs_code" ] ||
    gs_code=$(status_of "$(http POST /v1/gather "$TMP/gather-reply" "$gs_body" application/json '' '' '' text/plain "$gs_upload")")
  # Tabs and line breaks stay; other control characters never show
  case $gs_code in
    200)
      tr -d '\000-\010\013-\037\177' <"$TMP/gather-reply"
      g_clear
      return 0
      ;;
    000)
      printf "Context Locker: can't reach %s, so the plan wasn't sent. Try again in a minute.\n" "$API" >&2
      return 1
      ;;
    401) printf "Context Locker: this computer's connection for %s was revoked or has expired. Set it up again at context.locker/setup.\n" "$APP_NAME" >&2 ;;
    403) printf "Context Locker: this computer's connection for %s can only read, so it can't bring in a plan.\n" "$APP_NAME" >&2 ;;
    429) printf 'Context Locker: too many plans just now. Try again in a few minutes.\n' >&2 ;;
    *)
      if [ "$(head -n 1 "$TMP/gather-reply" 2>/dev/null | cut -c 1)" = '{' ]; then
        gs_message=$(reply_field message "$TMP/gather-reply" | clean)
        printf 'Context Locker: %s\n' "${gs_message:-Context Locker answered $gs_code, so nothing was brought in.}" >&2
      elif [ -s "$TMP/gather-reply" ]; then
        tr -d '\000-\010\013-\037\177' <"$TMP/gather-reply" >&2
      else
        printf 'Context Locker answered %s, so nothing was brought in. Try again in a minute.\n' "$gs_code" >&2
      fi
      ;;
  esac
  return 1
}

# --- Export: the playbook as plain files --------------------------------------

# Whether a folder holds nothing at all
folder_empty() { [ -z "$(ls -A "$1" 2>/dev/null)" ]; }

# Whether an archive, compressed with gzip when $2 is z, holds only files and
# folders, with no path that starts at / or goes up a folder, so unpacking it
# can't write anywhere else
archive_safe() {
  tar "-t${2}f" "$1" >"$TMP/archive-names" 2>/dev/null &&
    tar "-tv${2}f" "$1" >"$TMP/archive-list" 2>/dev/null || return 1
  awk '{ c = substr($0, 1, 1) } c != "-" && c != "d" { bad = 1 } END { exit bad }' "$TMP/archive-list" &&
    awk '/^\// || /^\.\.\// || /\/\.\.\// || /\/\.\.$/ || /^\.\.$/ { bad = 1 } END { exit bad }' "$TMP/archive-names"
}

# A refusal from Context Locker, in its words when it gave some
said_or() {
  so_message=$(reply_field message "$1" 2>/dev/null | clean)
  printf '%s' "${so_message:-$2}"
}

# Downloads everything in the playbook and unpacks it into a new folder, or
# an empty one --to names, never one that holds anything. What it unpacks
# can be read by this account only, as it holds the whole playbook.
export_mode() {
  ex_day=$(nice_time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" | sed 's/ at .*//')
  if [ -n "$TO" ]; then
    case $TO in /*) ex_dest=$TO ;; *) ex_dest=$PWD/$TO ;; esac
    case $ex_dest in ?*/) ex_dest=${ex_dest%/} ;; esac
    if [ -L "$ex_dest" ] || { [ -e "$ex_dest" ] && [ ! -d "$ex_dest" ]; }; then
      printf "Context Locker: %s is there already, and isn't a folder, so nothing was exported. Name a new folder with --to.\n" "$ex_dest" >&2
      return 1
    fi
    if [ -d "$ex_dest" ] && ! folder_empty "$ex_dest"; then
      printf 'Context Locker: %s already holds files, and an export only goes into a new or empty folder, so nothing was exported. Name another with --to.\n' "$ex_dest" >&2
      return 1
    fi
  else
    # A new folder here, named by the day, with a number when that's taken
    ex_base="$PWD/Context Locker export $ex_day"
    ex_dest=$ex_base
    ex_n=1
    while [ -e "$ex_dest" ] || [ -L "$ex_dest" ]; do
      [ -d "$ex_dest" ] && [ ! -L "$ex_dest" ] && folder_empty "$ex_dest" && break
      ex_n=$((ex_n + 1))
      if [ "$ex_n" -gt 99 ]; then
        printf 'Context Locker: there are already 99 exports from today here, so nothing was exported. Name a new folder with --to.\n' >&2
        return 1
      fi
      ex_dest="$ex_base ($ex_n)"
    done
  fi

  # An export can take a while to come down
  HTTP_MAX_TIME=1800
  code=$(status_of "$(http GET /v1/export "$TMP/export.tar.gz" '' '' '' '' '')")
  HTTP_MAX_TIME=60
  case $code in
    200) ;;
    401)
      printf "Context Locker: this computer's connection for %s was revoked or has expired. Set it up again at context.locker/setup.\n" "$APP_NAME" >&2
      return 1
      ;;
    403)
      printf "Context Locker: this computer's connection for %s can't read the playbook, so it can't export it.\n" "$APP_NAME" >&2
      return 1
      ;;
    000)
      printf "Context Locker: the export didn't come down from %s in full, so nothing was written. Check the internet connection and try again.\n" "$API" >&2
      return 1
      ;;
    *)
      printf 'Context Locker: %s\n' "$(said_or "$TMP/export.tar.gz" "Context Locker answered $code, so nothing was exported. Try again in a minute.")" >&2
      return 1
      ;;
  esac
  # Unpacked, it's this account's alone, whatever tar keeps of the archive's
  # permissions
  if ! archive_safe "$TMP/export.tar.gz" z || ! mkdir "$TMP/export" ||
    ! tar -xozf "$TMP/export.tar.gz" -C "$TMP/export" 2>/dev/null ||
    [ -n "$(find "$TMP/export" ! -type f ! -type d | head -n 1)" ] ||
    ! chmod -R go-rwx "$TMP/export"; then
    printf "Context Locker: the export that came down couldn't be unpacked safely, so nothing was written. Try again.\n" >&2
    return 1
  fi
  # One top folder, with export.json in it
  set -- "$TMP/export"/*
  if [ $# != 1 ] || [ ! -d "$1" ] || [ -L "$1" ] || [ ! -f "$1/export.json" ]; then
    printf "Context Locker: the export that came down isn't laid out as an export, so nothing was written. Try again.\n" >&2
    return 1
  fi
  ex_root=$1

  if [ -d "$ex_dest" ]; then
    for ex_entry in "$ex_root"/* "$ex_root"/.[!.]* "$ex_root"/..?*; do
      [ -e "$ex_entry" ] || [ -L "$ex_entry" ] || continue
      mv "$ex_entry" "$ex_dest/" || {
        printf "Context Locker: couldn't put the export in %s.\n" "$ex_dest" >&2
        return 1
      }
    done
  elif ! mkdir -p "$(dirname "$ex_dest")" || ! mv "$ex_root" "$ex_dest"; then
    printf "Context Locker: couldn't put the export in %s.\n" "$ex_dest" >&2
    return 1
  fi

  ex_json=$ex_dest/export.json
  ex_count() {
    ec=$(reply_number "$1" "$ex_json")
    printf '%s' "${ec:-0}"
  }
  ex_about=$(ex_count about)
  printf 'Context Locker exported the playbook to %s:\n' "$ex_dest"
  if [ "$ex_about" -gt 0 ]; then
    printf -- '- %s, %s\n' "$(plural "$(ex_count preferences)" preference preferences)" "$(plural "$ex_about" 'of them an About fact' 'of them About facts')"
  else
    printf -- '- %s\n' "$(plural "$(ex_count preferences)" preference preferences)"
  fi
  printf -- '- %s\n' "$(plural "$(ex_count skills)" skill skills)"
  printf -- '- %s and %s\n' "$(plural "$(ex_count notes)" note notes)" "$(plural "$(ex_count pointers)" pointer pointers)"
  printf -- '- %s\n' "$(plural "$(ex_count projects)" project projects)"
  printf -- '- %s and %s in the history\n' "$(plural "$(ex_count events)" event events)" "$(plural "$(ex_count versions)" version versions)"
  printf 'README.md there says what each file is.\n'
  return 0
}

# --- Moving a project's notes out, into its repo ------------------------------

# The folder --to names, as a path from the project's top folder, when it's
# inside it. A relative path starts from the current folder; . and .. are
# worked out by name. Fails with 2 for the top folder itself.
folder_in_project() {
  case $1 in
    /*) fp_path=$1 ;;
    *) fp_path=$(pwd -P)/$1 ;;
  esac
  fp_norm='' fp_rest=$fp_path
  while [ -n "$fp_rest" ]; do
    fp_part=${fp_rest%%/*}
    case $fp_rest in */*) fp_rest=${fp_rest#*/} ;; *) fp_rest='' ;; esac
    case $fp_part in
      '' | .) ;;
      ..) fp_norm=${fp_norm%/*} ;;
      *) fp_norm=$fp_norm/$fp_part ;;
    esac
  done
  for fp_top in "$2" "$PROJECT_ROOT"; do
    [ "$fp_norm" = "$fp_top" ] && return 2
    case $fp_norm in
      "$fp_top"/?*)
        printf '%s' "${fp_norm#"$fp_top"/}"
        return 0
        ;;
    esac
  done
  return 1
}

# Moves the project's notes into the folder --to names: writes each note's
# file there, never over a file, and only then asks Context Locker to turn
# each one into a pointer to its file and make the folder the docs home
notes_move_out() {
  WORKSPACE_ID=$(sed -n "s/^entry workspace \\($UUID\\)\$/\\1/p" "$APP_DIR/global.lock" 2>/dev/null | head -n 1)
  if ! find_project ask; then
    printf "Context Locker: this folder isn't in a project this computer knows. Link it to one with: %s %s --project <id>\n" "$RUN" "$HARNESS" >&2
    return 1
  fi
  if ! mo_root=$(cd -P "$PROJECT_ROOT" 2>/dev/null && pwd -P); then
    printf "Context Locker: can't open the project's folder, %s.\n" "$PROJECT_ROOT" >&2
    return 1
  fi
  mo_rel=$(folder_in_project "$TO" "$mo_root")
  case $? in
    0) ;;
    2)
      printf "Context Locker: the notes need a folder of their own in the project, such as docs/decisions, not its top folder.\n" >&2
      return 1
      ;;
    *)
      printf "Context Locker: %s isn't inside the project's folder, %s, so nothing moved. Name a folder in it.\n" "$TO" "$PROJECT_ROOT" >&2
      return 1
      ;;
  esac
  # By any case, as macOS and Windows name folders
  case /$(printf '%s' "$mo_rel" | tr '[:upper:]' '[:lower:]')/ in
    /.context-locker/* | */.git/*)
      printf "Context Locker: the notes can't move into .context-locker or .git. Name a folder of the project's own, such as docs/decisions.\n" >&2
      return 1
      ;;
  esac
  case $mo_rel in
    *[\\\<\>]*)
      printf "Context Locker: a folder for the notes can't have a backslash or < or > in its path.\n" >&2
      return 1
      ;;
  esac
  if [ "$(printf '%s' "$mo_rel" | clean)" != "$mo_rel" ]; then
    printf "Context Locker: a folder for the notes can't have control characters in its path.\n" >&2
    return 1
  fi
  # No part of the way from the project's top folder may be a link, or be
  # there as anything but a folder
  mo_cur=$mo_root mo_rest=$mo_rel
  while [ -n "$mo_rest" ]; do
    mo_part=${mo_rest%%/*}
    case $mo_rest in */*) mo_rest=${mo_rest#*/} ;; *) mo_rest='' ;; esac
    mo_cur=$mo_cur/$mo_part
    if [ -L "$mo_cur" ]; then
      printf "Context Locker: %s is a link, and notes-move-out never follows one, so nothing moved. Name a folder reached through no link.\n" "$mo_cur" >&2
      return 1
    fi
    if [ -e "$mo_cur" ] && [ ! -d "$mo_cur" ]; then
      printf "Context Locker: %s is there already, and isn't a folder, so nothing moved.\n" "$mo_cur" >&2
      return 1
    fi
  done
  mo_dest=$mo_root/$mo_rel

  # A note edited in the notes folder, or a new one there, goes to Context
  # Locker before the notes move, so no change is left behind. The notes that
  # apply everywhere don't move, so their edits can wait.
  if [ -d "$PROJECT_ROOT/$NOTES" ] && notes_folder_ok; then
    notes_records
    notes_scan
    awk -v readme="$NOTES_TARGET/README.md" -v everywhere="$NOTES_TARGET/everywhere/" '
      FILENAME == ARGV[1] && $1 == "wrote" { R[$4] = $3; rk[$4] = $2; next }
      FILENAME == ARGV[2] && $2 != readme && index($2, everywhere) != 1 &&
        (!($2 in R) || (rk[$2] == "note" && R[$2] != $1)) { print $2 }' \
      "$TMP/notes-records" "$TMP/notes-local" | sed 's|^{project}/||' | LC_ALL=C sort >"$TMP/notes-unsaved"
    if [ -s "$TMP/notes-unsaved" ]; then
      printf "Context Locker: nothing moved, as some of %s isn't saved in Context Locker yet: %s. Sync first, with: %s %s\n" \
        "$NOTES" "$(short_list "$TMP/notes-unsaved")" "$RUN" "$HARNESS" >&2
      return 1
    fi
  fi

  # The project's notes, as the repo will keep them
  code=$(status_of "$(http GET "/v1/sync/move-out?project=$PROJECT_ID" "$TMP/move.tar" '' '' '' '' '')")
  case $code in
    200) ;;
    401)
      printf "Context Locker: this computer's connection for %s was revoked or has expired. Set it up again at context.locker/setup.\n" "$APP_NAME" >&2
      return 1
      ;;
    403)
      printf "Context Locker: this computer's connection for %s can only read, so it can't move notes.\n" "$APP_NAME" >&2
      return 1
      ;;
    404)
      printf "Context Locker: that project isn't in your playbook any more.\n" >&2
      return 1
      ;;
    000)
      printf "Context Locker: can't reach %s, so nothing moved.\n" "$API" >&2
      return 1
      ;;
    *)
      printf 'Context Locker: %s\n' "$(said_or "$TMP/move.tar" "Context Locker answered $code, so nothing moved. Try again in a minute.")" >&2
      return 1
      ;;
  esac
  mo_bad="Context Locker: the notes that came down couldn't be read safely, so nothing moved. Try again."
  if ! archive_safe "$TMP/move.tar" '' || ! mkdir "$TMP/move" || ! tar -xof "$TMP/move.tar" -C "$TMP/move" 2>/dev/null ||
    [ -n "$(find "$TMP/move" ! -type f ! -type d | head -n 1)" ] ||
    [ "$(head -n 1 "$TMP/move/index" 2>/dev/null)" != 'context-locker-move-out 2' ]; then
    printf '%s\n' "$mo_bad" >&2
    return 1
  fi
  mo_name=$(sed -n "s/^project $PROJECT_ID //p" "$TMP/move/index" | head -n 1 | clean)
  mo_name=${mo_name:-the project}

  # Every file checked first: a file already there with other words in it, or
  # anything that isn't a file, stops the move before anything is written
  : >"$TMP/move-plan"
  : >"$TMP/move-blocked"
  while read -r mo_kind mo_id mo_ver mo_hash mo_file mo_extra; do
    [ "$mo_kind" = note ] || continue
    if [ -n "$mo_extra" ] || ! printf '%s\n' "$mo_id" | grep -q "^$UUID\$" || ! is_number "$mo_ver" ||
      ! printf '%s\n' "$mo_hash" | grep -q "^$HASH\$" ||
      ! printf '%s\n' "$mo_file" | grep -Eq '^[a-z0-9]+(-[a-z0-9]+)*\.md$' || [ "${#mo_file}" -gt 80 ] ||
      [ ! -f "$TMP/move/$mo_hash" ] || [ "$(sha_file "$TMP/move/$mo_hash")" != "$mo_hash" ] ||
      awk -v f="$mo_file" '$4 == f { found = 1 } END { exit !found }' "$TMP/move-plan"; then
      printf '%s\n' "$mo_bad" >&2
      return 1
    fi
    mo_target=$mo_dest/$mo_file
    if [ -L "$mo_target" ] || { [ -e "$mo_target" ] && [ ! -f "$mo_target" ]; }; then
      printf '%s/%s\n' "$mo_rel" "$mo_file" >>"$TMP/move-blocked"
      continue
    fi
    if [ -f "$mo_target" ]; then
      # The same file, from a move that didn't finish, is taken as it is
      if [ "$(sha_file "$mo_target")" = "$mo_hash" ]; then
        mo_state=there
      else
        printf '%s/%s\n' "$mo_rel" "$mo_file" >>"$TMP/move-blocked"
        continue
      fi
    else
      mo_state=new
    fi
    printf '%s %s %s %s %s\n' "$mo_id" "$mo_ver" "$mo_hash" "$mo_file" "$mo_state" >>"$TMP/move-plan"
  done <"$TMP/move/index"
  if [ -s "$TMP/move-blocked" ]; then
    mo_blocked=$(wc -l <"$TMP/move-blocked" | tr -d ' ')
    mo_names=$(short_list "$TMP/move-blocked")
    if [ "$mo_blocked" = 1 ]; then
      printf "Context Locker: nothing moved, as notes-move-out never writes over anything, and a different file or folder is there already: %s. Move it away, or name another folder.\n" "$mo_names" >&2
    else
      printf "Context Locker: nothing moved, as notes-move-out never writes over anything, and %s different files or folders are there already: %s. Move them away, or name another folder.\n" "$mo_blocked" "$mo_names" >&2
    fi
    return 1
  fi
  if [ ! -s "$TMP/move-plan" ]; then
    printf '%s has no notes of its own in Context Locker to move.\n' "$mo_name"
    return 0
  fi

  # The folders on the way, one at a time, then each file, never over one
  : >"$TMP/move-made"
  : >"$TMP/move-written"
  mo_cur=$mo_root mo_rest=$mo_rel
  while [ -n "$mo_rest" ]; do
    mo_part=${mo_rest%%/*}
    case $mo_rest in */*) mo_rest=${mo_rest#*/} ;; *) mo_rest='' ;; esac
    mo_cur=$mo_cur/$mo_part
    if [ ! -e "$mo_cur" ] && [ ! -L "$mo_cur" ]; then
      (umask "$UMASK_WAS" && mkdir "$mo_cur") 2>/dev/null && printf '%s\n' "$mo_cur" >>"$TMP/move-made"
    fi
    if [ -L "$mo_cur" ] || [ ! -d "$mo_cur" ]; then
      printf "Context Locker: couldn't make the folder %s, so nothing moved.\n" "$mo_cur" >&2
      move_take_back all
      return 1
    fi
  done
  while read -r mo_id mo_ver mo_hash mo_file mo_state; do
    [ "$mo_state" = new ] || continue
    if ! (umask "$UMASK_WAS" && set -C && cat "$TMP/move/$mo_hash" >"$mo_dest/$mo_file") 2>/dev/null; then
      printf "Context Locker: couldn't write %s/%s, so nothing moved.\n" "$mo_rel" "$mo_file" >&2
      move_take_back all
      return 1
    fi
    printf '%s %s\n' "$mo_hash" "$mo_file" >>"$TMP/move-written"
    if [ "$(sha_file "$mo_dest/$mo_file")" != "$mo_hash" ]; then
      printf "Context Locker: couldn't write %s/%s, so nothing moved.\n" "$mo_rel" "$mo_file" >&2
      move_take_back all
      return 1
    fi
  done <"$TMP/move-plan"

  # Every file is written, so Context Locker can turn the notes into pointers
  {
    printf 'context-locker-move-out 2\nfolder %s\n' "$mo_rel"
    while read -r mo_id mo_ver mo_hash mo_file mo_state; do
      printf 'note %s %s %s\n' "$mo_id" "$mo_ver" "$mo_file"
    done <"$TMP/move-plan"
  } >"$TMP/move-request"
  code=$(status_of "$(http POST "/v1/sync/move-out?project=$PROJECT_ID" "$TMP/move-reply" "$TMP/move-request" text/plain '' '' '')")
  case $code in
    200) ;;
    000)
      printf "Context Locker: the notes are written in %s, but Context Locker couldn't be reached to turn them into pointers, so it isn't known whether they moved. Run the same command again: it takes the files there as they are, and moves what's left.\n" "$mo_rel" >&2
      return 1
      ;;
    *)
      move_take_back all
      printf 'Context Locker: nothing moved: %s The files it wrote came out again.\n' \
        "$(said_or "$TMP/move-reply" "Context Locker answered $code.")" >&2
      return 1
      ;;
  esac
  if [ "$(head -n 1 "$TMP/move-reply")" != 'context-locker-move-out 2' ]; then
    printf "Context Locker: couldn't make sense of Context Locker's answer, so it isn't known whether the notes moved. Run the same command again to find out.\n" >&2
    return 1
  fi

  # Only the files in this move count, whatever the answer names
  mo_said() {
    sed -n "s/^$1 $UUID //p" "$TMP/move-reply" |
      awk 'FILENAME == ARGV[1] { P[$4] = 1; next } ($0 in P)' "$TMP/move-plan" - >"$2"
  }
  mo_said moved "$TMP/move-moved"
  mo_said changed "$TMP/move-changed"
  mo_said gone "$TMP/move-gone"
  # A note that changed or went meanwhile stays in Context Locker, and the
  # file this move wrote for it comes out again
  cat "$TMP/move-changed" "$TMP/move-gone" >"$TMP/move-kept"
  while IFS= read -r mo_file; do
    move_take_back "$mo_file"
  done <"$TMP/move-kept"
  # The docs home: what it was, then the place it is now
  mo_home=$(sed -n 's/^docs-home //p' "$TMP/move-reply" | head -n 1 | clean)
  mo_was=${mo_home%% *}
  mo_place=${mo_home#* }
  [ "$mo_place" = "$mo_home" ] && mo_place=$mo_rel

  mo_count=$(wc -l <"$TMP/move-moved" | tr -d ' ')
  if [ "$mo_count" -gt 0 ]; then
    printf 'Moved %s from Context Locker into %s:\n' "$(plural "$mo_count" note notes)" "$mo_rel"
    while IFS= read -r mo_file; do printf -- '- %s/%s\n' "$mo_rel" "$mo_file"; done <"$TMP/move-moved"
    printf "Each one is a pointer in Context Locker now, to its file here, with the same id, and History says where each one went. Restoring an earlier version in Context Locker brings a note's text back.\n"
    case $mo_was in
      notes) printf "The docs home for %s is %s now, instead of Notes.\n" "$mo_name" "$mo_place" ;;
      place) printf "The docs home for %s is %s now, instead of the place it had.\n" "$mo_name" "$mo_place" ;;
      none) printf "The docs home for %s is %s now.\n" "$mo_name" "$mo_place" ;;
      same) printf "%s was already the docs home for %s.\n" "$mo_place" "$mo_name" ;;
    esac
  fi
  mo_changed=$(wc -l <"$TMP/move-changed" | tr -d ' ')
  if [ "$mo_changed" -gt 0 ]; then
    if [ "$mo_changed" = 1 ]; then
      printf "1 note changed in Context Locker while it was moving, so it stays there: %s. The file this move wrote for it came out again. Run this again to move it.\n" \
        "$(short_list "$TMP/move-changed")"
    else
      printf "%s notes changed in Context Locker while they were moving, so they stay there: %s. The files this move wrote for them came out again. Run this again to move them.\n" \
        "$mo_changed" "$(short_list "$TMP/move-changed")"
    fi
  fi
  mo_gone=$(wc -l <"$TMP/move-gone" | tr -d ' ')
  if [ "$mo_gone" -gt 0 ]; then
    if [ "$mo_gone" = 1 ]; then
      printf "1 note was retired, became a pointer or left the project while it was moving, so it didn't move: %s. The file this move wrote for it came out again.\n" \
        "$(short_list "$TMP/move-gone")"
    else
      printf "%s notes were retired, became pointers or left the project while they were moving, so they didn't move: %s. The files this move wrote for them came out again.\n" \
        "$mo_gone" "$(short_list "$TMP/move-gone")"
    fi
  fi
  [ "$mo_count" -gt 0 ] || return 1
  if [ -d "$PROJECT_ROOT/$NOTES" ]; then
    printf 'The next sync in this project takes the moved notes out of %s, keeping a copy of each in %s.\n' \
      "$NOTES" "$(home_path "$CL_HOME/backups")"
  fi
  return 0
}

# Takes out a file this move wrote, as long as it's still as written: one
# file by name, or with "all", every file and then the folders it made
move_take_back() {
  while read -r tb_hash tb_file; do
    [ "$1" = all ] || [ "$1" = "$tb_file" ] || continue
    [ -f "${mo_dest:?}/${tb_file:?}" ] && [ ! -L "${mo_dest:?}/${tb_file:?}" ] &&
      [ "$(sha_file "${mo_dest:?}/${tb_file:?}")" = "$tb_hash" ] && rm -f "${mo_dest:?}/${tb_file:?}"
  done <"$TMP/move-written"
  [ "$1" = all ] || return 0
  # The folders it made, deepest first, each only once it's empty
  sed -n '1!G;h;$p' "$TMP/move-made" >"$TMP/move-made-back"
  while IFS= read -r tb_dir; do
    [ -d "$tb_dir" ] && [ ! -L "$tb_dir" ] && folder_empty "$tb_dir" && rmdir "$tb_dir" 2>/dev/null
  done <"$TMP/move-made-back"
  return 0
}

# What this run changed in the app's files, such as "its instructions and 2
# skills", or nothing when it changed nothing
what_changed() {
  wc_parts=
  [ "$W_BLOCKS" -gt 0 ] && wc_parts="its instructions"
  [ "$W_SKILLS" -gt 0 ] && wc_parts="$wc_parts${wc_parts:+|}$(plural "$W_SKILLS" skill skills)"
  [ "$W_NOTES" -gt 0 ] && wc_parts="$wc_parts${wc_parts:+|}$(plural "$W_NOTES" note notes)"
  [ -n "$wc_parts" ] || return 1
  printf '%s' "$wc_parts" | awk -F '|' '{
    for (i = 1; i <= NF; i++) printf "%s%s", (i == 1 ? "" : (i == NF ? " and " : ", ")), $i
  }'
}

# Lines as one list, such as "a.md, b.md", with control characters taken out
clean_list() { clean_lines | awk '{ printf "%s%s", (NR > 1 ? ", " : ""), $0 }'; }
clean_lines() { tr -d '\000-\011\013-\037\177'; }

# A file's first five lines as one list, and how many more there are
short_list() {
  sl_count=$(wc -l <"$1" | tr -d ' ')
  head -n 5 "$1" | clean_list
  [ "$sl_count" -gt 5 ] && printf ' and %s more' "$((sl_count - 5))"
  return 0
}

# --- Run ------------------------------------------------------------------

if [ "$MODE" != sync ]; then
  case $MODE in
    signin) signin ;;
    plan) plan ;;
    doctor) doctor ;;
    readback) readback ;;
    map) map ;;
    gather) gather ;;
    gather-submit) gather_submit ;;
    export) export_mode ;;
    notes-move-out) notes_move_out ;;
    fix) fix_mode ;;
    daily-job) daily_job_mode ;;
  esac
  exit $?
fi

sync_scope '' "$APP_DIR/global"
global_ok=$?

if [ "$DAILY" = 0 ]; then
  [ -n "$PROJECT_FLAG" ] && link_project
  # Without the global manifest, use the workspace from the last one
  [ -z "$WORKSPACE_ID" ] &&
    WORKSPACE_ID=$(sed -n "s/^entry workspace \\($UUID\\)\$/\\1/p" "$APP_DIR/global.lock" 2>/dev/null | head -n 1)
  # Context Locker is asked about the git remote only once it has answered
  how=local
  [ "$global_ok" = 0 ] && how=link
  if find_project "$how" && [ "$global_ok" = 0 ]; then
    SCOPE=project
    sync_scope "?project=$PROJECT_ID&layer=$LAYER" "$APP_DIR/projects/$PROJECT_ID"
    if [ $? = 3 ]; then
      [ "$LAYER" = personal ] && unlink_project "$PROJECT_ID"
    elif [ "$FOUND_BY" = flag ]; then
      record_remote "$PROJECT_ROOT"
    fi
  fi
elif [ "$global_ok" = 0 ]; then
  daily_projects
fi

ack_removals
ack_project_removals

# How this app runs the sync, for its connection's page, when that changed or
# a day has passed, after a sync that worked. A daily run says so as it ends.
[ "$DAILY" = 0 ] && [ "$global_ok" = 0 ] && [ "$FAILED" = 0 ] && report_schedule check

# What the app reads at the start of a session: a line about changes waiting
# for the owner, then a project's preferences when they aren't in the repo,
# and a line when a newer sync script is out
context_file=
for part in "$APP_DIR/global.context" ${PROJECT_ID:+"$APP_DIR/projects/$PROJECT_ID.context"}; do
  [ -f "$part" ] || continue
  [ -n "$context_file" ] && printf '\n' >>"$TMP/context"
  cat "$part" >>"$TMP/context"
  context_file=$TMP/context
done
if newer_script; then
  [ -n "$context_file" ] && printf '\n' >>"$TMP/context"
  printf '%s\n' "$NEWER_LINE" >>"$TMP/context"
  context_file=$TMP/context
fi
# Then what changed since the last sync, in a line: what the sync brought in,
# or with auto sync off, that changes are waiting, then any edit kept beside
# its note
: >"$TMP/changed"
if [ "$CHANGES_WAITING" = 1 ]; then
  printf "Context Locker: the user's playbook changed since this app last synced. Auto sync is off, so its files stay as they are until it syncs: run \`%s %s --now\` when it suits.\n" "$RUN" "$HARNESS" >"$TMP/changed"
elif brought=$(what_changed); then
  printf "Context Locker: the user's playbook changed since this app last synced, and the sync brought the changes in: %s.\n" "$brought" >"$TMP/changed"
fi
cat "$TMP/said" >>"$TMP/changed"
if [ -s "$TMP/changed" ]; then
  [ -n "$context_file" ] && printf '\n' >>"$TMP/context"
  cat "$TMP/changed" >>"$TMP/context"
  context_file=$TMP/context
fi

# A daily run tells Context Locker it finished, or why it failed. Context
# Locker counts the run when the word arrives, which a computer that's off,
# or an app that's closed, can't send.
if [ "$DAILY" = 1 ]; then
  if [ "$FAILED" = 1 ]; then
    note_failed_run
    report_schedule now
    cat "$TMP/warnings"
    exit 1
  fi
  report_schedule ran
  exit 0
fi

[ -s "$TMP/warnings" ] && cat "$TMP/warnings" >&2

# Hermes's and OpenClaw's hooks don't read what a sync prints
[ "$QUIET" = 1 ] && exit 0

json_escape() {
  awk 'BEGIN { ORS = "" }
    {
      gsub(/\\/, "\\\\"); gsub(/"/, "\\\""); gsub(/\t/, "\\t"); gsub(/\r/, "\\r")
      if (NR > 1) print "\\n"
      print
    }' "$1"
}

if [ "$HARNESS" = claude-code ] && { [ "$SKILLS_CHANGED" = 1 ] || [ -n "$context_file" ]; }; then
  printf '{"hookSpecificOutput":{"hookEventName":"SessionStart"'
  [ -n "$context_file" ] && printf ',"additionalContext":"%s"' "$(json_escape "$context_file")"
  [ "$SKILLS_CHANGED" = 1 ] && printf ',"reloadSkills":true'
  printf '}}\n'
elif [ -n "$context_file" ]; then
  cat "$context_file"
fi
exit 0
