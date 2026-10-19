#!/bin/sh
# Context Locker sync, version 2. MIT licence.
#
#   sh sync.sh <app> [--project <id>] [--daily]
#   sh sync.sh signin|plan|doctor|readback <app>
#
# Keeps one AI app's files in step with your playbook at context.locker. <app>
# is claude-code, codex, hermes or openclaw. The script asks for a manifest of
# what the app's files should hold, writes only what changed, and sends any
# edit it finds in a synced file back to Context Locker. It writes only inside
# Context Locker's marked blocks and skill folders, backs up anything it
# replaces that it didn't write, and never deletes a file of yours. When
# Context Locker can't be reached, the app keeps the files it has.
#
# --project <id> links the current folder to a project, for this computer only.
# --daily is for scheduled runs: silent when all is well, exit 1 when not.
#
# For setup (see context.locker/setup):
#   signin    connects the app with a code you approve in your browser. The
#             first run prints the link and the code and exits 3. Run it again
#             to wait up to --wait seconds (50) for the approval: it exits 0
#             once connected, and 3 while still waiting.
#   plan      shows what a sync would write, and the hook or daily job to add.
#             It changes nothing.
#   doctor    checks the connection, the files and the hook or daily job
#   readback  prints what Context Locker has put in the app's files
set -u
umask 077

SCRIPT_VERSION=2
MODE=sync
case ${1:-} in
  signin | plan | doctor | readback)
    MODE=$1
    shift
    ;;
esac
HARNESS=${1:-}
[ $# -gt 0 ] && shift
DAILY=0
PROJECT_FLAG=
WAIT=50
while [ $# -gt 0 ]; do
  case $1 in
    --daily) DAILY=1 ;;
    --project)
      PROJECT_FLAG=${2:-}
      [ $# -gt 1 ] && shift
      ;;
    --wait)
      WAIT=${2:-}
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
  printf 'Usage: sh sync.sh <app> [--project <id>] [--daily]\n       sh sync.sh signin|plan|doctor|readback <app>\n<app> is claude-code, codex, hermes or openclaw.\n' >&2
  exit 2
}
case $HARNESS in
  claude-code | codex | hermes | openclaw) ;;
  *) usage ;;
esac
case $WAIT in '' | *[!0-9]*) usage ;; esac

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

for tool in curl tar awk sed find mkdir mktemp; do
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
if [ "$MODE" = sync ] || [ "$MODE" = plan ]; then
  problem=$(token_problem) && finish_early "$problem"
fi

# Only a sync needs the projects folder, so plan leaves no trace
case $MODE in
  sync) mkdir -p "$APP_DIR/projects" ;;
  signin) mkdir -p "$APP_DIR" ;;
  *) mkdir -p "$CL_HOME" ;;
esac || finish_early "can't write to $CL_HOME."
TMP=$(mktemp -d "$CL_HOME/tmp.XXXXXX") || finish_early "can't write to $CL_HOME."
: >"$TMP/warnings"
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

# --- The API --------------------------------------------------------------

# Prints the HTTP status, or 000 when Context Locker can't be reached. The
# token goes to curl on stdin, never on the command line.
http() {
  method=$1 path=$2 out=$3 body=$4 type=$5 etag=$6 target=$7 base=$8
  set -- -K - -sS --connect-timeout 5 --max-time 60 -o "$out" -w '%{http_code}' \
    -A "context-locker-sync/$SCRIPT_VERSION ($HARNESS; sh)" -X "$method"
  [ -n "$etag" ] && set -- "$@" -H "If-None-Match: \"$etag\""
  [ -n "$type" ] && set -- "$@" -H "Content-Type: $type"
  [ -n "$target" ] && set -- "$@" -H "Context-Locker-Target: $target"
  [ -n "$base" ] && set -- "$@" -H "Context-Locker-Base: $base"
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
  code=$(status_of "$(http POST "/v1/sync/edits$query" "$TMP/edit-reply" "$TMP/edit" "$type" '' "$t" "$recorded")")
  case $code in
    200) reply_field status "$TMP/edit-reply" ;;
    000) printf 'offline' ;;
    4??) printf 'refused' ;;
    *) printf 'error' ;;
  esac
}

# --- One sync: global, or one project ---------------------------------------

