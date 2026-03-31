#!/usr/bin/env bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# /usr/local/bin/nas-dashboard.sh
# NAS Monitor — универсальный дашборд с историей метрик и графиками
# Запускается через cron каждую минуту от root

OUTPUT="/var/www/nas-dashboard/index.html"
METRICS_CSV="/var/www/nas-dashboard/metrics.csv"
CSV_MAX_LINES=10080   # 7 суток × 1440 мин
UPDATED=$(date '+%d.%m.%Y %H:%M:%S')
TS=$(date '+%Y-%m-%d %H:%M')

mkdir -p "$(dirname "$OUTPUT")"

# ===========================================================================
# Системные метрики
# ===========================================================================

UPTIME_STR=$(uptime -p | sed 's/up //')
LOAD=$(cut -d' ' -f1-3 /proc/loadavg)

CPU_IDLE=$(vmstat 1 1 | awk 'NR==3{print $15}')
CPU_IDLE=${CPU_IDLE:-50}
CPU_USED=$((100 - CPU_IDLE))

RAM_TOTAL=$(free -m | awk 'NR==2{print $2}')
RAM_USED=$(free -m  | awk 'NR==2{print $3}')
RAM_FREE=$(free -m  | awk 'NR==2{print $4}')
RAM_TOTAL=${RAM_TOTAL:-1}
RAM_PCT=$((RAM_USED * 100 / RAM_TOTAL))

SWAP_TOTAL=$(free -m | awk 'NR==3{print $2}')
SWAP_USED=$(free -m  | awk 'NR==3{print $3}')
SWAP_TOTAL=${SWAP_TOTAL:-0}
SWAP_USED=${SWAP_USED:-0}
[ "$SWAP_TOTAL" -gt 0 ] && SWAP_PCT=$((SWAP_USED * 100 / SWAP_TOTAL)) || SWAP_PCT=0

# Температура CPU — реальные ядра, не acpitz
CPU_TEMP=""
if command -v sensors &>/dev/null; then
    CPU_TEMP=$(sensors 2>/dev/null \
        | grep -E "^(Core 0|Tdie|CPU Temp):" \
        | head -1 \
        | grep -oP '[+-]\K[0-9]+\.[0-9]+' \
        | head -1)
    if [ -z "$CPU_TEMP" ]; then
        CPU_TEMP=$(sensors 2>/dev/null \
            | grep -E "^Core [0-9]+:" \
            | grep -oP '[+-]\K[0-9]+\.[0-9]+' \
            | awk '{s+=$1; n++} END{if(n>0) printf "%.1f", s/n}')
    fi
fi

# Температура GPU (Intel integrated / дискретная / hwmon)
GPU_TEMP=""
# Попытка 1: Intel/AMD через hwmon sysfs
for f in /sys/class/drm/card0/device/hwmon/hwmon*/temp1_input \
          /sys/class/drm/card1/device/hwmon/hwmon*/temp1_input; do
    [ -r "$f" ] || continue
    val=$(cat "$f" 2>/dev/null)
    if [ -n "$val" ] && [ "$val" -gt 1000 ] 2>/dev/null; then
        GPU_TEMP=$((val / 1000))
        break
    fi
done
# Попытка 2: sensors (nvidia / amdgpu / radeon)
if [ -z "$GPU_TEMP" ] && command -v sensors &>/dev/null; then
    GPU_TEMP=$(sensors 2>/dev/null \
        | grep -iE "^(GPU|edge|junction|temp1):" \
        | grep -v "acpitz" \
        | head -1 \
        | grep -oP '[+-]\K[0-9]+\.[0-9]+' \
        | head -1)
fi
# Попытка 3: nvidia-smi
if [ -z "$GPU_TEMP" ] && command -v nvidia-smi &>/dev/null; then
    GPU_TEMP=$(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader 2>/dev/null | head -1 | tr -d ' ')
fi

# ===========================================================================
# Вспомогательные функции
# ===========================================================================

pct_cls() {
    local v=$1 w=${2:-70} c=${3:-90}
    if   [ "$v" -ge "$c" ] 2>/dev/null; then echo "critical"
    elif [ "$v" -ge "$w" ] 2>/dev/null; then echo "warn"
    else echo "ok"
    fi
}

bar() {
    local p=$1 c="ok"
    [ "$p" -ge 75 ] 2>/dev/null && c="warn"
    [ "$p" -ge 90 ] 2>/dev/null && c="critical"
    echo "<div class=\"bar-wrap\"><div class=\"bar $c\" style=\"width:${p}%\"></div></div>"
}

# ===========================================================================
# Автоопределение дисков и флага smartctl
# ===========================================================================

