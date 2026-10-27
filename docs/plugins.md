# 插件

插件给页面增加一项宿主能力，由三部分组成，随应用一起分发（仓库内的标准插件见 [fetch](plugin-fetch.md)、[watch](plugin-watch.md)、[sqlite](plugin-sqlite.md)、[websocket](plugin-websocket.md)）：

1. **Zig 半部**：一个模块，导出返回 `page_runtime.Plugin` 的构造（名称 + endpoint）。应用在页面连接前调用 `host.use(plugin)`，页面以 `plugin:<name>` 访问。
2. **页面半部**：一个 npm 包，内含由插件服务 schema 生成的 TypeScript 客户端，并通过 `@ziggurat/runtime` 的 `service("plugin:<name>", createClient)` 连接；`@ziggurat/runtime` 作为 peer dependency。
3. **清单**：插件根目录的 `ziggurat-plugin.json`，声明名称、页面包名和需要放在可执行文件旁的原生库。

## Zig 半部

endpoint 实现三个回调，全部在主线程、由 Host 调用：

| 回调 | 时机 | 要求 |
| --- | --- | --- |
| `open(host, session)` | 新文档握手 | 取消旧 session 的全部工作，用新 session 重建 Router/EventSession |
| `receive(host, bytes)` | 发给当前 session 的消息 | 字节只借用到返回；用 `ipc.Dispatcher` 分派，回复经 `host.send`；`host.send` 失败时 Host 已结束连接并关闭所有 endpoint（包括调用者），之后返回错误 |
| `close(host)` | 文档离开、发送失败或 detach | 取消工作，之后不再发送；`host.send` 此时返回 `NotConnected` |

插件拥有自己的 IPC limits（页面侧客户端须传入相同 limits）。阻塞工作放在插件显式创建并 join 的 worker 上，结果经 `App.post` 回到主线程再用当前 token 回复；迟到结果遇到已关闭或已换代的 session 时由 Router 拒绝（`StaleSession`/`StaleRequest`），插件释放其数据。插件名为 1–32 字节小写 ASCII 字母、数字和 `-`，以字母开头；重名或超过 16 个插件时 `use` 失败。

## 页面半部

```ts
import { service } from "@ziggurat/runtime";
import { createClient } from "./generated/client";

const client = () => service("plugin:vault", createClient, { maxMessageBytes: 256 * 1024 });

export async function read(name: string): Promise<string> {
  return (await client()).read({ name }).result;
}
```

生成客户端由 `ipc.generate(Service, allocator)` 产生并提交到包内；包的测试应在 Zig 侧检查提交的客户端与 schema 一致（参照 `check-page-runtime-clients`）。宿主未注册插件时，`service` 以提示 `Host.use` 的错误拒绝。

## 清单

```json
{
  "name": "vault",
  "package": "@acme/vault-page",
  "libraries": [
    {
      "name": "vault-core",
      "files": {
        "x86_64-linux": { "name": "libvault.so", "path": "native/x86_64-linux/libvault.so" },
        "x86_64-windows": {
          "name": "vault.dll",
          "url": "https://example.com/releases/vault-1.2.0-x86_64-windows.dll",
          "sha256": "9b98b6d304a3f76cfe517340c5aae83d0e1835b680a056600d5ae3ac19bd4067"
        }
      }
    }
  ]
}
```

`page_runtime.manifest.parse` 严格校验：未知字段、重复键或库名、非法插件名/包名、文件名含路径分隔符、`path` 为绝对路径或含 `.`/`..` 段、`path` 与 `url` 同时出现或都缺失、`url` 不是带主机的 https 或含用户信息、带 `url` 却缺小写 64 位十六进制 `sha256` 都返回 `InvalidManifest`，`Diagnostic.field()` 给出出错字段。目标键是 `x86_64-windows`、`aarch64-windows`、`x86_64-linux`、`aarch64-linux`、`x86_64-macos`、`aarch64-macos`；`Target.of(arch, os)` 从 Zig 目标映射。`Manifest.filesFor(target, buffer)` 按清单顺序列出该目标要放到可执行文件旁的文件。

分发约定：`path` 文件从插件目录复制，`url` 文件下载后先比对 `sha256`，不一致即失败；两者都以 `name` 放在应用可执行文件所在目录。目前本模块只提供清单格式、校验和按目标列出文件，CLI 的构建与打包命令尚未读取清单，应用需在自己的构建步骤中按上述约定放置文件。清单只描述要分发的文件，不让页面获得额外权限；插件服务仍只对 WebView 已允许 IPC 的页面开放。
