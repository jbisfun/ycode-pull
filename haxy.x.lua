-- ycode-pull issues: haxy issues of the workspace repos, in a dock panel.
--
-- haxy (a local-first git forge) keeps issues on each repo's `haxy/events` branch.
-- The panel lists the open issues of every repo that has one (`pull haxy issues
-- --json`), grouped by repo; select one to read it with its comments, close or reopen
-- it, or open haxy's own UI on that repo in your terminal (`pull haxy open REPO`).
-- Sync (`pull haxy sync`) fetches, merges and pushes every repo's events. Toggle with
-- "pull: issues"; "pull: haxy sync" syncs without the panel.

local util = require("pullutil")
local q = util.sh_quote
local socket = require("socket")

local REFRESH_SECONDS = 10

-- Shared with the palette action: its result shows in the panel's footer.
local shared = { message = nil, synced = 0 }

local function root(st)
    if not st.root then st.root = util.find_root() end
    return st.root
end

local function last_line(out)
    out = (out or ""):gsub("%s+$", "")
    return out:match("[^\n]*$") or ""
end

local function refresh(st)
    if st.loading or not root(st) then return end
    st.loading, st.last_refresh = true, socket.gettime()
    ycode.spawn(util.pull_cmd(st.root, { "haxy", "issues", "--json" }), function(ok, out)
        st.loading = false
        if not ok then st.error = out; return end
        local okj, data = pcall(ycode.json_decode, out)
        if okj and type(data) == "table" then st.data, st.error = util.strip_nulls(data), nil end
    end)
end

local function run(w, args, after)
    local st = w.state
    st.busy = (st.busy or 0) + 1
    st.message, st.failed = "pull " .. table.concat(args, " ") .. " …", false
    ycode.spawn(util.pull_cmd(root(st), args) .. " 2>&1", function(ok, out)
        st.busy = st.busy - 1
        st.message, st.failed = ok and (last_line(out) ~= "" and last_line(out) or "done") or out, not ok
        st.last_refresh = 0
        if after then after(ok, out) end
    end)
end

local function sync(root_dir, done)
    ycode.spawn(util.pull_cmd(root_dir, { "haxy", "sync" }) .. " 2>&1", function(ok, out)
        out = out:gsub("%s+$", "")
        shared.message = ok and (out ~= "" and out:gsub("\n", "; ") or "no repo has haxy/events") or out
        shared.failed, shared.synced = not ok, socket.gettime()
        ycode.log("ycode-pull: haxy sync: " .. shared.message)
        if done then done(ok) end
    end)
end

local function open_haxy(w, repo)
    local st = w.state
    local cmd = "cd " .. q(st.root) .. " && pull haxy open " .. q(repo)
    ycode.spawn(util.terminal_cmd(cmd), function(ok, out)
        st.message = ok and ("opened haxy on " .. repo .. " in a terminal") or ("could not open a terminal: " .. out)
        st.failed = not ok
    end)
end

local function find(st)
    for _, r in ipairs(st.data and st.data.repos or {}) do
        for _, i in ipairs(r.issues or {}) do
            if r.name == st.sel_repo and i.id == st.sel_id then return r, i end
        end
    end
end

local function date(t) return t and os.date("%Y-%m-%d %H:%M", t) or "?" end