detect_disks() {
    lsblk -dpno NAME,TYPE 2>/dev/null | awk '$2=="disk"{print $1}'
}

probe_smart() {
    local dev=$1
    local flags=("" "sat,12" "sat,16" "sat" "usbsunplus" "usbjmicron" "usbcypress")
    for flag in "${flags[@]}"; do
        local raw
        if [ -n "$flag" ]; then
            raw=$(/usr/sbin/smartctl -d "$flag" -a "$dev" 2>/dev/null)
        else
            raw=$(/usr/sbin/smartctl -a "$dev" 2>/dev/null)
        fi
        if echo "$raw" | grep -q "overall-health"; then
            SMART_DATA="$raw"
            SMART_FLAG="$flag"
            return 0
        fi
    done
    SMART_DATA=""
    SMART_FLAG=""
    return 1
}

# ===========================================================================
# Парсинг SMART
# ===========================================================================

parse_attr() {
    echo "$1" | awk -v id="$2" '
        $1==id {
            val=$10
            sub(/[^0-9].*/, "", val)
            print val; exit
        }
    '
}

parse_temp() {
    local data="$1" temp
    temp=$(echo "$data" | awk '$1==194{val=$10; sub(/[^0-9].*/, "", val); print val; exit}')
    [ -z "$temp" ] && \
        temp=$(echo "$data" | awk '$1==190{val=$10; sub(/[^0-9].*/, "", val); print val; exit}')
    echo "$temp"
}

parse_status() {
    if   echo "$1" | grep -q "overall-health.*PASSED"; then echo "PASSED"
    elif echo "$1" | grep -q "overall-health.*FAILED"; then echo "FAILED"
    else echo "UNKNOWN"
    fi
}

parse_model() {
    echo "$1" | grep -E "^(Device Model|Model Number|Product):" \
        | head -1 | sed 's/.*: *//' | xargs
}

parse_ata_err() {
    echo "$1" | grep "ATA Error Count:" | grep -oP '\d+' | head -1
}

# ===========================================================================
# Pass 1: Зондируем все диски (не в subshell → ассоциативные массивы работают)
# ===========================================================================

declare -a ALL_DEVS=()
declare -A PROBED_DATA=()
declare -A PROBED_FLAGS=()
# Массивы для CSV (4 метрики на диск: temp, r5, r197, r199)
declare -a CSV_TEMP=()
declare -a CSV_R5=()
declare -a CSV_R197=()
declare -a CSV_R199=()

while IFS= read -r dev; do
    ALL_DEVS+=("$dev")
    probe_smart "$dev"
    PROBED_DATA["$dev"]="$SMART_DATA"
    PROBED_FLAGS["$dev"]="$SMART_FLAG"
    CSV_TEMP+=("$(parse_temp "$SMART_DATA")")
    CSV_R5+=("$(parse_attr  "$SMART_DATA" 5)")
    CSV_R197+=("$(parse_attr "$SMART_DATA" 197)")
    CSV_R199+=("$(parse_attr "$SMART_DATA" 199)")
done < <(detect_disks)

# ===========================================================================
# CSV: миграция схемы + запись + обрезка
# ===========================================================================

# Строим ожидаемый заголовок (меняется если добавить диск)
expected_header="timestamp,cpu_temp,gpu_temp,cpu_load,ram_pct"
for dev in "${ALL_DEVS[@]}"; do
    ds="${dev//\//}"   # /dev/sda → devsda
    expected_header="${expected_header},${ds}_temp,${ds}_r5,${ds}_r197,${ds}_r199"
done

# Если заголовок не совпадает — архивируем старый CSV и начинаем заново
if [ -f "$METRICS_CSV" ]; then
    actual_header=$(head -1 "$METRICS_CSV" 2>/dev/null)
    if [ "$actual_header" != "$expected_header" ]; then
        mv "$METRICS_CSV" "${METRICS_CSV%.csv}_backup_$(date '+%Y%m%d_%H%M%S').csv"
    fi
fi

# Создаём новый с заголовком
[ ! -f "$METRICS_CSV" ] && echo "$expected_header" > "$METRICS_CSV"

# Дописываем строку данных
csv_line="$TS,${CPU_TEMP:-},${GPU_TEMP:-},${CPU_USED},${RAM_PCT}"
for i in "${!ALL_DEVS[@]}"; do
    csv_line="${csv_line},${CSV_TEMP[$i]:-},${CSV_R5[$i]:-},${CSV_R197[$i]:-},${CSV_R199[$i]:-}"
done
echo "$csv_line" >> "$METRICS_CSV"

