local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local function q(value)
    return string.format("%q", value)
end

local function write_script(path, body)
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
    vim.fn.writefile(vim.split(body, "\n", { plain = true }), path)
end

local nvim = vim.v.progpath ~= "" and vim.v.progpath or vim.fn.exepath("nvim")
local base = typst_test_cache_path("output-lock-cross-process")
local output = base .. "/main.pdf"
local holder_script = base .. "/holder.lua"
local contender_script = base .. "/contender.lua"
local ready_path = base .. "/holder-ready.json"
local release_path = base .. "/release"
local result_path = base .. "/contender-result.json"

vim.fn.delete(base, "rf")
vim.fn.mkdir(base, "p")

write_script(
    holder_script,
    ([[
local root = %s
vim.opt.runtimepath:prepend(root)
local outputs = require("typst.resources.outputs")
outputs.reset()
local lease, err = outputs.acquire(%s, {
  kind = "cross-process-holder",
  token = "holder",
})
if not lease then
  vim.fn.writefile({ vim.json.encode({ ok = false, error = err }) }, %s)
  vim.cmd("cquit")
end
vim.fn.writefile({
  vim.json.encode({
    ok = true,
    lock_path = lease.lock_path,
    pid = vim.uv.os_getpid(),
  }),
}, %s)
vim.wait(10000, function()
  return vim.fn.filereadable(%s) == 1
end, 20)
outputs.release(lease)
vim.cmd("qa!")
]]):format(
        q(root),
        q(output),
        q(ready_path),
        q(ready_path),
        q(release_path)
    )
)

write_script(
    contender_script,
    ([[
local root = %s
vim.opt.runtimepath:prepend(root)
local outputs = require("typst.resources.outputs")
local lease, err = outputs.acquire(%s, {
  kind = "cross-process-contender",
  token = "contender",
})
if lease then
  outputs.release(lease)
  vim.fn.writefile({ vim.json.encode({ ok = true }) }, %s)
else
  err = err or { ok = false, reason = "unknown" }
  err.ok = false
  vim.fn.writefile({ vim.json.encode(err) }, %s)
end
vim.cmd("qa!")
]]):format(q(root), q(output), q(result_path), q(result_path))
)

local holder = vim.system({
    nvim,
    "--headless",
    "-n",
    "-u",
    "tests/minimal_init.lua",
    "-l",
    holder_script,
}, { text = true })

assert(
    vim.wait(10000, function()
        return vim.fn.filereadable(ready_path) == 1
    end, 20),
    "holder process did not acquire output lock"
)

local ready = vim.json.decode(table.concat(vim.fn.readfile(ready_path), "\n"))
assert(
    ready.ok,
    "holder process failed to acquire output lock: " .. vim.inspect(ready.error)
)

local contender = vim.system({
    nvim,
    "--headless",
    "-n",
    "-u",
    "tests/minimal_init.lua",
    "-l",
    contender_script,
}, { text = true }):wait(10000)

vim.fn.writefile({ "release" }, release_path)
local holder_result = holder:wait(10000)

assert(
    contender.code == 0,
    "contender process failed: " .. (contender.stderr or contender.stdout or "")
)
assert(
    holder_result.code == 0,
    "holder process failed: "
        .. (holder_result.stderr or holder_result.stdout or "")
)
assert(
    vim.fn.filereadable(result_path) == 1,
    "contender process did not write lock result"
)

local result = vim.json.decode(table.concat(vim.fn.readfile(result_path), "\n"))
assert(
    result.ok == false and result.reason == "active_output",
    "second process should be blocked by active output lock: "
        .. vim.inspect(result)
)
assert(
    result.active_output == output,
    "lock error should report existing active output path"
)
assert(
    result.external_lock == true,
    "lock error should identify cross-process ownership"
)
assert(
    result.owner and result.owner.kind == "cross-process-holder",
    "lock error should expose existing owner metadata"
)

vim.cmd("qa!")
