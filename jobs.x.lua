-- ycode-pull jobs: the workspace's launchd jobs and terminal sessions, in a dock panel.
--
-- Lists the pullfile's `jobs` (also ones not loaded yet) and ad-hoc `pull session`s, with
-- what each terminal is running (program, directory, pid, last exit). The inspector shows
-- the selected terminal's live screen; type into it, send ctrl-c, start/stop/restart,
-- unload or remove it, or open it in your terminal. New sessions start with a shell or a
-- command. Toggle with "pull: jobs" (bottom dock).

local util = require("pullutil")
local q = util.sh_quote
local socket = require("socket")

-- Run `pull <args>` in the background; `after(ok, out)` on the main thread.
local function run(w, args, after)
    local st = w.state
    st.busy = (st.busy or 0) + 1
    ycode.spawn(util.pull_cmd(st.root, args) .. " 2>&1", function(ok, out)
        st.busy = st.busy - 1
        if after then after(ok, out) end
        if not ok then st.message = out:gsub("%s+$", "") end
    end)
end

local strip_nulls = util.strip_nulls

local function refresh(w)
    local st = w.state
    if st.listing then return end
    st.last_list, st.listing = socket.gettime(), true
    -- --all: pullfile jobs that aren't loaded too, without starting the daemon to list.
    ycode.spawn(util.pull_cmd(st.root, { "launchctl", "list", "--json", "--all" }), function(ok, out)
        st.listing = false
        if not ok then return end
        local okj, list = pcall(ycode.json_decode, out)
        if okj and type(list) == "table" then
            st.sessions = strip_nulls(list)
            if not st.selected and list[1] then st.selected = list[1].label end
        end
    end)
end

local function capture(w)
    local st = w.state
    local name = st.selected
    if not name or st.capturing then return end
    st.last_capture, st.capturing = socket.gettime(), true
    ycode.spawn(util.pull_cmd(st.root, { "session", "capture", name }), function(ok, out)
        st.capturing = false
        if st.selected == name then st.screen = ok and out or "" end
    end)
end

local function selected(st)
    for _, s in ipairs(st.sessions or {}) do
        if s.label == st.selected then return s end
    end
end

local function act(w, args, msg)
    run(w, args, function(ok)
        if ok then w.state.message = msg end
        w.state.last_list = 0
        w.state.last_capture = 0
    end)
end