# Держим заголовок + последние CSV_MAX_LINES строк данных
{
    head -1 "$METRICS_CSV"
    tail -n +2 "$METRICS_CSV" | tail -n "$CSV_MAX_LINES"
} > "${METRICS_CSV}.tmp" && mv "${METRICS_CSV}.tmp" "$METRICS_CSV"

# ===========================================================================
# Данные для графиков: последние 1440 строк (24 часа)
# ===========================================================================

CHART_HAS_DATA=0
CHART_LABELS=""
CHART_CPU_TEMP_DATA=""
CHART_GPU_TEMP_DATA=""
CHART_CPU_LOAD_DATA=""
CHART_RAM_DATA=""
CHART_DISK_TEMP_DATASETS="[]"
CHART_DISK_R5_DATASETS="[]"
CHART_DISK_R199_DATASETS="[]"

PEAK_CPU_TEMP_VAL="" ; PEAK_CPU_TEMP_TIME=""
PEAK_GPU_TEMP_VAL="" ; PEAK_GPU_TEMP_TIME=""
PEAK_CPU_LOAD_VAL="" ; PEAK_CPU_LOAD_TIME=""
PEAK_RAM_VAL=""      ; PEAK_RAM_TIME=""
declare -a PEAK_DISK_TEMP_VAL=()
declare -a PEAK_DISK_TEMP_TIME=()

if [ -f "$METRICS_CSV" ] && [ -s "$METRICS_CSV" ]; then
    CSV_DATA=$(tail -n +2 "$METRICS_CSV" | tail -n 1440)
    LINE_COUNT=$(echo "$CSV_DATA" | grep -c '^' 2>/dev/null || echo 0)

    if [ "${LINE_COUNT:-0}" -gt 2 ]; then
        CHART_HAS_DATA=1

        CHART_LABELS=$(echo "$CSV_DATA" \
            | awk -F',' '{printf "\"%s\",",$1}' | sed 's/,$//')
        # col2=cpu_temp, col3=gpu_temp, col4=cpu_load, col5=ram_pct
        CHART_CPU_TEMP_DATA=$(echo "$CSV_DATA" \
            | awk -F',' '{print ($2=="" ? "null" : $2)}' | tr '\n' ',' | sed 's/,$//')
        CHART_GPU_TEMP_DATA=$(echo "$CSV_DATA" \
            | awk -F',' '{print ($3=="" ? "null" : $3)}' | tr '\n' ',' | sed 's/,$//')
        CHART_CPU_LOAD_DATA=$(echo "$CSV_DATA" \
            | awk -F',' '{print ($4=="" ? "null" : $4)}' | tr '\n' ',' | sed 's/,$//')
        CHART_RAM_DATA=$(echo "$CSV_DATA" \
            | awk -F',' '{print ($5=="" ? "null" : $5)}' | tr '\n' ',' | sed 's/,$//')

        # Диски: начиная с col6, шаг 4: temp(+0), r5(+1), r197(+2), r199(+3)
        DISK_COLORS=("#ff9800" "#7c4dff" "#00bcd4" "#4caf50")
        CHART_DISK_TEMP_DATASETS="["
        CHART_DISK_R5_DATASETS="["
        CHART_DISK_R199_DATASETS="["

        for i in "${!ALL_DEVS[@]}"; do
            base_col=$((6 + i * 4))
            col_temp=$base_col
            col_r5=$((base_col + 1))
            col_r199=$((base_col + 3))
            dev="${ALL_DEVS[$i]}"
            color="${DISK_COLORS[$((i % 4))]}"

            t_data=$(echo "$CSV_DATA" | awk -F',' -v c="$col_temp" \
                '{print ($c=="" ? "null" : $c)}' | tr '\n' ',' | sed 's/,$//')
            r5_data=$(echo "$CSV_DATA" | awk -F',' -v c="$col_r5" \
                '{print ($c=="" ? "null" : $c)}' | tr '\n' ',' | sed 's/,$//')
            r199_data=$(echo "$CSV_DATA" | awk -F',' -v c="$col_r199" \
                '{print ($c=="" ? "null" : $c)}' | tr '\n' ',' | sed 's/,$//')

            ds_base="\"label\":\"${dev}\",\"borderColor\":\"${color}\","
            ds_base+="\"backgroundColor\":\"${color}22\",\"borderWidth\":1.5,"
            ds_base+="\"pointRadius\":0,\"tension\":0.3,\"fill\":false"

            CHART_DISK_TEMP_DATASETS+="{${ds_base},\"data\":[${t_data}]},"
            CHART_DISK_R5_DATASETS+="{${ds_base},\"data\":[${r5_data}]},"
            CHART_DISK_R199_DATASETS+="{${ds_base},\"data\":[${r199_data}]},"

            # Пики температур дисков
            PEAK_DISK_TEMP_VAL[$i]=$(echo "$CSV_DATA" | awk -F',' -v c="$col_temp" '$c!=""' \
                | sort -t',' -k"$col_temp" -rn | head -1 | cut -d',' -f"$col_temp")
            PEAK_DISK_TEMP_TIME[$i]=$(echo "$CSV_DATA" | awk -F',' -v c="$col_temp" '$c!=""' \
                | sort -t',' -k"$col_temp" -rn | head -1 | cut -d',' -f1)
        done

        CHART_DISK_TEMP_DATASETS="${CHART_DISK_TEMP_DATASETS%,}]"
        CHART_DISK_R5_DATASETS="${CHART_DISK_R5_DATASETS%,}]"
        CHART_DISK_R199_DATASETS="${CHART_DISK_R199_DATASETS%,}]"

        # Системные пики
        PEAK_CPU_TEMP_VAL=$(echo "$CSV_DATA" | awk -F',' '$2!=""' \
            | sort -t',' -k2 -rn | head -1 | cut -d',' -f2)
        PEAK_CPU_TEMP_TIME=$(echo "$CSV_DATA" | awk -F',' '$2!=""' \
            | sort -t',' -k2 -rn | head -1 | cut -d',' -f1)
        PEAK_GPU_TEMP_VAL=$(echo "$CSV_DATA" | awk -F',' '$3!=""' \
            | sort -t',' -k3 -rn | head -1 | cut -d',' -f3)
        PEAK_GPU_TEMP_TIME=$(echo "$CSV_DATA" | awk -F',' '$3!=""' \
            | sort -t',' -k3 -rn | head -1 | cut -d',' -f1)
        PEAK_CPU_LOAD_VAL=$(echo "$CSV_DATA" | awk -F',' '$4!=""' \
            | sort -t',' -k4 -rn | head -1 | cut -d',' -f4)
        PEAK_CPU_LOAD_TIME=$(echo "$CSV_DATA" | awk -F',' '$4!=""' \
            | sort -t',' -k4 -rn | head -1 | cut -d',' -f1)
        PEAK_RAM_VAL=$(echo "$CSV_DATA" | awk -F',' '$5!=""' \
            | sort -t',' -k5 -rn | head -1 | cut -d',' -f5)
        PEAK_RAM_TIME=$(echo "$CSV_DATA" | awk -F',' '$5!=""' \
            | sort -t',' -k5 -rn | head -1 | cut -d',' -f1)
    fi
