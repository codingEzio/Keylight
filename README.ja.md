# Keylight

[English](README.md) · [简体中文](README.zh-CN.md) · [繁體中文](README.zh-TW.md) · [日本語](README.ja.md) · [한국어](README.ko.md)

macOS のアプリやローカルコマンドを素早く起動します。
省略した文字列でも検索でき、開いたアプリに応じてこの Mac 上で検索結果の順序を調整します。

`add` でプロジェクトを選び、未送信の依頼を作成・追記します。既存の依頼を選び ⌘Return で送信。`proj` は単発の依頼を作成して送信します。送信済みファイルは残り、未送信の依頼は次回も表示されます。設定の Requests で対象、ピン留め、保存先、プリセットを変更できます。初期値は `gpt-6.1-terra`、`high`、`Development` です。

依頼機能は任意で、設定済みの Godspeed Projects サービスが必要です。送信には対応するログイン済み ChatGPT デスクトップアプリも必要です。設定で有効にすると `clip` はローカルのテキスト履歴、`emp` はマウス確認が必要なゴミ箱操作を開きます。制限と権限は[ガイド](docs/guide.md)を参照してください。

「Default Web Browser」または「Menu Bar App Visibility」を検索すると、システム設定の対応するコントロールを開けます。この二つにはアクセシビリティのアクセスが必要です。「システム設定 → プライバシーとセキュリティ → アクセシビリティ」で Keylight を許可してから、もう一度実行してください。設定値は自分で選びます。

![Keylight search](docs/images/search.png)

## 使い始める

macOS 26 以降と Swift 6.2 以降が必要です。ビルドして開きます：

```sh
scripts/build.sh
open dist/Keylight.app
```

## ショートカット

| | |
|---|---|
| ⌘ Space | Keylight を開く |
| ↑ ↓ / Return | 結果を選択／開く |
| ⌘ M / ⌘ Z | 選択したアプリを除外／取り消す |
| ⌘ , | 設定を開く |
| ⌘ R / ⌘ Q | アプリを更新／Keylight を終了 |

設定、CLI、権限、フォントの帰属については[ガイド](docs/guide.md)（英語）を参照してください。ソースコードは [GPL-3.0-only](LICENSE)、Doto フォントは [SIL OFL 1.1](Resources/Doto-OFL.txt) です。
