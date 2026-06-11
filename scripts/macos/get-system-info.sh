#!/usr/bin/env bash
# macOS System Info Collector
# Uses system_profiler, sysctl, vm_stat, df, ifconfig, and nvidia-smi (if available)
# Compatible with macOS 12 Monterey+

set -euo pipefail

CATEGORY="${1:-all}"

# --- JSON helpers ---------------------------------------------------------
# Escape a value for safe embedding inside a JSON string literal.
# Hostnames, model names, GPU names etc. may contain quotes/backslashes,
# which would otherwise break the hand-built JSON.
json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\000-\037'
}

# Print the value if it is a plain number, otherwise print "null".
# Protects against non-numeric output (e.g. "[N/A]" from nvidia-smi) and
# avoids set -e aborts on numeric tests.
num_or_null() {
  if [[ "${1:-}" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then printf '%s' "$1"; else printf 'null'; fi
}

get_overview() {
  local hostname product os_ver build kern_ver uptime_s uptime_h boot_time tz
  hostname=$(scutil --get ComputerName 2>/dev/null || hostname)
  product=$(system_profiler SPHardwareDataType 2>/dev/null | awk -F': ' '/Model Name/{print $2}' | xargs)
  os_ver=$(sw_vers -productVersion)
  build=$(sw_vers -buildVersion)
  kern_ver=$(uname -r)
  boot_time=$(sysctl -n kern.boottime | awk -F'[= ,}]' '{print $5}')
  local now; now=$(date +%s)
  uptime_s=$(( now - boot_time ))
  uptime_h=$(awk "BEGIN{printf \"%.2f\", $uptime_s/3600}")
  tz=$(readlink /etc/localtime | sed 's|.*/zoneinfo/||')
  local boot_str; boot_str=$(date -r "$boot_time" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "N/A")
  local manufacturer; manufacturer="Apple Inc."
  local arch; arch=$(uname -m)
  local serial; serial=$(system_profiler SPHardwareDataType 2>/dev/null | awk -F': ' '/Serial Number/{print $2}' | xargs)

  hostname=$(json_escape "$hostname")
  product=$(json_escape "$product")
  serial=$(json_escape "$serial")

  cat <<EOF
"overview":{"hostname":"${hostname}","os":"macOS ${os_ver}","osVersion":"${os_ver}","buildNumber":"${build}","kernelVersion":"${kern_ver}","architecture":"${arch}","manufacturer":"${manufacturer}","model":"${product}","serialNumber":"${serial}","uptimeHours":${uptime_h},"lastBoot":"${boot_str}","timezone":"${tz}","timestamp":"$(date '+%Y-%m-%d %H:%M:%S')"}
EOF
}

get_cpu() {
  local name cores logical freq load temp temp_source
  name=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo "Unknown")
  cores=$(sysctl -n hw.physicalcpu 2>/dev/null || echo 0)
  logical=$(sysctl -n hw.logicalcpu 2>/dev/null || echo 0)
  freq=$(sysctl -n hw.cpufrequency_max 2>/dev/null || echo 0)
  local freq_mhz=0
  if [[ "$freq" =~ ^[0-9]+$ ]] && [ "$freq" -gt 0 ]; then freq_mhz=$(( freq / 1000000 )); fi

  # CPU usage via top (1 sample)
  load=$(top -l 1 -n 0 2>/dev/null | awk '/CPU usage/{gsub(/%/,""); print 100-$NF}' | head -1)
  load=$(num_or_null "$load")

  # Temperature: Apple Silicon via powermetrics (needs sudo), Intel via osx-cpu-temp or iStatistica
  temp="null"
  temp_source="null"

  if command -v osx-cpu-temp &>/dev/null; then
    local raw; raw=$(osx-cpu-temp 2>/dev/null | grep -oE '[0-9]+\.?[0-9]*')
    [ -n "$raw" ] && temp="$raw" && temp_source="\"osx-cpu-temp\""
  fi

  # Apple Silicon: try powermetrics (requires sudo - may not work without it)
  if [ "$temp" = "null" ] && [ "$(uname -m)" = "arm64" ]; then
    local pm_out; pm_out=$(sudo -n powermetrics --samplers smc -n 1 -i 100 2>/dev/null | grep -i "cpu die" | grep -oE '[0-9]+\.?[0-9]*' | head -1)
    [ -n "$pm_out" ] && temp="$pm_out" && temp_source="\"powermetrics\""
  fi

  cat <<EOF
"cpu":{"name":"$(json_escape "$name")","cores":${cores},"logicalCores":${logical},"maxClockMHz":${freq_mhz},"load":${load},"temperatureC":${temp},"tempSource":${temp_source}}
EOF
}

get_gpu() {
  local gpus="["

  # NVIDIA (eGPU or old Mac Pro)
  if command -v nvidia-smi &>/dev/null; then
    while IFS=',' read -r name temp util vmem_used vmem_total fan power plimit core_clk mem_clk; do
      name=$(json_escape "$(echo "$name" | xargs)")
      gpus+=$(cat <<EOF
{"vendor":"NVIDIA","name":"${name}","temperatureC":$(num_or_null "$(echo "${temp:-}" | xargs)"),"utilizationPct":$(num_or_null "$(echo "${util:-}" | xargs)"),"vramUsedMB":$(num_or_null "$(echo "${vmem_used:-}" | xargs)"),"vramTotalMB":$(num_or_null "$(echo "${vmem_total:-}" | xargs)"),"fanSpeedPct":$(num_or_null "$(echo "${fan:-}" | xargs)"),"powerDrawW":$(num_or_null "$(echo "${power:-}" | xargs)"),"powerLimitW":$(num_or_null "$(echo "${plimit:-}" | xargs)"),"coreClockMHz":$(num_or_null "$(echo "${core_clk:-}" | xargs)"),"memClockMHz":$(num_or_null "$(echo "${mem_clk:-}" | xargs)"),"source":"nvidia-smi"},
EOF
      )
    done < <(nvidia-smi --query-gpu=name,temperature.gpu,utilization.gpu,memory.used,memory.total,fan.speed,power.draw,power.limit,clocks.current.graphics,clocks.current.memory --format=csv,noheader,nounits 2>/dev/null)
  fi

  # system_profiler for all GPUs
  local sp_out; sp_out=$(system_profiler SPDisplaysDataType 2>/dev/null)
  while IFS= read -r line; do
    if [[ "$line" =~ "Chipset Model:" ]]; then
      local gname; gname=$(echo "$line" | awk -F': ' '{print $2}' | xargs)
      local vram="null"
      local vendor_raw; vendor_raw=$(echo "$sp_out" | grep -A5 "$gname" | grep "Vendor:" | head -1 | awk -F': ' '{print $2}' | xargs)
      local vram_raw; vram_raw=$(echo "$sp_out" | grep -A10 "$gname" | grep -i "VRAM\|Total Number of Cores" | grep -i "VRAM" | head -1 | grep -oE '[0-9]+ (MB|GB)')
      if [ -n "$vram_raw" ]; then
        local vnum; vnum=$(echo "$vram_raw" | grep -oE '[0-9]+')
        local vunit; vunit=$(echo "$vram_raw" | grep -oE 'MB|GB')
        [ "$vunit" = "GB" ] && vram=$(( vnum * 1024 )) || vram="$vnum"
      fi
      local vendor="Unknown"
      [[ "$gname" =~ AMD|Radeon ]] && vendor="AMD"
      [[ "$gname" =~ Intel ]]      && vendor="Intel"
      [[ "$gname" =~ Apple ]]      && vendor="Apple"
      [[ "$gname" =~ NVIDIA ]]     && vendor="NVIDIA"

      # Skip if NVIDIA already captured
      [[ "$vendor" == "NVIDIA" ]] && continue

      gpus+="{\"vendor\":\"${vendor}\",\"name\":\"$(json_escape "$gname")\",\"vramTotalMB\":${vram},\"source\":\"system_profiler\"},"
    fi
  done <<< "$sp_out"

  # Remove trailing comma and close array
  gpus="${gpus%,}]"
  [ "$gpus" = "]" ] && gpus="[]"

  echo "\"gpu\":${gpus}"
}

get_ram() {
  local total_bytes avail_bytes used_bytes used_pct
  total_bytes=$(sysctl -n hw.memsize 2>/dev/null || echo 0)
  local total_gb; total_gb=$(awk "BEGIN{printf \"%.2f\", $total_bytes/1073741824}")

  # vm_stat for free/used
  local vm_stat_out; vm_stat_out=$(vm_stat 2>/dev/null)
  local page_size; page_size=$(echo "$vm_stat_out" | grep "page size" | grep -oE '[0-9]+' | tail -1)
  [ -z "$page_size" ] && page_size=16384

  local pages_free; pages_free=$(echo "$vm_stat_out" | awk '/Pages free/{gsub(/\./,""); print $3}')
  local pages_speculative; pages_speculative=$(echo "$vm_stat_out" | awk '/Pages speculative/{gsub(/\./,""); print $3}')
  pages_free=$(( ${pages_free:-0} + ${pages_speculative:-0} ))
  local free_bytes=$(( pages_free * page_size ))
  local free_gb; free_gb=$(awk "BEGIN{printf \"%.2f\", $free_bytes/1073741824}")
  local used_bytes_val=$(( total_bytes - free_bytes ))
  local used_gb; used_gb=$(awk "BEGIN{printf \"%.2f\", $used_bytes_val/1073741824}")
  local used_pct_val; used_pct_val=$(awk "BEGIN{printf \"%.1f\", ($used_bytes_val/$total_bytes)*100}")

  # DIMM info
  local slots_json="["
  while IFS= read -r line; do
    local sz spd mfr type
    sz=$(echo "$line" | grep -oE '[0-9]+ GB' | head -1 | grep -oE '[0-9]+')
    spd=$(system_profiler SPMemoryDataType 2>/dev/null | grep -A5 "$line" | grep "Speed" | grep -oE '[0-9]+' | head -1)
    mfr=$(system_profiler SPMemoryDataType 2>/dev/null | grep -A5 "$line" | grep "Manufacturer" | awk -F': ' '{print $2}' | xargs)
    type=$(system_profiler SPMemoryDataType 2>/dev/null | grep -A5 "$line" | grep "Type" | awk -F': ' '{print $2}' | xargs)
    [ -n "$sz" ] && slots_json+="{\"capacityGB\":${sz},\"speedMHz\":${spd:-null},\"manufacturer\":\"$(json_escape "${mfr:-Unknown}")\",\"type\":\"$(json_escape "${type:-Unknown}")\"},"
  done < <(system_profiler SPMemoryDataType 2>/dev/null | grep "Size:" | awk -F': ' '{print $2}')

  slots_json="${slots_json%,}]"
  [ "$slots_json" = "]" ] && slots_json="[]"

  # Apple Silicon unified memory note
  local is_unified="false"
  [[ "$(uname -m)" == "arm64" ]] && is_unified="true"

  echo "\"ram\":{\"totalGB\":${total_gb},\"availableGB\":${free_gb},\"usedGB\":${used_gb},\"usedPct\":${used_pct_val},\"unifiedMemory\":${is_unified},\"slots\":${slots_json}}"
}

get_fans() {
  local fans="["

  # Try powermetrics (needs sudo)
  if command -v sudo &>/dev/null; then
    local pm; pm=$(sudo -n powermetrics --samplers smc -n 1 -i 100 2>/dev/null | grep -i "fan")
    while IFS= read -r line; do
      local fname; fname=$(echo "$line" | awk '{print $1}')
      local rpm; rpm=$(echo "$line" | grep -oE '[0-9]+' | tail -1)
      fans+="{\"name\":\"$(json_escape "$fname")\",\"rpm\":${rpm:-null},\"source\":\"powermetrics\"},"
    done <<< "$pm"
  fi

  # smcFanControl / iStatistica: check if smcFanControl CLI exists
  if command -v smcutil &>/dev/null; then
    local smc_out; smc_out=$(smcutil 2>/dev/null | grep -i fan)
    while IFS= read -r line; do
      local fname; fname=$(echo "$line" | awk '{print $1}')
      local rpm; rpm=$(echo "$line" | grep -oE '[0-9]+' | head -1)
      fans+="{\"name\":\"$(json_escape "$fname")\",\"rpm\":${rpm:-null},\"source\":\"smcutil\"},"
    done <<< "$smc_out"
  fi

  fans="${fans%,}]"
  [ "$fans" = "]" ] && fans="[]"
  echo "\"fan\":${fans}"
}

get_disk() {
  local drives="["
  while IFS= read -r line; do
    local mp size_raw avail_raw used_pct name
    mp=$(echo "$line" | awk '{print $9}')
    size_raw=$(echo "$line" | awk '{print $2}')
    avail_raw=$(echo "$line" | awk '{print $4}')
    used_pct=$(echo "$line" | awk '{print $5}' | tr -d '%')
    name=$(diskutil info "$mp" 2>/dev/null | grep "Device / Media Name:" | awk -F': ' '{print $2}' | xargs)
    local fs; fs=$(echo "$line" | awk '{print $1}' | cut -d/ -f1)
    [ -z "$name" ] && name="$mp"
    drives+="{\"mountpoint\":\"$(json_escape "$mp")\",\"totalGB\":$(num_or_null "${size_raw:-}"),\"freeGB\":$(num_or_null "${avail_raw:-}"),\"usedPct\":$(num_or_null "${used_pct:-}"),\"filesystem\":\"$(json_escape "$fs")\",\"label\":\"$(json_escape "$name")\"},"
  done < <(df -g 2>/dev/null | tail -n +2 | grep -v "tmpfs\|devfs\|map\|auto_home")

  drives="${drives%,}]"
  [ "$drives" = "]" ] && drives="[]"

  # IO stats via iostat
  local io_json="null"
  if command -v iostat &>/dev/null; then
    local io_out; io_out=$(iostat -d 1 2 2>/dev/null | tail -1)
    local kb_read; kb_read=$(echo "$io_out" | awk '{print $1}')
    local kb_write; kb_write=$(echo "$io_out" | awk '{print $2}')
    io_json="{\"readKBPerSec\":$(num_or_null "${kb_read:-}"),\"writeKBPerSec\":$(num_or_null "${kb_write:-}")}"
  fi

  echo "\"disk\":{\"drives\":${drives},\"io\":${io_json}}"
}

get_network() {
  local adapters="["
  while IFS= read -r iface; do
    local ip mac status
    ip=$(ipconfig getifaddr "$iface" 2>/dev/null || echo "")
    mac=$(ifconfig "$iface" 2>/dev/null | awk '/ether/{print $2}')
    status=$(ifconfig "$iface" 2>/dev/null | awk '/status/{print $2}')
    [ -z "$ip" ] && continue
    adapters+="{\"interface\":\"$(json_escape "$iface")\",\"ipAddress\":\"${ip}\",\"macAddress\":\"${mac:-N/A}\",\"status\":\"${status:-unknown}\"},"
  done < <(ifconfig -l 2>/dev/null | tr ' ' '\n' | grep -v "^lo")

  adapters="${adapters%,}]"
  [ "$adapters" = "]" ] && adapters="[]"

  # Throughput via netstat
  local throughput="[]"
  if command -v netstat &>/dev/null; then
    local net_out; net_out=$(netstat -i -b 2>/dev/null | tail -n +2)
    local t_arr="["
    while IFS= read -r line; do
      local iname ibytes obytes
      iname=$(echo "$line" | awk '{print $1}' | tr -d '*')
      ibytes=$(echo "$line" | awk '{print $7}')
      obytes=$(echo "$line" | awk '{print $10}')
      [[ "$iname" =~ ^lo ]] && continue
      [ -n "$iname" ] && t_arr+="{\"interface\":\"${iname}\",\"totalRecvBytes\":${ibytes:-0},\"totalSentBytes\":${obytes:-0}},"
    done <<< "$net_out"
    t_arr="${t_arr%,}]"
    [ "$t_arr" != "]" ] && throughput="$t_arr"
  fi

  echo "\"network\":{\"adapters\":${adapters},\"throughput\":${throughput}}"
}

# --- Main ---
echo -n "{"

case "$CATEGORY" in
  cpu)     echo -n "$(get_cpu)" ;;
  gpu)     echo -n "$(get_gpu)" ;;
  ram)     echo -n "$(get_ram)" ;;
  fan)     echo -n "$(get_fans)" ;;
  disk)    echo -n "$(get_disk)" ;;
  network) echo -n "$(get_network)" ;;
  overview)echo -n "$(get_overview)" ;;
  *)
    echo -n "$(get_overview),"
    echo -n "$(get_cpu),"
    echo -n "$(get_gpu),"
    echo -n "$(get_ram),"
    echo -n "$(get_fans),"
    echo -n "$(get_disk),"
    echo -n "$(get_network)"
    ;;
esac

echo "}"