fi

# ===========================================================================
# HTML-блок одного диска
# ===========================================================================

disk_block() {
    local dev=$1
    local label=$2
    local data="${PROBED_DATA[$dev]}"
    local flagused="${PROBED_FLAGS[$dev]}"

    if [ -z "$data" ]; then
        cat <<EOF
<div class="card disk-card">
  <div class="card-title">$label <span class="dev">$dev</span></div>
  <div class="attr-val unknown" style="margin-top:8px">Данные недоступны</div>
</div>
EOF
        return
    fi

    local model status temp r5 r197 r198 r199 r9 r12 ata_err
    model=$(parse_model "$data")
    status=$(parse_status "$data")
    temp=$(parse_temp "$data")
    r5=$(parse_attr    "$data" 5)
    r197=$(parse_attr  "$data" 197)
    r198=$(parse_attr  "$data" 198)
    r199=$(parse_attr  "$data" 199)
    r9=$(parse_attr    "$data" 9)
    r12=$(parse_attr   "$data" 12)
    ata_err=$(parse_ata_err "$data")

    local sc="ok"
    [ "$status" = "FAILED"  ] && sc="critical"
    [ "$status" = "UNKNOWN" ] && sc="unknown"

    local tc="ok"
    if [ -n "$temp" ] && [ "$temp" -gt 0 ] 2>/dev/null; then
        [ "$temp" -ge 50 ] && tc="warn"
        [ "$temp" -ge 55 ] && tc="critical"
    fi

    local rc="ok"
    if [ -n "$r5" ] && [ "$r5" -gt 0 ] 2>/dev/null; then
        rc="warn"; [ "$r5" -gt 50 ] 2>/dev/null && rc="critical"
    fi

    local pc="ok"
    [ -n "$r197" ] && [ "$r197" -gt 0 ] 2>/dev/null && pc="critical"

    local uc="ok"
    [ -n "$r198" ] && [ "$r198" -gt 0 ] 2>/dev/null && uc="critical"

    local cc="ok"
    if [ -n "$r199" ]; then
        [ "$r199" -gt 100  ] 2>/dev/null && cc="warn"
        [ "$r199" -gt 5000 ] 2>/dev/null && cc="critical"
    fi

    local ec="ok"
    [ -n "$ata_err" ] && [ "$ata_err" -gt 0 ] 2>/dev/null && ec="warn"

    local poh_str="н/д"
    if echo "$r9" | grep -qE '^[0-9]+$'; then
        poh_str="$((r9/24))д $((r9%24))ч (${r9}ч)"
    fi

    local flag_badge=""
    [ -n "$flagused" ] && flag_badge=" <span class=\"flag-badge\">-d $flagused</span>"

    cat <<EOF
<div class="card disk-card">
  <div class="card-title">$label <span class="dev">$dev$flag_badge</span></div>
  <div class="model">$model</div>
  <div class="attrs">
    <div class="attr"><span class="attr-name">Статус</span><span class="attr-val $sc">$status</span></div>
    <div class="attr"><span class="attr-name">Температура</span><span class="attr-val $tc">${temp:-н/д}°C</span></div>
    <div class="attr" title="Переназначенные секторы — рост означает умирающий диск">
      <span class="attr-name">Reallocated Sectors ⓘ</span><span class="attr-val $rc">${r5:-н/д}</span>
    </div>
    <div class="attr" title="Секторы ожидающие переназначения — любое ненулевое критично">
      <span class="attr-name">Pending Sectors ⓘ</span><span class="attr-val $pc">${r197:-н/д}</span>
    </div>
    <div class="attr" title="Неисправимые ошибки — любое ненулевое критично">
      <span class="attr-name">Uncorrectable ⓘ</span><span class="attr-val $uc">${r198:-н/д}</span>
    </div>
    <div class="attr" title="CRC-ошибки интерфейса — обычно плохой кабель или USB-адаптер">
      <span class="attr-name">UDMA CRC Errors ⓘ</span><span class="attr-val $cc">${r199:-н/д}</span>
    </div>
    <div class="attr"><span class="attr-name">ATA Errors (лог)</span><span class="attr-val $ec">${ata_err:-0}</span></div>
    <div class="attr"><span class="attr-name">Наработка</span><span class="attr-val">$poh_str</span></div>
    <div class="attr"><span class="attr-name">Циклов включения</span><span class="attr-val">${r12:-н/д}</span></div>
  </div>
</div>
EOF
}

