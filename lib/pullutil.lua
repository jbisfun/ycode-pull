-- Shared helpers for ycode-pull's windows.
local M = {}

-- Directory containing pullfile.plist: $PULL_ROOT, else walk up from the cwd.
function M.find_root()
    local env = os.getenv("PULL_ROOT")
    if env and env ~= "" then return env end
    local dir = os.getenv("PWD") or "."
    while dir and dir ~= "" do
        local f = io.open(dir .. "/pullfile.plist")
        if f then f:close(); return dir end
        local parent = dir:match("^(.*)/[^/]+$")
        if parent == dir then break end
        dir = parent
    end
    return os.getenv("HOME") .. "/jbisfun"
end

function M.sh_quote(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

-- `cd root && pull <args...>` as a shell command line (args are quoted).
function M.pull_cmd(root, args)
    local argv = {}
    for i, a in ipairs(args) do argv[i] = M.sh_quote(a) end
    return "cd " .. M.sh_quote(root) .. " && pull " .. table.concat(argv, " ")
end

return M
