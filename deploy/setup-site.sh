#!/usr/bin/env bash
# =====================================================================
#  setup-site.sh — установка и обновление сайта antonshkel.ru на VPS
#  Ubuntu / Debian: nginx + PHP-FPM + бесплатный SSL от Let's Encrypt
#
#  Первый запуск и обновление сайта:  bash setup-site.sh
#     (рядом со скриптом или в /root должен лежать antonshkel.ru.zip)
#  Или из папки с сайтом (например, из git-репозитория):  bash deploy/setup-site.sh site
#  Выпустить SSL, когда домен начал вести на сервер:  bash setup-site.sh --ssl
#  Заново настроить почту и Telegram:                 bash setup-site.sh --reconfigure
#  Проверить, доходят ли заявки:                      bash setup-site.sh --test
#  Вернуть предыдущую версию сайта:                   bash setup-site.sh --rollback
#  Подключить или поменять Яндекс Метрику:            bash setup-site.sh --metrika
#  Сообщить Яндексу об обновлении страниц:            bash setup-site.sh --ping
#
#  Скрипт не трогает ботов, папку /root и другие сайты в nginx.
#  Он только ставит nginx и PHP (если их нет) и создаёт свои файлы:
#    /var/www/antonshkel.ru/               — сайт, настройки, заявки
#    /etc/nginx/sites-available/antonshkel.ru.conf
#    /etc/nginx/snippets/antonshkel.ru-site.conf
#    /var/log/nginx/antonshkel.ru.access.log  — журнал сайта, IP обезличены
# =====================================================================
set -Eeuo pipefail
umask 022

DOMAIN="antonshkel.ru"
BASE="/var/www/${DOMAIN}"
WEB="${BASE}/public"
CONF="${BASE}/config.php"
ANSWERS="${BASE}/.setup-answers"
LEADS="${BASE}/leads"
ACME="/var/www/letsencrypt"
NGX_SITE="/etc/nginx/sites-available/${DOMAIN}.conf"
NGX_LINK="/etc/nginx/sites-enabled/${DOMAIN}.conf"
NGX_SNIP="/etc/nginx/snippets/${DOMAIN}-site.conf"
ALOG="/var/log/nginx/${DOMAIN}.access.log"
INDEXNOW_KEY_FILE="${BASE}/.indexnow-key"
CERT_DIR="/etc/letsencrypt/live/${DOMAIN}"
DEFAULT_EMAIL="anton.shkel06@mail.ru"
DEFAULT_METRIKA="112959584"   # счётчик antonshkel.ru в Яндекс Метрике

# ---------- оформление ----------
if [[ -t 1 ]]; then B=$'\e[1m'; G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; C=$'\e[36m'; N=$'\e[0m'; else B=; G=; Y=; R=; C=; N=; fi
step() { printf '\n%s▸ %s%s\n' "$B$C" "$*" "$N"; }
ok()   { printf '  %s✓%s %s\n' "$G" "$N" "$*"; }
warn() { printf '  %s!%s %s\n' "$Y" "$N" "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf '\n%s✗ %s%s\n' "$R$B" "$*" "$N" >&2; exit 1; }
trap 'printf "\n%s✗ Ошибка в строке %s: %s%s\nСайт и другие сервисы при этом не тронуты. Сохраните этот вывод: по нему видно, что пошло не так.\n" "$R" "$LINENO" "$BASH_COMMAND" "$N" >&2' ERR

# ---------- режим запуска ----------
MODE="install"; ZIP_ARG=""; SRC_ARG=""
for a in "$@"; do
  case "$a" in
    --ssl) MODE="ssl" ;;
    --reconfigure) MODE="reconfigure" ;;
    --test) MODE="test" ;;
    --rollback) MODE="rollback" ;;
    --metrika) MODE="metrika" ;;
    --ping) MODE="ping" ;;
    -h|--help) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *.zip) ZIP_ARG="$a" ;;
    *) if [[ -d $a ]]; then SRC_ARG="$(readlink -f "$a")"; else die "Неизвестный параметр: $a (справка: bash setup-site.sh --help)"; fi ;;
  esac
done

[[ $EUID -eq 0 ]] || die "Нужны права root. Запустите: sudo bash setup-site.sh"
command -v apt-get >/dev/null || die "Скрипт рассчитан на Ubuntu или Debian (нужен apt-get)."

printf '%s\n' "${B}antonshkel.ru — установка сайта на этот сервер${N}"

# =====================================================================
#  Откат
# =====================================================================
if [[ $MODE == rollback ]]; then
  [[ -d "${WEB}.prev" ]] || die "Предыдущей версии нет — откатывать не на что."
  mv "$WEB" "${WEB}.tmp" && mv "${WEB}.prev" "$WEB" && mv "${WEB}.tmp" "${WEB}.prev"
  ok "Вернул предыдущую версию сайта. Повторный --rollback вернёт новую."
  exit 0
fi

# =====================================================================
#  Вспомогательное
# =====================================================================
php_bin() { command -v php 2>/dev/null || true; }

