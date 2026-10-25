#!/usr/bin/env bash
# Claude Code statusline plugin
# Line1: model (ctx) effort | project (branch) Nf +A -D · org
# Line2: bar PCT% CL | 5h pace-bar used% countdown  7d pace-bar used% countdown
# Hook mode: claude-pace.sh --hook busy|idle (plugin hooks; drives the ripple)

# Disable glob expansion so unquoted vars with wildcards (e.g. DIR paths)
# are never accidentally expanded into filename lists.
set -f
# Hook stdout can be fed into Claude's context, so hook mode must never print.
HOOK=""
[[ "${1:-}" == "--hook" ]] && HOOK="${2:-}"
input=$(cat)
[[ -z "$input" && -z "$HOOK" ]] && {
  echo "Claude"
  exit 0
}
[[ -n "$HOOK" ]] || command -v jq >/dev/null || {
  echo "Claude [needs jq]"
  exit 0
}

# ── Colors & Utilities ──
# C=Cyan G=Green Y=Yellow R=Red D=Dim N=Normal (reset)
# Store real escape bytes so final output does not need echo -e interpretation.
C=$'\033[36m' G=$'\033[32m' Y=$'\033[33m' R=$'\033[31m' D=$'\033[2m' N=$'\033[0m'
# Cache records use ASCII Unit Separator so legal Git ref names cannot split
# serialized fields and empty values survive round-trips through read.
SEP=$'\037'
NOW=$(date +%s)
# Returns true when the candidate cache dir is a real directory owned by the
# current user, writable, and not a symlink into a foreign-controlled path.
_cache_dir_ok() { [ -d "$1" ] && [ ! -L "$1" ] && [ -O "$1" ] && [ -w "$1" ]; }
# Reads one cache record into CACHE_FIELDS, supporting the current separator
# and the legacy pipe format used by older cache files.
_read_cache_record() {
  local line="$1" delim rest field
  CACHE_FIELDS=()
  if [[ "$line" == *"$SEP"* ]]; then
    delim="$SEP"
  else
    delim='|'
  fi
  rest="$line"
  while [[ "$rest" == *"$delim"* ]]; do
    field=${rest%%"$delim"*}
    CACHE_FIELDS+=("$field")
    rest=${rest#*"$delim"}
  done
  CACHE_FIELDS+=("$rest")
}
# Loads and parses one cache file into CACHE_FIELDS.
_load_cache_record_file() {
  local path="$1" line=""
  [ -f "$path" ] || return 1
  IFS= read -r line <"$path" || line=""
  _read_cache_record "$line"
}
# Writes one cache record straight to its final path. This used to go through a
# mktemp file and an mv for atomicity, but Claude Code cancels the status line
# script whenever a refresh arrives mid-run, so every cancellation between the
# write and the mv stranded a uniquely named temp file forever — one reporter had
# 3008 of them. Atomicity was never needed here: the record is one short line of
# git data with a 5s TTL, so a torn write is just a cache miss that the reader
# already sanitizes and the next run recomputes. Dropping the temp file also drops
# two subprocess spawns per refresh and shrinks the cancellable window to a single
# builtin. Symlinks must be refused explicitly: mv used to replace the link
# itself, while > follows it.
_write_cache_record() {
  local path="$1" IFS="$SEP"
  shift
  [ ! -L "$path" ] || return 1
  printf '%s\n' "$*" >"$path" 2>/dev/null
}
# Computes remaining whole minutes until a future epoch. Missing or expired
# timestamps return an empty string so callers can skip countdown formatting.
_minutes_until() {
  local epoch="$1" mins
  [[ "$epoch" =~ ^[0-9]+$ ]] && ((epoch > 0)) || return
  mins=$(((epoch - NOW) / 60))
  ((mins < 0)) && mins=0
  printf '%s\n' "$mins"
}
# Collects live Git metadata for DIR. On non-repos, leaves defaults in place
# and returns non-zero so callers can decide whether to cache the empty result.
_collect_git_info() {
  BR="" FC=0 AD=0 DL=0
  git -C "$DIR" rev-parse --git-dir >/dev/null 2>&1 || return 1
  BR=$(git -C "$DIR" --no-optional-locks branch --show-current 2>/dev/null)
  while IFS=$'\t' read -r a d _; do
    # Skip binary files (reported as "-" instead of a number).
    [[ "$a" =~ ^[0-9]+$ ]] || continue
    FC=$((FC + 1))
    AD=$((AD + a))
    DL=$((DL + d))
  done < <(git -C "$DIR" --no-optional-locks diff HEAD --numstat 2>/dev/null)
}
# Cache only inside a user-owned, non-symlinked directory. If no safe root is
# available, disable caching for this run instead of falling back to shared /tmp.
_CD="" CACHE_OK=0
for _BASE in "${XDG_RUNTIME_DIR:-}" "${HOME}/.cache"; do
  [ -n "$_BASE" ] || continue
  _CAND="${_BASE%/}/claude-pace"
  # shellcheck disable=SC2174  # -p only creates leaf here; parent already exists
  [ -e "$_CAND" ] || mkdir -p -m 700 "$_CAND" 2>/dev/null || continue
  _cache_dir_ok "$_CAND" || continue
  _CD="$_CAND"
  CACHE_OK=1
  break
done
# Returns true (exit 0) when file is missing or older than $2 seconds.
_stale() { [ ! -f "$1" ] || [ $((NOW - $(stat -f%m "$1" 2>/dev/null || stat -c%Y "$1" 2>/dev/null || echo 0))) -gt "$2" ]; }

# ── Hook mode: per-session busy flag for the working ripple ──
# busy: UserPromptSubmit / PreToolUse. idle: Stop / StopFailure / SessionStart /
# SessionEnd. Esc fires no hook; the statusline catches that from the transcript.
# Subagent events carry agent_id and are ignored so background agents finishing
# after the main turn can't flip the flag. Pure builtins + rm, no jq needed.
if [[ -n "$HOOK" ]]; then
  [[ "$CACHE_OK" == "1" ]] || exit 0
  [[ "$input" =~ \"agent_id\"[[:space:]]*: ]] && exit 0
  [[ "$input" =~ \"session_id\"[[:space:]]*:[[:space:]]*\"([A-Za-z0-9_-]+)\" ]] || exit 0
  _BF="${_CD}/claude-busy-${BASH_REMATCH[1]}"
  case "$HOOK" in
  busy) _write_cache_record "$_BF" "$NOW" ;;
  idle) rm -f "$_BF" 2>/dev/null ;;
  esac
  exit 0
fi

# ── Parse stdin + settings in one jq call ──
# Fields: MODEL DIR PCT CTX COST EFF HAS_RL U5 U7 R5 R7 TIN SID TP
# Read settings into a shell var rather than process substitution so the jq
# --argjson path works on Windows Git Bash (where /proc/<pid>/fd/N used by
# <(...) is unavailable and --slurpfile silently fails, yielding empty fields).
# Every field needs a non-empty default: tab is IFS whitespace, so an empty
# field would collapse and shift the rest.
HAS_RL=0
_SETTINGS=$(cat "$HOME/.claude/settings.json" 2>/dev/null)
echo "$_SETTINGS" | jq -e . >/dev/null 2>&1 || _SETTINGS='{}'
IFS=$'\t' read -r MODEL DIR PCT CTX COST EFF HAS_RL U5 U7 R5 R7 TIN SID TP < <(
  jq -r --argjson cfg "$_SETTINGS" \
    '[(.model.display_name//"?"),(.workspace.project_dir//"."|gsub("\\\\";"/")),
    (.context_window.used_percentage//0|floor),(.context_window.context_window_size//0),
    (.cost.total_cost_usd//0),
    (.effort.level//$cfg.effortLevel//"default"),
    (if .rate_limits then 1 else 0 end),
    (.rate_limits.five_hour.used_percentage//null|if type=="number" then floor else "--" end),
    (.rate_limits.seven_day.used_percentage//null|if type=="number" then floor else "--" end),
    (.rate_limits.five_hour.resets_at//0),
    (.rate_limits.seven_day.resets_at//0),
    (if (.context_window.total_input_tokens|type)=="number" then (.context_window.total_input_tokens|floor) else -1 end),
    (.session_id//"-"),(.transcript_path//"-"|gsub("\\\\";"/"))]|@tsv' <<<"$input"
)
case "${EFF:-default}" in low) EF='low' ;; high) EF='high' ;; xhigh) EF='xhigh' ;; max) EF='max' ;; *) EF='medium' ;; esac

# ── Auto-compact window: track usage against the compaction threshold ──
# When CLAUDE_CODE_AUTO_COMPACT_WINDOW is set, compaction fires at that token
# count, not the model's full window. Recompute PCT against it and relabel CTX
# so the bar measures "distance to compaction", matching the desktop app's bar
# (e.g. 49.8k / 400.0k). The jq above emits TIN=-1 only when CC omits
# total_input_tokens entirely (old CC); the ^[0-9]+$ test rejects that and falls
# back to the full window. A present zero (fresh-session first frame, before the
# first API response) passes, so the bar measures against the cap from the start
# instead of flashing the full window while the env var is set.
ACW="${CLAUDE_CODE_AUTO_COMPACT_WINDOW:-0}"
if [[ "$ACW" =~ ^[0-9]+$ ]] && ((ACW > 0)) && [[ "$TIN" =~ ^[0-9]+$ ]]; then
  # Compaction can't exceed the real window; clamp so the label stays honest.
  ((CTX > 0 && ACW > CTX)) && ACW=$CTX
  PCT=$((TIN * 100 / ACW))
  ((PCT > 100)) && PCT=100
  CTX=$ACW
fi

# ── Context label (needed by MODEL_SHORT and line 2) ──
if ((CTX >= 1000000)); then
  CL="$((CTX / 1000000))M"
elif ((CTX > 0)); then
  CL="$((CTX / 1000))K"
else CL=""; fi

# ── MODEL_SHORT: strip redundant context label ──
MODEL=${MODEL/ context)/)}
[[ "$CTX" -gt 0 && "$MODEL" != *"("* ]] && MODEL="${MODEL} (${CL})"
# Cap "MODEL EF" at 28 chars; 28 fits the longest effort word ('medium', 6 chars)
# plus a typical "Sonnet 4.6 (200K)" without ellipsis.
_ML="${MODEL} ${EF}"
((${#_ML} > 28)) && MODEL="${MODEL:0:$((28 - 2 - ${#EF}))}…"

# ── Progress Bar ──
F=$((PCT / 10))
((F < 0)) && F=0
((F > 10)) && F=10
if ((PCT >= 90)); then BC=$R; elif ((PCT >= 70)); then BC=$Y; else BC=$G; fi
BAR=""
for ((i = 0; i < F; i++)); do BAR+='█'; done
for ((i = F; i < 10; i++)); do BAR+='░'; done

# ── Git Info (5s disposable cache) ──
# Cache key encodes DIR so concurrent sessions in different repos don't clash.
# Records are disposable: anything unreadable or torn falls through to the
# sanitizing guards below and is recomputed on the next run.
BR="" FC=0 AD=0 DL=0
if [[ "$CACHE_OK" == "1" ]]; then
  GC="${_CD}/claude-sl-git-$(printf '%s' "$DIR" | { shasum 2>/dev/null || sha1sum; } | cut -c1-16)"
  if _stale "$GC" 5; then
    if _collect_git_info; then
      _write_cache_record "$GC" "$BR" "$FC" "$AD" "$DL"
    else
      _write_cache_record "$GC" "" "" "" ""
    fi
  elif _load_cache_record_file "$GC"; then
    BR=${CACHE_FIELDS[0]:-}
    FC=${CACHE_FIELDS[1]:-}
    AD=${CACHE_FIELDS[2]:-}
    DL=${CACHE_FIELDS[3]:-}
  fi
  # Reject cache corruption before arithmetic or terminal output formatting.
  [[ "$FC" =~ ^[0-9]+$ ]] || FC=0
  [[ "$AD" =~ ^[0-9]+$ ]] || AD=0
  [[ "$DL" =~ ^[0-9]+$ ]] || DL=0
else
  _collect_git_info || true
fi

# ── Project Name + Line 1 Right Section ──
# Extract project name. Worktree: save repo name explicitly.
PN="${DIR##*/}"
IS_WT=0 _REPO=""
if [[ "${DIR/#$HOME/\~}" =~ /([^/]+)/\.claude/worktrees/([^/]+) ]]; then
  IS_WT=1
  _REPO="${BASH_REMATCH[1]}"
  _WT_NAME="${BASH_REMATCH[2]}"
  PN="$_REPO"
fi
((${#PN} > 25)) && PN="${PN:0:25}…"

# Format: project (branch) [git stats]
L1R="$PN"
if [ -n "$BR" ]; then
  ((${#BR} > 35)) && BR="${BR:0:35}…"
  L1R+=" (${BR})"
  ((FC > 0)) 2>/dev/null && L1R+=" ${FC}f ${G}+${AD}${N} ${R}-${DL}${N}"
elif [[ "$IS_WT" == "1" ]]; then
  # Detached HEAD in worktree: show repo/worktree to preserve identity
  L1R="${_REPO}/${_WT_NAME}"
  ((${#L1R} > 25)) && L1R="${L1R:0:25}…"
fi

# ── Org Label (10s disposable cache) ──
# Names the org/plan of the logged-in account so hopping between Team and
# Enterprise logins stays visible. Team/Enterprise show the org name, minus an
# optional shared prefix in CLAUDE_PACE_ORG_STRIP (unset by default), falling
# back to the plan type when nothing is left. Personal plans show the plan
# type, since their org name is "<email>'s Organization". API-key logins have
# no oauthAccount and show nothing.
ORG=""
_ACCT="${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json"
_org_label() {
  jq -r --arg strip "${CLAUDE_PACE_ORG_STRIP:-}" '
    .oauthAccount // empty | (.organizationType // "") as $t
    | ({claude_team: "Team", claude_enterprise: "Enterprise", claude_max: "Max",
        claude_pro: "Pro", claude_free: "Free"}[$t] // "") as $plan
    | if ($t | test("^claude_(max|pro|free)$")) then $plan
      else (.organizationName // "" | gsub("[[:cntrl:]]"; "")
          | if $strip != "" and (. == $strip or startswith($strip + " "))
            then .[($strip | length):] else . end
          | sub("^[\\s\\-–—·|:]+"; "") | sub("\\s+$"; "")) as $name
        | if $name != "" then $name else $plan end
      end' "$_ACCT" 2>/dev/null
}
if [ -f "$_ACCT" ]; then
  if [[ "$CACHE_OK" == "1" ]]; then
    OC="${_CD}/claude-sl-org-${_ACCT//[^A-Za-z0-9]/_}"
    if _stale "$OC" 10; then
      ORG=$(_org_label)
      _write_cache_record "$OC" "$ORG"
    elif _load_cache_record_file "$OC"; then
      ORG=${CACHE_FIELDS[0]:-}
    fi
  else
    ORG=$(_org_label)
  fi
  # Org names are admin-controlled; never let control bytes reach the terminal.
  ORG=${ORG//[[:cntrl:]]/}
  ((${#ORG} > 24)) && ORG="${ORG:0:24}…"
fi
[ -n "$ORG" ] && L1R+=" ${D}·${N} ${C}${ORG}${N}"

# Usage data: read stdin rate_limits when available. When absent we show
# placeholders and the session cost instead of falling back to a possibly stale
# (or wrong-account) cached snapshot. See docs/decisions/2026-05-20-quota-cache-removal.md.
SHOW_COST=0
if [[ "$HAS_RL" == "1" ]]; then
  # Stdin path: real-time, no network. U5/U7 already set by jq read above.
  # Guard: resets_at=0 means field missing, leave RM empty so _usage skips it.
  RM5=$(_minutes_until "$R5")
  RM7=$(_minutes_until "$R7")
else
  U5="--" U7="--" RM5="" RM7=""
  SHOW_COST=1
fi

# ── Working State (drives the ripple) ──
# Hooks keep a per-session flag while Claude works (see Hook mode above). Esc
# fires no hook, so a flagged session still counts as idle when the newest
# conversation entry in the transcript tail is the interrupt notice.
BUSY=0
if [[ "$CACHE_OK" == "1" && "$SID" =~ ^[A-Za-z0-9_-]+$ && -f "${_CD}/claude-busy-${SID}" ]]; then
  BUSY=1
  if [ -f "$TP" ]; then
    # Last of (entry type | interrupt notice) in file order. The notice sits after
    # its own entry's "type":"user", so it only wins if nothing followed it.
    # grep, not ${var##*pat}: bash 3.2 takes ~180ms on that over 16KB.
    _LAST=$(tail -c 16384 "$TP" 2>/dev/null |
      grep -oE '"type":"(user|assistant)"|"text":"\[Request interrupted by user' 2>/dev/null | tail -n 1)
    [[ "$_LAST" == '"text":"[Request interrupted by user' ]] && BUSY=0
  fi
fi

# Pace bar: fill = used%, ┃ = where usage would sit at an even pace through the
# window. Fill is red when ahead of the mark, green when at or behind it (or by
# absolute usage when there's no reset time). While busy, the fill ripples: a
# shallow dip in cell height rolls rightward along it one cell per second. When
# no fill cell is free to ripple (empty fill, or its one cell holds the mark), a
# glint sweeps the empty track instead so there's still something to see.
_RIPPLE=('█' '▇' '▆' '▅' '▆' '▇')
_pace_bar() {
  local u="$1" rm="$2" w="$3" f m=-1 e col rip=0 s=-1 i st g cur="" out=""
  f=$((u / 10))
  ((f > 10)) && f=10
  if [[ "$rm" =~ ^[0-9]+$ ]] && ((rm <= w)); then
    e=$(((w - rm) * 100 / w))
    m=$((e / 10))
    ((m > 9)) && m=9
    if ((u > e)); then col=$R; else col=$G; fi
  elif ((u >= 90)); then col=$R; elif ((u >= 70)); then col=$Y; else col=$G; fi
  if ((BUSY)); then
    if ((f > 1 || (f == 1 && m != 0))); then rip=1; else s=$((NOW % 10)); fi
  fi
  for ((i = 0; i < 10; i++)); do
    if ((i == m)); then
      st="" g='┃'
    elif ((i < f)); then
      st=$col g='█'
      ((rip)) && g=${_RIPPLE[((i - NOW) % 6 + 6) % 6]}
    else
      st=$D g='░'
      ((i == s)) && g='▒'
    fi
    # Emit a style change only between runs; reset first since dim persists.
    if [[ "$st" != "$cur" || -z "$out" ]]; then
      out+="${N}${st}"
      cur=$st
    fi
    out+=$g
  done
  printf '%s%s' "$out" "$N"
}

# Combined usage formatter: pace-bar used% (countdown)
_usage() {
  local u="${1:---}" rm="$2" w="$3"
  if [[ ! "$u" =~ ^[0-9]+$ ]]; then
    printf "%s" "$u"
  else
    _pace_bar "$u" "$rm" "$w"
    if ((u >= 90)); then printf " ${R}%d%%${N}" "$u"; elif ((u >= 70)); then printf " ${Y}%d%%${N}" "$u"; else printf " ${G}%d%%${N}" "$u"; fi
  fi
  [[ "$rm" =~ ^[0-9]+$ ]] || return
  ((rm >= 1440)) && {
    printf " ${D}%dd${N}" $((rm / 1440))
    return
  }
  ((rm >= 60)) && {
    printf " ${D}%dh${N}" $((rm / 60))
    return
  }
  printf " ${D}%dm${N}" "$rm"
}

# ── Output Assembly (symmetric single-pipe alignment) ──

# Build plain-text left sections for width measurement (no ANSI codes).
L1_PLAIN="${MODEL} ${EF}"
L2_PLAIN="${BAR} ${PCT}% ${CL}"
# Pad shorter side so | aligns on both lines.
W1=${#L1_PLAIN} W2=${#L2_PLAIN}
PAD1="" PAD2=""
if ((W1 > W2)); then
  printf -v PAD2 "%*s" $((W1 - W2)) ""
elif ((W2 > W1)); then
  printf -v PAD1 "%*s" $((W2 - W1)) ""
fi

# Line 1: model (context) effort | project (branch) git-stats
L1="${C}${MODEL} ${EF}${N}${PAD1} ${D}|${N}  ${L1R}"

# Line 2: bar pct% CL | 5h used% ...  7d used% ...
L2="${BC}${BAR}${N} ${PCT}% ${CL}${PAD2} ${D}|${N}  5h $(_usage "$U5" "$RM5" 300)  7d $(_usage "$U7" "$RM7" 10080)"
# Session cost: only when usage data is unavailable in stdin.
if [[ "$SHOW_COST" == "1" ]]; then
  printf -v _CS "\$%.2f" "$COST" 2>/dev/null
  [[ "$_CS" != "\$0.00" ]] && L2+="  $_CS"
fi

printf '%s\n' "$L1"
printf '%s\n' "$L2"
