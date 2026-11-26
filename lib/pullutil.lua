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

--- The cpull workspace server's base URL ("http://HOST:PORT"): the address it wrote to
-- `.pull/cpull/serve.addr`, else $CPULL_ADDR, else cpull's default 127.0.0.1:8080.
function M.cpull_base(root)
    local addr
    local f = root and io.open(root .. "/.pull/cpull/serve.addr")
    if f then addr = (f:read("a") or ""):match("^%s*(.-)%s*$"); f:close() end
    if not addr or addr == "" then addr = os.getenv("CPULL_ADDR") end
    if not addr or addr == "" then addr = "127.0.0.1:8080" end
    return "http://" .. addr
end

--- The owner part of the workspace's cpull repo identities ("<owner>:<repo>"): the root's
-- directory name when it is a valid cpull user name, else "workspace" (as cpull does).
function M.cpull_owner(root)
    local base = (root or ""):match("([^/]+)/*$") or ""
    local lower = base:lower()
    if #base >= 3 and #base <= 32 and base:match("^[%w%-]+$") and not base:match("^%-")
        and not base:match("%-$") and not base:match("%-%-") and lower ~= "home" and lower ~= "user" then
        return base
    end
    return "workspace"
end

--- `s` percent-encoded for a URL path segment (keeps `/` when `keep_slash`).
function M.url_encode(s, keep_slash)
    return (tostring(s):gsub("[^%w%-%._~/]", function(c)
        return string.format("%%%02X", c:byte())
    end):gsub("/", keep_slash and "/" or "%%2F"))
end

--- The cpull files page for `file` (relative to pullfile repo `repo`) at `ref` (a branch
-- name, or a commit when `is_commit`), scrolled to `line`. Like cpull's own report links,
-- a line past the files view's first 5000 starts the window a little above it.
function M.cpull_file_url(root, repo, ref, file, line, is_commit)
    local id = M.cpull_owner(root) .. ":" .. repo:gsub("/", ".")
    local url = M.cpull_base(root) .. "/" .. id .. "/files/"
        .. (is_commit and "object:" or "branch:") .. M.url_encode(ref)
    if line and line > 4000 then url = url .. "/line:" .. (line - 20) end
    if file and file ~= "" then url = url .. "/path:" .. M.url_encode(file, true) end
    if line then url = url .. "#L" .. line end
    return url
end

--- Shell command that opens `url` in the desktop's browser (xdg-open), detached.
function M.browser_cmd(url)
    return "setsid -f xdg-open " .. M.sh_quote(url) .. " >/dev/null 2>&1"
end

--- Open `url` in the browser; `done(ok, msg)` gets a one-line result.
function M.open_url(url, done)
    ycode.spawn(M.browser_cmd(url), function(ok, out)
        if done then done(ok, ok and ("opened " .. url) or ("xdg-open failed: " .. (out or ""))) end
    end)
end

--- `{root, repo, file}` for an absolute `path` inside the workspace: the repo is the
-- deepest directory above it holding a `.git` (pullfile repos can be nested, e.g.
-- fossify-ios/calculator-ios). nil when `path` isn't in a repo of the workspace.
function M.repo_of(root, path)
    local prefix = root .. "/"
    if not path or path:sub(1, #prefix) ~= prefix then return nil end
    local rel = path:sub(#prefix + 1)
    local dir = rel:match("^(.*)/[^/]+$")
    while dir and dir ~= "" do
        local f = io.open(prefix .. dir .. "/.git")
        if f then
            f:close()
            return { root = root, repo = dir, file = rel:sub(#dir + 2) }
        end
        dir = dir:match("^(.*)/[^/]+$")
    end
end

--- Open absolute `path` at `line` in the cpull web UI's files view, at the repo's
-- checked-out branch (or its HEAD commit when detached). `done(ok, msg)`.
function M.open_file_in_cpull(root, path, line, done)
    local at = M.repo_of(root, path)
    if not at then done(false, path .. " is not in a repo of " .. root); return end
    local dir = M.sh_quote(root .. "/" .. at.repo)
    ycode.spawn("git -C " .. dir .. " symbolic-ref -q --short HEAD || git -C " .. dir .. " rev-parse HEAD",
        function(ok, out)
            local ref = (out or ""):match("^%s*(%S+)")
            if not ok or not ref then done(false, "git: " .. (out or "")); return end
            local url = M.cpull_file_url(root, at.repo, ref, at.file, line, ref:match("^%x+$") and #ref == 40)
            M.open_url(url, done)
        end)
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
