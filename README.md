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
- CI ([idlci](https://github.com/jbisfun/idlci), the workspace's own pull job
  `idlci serve`): every idl project with its last result, hover to
  queue a build or the tests; the active and recent jobs, click one for a live log tail,
  hover to cancel or retry. Globe buttons open idlci's pages in the browser. Repos with CI
  projects show their status next to the name. It reads idlci's `/api` at the address in
  `.pull/idlci/serve.addr` (curl) and writes through the `idlci` CLI, so `curl` and `idlci`
  must be on ycode's PATH.

## Jobs panel

"pull: jobs" toggles a bottom-dock panel with the pullfile's `jobs` and ad-hoc sessions. The inspector shows the selected terminal live:

- type into it, send ctrl-c, start/stop/restart, load or unload a job, remove a session
- open it in `$TERMINAL` (via `pull session attach`)

## Issues panel

"pull: issues" toggles a right-dock panel with the open [cpull](https://github.com/jbisfun/cpull) (a fork of [haxy](https://github.com/xit-vcs/haxy))
issues of every repo (`pull cpull issues --json`): read one with its comments, close or reopen
it, open cpull on the repo in `$TERMINAL` or its page in the browser, or sync (`pull cpull sync`,
also "pull: cpull sync"). "pull: open file in cpull" opens the active editor's file at the cursor
line in the workspace server's files view (the repo's checked-out branch).

## MCP

In a pull workspace the plugin runs `pull mcp-servers` and registers every server it
returns (`context_servers`, in-memory settings layer): `pull mcp --root <root>` itself
(workspace, search, exec and terminal-session tools) plus whatever the pullfile's
`mcp_servers` section configures, e.g.

    <key>mcp_servers</key>
    <dict>
        <key>mytool</key>
        <dict><key>args</key><array><string>mcp</string></array></dict>
    </dict>

(`command` defaults to the section key, resolved on PATH; `PULL_ROOT` is set for these).
ycode forwards all of it to ACP agents such as Hermes too.
