--- The workspace CI (idlci) for ycode-pull: reads idlci's JSON API (`/api`, at the
-- address in `.pull/idlci/serve.addr`; theme docs/workspace-tools.md §5) and
-- queues/cancels/retries through the `idlci` CLI, which checks that the server it
-- reaches serves this workspace.
-- @module pullci
local util = require("pullutil")
local socket = require("socket")

local M = {}

--- Seconds between project/job list refreshes, and between log tail refreshes of a
-- running job.
M.REFRESH_SECONDS = 3
M.TAIL_SECONDS = 1
M.TAIL_LINES = 15
--- Jobs listed below the projects: every queued/running one, then the latest others.
M.RECENT_JOBS = 5

local ACTIVE = { queued = true, running = true }

--- `{icon, color}` for a job/project status.
M.STATUS_ICON = {
    passed = { "check", "success" },
    failed = { "x_circle", "error" },
    running = { "load_circle", "accent" },
    queued = { "clock", "muted" },
    cancelled = { "dash", "muted" },
}

local function base(root)
    return util.tool_base(root, "idlci")
end

local function curl(root, path)
    return "curl -sS --fail-with-body --max-time 5 " .. util.sh_quote(base(root) .. path)
end

local function decode(out)
    local ok, v = pcall(ycode.json_decode, out)
    if ok and type(v) == "table" then return util.strip_nulls(v) end
end

--- `idlci ARGS --root ROOT` as a shell command line.
function M.cli_cmd(root, args)
    local argv = {}
    for i, a in ipairs(args) do argv[i] = util.sh_quote(a) end
    return "cd " .. util.sh_quote(root) .. " && idlci " .. table.concat(argv, " ")
        .. " --root " .. util.sh_quote(root)
end

--- Run `idlci ARGS`; `done(ok, last_line)` on the main thread.
function M.cli(root, args, done)
    ycode.spawn(M.cli_cmd(root, args) .. " 2>&1", function(ok, out)
        out = (out or ""):gsub("%s+$", "")
        done(ok, out:match("[^\n]*$") or "")
    end)
end

--- The CI state kept in a window's state (`st.ci`).
function M.state(st)
    st.ci = st.ci or { tails = {}, open = {} }
    return st.ci
end

--- Re-read projects and recent jobs when they are older than REFRESH_SECONDS (or `force`).
function M.refresh(ci, root, force)
    local now = socket.gettime()
    if ci.loading or not root or (not force and now - (ci.at or 0) < M.REFRESH_SECONDS) then return end
    ci.loading, ci.at = 2, now
    local function landed() ci.loading = ci.loading - 1; if ci.loading == 0 then ci.loading = nil end end
    ycode.spawn(curl(root, "/api/projects") .. " 2>&1", function(ok, out)
        landed()
        local v = ok and decode(out)
        if v then
            ci.projects, ci.error = v, nil
        else
            ci.projects = nil
            ci.error = "idlci isn't running at " .. base(root)
                .. " (pull launchctl start idlci)"
        end
    end)
    ycode.spawn(curl(root, "/api/jobs?limit=30") .. " 2>/dev/null", function(ok, out)
        landed()
        local v = ok and decode(out)
        if v then ci.jobs = v end
    end)
end

--- Re-read the last TAIL_LINES lines of job `id`'s log (throttled to TAIL_SECONDS).
function M.tail(ci, root, id)
    local t = ci.tails[id] or {}
    ci.tails[id] = t
    local now = socket.gettime()
    if t.loading or (t.at and (t.final or now - t.at < M.TAIL_SECONDS)) then return t end
    t.loading, t.at = true, now
    ycode.spawn(curl(root, "/api/jobs/" .. id .. "/log?tail=" .. M.TAIL_LINES), function(ok, out)
        t.loading = false
        local v = ok and decode(out)
        if v then
            t.text, t.status = v.text or "", v.status
            t.final = v.status and not ACTIVE[v.status]
        else
            t.text = out
        end
    end)
    return t
end

--- A project's status: running, queued (a job waits for it), else its last build's.
function M.project_status(ci, p)
    if p.running then return "running" end
    for _, j in ipairs(ci.jobs or {}) do
        if j.project == p.path and j.status == "queued" then return "queued" end
    end
    return p.last_build and p.last_build.status or nil
end

local RANK = { running = 5, queued = 4, failed = 3, cancelled = 2, passed = 1 }

--- The most pressing status of the CI projects in pullfile repo `repo` (running >
-- queued > failed > cancelled > passed), and how many projects it has; nil without any.
function M.repo_status(ci, repo)
    local best, n = nil, 0
    for _, p in ipairs(ci.projects or {}) do
        if p.repo == repo then
            n = n + 1
            local s = M.project_status(ci, p)
            if s and (not best or RANK[s] > RANK[best]) then best = s end
        end
    end
    if n > 0 then return best or "none", n end
end

