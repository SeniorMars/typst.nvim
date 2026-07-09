local controller = require("typst.preview.controller")
local capabilities = require("typst.preview.capabilities")
local delegated_runtime = require("typst.preview.backends.delegated_runtime")
local location = require("typst.preview.location")
local source_sync = require("typst.preview.source_sync")
local state = require("typst.preview.state_machine")

assert(
    require("typst.integrations.typst_preview") == controller,
    "typst_preview integration compatibility facade should delegate to controller"
)

for _, removed in ipairs({
    "typst.integrations.typst_preview.runtime",
    "typst.integrations.typst_preview.capabilities",
    "typst.integrations.typst_preview.location",
    "typst.integrations.typst_preview.state",
    "typst.integrations.typst_preview.source_sync",
}) do
    assert(
        not pcall(require, removed),
        removed .. " should not remain as a one-line compatibility alias"
    )
end

for _, name in ipairs({
    "available",
    "command_available",
    "open",
    "stop",
    "stop_for_exit",
    "clear_state",
    "refresh",
    "toggle",
    "forward",
    "inverse",
    "capabilities",
    "status",
    "own_command_definition",
    "own_stop_command_definition",
    "own_toggle_command_definition",
    "own_inverse_command_definition",
}) do
    assert(
        controller[name] ~= nil,
        ("preview controller should expose %s"):format(name)
    )
end

for _, name in ipairs({ "forward", "inverse", "capabilities" }) do
    assert(
        type(source_sync[name]) == "function",
        ("preview.source_sync should expose %s"):format(name)
    )
end

assert(
    type(delegated_runtime.available) == "function",
    "delegated runtime should live under preview.backends"
)
assert(
    type(capabilities.base) == "function",
    "preview capabilities helper should live under preview/"
)
assert(
    type(location.current_position) == "function",
    "preview location helper should live under preview/"
)
assert(
    type(state.to_active_callback) == "function",
    "preview state machine should live under preview/"
)
