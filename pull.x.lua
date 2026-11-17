-- ycode-pull: the `pull` multi-repo workflow inside ycode.
--
-- Open with ["ycode::Run", { "name": "pull::Open" }] (keymap) or ycode.dispatch("pull::Open").
-- Commands run in the background (`pull` must be on PATH); output streams into the window.

local util = require("pullutil")
local find_root, sh_quote = util.find_root, util.sh_quote

local function read_all(path)
    local f = io.open(path)
    if not f then return nil end
    local s = f:read("a")
    f:close()
    return s
end

-- Start `pull <args>` in the background; output and exit code go to temp files.
local function start(w, args)
    local st = w.state
    if st.job then return end
    local root = w.text("root")
    if not root or root:match("^%s*$") then root = st.root end
    local out, code = os.tmpname(), os.tmpname()
    os.remove(code)
    local argv = {}
    for i, a in ipairs(args) do argv[i] = sh_quote(a) end
    local cmd = string.format("(cd %s && pull %s) >%s 2>&1; echo $? >%s",
        sh_quote(root), table.concat(argv, " "), out, code)
    os.execute("sh -c " .. sh_quote(cmd) .. " &")
    st.job = { label = "pull " .. table.concat(args, " "), out = out, code = code }
    st.output = ""
    st.status_line = "running " .. st.job.label .. " …"
end

-- Called every frame: pick up output of the running job.
local function poll(w)
    local st, job = w.state, w.state.job
    if not job then return end
    st.output = read_all(job.out) or ""
    local code = read_all(job.code)
    if code then
        code = tonumber(code) or -1
        st.status_line = string.format("%s → %s", job.label, code == 0 and "ok" or ("exit " .. code))
        st.ok = code == 0
        os.remove(job.out); os.remove(job.code)
        st.job = nil
        if job.after then job.after(w, code) end
        w.scroll_bottom("out")
    end
end

local function commit(w)
    local msg = w.text("msg") or ""
    if msg:match("^%s*$") then
        w.state.status_line = "commit message is empty"
        return
    end
    local args = { "commit", "-m", msg }
    if w.state.all then table.insert(args, 3, "-a") end
    start(w, args)
    w.state.job.after = function(w, code)
        if code == 0 then w.set_text("msg", "") end
    end
end

local function worktree_add(w)
    local name = w.text("wt") or ""
    if name:match("^%s*$") then return end
    start(w, { "worktree", "add", name })
    w.state.job.after = function(w, code)
        if code == 0 then w.set_text("wt", "") end
    end
end

local function button(label, f, disabled)
    return { "button", label, on_click = not disabled and f or nil,
             fg = disabled and "muted" or nil }
end

local function render(w)
    poll(w)
    local st = w.state
    local busy = st.job ~= nil
    local msg = w.text("msg") or ""
    local over = #msg > 40

    local out = { "col", id = "out", scroll = true, grow = true, p = 10, mono = true, size = 12,
                  bg = "editor" }
    for line in (st.output .. "\n"):gmatch("(.-)\n") do
        local fg
        if line:match("^pull:") or line:match("^lint:") then fg = "error"
        elseif line:match("^%[") then fg = "muted"
        elseif line:match("^  ") then fg = "accent" end
        out[#out + 1] = { "text", line, fg = fg }
    end

    return { "col", w = "full", h = "full",
        { "col", p = 8, gap = 6, bg = "panel", border = "border",
            { "row", gap = 6, align = "center",
                { "text", "root", fg = "muted", w = 40 },
                { "col", grow = true, { "input", id = "root", placeholder = st.root } },
            },
            { "row", gap = 6,
                button("Status", function(w) start(w, { "status" }) end, busy),
                button("Sync", function(w) start(w, { "sync" }) end, busy),
                button("Update", function(w) start(w, { "update" }) end, busy),
                button("Push", function(w) start(w, { "push" }) end, busy),
                button("Worktrees", function(w) start(w, { "worktree", "list" }) end, busy),
                button("Env", function(w) start(w, { "env" }) end, busy),
                button("Sessions", function() ycode.dispatch("pull::Sessions") end),
            },
            { "row", gap = 6, align = "center",
                { "col", grow = true, { "input", id = "msg", placeholder = "commit message (ctrl-enter)" } },
                { "text", #msg .. "/40", fg = over and "error" or "muted", size = 12, w = 44 },
                button(st.all and "[x] -a" or "[ ] -a", function(w) w.state.all = not w.state.all end),
                button("Commit", commit, busy),
            },
            { "row", gap = 6, align = "center",
                { "col", grow = true, { "input", id = "wt", placeholder = "new worktree name" } },
                button("Add worktree", worktree_add, busy),
            },
        },
        out,
        { "row", px = 10, py = 4, bg = "panel",
            { "text", st.status_line, size = 12,
              fg = busy and "accent" or (st.ok == false and "error" or "muted") },
        },
    }
end

local function on_key(w, ev)
    if ev.ctrl and ev.key == "enter" then
        if not w.state.job then commit(w) end
        return true
    end
end

%hook pull
%new - Open
    local root = find_root()
    gpui.open_window{
        title = "pull — " .. root,
        width = 760, height = 560,
        focus = "msg",
        poll_ms = 250,
        state = { root = root, output = "", status_line = "ready", all = true },
        on_key = on_key,
        render = function(w)
            local ok, tree = pcall(render, w)
            if ok then return tree end
            return { "text", "ycode-pull: " .. tostring(tree), fg = "error" }
        end,
    }
end
%end