--- An `icon` element for `status` (a muted circle when there's none).
function M.status_icon(status, size)
    local s = M.STATUS_ICON[status] or { "circle", "muted" }
    return { "icon", name = s[1], color = s[2], size = size or "small" }
end

local function ago(t)
    if not t then return "" end
    local d = os.time() - t
    if d < 60 then return d .. "s ago" end
    if d < 3600 then return math.floor(d / 60) .. "m ago" end
    if d < 86400 then return math.floor(d / 3600) .. "h ago" end
    return math.floor(d / 86400) .. "d ago"
end

local function duration(j)
    if not j.started then return nil end
    local d = (j.finished or os.time()) - j.started
    return d < 60 and (d .. "s") or string.format("%dm%02ds", d // 60, d % 60)
end

--- One line about job `j`: "build · passed · 12s · 3m ago".
function M.job_detail(j, with_project)
    local parts = {}
    if with_project then parts[#parts + 1] = j.project end
    parts[#parts + 1] = j.status
    if j.configuration and j.configuration ~= "none" then parts[#parts + 1] = j.configuration end
    parts[#parts + 1] = duration(j)
    parts[#parts + 1] = ago(j.finished or j.started or j.created)
    return table.concat(parts, " · ")
end

--- URLs of the CI pages: dashboard, a project's, a job's (live console).
function M.url(root, kind, arg)
    local b = base(root)
    if kind == "project" then return b .. "/projects/" .. util.url_encode(arg, true) end
    if kind == "job" then return b .. "/jobs/" .. arg end
    return b .. "/"
end

--- The panel's CI sections: "CI" lists the projects (status, hover: build, test, open
-- page), "CI jobs" the active and recent jobs (click: live log tail below it; hover:
-- cancel or retry, open the job page). `act(w, ok, msg)` reports results.
function M.sections(st, root, act)
    local ci = M.state(st)
    M.refresh(ci, root)
    local function open(url)
        return function(w) util.open_url(url, function(ok, msg) act(w, ok, msg) end) end
    end
    local function cli(args, prefix)
        return function(w)
            M.cli(root, args, function(ok, msg)
                act(w, ok, ok and prefix and (prefix .. msg) or msg)
                M.refresh(ci, root, true)
            end)
        end
    end

    local sec = { "section", "CI", empty = ci.error or (ci.projects and "no idl projects" or "loading…"),
        action = { "icon_button", icon = "public", tooltip = "Open the CI dashboard in the browser",
            on_click = open(M.url(root)) } }
    for _, p in ipairs(ci.projects or {}) do
        local s = M.project_status(ci, p)
        local last = p.last_build
        sec[#sec + 1] = { "list_item", p.path, tooltip = p.path .. (p.head and (" @" .. (p.branch or "?") .. ":" .. p.head) or ""),
            detail = last and ("#" .. last.id .. " " .. (last.status or "") .. " " .. ago(last.finished or last.created))
                or "never built",
            start = M.status_icon(s),
            end_ = p.health and { "text", p.health .. "%", size = "small", color = "muted" } or nil,
            end_hover = { "row",
                { "icon_button", icon = "tool_hammer", tooltip = "Queue a build (idlci queue " .. p.path .. " build)",
                  on_click = cli({ "queue", p.path, "build" }) },
                { "icon_button", icon = "play_outlined", tooltip = "Queue the tests (idlci queue " .. p.path .. " test)",
                  on_click = cli({ "queue", p.path, "test" }) },
                { "icon_button", icon = "public", tooltip = "Open the project page in the browser",
                  on_click = open(M.url(root, "project", p.path)) } },
            on_click = open(M.url(root, "project", p.path)) }
    end

    -- active jobs first, then the latest finished ones
    local shown, recent = {}, 0
    for _, j in ipairs(ci.jobs or {}) do if ACTIVE[j.status] then shown[#shown + 1] = j end end
    for _, j in ipairs(ci.jobs or {}) do
        if not ACTIVE[j.status] and recent < M.RECENT_JOBS then
            shown[#shown + 1] = j
            recent = recent + 1
        end
    end
    local jobs = { "section", "CI jobs", empty = ci.projects and "no jobs yet" or nil }
    for _, j in ipairs(shown) do
        local expanded = ci.open[j.id]
        local hover = { "row" }
        if ACTIVE[j.status] then
            hover[#hover + 1] = { "icon_button", icon = "stop", tooltip = "Cancel #" .. j.id,
                on_click = cli({ "cancel", tostring(j.id) }, "cancel sent: ") }
        else
            hover[#hover + 1] = { "icon_button", icon = "rotate_ccw", tooltip = "Retry #" .. j.id,
                on_click = cli({ "retry", tostring(j.id) }) }
        end
        hover[#hover + 1] = { "icon_button", icon = "public", tooltip = "Open the job page (live console)",
            on_click = open(M.url(root, "job", j.id)) }
        jobs[#jobs + 1] = { "list_item", "#" .. j.id .. " " .. j.command, detail = M.job_detail(j, true),
            indent = 1, selected = expanded == true, start = M.status_icon(j.status),
            end_hover = hover,
            on_click = function() ci.open[j.id] = not expanded or nil end }
        if expanded then
            local t = M.tail(ci, root, j.id)
            local log = { "col", px = "sm", py = "xs", bg = "editor", border = true, rounded = true }
            local text = t.text or "loading…"
            if text == "" then text = "(no output yet)" end
            for line in (text .. "\n"):gmatch("(.-)\n") do
                log[#log + 1] = { "text", line == "" and " " or line, mono = true, size = "xsmall", truncate = true }
            end
            jobs[#jobs + 1] = { "col", px = "md", py = "xs", log }
        end
    end
    if not ci.projects then return { sec } end
    if #ci.projects == 0 and #shown == 0 then return {} end -- a workspace without CI
    return { sec, jobs }
end

return M