-- `text` as one text element per line (long descriptions and comments).
local function lines(out, text, opts)
    for line in ((text or "") .. "\n"):gmatch("(.-)\n") do
        local el = { "text", line == "" and " " or line, size = "small" }
        for k, v in pairs(opts or {}) do el[k] = v end
        out[#out + 1] = el
    end
end

local function issue_row(w, repo, i)
    local st = w.state
    local detail = {}
    if #(i.labels or {}) > 0 then detail[#detail + 1] = table.concat(i.labels, " ") end
    if #(i.comments or {}) > 0 then detail[#detail + 1] = #i.comments .. " comments" end
    return { "list_item", i.title, detail = table.concat(detail, " · "), indent = 1,
        selected = st.sel_repo == repo.name and st.sel_id == i.id,
        on_click = function() st.sel_repo, st.sel_id = repo.name, i.id end }
end

local function details(w, repo, i)
    local closed = i.status == "closed"
    local body = { "col", gap = "sm", px = "md", py = "sm",
        { "text", i.id:sub(1, 8) .. " · " .. (i.author or "?") .. " · " .. date(i.created),
          size = "small", color = "muted", truncate = true } }
    if #(i.labels or {}) > 0 then
        body[#body + 1] = { "text", table.concat(i.labels, " "), size = "small", color = "accent" }
    end
    lines(body, i.description ~= "" and i.description or "(no description)",
        i.description == "" and { color = "muted" } or nil)
    for _, c in ipairs(i.comments or {}) do
        body[#body + 1] = { "divider" }
        body[#body + 1] = { "text", (c.author or "?") .. " · " .. date(c.created), size = "small",
            color = "muted", truncate = true }
        lines(body, c.body)
    end
    return { "panel", header = { title = i.title, context = i.status, actions = {
        { "icon_button", icon = closed and "rotate_ccw" or "check", tooltip = closed and "Reopen" or "Close",
          on_click = function(w)
              run(w, { "haxy", closed and "reopen" or "close", repo.name, i.id })
          end },
        { "icon_button", icon = "terminal", tooltip = "Open in haxy (terminal)",
          on_click = function(w) open_haxy(w, repo.name) end } } },
        body }
end

local function render(w)
    local st = w.state
    if not root(st) then return { "empty", util.NO_ROOT, color = "warning" } end
    if socket.gettime() - (st.last_refresh or 0) > REFRESH_SECONDS
        or (shared.synced or 0) > (st.last_refresh or 0) then refresh(st) end

    local repos = st.data and st.data.repos or {}
    local count = 0
    local list = { "panel", id = "haxy-list" }
    for _, r in ipairs(repos) do
        local sec = { "section", r.name, empty = "no open issues",
            action = { "icon_button", icon = "terminal", tooltip = "Open " .. r.name .. " in haxy",
                on_click = function(w) open_haxy(w, r.name) end } }
        for _, i in ipairs(r.issues or {}) do
            sec[#sec + 1] = issue_row(w, r, i)
            count = count + 1
        end
        list[#list + 1] = sec
    end
    if #repos == 0 then
        list[#list + 1] = { "empty", st.data and "no repo has a haxy/events branch"
            or (st.error or "loading…") }
    end

    local repo, issue = find(st)
    local status = (st.busy or 0) > 0 and "working…" or (st.message or shared.message or st.root)
    return { "panel", scroll = false,
        header = { title = "Issues", context = count .. " open", actions = {
            { "icon_button", icon = "rotate_cw", tooltip = "Sync haxy/events (pull haxy sync)",
              on_click = function(w)
                  st.busy = (st.busy or 0) + 1
                  st.message = nil
                  sync(st.root, function() st.busy = st.busy - 1 end)
              end } } },
        footer = { "text", status, size = "small", truncate = true,
            color = (st.failed or (not st.message and shared.failed)) and "error" or "muted" },
        { "split", list, issue and details(w, repo, issue) or { "empty", "select an issue" } } }
end

%ctor
    gpui.register_panel{
        id = "pull-haxy", title = "Issues", icon = "list_todo", position = "right", size = 420,
        poll_ms = 500,
        state = {},
        render = function(w)
            local ok, tree = pcall(render, w)
            if ok then return tree end
            return { "empty", "ycode-pull issues: " .. tostring(tree), color = "error" }
        end,
    }
end

%hook pull
%new - Issues
    ycode.dispatch("ycode::TogglePanel", { id = "pull-haxy" })
end
%new - HaxySync
    local dir = util.find_root()
    if not dir then ycode.log("ycode-pull: " .. util.NO_ROOT); return end
    sync(dir)
end
%end