# ===========================================================================
# Файловые системы
# ===========================================================================

fs_rows() {
    df -h -x tmpfs -x devtmpfs -x squashfs 2>/dev/null | awk 'NR>1' | \
    while read -r fs size used avail pct mnt; do
        local n; n=$(echo "$pct" | tr -d '%')
        local rc=""; [ "$n" -ge 90 ] 2>/dev/null && rc="critical"
        echo "<tr class=\"$rc\"><td>$mnt</td><td>$fs</td><td>$size</td><td>$used</td><td>$avail</td><td>$pct $(bar "$n")</td></tr>"
    done
}

# ===========================================================================
# Собираем данные для HTML
# ===========================================================================

DISK_BLOCKS=""
DISK_NUM=0
for dev in "${ALL_DEVS[@]}"; do
    DISK_NUM=$((DISK_NUM + 1))
    DISK_BLOCKS="${DISK_BLOCKS}$(disk_block "$dev" "Диск $DISK_NUM")"$'\n'
done

FS_ROWS=$(fs_rows)
CPU_CLS=$(pct_cls "$CPU_USED")
RAM_CLS=$(pct_cls "$RAM_PCT" 75 90)
RAM_BAR=$(bar "$RAM_PCT")

CPU_TEMP_HTML=""
if [ -n "$CPU_TEMP" ]; then
    T_INT=$(echo "$CPU_TEMP" | cut -d'.' -f1)
    T_CLS=$(pct_cls "$T_INT" 70 85)
    CPU_TEMP_HTML="<div class=\"metric\"><span class=\"metric-name\">Температура (ядра)</span><span class=\"metric-val $T_CLS\">${CPU_TEMP}°C</span></div>"
fi

GPU_TEMP_HTML=""
if [ -n "$GPU_TEMP" ]; then
    G_INT=$(echo "$GPU_TEMP" | cut -d'.' -f1)
    G_CLS=$(pct_cls "$G_INT" 75 90)
    GPU_TEMP_HTML="<div class=\"metric\"><span class=\"metric-name\">Температура GPU</span><span class=\"metric-val $G_CLS\">${GPU_TEMP}°C</span></div>"
fi

SWAP_HTML=""
if [ "$SWAP_TOTAL" -gt 0 ]; then
    SWAP_CLS=$(pct_cls "$SWAP_PCT" 50 80)
    SWAP_BAR=$(bar "$SWAP_PCT")
    SWAP_HTML="<div class=\"metric\" style=\"margin-top:12px\"><span class=\"metric-name\">Swap</span><span class=\"metric-val $SWAP_CLS\">${SWAP_PCT}%</span></div><div style=\"font-size:12px;color:var(--muted);margin-bottom:6px\">${SWAP_USED} МБ / ${SWAP_TOTAL} МБ</div>${SWAP_BAR}"
