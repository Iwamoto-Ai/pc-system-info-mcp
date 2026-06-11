# PC System Info MCP Server

[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](https://www.apache.org/licenses/LICENSE-2.0)
[![Node.js](https://img.shields.io/badge/Node.js-18%2B-green.svg)](https://nodejs.org/)
[![Platform](https://img.shields.io/badge/Platform-Windows%20%7C%20macOS%20%7C%20WSL2-blue.svg)](https://github.com/Iwamoto-Ai/pc-system-info-mcp)
[![MCP](https://img.shields.io/badge/MCP-Compatible-purple.svg)](https://modelcontextprotocol.io/)

PCのシステム情報を取得する **Model Context Protocol (MCP) サーバー**です。
CPU/GPU稼働状況、RAM/VRAM、ディスク、ネットワーク情報を Claude Desktop、🦞OpenClaw、Hermes Agent から自然言語で確認できます。

プロンプト例: 「CPUとGPUの状況を教えて」など

🦞 OpenClaw と組み合わせれば、外出先から LINE や Discord で自宅PCの状況確認にも使えます。
**※リモート利用時は後述の [プライバシーモード](#-セキュリティプライバシー) の利用を推奨します。**

> **⚠️ 設計方針**
> - Windows の WMIC コマンドは廃止されたため使用せず、`Get-CimInstance`(PowerShell)を使用します。
> - LibreHardwareMonitor / OpenHardwareMonitor は **使用しません**(依存ドライバー WinRing0.sys に既知の脆弱性 CVE-2020-14979 があるため)。このため Windows での CPU温度・ファンRPM の取得には制約があります(下記の対応表を参照)。

---

## 📊 取得できる情報

| カテゴリ | 取得情報 | Windows | macOS |
| --- | --- | --- | --- |
| **システム概要** | OS・ホスト名・稼働時間・マザーボード・BIOS | ✅ | ✅ |
| **CPU** | 名称・コア数・クロック速度・負荷% | ✅ | ✅ |
| **CPU温度** | 温度°C | ⚠️ 一部環境のみ¹ | ⚠️ 要追加設定² |
| **GPU (NVIDIA)** | 名称・温度°C・使用率%・VRAM使用量・ファン速度%・消費電力W・クロック | ✅³ | ✅³ |
| **GPU (AMD/Intel/Apple)** | 名称・VRAM総量・ドライババージョン | ✅ | ✅ |
| **RAM** | 総容量・使用量・空き容量・使用率%・スロット情報 | ✅ | ✅ |
| **ファン回転数** | RPM | ❌ 取得不可⁴ | ⚠️ sudo必要⁵ |
| **ディスク** | モデル・容量・インターフェース・ボリューム使用量・読み書き速度 | ✅ | ✅ |
| **ネットワーク** | アダプター情報・IPアドレス・MAC・DNS・送受信スループット | ✅ | ✅ |

> ¹ `MSAcpi_ThermalZoneTemperature`(標準WMI)で取得します。対応はハードウェア依存で、Intel Core Ultra(Meteor Lake / Arrow Lake)世代を含む多くのPCでは取得できません。取得できない場合は `temperatureC: null` と理由を示す `tempNote` が返ります。
> ² Intel Mac: `brew install osx-cpu-temp`。Apple Silicon: `powermetrics`(sudo必要)。
> ³ `nvidia-smi`(NVIDIAドライバー付属)経由。追加ソフト不要です。
> ⁴ 標準WMIではコンシューマー向けマザーボードのファンRPMは公開されておらず、サードパーティのセンサーツールは上記の方針により使用しないため、現状取得できません。レスポンスには理由を示す `note` が含まれます。
> ⁵ `powermetrics` 経由(sudo必要)。

---

## 🛠️ 利用可能なMCPツール

| ツール名 | 説明 |
| --- | --- |
| `get_system_overview` | システム全体の概要 |
| `get_cpu_info` | CPU情報(負荷、温度は取得可能な環境のみ) |
| `get_gpu_info` | GPU情報(NVIDIAは完全テレメトリ) |
| `get_ram_info` | RAM使用状況・DIMMスロット |
| `get_fan_info` | ファン情報(取得可否と理由を含む) |
| `get_disk_info` | ストレージ情報・I/Oスループット |
| `get_network_info` | ネットワーク情報・スループット |
| `get_all_system_info` | **全情報を一括取得** |
| `get_server_info` | MCPサーバー自体の情報・設定状態 |

> ローカルLLMがツール名を間違えやすいことへの対策として、`cpu_info` や `get_memory` などの**別名(エイリアス)も受け付けます**。エイリアスはツール一覧には現れず、ローカルLLM救済専用です。

---

## 📋 必要条件

- **Node.js 18.0.0 以上**、Git
- **Windows**: Windows 10 21H1 以降(Windows 11 推奨)、PowerShell 5.1以上(標準付属)
- **macOS**: macOS 12 Monterey 以降
- **WSL2**: Windows側の情報を取得します(`powershell.exe` がWSLのPATHに必要)

OpenClaw / Hermes Agent と組み合わせる場合の要件・推奨モデル・設定は、それぞれ [docs/openclaw.md](docs/openclaw.md) / [docs/hermes.md](docs/hermes.md) を参照してください。

---

## 🚀 インストール

```bash
# 1. リポジトリのクローン
git clone https://github.com/Iwamoto-Ai/pc-system-info-mcp.git
cd pc-system-info-mcp

# 2. 依存パッケージのインストール
npm install

# 3. ビルド
npm run build
```

> macOSスクリプトは `bash` 経由で実行されるため、`chmod +x` は不要です。
> PowerShellスクリプトは `-ExecutionPolicy Bypass` 付きで起動されるため、通常は実行ポリシーの変更も不要です。

---

## ⚙️ Claude Desktop への設定

設定ファイルの場所:

| OS | パス |
| --- | --- |
| Windows | `%APPDATA%\Claude\claude_desktop_config.json` |
| macOS | `~/Library/Application Support/Claude/claude_desktop_config.json` |

Windows の設定例:

```json
{
  "mcpServers": {
    "pc-system-info": {
      "command": "node",
      "args": ["C:\\Users\\YourName\\pc-system-info-mcp\\dist\\index.js"]
    }
  }
}
```

macOS の設定例:

```json
{
  "mcpServers": {
    "pc-system-info": {
      "command": "node",
      "args": ["/Users/YourName/pc-system-info-mcp/dist/index.js"]
    }
  }
}
```

設定後、**Claude Desktop を再起動**してください。

OpenClaw への設定(`mcpServers` キーは使えません)は [docs/openclaw.md](docs/openclaw.md)、Hermes Agent(WSL)への設定は [docs/hermes.md](docs/hermes.md) を参照してください。

---

## 🔧 環境変数によるオプション

| 環境変数 | 既定値 | 説明 |
| --- | --- | --- |
| `PRIVACY_MODE` | `0` | `1` でシリアル番号・MACアドレス・IPアドレス・DNS・ゲートウェイを `[REDACTED]` にマスク |
| `MCP_LENIENT_MODE` | `0` | `1` で未知のツール名を `get_all_system_info` にフォールバック(ローカルLLM向け)。既定ではMCP仕様どおりエラーを返します |
| `CACHE_TTL_MS` | `3000` | 結果キャッシュの有効期間(ミリ秒)。同一カテゴリの連続呼び出しでスクリプトを多重起動しません |

設定例(Claude Desktop):

```json
{
  "mcpServers": {
    "pc-system-info": {
      "command": "node",
      "args": ["/Users/YourName/pc-system-info-mcp/dist/index.js"],
      "env": { "PRIVACY_MODE": "1" }
    }
  }
}
```

---

## 🌡️ 温度の取得について

### Windows

標準WMI(`MSAcpi_ThermalZoneTemperature`)のみを使用します。対応ハードウェアは限られており、取得できない場合は `temperatureC: null` と `tempNote` が返ります。

Intel Core Ultra(Meteor Lake / Arrow Lake)世代は標準WMIで温度を公開しないため取得できません。NVIDIA外付けGPUの温度は `nvidia-smi` 経由で正常に取得できます。

> LibreHardwareMonitor / OpenHardwareMonitor を使えばCPU温度・ファンRPMを取得できますが、依存ドライバー WinRing0.sys の脆弱性(CVE-2020-14979)のため本プロジェクトでは対応していません。

### macOS

```bash
# Intel Mac
brew install osx-cpu-temp
```

Apple Silicon (M1/M2/M3/M4) では `powermetrics`(sudo必要)が使用されます。sudoなしでは温度は取得できませんが、他の情報は取得可能です。

### NVIDIA GPU(Windows / macOS / WSL 共通)

`nvidia-smi` がPATHにあれば自動的に使用されます(NVIDIAドライバーに付属)。

```powershell
# 動作確認
nvidia-smi
```

---

## 💡 使用例(Claudeとの会話)

```
ユーザー: PCの現在の温度を教えて

Claude: [get_all_system_info を実行]
        CPU温度: 65°C(負荷: 23%)
        GPU(RTX 4090)温度: 72°C(使用率: 45%、VRAM: 8GB/24GB使用中)

ユーザー: RAMの使用状況は?

Claude: [get_ram_info を実行]
        合計: 32GB DDR5
        使用中: 18.4GB (57.5%)
        空き: 13.6GB
        スロット: 2枚 × 16GB (6000MHz, G.Skill)
```

---

## 🔧 開発・カスタマイズ

```bash
npm run dev     # 開発モード(ビルド不要)
npm run build   # ビルド
```

プロジェクト構成:

```
pc-system-info-mcp/
├── src/
│   └── index.ts                    # MCPサーバー本体
├── scripts/
│   ├── windows/
│   │   ├── get-system-info.ps1     # Windows PowerShell スクリプト
│   │   └── diagnose-lhm.ps1        # (参考) センサーWMI診断スクリプト
│   └── macos/
│       └── get-system-info.sh      # macOS Bash スクリプト
├── docs/
│   ├── openclaw.md                 # OpenClaw 設定ガイド
│   ├── hermes.md                   # Hermes Agent 設定ガイド
│   ├── claude-desktop-windows.json
│   ├── claude-desktop-macos.json
│   └── openclaw-config.json
├── .github/workflows/ci.yml        # CI(ビルド+スクリプト出力のJSON検証)
├── dist/                           # ビルド成果物(gitignore)
├── package.json
├── tsconfig.json
└── README.md
```

---

## 🔒 セキュリティ・プライバシー

**返却データに含まれる識別情報**: ホスト名、内部IPアドレス、MACアドレス、DNS/ゲートウェイ、ディスクおよび本体のシリアル番号が含まれます。LINE・Discord等の外部メッセンジャー経由でリモート利用する場合は、`PRIVACY_MODE=1` でこれらをマスクすることを強く推奨します。

**サードパーティドライバー不使用**: WinRing0.sys 脆弱性(CVE-2020-14979)を避けるため、カーネルドライバーに依存するセンサーツールは使用しません。すべて標準API(CIM/WMI、nvidia-smi、sysctl等)で取得します。

**PowerShell実行ポリシー**: サーバーは `-ExecutionPolicy Bypass -NoProfile -NonInteractive` でスクリプト単体を起動します。システムの実行ポリシー変更は不要です。

---

## ❓ トラブルシューティング

### nvidia-smi が見つからない(GPU温度なし)

```powershell
# Windows: NVIDIAドライバー(最新版推奨)の再インストール後
where nvidia-smi
```

### WSL環境で nvidia-smi の情報にアクセスできない

GPUドライバーが古くないか確認し(最新化後はPC再起動)、WSL2のGPUパススルーが機能しているかを `nvidia-smi` の実行で確認してください。必要に応じてNVIDIAのWSL2専用CUDAリポジトリからツールキットをインストールし、`PATH` / `LD_LIBRARY_PATH` を設定します(詳細は[NVIDIAのWSLドキュメント](https://docs.nvidia.com/cuda/wsl-user-guide/index.html)参照)。

### "Script not found" エラー

```bash
npm run build   # dist/ を生成
```

### WSL: "powershell.exe not found" エラー

```bash
# フルパスを確認
ls /mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe

# PATHにWindowsパスが含まれているか確認
echo $PATH | grep -i windows
```

含まれていない場合、`/etc/wsl.conf` に追加して WSL を再起動:

```ini
[interop]
appendWindowsPath = true
```

### CPU温度・ファンRPMが null になる(Windows)

仕様です。上記「📊 取得できる情報」の注記を参照してください。レスポンスの `tempNote` / `note` に理由が示されます。

OpenClaw固有のトラブルシューティングは [docs/openclaw.md](docs/openclaw.md) を参照してください。

---

## 📝 Windows技術詳細

### 使用API(WMIC廃止後の代替)

| 廃止(WMIC) | 代替(Get-CimInstance) |
| --- | --- |
| `wmic cpu get ...` | `Get-CimInstance Win32_Processor` |
| `wmic memorychip get ...` | `Get-CimInstance Win32_PhysicalMemory` |
| `wmic diskdrive get ...` | `Get-CimInstance Win32_DiskDrive` |
| `wmic path win32_VideoController get ...` | `Get-CimInstance Win32_VideoController` |
| `wmic os get ...` | `Get-CimInstance Win32_OperatingSystem` |

### センサー情報の取得元

```
CPU温度:
  root/WMI MSAcpi_ThermalZoneTemperature(一部環境のみ)

ファン:
  Win32_Fan(root/cimv2。RPMはほとんどの環境で非公開)

GPU情報 (NVIDIA):
  nvidia-smi コマンド(ドライバー付属)

GPU情報 (AMD/Intel):
  Get-CimInstance Win32_VideoController

ディスクI/O・ネットワークスループット:
  Get-Counter パフォーマンスカウンター(全インターフェース一括取得)
```

---

## 📄 ライセンス

Apache License Version 2.0 - 詳細は [LICENSE](LICENSE) を参照

Copyright 2026 岩本 剛 All rights reserved.

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

- [WMIC の Windows からの削除について (Microsoft)](https://support.microsoft.com/ja-jp/topic/e9e83c7f-4992-477f-ba1d-96f694b8665d)
- [Model Context Protocol (MCP) 公式](https://modelcontextprotocol.io/)
- [WinRing0 脆弱性 CVE-2020-14979](https://nvd.nist.gov/vuln/detail/CVE-2020-14979)
- [Claude Desktop での MCP 利用 (Anthropic)](https://support.claude.com/ja/articles/10065433)
- [🦞OpenClaw](https://openclaw.ai/)
- [Hermes-Agent](https://hermes-agent.nousresearch.com/docs/)
