# Keylight

[English](README.md) · [简体中文](README.zh-CN.md) · [繁體中文](README.zh-TW.md) · [日本語](README.ja.md) · [한국어](README.ko.md)

快速啟動 macOS App 和本機指令。
搜尋支援縮寫，並在本機依你開啟的 App 調整排序。


![Keylight search](docs/images/search.png)

## 開始使用

需要 macOS 26+ 和 Swift 6.2+。建置並開啟：

```sh
scripts/build.sh
open dist/Keylight.app
```

## 快捷鍵

| | |
|---|---|
| ⌘ Space | 開啟 Keylight |
| ↑ ↓ / Return | 選取／開啟結果 |
| ⌘ M / ⌘ Z | 排除所選 App／復原 |
| ⌘ , | 開啟設定 |

更多設定、CLI、權限與字型署名見[指南](docs/guide.md)（英文）。原始碼採用 [GPL-3.0-only](LICENSE)；Doto 字型採用 [SIL OFL 1.1](Resources/Doto-OFL.txt)。
