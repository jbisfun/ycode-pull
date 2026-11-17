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
`pullfile.plist` above ycode's working directory, else `~/jbisfun`; it can be changed in
the window. `pull` must be on ycode's PATH.