# In a plan, what each step would do, in plain words
planned() { [ "$MODE" = plan ] && printf '%s\n' "$*" >>"$TMP/plan-out"; return 0; }

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

  # One line per target: what the manifest says, what this script last wrote,
  # edits waiting for approval, and edits the API refused
  awk '
    FILENAME == ARGV[1] && ($1 == "block" || $1 == "skill") {
      kind[$3] = $1; S[$3] = $2; order[++n] = $3
      item[$3] = ($1 == "skill" ? $4 : "-"); ver[$3] = ($1 == "skill" ? $5 : "-")
      next
    }
    FILENAME == ARGV[1] && $1 == "hold" { H[$3] = (H[$3] == "" ? $2 : H[$3] "," $2); next }
    FILENAME == ARGV[2] && $1 == "wrote" { R[$4] = $3; rk[$4] = $2; next }
    FILENAME == ARGV[2] && $1 == "refused" { F[$3] = (F[$3] == "" ? $2 : F[$3] "," $2); next }
    END {
      for (i = 1; i <= n; i++) {
        t = order[i]; seen[t] = 1
        print t, kind[t], S[t], (t in R ? R[t] : "-"), (t in H ? H[t] : "-"), (t in F ? F[t] : "-"), item[t], ver[t]
      }
      for (t in R) if (!(t in seen)) print t, rk[t], "-", R[t], (t in H ? H[t] : "-"), (t in F ? F[t] : "-"), "-", "-"
    }' "$TMP/entries" "$lockfile" >"$TMP/plan"

  : >"$TMP/actions"
  : >"$TMP/wrote"
  : >"$TMP/refused"
  : >"$TMP/skipped"
  complete=1

  while read -r t kind S R holds refused item ver <&3; do
    if ! allowed "$t" "$kind"; then
      warn "skipped $t: it isn't a file $HARNESS's sync may write."
      planned "Skip $t: it isn't a file $APP_NAME's sync may write."
      printf 'skipped not-allowed %s\n' "$t" >>"$TMP/skipped"
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

  # Text for the session start, kept on this computer so it shows offline too
  context_hash=$(sed -n "s/^context \\($HASH\\)\$/\\1/p" "$TMP/entries" | head -n 1)
  if [ -z "$context_hash" ]; then
    rm -f "$state.context"
  elif [ ! -f "$state.context" ] || [ "$(sha_file "$state.context")" != "$context_hash" ]; then
    printf 'context %s - %s - - 0\n' "$context_hash" "$context_hash" >>"$TMP/actions"
  fi

  # Fetch everything that needs writing in one request
  awk '$1 == "write" || $1 == "context" { print $4 }' "$TMP/actions" | sort -u >"$TMP/want"
  rm -rf "$TMP/blobs"
  mkdir "$TMP/blobs"
  if [ -s "$TMP/want" ]; then
    code=$(status_of "$(http POST "/v1/sync/blobs$query" "$TMP/blobs.tar" "$TMP/want" text/plain '' '' '')")
    if [ "$code" != 200 ] || ! tar -xmof "$TMP/blobs.tar" -C "$TMP/blobs" 2>/dev/null ||
      [ -n "$(find "$TMP/blobs" ! -type f ! -type d | head -n 1)" ]; then
      warn "couldn't fetch the latest files, so $HARNESS keeps the ones it has. The next sync tries again."
      FAILED=1
      return 1
    fi
  fi

  while read -r action t kind hash item ver keep <&3; do
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
          printf 'wrote skill %s %s\n' "$hash" "$t" >>"$TMP/wrote"
        else
          warn "couldn't write $path."
          complete=0
        fi
        ;;
      'remove block')
        remove_block "$path" "$t" || complete=0
        ;;
      'remove skill')
        if backup "$path" "$t"; then
          rm -rf "$path"
          SKILLS_CHANGED=1
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
    esac
  done 3<"$TMP/actions"

  {
    printf 'context-locker-lock 1\n'
    [ "$complete" = 1 ] && printf 'etag %s\n' "$etag"
    printf 'synced %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    sed 's/^/entry /' "$TMP/entries"
    cat "$TMP/wrote" "$TMP/refused"
  } >"$lockfile.tmp" && mv -f "$lockfile.tmp" "$lockfile"

  [ "$complete" = 1 ] || FAILED=1
  if [ "$fresh" = 1 ] && [ "$complete" = 1 ]; then
    {
      printf 'manifest %s\nwritten %s\nheld %s\n' "$etag" "$WRITTEN" "$HELD"
      head -n 100 "$TMP/skipped"
    } >"$TMP/report"
    http POST "/v1/sync/done$query" "$TMP/done-reply" "$TMP/report" text/plain '' '' '' >/dev/null
  fi
  return 0
}

