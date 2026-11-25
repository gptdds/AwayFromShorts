# AwayFromShorts 2.1.1

- 新增 `awayfromshorts.cross-platform` v1 跨端功能契约。
- `/api/status` 与 `/api/contract` 会返回电脑端版本、契约哈希、作用域位图和支持功能。
- `hub-config.json` 的 `pc` 分节新增 `contract` 能力清单；规则未变但契约升级时也会推送。
- 读写 Hub 时保留顶层、设备分节以及与当前版本无关的未知字段。
- 契约明确标注电脑端尚未支持按星期全局停用、或集和备忘录 Markdown，避免与手机端功能产生错误对齐。
