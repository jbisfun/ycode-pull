# ycode-pull

[pull](https://github.com/jbisfun/pull) inside ycode, as a Lua extension built on
ycode's `lua_hooks` (`gpui.open_window`).

A window with status / sync / update / push, a commit box (40-char counter, `-a` toggle,
ctrl-enter commits through `pull commit`, so pullfile lint rules and hooks apply), and
workspace worktrees. Commands run in the background and stream their output.

## Install

    # from the ycode-pull clone
    ln -s "$PWD" ~/.config/zed/hooks/ycode-pull

then "ycode: reload hooks". Open it with

    ycode.dispatch("pull::Open")                       -- executor
    "ctrl-alt-p": ["ycode::Run", { "name": "pull::Open" }]   -- keymap.json

The workspace root is `$PULL_ROOT` (set by `pull shell` / `pull env`), else the nearest
`pullfile.plist` above a folder open in ycode (active window first), else above ycode's
working directory; it can be changed in
the window. `pull` must be on ycode's PATH.

## Changes panel

"pull: changes" toggles a left-dock panel with every repo's changes, branch and ahead/behind.

- Click a file to open it; tick it (or a repo) to stage via `pull add` / `pull unstage`.
- Commit runs `pull commit` (`-a` if nothing is staged), with the pullfile's lint and hooks.
- Sync, Update and Push act on the whole workspace. Zed's git panel is hidden.

## Jobs panel

"pull: jobs" toggles a bottom-dock panel with the pullfile's `jobs` and ad-hoc sessions. The inspector shows the selected terminal live:

- type into it, send ctrl-c, start/stop/restart, load or unload a job, remove a session
- open it in `$TERMINAL` (via `pull session attach`)

## MCP

In a pull workspace the plugin registers `pull mcp --root <root>` as an MCP server
(`context_servers.pull`, in-memory settings layer), so ycode's agent gets pull's
workspace, search, exec and terminal-session tools; ycode forwards it to ACP agents such
as Hermes too.