# --- Which project this session is in ---------------------------------------

WORKSPACE_ID=
detect_project() {
  start=${CLAUDE_PROJECT_DIR:-$PWD}
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

  # Folders linked on this computer only: "<project id> <folder>" per line
  [ -f "$CL_HOME/projects" ] || return 1
  best=
  while IFS= read -r line; do
    id=${line%% *} folder=${line#* }
    case $start/ in
      "$folder"/*)
        if [ "${#folder}" -gt "${#best}" ]; then
          best=$folder PROJECT_ID=$id
        fi
        ;;
    esac
  done <"$CL_HOME/projects"
  [ -n "$best" ] || return 1
  PROJECT_ROOT=$best LAYER=personal
}

link_project() {
  printf '%s\n' "$PROJECT_FLAG" | grep -q "^$UUID\$" || {
    warn "--project needs a project's id."
    FAILED=1
    return 1
  }
  root=$(git -C "${CLAUDE_PROJECT_DIR:-$PWD}" rev-parse --show-toplevel 2>/dev/null) || root=${CLAUDE_PROJECT_DIR:-$PWD}
  touch "$CL_HOME/projects"
  awk -v folder="$root" '{ f = $0; sub(/^[^ ]* /, "", f); if (f != folder) print }' \
    "$CL_HOME/projects" >"$CL_HOME/projects.tmp"
  printf '%s %s\n' "$PROJECT_FLAG" "$root" >>"$CL_HOME/projects.tmp"
  mv -f "$CL_HOME/projects.tmp" "$CL_HOME/projects"
}

unlink_project() {
  awk -v id="$1" '$1 != id' "$CL_HOME/projects" >"$CL_HOME/projects.tmp" &&
    mv -f "$CL_HOME/projects.tmp" "$CL_HOME/projects"
}

# --- Setup: sign-in, plan, doctor and read-back ------------------------------

# Quotes a word for sh, when it needs quoting
shell_quote() {
  case $1 in
    '' | *[!A-Za-z0-9/._~-]*) printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")" ;;
    *) printf '%s' "$1" ;;
  esac
}

# Where setup saves this script, and how hooks and daily jobs run it
INSTALLED=$CL_HOME/sync.sh
if [ "$CL_HOME" = "$HOME/.contextlocker" ]; then
  RUN='sh ~/.contextlocker/sync.sh'
else
  RUN="sh $(shell_quote "$INSTALLED")"
fi
case $HARNESS in
  hermes | openclaw) TRIGGER='daily job' ;;
  *) TRIGGER='session-start hook' ;;
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

# "Claude Code on Ada's laptop, in the Personal workspace", from GET /v1/agent
connected_as() {
  name=$(json_value agent name "$TMP/agent")
  machine=$(json_value agent machine_name "$TMP/agent")
  workspace=$(json_value workspace name "$TMP/agent")
  printf '%s' "${name:-$APP_NAME}"
  [ -n "$machine" ] && printf ' on %s' "$machine"
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

# Connects this app with a device code (RFC 8628). Only the link and the code
# are shown: the token goes straight into a file only this account can read.
signin() {
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

# Daily jobs run at a minute past 9 that comes from this computer's id, so
# computers don't all sync at once. Reading the id never creates it.
job_minute() {
  id=$(machine_id saved)
  sum=$(printf '%s' "${id:-$(uname -n 2>/dev/null)}" | cksum | cut -d ' ' -f 1)
  printf '%s' $((sum % 60))
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
      printf 'Daily job: save this as %s/scripts/contextlocker-sync.sh, the script Hermes runs:\n\n' "$(root_dir hermes)"
      printf '    #!/bin/sh\n    exec %s hermes --daily\n\n' "$RUN"
      printf 'Then add a daily job that runs it with no model call. From this chat, use your cron tool with no agent, the script contextlocker-sync.sh and the name contextlocker-daily. Or run:\n\n'
      printf '    hermes cron create "%s 9 * * *" --no-agent --script contextlocker-sync.sh --name contextlocker-daily --deliver origin\n\n' "$(job_minute)"
      printf 'It stays quiet when the sync works, and tells you when it fails.\n'
      ;;
    openclaw)
      printf 'Daily job: add an OpenClaw automation that runs the sync with no model call. Run this on the computer where the OpenClaw gateway runs:\n\n'
      printf '    openclaw cron add --name contextlocker-daily --cron "%s 9 * * *" --command %s\n\n' "$(job_minute)" "$(shell_quote "$RUN openclaw --daily")"
      printf 'It stays quiet when the sync works, and posts the problem to your usual chat when it fails. With more than one chat set up, add --channel and the chat to use.\n'
      ;;
  esac
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
  printf '\nAlready here, and left as it is:\n'
  existing_files
  printf '\nIf this looks right, approve it once. Then:\n'
  [ -f "$INSTALLED" ] || printf -- '- Save this script as %s.\n' "$INSTALLED"
  printf -- '- Write the files: %s %s\n' "$RUN" "$HARNESS"
  printf -- '- Add the %s shown above.\n' "$TRIGGER"
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

doctor() {
  fails=0 warns=0
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
    check_fail "The sync script isn't at $INSTALLED, where the $TRIGGER runs it. Save it there."
  else
    installed=$(sed -n 's/^SCRIPT_VERSION=\([0-9]*\)$/\1/p' "$INSTALLED" | head -n 1)
    if [ "$installed" = "$SCRIPT_VERSION" ]; then
      check_pass "The sync script is at $INSTALLED."
    else
      check_warn "The sync script at $INSTALLED is version ${installed:-unknown}, and this one is version $SCRIPT_VERSION."
    fi
  fi

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

  lock=$APP_DIR/global.lock
  if ! grep -q '^synced ' "$lock" 2>/dev/null; then
    check_fail "Nothing has synced yet. Run: $RUN $HARNESS"
  else
    synced=$(nice_time "$(sed -n 's/^synced //p' "$lock" | head -n 1)")
    etag=$(sed -n "s/^etag \\($HASH\\)\$/\\1/p" "$lock" | head -n 1)
    if [ -z "$etag" ]; then
      check_warn "The last sync didn't finish ($synced). The next one tries again."
    elif [ "$connected" = 1 ]; then
      code=$(status_of "$(http GET /v1/sync "$TMP/manifest" '' '' "$etag" '' '')")
      case $code in
        304) check_pass "The files match your playbook. Last synced $synced." ;;
        200) check_warn "Your playbook has changed since the last sync ($synced). The next sync brings the files up to date." ;;
        *) check_warn "Couldn't compare the files with your playbook: Context Locker answered $code." ;;
      esac
    fi
    grep '^wrote ' "$lock" >"$TMP/wrote-lines"
    blocks=0 skills=0
    while read -r _ kind hash t; do
      path=$(resolve "$t") || continue
      if [ "$kind" = skill ]; then
        if [ -f "$path/.ctx-managed" ]; then
          skills=$((skills + 1))
        else
          check_warn "The skill at $path is missing. The next sync adds it again."
        fi
        continue
      fi
      if [ ! -f "$path" ]; then
        check_warn "$path is missing. The next sync writes it again."
        continue
      fi
      pos=$(block_position "$path")
      case $pos in
        none) check_warn "Context Locker's block is missing from $path. The next sync adds it again." ;;
        broken) check_fail "The Context Locker markers in $path don't pair up, so syncs leave the file alone until someone fixes it by hand." ;;
        *)
          if [ "$(block_lines "$path" "${pos% *}" "${pos#* }" | sha_stdin)" = "$hash" ]; then
            blocks=$((blocks + 1))
          else
            check_warn "Context Locker's block in $path has an edit that isn't in your playbook. It goes to Context Locker at the next sync, if it hasn't already."
          fi
          ;;
      esac
    done <"$TMP/wrote-lines"
    if [ "$skills" -gt 0 ]; then
      check_pass "$(plural "$blocks" block blocks) and $(plural "$skills" skill skills) in place."
    elif [ "$blocks" -gt 0 ]; then
      check_pass "$(plural "$blocks" block blocks) in place."
    fi
  fi

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
      wrapper=$(root_dir hermes)/scripts/contextlocker-sync.sh
      if [ -f "$wrapper" ] && { grep -Eq 'contextlocker[/\\]+sync\.(sh|ps1)' "$wrapper" || grep -Fq "$INSTALLED" "$wrapper"; }; then
        check_pass "The daily job's script is at $wrapper."
      else
        check_fail "The daily job's script isn't at $wrapper. Run: $RUN plan $HARNESS, and save the script it shows."
      fi
      # `hermes cron list --all` prints a paragraph per job: its id and state
      # ([active], [paused], ...), then lines such as "Script: <name>"
      if ! have hermes; then
        check_warn "The hermes command isn't on this account's PATH, so the daily job wasn't checked."
      elif ! hermes cron list --all >"$TMP/jobs" 2>&1; then
        check_warn "Couldn't list Hermes's jobs, so the daily job wasn't checked."
      else
        jobs=$(tr -d '\033' <"$TMP/jobs" | sed 's/\[[0-9;]*m//g' |
          awk 'BEGIN { RS = ""; ORS = "\n\n" } /contextlocker-sync\.sh/')
        case $jobs in
          '') check_fail "Hermes has no job that runs contextlocker-sync.sh. Run: $RUN plan $HARNESS, and add the job it shows." ;;
          *'[active]'*) check_pass "Hermes has a job that runs contextlocker-sync.sh." ;;
          *) check_warn "Hermes's job that runs contextlocker-sync.sh is paused or turned off. Run: hermes cron resume $(printf '%s\n' "$jobs" | awk 'NF { print $1; exit }' | clean)" ;;
        esac
        grep -q 'Scheduler is not ready' "$TMP/jobs" &&
          check_warn "Hermes says its scheduler isn't running, so the daily job won't run. Run: hermes cron status"
      fi
      ;;
    openclaw)
      # Without --all, OpenClaw lists only the jobs that are turned on
      if ! have openclaw; then
        check_warn "The openclaw command isn't on this account's PATH, so the daily job wasn't checked."
      elif ! listed=$(openclaw cron list --json 2>/dev/null); then
        check_warn "Couldn't list OpenClaw's jobs. Is its gateway running?"
      elif printf '%s' "$listed" | grep -Eq 'contextlocker-daily|contextlocker[/\\]+sync\.(sh|ps1)'; then
        check_pass "OpenClaw has a job that runs the sync."
      elif openclaw cron list --all --json 2>/dev/null | grep -Eq 'contextlocker-daily|contextlocker[/\\]+sync\.(sh|ps1)'; then
        check_warn "OpenClaw's job that runs the sync is turned off. Turn it back on in OpenClaw."
      else
        check_fail "OpenClaw has no job that runs the sync. Run: $RUN plan $HARNESS, and add the job it shows."
      fi
      ;;
  esac

  if [ "$fails" -gt 0 ]; then
    printf '\n%s to fix.\n' "$(plural "$fails" problem problems)"
    return 1
  fi
  if [ "$warns" -gt 0 ]; then
    printf '\nWorking, with %s.\n' "$(plural "$warns" warning warnings)"
  else
    printf '\nAll checks passed.\n'
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
    about=$(sed -n 's/^description:[[:space:]]*//p' "$path/SKILL.md" 2>/dev/null | head -n 1 | clean)
    printf -- '- %s, in %s%s\n' "${t##*/}" "$path" "${about:+: $about}"
  done <"$TMP/wrote-lines"
  return 0
}

# --- Run ------------------------------------------------------------------

if [ "$MODE" != sync ]; then
  case $MODE in
    signin) signin ;;
    plan) plan ;;
    doctor) doctor ;;
    readback) readback ;;
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
  if detect_project; then
    if [ "$global_ok" = 0 ]; then
      SCOPE=project
      sync_scope "?project=$PROJECT_ID&layer=$LAYER" "$APP_DIR/projects/$PROJECT_ID"
      [ $? = 3 ] && [ "$LAYER" = personal ] && unlink_project "$PROJECT_ID"
    fi
  fi
fi

# What the app reads at the start of a session: a line about changes waiting
# for the owner, then a project's preferences when they aren't in the repo
context_file=
for part in "$APP_DIR/global.context" ${PROJECT_ID:+"$APP_DIR/projects/$PROJECT_ID.context"}; do
  [ -f "$part" ] || continue
  [ -n "$context_file" ] && printf '\n' >>"$TMP/context"
  cat "$part" >>"$TMP/context"
  context_file=$TMP/context
done

if [ "$DAILY" = 1 ]; then
  if [ "$FAILED" = 1 ]; then
    cat "$TMP/warnings"
    exit 1
  fi
  exit 0
fi

[ -s "$TMP/warnings" ] && cat "$TMP/warnings" >&2

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
