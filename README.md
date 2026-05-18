# PC System Info MCP Server

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Node.js](https://img.shields.io/badge/Node.js-18%2B-green.svg)](https://nodejs.org/)
[![Platform](https://img.shields.io/badge/Platform-Windows%20%7C%20macOS-blue.svg)](#)
[![MCP](https://img.shields.io/badge/MCP-Compatible-purple.svg)](https://modelcontextprotocol.io/)

PCのシステム情報を取得する **Model Context Protocol (MCP) サーバー**です。  
CPU/GPU稼働状況、RAM/VRAM、ファン回転数、ディスク、ネットワーク情報を Claude Desktop および 🦞OpenClaw から自然言語で確認できます。

🦞 外出先からOpenClawが稼働しているPCの状況確認に使えます。

プロンプト例　「CPUとGPUの状況を教えて」など
 

> **⚠️ 注意**: WMICコマンドは廃止されたため使用していません。Windows では `Get-CimInstance`（PowerShell）を使用します。

---

## 📊 取得できる情報

| カテゴリ | 取得情報 | Windows | macOS |
|---------|---------|---------|-------|
| **システム概要** | OS・ホスト名・稼働時間・マザーボード・BIOS | ✅ | ✅ |
| **CPU** | 名称・コア数・クロック速度・負荷%・**温度°C** | ✅ | ✅ |
| **GPU (NVIDIA)** | 名称・**温度°C**・使用率%・**VRAM使用量**・**ファン速度%**・消費電力W・クロック | ✅ | ✅ |
| **GPU (AMD/Intel)** | 名称・VRAM総量・ドライババージョン | ✅ | ✅ |
| **RAM** | 総容量・使用量・空き容量・使用率%・スロット情報 | ✅ | ✅ |
| **ファン** | 全ファンの回転数 (RPM) | ✅* | ✅* |
| **ディスク** | モデル・容量・メディア種別・インターフェース・ボリューム使用量・読み書き速度 | ✅ | ✅ |
| **ネットワーク** | アダプター情報・IPアドレス・MAC・DNS・送受信スループット | ✅ | ✅ |

> *ファン・CPU温度: 追加ソフトウェアが必要（後述）

---

## 🛠️ 利用可能なMCPツール

| ツール名 | 説明 |
|---------|------|
| `get_system_overview` | システム全体の概要 |
| `get_cpu_info` | CPU情報（温度・負荷含む） |
| `get_gpu_info` | GPU情報（NVIDIA完全テレメトリ） |
| `get_ram_info` | RAM使用状況・DIMMスロット |
| `get_fan_info` | ファン回転数 (RPM) |
| `get_disk_info` | ストレージ情報・I/Oスループット |
| `get_network_info` | ネットワーク情報・スループット |
| `get_all_system_info` | **全情報を一括取得** |
| `get_server_info` | MCPサーバー自体の情報・設定ヒント |

---

## 📋 必要条件

### 共通
- **Node.js 18.0.0 以上**
- Git

### Windows
- Windows 10 バージョン 21H1 以降（WMICが削除されたバージョン対応）
- Windows 11 推奨
- PowerShell 5.1以上（Windows標準付属）

### macOS
- macOS 12 Monterey 以降

### OpenClaw
- 🦞 OpenClaw Version 2026.5.12 以降

---

## 🚀 インストール

```bash
# 1. リポジトリのクローン
git clone https://github.com/YourName/pc-system-info-mcp.git
cd pc-system-info-mcp

# 2. 依存パッケージのインストール
npm install

# 3. ビルド
npm run build

# macOSの場合: スクリプトに実行権限を付与
chmod +x scripts/macos/get-system-info.sh
```

---

## ⚙️ Claude Desktop への設定

### 設定ファイルの場所

| OS | パス |
|----|------|
| Windows | `%APPDATA%\Claude\claude_desktop_config.json` |
| macOS | `~/Library/Application Support/Claude/claude_desktop_config.json` |


### Windows の設定例

```json
{
  "mcpServers": {
    "pc-system-info": {
      "command": "node",
      "args": [
        "C:\\Users\\YourName\\pc-system-info-mcp\\dist\\index.js"
      ]
    }
  }
}
```


### macOS の設定例

```json
{
  "mcpServers": {
    "pc-system-info": {
      "command": "node",
      "args": [
        "/Users/YourName/pc-system-info-mcp/dist/index.js"
      ]
    }
  }
}
```

設定後、**Claude Desktop を再起動**してください。

---


## 🦞 OpenClaw への設定

> **⚠️ 重要**: OpenClaw では Claude Desktop の `mcpServers` キーは使用できません。  
> OpenClaw 専用の設定方法を使ってください。

### 推奨モデル

OpenClaw でMCPツール呼び出しを安定して使うには **mistral-nemo** を推奨します。

| モデル | ツール呼び出し | 日本語 | VRAM | 備考 |
|--------|--------------|--------|------|------|
| **mistral-nemo** | ◎ 安定 | ◎  | 8GB | **推奨** |
| qwen3:8b | △ 不安定 | ○ | 5GB | ツール呼び出しに失敗する |
| qwen3:1.7b | ✗ 非対応 | ○ | 5GB | MCPツール呼び出し不可 |

```bash
# mistral-nemo のインストール（Windows PowerShell）
ollama pull mistral-nemo  # 約7.1GB
```

### ステップ1: CLIコマンドで登録（推奨）

`openclaw.json` を直接編集せず、CLIで登録するのが確実です:

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
# mistral-nemoをOpenClawに登録
openclaw config set models.providers.ollama.models   '[{"id":"mistral-nemo","name":"Mistral NeMo 12B","input":["text"],"contextWindow":128000,"maxTokens":4096}]'

# デフォルトモデルに設定
openclaw config set agents.defaults.model '{"primary":"ollama/mistral-nemo"}'

# 思考モードをオフ（誤動作防止）
openclaw config set agents.defaults.thinkingDefault '"off"'
```

### ステップ3: ゲートウェイ再起動・確認

```bash
openclaw gateway restart
openclaw status | grep -i "model\|session"
```

`mistral-nemo` が表示されれば成功です。

### openclaw.json に直接記述する場合

`~/.openclaw/openclaw.json` に追記する場合は **`mcp.servers`** キーを使います（`mcpServers` は無効）:

```json
{
  "mcp": {
    "servers": {
      "pc-system-info": {
        "command": "node",
        "args": [
          "/home/YourName/pc-system-info-mcp/dist/index.js"
        ]
      }
    }
  }
}
```

### WSL (Windows Subsystem for Linux) からの使用

WSL内で動かす場合、MCPサーバーは自動的にWSLを検出してWindows側の `powershell.exe` を呼び出します。  
`wslpath` コマンドが利用可能であることを確認してください。

```bash
# WSLでの登録例
openclaw mcp set pc-system-info '{
  "command": "node",
  "args": ["/home/YourName/pc-system-info-mcp/dist/index.js"]
}'
```


> ** ⚠️ WSLの注意事項**:  
> - `powershell.exe` がWSLのPATHに含まれている必要があります  
> - パスが見つからない場合: `/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe` をフルパスで指定  
> - Windows側のOllamaに接続するため、Ollamaは必ずWindows側で起動してください

### AGENTS.md へのツール使用指示追加（推奨）

ローカルLLMがMCPツールを確実に呼び出すよう、`~/.openclaw/workspace/AGENTS.md` に以下を追加することを推奨します:

```markdown
## PC System Info MCP Tools
When user asks about CPU, GPU, RAM, temperature, fan, disk, or network,
ALWAYS call the appropriate tool directly:
- get_cpu_info: CPU load and temperature
- get_gpu_info: GPU temperature and VRAM  
- get_ram_info: RAM usage
- get_fan_info: Fan speeds RPM
- get_disk_info: Disk usage and throughput
- get_network_info: Network adapters
- get_all_system_info: ALL metrics at once (recommended)
Do NOT answer from memory. Always call the tool first.
```

---

## 🌡️ 温度・ファン情報の取得（追加設定）

### Windows: CPU温度・ファン回転数

標準のWMIでは詳細なセンサー情報を取得できないため、以下のいずれかが必要です:

#### LibreHardwareMonitor（推奨・無料）
1. [LibreHardwareMonitor](https://github.com/LibreHardwareMonitor/LibreHardwareMonitor) をダウンロード
2. **管理者権限**で実行
3. メニュー: `Options → WMI Provider → Enable` にチェックを入れる
4. バックグラウンドで常駐させる

#### OpenHardwareMonitor（代替・無料）
1. [OpenHardwareMonitor](https://openhardwaremonitor.org/) をダウンロード
2. 管理者権限で実行してバックグラウンド常駐

> どちらも実行中でない場合、CPU温度・ファン情報は `null` になります。  
> NVIDIA GPU温度は nvidia-smi 経由のため、上記ソフト不要です。

#### ⚠️ Intel Core Ultra（Meteor Lake / Arrow Lake）世代の注意

Intel Core Ultra 125U / 165U / 185H などの第14世代以降のCPUは、2025年時点で  
LibreHardwareMonitor・OpenHardwareMonitor ともに **CPU Package温度を取得できません**。

代替として、同一ダイ上にある **内蔵GPU（Intel Arc Graphics）の温度を近似値**として取得します。  
その場合 `tempSource` に `"iGPU temp used as approximation (Intel Core Ultra)"` と明示されます。

| CPU世代 | CPU温度 | iGPU温度 | 取得方法 |
|---------|---------|---------|---------|
| Intel Core 12/13世代 | ✅ 取得可能 | - | LibreHardwareMonitor WMI |
| **Intel Core Ultra (Meteor Lake)** | ❌ 取得不可 | ❌ 取得不可 | OHM/LHM ともに未対応（2025年時点） |
| AMD Ryzen | ✅ 取得可能 | - | LibreHardwareMonitor WMI |

> **Intel Core Ultra 125U / 165U / 185H などのMeteor Lake世代**では、  
> OpenHardwareMonitor・LibreHardwareMonitor ともにCPU温度・iGPU温度を取得できません。  
> `temperatureC: null` + `tempNote` に理由が明示されます。  
> NVIDIA外付けGPUの温度は nvidia-smi 経由で正常取得できます。

### macOS: CPU温度

```bash
# Homebrewでインストール（Intel Mac）
brew install osx-cpu-temp

# 動作確認
osx-cpu-temp
```

**Apple Silicon (M1/M2/M3/M4) の場合:**  
`powermetrics` コマンドが使用されます（sudo権限が必要）。  
sudo なしの場合は温度が取得できませんが、他の情報は取得可能です。

### NVIDIA GPU（Windows / macOS 共通）

`nvidia-smi` がシステムPATHに存在する場合、自動的に使用されます。  
NVIDIAドライバーをインストールすると通常は自動的に追加されます。

確認コマンド:
```bash
# Windows PowerShell
nvidia-smi

# macOS / WSL
nvidia-smi
```

---

## 💡 使用例（Claudeとの会話）

```
ユーザー: PCの現在の温度を教えて

Claude: [get_all_system_info を実行]
        CPU温度: 65°C（負荷: 23%）
        GPU(RTX 4090)温度: 72°C（使用率: 45%、VRAM: 8GB/24GB使用中）
        ファン: CPUファン 1200RPM、ケースファン 800RPM

ユーザー: RAMの使用状況は？

Claude: [get_ram_info を実行]
        合計: 32GB DDR5
        使用中: 18.4GB (57.5%)
        空き: 13.6GB
        スロット: 2枚 × 16GB (6000MHz, G.Skill)
```

---

## 🔧 開発・カスタマイズ

### 開発モード（ビルド不要）

```bash
npm run dev
```

### ビルド

```bash
npm run build
```

### プロジェクト構成

```
pc-system-info-mcp/
├── src/
│   └── index.ts              # MCPサーバー本体
├── scripts/
│   ├── windows/
│   │   └── get-system-info.ps1  # Windows PowerShell スクリプト
│   └── macos/
│       └── get-system-info.sh   # macOS Bash スクリプト
├── docs/
│   ├── claude-desktop-windows.json
│   ├── claude-desktop-macos.json
│   └── openclaw-config.json
├── dist/                     # ビルド成果物（gitignore）
├── package.json
├── tsconfig.json
└── README.md
```

---

## 🔒 セキュリティ・権限

### Windows PowerShell 実行ポリシー

初回実行時にエラーが出る場合、PowerShellをAdministratorで開いて実行:

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

### macOS 権限

sudo なしでは一部センサー情報（AppleSilicon温度等）が取得できません。  
管理者権限不要な情報は通常権限で取得されます。

### WMIアクセス権（Windows）

LibreHardwareMonitor のWMIプロバイダーへのアクセスに管理者権限が必要な場合があります。

---

## ❓ トラブルシューティング

### "Script not found" エラー

```bash
# ビルドを実行してdist/を生成する
npm run build
```

### Windows: "execution policy" エラー

```powershell
# PowerShellを管理者で開いて実行
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

### macOS: "permission denied" エラー

```bash
chmod +x scripts/macos/get-system-info.sh
```

### WSL: "powershell.exe not found" エラー

```bash
# フルパスを確認
ls /mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe

# 環境変数PATHにWindowsパスが含まれているか確認
echo $PATH | grep -i windows
```

WSL2でWindowsのパスが含まれていない場合、`/etc/wsl.conf` に追加:
```ini
[interop]
appendWindowsPath = true
```

### CPU/ファン温度が null になる（Windows）

LibreHardwareMonitor または OpenHardwareMonitor を:
1. **管理者権限**で起動
2. WMI Provider を有効化
3. バックグラウンドで常駐させた状態で再試行

### nvidia-smi が見つからない（GPU温度なし）

```powershell
# Windows: NVIDIAドライバーの再インストール後
where nvidia-smi

# PATHに追加する場合
$env:PATH += ";C:\Program Files\NVIDIA Corporation\NVSMI"
```

---

## ❓ OpenClaw トラブルシューティング

### `Unrecognized key: "mcpServers"` エラー

OpenClaw では Claude Desktop 形式の `mcpServers` キーは使用できません。  
CLIコマンドで登録してください:

```bash
openclaw mcp set pc-system-info '{
  "command": "node",
  "args": ["/home/YourName/pc-system-info-mcp/dist/index.js"]
}'
openclaw gateway restart
```

### ツールを呼び出さず 엉뚱 のような返答をする

ローカルLLMがMCPツールを無視して返答する場合:

1. **モデルを mistral-nemo に切り替える**（最も効果的）
```bash
ollama pull mistral-nemo
openclaw config set agents.defaults.model '{"primary":"ollama/mistral-nemo"}'
openclaw gateway restart
```

2. **AGENTS.md にツール使用を明示する**
```bash
cat >> ~/.openclaw/workspace/AGENTS.md << 'AGEOF'

## PC System Info MCP Tools
When user asks about CPU, GPU, RAM, temperature, fan, disk, or network,
ALWAYS call the appropriate MCP tool. Do NOT answer from memory.
- get_cpu_info, get_gpu_info, get_ram_info, get_fan_info
- get_disk_info, get_network_info, get_all_system_info
AGEOF
```

3. **英語で明示的に指示して試してみる**
```
Use get_all_system_info tool and show the result.
```

### Tool output が返ってこない（タイムアウト）

PowerShellの起動に数秒かかるため、OpenClawのMCPタイムアウトを延長:

```bash
openclaw config set mcp.sessionIdleTtlMs 300000
openclaw gateway restart
```

### `model not allowed` エラー

OllamaのモデルをOpenClawに明示的に登録する必要があります:

```bash
openclaw config set models.providers.ollama.models   '[{"id":"mistral-nemo","name":"Mistral NeMo 12B","input":["text"],"contextWindow":128000,"maxTokens":4096}]'
```

### セッションが古いモデルを使い続ける

```bash
# セッションをリセットしてモデルを反映
openclaw gateway restart
# ダッシュボードで /new と入力して新しいセッションを開始
```

---

## 📝 Windows技術詳細

### 使用API（WMIC廃止後の代替）

| 廃止（WMIC） | 代替（Get-CimInstance） |
|-------------|------------------------|
| `wmic cpu get ...` | `Get-CimInstance Win32_Processor` |
| `wmic memorychip get ...` | `Get-CimInstance Win32_PhysicalMemory` |
| `wmic diskdrive get ...` | `Get-CimInstance Win32_DiskDrive` |
| `wmic path win32_VideoController get ...` | `Get-CimInstance Win32_VideoController` |
| `wmic os get ...` | `Get-CimInstance Win32_OperatingSystem` |

### センサー情報の取得元

```
CPU温度・ファン回転数:
  1. root/LibreHardwareMonitor (LibreHardwareMonitor)
  2. root/OpenHardwareMonitor  (OpenHardwareMonitor)  
  3. root/WMI MSAcpi_ThermalZoneTemperature (一部環境のみ)

GPU情報 (NVIDIA):
  nvidia-smi コマンド（ドライバー付属）

GPU情報 (AMD/Intel):
  Get-CimInstance Win32_VideoController

ディスクI/O・ネットワークスループット:
  Get-Counter パフォーマンスカウンター
```

---

## 📄 ライセンス

Apache License Version 2.0 - 詳細は [LICENSE](LICENSE) を参照

Copyright 2026　岩本 剛　All rights reserved.

---

## 🤝 コントリビュート

Issue・Pull Request 歓迎です。

1. Fork する
2. Feature branch を作成: `git checkout -b feature/your-feature`
3. Commit: `git commit -m 'Add your feature'`
4. Push: `git push origin feature/your-feature`
5. Pull Request を作成

---

## 📚 参考資料

- [WMIC の Windows からの削除について (Microsoft)](https://support.microsoft.com/ja-jp/topic/windows-%E7%AE%A1%E7%90%86%E3%82%A4%E3%83%B3%E3%82%B9%E3%83%88%E3%83%AB%E3%83%A1%E3%83%B3%E3%83%86%E3%83%BC%E3%82%B7%E3%83%A7%E3%83%B3-%E3%82%B3%E3%83%9E%E3%83%B3%E3%83%89-%E3%83%A9%E3%82%A4%E3%83%B3-wmic-%E3%81%AE-windows-%E3%81%8B%E3%82%89%E3%81%AE%E5%89%8A%E9%99%A4-e9e83c7f-4992-477f-ba1d-96f694b8665d)
- [Model Context Protocol (MCP) 公式](https://modelcontextprotocol.io/)
- [LibreHardwareMonitor](https://github.com/LibreHardwareMonitor/LibreHardwareMonitor)
- [Claude Desktop MCP Documentation](https://docs.anthropic.com/en/docs/claude-code/overview)
