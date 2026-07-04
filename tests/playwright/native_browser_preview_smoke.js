#!/usr/bin/env node

const fs = require("fs");
const os = require("os");
const path = require("path");
const { spawn } = require("child_process");

const requirePlaywright = process.env.TYPST_NVIM_REQUIRE_PLAYWRIGHT === "1";

function loadPlaywright() {
  try {
    return require("playwright");
  } catch (firstError) {
    try {
      return require("playwright-core");
    } catch (_) {
      if (requirePlaywright) {
        throw firstError;
      }
      console.log(
        "playwright smoke skipped: install playwright or set TYPST_NVIM_REQUIRE_PLAYWRIGHT=1 to require it",
      );
      process.exit(0);
    }
  }
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function waitForFile(file, timeoutMs) {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    if (fs.existsSync(file)) {
      return JSON.parse(fs.readFileSync(file, "utf8"));
    }
    await sleep(50);
  }
  throw new Error(`timed out waiting for ${file}`);
}

async function waitForProcessExit(exitPromise, child, timeoutMs) {
  let timer = null;
  try {
    return await Promise.race([
      exitPromise,
      new Promise((_, reject) => {
        timer = setTimeout(() => {
          child.kill("SIGTERM");
          reject(new Error(`nvim driver did not exit within ${timeoutMs}ms`));
        }, timeoutMs);
      }),
    ]);
  } finally {
    if (timer) {
      clearTimeout(timer);
    }
  }
}

function assert(condition, message) {
  if (!condition) {
    throw new Error(message);
  }
}

function nvimCommand(repoRoot, statePath, donePath) {
  return {
    command: process.env.NVIM || "nvim",
    args: [
      "--headless",
      "-n",
      "-u",
      "tests/minimal_init.lua",
      "-l",
      "tests/playwright/native_browser_preview_driver.lua",
    ],
    options: {
      cwd: repoRoot,
      env: {
        ...process.env,
        TYPST_NVIM_PLAYWRIGHT_STATE: statePath,
        TYPST_NVIM_PLAYWRIGHT_DONE: donePath,
      },
      stdio: ["ignore", "pipe", "pipe"],
    },
  };
}

async function main() {
  const playwright = loadPlaywright();
  const repoRoot = path.resolve(__dirname, "..", "..");
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "typst-nvim-playwright-"));
  const statePath = path.join(tmp, "state.json");
  const donePath = path.join(tmp, "done");
  const nvim = nvimCommand(repoRoot, statePath, donePath);
  const child = spawn(nvim.command, nvim.args, nvim.options);
  let stdout = "";
  let stderr = "";
  const childExit = new Promise((resolve) => {
    child.once("exit", (code, signal) => resolve({ code, signal }));
    child.once("error", (error) => resolve({ error }));
  });

  child.stdout.on("data", (chunk) => {
    stdout += chunk.toString();
  });
  child.stderr.on("data", (chunk) => {
    stderr += chunk.toString();
  });

  let browser = null;
  try {
    const state = await waitForFile(statePath, 15000);
    assert(state.ok === true, `preview driver failed: ${JSON.stringify(state)}`);
    assert(
      typeof state.url === "string" && state.url.startsWith("http://"),
      `expected native browser server URL, got ${state.url}`,
    );
    assert(
      state.transport === "server",
      `expected server transport, got ${state.transport}`,
    );

    try {
      browser = await playwright.chromium.launch({ headless: true });
    } catch (error) {
      if (requirePlaywright) {
        throw error;
      }
      console.log(
        `playwright smoke skipped: chromium launch failed (${error.message})`,
      );
      fs.writeFileSync(donePath, "skipped\n");
      await waitForProcessExit(childExit, child, 10000);
      return;
    }

    const page = await browser.newPage();
    await page.goto(state.url, { waitUntil: "domcontentloaded" });
    await page.waitForSelector("#artifact", { timeout: 5000 });
    await page.waitForSelector("#reload", { timeout: 5000 });
    await page.waitForSelector("#sync", { timeout: 5000 });

    const title = await page.title();
    assert(title.includes("main.typ"), `unexpected preview title: ${title}`);

    const metaText = await page.locator("#meta").textContent();
    assert(metaText !== null, "preview metadata element should render");

    await page.locator("#reload").click();

    const previewState = await page.evaluate(async () => {
      const response = await fetch("state", { cache: "no-store" });
      return { status: response.status, body: await response.json() };
    });
    assert(previewState.status === 200, "state endpoint should return 200");
    assert(previewState.body.ok === true, "state endpoint should report ok");
    assert(
      previewState.body.output_name === "main.pdf",
      `unexpected output name: ${previewState.body.output_name}`,
    );
    assert(
      previewState.body.source_sync
        && previewState.body.source_sync.browser_click === true,
      "state endpoint should advertise browser source sync",
    );

    const artifact = await page.evaluate(async () => {
      const response = await fetch("artifact", { cache: "no-store" });
      return { status: response.status, text: await response.text() };
    });
    assert(artifact.status === 200, "artifact endpoint should return 200");
    assert(
      artifact.text.includes("fake typst.nvim integration fixture"),
      "artifact endpoint should serve fake Typst output",
    );

    const sync = await page.evaluate(async () => {
      const params = new URLSearchParams({
        x: "12",
        y: "34",
        page: "1",
        viewport_width: "800",
        viewport_height: "600",
        target: "svg",
      });
      const response = await fetch(`source-sync?${params.toString()}`, {
        cache: "no-store",
      });
      return { status: response.status, body: await response.json() };
    });
    assert(sync.status === 200, "source-sync endpoint should return 200");
    assert(sync.body.ok === true, "source-sync endpoint should report ok");
    assert(
      sync.body.source_sync === "browser-inverse",
      `unexpected source-sync mode: ${sync.body.source_sync}`,
    );

    fs.writeFileSync(donePath, "ok\n");
    const exit = await waitForProcessExit(childExit, child, 10000);
    assert(
      !exit.error && exit.code === 0,
      `nvim driver exited with ${exit.error || exit.code || exit.signal}\n${stderr}`,
    );
    console.log("playwright native browser preview smoke passed");
  } catch (error) {
    fs.writeFileSync(donePath, "failed\n");
    child.kill("SIGTERM");
    try {
      await waitForProcessExit(childExit, child, 2000);
    } catch (_) {
      // The primary failure below contains the useful browser/assertion context.
    }
    throw new Error(
      `${error.message}\n\n--- nvim stdout ---\n${stdout}\n--- nvim stderr ---\n${stderr}`,
    );
  } finally {
    if (browser) {
      await browser.close();
    }
  }
}

main().catch((error) => {
  console.error(error.stack || String(error));
  process.exit(1);
});
