# Установка на сервер

Сайт ставится на VPS с Ubuntu или Debian одной командой. Скрипт `deploy/setup-site.sh`:

- ставит nginx, PHP-FPM и certbot, если их нет;
- раскладывает сайт в `/var/www/antonshkel.ru/public`, а прошлую версию сохраняет для отката;
- создаёт настройки формы `config.php` вне папки сайта;
- выпускает бесплатный SSL-сертификат Let's Encrypt;
- сообщает Яндексу о страницах через IndexNow.

Другие сайты в nginx, ботов и папку `/root` скрипт не трогает. Если порты 80 или 443 заняты не nginx, он останавливается и ничего не меняет.

## Что понадобится

- VPS с Ubuntu 22.04+ или Debian 12+ и доступ root по SSH;
- домен. В его DNS нужны A-записи `@` и `www` с IP сервера;
- почта для заявок. Для Mail.ru, Яндекса и Gmail нужен **пароль для внешних приложений**: его создают в настройках безопасности ящика.

> Скрипт написан под antonshkel.ru. Для другого домена поменяйте `DOMAIN`, `DEFAULT_EMAIL` и `DEFAULT_METRIKA` в начале `deploy/setup-site.sh`, а также адреса в `site/sitemap.xml`, `site/robots.txt` и в теге canonical на страницах.

## Первая установка

```bash
git clone https://github.com/antonshkelll/antonshkel.ru.git
cd antonshkel.ru
sudo bash deploy/setup-site.sh site
```

Скрипт спросит:

1. **Отчество и ИНН** — для политики конфиденциальности и согласия. Хранятся только на сервере. Можно пропустить, тогда на страницах останутся пометки.
2. **Номер счётчика Яндекс Метрики** — по желанию. Минус (`-`) выключает Метрику и плашку cookies.
3. **Почту и пароль приложения** — для отправки заявок. Пароль при вводе не виден.
4. **Telegram-бота** — по желанию: токен от @BotFather и ваш chat_id.

Если домен ещё не смотрит на сервер, сайт заработает по HTTP. Когда DNS обновится (обычно 15–60 минут), выпустите сертификат:

```bash
sudo bash deploy/setup-site.sh --ssl
```

Без git можно так: запаковать содержимое папки `site` в `antonshkel.ru.zip`, положить архив рядом со скриптом (или в `/root`) и запустить `sudo bash setup-site.sh`.

## Команды

| Команда | Что делает |
|---|---|
| `sudo bash deploy/setup-site.sh site` | Установить или обновить сайт из папки `site` |
| `sudo bash deploy/setup-site.sh --ssl` | Выпустить SSL, когда домен начал вести на сервер |
| `sudo bash deploy/setup-site.sh --reconfigure` | Заново ввести почту, Telegram, отчество и ИНН |
| `sudo bash deploy/setup-site.sh --test` | Отправить тестовую заявку на почту и в Telegram |
| `sudo bash deploy/setup-site.sh --metrika` | Подключить, поменять или выключить Яндекс Метрику |
| `sudo bash deploy/setup-site.sh --ping` | Ещё раз сообщить Яндексу о страницах (IndexNow) |
| `sudo bash deploy/setup-site.sh --rollback` | Вернуть предыдущую версию сайта |

## Обновление

```bash
cd antonshkel.ru
git pull
sudo bash deploy/setup-site.sh site
```

Почту, Telegram, SSL, отчество и ИНН скрипт помнит и заново не спрашивает. Файлы подтверждения Яндекс Вебмастера и Google переносятся в новую версию сами.

## Что где лежит на сервере

| Путь | Что это |
|---|---|
| `/var/www/antonshkel.ru/public` | Сайт |
| `/var/www/antonshkel.ru/public.prev` | Прошлая версия для `--rollback` |
| `/var/www/antonshkel.ru/config.php` | Настройки формы: почта, пароль, токен (права 640) |
| `/var/www/antonshkel.ru/.setup-answers` | Ответы на вопросы скрипта |
| `/var/www/antonshkel.ru/.indexnow-key` | Ключ IndexNow |
| `/etc/nginx/sites-available/antonshkel.ru.conf` | Конфиг nginx (перезаписывается скриптом) |
| `/var/log/nginx/antonshkel.ru.access.log` | Журнал посещений, IP обезличены |

## Персональные данные

- Заявки уходят письмом на почту. Если сервер стоит за пределами России, на нём они не сохраняются, чтобы соблюсти требование о хранении данных россиян в России. На российском сервере можно включить копию в `leads/leads.csv` (`store_csv`).
- Яндекс Метрика и значок ИКС загружаются только после согласия в плашке cookies.
- В журнале nginx последняя часть IP-адреса обнуляется.

Перед запуском сбора заявок оператор персональных данных подаёт уведомление в Роскомнадзор.
