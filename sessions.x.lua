-- ycode-pull sessions: inspect and control the workspace's terminal sessions and jobs.
--
-- Lists `pull session` / launchd jobs with what is running in each (program, directory,
-- pid, last exit), shows the selected session's live screen, and can type into it,
-- send ctrl-c, stop/start/restart it, remove it, open it in a terminal, or start new ones.
-- Open with "pull: sessions" or the Sessions button in the pull window.

local util = require("pullutil")
local q = util.sh_quote
local socket = require("socket")

local function sock_path(root) return root .. "/.pull/launchd.sock" end

local function daemon_running(root)
    local ok = os.execute("test -S " .. q(sock_path(root)))
    return ok == true or ok == 0
end

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

-- ycode.json_decode turns JSON null into a userdata sentinel; make those nil.
local function strip_nulls(t)
    for k, v in pairs(t) do
        if type(v) == "userdata" then t[k] = nil
        elseif type(v) == "table" then strip_nulls(v) end
    end
    return t
end

local function refresh(w)
    local st = w.state
    if st.listing then return end
    st.last_list = socket.gettime()
    if not daemon_running(st.root) then
        st.sessions, st.daemon = {}, false
        return
    end
    st.daemon, st.listing = true, true
    ycode.spawn(util.pull_cmd(st.root, { "session", "ls", "--json" }), function(ok, out)
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
    ycode.spawn("cd " .. q(st.root) .. " && setsid -f ghostty --working-directory=" .. q(st.root)
        .. " -e pull session attach " .. q(name) .. " >/dev/null 2>&1", function() end)
    st.message = "opened " .. name .. " in ghostty (detach with ctrl-\\)"
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
    waiting = "accent", loaded = "muted" }

local function session_row(w, s)
    local st = w.state
    local is_sel = s.label == st.selected
    local what = s.foreground and (s.foreground .. " in " .. (s.foreground_cwd or "?"))
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
    else
        btn("Start", function(w)
            act(w, { "launchctl", "kickstart", s.label }, "started " .. s.label) end)
    end
    btn("Remove", function(w)
        act(w, { "session", "kill", s.label }, "removed " .. s.label)
        st.selected, st.screen = nil, ""
    end)

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
    local now = socket.gettime()
    if now - (st.last_list or 0) > 1.5 then refresh(w) end
    if st.selected and now - (st.last_capture or 0) > 0.7 then capture(w) end

    local list = { "col", id = "list", scroll = true, grow = true, gap = 4 }
    for _, s in ipairs(st.sessions or {}) do list[#list + 1] = session_row(w, s) end
    if #list == 0 then
        list[#list + 1] = { "text", st.daemon == false and "no sessions (daemon not running)"
            or "no sessions", fg = "muted", size = 12 }
    end

    local left = { "col", w = 250, gap = 8, p = 8, bg = "panel", border = "border",
        { "text", "Sessions", bold = true, size = 15 },
        list,
        { "input", id = "new_name", placeholder = "new session name" },
        { "input", id = "new_cmd", placeholder = "command (empty: shell)" },
        { "button", "New session", on_click = new_session },
    }

    local sel = selected(st)
    local right = sel and details(w, sel)
        or { "col", grow = true, align = "center", justify = "center",
             { "text", "select a session", fg = "muted" } }

    return { "col", w = "full", h = "full",
        { "row", grow = true, gap = 8, p = 8, left, right },
        { "row", px = 10, py = 4, bg = "panel",
            { "text", st.message or st.root, size = 12, fg = "muted", grow = true },
            { "text", (st.busy or 0) > 0 and "…" or "", size = 12, fg = "accent" },
        },
    }
end

%hook pull
%new - Sessions
    gpui.open_window{
        title = "pull sessions",
        width = 900, height = 600,
        poll_ms = 300,
        state = { root = util.find_root(), sessions = {}, screen = "" },
        render = function(w)
            local ok, tree = pcall(render, w)
            if ok then return tree end
            return { "text", "ycode-pull sessions: " .. tostring(tree), fg = "error" }
        end,
    }
end
%end
