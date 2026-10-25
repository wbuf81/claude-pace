# Claude Pace

A lightweight Claude Code status line and rate limit tracker that shows your 5-hour and 7-day quota usage in real time. Pure Bash + jq, single file, zero npm.

If you are searching for a Claude Code statusline, a Claude Code quota monitor, or a Claude Code usage tracker, claude-pace is built for that narrow job. It shows not only how much quota you have used, but whether your current burn rate is sustainable before the window resets.

![claude-pace statusline demo](.github/claude-pace-demo.gif)

## This Fork

[wbuf81/claude-pace](https://github.com/wbuf81/claude-pace) adds three things on top of upstream v0.9.5:

```
Opus 5.5 (1M) xhigh |  claudepace (main) · Acme
██░░░░░░░░ 23% 1M   |  5h ██▓█┃░░░░░ 41% 3h  7d █░░░┃░▒░░░ 18% 4d
```

- **Org label.** The top line ends with the org you're logged into, read from `~/.claude.json` (or `$CLAUDE_CONFIG_DIR/.claude.json`). Team and Enterprise logins show the org name, minus an optional shared prefix set in `CLAUDE_PACE_ORG_STRIP` (e.g. `Acme Corp` turns "Acme Corp Platform" into `Platform`), falling back to `Team`/`Enterprise` when nothing is left. Personal plans show `Pro`/`Max`. API-key logins show nothing.
- **Pace bars.** 5h and 7d usage are 10-cell bars. The fill is what you've used; `┃` marks where you'd be at an even pace through the window. Red fill means you're ahead of the mark (burning too fast), green means at or behind it. These replace the `⇡`/`⇣` arrows.
- **Working shimmer.** While Claude is working, a glint (`▓` on the fill, `▒` on the empty track) sweeps along the bars one cell per second. Plugin hooks (`hooks/hooks.json`) keep a per-session busy flag; Esc fires no hook, so the statusline also checks the transcript for the interrupt notice. Needs the plugin install (for the hooks) and `"refreshInterval": 1` on `statusLine`, which `/claude-pace:setup` adds.

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
| Rate limit tracking | 5h + 7d usage %, pace delta, reset countdown | Usage % | Usage % (planned) | None (formatting only) |
| Execution | ~10ms | ~90ms | ~5ms | ~90ms |
| Memory | ~2 MB | ~57 MB | ~3 MB | ~57 MB |

Execution and memory measured on Apple Silicon, 300 runs, same stdin JSON.

Need themes, powerline aesthetics, or TUI config? Try [ccstatusline](https://github.com/sirmalloc/ccstatusline). The entire source of claude-pace is [one file](claude-pace.sh). Read it.

## How Claude Pace Tracks Quota

Claude Code polls the statusline every ~300ms:

| Data | Source | Cache |
|------|--------|-------|
| Model, context, cost | stdin JSON (single `jq` call) | None needed |
| Quota (5h, 7d, pace) | stdin `rate_limits` (live, no fallback) | None |
| Git branch + diff | `git` commands | Private cache dir, 5s TTL |

Requires Claude Code `2.1.80+`, where `rate_limits` is available in statusline stdin. When stdin omits `rate_limits` (older Claude Code, or providers that do not surface the field), claude-pace shows `--` for 5h/7d quota and the session cost if available. No cached or stale quota is ever shown, because a cached account-level snapshot cannot be proven to belong to the current provider/account.

Git cache files live in a private per-user directory (`$XDG_RUNTIME_DIR/claude-pace` or `~/.cache/claude-pace`, mode 700). All cache reads are validated before use. No files are ever written to shared `/tmp`.

## Claude Code Statusline FAQ

**Does it need Node.js?**
No. Only `jq` (available via `brew install jq` or your package manager). No npm, no node_modules, no lock files.

**How does pace tracking work?**
claude-pace compares your current usage percentage to the fraction of time elapsed in each window (5-hour and 7-day). The `┃` mark sits at the elapsed fraction. If you've used 40% of your quota but only 30% of the time has passed, the fill runs past the mark and turns red (burning too fast). If you've used 30% with 40% of time elapsed, the fill stops short of the mark and stays green (headroom).

**Does it make network calls?**
No. Quota data comes from stdin `rate_limits` on Claude Code `2.1.80+`. If `rate_limits` is absent (older Claude Code, or providers that omit it), claude-pace shows `--` for 5h/7d and the local session cost when present. No stale quota fallback — see [the removal decision](docs/decisions/2026-05-20-quota-cache-removal.md).

**Can I inspect the source?**
The entire tool is [one Bash file](claude-pace.sh). Read it before you install it.

## Also by the Author

[**diffpane**](https://github.com/Astro-Han/diffpane) - Real-time TUI diff viewer for AI coding agents. See what Claude Code changes as it happens.

## License

MIT

*Last updated: 2026-10-25 · v0.9.5-fork.1*
