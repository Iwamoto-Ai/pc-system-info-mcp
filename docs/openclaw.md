# 🦞 OpenClaw 設定ガイド

OpenClaw と組み合わせると、外出先から LINE や Discord で自宅PCの状況を確認できます。

> **⚠️ リモート利用時の注意**: レスポンスにはMAC・IP・シリアル番号等が含まれます。外部メッセンジャー経由で使う場合は、MCPサーバーの環境変数 `PRIVACY_MODE=1` の利用を推奨します(README参照)。

## 必要条件

- 🦞 OpenClaw Version 2026.5.12 以降

## 推奨モデル

| モデル | ツール呼び出し | 日本語 | 必要VRAM | 備考 |
| --- | --- | --- | --- | --- |
| **nemotron-nano** | 〇 | ◎ | 12GB以上 | |
| llama-3.3-70b-versatile | ◎ 安定 | ◎ | 48GB以上 | **推奨** |
| google/gemma-3-27b-it | △ | ◎ | 35GB以上 | |
| qwen3.5-9b | ◎ 安定  | ◎ | 12GB以上 | **推奨** |
| qwen2.5-coder-7b-instruct | 〇  | △ | 12GB以上 | |
| qwen3:14b | △  | △ | 12GB以上 | |
| qwen3:8b | ✗ 不安定 | △ | 8GB以上 | ツール呼び出しに失敗する |
| qwen3:1.7b | ✗ 非対応 | △ | 6GB以上 | MCPツール呼び出し不可 |


```powershell
# qwen3.5:9b のインストール(Windows PowerShell)
ollama pull qwen3.5:9b
```

## 設定手順

> **⚠️ 重要**: OpenClaw では Claude Desktop の `mcpServers` キーは使用できません。

### ステップ1: CLIコマンドで登録(推奨)

```bash
# Linux / WSL
openclaw mcp set pc-system-info '{
  "command": "node",
  "args": ["/home/YourName/pc-system-info-mcp/dist/index.js"]
}'

# 登録確認
openclaw mcp list
openclaw mcp show pc-system-info
```

### ステップ2: モデルを登録・設定

```bash
# qwen3.5:9b をOpenClawに登録
openclaw config set models.providers.ollama.models '[{"id":"qwen3.5:9b","name":"ollama/qwen3.5:9b","input":["text"],"contextWindow":128000,"maxTokens":4096}]'

# デフォルトモデルに設定
openclaw config set agents.defaults.model '{"primary":"ollama/qwen3.5:9b"}'

# 思考モードをオフ(誤動作防止)
openclaw config set agents.defaults.thinkingDefault '"off"'
```

### ステップ3: ゲートウェイ再起動・確認

```bash
openclaw gateway restart
openclaw status | grep -i "model\|session"
```

`nemotron-nano` が表示されれば成功です。

### openclaw.json に直接記述する場合

`~/.openclaw/openclaw.json` に追記する場合は **`mcp.servers`** キーを使います(`mcpServers` は無効):

```json
{
  "mcp": {
    "servers": {
      "pc-system-info": {
        "command": "node",
        "args": ["/home/YourName/pc-system-info-mcp/dist/index.js"]
      }
    }
  }
}
```

### WSL (Windows Subsystem for Linux) で使用する場合

WSL内で動かす場合、MCPサーバーは自動的にWSLを検出してWindows側の `powershell.exe` を呼び出します。`wslpath` コマンドが利用可能であることを確認してください。また、Windows側のOllamaに接続するため、Ollamaは必ずWindows側で起動してください。

## AGENTS.md へのツール使用指示追加(推奨)

ローカルLLMがMCPツールを確実に呼び出すよう、`~/.openclaw/workspace/AGENTS.md` に以下を追加することを推奨します:

```
## PC System Info MCP Tools
When user asks about CPU, GPU, RAM, temperature, fan, disk, or network,
ALWAYS call the appropriate tool directly:
- get_cpu_info: CPU load and temperature
- get_gpu_info: GPU temperature and VRAM
- get_ram_info: RAM usage
- get_fan_info: Fan info
- get_disk_info: Disk usage and throughput
- get_network_info: Network adapters
- get_all_system_info: ALL metrics at once (recommended)
Do NOT answer from memory. Always call the tool first.
```

> 補足: ツール名を間違えやすいローカルLLM向けに、サーバー側でも `MCP_LENIENT_MODE=1` を設定すると未知のツール名を `get_all_system_info` にフォールバックさせられます(既定はオフ)。

## トラブルシューティング

### `Unrecognized key: "mcpServers"` エラー

OpenClaw では Claude Desktop 形式の `mcpServers` キーは使用できません。CLIコマンドで登録してください:

```bash
openclaw mcp set pc-system-info '{
  "command": "node",
  "args": ["/home/YourName/pc-system-info-mcp/dist/index.js"]
}'
openclaw gateway restart
```

### ツールを呼び出さず、見当違いの返答をする

ローカルLLMがMCPツールを無視して返答する場合:

1. **モデルを qwen3.5:9b に切り替える**(最も効果的)

```bash
ollama pull qwen3.5:9b
openclaw config set agents.defaults.model '{"primary":"ollama/qwen3.5:9b"}'
openclaw gateway restart
```

2. **AGENTS.md にツール使用を明示する**(上記参照)

3. **英語で明示的に指示して試してみる**

```
Use get_all_system_info tool and show the result.
```

### Tool output が返ってこない(タイムアウト)

PowerShellの起動に数秒かかるため、OpenClawのMCPタイムアウトを延長:

```bash
openclaw config set mcp.sessionIdleTtlMs 300000
openclaw gateway restart
```

### `model not allowed` エラー

Ollamaのモデルを OpenClaw に明示的に登録する必要があります:

```bash
openclaw config set models.providers.ollama.models '[{"id":"qwen3.5:9b","name":"ollama/qwen3.5:9b","input":["text"],"contextWindow":128000,"maxTokens":4096}]'
```

### セッションが古いモデルを使い続ける

```bash
openclaw gateway restart
# ダッシュボードで /new と入力して新しいセッションを開始
```
