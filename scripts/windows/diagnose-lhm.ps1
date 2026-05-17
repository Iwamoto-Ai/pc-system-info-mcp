# diagnose-lhm.ps1
# LibreHardwareMonitor WMI接続の診断スクリプト
# PowerShellを管理者権限で実行してください

Write-Host "=== LibreHardwareMonitor WMI 診断 ===" -ForegroundColor Cyan
Write-Host ""

# 1. LHMプロセスが起動しているか確認
Write-Host "[1] LibreHardwareMonitor プロセス確認..." -ForegroundColor Yellow
$lhmProcess = Get-Process -Name "LibreHardwareMonitor" -ErrorAction SilentlyContinue
if ($lhmProcess) {
    Write-Host "    ✅ 実行中 (PID: $($lhmProcess.Id))" -ForegroundColor Green
} else {
    Write-Host "    ❌ 実行されていません" -ForegroundColor Red
    Write-Host "    → LibreHardwareMonitor.exe を管理者権限で起動してください" -ForegroundColor Red
}
Write-Host ""

# 2. WMI名前空間が存在するか確認
Write-Host "[2] WMI 名前空間の存在確認..." -ForegroundColor Yellow
$namespaces = @("root/LibreHardwareMonitor", "root/OpenHardwareMonitor")
foreach ($ns in $namespaces) {
    try {
        $test = Get-CimInstance -Namespace $ns -ClassName "__Namespace" -ErrorAction Stop | Select-Object -First 1
        Write-Host "    ✅ $ns  → 存在します" -ForegroundColor Green
    } catch {
        Write-Host "    ❌ $ns  → 見つかりません" -ForegroundColor Red
    }
}
Write-Host ""

# 3. Sensor クラスの確認
Write-Host "[3] Sensor クラス・データ確認..." -ForegroundColor Yellow
foreach ($ns in $namespaces) {
    try {
        $sensors = Get-CimInstance -Namespace $ns -ClassName Sensor -ErrorAction Stop
        if ($sensors) {
            Write-Host "    ✅ $ns\Sensor : $($sensors.Count) 件のセンサーが見つかりました" -ForegroundColor Green
            
            # CPU温度センサーを探す
            $cpuTemps = $sensors | Where-Object { $_.SensorType -eq "Temperature" -and $_.Name -match "CPU|Core|Package" }
            if ($cpuTemps) {
                Write-Host "    --- CPU温度センサー ---" -ForegroundColor Cyan
                foreach ($s in $cpuTemps) {
                    Write-Host "      Name: $($s.Name)  Value: $($s.Value)°C  Identifier: $($s.Identifier)" -ForegroundColor White
                }
            } else {
                Write-Host "    ⚠️  CPU温度センサーが見つかりません（全センサー種別を確認）" -ForegroundColor Yellow
                $types = $sensors | Select-Object -ExpandProperty SensorType -Unique
                Write-Host "    利用可能な SensorType: $($types -join ', ')" -ForegroundColor Gray
                $names = $sensors | Select-Object -ExpandProperty Name -First 10
                Write-Host "    センサー名サンプル: $($names -join ', ')" -ForegroundColor Gray
            }
        } else {
            Write-Host "    ⚠️  $ns\Sensor にデータがありません" -ForegroundColor Yellow
        }
    } catch {
        Write-Host "    ❌ $ns\Sensor : アクセスできません ($($_.Exception.Message))" -ForegroundColor Red
    }
}
Write-Host ""

# 4. 管理者権限の確認
Write-Host "[4] 実行権限の確認..." -ForegroundColor Yellow
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($isAdmin) {
    Write-Host "    ✅ 管理者権限で実行中" -ForegroundColor Green
} else {
    Write-Host "    ❌ 管理者権限なし" -ForegroundColor Red
    Write-Host "    → このスクリプトを管理者として実行してください" -ForegroundColor Red
    Write-Host "    → LibreHardwareMonitor も管理者として起動してください" -ForegroundColor Red
}
Write-Host ""

# 5. LHM設定確認ヒント
Write-Host "[5] LibreHardwareMonitor の設定確認事項:" -ForegroundColor Yellow
Write-Host "    ① LHMを管理者権限で起動する（右クリック → 管理者として実行）" -ForegroundColor White
Write-Host "    ② メニュー: Options → WMI Provider → Enable にチェック" -ForegroundColor White
Write-Host "    ③ メニュー: Options → Run On Windows Startup（任意）" -ForegroundColor White
Write-Host "    ④ 上記③の場合はスタートアップで管理者実行を設定する" -ForegroundColor White
Write-Host ""

# 6. 代替手段: MSAcpi_ThermalZoneTemperature
Write-Host "[6] 代替: MSAcpi_ThermalZoneTemperature の確認..." -ForegroundColor Yellow
try {
    $tz = Get-CimInstance -Namespace "root/WMI" -ClassName MSAcpi_ThermalZoneTemperature -ErrorAction Stop
    if ($tz) {
        foreach ($t in $tz) {
            $celsius = [math]::Round(($t.CurrentTemperature / 10) - 273.15, 1)
            Write-Host "    ✅ $($t.InstanceName): $celsius °C" -ForegroundColor Green
        }
    }
} catch {
    Write-Host "    ❌ MSAcpi 取得不可（管理者権限が必要な場合あり）" -ForegroundColor Red
}
Write-Host ""
Write-Host "=== 診断完了 ===" -ForegroundColor Cyan
