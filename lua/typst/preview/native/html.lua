local util = require("typst.core.util")

local M = {}

local function json(value)
    if vim.json and vim.json.encode then
        return vim.json.encode(value)
    end
    return vim.fn.json_encode(value)
end

local function read_css_file(path, root)
    if type(path) ~= "string" or path == "" then
        return nil
    end

    local resolved = util.resolve_path(path, root or vim.fn.getcwd())
    if not resolved or vim.fn.filereadable(resolved) ~= 1 then
        return nil
    end

    local ok, lines = pcall(vim.fn.readfile, resolved)
    if not ok or type(lines) ~= "table" then
        return nil
    end
    return table.concat(lines, "\n")
end

function M.json(value)
    return json(value)
end

function M.escape(value)
    value = tostring(value or "")
    return value
        :gsub("&", "&amp;")
        :gsub("<", "&lt;")
        :gsub(">", "&gt;")
        :gsub('"', "&quot;")
        :gsub("'", "&#39;")
end

local base_style = [[
    :root {
      --typst-preview-bg: #f7f7f3;
      --typst-preview-fg: #171717;
      --typst-preview-muted: #585858;
      --typst-preview-subtle: #6b6b63;
      --typst-preview-toolbar-bg: #ffffff;
      --typst-preview-toolbar-border: #d8d8d0;
      --typst-preview-artifact-bg: #ffffff;
      --typst-preview-error-fg: #8a1f11;
      --typst-preview-error-bg: #fff7f4;
      --typst-preview-error-border: #f0c8bd;
      --typst-preview-control-bg: #fbfbf8;
      --typst-preview-control-border: #c9c9bf;
      --typst-preview-control-hover-bg: #efefe8;
      --typst-preview-control-disabled: #9a9a91;
      --typst-preview-font: 13px system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    }
    html, body { height: 100%; margin: 0; background: var(--typst-preview-bg); color: var(--typst-preview-fg); }
    body { display: grid; grid-template-rows: auto auto 1fr; font: var(--typst-preview-font); }
    header { display: flex; gap: 10px; align-items: center; padding: 7px 10px; border-bottom: 1px solid var(--typst-preview-toolbar-border); background: var(--typst-preview-toolbar-bg); min-width: 0; }
    strong { font-weight: 650; }
    span { color: var(--typst-preview-muted); }
    #status, #meta { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; min-width: 0; }
    #status { flex: 1 1 auto; }
    #meta { flex: 0 1 auto; color: var(--typst-preview-subtle); }
    #error { min-height: 0; padding: 0 10px; color: var(--typst-preview-error-fg); background: var(--typst-preview-error-bg); border-bottom: 0 solid var(--typst-preview-error-border); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    #error.active { min-height: 24px; padding-top: 4px; padding-bottom: 4px; border-bottom-width: 1px; }
    .controls { display: flex; gap: 4px; align-items: center; flex: 0 0 auto; }
    button, input { height: 26px; border: 1px solid var(--typst-preview-control-border); background: var(--typst-preview-control-bg); color: var(--typst-preview-fg); font: inherit; }
    button { min-width: 28px; padding: 0 8px; cursor: pointer; }
    button:hover:not(:disabled) { background: var(--typst-preview-control-hover-bg); }
    button:disabled { color: var(--typst-preview-control-disabled); cursor: default; }
    label { display: inline-flex; gap: 4px; align-items: center; color: var(--typst-preview-muted); }
    input { width: 52px; padding: 0 4px; }
    #viewport { overflow: auto; background: var(--typst-preview-artifact-bg); }
    iframe { width: 100%; height: 100%; border: 0; background: var(--typst-preview-artifact-bg); transform-origin: 0 0; display: block; }
    @media (max-width: 720px) {
      header { flex-wrap: wrap; }
      #status { flex-basis: 100%; order: 3; }
      #meta { display: none; }
    }
]]

