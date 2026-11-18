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
-- Returns the job (to attach an `after` callback), or nil if nothing was started.
local function start(w, args)
    local st = w.state
    if st.job then return nil end
    local root = w.text("root")
    if not root or root:match("^%s*$") then root = st.root end
    if not root then
        st.status_line, st.ok = util.NO_ROOT, false
        return nil
    end
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
    return st.job
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
    local job = start(w, args)
    if not job then return end
    job.after = function(w, code)
        if code == 0 then w.set_text("msg", "") end
    end
end

local function worktree_add(w)
    local name = w.text("wt") or ""
    if name:match("^%s*$") then return end
    local job = start(w, { "worktree", "add", name })
    if not job then return end
    job.after = function(w, code)
        if code == 0 then w.set_text("wt", "") end
    end
end

local function button(label, f, disabled, style)
    return { "button", label, style = style, disabled = disabled, on_click = f }
end

local function render(w)
    poll(w)
    local st = w.state
    local busy = st.job ~= nil
    local msg = w.text("msg") or ""
    -- The subject limit comes from the pullfile's lint rules (loaded on open).
    local max = st.max_subject
    local over = max ~= nil and #msg > max

    local out = { "col", id = "out", scroll = true, grow = true, p = "md", bg = "editor" }
    for line in (st.output .. "\n"):gmatch("(.-)\n") do
        local color
        if line:match("^pull:") or line:match("^lint:") then color = "error"
        elseif line:match("^%[") then color = "muted"
        elseif line:match("^  ") then color = "accent" end
        out[#out + 1] = { "text", line == "" and " " or line, mono = true, size = "small", color = color }
    end

    return { "panel", scroll = false,
        footer = st.status_line, color = busy and "accent" or (st.ok == false and "error" or nil),
        { "col", gap = "sm", py = "sm",
            { "row", gap = "sm", px = "md",
                { "text", "Root", size = "small", color = "muted" },
                { "input", id = "root", grow = true, placeholder = st.root or "path to a pull workspace" } },
            { "toolbar",
                button("Status", function(w) start(w, { "status" }) end, busy),
                button("Sync", function(w) start(w, { "sync" }) end, busy),
                button("Update", function(w) start(w, { "update" }) end, busy),
                button("Push", function(w) start(w, { "push" }) end, busy),
                button("Worktrees", function(w) start(w, { "worktree", "list" }) end, busy),
                button("Env", function(w) start(w, { "env" }) end, busy),
                button("Jobs", function() ycode.dispatch("pull::Jobs") end) },
            { "row", gap = "sm", px = "md",
                { "input", id = "msg", grow = true, placeholder = "commit message (ctrl-enter)" },
                { "text", max and (#msg .. "/" .. max) or tostring(#msg), size = "small",
                  color = over and "error" or "muted" },
                { "checkbox", label = "-a", checked = st.all == true,
                  on_click = function(w) w.state.all = not w.state.all end },
                button("Commit", commit, busy, "filled") },
            { "row", gap = "sm", px = "md",
                { "input", id = "wt", grow = true, placeholder = "new worktree name" },
                button("Add worktree", worktree_add, busy) },
        },
        { "divider" },
        out,
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
    local state = { root = root, output = "", all = true,
                    status_line = root and "ready" or util.NO_ROOT }
    if root then
        ycode.spawn(util.pull_cmd(root, { "status", "--json" }), function(ok, out)
            local okj, data = pcall(ycode.json_decode, ok and out or "")
            if okj and type(data) == "table" then
                local lint = util.strip_nulls(data).lint or {}
                state.max_subject = lint.max_subject_length
            end
        end)
    end
    gpui.open_window{
        title = root and ("pull — " .. root) or "pull",
        width = 760, height = 560,
        focus = "msg",
        poll_ms = 250,
        state = state,
        on_key = on_key,
        render = function(w)
            local ok, tree = pcall(render, w)
            if ok then return tree end
            return { "empty", "ycode-pull: " .. tostring(tree), color = "error" }
        end,
    }
end
%end