fi

# ---------------------------------------------------------------------------
# Блок пиков
# ---------------------------------------------------------------------------
PEAKS_HTML=""
if [ "$CHART_HAS_DATA" -eq 1 ]; then
    P_CPU_T_CLS=$(pct_cls "${PEAK_CPU_TEMP_VAL%.*}" 70 85)
    P_GPU_T_CLS=$(pct_cls "${PEAK_GPU_TEMP_VAL%.*}" 75 90)
    P_CPU_L_CLS=$(pct_cls "${PEAK_CPU_LOAD_VAL:-0}")
    P_RAM_CLS=$(pct_cls "${PEAK_RAM_VAL:-0}" 75 90)

    # Карточки пиков дисков
    DISK_PEAK_CARDS=""
    for i in "${!ALL_DEVS[@]}"; do
        dev="${ALL_DEVS[$i]}"
        pval="${PEAK_DISK_TEMP_VAL[$i]:-—}"
        ptime="${PEAK_DISK_TEMP_TIME[$i]}"
        p_tc=$(pct_cls "${pval%.*}" 50 55)
        DISK_PEAK_CARDS+="<div class=\"card\"><div class=\"card-title\">Темп. $dev</div>"
        DISK_PEAK_CARDS+="<div class=\"metric\"><span class=\"metric-name\">Максимум</span><span class=\"metric-val $p_tc\">${pval}°C</span></div>"
        DISK_PEAK_CARDS+="<div style=\"font-size:12px;color:var(--muted)\">$ptime</div></div>"$'\n'
    done

    GPU_PEAK_CARD=""
    if [ -n "$PEAK_GPU_TEMP_VAL" ]; then
        GPU_PEAK_CARD="<div class=\"card\"><div class=\"card-title\">Температура GPU</div>
<div class=\"metric\"><span class=\"metric-name\">Максимум</span><span class=\"metric-val $P_GPU_T_CLS\">${PEAK_GPU_TEMP_VAL:-—}°C</span></div>
<div style=\"font-size:12px;color:var(--muted)\">${PEAK_GPU_TEMP_TIME}</div></div>"
    fi

    PEAKS_HTML=$(cat <<PEAKSEOF
<div class="section-title">Пики за 24 часа</div>
<div class="grid">
  <div class="card">
    <div class="card-title">Температура CPU</div>
    <div class="metric"><span class="metric-name">Максимум</span><span class="metric-val $P_CPU_T_CLS">${PEAK_CPU_TEMP_VAL:-—}°C</span></div>
    <div style="font-size:12px;color:var(--muted)">${PEAK_CPU_TEMP_TIME}</div>
  </div>
  $GPU_PEAK_CARD
  $DISK_PEAK_CARDS
  <div class="card">
    <div class="card-title">Загрузка CPU</div>
    <div class="metric"><span class="metric-name">Максимум</span><span class="metric-val $P_CPU_L_CLS">${PEAK_CPU_LOAD_VAL:-—}%</span></div>
    <div style="font-size:12px;color:var(--muted)">${PEAK_CPU_LOAD_TIME}</div>
  </div>
  <div class="card">
    <div class="card-title">RAM</div>
    <div class="metric"><span class="metric-name">Максимум</span><span class="metric-val $P_RAM_CLS">${PEAK_RAM_VAL:-—}%</span></div>
    <div style="font-size:12px;color:var(--muted)">${PEAK_RAM_TIME}</div>
  </div>
</div>
PEAKSEOF
    )
fi

# ---------------------------------------------------------------------------
# Canvas-блок графиков
# ---------------------------------------------------------------------------
CHARTS_HTML=""
if [ "$CHART_HAS_DATA" -eq 1 ]; then
    # Добавляем GPU в легенду только если есть данные
    GPU_LINE=""
    [ -n "$PEAK_GPU_TEMP_VAL" ] && \
        GPU_LINE='{ label: "GPU", data: gpuTempData, borderColor: "#4caf50", backgroundColor: "#4caf5022", borderWidth:1.5, pointRadius:0, tension:0.3, fill:false },'

    CHARTS_HTML='<div class="section-title">История за 24 часа</div>
