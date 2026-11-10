# Keylight

[English](README.md) · [简体中文](README.zh-CN.md) · [繁體中文](README.zh-TW.md) · [日本語](README.ja.md) · [한국어](README.ko.md)

快速启动 macOS 应用和本地命令。
搜索支持缩写，并在本机根据你打开的应用调整排序。

输入 `add` 或 `proj`，选择项目后写需求。`ADD` 仅保存；`PROJ` 打开对应的 ChatGPT 对话并发送。可在「设置 → 请求」调整范围、置顶、队列与预设。默认使用 `gpt-6.1-terra`、`high`、`Development`。

![Keylight search](docs/images/search.png)

## 开始使用

需要 macOS 26+ 和 Swift 6.2+。构建并打开：

```sh
scripts/build.sh
open dist/Keylight.app
```

## 快捷键

| | |
|---|---|
| ⌘ Space | 打开 Keylight |
| ↑ ↓ / Return | 选择／打开结果 |
| ⌘ M / ⌘ Z | 排除所选应用／撤销 |
| ⌘ , | 打开设置 |
| ⌘ R / ⌘ Q | 刷新应用／退出 Keylight |

更多设置、CLI、权限与字体署名见[指南](docs/guide.md)（英文）。源码采用 [GPL-3.0-only](LICENSE)；Doto 字体采用 [SIL OFL 1.1](Resources/Doto-OFL.txt)。
