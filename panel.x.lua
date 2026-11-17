-- ycode-pull changes panel: the pull workspace's changes in a dock panel.
--
-- Every repo's changed files in one list, grouped by repo. Click a file to open it, click
-- its box to stage/unstage (`pull add` / `pull unstage`). One commit message goes to every
-- repo with staged changes through `pull commit`, so the pullfile's lint rules and hooks
-- apply; with nothing staged it commits all tracked changes (-a). Sync, update and push
-- for the whole workspace. Zed's single-repository git panel button is hidden in pull
-- workspaces, and `pull mcp` is registered as an MCP server for ycode's agents.
-- Toggle with "pull: changes".

local util = require("pullutil")
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
    local box = staged and (unstaged and "[-]" or "[x]") or "[ ]"
    local letter = staged and c.staged or c.unstaged
    local dir, file = c.path:match("^(.*/)([^/]+)$")
    local name = { "row", gap = 6, grow = true, on_click = function()
            ycode.open(repo.path .. "/" .. c.path)
        end,
        { "text", file or c.path },
    }
    if dir then name[#name + 1] = { "text", dir, fg = "muted", size = 11 } end
    return { "row", gap = 6, align = "center", px = 6, py = 1,
        { "text", box, mono = true, fg = staged and "accent" or "muted",
          on_click = function(w)
              run(w, { unstaged and "add" or "unstage", rel })
          end },
        { "text", letter, mono = true, bold = true, fg = LETTER_COLOR[letter] or "muted", w = 12 },
        name,
    }
end

local function repo_section(w, repo)
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
    local header = { "row", gap = 6, align = "center", px = 6, py = 3, bg = "element", rounded = 4,
        { "row", gap = 6, grow = true, align = "center",
          on_click = function() st.collapsed[repo.name] = not collapsed end,
            { "text", (collapsed and "▸ " or "▾ ") .. repo.name, bold = true },
            { "text", info, size = 11, fg = "muted" },
            { "text", #changes > 0 and tostring(#changes) or "", size = 11, fg = "accent" },
        },
    }
    if unstaged > 0 then
        header[#header + 1] = { "button", "Stage all", size = 11,
            on_click = function(w) run(w, { "add", repo.name }) end }
    end
    if staged > 0 then
        header[#header + 1] = { "button", "Unstage all", size = 11,
            on_click = function(w) run(w, { "unstage", repo.name }) end }
    end
    local section = { "col", gap = 1, header }
    if not collapsed then
        for _, c in ipairs(changes) do section[#section + 1] = change_row(w, repo, c) end
    end
    return section
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
    if not root(st) then
        return { "col", p = 12, { "text", util.NO_ROOT, fg = "muted", size = 12 } }
    end
    if socket.gettime() - (st.last_refresh or 0) > REFRESH_SECONDS then refresh(st) end

    local data = st.data or { repos = {} }
    local list = { "col", id = "changes", scroll = true, grow = true, gap = 6, p = 6 }
    for _, repo in ipairs(data.repos or {}) do
        if #(repo.changes or {}) > 0 or (repo.ahead or 0) > 0 or not repo.cloned then
            list[#list + 1] = repo_section(w, repo)
        end
    end
    local staged, changed = counts(data)
    if #list == 0 then
        list[#list + 1] = { "text", st.data and "no changes in " .. #(data.repos or {}) .. " repos"
            or (st.error or "loading…"), fg = "muted", size = 12, p = 6 }
    end

    local lint = data.lint or {}
    local max = lint.max_subject_length
    local msg = w.text("msg") or ""
    local counter = max and (#msg .. "/" .. max) or tostring(#msg)
    local label = staged > 0 and ("Commit " .. staged .. (staged == 1 and " file" or " files"))
        or "Commit tracked"

    return { "col", w = "full", h = "full",
        { "row", gap = 6, align = "center", px = 8, py = 6, border = "border",
            { "text", "Pull", bold = true },
            { "text", changed .. " changed", size = 11, fg = "muted", grow = true },
            { "button", "Sync", size = 11, on_click = function(w) run(w, { "sync" }) end },
            { "button", "Update", size = 11, on_click = function(w) run(w, { "update" }) end },
            { "button", "Push", size = 11, on_click = function(w) run(w, { "push" }) end },
        },
        list,
        { "col", gap = 6, p = 8, border = "border",
            { "input", id = "msg", placeholder = "commit message (ctrl-enter)" },
            { "row", gap = 6, align = "center",
                { "text", counter, size = 11, grow = true,
                  fg = (max and #msg > max) and "error" or "muted" },
                { "button", label, on_click = commit },
            },
            { "text", st.message or st.root, size = 11, mono = true,
              fg = st.failed and "error" or "muted" },
        },
    }
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
            return { "text", "ycode-pull: " .. tostring(tree), fg = "error" }
        end,
    }
    -- Once a pull workspace is open (folders appear after startup; retry for a while):
    -- hide Zed's git panel (one repository at a time; this panel replaces it) and
    -- register `pull mcp` as an MCP server, which ycode's agent uses and forwards to ACP
    -- agents such as Hermes.
    local tries = 0
    local function setup()
        local root = util.find_root()
        if not root then
            tries = tries + 1
            if tries < 30 then ycode.spawn("sleep 1", setup) end
            return
        end
        ycode.spawn("command -v pull", function(ok, out)
            local pull = ok and out:match("[^\n]+") or "pull"
            ycode.settings{
                git_panel = { button = false },
                context_servers = {
                    pull = { command = pull, args = { "mcp", "--root", root } },
                },
            }
            ycode.log("ycode-pull: " .. root .. ", MCP server registered (" .. pull .. " mcp)")
        end)
    end
    setup()
end

%hook pull
%new - Changes
    ycode.dispatch("ycode::TogglePanel", { id = "pull" })
end
%end
