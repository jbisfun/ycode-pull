# ycode-pull

[pull](https://github.com/jbisfun/pull) inside ycode, as a Lua extension built on
ycode's `lua_hooks` (`gpui.open_window`).

A window with status / sync / update / push, a commit box (40-char counter, `-a` toggle,
ctrl-enter commits through `pull commit`, so pullfile lint rules and hooks apply), and
workspace worktrees. Commands run in the background and stream their output.

## Install

    ln -s ~/jbisfun/ycode-pull ~/.config/zed/hooks/ycode-pull

then "ycode: reload hooks". Open it with

    ycode.dispatch("pull::Open")                       -- executor
    "ctrl-alt-p": ["ycode::Run", { "name": "pull::Open" }]   -- keymap.json

The workspace root is `$PULL_ROOT` (set by `pull shell` / `pull env`), else the nearest
`pullfile.plist` above a folder open in ycode (active window first), else above ycode's
working directory; it can be changed in
the window. `pull` must be on ycode's PATH.

## Changes panel

A "Pull" dock panel (left dock, branch icon; "pull: changes" toggles it) shows every
repo's changes in one list, grouped by repo, with branch and ahead/behind. Click a file to
open it; click its box to stage or unstage it (`pull add` / `pull unstage`), or stage a
whole repo. The commit box sends one message to every repo with staged changes through
`pull commit` (all tracked changes, `-a`, when nothing is staged), so the pullfile's lint
rules and hooks apply; the character counter uses the pullfile's subject limit.
Sync, Update and Push run for the whole workspace. In a pull workspace, Zed's git panel
(one repository at a time) is hidden.

## Jobs panel

"pull: jobs" (or the Jobs button in the pull window) toggles a bottom-dock panel listing
the pullfile's `jobs` (including ones not loaded yet) and ad-hoc terminal sessions
(`pull launchctl` / `pull session`), with what each terminal is running, its directory,
pid and last exit. The inspector shows the selected terminal's live screen: type into it
(Run presses enter), send ctrl-c, start / stop / restart, load and start an unloaded job,
unload a job or remove a session, or open it in your terminal (`$TERMINAL`, else
`xdg-terminal-exec`, else `x-terminal-emulator`; runs `pull session attach`). New sessions
start with a shell or a command.

## MCP

In a pull workspace the plugin registers `pull mcp --root <root>` as an MCP server
(`context_servers.pull`, in-memory settings layer), so ycode's agent gets pull's
workspace, search, exec and terminal-session tools; ycode forwards it to ACP agents such
as Hermes too.