local function send(w, text, enter, label)
    local st = w.state
    local args = { "session", "send", st.selected }
    if enter then args[#args + 1] = "-e" end
    args[#args + 1] = "--"
    args[#args + 1] = text
    act(w, args, label or ("sent to " .. st.selected))
end

local function open_terminal(w, name)
    local st = w.state
    local attach = "cd " .. q(st.root) .. " && pull session attach " .. q(name)
    ycode.spawn(util.terminal_cmd(attach), function(ok, out)
        st.message = ok and ("opened " .. name .. " in a terminal (detach with ctrl-\\)")
            or ("could not open a terminal: " .. out)
    end)
end

local function new_session(w)
    local st = w.state
    local name = (w.text("new_name") or ""):match("^%s*(.-)%s*$")
    if name == "" then st.message = "session name is empty"; return end
    local cmd = (w.text("new_cmd") or ""):match("^%s*(.-)%s*$")
    local args = { "session", "new", "-d", name }
    if cmd ~= "" then
        for _, a in ipairs({ "--", "sh", "-c", cmd }) do args[#args + 1] = a end
    end
    run(w, args, function(ok)
        if not ok then return end
        w.set_text("new_name", "")
        w.set_text("new_cmd", "")
        st.selected, st.message = name, "started " .. name
        st.last_list, st.last_capture = 0, 0
    end)
end

local STATE_COLOR = { running = "success", exited = "muted", stopped = "warning",
    waiting = "accent", loaded = "muted", unloaded = "muted" }

local function session_row(w, s)
    local st = w.state
    local is_sel = s.label == st.selected
    local what = s.foreground and (s.foreground .. " in " .. (s.foreground_cwd or "?"))
        or (s.state == "unloaded" and table.concat(s.argv or {}, " "))
        or (s.state .. (s.last_exit and (", exit " .. s.last_exit) or ""))
    return { "col", p = 6, gap = 2, rounded = 4, bg = is_sel and "element" or nil,
        on_click = function(w)
            st.selected, st.screen, st.last_capture = s.label, "", 0
        end,
        { "row", gap = 6,
            { "text", s.label, bold = true, grow = true },
            { "text", s.state, size = 11, fg = STATE_COLOR[s.state] or "muted" },
        },
        { "text", what, size = 11, mono = true, fg = "muted" },
    }
end

local function details(w, s)
    local st = w.state
    local running = s.state == "running"
    local unloaded = s.state == "unloaded"
    local function info(k, v) return { "row", gap = 6,
        { "text", k, size = 12, fg = "muted", w = 80 },
        { "text", tostring(v), size = 12, mono = true, grow = true } } end

    local controls = { "row", gap = 6 }
    local function btn(label, f) controls[#controls + 1] = { "button", label, on_click = f } end
    if running then
        btn("Ctrl-C", function(w) send(w, "\3", false, "sent ctrl-c to " .. s.label) end)
        btn("Stop", function(w) act(w, { "launchctl", "stop", s.label }, "stopped " .. s.label) end)
        btn("Restart", function(w)
            act(w, { "launchctl", "kickstart", "-k", s.label }, "restarting " .. s.label) end)
        btn("Open in terminal", function(w) open_terminal(w, s.label) end)
    elseif unloaded then
        -- Loading the pullfile jobs starts the RunAtLoad ones; then start this one.
        btn("Load and start", function(w)
            run(w, { "launchctl", "load" }, function(ok)
                if ok then act(w, { "launchctl", "kickstart", s.label }, "started " .. s.label) end
            end)
        end)
    else
        btn("Start", function(w)
            act(w, { "launchctl", "kickstart", s.label }, "started " .. s.label) end)
    end
    if not unloaded then
        -- A pullfile job stays listed (unloaded); an ad-hoc session is gone.
        btn(s.pullfile and "Unload" or "Remove", function(w)
            act(w, { "launchctl", "unload", s.label },
                (s.pullfile and "unloaded " or "removed ") .. s.label)
            if not s.pullfile then st.selected, st.screen = nil, "" end
        end)
    end

    local screen = { "col", id = "screen", scroll = true, grow = true, p = 8, mono = true,
        size = 12, bg = "editor", border = "border", rounded = 4 }
    for line in ((st.screen or "") .. "\n"):gmatch("(.-)\n") do
        screen[#screen + 1] = { "text", line == "" and " " or line }
    end

    local col = { "col", grow = true, gap = 6,
        { "row", gap = 8, align = "center",
            { "text", s.label, bold = true, size = 15, grow = true },
            { "text", s.state, fg = STATE_COLOR[s.state] or "muted" },
        },
        info("running", s.foreground and (s.foreground .. " in " .. (s.foreground_cwd or "?")) or "-"),
        info("program", table.concat(s.argv or {}, " ")),
        info("pid", s.pid or "-"),
        info("runs", (s.runs or 0) .. (s.last_exit and (", last exit " .. s.last_exit) or "")),
        info("attached", s.attached or 0),
        controls,
        screen,
    }
    if running then
        col[#col + 1] = { "row", gap = 6, align = "center",
            { "col", grow = true, { "input", id = "send", placeholder = "type into " .. s.label } },
            { "button", "Run", on_click = function(w)
                local t = w.text("send") or ""
                send(w, t, true)
                w.set_text("send", "")
            end },
            { "button", "Type", on_click = function(w)
                local t = w.text("send") or ""
                if t ~= "" then send(w, t, false); w.set_text("send", "") end
            end },
        }
    end
    return col
end

local function render(w)
    local st = w.state
    if not st.root then st.root = util.find_root() end
    if not st.root then
        return { "col", w = "full", h = "full", p = 14,
            { "text", util.NO_ROOT, fg = "warning" } }
    end
    local now = socket.gettime()
    if now - (st.last_list or 0) > 1.5 then refresh(w) end
    if st.selected and now - (st.last_capture or 0) > 0.7 then capture(w) end

    local list = { "col", id = "list", scroll = true, grow = true, gap = 4 }
    local function group(title, pullfile)
        local rows = {}
        for _, s in ipairs(st.sessions or {}) do
            if (s.pullfile == true) == pullfile then rows[#rows + 1] = session_row(w, s) end
        end
        list[#list + 1] = { "text", title, bold = true, size = 12, fg = "muted" }
        if #rows == 0 then
            list[#list + 1] = { "text", pullfile and "no jobs in the pullfile" or "no sessions",
                fg = "muted", size = 11, px = 6 }
        end
        for _, r in ipairs(rows) do list[#list + 1] = r end
    end
    group("Jobs", true)
    group("Sessions", false)

    local left = { "col", w = 260, gap = 8, p = 8, border = "border",
        list,
        { "input", id = "new_name", placeholder = "new session name" },
        { "input", id = "new_cmd", placeholder = "command (empty: shell)" },
        { "button", "New session", on_click = new_session },
    }

    local sel = selected(st)
    local right = sel and details(w, sel)
        or { "col", grow = true, align = "center", justify = "center",
             { "text", "select a job or session", fg = "muted" } }

    return { "col", w = "full", h = "full",
        { "row", grow = true, gap = 8, p = 8, left, right },
        { "row", px = 10, py = 4,
            { "text", st.message or st.root, size = 12, fg = "muted", grow = true },
            { "text", (st.busy or 0) > 0 and "…" or "", size = 12, fg = "accent" },
        },
    }
end

%ctor
    gpui.register_panel{
        id = "pull-jobs", title = "Jobs", icon = "terminal", position = "bottom", size = 320,
        poll_ms = 300,
        state = { sessions = {}, screen = "" },
        render = function(w)
            local ok, tree = pcall(render, w)
            if ok then return tree end
            return { "text", "ycode-pull jobs: " .. tostring(tree), fg = "error" }
        end,
    }
end

%hook pull
%new - Jobs
    ycode.dispatch("ycode::TogglePanel", { id = "pull-jobs" })
end
%end
