# 凭据与使用流程 HTML 参考图

全部来自已确认 round05 HTML；紫色，1x DPR，原始内容视口。不是 Flutter 实现或业务验收。

| Case | Query | Steps | 1440×900 | 1280×800 |
| --- | --- | --- | --- | --- |
| credential-file | `theme=purple&page=credentials` | `none` | [PNG](cases/credential-file/page-1440x900.png) | [PNG](cases/credential-file/page-1280x800.png) |
| credential-string | `theme=purple&page=credentials&state=token` | `none` | [PNG](cases/credential-string/page-1440x900.png) | [PNG](cases/credential-string/page-1280x800.png) |
| credential-expired | `theme=purple&page=credentials&state=expired` | `none` | [PNG](cases/credential-expired/page-1440x900.png) | [PNG](cases/credential-expired/page-1280x800.png) |
| credential-add-string | `theme=purple&page=credentials` | `click [aria-label="添加凭据"]` | [PNG](cases/credential-add-string/page-1440x900.png) | [PNG](cases/credential-add-string/page-1280x800.png) |
| credential-add-file | `theme=purple&page=credentials` | `click [aria-label="添加凭据"]; click .credential-form-options button:has-text("文件")` | [PNG](cases/credential-add-file/page-1440x900.png) | [PNG](cases/credential-add-file/page-1280x800.png) |
| credential-rotate | `theme=purple&state=credential-rotate` | `none` | [PNG](cases/credential-rotate/page-1440x900.png) | [PNG](cases/credential-rotate/page-1280x800.png) |
| credential-discovery | `theme=purple&state=credential-discovery` | `none` | [PNG](cases/credential-discovery/page-1440x900.png) | [PNG](cases/credential-discovery/page-1280x800.png) |
| credential-links | `theme=purple&page=library` | `click .associated-credentials .section-heading button` | [PNG](cases/credential-links/page-1440x900.png) | [PNG](cases/credential-links/page-1280x800.png) |
| server-linked | `theme=purple&state=server` | `none` | [PNG](cases/server-linked/page-1440x900.png) | [PNG](cases/server-linked/page-1280x800.png) |
| use-string | `theme=purple&state=use-token` | `none` | [PNG](cases/use-string/page-1440x900.png) | [PNG](cases/use-string/page-1280x800.png) |
| use-file | `theme=purple&state=use-file` | `none` | [PNG](cases/use-file/page-1440x900.png) | [PNG](cases/use-file/page-1280x800.png) |
| use-file-env | `theme=purple&state=file-env` | `none` | [PNG](cases/use-file-env/page-1440x900.png) | [PNG](cases/use-file-env/page-1280x800.png) |
| use-file-tip | `theme=purple&state=use-file` | `click [aria-label="查看注入方式说明"]` | [PNG](cases/use-file-tip/page-1440x900.png) | [PNG](cases/use-file-tip/page-1280x800.png) |
| use-request | `theme=purple&state=use-file` | `click .request-link` | [PNG](cases/use-request/page-1440x900.png) | [PNG](cases/use-request/page-1280x800.png) |
| use-file-confirm | `theme=purple&state=use-file` | `click .credential-request .decision-actions .primary` | [PNG](cases/use-file-confirm/page-1440x900.png) | [PNG](cases/use-file-confirm/page-1280x800.png) |
| use-string-confirm | `theme=purple&state=use-token` | `click .credential-request .decision-actions .primary` | [PNG](cases/use-string-confirm/page-1440x900.png) | [PNG](cases/use-string-confirm/page-1280x800.png) |
| execution-running | `theme=purple&state=execution-running` | `none` | [PNG](cases/execution-running/page-1440x900.png) | [PNG](cases/execution-running/page-1280x800.png) |
| execution-prepare-failed | `theme=purple&state=execution-prepare_failed` | `none` | [PNG](cases/execution-prepare-failed/page-1440x900.png) | [PNG](cases/execution-prepare-failed/page-1280x800.png) |
| execution-start-failed | `theme=purple&state=execution-start_failed` | `none` | [PNG](cases/execution-start-failed/page-1440x900.png) | [PNG](cases/execution-start-failed/page-1280x800.png) |
| execution-nonzero | `theme=purple&state=execution-nonzero` | `none` | [PNG](cases/execution-nonzero/page-1440x900.png) | [PNG](cases/execution-nonzero/page-1280x800.png) |
| execution-unknown | `theme=purple&state=execution-unknown` | `none` | [PNG](cases/execution-unknown/page-1440x900.png) | [PNG](cases/execution-unknown/page-1280x800.png) |
| execution-token | `theme=purple&state=execution-token` | `none` | [PNG](cases/execution-token/page-1440x900.png) | [PNG](cases/execution-token/page-1280x800.png) |
| execution-cleanup-failed | `theme=purple&state=cleanup` | `none` | [PNG](cases/execution-cleanup-failed/page-1440x900.png) | [PNG](cases/execution-cleanup-failed/page-1280x800.png) |
