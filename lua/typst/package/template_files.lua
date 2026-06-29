local package_provider = require("typst.package.cache")
local util = require("typst.core.util")

local M = {}
local uv = vim.uv or vim.loop
local DEFAULT_MAX_FILES = 10000
local DEFAULT_MAX_BYTES = 100 * 1024 * 1024

-- Template initialization copies package-owned files into a user directory.
-- Keep every path checked against a known root and commit through staging plus
-- backup so a failed copy does not leave a half-written project.

function M.cached_record(package)
    local spec = package_provider.parse_spec(package)
    if not spec then
        return nil
    end

    for _, record in
        ipairs(package_provider.cached_packages({
            namespace = spec.namespace,
            name = spec.name,
        }))
    do
        if
            record.is_template
            and record.namespace == spec.namespace
            and record.name == spec.name
            and (not spec.version or record.version == spec.version)
        then
            return record
        end
    end
end

function M.entrypoint(record)
    local template = record and record.template or {}
    local package_root = util.canonical(record.root)
    local template_dir = template.path
            and util.resolve_path(template.path, package_root)
        or package_root
    template_dir = util.canonical(template_dir)
    if not util.path_within(template_dir, package_root) then
        return nil, nil, "template_path_outside_package"
    end

    local entrypoint = template.entrypoint or "main.typ"
    entrypoint = util.canonical(util.resolve_path(entrypoint, template_dir))
    if not util.path_within(entrypoint, template_dir) then
        return nil, template_dir, "template_entrypoint_outside_template"
    end

    return entrypoint, template_dir, nil
end

local function check_contained(path, root, reason)
    path = util.canonical(path)
    root = util.canonical(root)
    if not util.path_within(path, root) then
        error(reason .. ": " .. path)
    end
    return path
end

local function remove_tree(path, root)
    path = util.canonical(path)
    root = util.canonical(root)
    if not path or path == "" or not util.path_within(path, root) then
        return false
    end

    local stat = (uv.fs_lstat and uv.fs_lstat(path)) or uv.fs_stat(path)
    if not stat then
        return true
    end

    if stat.type == "directory" then
        local scan = uv.fs_scandir(path)
        while scan do
            local name = uv.fs_scandir_next(scan)
            if not name then
                break
            end
            remove_tree(util.join(path, name), root)
        end
        return uv.fs_rmdir(path)
    end

    return uv.fs_unlink(path)
end