fpm_version() { # версия установленного PHP-FPM (если их несколько — самая новая)
  local v
  v=$(dpkg-query -W -f='${Package} ${Status}\n' 'php*-fpm' 2>/dev/null \
      | awk '/install ok installed/ && $1 ~ /^php[0-9]+\.[0-9]+-fpm$/ {sub(/^php/,"",$1); sub(/-fpm$/,"",$1); print $1}' \
      | sort -V | tail -1) || true
  [[ -n $v ]] || v=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')
  echo "$v"
}
fpm_socket()  { echo "/run/php/php$(fpm_version)-fpm.sock"; }
fpm_service() { echo "php$(fpm_version)-fpm"; }

server_ip() {
  local ip
  ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}') || true
  if [[ -z $ip || $ip =~ ^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.) ]]; then
    ip=$(curl -4 -fsS -m 6 https://api.ipify.org 2>/dev/null || true)
  fi
  echo "$ip"
}
dns_lookup() { # $1 = имя, $2 = A | AAAA → первый адрес. Спрашиваем публичный DNS, чтобы не мешали /etc/hosts и кэш
  local r
  r=$(curl -fsS -m 8 "https://dns.google/resolve?name=$1&type=$2" 2>/dev/null \
      | php -r '$j=json_decode(stream_get_contents(STDIN),true); foreach (($j["Answer"] ?? []) as $a) { if ($a["type"] === ($argv[1]==="A"?1:28)) { echo $a["data"]; break; } }' "$2" 2>/dev/null || true)
  if [[ -z $r && $2 == A ]]; then r=$(getent ahostsv4 "$1" 2>/dev/null | awk 'NR==1{print $1}' || true); [[ $r == 127.* ]] && r=""; fi
  echo "$r"
}
resolve4() { dns_lookup "$1" A; }

ask() { # ask "Вопрос" "по умолчанию" → REPLY
  local q="$1" def="${2:-}"
  if [[ -n $def ]]; then read -r -p "  ${q} [${def}]: " REPLY || true; REPLY="${REPLY:-$def}"
  else read -r -p "  ${q}: " REPLY || true; fi
  REPLY="$(printf '%s' "$REPLY" | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
}
ask_secret() {
  read -r -s -p "  $1: " REPLY || true; echo
  REPLY="$(printf '%s' "$REPLY" | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
}
confirm() { local r; read -r -p "  $1 [y/N]: " r || true; [[ $r =~ ^[YyДд] ]]; }

# =====================================================================
#  1. Порты 80 и 443 не должны быть заняты не-nginx
# =====================================================================
check_ports() {
  step "Проверяю, свободны ли порты 80 и 443"
  if ! command -v ss >/dev/null; then warn "Нет утилиты ss — пропускаю проверку."; return; fi
  local busy
  busy=$(ss -H -ltnp '( sport = :80 or sport = :443 )' 2>/dev/null | grep -v '"nginx"' || true)
  if [[ -n $busy ]]; then
    printf '%s\n' "$busy" | sed 's/^/    /'
    die "Порт 80 или 443 уже занят другой программой (см. строки выше: имя программы в users:((\"...\")).
  Возможно, это веб-сервер Apache или один из ботов принимает вебхуки.
  Чтобы ничего не сломать, скрипт остановился. Остановите эту программу или переведите её на другой порт и запустите скрипт снова."
  fi
  ok "Порты свободны или заняты nginx — можно продолжать."
}