local function css_variable_name(key)
    key = tostring(key or "")
    if key:match("^%-%-") then
        return key
    end
    return "--typst-preview-" .. key
end

local function style_overrides(style, root)
    style = style or {}
    local blocks = {}
    if type(style.variables) == "table" and next(style.variables) ~= nil then
        local keys = vim.tbl_keys(style.variables)
        table.sort(keys)
        local lines = { ":root {" }
        for _, key in ipairs(keys) do
            lines[#lines + 1] = ("  %s: %s;"):format(
                css_variable_name(key),
                tostring(style.variables[key])
            )
        end
        lines[#lines + 1] = "}"
        blocks[#blocks + 1] = table.concat(lines, "\n")
    end

    local file_css = read_css_file(style.css_path, root)
    if file_css and file_css ~= "" then
        blocks[#blocks + 1] = file_css
    end

    if type(style.css) == "string" and style.css ~= "" then
        blocks[#blocks + 1] = style.css
    end
    return #blocks > 0 and ("\n" .. table.concat(blocks, "\n")) or ""
end

local function style_for(route)
    return base_style .. style_overrides(route.style, route.root)
end

local shell_template = [[
<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>__TITLE__</title>
  <style>
__STYLE__
  </style>
</head>
<body>
  <header>
    <strong>typst.nvim</strong>
    <span id="status">__STATUS__</span>
    <span id="meta"></span>
    <div class="controls">
      <button id="reload" type="button" title="Reload">R</button>
      <button id="zoomOut" type="button" title="Zoom out">-</button>
      <span id="zoomLabel">100%</span>
      <button id="zoomIn" type="button" title="Zoom in">+</button>
      <button id="fit" type="button" title="Toggle fit">Fit</button>
      <label title="Page">Page <input id="page" type="number" min="1" value="1"></label>
      <button id="sync" type="button" title="Toggle source sync">Sync</button>
    </div>
  </header>
  <div id="error"></div>
  <div id="viewport">
    <iframe id="artifact" title="Typst preview"></iframe>
  </div>
  <script>
    const stateUrl = __STATE_URL__;
    const artifactUrl = __ARTIFACT_URL__;
    const refreshMs = __REFRESH_MS__;
    const frame = document.getElementById("artifact");
    const status = document.getElementById("status");
    const meta = document.getElementById("meta");
    const errorBox = document.getElementById("error");
    const reloadButton = document.getElementById("reload");
    const zoomOutButton = document.getElementById("zoomOut");
    const zoomInButton = document.getElementById("zoomIn");
    const fitButton = document.getElementById("fit");
    const pageInput = document.getElementById("page");
    const syncButton = document.getElementById("sync");
    let lastVersion = null;
    let lastOutput = null;
    let currentState = null;
    let zoom = 1;
    let fit = true;
    let sourceSyncEnabled = true;
    let lastForwardSerial = null;

    function setError(message) {
      if (message) {
        errorBox.textContent = message;
        errorBox.classList.add("active");
      } else {
        errorBox.textContent = "";
        errorBox.classList.remove("active");
      }
    }

    function versionFor(state) {
      return String(state.generation || state.mtime || Date.now());
    }

    function artifactSrc(outputUrl, version) {
      const base = outputUrl || artifactUrl;
      if (!base) {
        return "about:blank";
      }
      const sep = base.includes("?") ? "&" : "?";
      let src = base + sep + "v=" + encodeURIComponent(version || Date.now());
      const state = currentState || {};
      const page = Number(pageInput.value || 1);
      if (state.output_format === "pdf" && page > 0) {
        src += "#page=" + encodeURIComponent(page);
      }
      return src;
    }

    function applyZoom() {
      document.getElementById("zoomLabel").textContent = Math.round(zoom * 100) + "%";
      fitButton.textContent = fit ? "Fit" : "1:1";
      if (fit) {
        frame.style.width = "100%";
        frame.style.height = "100%";
        frame.style.transform = "";
        return;
      }
      frame.style.width = (100 / zoom) + "%";
      frame.style.height = (100 / zoom) + "%";
      frame.style.transform = "scale(" + zoom + ")";
    }

    function bytesLabel(bytes) {
      const value = Number(bytes || 0);
      if (!value) {
        return "";
      }
      if (value >= 1024 * 1024) {
        return (value / 1024 / 1024).toFixed(1) + " MiB";
      }
      if (value >= 1024) {
        return (value / 1024).toFixed(1) + " KiB";
      }
      return String(value) + " B";
    }

    function metadataText(state) {
      const parts = [];
      if (state.output_format) {
        parts.push(String(state.output_format).toUpperCase());
      }
      const size = bytesLabel(state.output_size);
      if (size) {
        parts.push(size);
      }
      if (state.mtime || state.generation) {
        parts.push("updated " + new Date().toLocaleTimeString());
      }
      return parts.join(" · ");
    }

    function updateArtifactControls(state) {
      const pdf = state.output_format === "pdf";
      pageInput.disabled = !pdf;
      if (!pdf) {
        pageInput.value = "1";
      }
    }

    function reload(version) {
      const state = currentState || {};
      frame.src = artifactSrc(state.output_url, version || Date.now());
    }

    function setMeta(state, suffix) {
      const base = metadataText(state || {});
      meta.textContent = suffix ? (base ? base + " · " + suffix : suffix) : base;
    }

    function updateSourceSync(state) {
      const sync = state.source_sync || {};
      const available = Boolean(state.sync_url && sync.browser_click);
      syncButton.disabled = !available;
      syncButton.textContent = available && sourceSyncEnabled ? "Sync on" : "Sync";
      if (!available) {
        syncButton.textContent = "Sync";
        const prefix = sync.forward ? "forward sync available" : "source sync unavailable";
        setMeta(state, sync.message || (prefix + "; browser click sync unavailable"));
        return;
      }
      const provider = sync.provider && sync.provider !== "none" ? sync.provider : "source-map";
      setMeta(state, provider + " browser click sync");
    }

    function handleState(state) {
      if (!state.ok) {
        status.textContent = state.message || "Preview stopped";
        frame.removeAttribute("src");
        syncButton.disabled = true;
        pageInput.disabled = true;
        setError(state.message || "Preview stopped");
        return;
      }

      currentState = state;
      setError("");
      updateArtifactControls(state);
      const version = versionFor(state);
      if (version !== lastVersion || state.output !== lastOutput) {
        lastVersion = version;
        lastOutput = state.output;
        reload(version);
      }
      status.textContent = state.output_name || state.output || "Preview";
      setMeta(state);
      updateSourceSync(state);
      handleForwardTarget(state.forward_target);
    }

    async function fetchJson(url) {
      const response = await fetch(url, { cache: "no-store" });
      if (!response.ok) {
        throw new Error("HTTP " + response.status);
      }
      return await response.json();
    }

    async function tick() {
      try {
        handleState(await __LOAD_STATE__);
      } catch (error) {
        status.textContent = "Waiting for typst.nvim...";
        setError(String(error && error.message || error));
      }
    }

    function svgPointFor(event) {
      try {
        const doc = frame.contentDocument || (frame.contentWindow && frame.contentWindow.document);
        const svg = event.target && event.target.ownerSVGElement
          ? event.target.ownerSVGElement
          : doc && doc.documentElement && doc.documentElement.tagName.toLowerCase() === "svg"
            ? doc.documentElement
            : null;
        if (!svg || typeof svg.createSVGPoint !== "function" || typeof svg.getScreenCTM !== "function") {
          return null;
        }
        const matrix = svg.getScreenCTM();
        if (!matrix) {
          return null;
        }
        const point = svg.createSVGPoint();
        point.x = event.clientX || 0;
        point.y = event.clientY || 0;
        return point.matrixTransform(matrix.inverse());
      } catch (_) {
        return null;
      }
    }

    function syncParams(event) {
      const target = event.target && event.target.tagName ? event.target.tagName : "";
      const point = svgPointFor(event);
      const x = point ? point.x : Math.max(0, event.clientX || 0);
      const y = point ? point.y : Math.max(0, event.clientY || 0);
      return new URLSearchParams({
        event: "click",
        page: String(Number(pageInput.value || 1)),
        x: String(Math.max(0, x || 0)),
        y: String(Math.max(0, y || 0)),
        client_x: String(Math.max(0, event.clientX || 0)),
        client_y: String(Math.max(0, event.clientY || 0)),
        viewport_width: String(frame.clientWidth || 0),
        viewport_height: String(frame.clientHeight || 0),
        target: target
      });
    }

    async function sendSourceSync(event) {
      const state = currentState || {};
      const sync = state.source_sync || {};
      if (!sourceSyncEnabled || !state.sync_url || !sync.browser_click) {
        return;
      }
      try {
        const response = await fetch(state.sync_url + "?" + syncParams(event).toString(), {
          cache: "no-store"
        });
        const result = await response.json();
        if (!result.ok && !result.pending) {
          setError(result.message || result.reason || "Source sync failed");
        } else {
          setError("");
          status.textContent = result.pending ? "Source sync pending" : "Source sync sent";
          setTimeout(function() {
            if (currentState) {
              status.textContent = currentState.output_name || currentState.output || "Preview";
            }
          }, 1200);
        }
      } catch (error) {
        setError("Source sync failed: " + String(error && error.message || error));
      }
    }

    function scrollFrameToTarget(target) {
      if (!target || target.x == null || target.y == null) {
        return;
      }
      try {
        const win = frame.contentWindow;
        const doc = frame.contentDocument || (win && win.document);
        const svg = doc && doc.documentElement && doc.documentElement.tagName.toLowerCase() === "svg"
          ? doc.documentElement
          : null;
        if (!win || !svg) {
          return;
        }
        const box = svg.viewBox && svg.viewBox.baseVal;
        const rect = svg.getBoundingClientRect();
        const scaleX = box && box.width ? rect.width / box.width : 1;
        const scaleY = box && box.height ? rect.height / box.height : 1;
        const left = Math.max(0, ((Number(target.x) || 0) - (box ? box.x : 0)) * scaleX - frame.clientWidth * 0.2);
        const top = Math.max(0, ((Number(target.y) || 0) - (box ? box.y : 0)) * scaleY - frame.clientHeight * 0.25);
        win.scrollTo({ left, top, behavior: "smooth" });
        meta.textContent = "source sync line " + String(target.line || "?");
      } catch (error) {
        setError("Forward sync failed: " + String(error && error.message || error));
      }
    }

    function handleForwardTarget(target) {
      if (!target || target.serial == null || target.serial === lastForwardSerial) {
        return;
      }
      lastForwardSerial = target.serial;
      if (frame.contentDocument && frame.contentDocument.readyState === "complete") {
        scrollFrameToTarget(target);
      } else {
        frame.addEventListener("load", function once() {
          frame.removeEventListener("load", once);
          scrollFrameToTarget(target);
        });
      }
    }

    function attachFrameClick() {
      try {
        const doc = frame.contentDocument || (frame.contentWindow && frame.contentWindow.document);
        if (!doc || doc.__typstNvimSourceSync) {
          return;
        }
        doc.__typstNvimSourceSync = true;
        doc.addEventListener("click", function(event) {
          if (!sourceSyncEnabled) {
            return;
          }
          sendSourceSync(event);
        }, true);
      } catch (_) {
      }
    }

    reloadButton.addEventListener("click", function() {
      reload(Date.now());
    });
    zoomOutButton.addEventListener("click", function() {
      fit = false;
      zoom = Math.max(0.25, zoom - 0.1);
      applyZoom();
    });
    zoomInButton.addEventListener("click", function() {
      fit = false;
      zoom = Math.min(4, zoom + 0.1);
      applyZoom();
    });
    fitButton.addEventListener("click", function() {
      fit = !fit;
      applyZoom();
    });
    pageInput.addEventListener("change", function() {
      reload(lastVersion || Date.now());
    });
    syncButton.addEventListener("click", function() {
      sourceSyncEnabled = !sourceSyncEnabled;
      updateSourceSync(currentState || {});
    });
    document.addEventListener("keydown", function(event) {
      if (event.defaultPrevented || event.metaKey || event.ctrlKey || event.altKey) {
        return;
      }
      const tag = event.target && event.target.tagName ? event.target.tagName.toLowerCase() : "";
      if (tag === "input" || tag === "textarea" || tag === "select") {
        return;
      }
      if (event.key === "r" || event.key === "R") {
        reload(Date.now());
      } else if (event.key === "+" || event.key === "=") {
        fit = false;
        zoom = Math.min(4, zoom + 0.1);
        applyZoom();
      } else if (event.key === "-" || event.key === "_") {
        fit = false;
        zoom = Math.max(0.25, zoom - 0.1);
        applyZoom();
      } else if (event.key === "f" || event.key === "F") {
        fit = !fit;
        applyZoom();
      } else if (event.key === "s" || event.key === "S") {
        if (!syncButton.disabled) {
          sourceSyncEnabled = !sourceSyncEnabled;
          updateSourceSync(currentState || {});
        }
      } else {
        return;
      }
      event.preventDefault();
    });
    frame.addEventListener("load", attachFrameClick);
    applyZoom();
    tick();
    if (refreshMs > 0) {
      setInterval(tick, refreshMs);
    }
  </script>
</body>
</html>
]]

local file_state_loader = [[
    new Promise((resolve, reject) => {
      const script = document.createElement("script");
      script.src = stateUrl + "?v=" + encodeURIComponent(Date.now());
      script.onload = () => resolve(window.__typstNvimPreviewState || {});
      script.onerror = reject;
      document.head.appendChild(script);
      setTimeout(() => script.remove(), 0);
    })
]]

local function title_for(route)
    return ("typst.nvim preview - %s"):format(
        util.basename(route.main or route.output or "Typst")
    )
end

local function render_template(template, replacements)
    for key, value in pairs(replacements) do
        template = template:gsub("__" .. key .. "__", function()
            return value
        end)
    end
    return template
end

local function shell(route, opts)
    opts = opts or {}
    return render_template(shell_template, {
        TITLE = M.escape(title_for(route)),
        STYLE = style_for(route),
        STATUS = M.escape(opts.status or "Connecting..."),
        STATE_URL = opts.state_url or json("state"),
        ARTIFACT_URL = opts.artifact_url or json("artifact"),
        REFRESH_MS = tostring(route.refresh_ms or 1000),
        LOAD_STATE = opts.load_state or "fetchJson(stateUrl)",
    })
end

function M.server_shell(route)
    return shell(route)
end

function M.file_shell(route)
    return shell(route, {
        status = util.basename(route.output or "output"),
        state_url = json(route.state_url),
        artifact_url = "null",
        load_state = file_state_loader,
    })
end

function M.stopped_shell(message, custom_style, root)
    return ([[
<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>typst.nvim preview stopped</title>
  <style>
	%s
	  </style>
</head>
<body>
  <header>
    <strong>typst.nvim</strong>
    <span>%s</span>
  </header>
  <iframe id="artifact" title="Typst preview"></iframe>
</body>
</html>
]]):format(
        base_style .. style_overrides(custom_style, root),
        M.escape(message or "Preview stopped")
    )
end

function M.file_state(payload)
    return "window.__typstNvimPreviewState = " .. json(payload or {}) .. ";"
end

return M