function M.copy_dir(source, destination, opts)
    opts = opts or {}
    if
        type(source) ~= "string"
        or type(destination) ~= "string"
        or destination == ""
    then
        return {
            ok = false,
            reason = "invalid_destination",
        }
    end

    source = util.canonical(source)
    destination = util.canonical(destination)
    local source_root = opts.source_root and util.canonical(opts.source_root)
        or source
    if vim.fn.isdirectory(source) ~= 1 then
        return {
            ok = false,
            reason = "missing_template",
            source = source,
        }
    end
    if not util.path_within(source, source_root) then
        return {
            ok = false,
            reason = "template_path_outside_package",
            source = source,
            root = source_root,
        }
    end
    if util.same_path(destination, source) then
        return {
            ok = false,
            reason = "destination_is_template",
            source = source,
            destination = destination,
        }
    end
    if util.path_within(destination, source) then
        return {
            ok = false,
            reason = "destination_inside_template",
            source = source,
            destination = destination,
        }
    end
    if uv.fs_stat(destination) and opts.overwrite ~= true then
        return {
            ok = false,
            reason = "destination_exists",
            source = source,
            destination = destination,
        }
    end

    local parent = util.dirname(destination)
    vim.fn.mkdir(parent, "p")
    parent = util.canonical(parent)
    local staging = util.canonical(
        util.join(
            parent,
            (".%s.typst-nvim-staging-%s"):format(
                util.basename(destination),
                tostring(uv.hrtime())
            )
        )
    )
    local backup = nil
    local backup_path = nil
    local backup_restored = nil
    local backup_restore_error = nil
    local destination_root = staging
    if util.path_within(staging, source) then
        return {
            ok = false,
            reason = "staging_inside_template",
            source = source,
            destination = destination,
            staging = staging,
        }
    end

    local copied = 0
    local copied_bytes = 0
    local function copy_dir(src, dst)
        src =
            check_contained(src, source_root, "template source escaped package")
        dst = check_contained(
            dst,
            destination_root,
            "template destination escaped root"
        )
        vim.fn.mkdir(dst, "p")
        local scan = uv.fs_scandir(src)
        if not scan then
            return
        end

        while true do
            local name, kind = uv.fs_scandir_next(scan)
            if not name then
                break
            end

            if name == "." or name == ".." or name:find("[/\\]") then
                error("unsafe template path: " .. name)
            end

            local raw_src_path = util.join(src, name)
            local raw_stat = uv.fs_lstat and uv.fs_lstat(raw_src_path)
                or uv.fs_stat(raw_src_path)
            if not raw_stat then
                error("missing template entry: " .. raw_src_path)
            end
            if raw_stat.type == "link" then
                -- Do not preserve package symlinks into arbitrary destinations;
                -- templates are copied as concrete files/directories only.
                error("template symlink rejected: " .. raw_src_path)
            end
            local src_path = check_contained(
                raw_src_path,
                source_root,
                "template source escaped package"
            )
            local dst_path = check_contained(
                util.join(dst, name),
                destination_root,
                "template destination escaped root"
            )
            local stat = uv.fs_lstat and uv.fs_lstat(src_path)
                or uv.fs_stat(src_path)
            if not stat then
                error("missing template entry: " .. src_path)
            end
            if kind == "directory" then
                if stat.type ~= "directory" then
                    error("unsafe template entry: " .. src_path)
                end
                copy_dir(src_path, dst_path)
            elseif kind == "file" then
                if stat.type ~= "file" then
                    error("unsafe template entry: " .. src_path)
                end
                if copied + 1 > (opts.max_files or DEFAULT_MAX_FILES) then
                    error("template file count limit exceeded")
                end
                copied_bytes = copied_bytes + (stat.size or 0)
                if copied_bytes > (opts.max_bytes or DEFAULT_MAX_BYTES) then
                    error("template byte limit exceeded")
                end
                if
                    opts.overwrite ~= true
                    and vim.fn.filereadable(dst_path) == 1
                then
                    error(("destination exists: %s"):format(dst_path))
                end
                vim.fn.mkdir(util.dirname(dst_path), "p")
                local ok, err = uv.fs_copyfile(src_path, dst_path)
                if not ok then
                    error(err or ("failed to copy " .. src_path))
                end
                copied = copied + 1
            end
        end
    end

    local ok, err = pcall(copy_dir, source, staging)
    if ok then
        ok, err = pcall(function()
            if uv.fs_stat(destination) then
                -- Move an existing destination out of the way before the final
                -- rename so overwrite is recoverable if the last step fails.
                backup = util.canonical(
                    util.join(
                        parent,
                        (".%s.typst-nvim-backup-%s"):format(
                            util.basename(destination),
                            tostring(uv.hrtime())
                        )
                    )
                )
                backup_path = backup
                local renamed, rename_err =
                    util.rename_checked(destination, backup)
                if not renamed then
                    error(
                        rename_err
                            or (
                                "failed to move existing destination "
                                .. destination
                            )
                    )
                end
            end

            local renamed, rename_err =
                util.rename_checked(staging, destination)
            if not renamed then
                if backup then
                    local restored, restore_err =
                        util.rename_checked(backup, destination)
                    backup_restored = restored == true
                    if backup_restored then
                        backup = nil
                    else
                        backup_restore_error = restore_err
                            or "failed to restore backup"
                    end
                end
                error(
                    rename_err
                        or ("failed to move template into " .. destination)
                )
            end
        end)
    end
    if not ok then
        remove_tree(staging, staging)
        if backup then
            local restored, restore_err =
                util.rename_checked(backup, destination)
            backup_restored = restored == true
            if backup_restored then
                backup = nil
            else
                backup_restore_error = restore_err
                    or backup_restore_error
                    or "failed to restore backup"
            end
        end
        return {
            ok = false,
            reason = "copy_failed",
            error = err,
            source = source,
            destination = destination,
            backup = backup or backup_path,
            backup_restored = backup_restored,
            backup_restore_error = backup_restore_error,
        }
    end
    if backup then
        remove_tree(backup, backup)
    end

    return {
        ok = true,
        source = source,
        destination = destination,
        files = copied,
    }
end

return M
