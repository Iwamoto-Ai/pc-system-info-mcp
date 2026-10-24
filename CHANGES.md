# v2.0.0 変更点

出力JSONの構造が変わるため、メジャーバージョンを上げています。

## 新機能(Windows)
- **CPU構成**: P-core / E-core / LP E-core の数とスレッド数(`cpu.topology`)、コア種別ごとの負荷%(`cpu.loadByCoreType`)。Windows は E-core と LP E-core を同じ効率クラスで報告するため、L3キャッシュを共有しないE-coreを LP E-core と判定
- **CPU詳細**: L2/L3キャッシュ(`cpu.cache`)、マイクロコード(`cpu.microcode`)、命令セット SSE3〜AVX-512F(`cpu.instructionSets`)、仮想化の有効状態(`cpu.virtualizationFirmwareEnabled`)
- **消費電力**: 新ツール `get_power_info`。Windows標準のパフォーマンスカウンター「Energy Meter」(RAPL)から CPUパッケージ・CPUコア・内蔵GPU・DRAM の消費電力(W)を取得。`cpu.power` にもパッケージ/コア電力を追加
- **内蔵GPU**: 使用率%・最も負荷の高いエンジン・共有/専用メモリ使用量(「GPU Engine」「GPU Adapter Memory」カウンター)、Intel内蔵GPUの消費電力(RAPL PP1)
- **NPU**: Intel AI Boost 等の NPU を検出し使用率%を取得(`gpu` 配列に `type: "npu"` で追加)
- いずれもカーネルドライバー・管理者権限・追加ソフト不要(ユーザーモードAPIとパフォーマンスカウンターのみ)

## 出力JSONの変更(破壊的変更)
- `gpu` 配列の各要素に `type`(`discrete` / `integrated` / `npu`)を追加。NPU が要素として加わる
- `cpu` に `topology` / `cache` / `microcode` / `instructionSets` / `loadByCoreType` / `power` 等を追加
- `all` カテゴリに `power` を追加
- `overview.architecture` をローカライズされない値(例: `AMD64`)に変更(日本語Windowsで文字化けしていたため)
- RAMの `type` は `SMBIOSMemoryType` を優先し、LPDDR4/LPDDR5 等も判定(従来はオンボードメモリが `Unknown` になっていた)

## プライバシー(既定動作の変更)
- `PRIVACY_MODE` を3段階に変更。**既定(未設定)で、シリアル番号・MAC・IP・DNS・ゲートウェイの末尾4文字以外をマスク**
  - `full`(または `1`): 従来どおり `[REDACTED]`
  - `off`(または `0`): マスクなし
- v1.x の `PRIVACY_MODE=1`(隠す)・`0`(表示)の意味はそのまま維持し、既存設定で保護が外れることはありません
- マスク処理を `src/privacy.ts` に分離し、テスト(`npm test`)を追加

## 性能・堅牢性
- パフォーマンスカウンターを全カテゴリ分まとめて1回だけサンプリング(`all` で約1秒)
- 日本語など非英語Windowsで、カウンターのパス名が翻訳されて返る場合にも動作するようフォールバックを追加
- ネットワークの送受信は別カウンターとして取得し、インターフェース名で結合

## 調査の結果、採用しなかったもの
- Intel Graphics Control Library(IGCL): Meteor Lake の内蔵GPUでは温度センサーが0件、テレメトリの温度も非対応であることを検証用プログラムで確認したため不採用
- CPUID命令による温度取得: CPUIDは温度センサーの有無を返すのみで、温度の読み出し(MSR)にはカーネルドライバーが必要なため不可

## CI
- `npm test` を追加
- Windowsスクリプトの全カテゴリについて JSON 妥当性を検証
- Windowsスクリプトが ASCII のみで書かれていることを検査(Windows PowerShell 5.1 の文字コード対策)

---

# v1.2.0 変更点

## 改善
- **Windowsファン情報**: `Win32_Fan` を誤った名前空間(root/WMI)で照会していた箇所を修正(正: root/cimv2)。`DesiredSpeed` があればRPMとして返し、取得不可時は理由を示す `note` を返すように変更
- **CPU負荷**: `Win32_Processor` の二重照会を解消し、マルチソケット環境(LoadPercentageが配列)で平均値を返すように修正
- **macOSスクリプト**: 手組みJSONに `json_escape` を導入(ホスト名・モデル名・GPU名等に `"` や `\` が含まれてもJSONが壊れない)。`num_or_null` で非数値(nvidia-smiの "[N/A]" 等)を null に正規化し、`set -e` 下での数値比較による異常終了を防止

## 性能改善
- **ネットワークスループット(Windows)**: インターフェイスごとの Get-Counter 呼び出し(N+1、各約1秒)を、全インターフェイス・送受信両カウンターの1回呼び出しに集約
- **結果キャッシュ**: 同一カテゴリへの連続呼び出しを TTL キャッシュ(既定3秒、`CACHE_TTL_MS` で変更可)と実行中リクエストへの合流で多重起動を防止

## 設計・セキュリティ
- **未知ツール名**: MCP仕様どおり `isError: true` のエラーを返すように変更。従来の「全情報フォールバック」は `MCP_LENIENT_MODE=1` でオプトイン
- **PRIVACY_MODE=1**: シリアル番号・MAC・IP・DNS・ゲートウェイを `[REDACTED]` にマスク(LINE/Discord経由のリモート利用向け)
- **execFile化**: シェル経由の exec を廃止し引数配列で直接起動(クオート処理・インジェクション懸念を排除)
- **バージョン単一化**: package.json(1.2.0)を唯一のソースとし、index.ts のハードコードを撤廃

## ドキュメント(READMEを実装と整合)
- clone URL のプレースホルダ(YourName)を実URLに修正
- LibreHardwareMonitor / OpenHardwareMonitor についての WinRing0脆弱性(CVE-2020-14979)を理由とした不使用方針をセキュリティ節に明記。センサー取得元一覧も実装準拠に修正
- Intel Core Ultra の「iGPU温度近似」など未実装機能の記述を削除
- 対応表のファン(Windows)を「取得不可」に訂正
- 不要だった chmod / Set-ExecutionPolicy 手順を削除(bash経由実行・Bypass指定のため)
- OpenClaw / Hermes Agent の設定・トラブルシューティングを docs/openclaw.md / docs/hermes.md に分離
- 重複注意書きの統合、リンク先修正
- 環境変数オプション(PRIVACY_MODE / MCP_LENIENT_MODE / CACHE_TTL_MS)の説明を追加

## 運用
- `.github/workflows/ci.yml` を追加(windows-latest / macos-latest でビルド+スクリプト出力のJSON妥当性検証)
- `.gitignore` を追加し dist/ をコミット対象外に(npm の `files` フィールドで配布物は担保)
- package.json に author / repository / files を追記

## その他
- 未使用の LibreHardwareMonitor / OpenHardwareMonitor 連携スクリプト（WinRing0脆弱性あり注意）は scripts/windows/caution/ に格納