# =====================================================================
#  2. Пакеты
# =====================================================================
NGINX_FRESH=0
install_packages() {
  step "Ставлю nginx, PHP и certbot (если их ещё нет)"
  local pkgs=(nginx php-fpm php-cli php-mbstring php-curl unzip curl ca-certificates openssl)
  command -v certbot >/dev/null || pkgs+=(certbot)   # certbot мог быть установлен через snap — второй не ставим
  local missing=() p st
  for p in "${pkgs[@]}"; do
    st=$(dpkg-query -W -f='${Status}' "$p" 2>/dev/null || true)
    [[ $st == *"install ok installed"* ]] || missing+=("$p")
  done
  [[ " ${missing[*]} " == *" nginx "* ]] && NGINX_FRESH=1
  if ((${#missing[@]})); then
    info "Устанавливаю: ${missing[*]}"
    info "Это займёт 1–3 минуты. Подробный журнал: /var/log/antonshkel-setup.log"
    export DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1 NEEDRESTART_MODE=l
    apt-get -o DPkg::Lock::Timeout=600 update -qq >>/var/log/antonshkel-setup.log 2>&1 \
      || warn "apt-get update завершился с ошибкой (возможно, сломан сторонний репозиторий) — пробую установить всё равно."
    apt-get install -y -qq --no-install-recommends -o DPkg::Lock::Timeout=600 \
      -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
      "${missing[@]}" >>/var/log/antonshkel-setup.log 2>&1 \
      || die "Не удалось установить пакеты. Последние строки журнала:
$(tail -n 15 /var/log/antonshkel-setup.log)"
    ok "Установлено."
  else
    ok "Всё уже установлено."
  fi
  systemctl enable --now "$(fpm_service)" >/dev/null 2>&1 || true
  systemctl enable --now nginx >/dev/null 2>&1 || true
  [[ -S $(fpm_socket) ]] || { sleep 2; [[ -S $(fpm_socket) ]] || die "PHP-FPM не запустился: нет файла $(fpm_socket). Проверьте: systemctl status $(fpm_service)"; }
  ok "PHP $(php -r 'echo PHP_VERSION;') и nginx $(nginx -v 2>&1 | sed 's/.*\///') работают."
  certbot --version >/dev/null 2>&1 || warn "certbot установлен, но не запускается — SSL может не выпуститься. Проверьте: certbot --version"
}

# =====================================================================
#  3. Отчество и ИНН для политики и согласия
# =====================================================================
PATRONYMIC=""; INN=""; METRIKA_ID=""; METRIKA_ASKED=""
load_answers() { [[ -f $ANSWERS ]] && source "$ANSWERS" || true; }
save_answers() {
  mkdir -p "$BASE"
  { printf 'PATRONYMIC=%q\n' "$PATRONYMIC"; printf 'INN=%q\n' "$INN"
    printf 'METRIKA_ID=%q\n' "$METRIKA_ID"; printf 'METRIKA_ASKED=%q\n' "$METRIKA_ASKED"; } > "$ANSWERS"
  chmod 600 "$ANSWERS"
}
ask_answers() {
  step "Данные для политики конфиденциальности и согласия"
  info "Они нужны по закону о персональных данных. Спрошу один раз и запомню."
  while :; do
    ask "Ваше отчество, например Игоревич (Enter — пропустить)" "$PATRONYMIC"
    if [[ -z $REPLY ]] || php -r 'exit(preg_match("/^[А-ЯЁ][а-яё]+(-[А-ЯЁ]?[а-яё]+)?$/u", $argv[1]) ? 0 : 1);' "$REPLY"; then PATRONYMIC="$REPLY"; break; fi
    warn "Только русские буквы, с заглавной: Игоревич"
  done
  while :; do
    ask "ИНН — 12 цифр, есть в приложении «Мой налог» (Enter — пропустить)" "$INN"
    [[ -z $REPLY || $REPLY =~ ^[0-9]{12}$ ]] && { INN="$REPLY"; break; }
    warn "ИНН физлица — ровно 12 цифр, без пробелов"
  done
  save_answers
  [[ -n $PATRONYMIC && -n $INN ]] && ok "Сохранил." || warn "Что-то пропущено — на страницах останутся жёлтые пометки. Потом: bash setup-site.sh --reconfigure"
}

ask_metrika() {
  step "Яндекс Метрика (по желанию)"
  info "Номер счётчика — цифры в metrika.yandex.ru, рядом с названием счётчика."
  info "С Метрикой на сайте появится плашка о cookies: счётчик включается, только если посетитель нажал «Разрешить»."
  while :; do
    if [[ $METRIKA_ASKED == 1 ]]; then
      ask "Номер счётчика (Enter — оставить; «-» — отключить Метрику)" "$METRIKA_ID"
    else
      ask "Номер счётчика (Enter — подключить этот; «-» — без Метрики)" "$DEFAULT_METRIKA"
    fi
    [[ $REPLY == "-" ]] && REPLY=""
    [[ -z $REPLY || $REPLY =~ ^[0-9]{5,12}$ ]] && { METRIKA_ID="$REPLY"; break; }
    warn "Номер счётчика — только цифры, например 98765432"
  done
  METRIKA_ASKED=1
}

fill_placeholders() { # $1 — папка сайта
  PATRONYMIC="$PATRONYMIC" INN="$INN" YM="$METRIKA_ID" php -r '
    $ym = preg_match("/^[0-9]{5,12}$/", (string)getenv("YM")) ? getenv("YM") : "";
    $it = new RecursiveIteratorIterator(new RecursiveDirectoryIterator($argv[1], FilesystemIterator::SKIP_DOTS));
    foreach ($it as $f) {
      if (substr($f->getFilename(), -5) !== ".html") continue;
      $s = file_get_contents($f->getPathname());
      if (strpos($s, "data-ym=") === false) continue;
      $n = preg_replace("~data-ym=\"[^\"]*\"~", "data-ym=\"" . $ym . "\"", $s);
      if ($n !== null && $n !== $s) file_put_contents($f->getPathname(), $n);
    }
    $o = getenv("PATRONYMIC"); $i = getenv("INN");
    foreach (["privacy/index.html", "soglasie/index.html"] as $f) {
      $p = $argv[1] . "/" . $f; if (!is_file($p)) continue;
      $s = file_get_contents($p);
      $s = preg_replace_callback("~<span class=\"fill\">(.*?)</span>~u", function ($m) use ($o, $i) {
        $t = $m[1];
        if ($o !== "") $t = str_replace("[отчество]", $o, $t);
        if ($i !== "") $t = str_replace("[ИНН]", $i, $t);
        return strpos($t, "[") === false ? $t : "<span class=\"fill\">" . $t . "</span>";
      }, $s);
      if ($s !== null) file_put_contents($p, $s);
    }' "$1"
}

# =====================================================================
#  4. Файлы сайта
# =====================================================================
find_zip() { # $1 = quiet: не останавливаться, если архива нет
  local z=""
  if [[ -n $ZIP_ARG ]]; then z="$ZIP_ARG"
  else
    local d f
    for d in "$PWD" "$(dirname "$(readlink -f "$0")")" /root; do
      f=$(ls -t "$d"/antonshkel.ru*.zip 2>/dev/null | head -1 || true)
      [[ -n $f ]] && { z="$f"; break; }
    done
  fi
  if [[ -z $z || ! -f $z ]]; then
    [[ ${1:-} == quiet ]] && { ZIP=""; return 1; }
    die "Не нашёл архив antonshkel.ru.zip. Загрузите его через MobaXterm в папку /root рядом со скриптом."
  fi
  ZIP="$(readlink -f "$z")"
}

# ---------- IndexNow: сообщаем Яндексу об обновлённых страницах ----------
indexnow_key() { # ключ создаётся один раз и хранится вне сайта
  if [[ ! -s $INDEXNOW_KEY_FILE ]]; then
    mkdir -p "$BASE"
    openssl rand -hex 16 > "$INDEXNOW_KEY_FILE"
    chmod 644 "$INDEXNOW_KEY_FILE"
  fi
  tr -dc 'a-zA-Z0-9-' < "$INDEXNOW_KEY_FILE"
}
place_indexnow_key() { # $1 — папка сайта; Яндекс проверяет ключ по адресу https://домен/<ключ>.txt
  local k; k=$(indexnow_key)
  printf '%s' "$k" > "$1/$k.txt"
  chmod 644 "$1/$k.txt"
}
ping_search() {
  step "Сообщаю Яндексу об обновлении страниц (IndexNow)"
  if [[ ! -f $CERT_DIR/fullchain.pem ]]; then
    info "Пропускаю: сначала нужен SSL (bash setup-site.sh --ssl)."
    return 0
  fi
  local k urls json code n
  k=$(indexnow_key)
  [[ -f $WEB/$k.txt ]] || place_indexnow_key "$WEB"
  urls=$(grep -o '<loc>[^<]*</loc>' "$WEB/sitemap.xml" 2>/dev/null | sed -e 's#<loc>##' -e 's#</loc>##' || true)
  if [[ -z $urls ]]; then warn "В sitemap.xml нет адресов — пропускаю."; return 0; fi
  n=$(printf '%s\n' "$urls" | wc -l | tr -d ' ')
  json=$(printf '%s\n' "$urls" | php -r '$u = array_values(array_filter(array_map("trim", file("php://stdin"))));
    echo json_encode(["host" => $argv[1], "key" => $argv[2], "keyLocation" => "https://" . $argv[1] . "/" . $argv[2] . ".txt", "urlList" => $u], JSON_UNESCAPED_SLASHES);' "$DOMAIN" "$k")
  code=$(curl -s -o /dev/null -w '%{http_code}' -m 15 -H 'Content-Type: application/json; charset=utf-8' \
         --data "$json" https://yandex.com/indexnow || true)
  case $code in
    200) ok "Яндекс принял список страниц ($n шт.). Робот придёт в ближайшее время." ;;
    202) ok "Яндекс принял список страниц ($n шт.). Ключ новый — Яндекс его проверит, это нормально." ;;
    *)   warn "Яндекс ответил кодом ${code:-нет ответа}. Не страшно: страницы он всё равно найдёт по sitemap."
         info "Повторить позже: bash setup-site.sh --ping" ;;
  esac
}

deploy_files() {
  step "Раскладываю файлы сайта"
  mkdir -p "$BASE"
  local tmp src
  if [[ -n $SRC_ARG ]]; then
    info "Папка: $SRC_ARG"
    tmp=$(mktemp -d "${BASE}/.new.XXXXXX")
    cp -a "$SRC_ARG"/. "$tmp"/
    rm -rf "$tmp/.git"
  else
    find_zip
    info "Архив: $ZIP"
    tmp=$(mktemp -d "${BASE}/.new.XXXXXX")
    unzip -q -o "$ZIP" -d "$tmp"
  fi
  src="$tmp"
  if [[ ! -f $src/index.html ]]; then  # архив запакован вместе с папкой
    local found; found=$(find "$tmp" -maxdepth 3 -name send.php -print -quit)
    [[ -n $found ]] && src=$(dirname "$found")
  fi
  [[ -n $src && -f $src/index.html && -f $src/send.php && -f $src/polutone/index.html ]] \
    || { rm -rf "$tmp"; die "В архиве нет index.html, send.php или папки polutone — это не тот архив."; }

  fill_placeholders "$src"
  place_indexnow_key "$src"
  chown -R root:root "$src"
  find "$src" -type d -exec chmod 755 {} +
  find "$src" -type f -exec chmod 644 {} +

  if [[ -d $WEB ]]; then  # файлы подтверждения Яндекс Вебмастера и Google переносим в новую версию
    local vf
    for vf in "$WEB"/yandex_*.html "$WEB"/google*.html; do
      [[ -f $vf && ! -e $src/$(basename "$vf") ]] && cp -p "$vf" "$src/"
    done
  fi
  rm -rf "${WEB}.prev"
  [[ -d $WEB ]] && mv "$WEB" "${WEB}.prev"
  mv "$src" "$WEB"
  rm -rf "$tmp"
  [[ -d ${WEB}.prev ]] && ok "Сайт обновлён: $WEB (прошлая версия сохранена, откат — bash setup-site.sh --rollback)" || ok "Сайт лежит в $WEB"

  mkdir -p "$LEADS"; chown www-data:www-data "$LEADS"; chmod 700 "$LEADS"
  mkdir -p "$ACME/.well-known/acme-challenge"
}

# =====================================================================
#  5. Почта и Telegram
# =====================================================================
write_config() { # всё передаётся через переменные окружения — без проблем с кавычками
  install -m 640 -o root -g www-data /dev/null "$CONF"
  php -r '
    date_default_timezone_set("Europe/Moscow");
    $c = [
      "notify_email"      => (string)getenv("C_EMAIL"),
      "smtp_host"         => (string)getenv("C_SMTP_HOST"),
      "smtp_port"         => 465,
      "smtp_user"         => (string)getenv("C_SMTP_USER"),
      "smtp_pass"         => (string)getenv("C_SMTP_PASS"),
      "bot_token"         => (string)getenv("C_BOT"),
      "chat_id"           => (string)getenv("C_CHAT"),
      "telegram_contacts" => false,
      "store_csv"         => getenv("C_STORE") === "1",
      "rl_secret"         => bin2hex(random_bytes(16)),
    ];
    $out = "<?php\n// Настройки приёма заявок antonshkel.ru. Создано setup-site.sh " . date("d.m.Y H:i") . "\n"
         . "// Изменить: bash setup-site.sh --reconfigure (или отредактировать этот файл)\nreturn " . var_export($c, true) . ";\n";
    file_put_contents($argv[1], $out);' "$CONF"
  chown root:www-data "$CONF"; chmod 640 "$CONF"
}

configure_notifications() {
  step "Куда присылать заявки с сайта"
  local country store email host user pass bot chat="" name
  country=$(curl -fsS -m 6 https://ipinfo.io/country 2>/dev/null | tr -d '\r\n ' || true)
  if [[ $country == RU ]]; then
    store=1; ok "Сервер в России — заявки будут ещё и сохраняться в файл на сервере."
  else
    store=0
    warn "Сервер находится не в России (${country:-страна не определилась})."
    info "По закону 152-ФЗ данные россиян сначала должны записываться в базу в России."
    info "Поэтому на этом сервере заявки НЕ сохраняются: они сразу уходят письмом"
    info "в почту Mail.ru (серверы в России), а в Telegram — только сигнал без контактов."
  fi

  echo
  ask "Почта, куда приходят заявки" "$DEFAULT_EMAIL"; email="$REPLY"
  case "${email##*@}" in
    mail.ru|inbox.ru|list.ru|bk.ru|internet.ru|vk.com) host="smtp.mail.ru"; name="Mail.ru" ;;
    yandex.ru|ya.ru|yandex.com) host="smtp.yandex.ru"; name="Яндекс" ;;
    gmail.com) host="smtp.gmail.com"; name="Gmail" ;;
    *) ask "SMTP-сервер вашей почты (порт 465)" ""; host="$REPLY"; name="почты" ;;
  esac
  user="$email"
  info "Письма отправляются с этого же ящика самому себе. Нужен ${B}пароль для внешнего приложения${N} ${name}"
  info "(не обычный пароль!). Его создают в настройках безопасности почты, раздел «Пароли для внешних приложений»."
  ask_secret "Вставьте пароль для внешнего приложения (символы не видны; Enter — пропустить)"; pass="$REPLY"
  [[ -z $pass ]] && warn "Без пароля письма отправляться не будут."

  echo
  info "Telegram-уведомления (по желанию): отдельный бот пишет вам «Новая заявка с сайта»."
  info "Создайте бота у @BotFather → /newbot. Не используйте токен рабочего бота."
  while :; do
    ask "Токен бота (Enter — пропустить)" ""; bot="$REPLY"
    [[ -z $bot || $bot =~ ^[0-9]{5,}:[A-Za-z0-9_-]{30,}$ ]] && break
    warn "Токен выглядит как 1234567890:AAH...  — скопируйте его из @BotFather целиком"
  done
  if [[ -n $bot ]]; then
    local me uname upd
    me=$(curl -sS -m 10 "https://api.telegram.org/bot${bot}/getMe" 2>/dev/null || true)
    uname=$(printf '%s' "$me" | php -r '$j=json_decode(stream_get_contents(STDIN),true); echo $j["result"]["username"] ?? "";')
    if [[ -z $me ]]; then
      warn "Нет связи с api.telegram.org с этого сервера — Telegram пропускаю."; bot=""
    elif [[ -z $uname ]]; then
      warn "Telegram не принял токен — проверьте его в @BotFather. Telegram пропускаю."; bot=""
    else
      ok "Бот найден: @${uname}"
      info "Откройте в Telegram бота @${uname}, нажмите «Запустить» (Start), затем вернитесь сюда."
      read -r -p "  Нажмите Enter, когда нажмёте Start в Telegram… " _ || true
      upd=$(curl -sS -m 10 "https://api.telegram.org/bot${bot}/getUpdates?limit=20" 2>/dev/null || true)
      chat=$(printf '%s' "$upd" | php -r '$j=json_decode(stream_get_contents(STDIN),true); $id="";
        foreach (($j["result"] ?? []) as $u) { $m = $u["message"] ?? $u["my_chat_member"] ?? null; if ($m && ($m["chat"]["type"] ?? "") === "private") $id = (string)$m["chat"]["id"]; }
        echo $id;')
      if [[ -z $chat ]]; then
        [[ $upd == *'"error_code":409'* ]] && warn "Этот токен уже занят работающим ботом. Лучше создать отдельного."
        ask "Не нашёл ваш chat_id автоматически. Введите его вручную (число от @userinfobot; Enter — пропустить)" ""
        [[ $REPLY =~ ^-?[0-9]+$ ]] && chat="$REPLY" || { warn "Telegram пропускаю."; bot=""; }
      else
        ok "Ваш chat_id: ${chat}"
      fi
    fi
  fi

  C_EMAIL="$email" C_SMTP_HOST="$host" C_SMTP_USER="$user" C_SMTP_PASS="$pass" C_BOT="$bot" C_CHAT="$chat" C_STORE="$store" write_config
  ok "Настройки сохранены в $CONF (доступ только у root и PHP)."
  NEED_TEST=1
}

