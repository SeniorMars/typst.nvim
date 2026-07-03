local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local project = require("typst.project")
local compiler_service = require("typst.project.services.compiler")
local project_store = require("typst.project.store")
local typst = require("typst")

typst.reset({ force = true })
typst.setup({
    root_markers = {},
    project = {
        import_scan = false,
    },
})

local fixture_root = typst_test_cache_path("project-public-snapshot")
vim.fn.delete(fixture_root, "rf")
vim.fn.mkdir(fixture_root, "p")
local main = fixture_root .. "/main.typ"
vim.fn.writefile({ "= Main" }, main)
vim.cmd.edit(vim.fn.fnameescape(main))
vim.bo.filetype = "typst"

local bufnr = vim.api.nvim_get_current_buf()
local live = assert(project.resolve(bufnr))
compiler_service.set(live, {
    status = "live-status",
    last_command = { "typst", "compile", main },
    last_result = {
        ok = true,
        nested = {
            value = "live-result",
        },
    },
})
live.resolutions = live.resolutions or {}
live.resolutions[bufnr] =
    vim.tbl_extend("force", live.resolutions[bufnr] or {}, {
        main = main,
        nested = {
            value = "live-resolution",
        },
    })

local function mutate_snapshot(snapshot, label)
    assert(type(snapshot) == "table", label .. " snapshot should be a table")
    assert(
        snapshot.mutable == false,
        label .. " should return a public snapshot"
    )

    snapshot.key = "mutated-" .. label
    snapshot.status = "mutated-" .. label

    if type(snapshot.bufs) == "table" then
        snapshot.bufs[bufnr] = false
        snapshot.bufs[999] = true
    end

    if
        type(snapshot.resolutions) == "table"
        and type(snapshot.resolutions[bufnr]) == "table"
    then
        snapshot.resolutions[bufnr].main = "mutated-" .. label
        if type(snapshot.resolutions[bufnr].nested) == "table" then
            snapshot.resolutions[bufnr].nested.value = "mutated-" .. label
        end
    end

    if type(snapshot.last_command) == "table" then
        snapshot.last_command[1] = "mutated-" .. label
    end

    if type(snapshot.last_result) == "table" then
        snapshot.last_result.nested = snapshot.last_result.nested or {}
        snapshot.last_result.nested.value = "mutated-" .. label
    end

    if
        type(snapshot.services) == "table"
        and type(snapshot.services.compiler) == "table"
    then
        snapshot.services.compiler.status = "mutated-" .. label
    end
end

local function assert_live_unchanged(label, key)
    local still_live = assert(project_store.get(key or live.key), label)
    assert(
        still_live.key == live.key,
        label .. ": key mutation reached live state"
    )
    assert(
        still_live.bufs[999] == nil,
        label .. ": new buffer reached live state"
    )
    assert(
        still_live.bufs[bufnr] == true,
        label .. ": buffer membership mutation reached live state"
    )
    assert(
        still_live.services.compiler.status == "live-status",
        label .. ": compiler status mutation reached live state"
    )
    assert(
        still_live.services.compiler.last_command[1] == "typst",
        label .. ": compiler command mutation reached live state"
    )
    assert(
        still_live.services.compiler.last_result.nested.value == "live-result",
        label .. ": compiler result mutation reached live state"
    )
    assert(
        still_live.resolutions[bufnr].main == main
            and still_live.resolutions[bufnr].nested.value
                == "live-resolution",
        label .. ": resolution mutation reached live state"
    )
end

local function capture_live_state(key)
    local state = project_store.get(key)
    if not state then
        return nil
    end
    local compiler = state.services and state.services.compiler or {}
    local resolution = state.resolutions and state.resolutions[bufnr] or {}
    return {
        key = state.key,
        buf_member = state.bufs and state.bufs[bufnr],
        extra_buf_member = state.bufs and state.bufs[999],
        compiler_status = compiler.status,
        last_command_head = type(compiler.last_command) == "table"
                and compiler.last_command[1]
            or nil,
        last_result_nested = type(compiler.last_result) == "table" and type(
            compiler.last_result.nested
        ) == "table" and compiler.last_result.nested.value or nil,
        resolution_main = resolution.main,
        resolution_nested = type(resolution.nested) == "table"
                and resolution.nested.value
            or nil,
    }
end

local function assert_live_matches(label, baseline)
    local state = assert(project_store.get(baseline.key), label)
    local compiler = state.services and state.services.compiler or {}
    local resolution = state.resolutions and state.resolutions[bufnr] or {}
    assert(state.key == baseline.key, label .. ": key changed")
    assert(
        (state.bufs and state.bufs[bufnr]) == baseline.buf_member,
        label .. ": buffer membership changed"
    )
    assert(
        (state.bufs and state.bufs[999]) == baseline.extra_buf_member,
        label .. ": unexpected buffer membership was added"
    )
    assert(
        compiler.status == baseline.compiler_status,
        label .. ": compiler status changed"
    )
    if baseline.last_command_head ~= nil then
        assert(
            type(compiler.last_command) == "table"
                and compiler.last_command[1] == baseline.last_command_head,
            label .. ": compiler command changed"
        )
    end
    if baseline.last_result_nested ~= nil then
        assert(
            type(compiler.last_result) == "table"
                and type(compiler.last_result.nested) == "table"
                and compiler.last_result.nested.value
                    == baseline.last_result_nested,
            label .. ": compiler result changed"
        )
    end
    if baseline.resolution_main ~= nil then
        assert(
            resolution.main == baseline.resolution_main,
            label .. ": resolution main changed"
        )
    end
    if baseline.resolution_nested ~= nil then
        assert(
            type(resolution.nested) == "table"
                and resolution.nested.value == baseline.resolution_nested,
            label .. ": resolution nested state changed"
        )
    end
