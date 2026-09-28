<?php
// Пример настроек формы заявок antonshkel.ru.
//
// На сервере этот файл создаёт deploy/setup-site.sh и кладёт его на уровень выше папки сайта:
//   /var/www/antonshkel.ru/config.php   (права 640, владелец root:www-data)
// Так пароли не лежат в папке, которая открыта из интернета, и не попадают в git.
//
// Вручную: скопируйте файл в /var/www/antonshkel.ru/config.php и впишите свои значения.
// Изменить позже: sudo bash deploy/setup-site.sh --reconfigure
// Проверить доставку: php /var/www/antonshkel.ru/public/send.php --test

return [
    'notify_email'      => 'you@example.com',   // куда присылать заявки
    'smtp_host'         => 'smtp.mail.ru',      // SMTP-сервер почты. Пусто — отправка через mail() хостинга
    'smtp_port'         => 465,                 // 465 — SSL, 587 — STARTTLS
    'smtp_user'         => 'you@example.com',   // логин ящика
    'smtp_pass'         => '',                  // пароль для внешнего приложения (не обычный пароль от почты)
    'bot_token'         => '',                  // Telegram: токен бота от @BotFather. Пусто — Telegram выключен
    'chat_id'           => '',                  // Telegram: ваш chat_id (число)
    'telegram_contacts' => false,               // true — в Telegram вся заявка; false — только сигнал «новая заявка»
    'store_csv'         => false,               // true — дополнительно сохранять заявки в leads/leads.csv
    'rl_secret'         => 'замените-на-случайную-строку', // секрет для антиспама: php -r 'echo bin2hex(random_bytes(16));'
];
