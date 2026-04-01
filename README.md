# NAS Dashboard — инструкция

Кастомный веб-дашборд для мониторинга домашнего NAS на Debian.
Bash-скрипт каждую минуту собирает метрики, генерирует статичный HTML,
nginx раздаёт его в браузере. Никаких сторонних сервисов, никакого интернета.

---

## Что отображает дашборд

### Текущее состояние (обновляется каждые 60 сек, (!) кроме SMART на жестких дисках - они обновляются раз в сутки)
- **Процессор** — загрузка %, Load Average (1/5/15 мин), температура ядер, аптайм
- **Память** — RAM % с прогресс-баром, занято/свободно в МБ, Swap если есть
- **GPU** — температура (если доступна через sensors / nvidia-smi / sysfs)
- **Диски — S.M.A.R.T.** — по каждому диску:
  - Модель, статус PASSED/FAILED
  - Температура (атрибут 194 или 190 — автоматически)
  - Reallocated Sectors — переназначенные секторы (рост = умирающий диск)
  - Pending Sectors — ожидающие переназначения (любое ненулевое = тревога)
  - Uncorrectable — неисправимые ошибки (любое ненулевое = тревога)
  - UDMA CRC Errors — ошибки USB-адаптера/кабеля
  - ATA Error Count — ошибки из журнала диска
  - Наработка в часах и днях, количество включений
  - **«SMART: обновлено N мин назад»** — время последнего реального опроса диска
- **Файловые системы** — таблица df: размер, занято, свободно, прогресс-бар

### История за 24 часа (графики Chart.js)
- **Температуры** — CPU + GPU + все диски на одном графике
- **Загрузка системы** — CPU % и RAM %
- **Reallocated Sectors** — динамика по каждому диску (должен быть ровный ноль)
- **UDMA CRC Errors** — тренд ошибок USB/кабелей по каждому диску

### Пики за 24 часа
- Максимальная температура CPU, GPU и каждого диска с точным временем
- Максимальная загрузка CPU и RAM с точным временем

---

## Как скрипт работает изнутри

```
cron (каждую минуту, от root)
  → /usr/local/bin/nas-dashboard.sh
      → vmstat, free, uptime, sensors      — системные метрики (каждую минуту)
      → lsblk                              — список всех дисков
      → SMART-кэш (TTL = 10 мин):
            свежий? → читать /tmp/nas_smart_*.data   (без I/O к диску)
            устарел? → smartctl → обновить кэш
      → дописывает строку в metrics.csv
      → читает последние 1440 строк CSV (= 24 часа)
      → генерирует /var/www/nas-dashboard/index.html
          → nginx раздаёт на порту 8080
              → браузер (meta refresh каждые 60 сек)
```

**Частота опросов дисков:**

| Метрика | Частота | Как |
|---------|---------|-----|
| CPU, RAM, Load | каждую минуту | `vmstat`, `free` — нет I/O к дискам |
| Температура дисков | каждую минуту | `smartctl -A -H` — лёгкий запрос, только регистры диска |
| Полный SMART (здоровье, секторы, ошибки) | раз в сутки | `smartctl -a` — полный опрос с чтением журналов |

**Автоопределение USB-мостов** — для каждого диска пробует флаги smartctl по очереди:
без флага → `sat,12` → `sat,16` → `sat` → `usbsunplus` → `usbjmicron` → `usbcypress`.
Первый сработавший используется и показывается в заголовке карточки.

**CSV-лог** хранит 7 дней (10080 строк). При изменении набора дисков старый файл
автоматически архивируется, история начинается заново.

---

## Установка с нуля

### 1. Установить зависимости

```bash
sudo apt update
sudo apt install -y nginx smartmontools lm-sensors
sudo sensors-detect --auto   # автоопределение датчиков температуры
```

### 2. Создать директорию для дашборда

```bash
sudo mkdir -p /var/www/nas-dashboard
```

### 3. Скопировать скрипт на нетбук