end

local function mutate_snapshot_and_assert_live(snapshot, label)
    local baseline = assert(
        capture_live_state(snapshot.key),
        label .. " live project missing"
    )
    mutate_snapshot(snapshot, label)
    assert_live_matches(label, baseline)
end

local snapshots = project.all()
local snapshot = assert(snapshots[live.key], "public project list missing key")

snapshot.key = "mutated"
snapshot.bufs[bufnr] = false
snapshot.bufs = { [999] = true }
snapshot.status = "mutated"
snapshot.resolutions[bufnr].main = "mutated"
snapshot.resolutions[bufnr].nested.value = "mutated"
snapshot.last_command[1] = "mutated"
snapshot.last_result.nested.value = "mutated"
snapshot.services.compiler.status = "mutated"
snapshot.last_result = { ok = false, reason = "mutated" }

local still_live = assert(project_store.get(live.key))
assert(still_live.key == live.key, "snapshot key mutation reached live state")
assert(
    still_live.bufs[999] == nil,
    "snapshot buffer mutation reached live state"
)
assert(
    still_live.bufs[bufnr] == true,
    "nested snapshot buffer mutation reached live state"
)
assert(
    (still_live.services.compiler or {}).status ~= "mutated",
    "snapshot compiler status mutation reached live state"
)
assert(
    still_live.services.compiler.status == "live-status",
    "nested service snapshot mutation reached live compiler state"
)
assert(
    still_live.services.compiler.last_command[1] == "typst",
    "nested last_command snapshot mutation reached live compiler state"
)
assert(
    still_live.services.compiler.last_result.nested.value == "live-result",
    "nested last_result snapshot mutation reached live compiler state"
)
assert(
    still_live.resolutions[bufnr].main == main
        and still_live.resolutions[bufnr].nested.value == "live-resolution",
    "nested resolution snapshot mutation reached live project state"
)

local public_get = assert(
    typst.project.get(bufnr),
    "public project.get should return a snapshot"
)
public_get.key = "mutated-get"
public_get.bufs[bufnr] = false
public_get.resolutions[bufnr].main = "mutated-get"
public_get.resolutions[bufnr].nested.value = "mutated-get"
public_get.services.compiler.status = "mutated-get"
public_get.last_result.nested.value = "mutated-get"

local after_get = assert(project_store.get(live.key))
assert(after_get.key == live.key, "project.get key mutation reached live state")
assert(
    after_get.bufs[bufnr] == true,
    "project.get buffer mutation reached live state"
)
assert(
    after_get.services.compiler.status == "live-status",
    "project.get service mutation reached live state"
)
assert(
    after_get.services.compiler.last_result.nested.value == "live-result",
    "project.get result mutation reached live state"
)
assert(
    after_get.resolutions[bufnr].main == main
        and after_get.resolutions[bufnr].nested.value == "live-resolution",
    "project.get resolution mutation reached live state"
)

local first = assert(project.all()[live.key], "first snapshot missing key")
local second = assert(project.all()[live.key], "second snapshot missing key")
first.resolutions[bufnr].main = "mutated-reused-snapshot"
assert(
    second.resolutions[bufnr].main == main,
    "project.all snapshots should not reuse nested tables across calls"
)

local public_snapshot = assert(
    typst.project.snapshot(bufnr, { runtime = true }),
    "public project.snapshot should return a snapshot"
)
assert(
    public_snapshot.process == nil
        and public_snapshot.watcher == nil
        and public_snapshot.stopping_compile == nil,
    "public project.snapshot should not expose runtime handles"
)
mutate_snapshot_and_assert_live(public_snapshot, "project.snapshot")

local public_attach = assert(
    typst.project.attach(bufnr),
    "public project.attach should return a snapshot"
)
mutate_snapshot_and_assert_live(public_attach, "project.attach")

local public_set_main = assert(
    typst.project.set_main(main, bufnr, { force = true }),
    "public project.set_main should return a snapshot"
)
mutate_snapshot_and_assert_live(public_set_main, "project.set_main")

local public_toggle = assert(
    typst.project.toggle_main({ bufnr = bufnr, notify = false }),
    "public project.toggle_main should return a result"
)
mutate_snapshot_and_assert_live(
    assert(public_toggle.state, "toggle_main should include project state"),
    "project.toggle_main"
)

local public_reload = assert(
    typst.project.reload_state({ bufnr = bufnr, notify = false }),
    "public project.reload_state should return a snapshot"
)
mutate_snapshot_and_assert_live(public_reload, "project.reload_state")

local public_detach = assert(
    typst.project.detach(bufnr),
    "public project.detach should return a snapshot"
)
local detach_key = public_detach.key
local detach_baseline = capture_live_state(detach_key)
mutate_snapshot(public_detach, "project.detach")
if detach_baseline then
    assert_live_matches("project.detach", detach_baseline)
else
    assert(
        project_store.get(detach_key) == nil,
        "project.detach snapshot mutation recreated live state"
    )
end

vim.cmd("qa!")