<div class="charts-grid">
  <div class="card chart-card">
    <div class="card-title" style="margin-bottom:12px">Температуры</div>
    <canvas id="chartTemp"></canvas>
  </div>
  <div class="card chart-card">
    <div class="card-title" style="margin-bottom:12px">Загрузка системы</div>
    <canvas id="chartRes"></canvas>
  </div>
  <div class="card chart-card">
    <div class="card-title" style="margin-bottom:12px">Reallocated Sectors (здоровье дисков)</div>
    <canvas id="chartR5"></canvas>
  </div>
  <div class="card chart-card">
    <div class="card-title" style="margin-bottom:12px">UDMA CRC Errors (качество кабелей/USB)</div>
    <canvas id="chartCrc"></canvas>
  </div>
</div>'
fi

# ---------------------------------------------------------------------------
# JS-блок Chart.js
# ---------------------------------------------------------------------------
CHART_SCRIPT=""
if [ "$CHART_HAS_DATA" -eq 1 ]; then
    GPU_DATASET_LINE=""
    [ -n "$PEAK_GPU_TEMP_VAL" ] && \
        GPU_DATASET_LINE='{ label: "GPU", data: gpuTempData, borderColor: "#4caf50", backgroundColor: "#4caf5022", borderWidth:1.5, pointRadius:0, tension:0.3, fill:false },'

    CHART_SCRIPT=$(cat <<JSEOF
<script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.0/dist/chart.umd.min.js"></script>
<script>
(function(){
  const labels         = [$CHART_LABELS];
  const cpuTempData    = [$CHART_CPU_TEMP_DATA];
  const gpuTempData    = [$CHART_GPU_TEMP_DATA];
  const cpuLoadData    = [$CHART_CPU_LOAD_DATA];
  const ramData        = [$CHART_RAM_DATA];
  const diskTempDS     = $CHART_DISK_TEMP_DATASETS;
  const diskR5DS       = $CHART_DISK_R5_DATASETS;
  const diskCrcDS      = $CHART_DISK_R199_DATASETS;

  Chart.defaults.color       = '#888';
  Chart.defaults.borderColor = '#2a2d3a';
  Chart.defaults.font.family = "'Segoe UI', system-ui, sans-serif";
  Chart.defaults.font.size   = 11;

  const xAxis = {
    ticks: {
      maxTicksLimit: 8, maxRotation: 0,
      callback: function(val) {
        const l = this.getLabelForValue(val);
        return l ? l.slice(11,16) : '';
      }
    }
  };
  const tip = { backgroundColor:'#1a1d27', borderColor:'#2a2d3a', borderWidth:1 };
  const leg = { position:'bottom', labels:{ usePointStyle:true, padding:12, font:{size:11} } };

  function makeChart(id, datasets, yTitle, yMin) {
    new Chart(document.getElementById(id), {
      type: 'line',
      data: { labels, datasets },
      options: {
        responsive: true, maintainAspectRatio: true, animation: false,
        interaction: { mode:'index', intersect:false },
        plugins: { legend: leg, tooltip: tip },
        scales: {
          x: xAxis,
          y: {
            beginAtZero: yMin !== undefined,
            min: yMin,
            ticks: { maxTicksLimit:6 },
            title: { display:true, text: yTitle, color:'#888' }
          }
        }
      }
    });
  }

  // 1. Температуры: CPU + GPU + диски
  makeChart('chartTemp', [
    { label:'CPU (ядра)', data:cpuTempData, borderColor:'#f44336', backgroundColor:'#f4433622', borderWidth:1.5, pointRadius:0, tension:0.3, fill:false },
    $GPU_DATASET_LINE
    ...diskTempDS
  ], '\u00b0C');

  // 2. Загрузка системы
  makeChart('chartRes', [
    { label:'CPU %',  data:cpuLoadData, borderColor:'#7c4dff', backgroundColor:'#7c4dff22', borderWidth:1.5, pointRadius:0, tension:0.3, fill:true },
    { label:'RAM %',  data:ramData,     borderColor:'#00bcd4', backgroundColor:'#00bcd422', borderWidth:1.5, pointRadius:0, tension:0.3, fill:true }
  ], '%', 0);

  // 3. Reallocated Sectors (attr 5) — должны быть нулями
  makeChart('chartR5', diskR5DS, 'секторы', 0);

  // 4. UDMA CRC Errors (attr 199) — тренд ошибок USB/кабеля
  makeChart('chartCrc', diskCrcDS, 'ошибки', 0);

})();
</script>
JSEOF
    )
fi

# ===========================================================================
# Финальный HTML
# ===========================================================================