Выполнить на своём Mac/PC (заменить IP):

```bash
scp nas-dashboard.sh volnyii@192.168.x.x:/tmp/nas-dashboard.sh
```

### 4. Установить скрипт на нетбуке

```bash
ssh volnyii@192.168.x.x

sudo mv /tmp/nas-dashboard.sh /usr/local/bin/nas-dashboard.sh
sudo chmod +x /usr/local/bin/nas-dashboard.sh
```

### 5. Настроить nginx

```bash
sudo nano /etc/nginx/sites-available/nas-dashboard
```

Вставить:

```nginx
server {
    listen 8080;
    root /var/www/nas-dashboard;
    index index.html;
}
```

Подключить конфиг и перезапустить:

```bash
sudo ln -s /etc/nginx/sites-available/nas-dashboard /etc/nginx/sites-enabled/
sudo nginx -t
sudo systemctl reload nginx
sudo systemctl enable nginx
```

### 6. Настроить cron

```bash
echo "* * * * * /usr/local/bin/nas-dashboard.sh" | sudo crontab -
```

Проверить:

```bash
sudo crontab -l
# Должно быть: * * * * * /usr/local/bin/nas-dashboard.sh
```

### 7. Первый запуск вручную

```bash
sudo /usr/local/bin/nas-dashboard.sh && echo "OK"
```

Через несколько секунд открыть в браузере:

```
http://IP-нетбука:8080
```

Графики появятся после 3–5 минут (нужно накопить записи в CSV).

---

## Обновление скрипта

```bash
# На Mac/PC:
scp nas-dashboard.sh volnyii@192.168.x.x:/tmp/nas-dashboard.sh

# На нетбуке:
sudo mv /tmp/nas-dashboard.sh /usr/local/bin/nas-dashboard.sh
sudo chmod +x /usr/local/bin/nas-dashboard.sh
sudo /usr/local/bin/nas-dashboard.sh && echo "OK"
```

---

## Файлы на нетбуке

| Путь | Описание |
|------|----------|
| `/usr/local/bin/nas-dashboard.sh` | Основной скрипт |
| `/var/www/nas-dashboard/index.html` | Генерируемый дашборд (пересоздаётся каждую минуту) |
| `/var/www/nas-dashboard/metrics.csv` | История метрик за 7 дней |
| `/tmp/nas_smart_*_full.data` | Полный SMART-кэш (TTL 24 ч, сбрасывается при перезагрузке) |
| `/tmp/nas_smart_*_temp.data` | Кэш температуры (TTL 60 с) |
| `/tmp/nas_smart_*.flag` | Рабочий флаг smartctl для каждого диска |
| `/etc/nginx/sites-available/nas-dashboard` | Конфиг nginx |

---

## Диагностика

**Дашборд не открывается:**
```bash
sudo systemctl status nginx
sudo nginx -t
```

**Скрипт не запускается по cron:**
```bash
sudo crontab -l                        # проверить наличие строки
sudo /usr/local/bin/nas-dashboard.sh   # запустить вручную и смотреть ошибки
```

**Диск не определяется / нет SMART данных:**
```bash
lsblk -dpno NAME,TYPE                  # список дисков
sudo smartctl -a /dev/sdX              # без флага
sudo smartctl -d sat,12 -a /dev/sdX    # с флагом для USB OWC PA023U3
```

**Нет температуры CPU (показывает acpitz вместо ядер):**
```bash
sensors                                # посмотреть все датчики
# Нужны строки "Core 0:", "Core 1:" — это реальные ядра
# "temp1" от acpitz — это материнская плата, часто врёт
```

**Принудительно обновить полный SMART-кэш (перечитать диски сейчас):**
```bash
sudo rm /tmp/nas_smart_*_full.data
sudo /usr/local/bin/nas-dashboard.sh
```

**Сбросить историю графиков:**
```bash
sudo rm /var/www/nas-dashboard/metrics.csv
```
