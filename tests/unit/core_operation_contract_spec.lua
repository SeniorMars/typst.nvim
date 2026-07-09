local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local operation = require("typst.core.operation")
local log = require("typst.core.log")
local result = require("typst.core.result")

operation.reset({ scope = "all", force = true, clear_retained = true })

local function assert_eq(actual, expected, message)
    assert(actual == expected, message .. " (got " .. vim.inspect(actual) .. ")")
end

local ok, err = xpcall(function()
    local pending_result = result.pending("unit", { owner = "project" })
    assert_eq(pending_result.ok, false, "pending results should not be ok")
    assert_eq(pending_result.pending, true, "pending results should be live")
    assert_eq(pending_result.kind, "unit", "pending result should carry kind")

    local stale_result = result.stale("stale_unit", { generation = 7 })
    assert_eq(stale_result.ok, false, "stale results should not be ok")
    assert_eq(stale_result.pending, false, "stale results should be terminal")
    assert_eq(stale_result.stale, true, "stale results should be marked")
    assert_eq(stale_result.generation, 7, "stale results should keep fields")

    local retained_result = result.retained({ kind = "compiler.compile" })
    assert_eq(retained_result.pending, false, "retained orphans should settle")
    assert_eq(retained_result.stopped, false, "retained orphans are not stopped")
    assert_eq(retained_result.orphaned, true, "retained implies orphaned")
    assert_eq(retained_result.retained, true, "retained should be explicit")

    local live_orphan = result.orphaned({ kind = "compiler.watch" })
    assert_eq(live_orphan.pending, true, "live orphans are still pending")
    assert_eq(live_orphan.stopped, false, "live orphans are not stopped")

    local settle_op = operation.new("contract-settle", {
        owner = "project",
        project_key = "project-a",
        slot = "compiler",
    })
    assert(
        operation.by_id(settle_op.id) == settle_op,
        "operations should be findable by id"
    )
    assert(
        operation.by_slot("project", "project-a", "compiler") == settle_op,
        "active slots should resolve to their operation"
    )
    assert(
        operation.by_slot({
            owner = "project",
            project_key = "project-a",
            slot = "compiler",
        }) == settle_op,
        "option-table slot lookup should be supported"
    )

    local settled = nil
    local finished = nil
    settle_op:on_settle(function(done, op)
        settled = { result = done, operation = op }
    end)
    settle_op:on_finish(function(op)
        finished = op
    end)
    settle_op:finish(result.ok({ stdout = "done", stderr = "" }))
    assert(
        settled
            and settled.result == settle_op.result
            and settled.operation == settle_op,
        "normal finish should settle with the terminal result"
    )
    assert(finished == settle_op, "normal finish should run finish callbacks")
    assert(
        operation.by_slot("project", "project-a", "compiler") == nil,
        "finished operations should release their slot"
    )

    local late_settle = nil
    settle_op:on_settle(function(done, op)
        late_settle = { result = done, operation = op }
    end)
    assert(
        late_settle and late_settle.operation == settle_op,
        "late settle subscribers should run immediately"
    )

    local orphan_cleaned = false
    local orphan_finish = false
    local orphan_settle = nil
    local orphan = operation.new("contract-retained", {
        owner = "project",
        project_key = "project-a",
        slot = "preview",
        cleanup = function()
            orphan_cleaned = true
        end,
    })
    orphan:on_settle(function(done, op)
        orphan_settle = { result = done, operation = op }
    end)
    orphan:on_finish(function()
        orphan_finish = true
    end)
    orphan:_retain_orphan(result.retained({ reason = "orphaned" }))
    assert(
        orphan_settle
            and orphan_settle.operation == orphan
            and orphan_settle.result.retained == true,
        "retained orphans should settle without finishing"
    )
    assert_eq(orphan_finish, false, "retained orphans should not finish yet")
    assert_eq(orphan_cleaned, false, "retained orphans should not clean up")
    assert(
        operation.by_slot("project", "project-a", "preview") == nil,
        "retained orphans should release their slot"
    )
    orphan:finish({ code = 1, stderr = "late", stopped = false })
    assert_eq(orphan_finish, true, "late orphan exit should finish")
    assert_eq(orphan_cleaned, true, "late orphan exit should clean up")

    local cleanup_order = {}
    local cleanup_op = operation.new("contract-cleanup-before-settle", {
        cleanup = function()
            cleanup_order[#cleanup_order + 1] = "cleanup"
        end,
    })
    cleanup_op:on_finish(function()
        cleanup_order[#cleanup_order + 1] = "finish"
    end)
    cleanup_op:on_settle(function()
        cleanup_order[#cleanup_order + 1] = "settle"
    end)
    cleanup_op:finish(result.ok())
    assert_eq(
        cleanup_order[1],
        "cleanup",
        "normal finish should run cleanup before settle"
    )
    assert_eq(
        cleanup_order[2],
        "settle",
        "normal finish should settle after cleanup"
    )
    assert_eq(
        cleanup_order[3],
        "finish",
        "normal finish should run finish callbacks after settle"
    )

    local cancel_cleanup_order = {}
    local cancel_cleanup_op =
        operation.new("contract-cancel-callback-after-cleanup", {
            cleanup = function()
                cancel_cleanup_order[#cancel_cleanup_order + 1] = "cleanup"
            end,
        })
    cancel_cleanup_op._cancel_callbacks[#cancel_cleanup_op._cancel_callbacks + 1] =
        function()
            cancel_cleanup_order[#cancel_cleanup_order + 1] = "cancel"
        end
    cancel_cleanup_op:finish(result.stopped())
    assert_eq(
        cancel_cleanup_order[1],
        "cleanup",
        "normal finish should clean up before cancel callbacks"
    )
    assert_eq(
        cancel_cleanup_order[2],
        "cancel",
        "normal finish should drain cancel callbacks after cleanup"
    )

    local snapshot_op = operation.new("contract-snapshot", {
        owner = "project",
        project_key = "project-a",
        slot = "index",
        generation = 12,
    })
    local snapshot = operation.snapshot({
        scope = "project",
        project_key = "project-a",
    })
    assert_eq(snapshot.active, 1, "snapshot should include active project op")
    assert_eq(snapshot.records[1].slot, "index", "snapshot should expose slot")
    assert_eq(
        snapshot.records[1].generation,
        12,
        "snapshot should expose generation"
    )
    snapshot_op:finish(result.ok())

    log.clear()
    local first_slot = operation.new("contract-slot-first", {
        owner = "project",
        project_key = "project-a",
        slot = "compiler",
    })
    local second_slot = operation.new("contract-slot-second", {
        owner = "project",
        project_key = "project-a",
        slot = "compiler",
    })
    assert(
        operation.by_slot("project", "project-a", "compiler") == first_slot,
        "slot collision should keep the first discoverable owner"
    )
    assert(
        second_slot.slot_collision == true,
        "slot collision should be visible on the colliding operation"
    )
    assert_eq(
        second_slot.reason,
        "slot_collision",
        "slot collision should reject the second operation"
    )
    assert_eq(
        second_slot.pending,
        false,
        "rejected slot collision should not remain pending"
    )
    local collision_snapshot = operation.snapshot({
        scope = "project",
        project_key = "project-a",
    })
    assert_eq(
        collision_snapshot.active,
        1,
        "slot collision should not leave a hidden active operation"
    )
    local collision_logged = false
    for _, entry in ipairs(log.entries()) do
        if entry.message == "operation slot collision" then
            collision_logged = true
            break
        end
    end
    assert(collision_logged, "slot collision should be logged")
    first_slot:finish(result.ok())
    assert(
        operation.by_slot("project", "project-a", "compiler") == nil,
        "slot should clear once the original owner finishes"
    )
end, debug.traceback)

operation.reset({ scope = "all", force = true, clear_retained = true })

if not ok then
    error(err)
end

vim.cmd("qa!")
