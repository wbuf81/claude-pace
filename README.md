# Claude Pace

A lightweight Claude Code status line and rate limit tracker that shows your 5-hour and 7-day quota usage in real time. Pure Bash + jq, single file, zero npm.

If you are searching for a Claude Code statusline, a Claude Code quota monitor, or a Claude Code usage tracker, claude-pace is built for that narrow job. It shows not only how much quota you have used, but whether your current burn rate is sustainable before the window resets.

![claude-pace statusline demo](.github/claude-pace-demo.gif)

## This Fork

[wbuf81/claude-pace](https://github.com/wbuf81/claude-pace) is a fork of [Astro-Han/claude-pace](https://github.com/Astro-Han/claude-pace) v0.9.5 that adds three things: an org label, pace bars, and a working ripple.

```
Opus 5.5 (1M) xhigh |  claudepace (main) · Acme
██░░░░░░░░ 23% 1M   |  5h ▆▅▆▇┃░░░░░ 41% 3h  7d ▆░░░┃░░░░░ 18% 4d
```

### Org label

The top line ends with the org you're logged into (`· Acme` above), so hopping between Team and Enterprise logins stays visible. It's read from `~/.claude.json` (or `$CLAUDE_CONFIG_DIR/.claude.json`) and cached for 10 seconds.

| Login | Shows |
|---|---|
| Team / Enterprise | Org name minus `CLAUDE_PACE_ORG_STRIP`, or `Team` / `Enterprise` if nothing is left |
| Pro / Max | `Pro` / `Max` |
| API key | Nothing |

To trim a prefix every org name shares, set `CLAUDE_PACE_ORG_STRIP` in the `env` block of `~/.claude/settings.json`: with `"CLAUDE_PACE_ORG_STRIP": "Acme Corp"`, "Acme Corp Platform" shows as `Platform`. It's unset by default, so the full name shows. Names over 24 characters are truncated, and control characters are stripped since org names are admin-controlled text.

### Pace bars

5h and 7d usage are 10-cell bars instead of upstream's `⇡`/`⇣` arrows. The fill is how much you've used; `┃` marks where you'd be at an even pace through the window.

- `██░░┃░░░░░` green: the fill is at or behind the mark. Headroom.
- `█████┃██░░` red: the fill is past the mark. You're burning faster than the window allows.

When Claude Code sends no reset time there's no mark, and the fill colors by usage alone: green, yellow from 70%, red from 90%.

### Working ripple

While Claude is working, a shallow dip in height (`█▇▆▅▆▇`) rolls along each bar's fill, one cell per second. It stops when Claude finishes or you press Esc. A bar with no fill to ripple gets a `▒` glint sweeping its track instead, so there's always something moving.

It needs two things:

- **The plugin install.** Plugin hooks (`hooks/hooks.json`) keep a per-session busy flag: busy on each prompt and tool call, idle on stop, failure, and session start or end. Subagent events are ignored so a background agent can't flip it. Esc fires no hook, so the statusline also checks the end of the transcript for the interrupt notice. The npx and manual installs have no hooks, so their bars stay still.
- **`"refreshInterval": 1` on `statusLine`.** This redraws the statusline every second so the ripple animates. `/claude-pace:setup` adds it.

## TL;DR

- Claude Code status line with `5h` and `7d` quota usage, reset countdowns, and pace bars
- Pace-aware rate limit tracking: the bar's `┃` is where an even pace would put you, red fill means overspending
- Pure Bash + jq, single file, no Node.js runtime and no lockfile churn
- Install as a Claude Code plugin, with `npx`, or as a single script

Most statuslines show "you used 60%." That number means nothing without context. 60% with 30 minutes left? Fine, the window resets soon. 60% with 4 hours left? You are about to hit the wall. claude-pace compares your burn rate to the time remaining and shows the delta.

- **`██░░┃░░░░░`** green = your fill is behind the `┃` pace mark. Headroom. Keep going.
- **`█████┃██░░`** red = your fill is past the mark. You're burning faster than sustainable. Slow down.
- **15%** / **20%** = used in the 5h and 7d windows. **3h** = resets in 3 hours.
- Top line: model, effort, project `(branch)`, `3f +24 -7` = git diff stats, `· Acme` = logged-in org

Claude Code supports custom status lines through its `statusLine` setting and `/statusline` workflow in the official docs:

- [Customize your status line](https://code.claude.com/docs/en/statusline)
- [Claude Code settings](https://docs.anthropic.com/en/docs/claude-code/settings)

## Table of Contents

- [Install This Claude Code Statusline](#install-this-claude-code-statusline)
- [Upgrade](#upgrade)
- [Claude Code Statusline Comparison](#claude-code-statusline-comparison)
- [How Claude Pace Tracks Quota](#how-claude-pace-tracks-quota)
- [Claude Code Statusline FAQ](#claude-code-statusline-faq)

## Install This Claude Code Statusline

Requires `jq`.

**Plugin (recommended):**

Inside Claude Code:

```
/plugin marketplace add wbuf81/claude-pace
/plugin install claude-pace@claude-pace-fork
/reload-plugins
/claude-pace:setup
```

If the upstream plugin is installed, remove it first
(`/plugin uninstall claude-pace@claude-pace-marketplace`) so the two don't
share the `/claude-pace:setup` name. The npx and manual installs below fetch
upstream releases, which don't include this fork's additions.

**npx:**

```bash
npx claude-pace
```

Restart Claude Code. Done.

**Manual:**

```bash
mkdir -p ~/.claude
curl -fsSL -o ~/.claude/statusline.sh.new \
  https://github.com/Astro-Han/claude-pace/releases/latest/download/claude-pace.sh
mv ~/.claude/statusline.sh.new ~/.claude/statusline.sh
chmod +x ~/.claude/statusline.sh
```

This installs the latest release, not the current state of `main`. To pin an exact
version, swap `latest/download` for `download/vX.Y.Z` with a tag from
[Releases](https://github.com/Astro-Han/claude-pace/releases).

Add to `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "~/.claude/statusline.sh"
  }
}
```

Restart Claude Code. Done.

To remove: delete the `statusLine` block from `~/.claude/settings.json`.

## Upgrade

- **Plugin:**

  ```
  /plugin marketplace update claude-pace-fork
  /plugin update claude-pace
  /reload-plugins
  /claude-pace:setup
  ```

- **npx:** `npx claude-pace@latest`
- **Manual:** Re-run the `curl` command above.

Every channel installs a tagged release. `/claude-pace:setup` copies the script the
plugin ships rather than downloading one, so the plugin version you have is the
version you run. Nothing installs from `main`.

Release notifications: Watch this repo → Custom → Releases.

## Claude Code Statusline Comparison

|  | claude-pace | [claude-hud](https://github.com/jarrodwatts/claude-hud) | [CCometixLine](https://github.com/Haleclipse/CCometixLine) | [ccstatusline](https://github.com/sirmalloc/ccstatusline) |
|---|---|---|---|---|
| Runtime | `jq` | Node.js 18+ / npm | Compiled (Rust) | Node.js / npm |
| Codebase | Single Bash file | 1000+ lines + node_modules | Compiled binary | 1000+ lines + node_modules |
| Rate limit tracking | 5h + 7d usage %, pace bars, reset countdown | Usage % | Usage % (planned) | None (formatting only) |
| Execution | ~10ms | ~90ms | ~5ms | ~90ms |
| Memory | ~2 MB | ~57 MB | ~3 MB | ~57 MB |

Execution and memory measured on Apple Silicon, 300 runs, same stdin JSON.

Need themes, powerline aesthetics, or TUI config? Try [ccstatusline](https://github.com/sirmalloc/ccstatusline). The entire source of claude-pace is [one file](claude-pace.sh). Read it.

## How Claude Pace Tracks Quota

Claude Code reruns the statusline as the conversation updates (at most every ~300ms), and every second with `refreshInterval: 1`:

| Data | Source | Cache |
|------|--------|-------|
| Model, context, cost | stdin JSON (single `jq` call) | None needed |
| Quota (5h, 7d, pace) | stdin `rate_limits` (live, no fallback) | None |
| Git branch + diff | `git` commands | Private cache dir, 5s TTL |
| Org label | `oauthAccount` in `~/.claude.json` | Private cache dir, 10s TTL |
| Working state | Busy flag from the plugin hooks, plus the transcript tail for Esc | One flag file per session |

Requires Claude Code `2.1.80+`, where `rate_limits` is available in statusline stdin. When stdin omits `rate_limits` (older Claude Code, or providers that do not surface the field), claude-pace shows `--` for 5h/7d quota and the session cost if available. No cached or stale quota is ever shown, because a cached account-level snapshot cannot be proven to belong to the current provider/account.

Git and org cache files and the busy flags live in a private per-user directory (`$XDG_RUNTIME_DIR/claude-pace` or `~/.cache/claude-pace`, mode 700). All cache reads are validated before use. No files are ever written to shared `/tmp`.

## Claude Code Statusline FAQ

**Does it need Node.js?**
No. Only `jq` (available via `brew install jq` or your package manager). No npm, no node_modules, no lock files.

**How does pace tracking work?**
claude-pace compares your current usage percentage to the fraction of time elapsed in each window (5-hour and 7-day). The `┃` mark sits at the elapsed fraction. If you've used 40% of your quota but only 30% of the time has passed, the fill runs past the mark and turns red (burning too fast). If you've used 30% with 40% of time elapsed, the fill stops short of the mark and stays green (headroom).

**Does it make network calls?**
No. Quota data comes from stdin `rate_limits` on Claude Code `2.1.80+`. If `rate_limits` is absent (older Claude Code, or providers that omit it), claude-pace shows `--` for 5h/7d and the local session cost when present. No stale quota fallback — see [the removal decision](docs/decisions/2026-05-20-quota-cache-removal.md).

**Why aren't the bars rippling while Claude works?**
The ripple needs this fork's plugin install (for the hooks) and `"refreshInterval": 1` under `statusLine` in `~/.claude/settings.json`. Run `/claude-pace:setup` to add the setting. The npx and manual installs fetch upstream releases, which don't have the ripple.

**Where does the org name come from?**
From `oauthAccount` in `~/.claude.json`, which Claude Code writes when you log in. Nothing is fetched over the network. Use `CLAUDE_PACE_ORG_STRIP` to trim a shared prefix (see [Org label](#org-label)).

**Can I inspect the source?**
The entire tool is [one Bash file](claude-pace.sh). Read it before you install it.

## Also by the Author

[**diffpane**](https://github.com/Astro-Han/diffpane) - Real-time TUI diff viewer for AI coding agents. See what Claude Code changes as it happens.

## License

MIT

*Last updated: 2026-10-25 · v0.9.5-fork.1*