cat > "$OUTPUT" <<HTML
<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="refresh" content="60">
<title>NAS Monitor</title>
<style>
*, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
:root {
  --bg: #0f1117; --card: #1a1d27; --border: #2a2d3a;
  --text: #e0e0e0; --muted: #888;
  --ok: #4caf50; --warn: #ff9800; --crit: #f44336; --accent: #7c4dff;
}
body { background: var(--bg); color: var(--text); font-family: 'Segoe UI', system-ui, sans-serif; font-size: 14px; padding: 16px; }
h1 { font-size: 20px; font-weight: 600; margin-bottom: 4px; }
.updated { color: var(--muted); font-size: 12px; margin-bottom: 20px; }
.section-title { font-size: 13px; font-weight: 600; text-transform: uppercase; letter-spacing: .08em; color: var(--muted); margin: 24px 0 10px; }
.grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(240px, 1fr)); gap: 12px; }
.charts-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(420px, 1fr)); gap: 12px; }
.card { background: var(--card); border: 1px solid var(--border); border-radius: 10px; padding: 16px; }
.chart-card { padding: 16px 16px 12px; }
.card-title { font-size: 15px; font-weight: 600; margin-bottom: 4px; }
.dev { color: var(--muted); font-size: 11px; font-weight: 400; margin-left: 6px; }
.model { color: var(--muted); font-size: 12px; margin-bottom: 12px; }
.flag-badge { background: #2a2d3a; border-radius: 4px; padding: 1px 5px; font-size: 10px; font-family: monospace; }
.metric { display: flex; align-items: center; justify-content: space-between; margin-bottom: 10px; }
.metric-name { color: var(--muted); font-size: 13px; }
.metric-val { font-size: 22px; font-weight: 700; }
.metric-val.ok, .attr-val.ok     { color: var(--ok); }
.metric-val.warn, .attr-val.warn  { color: var(--warn); }
.metric-val.critical, .attr-val.critical { color: var(--crit); }
.attr-val.unknown { color: var(--muted); }
.attrs { display: flex; flex-direction: column; gap: 6px; }
.attr { display: flex; justify-content: space-between; align-items: center; font-size: 13px; padding: 4px 0; border-bottom: 1px solid var(--border); }
.attr:last-child { border-bottom: none; }
.attr-name { color: var(--muted); }
.attr-val { font-weight: 600; }
.bar-wrap { background: var(--border); border-radius: 4px; height: 6px; width: 120px; overflow: hidden; display: inline-block; vertical-align: middle; margin-left: 8px; }
.bar { height: 100%; border-radius: 4px; }
.bar.ok { background: var(--ok); } .bar.warn { background: var(--warn); } .bar.critical { background: var(--crit); }
table { width: 100%; border-collapse: collapse; font-size: 13px; }
th { text-align: left; color: var(--muted); font-weight: 600; padding: 6px 8px; border-bottom: 1px solid var(--border); }
td { padding: 6px 8px; border-bottom: 1px solid var(--border); }
tr.critical td { color: var(--crit); }
tr:hover td { background: rgba(255,255,255,.03); }
.disk-card { border-left: 3px solid var(--accent); }
</style>
</head>
<body>

<h1>NAS Monitor</h1>
<div class="updated">Обновлено: $UPDATED &nbsp;·&nbsp; Автообновление каждые 60 сек</div>

<div class="section-title">Система</div>
<div class="grid">

<div class="card">
  <div class="card-title">Процессор</div>
  <div class="metric"><span class="metric-name">Загрузка</span><span class="metric-val $CPU_CLS">${CPU_USED}%</span></div>
  <div class="metric"><span class="metric-name">LA (1/5/15)</span><span style="font-size:13px">$LOAD</span></div>
  $CPU_TEMP_HTML
  $GPU_TEMP_HTML
  <div class="metric"><span class="metric-name">Аптайм</span><span style="font-size:13px">$UPTIME_STR</span></div>
</div>

<div class="card">
  <div class="card-title">Память</div>
  <div class="metric"><span class="metric-name">RAM</span><span class="metric-val $RAM_CLS">${RAM_PCT}%</span></div>
  <div style="font-size:12px;color:var(--muted);margin-bottom:8px">${RAM_USED} МБ / ${RAM_TOTAL} МБ &nbsp;(свободно ${RAM_FREE} МБ)</div>
  $RAM_BAR
  $SWAP_HTML
</div>

</div>

$PEAKS_HTML

$CHARTS_HTML

<div class="section-title">Диски — S.M.A.R.T.</div>
<div class="grid">
$DISK_BLOCKS
</div>

<div class="section-title">Файловые системы</div>
<div class="card" style="overflow-x:auto">
<table>
  <tr>
    <th>Точка монтирования</th><th>Устройство</th><th>Размер</th>
    <th>Занято</th><th>Свободно</th><th>Использование</th>
  </tr>
  $FS_ROWS
</table>
</div>

$CHART_SCRIPT
</body>
</html>
HTML
