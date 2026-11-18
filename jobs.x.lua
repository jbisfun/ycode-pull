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
    local what = s.foreground and (s.foreground .. " in " .. (s.foreground_cwd or "?"))
        or (s.state == "unloaded" and table.concat(s.argv or {}, " "))
        or (s.state .. (s.last_exit and (", exit " .. s.last_exit) or ""))
    return { "list_item", s.label, detail = what, selected = s.label == st.selected,
        start = { "icon", name = "circle", size = "xsmall", color = STATE_COLOR[s.state] or "muted" },
        on_click = function(w)
            st.selected, st.screen, st.last_capture = s.label, "", 0
        end }
end

local function controls(w, s)
    local st = w.state
    local out = {}
    local function btn(icon, tooltip, f)
        out[#out + 1] = { "icon_button", icon = icon, tooltip = tooltip, on_click = f }
    end
    if s.state == "running" then
        btn("control", "Send Ctrl-C", function(w) send(w, "\3", false, "sent ctrl-c to " .. s.label) end)
        btn("stop", "Stop", function(w) act(w, { "launchctl", "stop", s.label }, "stopped " .. s.label) end)
        btn("rotate_cw", "Restart", function(w)
            act(w, { "launchctl", "kickstart", "-k", s.label }, "restarting " .. s.label) end)
        btn("terminal", "Open in terminal", function(w) open_terminal(w, s.label) end)
    elseif s.state == "unloaded" then
        -- Loading the pullfile jobs starts the RunAtLoad ones; then start this one.
        btn("play_filled", "Load and start", function(w)
            run(w, { "launchctl", "load" }, function(ok)
                if ok then act(w, { "launchctl", "kickstart", s.label }, "started " .. s.label) end
            end)
        end)
    else
        btn("play_filled", "Start", function(w)
            act(w, { "launchctl", "kickstart", s.label }, "started " .. s.label) end)
    end
    if s.state ~= "unloaded" then
        -- A pullfile job stays listed (unloaded); an ad-hoc session is gone.
        btn(s.pullfile and "power" or "trash", s.pullfile and "Unload" or "Remove", function(w)
            act(w, { "launchctl", "unload", s.label },
                (s.pullfile and "unloaded " or "removed ") .. s.label)
            if not s.pullfile then st.selected, st.screen = nil, "" end
        end)
    end
    return out
end

local function details(w, s)
    local st = w.state
    local program = table.concat(s.argv or {}, " ")
    local facts = { "pid " .. (s.pid or "-"), (s.runs or 0) .. " runs" }
    if s.last_exit then facts[#facts + 1] = "last exit " .. s.last_exit end
    if (s.attached or 0) > 0 then facts[#facts + 1] = s.attached .. " attached" end

    local screen = { "col", id = "screen", scroll = true, grow = true, mono = true, size = "small",
        p = "sm", bg = "editor", border = true, rounded = true }
    for line in ((st.screen or "") .. "\n"):gmatch("(.-)\n") do
        screen[#screen + 1] = { "text", line == "" and " " or line, mono = true, size = "small" }
    end

    local body = { "col", grow = true, gap = "sm", px = "md", py = "sm",
        { "text", s.foreground and (s.foreground .. " in " .. (s.foreground_cwd or "?")) or program,
          size = "small", mono = true, color = "muted", truncate = true },
        { "text", table.concat(facts, " · "), size = "small", color = "muted" },
        screen,
    }
    if s.state == "running" then
        body[#body + 1] = { "row", gap = "xs",
            { "input", id = "send", placeholder = "type into " .. s.label, grow = true },
            { "icon_button", icon = "return", tooltip = "Run (sends enter)", on_click = function(w)
                send(w, w.text("send") or "", true)
                w.set_text("send", "")
            end },
            { "icon_button", icon = "send", tooltip = "Type (no enter)", on_click = function(w)
                local t = w.text("send") or ""
                if t ~= "" then send(w, t, false); w.set_text("send", "") end
            end },
        }
    end
    return { "panel", scroll = false,
        header = { title = s.label, context = s.state, actions = controls(w, s) },
        body }
end

local function render(w)
    local st = w.state
    if not st.root then st.root = util.find_root() end
    if not st.root then return { "empty", util.NO_ROOT, color = "warning" } end
    local now = socket.gettime()
    if now - (st.last_list or 0) > 1.5 then refresh(w) end
    if st.selected and now - (st.last_capture or 0) > 0.7 then capture(w) end

    local function group(title, pullfile)
        local sec = { "section", title, empty = pullfile and "no jobs in the pullfile" or "no sessions" }
        for _, s in ipairs(st.sessions or {}) do
            if (s.pullfile == true) == pullfile then sec[#sec + 1] = session_row(w, s) end
        end
        return sec
    end

    local sidebar = { "panel", id = "jobs-list",
        footer = { "row", gap = "xs", grow = true,
            { "col", grow = true, gap = "xs",
                { "input", id = "new_name", placeholder = "new session name" },
                { "input", id = "new_cmd", placeholder = "command (empty: shell)" } },
            { "icon_button", icon = "plus", tooltip = "New session", on_click = new_session } },
        group("Jobs", true),
        group("Sessions", false),
    }

    local sel = selected(st)
    local status = (st.busy or 0) > 0 and "working…" or (st.message or st.root)
    return { "panel", scroll = false, footer = status,
        { "split", sidebar, sel and details(w, sel) or { "empty", "select a job or session" } } }
end

%ctor
    gpui.register_panel{
        id = "pull-jobs", title = "Jobs", icon = "terminal", position = "bottom", size = 320,
        poll_ms = 300,
        state = { sessions = {}, screen = "" },
        render = function(w)
            local ok, tree = pcall(render, w)
            if ok then return tree end
            return { "empty", "ycode-pull jobs: " .. tostring(tree), color = "error" }
        end,
    }
end

%hook pull
%new - Jobs
    ycode.dispatch("ycode::TogglePanel", { id = "pull-jobs" })
end
%end