run_test() {
  step "Проверяю отправку заявок (придёт тестовое письмо)"
  if runuser -u www-data -- php "$WEB/send.php" --test; then ok "Готово."; else warn "Есть проблемы — см. выше. Исправить: bash setup-site.sh --reconfigure"; fi
}

# =====================================================================
#  6. nginx
# =====================================================================
write_snippet() {
  cat > "$NGX_SNIP" <<EOF
# Сайт ${DOMAIN} — общие правила. Создано setup-site.sh, перезаписывается при каждом запуске.
root ${WEB};
index index.html;
charset utf-8;
absolute_redirect off;
server_tokens off;

add_header X-Content-Type-Options "nosniff" always;
add_header Referrer-Policy "strict-origin-when-cross-origin" always;
add_header X-Frame-Options "SAMEORIGIN" always;
add_header Permissions-Policy "camera=(), microphone=(), geolocation=()" always;

gzip on;
gzip_vary on;
gzip_comp_level 5;
gzip_min_length 512;
gzip_types text/css text/plain application/javascript application/json application/xml image/svg+xml;

error_page 404 /404.html;

location ^~ /.well-known/acme-challenge/ { root ${ACME}; default_type text/plain; try_files \$uri =404; }

# Служебные файлы не отдаём
location ~ /\. { return 404; }
location ^~ /_leads/ { return 404; }
location ~* \.(?:csv|log|md|sh|zip|bak|env|ini)$ { return 404; }

# Форма заявок — единственный PHP-файл, который выполняется
location = /send.php {
    client_max_body_size 64k;
    include fastcgi_params;
    fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    fastcgi_pass unix:$(fpm_socket);
    fastcgi_read_timeout 30s;
}
location ~ \.php$ { return 404; }

# /opushka → /opushka/
location ~ ^/(polutone|voronka|opushka|slotwise|privacy|soglasie)$ { return 301 /\$1/; }

# Кэш: картинки — месяц, шрифты — год, страницы — всегда свежие
location ~* \.(?:webp|jpe?g|png|svg|ico)$ { expires 30d; access_log off; try_files \$uri =404; }
location ~* \.woff2$ { expires 1y; access_log off; try_files \$uri =404; }
location / { expires -1; try_files \$uri \$uri/ =404; }
EOF
}

