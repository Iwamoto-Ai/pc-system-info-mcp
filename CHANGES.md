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
- LibreHardwareMonitor / OpenHardwareMonitor の設定手順を削除し、WinRing0脆弱性(CVE-2020-14979)を理由とした不使用方針をセキュリティ節に明記。センサー取得元一覧も実装準拠に修正
- Intel Core Ultra の「iGPU温度近似」など未実装機能の記述を削除
- 対応表のファン(Windows)を「取得不可」に訂正
- 不要だった chmod / Set-ExecutionPolicy 手順を削除(bash経由実行・Bypass指定のため)
- OpenClaw / Hermes Agent の設定・トラブルシューティングを docs/openclaw.md / docs/hermes.md に分離
- 誤字修正(Discode→Discord、Line→LINE、WLS→WSL、韓国語混入の見出し)、重複注意書きの統合、リンク先修正
- 環境変数オプション(PRIVACY_MODE / MCP_LENIENT_MODE / CACHE_TTL_MS)の説明を追加

## 運用
- `.github/workflows/ci.yml` を追加(windows-latest / macos-latest でビルド+スクリプト出力のJSON妥当性検証)
- `.gitignore` を追加し dist/ をコミット対象外に(npm の `files` フィールドで配布物は担保)
- package.json に author / repository / files を追記
- 未使用の HWMonitor 連携スクリプトを scripts/windows/legacy/ に移動
