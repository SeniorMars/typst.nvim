# Cache Invalidation Inventory

Caches exist to keep common editor paths fast. Each cache must have an owner,
an invalidation trigger, and a reset path. Adding a cache without a reset or
status hook should be treated as a lifecycle change.

| Cache / state | Owner | Invalidated by | Reset path |
| --- | --- | --- | --- |
| Config read-only cache | `typst.config` | `setup`, profile changes, reset | config setup/reset |
| Generated metadata selection | `typst.metadata` | metadata version/config changes, explicit clear | `:TypstClearCache` |
| Package resource cache | `typst.package.cache` | TTL, explicit refresh, package cache path changes | `:TypstClearCache`, package cache reset |
| Import-scan cache | project resolver/import scan | root/main config, scan caps, root markers, TTL | project cache clear/reset |
| Project graph/index | project graph/index modules | attach/detach, writes, imports, bibliography changes, explicit dirty marks | project reset/cache clear |
| Source-map cache | preview source-sync modules | compiler output path, source signature, project/index generation, loaded buffer changedtick | preview/source-map cache clear |
| Diagnostics parse line cache | diagnostics parser | per publish call only | discarded after publish |
| Diagnostics quickfix-only paths | diagnostics service | source clear, project clear, new publish for the source | diagnostics clear/project prune |
| Completion path scan | completion path source | directory TTL, config caps, cwd/root changes | completion/cache clear |
| Tinymist completion cache | completion LSP source | buffer changedtick, position/context, client generation | completion/cache clear |
| Conceal match chunks | conceal query engine | buffer changedtick, parser changes, config/categories, custom rules | conceal refresh/cache clear |
| Conceal shadow cache | conceal shadow collector | syntax signature, parser callbacks, custom symbol rules | conceal refresh/cache clear |
| Preview browser artifact state | native browser preview | preview refresh, artifact path/mtime/size changes, stop/reset | preview stop/reset |
| Operation registry | `typst.core.operation` | operation finish/cancel/retain | operation reset/resource supervisor |

Output leases and lock files are not caches. They are ownership records and
must be released only by the resource/output owner rules.

## Budget Rules

- Import scans must obey configured file/depth/entry caps and expose cap-hit
  status in reports.
- Source-map cache keys should prefer project/index generation data and loaded
  buffer changedticks before falling back to filesystem stats.
- Conceal redraw hot paths should use window-local filtering over cached syntax
  matches rather than collecting a full tree on every cursor movement.
- Bug-report generation must cap projects, operations, telemetry, retained
  resources, logs, and nesting depth.
