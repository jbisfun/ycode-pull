-- ycode-pull changes panel: the pull workspace's changes in a dock panel.
--
-- Every repo's changed files in one list, grouped by repo. Click a file to open it, click
-- its checkbox to stage/unstage (`pull add` / `pull unstage`). One commit message goes to every
-- repo with staged changes through `pull commit`, so the pullfile's lint rules and hooks
-- apply; with nothing staged it commits all tracked changes (-a). Sync, update and push
-- for the whole workspace. Zed's single-repository git panel button is hidden in pull
-- workspaces, and every MCP server from `pull mcp-servers` (pull itself, plus the
-- pullfile's `mcp_servers` section) is registered for ycode's agents.
--
-- Below the changes, the workspace CI, idlci (lib/pullci.lua): each idl project's status with
-- build/test buttons, the active and recent jobs with a live log tail, cancel and retry,
-- and links to the CI pages; repos with CI projects show their status next to the name.
-- Toggle with "pull: changes".

local util = require("pullutil")
local ci = require("pullci")
local socket = require("socket")

local REFRESH_SECONDS = 2

local function root(st)
    if not st.root then st.root = util.find_root() end
    return st.root
end

local function run(w, args, after)
    local st = w.state
    st.busy = (st.busy or 0) + 1
    st.message = "pull " .. table.concat(args, " ") .. " …"
    ycode.spawn(util.pull_cmd(root(st), args) .. " 2>&1", function(ok, out)
        st.busy = st.busy - 1
        out = out:gsub("%s+$", "")
        st.message = ok and (out ~= "" and out:match("[^\n]*$") or "done") or out
        st.failed = not ok
        st.last_refresh = 0
        if after then after(ok, out) end
    end)
end

local function refresh(st)
    if st.loading or not root(st) then return end
    st.loading, st.last_refresh = true, socket.gettime()
    ycode.spawn(util.pull_cmd(st.root, { "status", "--json" }), function(ok, out)
        st.loading = false
        if not ok then st.error = out; return end
        local okj, data = pcall(ycode.json_decode, out)
        if okj and type(data) == "table" then
            st.data, st.error = util.strip_nulls(data), nil
        end
    end)
end

local LETTER_COLOR = { A = "success", ["?"] = "success", M = "warning", D = "error",
    R = "accent" }

local function is_staged(c) return c.staged ~= " " and c.staged ~= "?" end
local function is_unstaged(c) return c.unstaged ~= " " end

local function counts(data)
    local staged, changed = 0, 0
    for _, r in ipairs(data and data.repos or {}) do
        for _, c in ipairs(r.changes or {}) do
            changed = changed + 1
            if is_staged(c) then staged = staged + 1 end
        end
    end
    return staged, changed
end

local function change_row(w, repo, c)
    local rel = repo.name .. "/" .. c.path
    local staged, unstaged = is_staged(c), is_unstaged(c)
    local letter = staged and c.staged or c.unstaged
    local dir, file = c.path:match("^(.*/)([^/]+)$")
    return { "list_item", file or c.path, detail = dir, indent = 1, tooltip = rel,
        start = { "checkbox", checked = staged and (unstaged and "mixed" or true) or false,
            on_click = function(w) run(w, { unstaged and "add" or "unstage", rel }) end },
        end_ = { "text", letter, mono = true, size = "small", color = LETTER_COLOR[letter] or "muted" },
        on_click = function() ycode.open(repo.path .. "/" .. c.path) end }
end

local function repo_rows(w, repo, out)
    local st = w.state
    local changes = repo.changes or {}
    local staged, unstaged = 0, 0
    for _, c in ipairs(changes) do
        if is_staged(c) then staged = staged + 1 end
        if is_unstaged(c) then unstaged = unstaged + 1 end
    end
    local info = repo.branch or (repo.cloned and "(unborn)" or "not cloned")
    if (repo.ahead or 0) > 0 or (repo.behind or 0) > 0 then
        info = info .. string.format("  ↑%d ↓%d", repo.ahead or 0, repo.behind or 0)
    end
    local collapsed = st.collapsed[repo.name]
    local function toggle() st.collapsed[repo.name] = not collapsed end

    -- Stage/unstage all appear on hover in place of the change count.
    local hover = { "row" }
    if unstaged > 0 then
        hover[#hover + 1] = { "icon_button", icon = "plus", tooltip = "Stage all",
            on_click = function(w) run(w, { "add", repo.name }) end }
    end
    if staged > 0 then
        hover[#hover + 1] = { "icon_button", icon = "dash", tooltip = "Unstage all",
            on_click = function(w) run(w, { "unstage", repo.name }) end }
    end
    local end_ = { "row", gap = "xs" }
    local ci_status, ci_projects = ci.repo_status(ci.state(st), repo.name)
    if ci_status then
        local icon = ci.status_icon(ci_status, "xsmall")
        end_[#end_ + 1] = icon
    end
    if #changes > 0 then
        end_[#end_ + 1] = { "text", tostring(#changes), size = "small", color = "muted" }
    end
    out[#out + 1] = { "list_item", repo.name, detail = info, bold = true, on_click = toggle,
        tooltip = ci_status and ("CI: " .. ci_status .. " (" .. ci_projects .. " project"
            .. (ci_projects == 1 and "" or "s") .. ")") or nil,
        start = { "disclosure", open = not collapsed, on_click = toggle },
        end_ = #end_ > 1 and end_ or nil,
        end_hover = #hover > 1 and hover or nil }
    if not collapsed then
        for _, c in ipairs(changes) do out[#out + 1] = change_row(w, repo, c) end
    end
end

local function commit(w)
    local st = w.state
    local msg = (w.text("msg") or ""):match("^%s*(.-)%s*$")
    if msg == "" then st.message, st.failed = "commit message is empty", true; return end
    local staged = counts(st.data)
    local args = { "commit", "-m", msg }
    if staged == 0 then table.insert(args, 2, "-a") end
    run(w, args, function(ok) if ok then w.set_text("msg", "") end end)
end

local function render(w)
    local st = w.state
    if not root(st) then return { "empty", util.NO_ROOT } end
    if socket.gettime() - (st.last_refresh or 0) > REFRESH_SECONDS then refresh(st) end

    local data = st.data or { repos = {} }
    local staged, changed = counts(data)
    local rows = {}
    for _, repo in ipairs(data.repos or {}) do
        if #(repo.changes or {}) > 0 or (repo.ahead or 0) > 0 or not repo.cloned then
            repo_rows(w, repo, rows)
        end
    end

    local lint = data.lint or {}
    local max = lint.max_subject_length
    local msg = w.text("msg") or ""
    local counter = max and (#msg .. "/" .. max) or tostring(#msg)
    local label = staged > 0 and ("Commit " .. staged .. (staged == 1 and " file" or " files"))
        or "Commit tracked"

    local panel = { "panel", id = "changes",
        header = { title = "Pull", context = changed .. " changed", actions = {
            { "icon_button", icon = "rotate_cw", tooltip = "Sync",
              on_click = function(w) run(w, { "sync" }) end },
            { "icon_button", icon = "cloud_download", tooltip = "Update",
              on_click = function(w) run(w, { "update" }) end },
            { "icon_button", icon = "arrow_up", tooltip = "Push",
              on_click = function(w) run(w, { "push" }) end } } },
        footer = { "col", grow = true, gap = "sm", py = "xs",
            { "input", id = "msg", placeholder = "commit message (ctrl-enter)" },
            { "row", gap = "sm",
                { "text", counter, size = "small", grow = true,
                  color = (max and #msg > max) and "error" or "muted" },
                { "button", label, style = "filled", disabled = changed == 0, on_click = commit } },
            { "text", st.message or st.root, size = "small", truncate = true,
              color = st.failed and "error" or "muted" } },
    }
    local ci_sections = ci.sections(st, st.root, function(_, ok, msg)
        st.message, st.failed = msg, not ok
    end)
    if #rows == 0 then
        local msg = st.data and ("no changes in " .. #(data.repos or {}) .. " repos")
            or (st.error or "loading…")
        panel[#panel + 1] = #ci_sections == 0 and { "empty", msg } or { "section", "Changes", empty = msg }
    else
        for _, r in ipairs(rows) do panel[#panel + 1] = r end
    end
    for _, sec in ipairs(ci_sections) do panel[#panel + 1] = sec end
    return panel
end

%ctor
    gpui.register_panel{
        id = "pull", title = "Pull", icon = "git_branch", position = "left", size = 340,
        poll_ms = 500,
        state = { collapsed = {} },
        on_key = function(w, ev)
            if ev.ctrl and ev.key == "enter" then commit(w); return true end
        end,
        render = function(w)
            local ok, tree = pcall(render, w)
            if ok then return tree end
            return { "empty", "ycode-pull: " .. tostring(tree), color = "error" }
        end,
    }
    -- Once a pull workspace is open (folders appear after startup; retry for a while):
    -- hide Zed's git panel (one repository at a time; this panel replaces it) and
    -- register every MCP server the pullfile configures (`pull mcp-servers --json`:
    -- `pull` itself, plus the `mcp_servers` section), which ycode's agent
    -- uses and forwards to ACP agents such as Hermes.
    local tries = 0
    local function setup()
        local root = util.find_root()
        if not root then
            tries = tries + 1
            if tries < 30 then ycode.spawn("sleep 1", setup) end
            return
        end
        ycode.spawn(util.pull_cmd(root, { "mcp-servers" }), function(ok, out)
            if not ok then
                ycode.log("ycode-pull: `pull mcp-servers` failed: " .. out)
                return
            end
            local okj, servers = pcall(ycode.json_decode, out)
            if not okj or type(servers) ~= "table" then
                ycode.log("ycode-pull: bad mcp-servers json: " .. tostring(servers))
                return
            end
            util.strip_nulls(servers)
            ycode.settings{
                git_panel = { button = false },
                context_servers = servers,
            }
            local names = {}
            for name in pairs(servers) do names[#names + 1] = name end
            table.sort(names)
            ycode.log("ycode-pull: " .. root .. ", MCP servers registered (" ..
                table.concat(names, ", ") .. ")")
        end)
    end
    setup()
end

%hook pull
%new - Changes
    ycode.dispatch("ycode::TogglePanel", { id = "pull" })
end
%end
