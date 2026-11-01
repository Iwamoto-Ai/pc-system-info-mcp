# Hermes Agent 設定ガイド

## 必要条件

- Hermes Agent v0.14.0 (2026.5.16) 以降
- Windowsの場合は WSL (Windows Subsystem for Linux) で動作させている想定

> **⚠️ Hermes Agent の注意点**
> - LLMモデルは必ずMCPツール使用の性能が高いものを使う必要があります(例: qwen3:14b、qwen3.5:9b)
> - `display.language` を `ja` に変更
> - `tool_use_enforcement: strict` auto から strict に変更
> - **コンテキストサイズは65536以上必須。**
　　(例: `context_length: 65536` と `ollama_num_ctx: 65536` の行を追加)　

モデルをカスタムビルド例、
`.Modelfile`
```
FROM qwen3.5:9b
PARAMETER num_ctx 65536
```

```powershell
ollama create qwen3.5:9b_ctx64k -f ./Modelfile
```
この例では、 model名　qwen3.5:9b_ctx64k　で作成されますので、設定はこのmodel名を指定します。



> - 大量のトークンを必要とします。不要なツールセットを無効化するなどしてトークンを減らす工夫も必要です



## MCPサーバーの登録

`.hermes/config.yaml` を直接編集:

```yaml
mcp_servers:
  pc-system-info:
    command: node
    args:
      - /home/YourName/pc-system-info-mcp/dist/index.js
    sessionIdleTtlMs: 600000
```


## OpenRouter を使った model自動ルーティング設定例

`.hermes/config.yaml`

```yaml
model:
  api_key: API-KEYを記入
  base_url: https://openrouter.ai/api/v1
  context_length: 65536
  default: openrouter/auto
  provider: openrouter
  tools: all
  api_mode: chat_completions
```

## WSLの注意事項

- `powershell.exe` がWSLのPATHに含まれている必要があります
- パスが見つからない場合: `/etc/wsl.conf` に `[interop]` / `appendWindowsPath = true` を追加してWSLを再起動
- Windows側のOllamaに接続する場合、Ollamaは必ずWindows側で起動してください
