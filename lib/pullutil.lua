--- Shared helpers for ycode-pull's windows.
-- @module pullutil
local M = {}

-- Nearest directory at or above `dir` that holds a pullfile.plist.
local function walk_up(dir)
    while dir and dir ~= "" do
        local f = io.open(dir .. "/pullfile.plist")
        if f then f:close(); return dir end
        local parent = dir:match("^(.*)/[^/]+$")
        if not parent or parent == dir then break end
        dir = parent
    end
end

--- The pull workspace: $PULL_ROOT, else the nearest pullfile.plist above a folder open in
-- ycode (active window first), else above ycode's working directory. nil if none.
function M.find_root()
    local env = os.getenv("PULL_ROOT")
    if env and env ~= "" then return env end
    local ok, folders = pcall(ycode.workspace_folders)
    for _, folder in ipairs(ok and folders or {}) do
        local root = walk_up(folder)
        if root then return root end
    end
    return walk_up(os.getenv("PWD"))
end

--- Message shown when `find_root` finds no workspace.
M.NO_ROOT = "no pullfile.plist in the open folders or above them; open a pull workspace"
    .. " or set PULL_ROOT"

--- `s` quoted for a POSIX shell.
function M.sh_quote(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

--- `cd root && pull ARGS...` as a shell command line (args are quoted).
function M.pull_cmd(root, args)
    local argv = {}
    for i, a in ipairs(args) do argv[i] = M.sh_quote(a) end
    return "cd " .. M.sh_quote(root) .. " && pull " .. table.concat(argv, " ")
end

--- Shell command that opens the user's terminal running `cmd` (a command line):
-- $TERMINAL (-e), else xdg-terminal-exec (the desktop's default), else x-terminal-emulator.
function M.terminal_cmd(cmd)
    return 'if [ -n "$TERMINAL" ]; then set -- "$TERMINAL" -e; '
        .. "elif command -v xdg-terminal-exec >/dev/null; then set -- xdg-terminal-exec; "
        .. "else set -- x-terminal-emulator -e; fi; "
        .. 'setsid -f "$@" sh -c ' .. M.sh_quote(cmd) .. " >/dev/null 2>&1"
end

--- ycode.json_decode turns JSON null into a userdata sentinel; make those nil.
function M.strip_nulls(t)
    for k, v in pairs(t) do
        if type(v) == "userdata" then t[k] = nil
        elseif type(v) == "table" then M.strip_nulls(v) end
    end
    return t
end

return M