head_site() { # шапка файла сайта: комментарий + обезличенный формат журнала (контекст http)
  cat <<EOF
# ${DOMAIN} — создано setup-site.sh. $1

# IP посетителя пишется в журнал без последней части (1.2.3.4 → 1.2.3.0),
# чтобы на сервере за пределами РФ не хранились персональные данные.
map \$remote_addr \$antonshkel_anon_ip {
    "~^(?<anon_v4>\d+\.\d+\.\d+)\.\d+\$"          \$anon_v4.0;
    "~*^(?<anon_v6>[0-9a-f]*:[0-9a-f]*:[0-9a-f]*):"  \$anon_v6::;
    default                                    0.0.0.0;
}
log_format antonshkel_anon '\$antonshkel_anon_ip - - [\$time_local] "\$request" \$status \$body_bytes_sent "\$http_referer" "\$http_user_agent"';

EOF
}

write_site() { # $1 = http | https ; $2 = 1, если в сертификате есть www
  local v6="" h2="" l443="listen 443 ssl;" l443v6=""
  [[ -f /proc/net/if_inet6 ]] && v6="listen [::]:80;" && l443v6="listen [::]:443 ssl;"
  local ver; ver=$(nginx -v 2>&1 | sed 's/.*nginx\///; s/ .*//')
  if dpkg --compare-versions "$ver" ge 1.25.1; then h2="http2 on;"; else l443="listen 443 ssl http2;"; [[ -n $l443v6 ]] && l443v6="listen [::]:443 ssl http2;"; fi
  # Журнал сайта — отдельный файл, IP посетителей в нём обезличен (последняя часть обнулена).
  local alog="access_log ${ALOG} antonshkel_anon; log_not_found off;"

  if [[ $1 == http ]]; then
    { head_site "Пока без SSL; после «bash setup-site.sh --ssl» файл перезапишется."
      cat <<EOF
server {
    listen 80;
    ${v6}
    server_name ${DOMAIN} www.${DOMAIN};
    ${alog}
    include ${NGX_SNIP};
}
EOF
    } > "$NGX_SITE.new"
  else
    { head_site "Не правьте вручную: файл перезаписывается при каждом запуске."
      cat <<EOF
server {
    listen 80;
    ${v6}
    server_name ${DOMAIN} www.${DOMAIN};
    ${alog}
    location ^~ /.well-known/acme-challenge/ { root ${ACME}; default_type text/plain; try_files \$uri =404; }
    location / { return 301 https://${DOMAIN}\$request_uri; }
}
EOF
    } > "$NGX_SITE.new"
    if [[ ${2:-0} == 1 ]]; then
      cat >> "$NGX_SITE.new" <<EOF
server {
    ${l443}
    ${l443v6}
    ${h2}
    server_name www.${DOMAIN};
    ${alog}
    ssl_certificate     ${CERT_DIR}/fullchain.pem;
    ssl_certificate_key ${CERT_DIR}/privkey.pem;
    return 301 https://${DOMAIN}\$request_uri;
}
EOF
    fi
    cat >> "$NGX_SITE.new" <<EOF
server {
    ${l443}
    ${l443v6}
    ${h2}
    server_name ${DOMAIN};
    ${alog}
    ssl_certificate     ${CERT_DIR}/fullchain.pem;
    ssl_certificate_key ${CERT_DIR}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:antonshkel_ssl:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;
    add_header Strict-Transport-Security "max-age=31536000" always;
    include ${NGX_SNIP};
}
EOF
  fi
}

apply_nginx() { # $1 = http | https ; $2 = www в сертификате
  step "Настраиваю nginx ($([[ $1 == https ]] && echo 'с SSL' || echo 'пока без SSL'))"
  local had_old=0
  [[ -f $NGX_SITE ]] && { cp "$NGX_SITE" "$NGX_SITE.bak"; had_old=1; }
  [[ -f $NGX_SNIP ]] && cp "$NGX_SNIP" "$NGX_SNIP.bak"
  write_snippet
  write_site "$1" "${2:-0}"
  mv "$NGX_SITE.new" "$NGX_SITE"
  ln -sf "$NGX_SITE" "$NGX_LINK"
  if (( NGINX_FRESH )) && [[ -L /etc/nginx/sites-enabled/default ]]; then
    rm -f /etc/nginx/sites-enabled/default   # стандартная страница «Welcome to nginx» только что установленного nginx
  fi
  local t
  if ! t=$(nginx -t 2>&1); then
    printf '%s\n' "$t" | sed 's/^/    /'
    if (( had_old )); then mv "$NGX_SITE.bak" "$NGX_SITE"; [[ -f $NGX_SNIP.bak ]] && mv "$NGX_SNIP.bak" "$NGX_SNIP"
    else rm -f "$NGX_LINK" "$NGX_SITE" "$NGX_SNIP"; fi
    die "nginx не принял настройки — я вернул как было, работающие сайты не затронуты. Причина — в строках выше."
  fi
  rm -f "$NGX_SITE.bak" "$NGX_SNIP.bak"
  systemctl reload nginx 2>/dev/null || systemctl restart nginx
  ok "nginx перезагружен без ошибок."

  if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow 80/tcp >/dev/null && ufw allow 443/tcp >/dev/null && ok "В файрволе ufw открыты порты 80 и 443."
  fi
}

# =====================================================================
#  7. SSL
# =====================================================================
cert_has_www() {
  [[ -f $CERT_DIR/fullchain.pem ]] || return 1
  local san; san=$(openssl x509 -in "$CERT_DIR/fullchain.pem" -noout -ext subjectAltName 2>/dev/null || true)
  [[ $san == *"DNS:www.${DOMAIN}"* ]]
}

setup_ssl() {
  step "SSL-сертификат (замочек в браузере)"
  mkdir -p "$ACME/.well-known/acme-challenge"
  local me d w with_www=0
  me=$(server_ip); d=$(resolve4 "$DOMAIN"); w=$(resolve4 "www.$DOMAIN")
  info "IP этого сервера: ${me:-?}   ${DOMAIN} → ${d:-не найден}   www.${DOMAIN} → ${w:-не найден}"
  if [[ -z $d || $d != "$me" ]]; then
    warn "Домен пока не ведёт на этот сервер."
    info "Проверьте A-записи домена (@ и www → IP этого сервера), подождите 15–60 минут и запустите:"
    info "${B}bash setup-site.sh --ssl${N}"
    return 1
  fi
  [[ $w == "$me" ]] && with_www=1
  local d6 my6
  d6=$(dns_lookup "$DOMAIN" AAAA)
  if [[ -n $d6 ]]; then
    my6=$(ip -6 addr show scope global 2>/dev/null | awk '/inet6/{print $2}' | cut -d/ -f1 || true)
    if ! grep -qxF "$d6" <<<"$my6"; then
      warn "У домена есть AAAA-запись (IPv6) ${d6}, но это не адрес этого сервера."
      info "Let's Encrypt проверяет сначала IPv6 — удалите AAAA-запись в DNS-панели домена и запустите: bash setup-site.sh --ssl"
      return 1
    fi
  fi

  if [[ -f $CERT_DIR/fullchain.pem ]] && { (( ! with_www )) || cert_has_www; }; then
    ok "Сертификат уже есть, certbot будет продлевать его сам."
  else
    info "Сейчас программа certbot (Let's Encrypt) может задать вопросы на английском:"
    info "  • Enter email address — впишите ${DEFAULT_EMAIL}, на неё придут напоминания;"
    info "  • Terms of Service — это условия бесплатного сертификата, для выпуска нужно ответить Y;"
    info "  • share your email with EFF — рассылка фонда EFF, можно ответить N."
    local args=(certonly --webroot -w "$ACME" --cert-name "$DOMAIN" -d "$DOMAIN" --expand)
    (( with_www )) && args+=(-d "www.$DOMAIN")
    if ! certbot "${args[@]}"; then
      warn "Сертификат не выпустился. Частая причина — домен ещё не обновился в DNS. Подождите и запустите: bash setup-site.sh --ssl"
      return 1
    fi
    ok "Сертификат выпущен."
  fi
  mkdir -p /etc/letsencrypt/renewal-hooks/deploy
  printf '#!/bin/sh\nsystemctl reload nginx\n' > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
  chmod 755 /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
  cert_has_www && apply_nginx https 1 || apply_nginx https 0
  (( with_www )) || warn "www.${DOMAIN} пока не ведёт на сервер. Когда заработает — запустите bash setup-site.sh --ssl ещё раз."
  return 0
}

# =====================================================================
#  Сценарии
# =====================================================================
NEED_TEST=0
final_check() {
  step "Проверка"
  local scheme="http" code
  [[ -f $CERT_DIR/fullchain.pem ]] && scheme="https"
  local port=80; [[ $scheme == https ]] && port=443
  code=$(curl -s -o /dev/null -w '%{http_code}' -m 10 --resolve "${DOMAIN}:${port}:127.0.0.1" "${scheme}://${DOMAIN}/" || true)
  [[ $code == 200 ]] && ok "Главная страница отвечает (${scheme}, код 200)." || warn "Главная ответила кодом ${code:-нет ответа} — проверьте вывод выше."
  code=$(curl -s -o /dev/null -w '%{http_code}' -m 10 --resolve "${DOMAIN}:${port}:127.0.0.1" "${scheme}://${DOMAIN}/opushka/" || true)
  [[ $code == 200 ]] && ok "Страницы работ открываются." || warn "/opushka/ ответила кодом ${code:-нет ответа}"

  printf '\n%s\n' "${B}${G}Готово.${N}"
  if [[ $scheme == https ]]; then info "Сайт:   ${B}https://${DOMAIN}${N}"; else info "Сайт:   http://${DOMAIN}  (SSL — после «bash setup-site.sh --ssl»)"; fi
  info "Работы: /polutone  /voronka  /opushka  /slotwise"
  if [[ -f $CONF ]] && php -r '$c=require $argv[1]; exit(!empty($c["store_csv"]) ? 0 : 1);' "$CONF"; then
    info "Заявки: на почту и в файл ${LEADS}/leads.csv"
  else
    info "Заявки: на почту (на сервере не хранятся)"
  fi
  info "Обновить сайт: загрузите новый antonshkel.ru.zip в /root и снова запустите bash setup-site.sh"
}

case "$MODE" in
  install)
    check_ports
    install_packages
    load_answers
    [[ -f $ANSWERS ]] || ask_answers
    [[ $METRIKA_ASKED == 1 ]] || { ask_metrika; save_answers; }
    deploy_files
    [[ -f $CONF ]] || configure_notifications
    if [[ -f $CERT_DIR/fullchain.pem ]]; then
      cert_has_www && apply_nginx https 1 || apply_nginx https 0
    else
      apply_nginx http
      setup_ssl || true
    fi
    (( NEED_TEST )) && run_test
    ping_search
    final_check
    ;;
  ssl)
    [[ -d $WEB ]] || die "Сайт ещё не установлен. Сначала: bash setup-site.sh"
    install_packages
    setup_ssl || exit 1
    ping_search
    final_check
    ;;
  reconfigure)
    [[ -d $WEB ]] || die "Сайт ещё не установлен. Сначала: bash setup-site.sh"
    load_answers
    ask_answers
    if [[ -n $SRC_ARG ]] || find_zip quiet; then deploy_files; else fill_placeholders "$WEB"; fi
    configure_notifications
    run_test
    ;;
  test)
    [[ -f $WEB/send.php ]] || die "Сайт ещё не установлен."
    run_test
    ;;
  metrika)
    [[ -d $WEB ]] || die "Сайт ещё не установлен. Сначала: bash setup-site.sh"
    load_answers
    ask_metrika
    save_answers
    fill_placeholders "$WEB"
    if [[ -n $METRIKA_ID ]]; then
      ok "Метрика $METRIKA_ID подключена. Посетители увидят плашку о cookies; счётчик включится после «Разрешить»."
    else
      ok "Метрика отключена: плашки о cookies и счётчика на сайте нет."
    fi
    ;;
  ping)
    [[ -f $WEB/sitemap.xml ]] || die "Сайт ещё не установлен. Сначала: bash setup-site.sh"
    ping_search
    ;;
esac
