<?php
/**
 * Приём заявок с сайта antonshkel.ru
 *
 * Что делает:
 *   1) проверяет заявку (обязательные поля, согласие, защита от спама);
 *   2) присылает её письмом на почту — через SMTP (например, Mail.ru) или, если SMTP не настроен, через mail() хостинга;
 *   3) по желанию шлёт уведомление в Telegram;
 *   4) по желанию сохраняет заявку в файл leads/leads.csv рядом с папкой сайта (открывается в Excel).
 *
 * Настройки лежат НЕ здесь, а в файле config.php на уровень выше папки сайта
 * (на VPS его создаёт setup-site.sh). Поэтому при обновлении сайта их не нужно вводить заново.
 * Значения ниже — только запасные, если config.php нет.
 *
 * Проверка из консоли сервера:  php send.php --test
 */
declare(strict_types=1);
ini_set('display_errors', '0');

$CFG = [
    'notify_email'      => 'anton.shkel06@mail.ru', // куда присылать заявки
    'smtp_host'         => '',      // например 'smtp.mail.ru'. Пусто — письмо уходит через mail() хостинга
    'smtp_port'         => 465,     // 465 — SSL, 587 — STARTTLS
    'smtp_user'         => '',      // логин ящика, например 'anton.shkel06@mail.ru'
    'smtp_pass'         => '',      // пароль для внешнего приложения (не обычный пароль от почты)
    'mail_from'         => '',      // отправитель. Пусто — smtp_user или noreply@домен
    'bot_token'         => '',      // Telegram: токен бота от @BotFather. Пусто — Telegram не используется
    'chat_id'           => '',      // Telegram: ваш chat_id (число)
    'telegram_contacts' => false,   // true — в Telegram придёт вся заявка; false — только сигнал «новая заявка»
    'store_csv'         => true,    // true — сохранять заявки в leads/leads.csv на сервере
    'allowed_hosts'     => ['antonshkel.ru', 'www.antonshkel.ru'],
    'rl_secret'         => '',      // секрет для защиты от спама (его пишет setup-site.sh)
    'telegram_api'      => 'https://api.telegram.org', // адрес Telegram Bot API (можно указать свой прокси)
    'timezone'          => 'Europe/Moscow',
];
$cfgFile = dirname(__DIR__) . '/config.php';
if (is_file($cfgFile)) {
    $user = require $cfgFile;
    if (is_array($user)) $CFG = array_replace($CFG, $user);
}
date_default_timezone_set((string)$CFG['timezone']);

/* ------------------------------------------------------------------ */
/*  Письмо через SMTP (без sendmail на сервере)                        */
/* ------------------------------------------------------------------ */

/** Возвращает true или текст ошибки. */
function smtp_send(array $c, string $to, string $subject, string $body, string $replyTo = '')
{
    $host = (string)$c['smtp_host'];
    $port = (int)$c['smtp_port'];
    $user = (string)$c['smtp_user'];
    $from = (string)($c['mail_from'] ?: $user);
    $helo = (string)($c['allowed_hosts'][0] ?? 'localhost');
    $implicit = $port === 465;

    $ctx = stream_context_create(['ssl' => ['verify_peer' => true, 'verify_peer_name' => true, 'SNI_enabled' => true]]);
    $fp = @stream_socket_client(($implicit ? 'ssl://' : 'tcp://') . $host . ':' . $port, $errno, $errstr, 6, STREAM_CLIENT_CONNECT, $ctx);
    if (!$fp) return "нет соединения с {$host}:{$port} ({$errstr})";
    stream_set_timeout($fp, 12);

    $read = function () use ($fp): array {
        $text = '';
        while (($l = fgets($fp, 1024)) !== false) {
            $text .= $l;
            if (strlen($l) < 4 || $l[3] !== '-') break;
        }
        return [(int)substr($text, 0, 3), trim($text)];
    };
    $cmd = function (string $line, array $ok, string $shown = '') use ($fp, $read) {
        fwrite($fp, $line . "\r\n");
        [$code, $text] = $read();
        if (!in_array($code, $ok, true)) throw new RuntimeException(($shown ?: strtok($line, ' ')) . ' → ' . $text);
        return $text;
    };

    try {
        [$code, $text] = $read();
        if ($code !== 220) throw new RuntimeException('приветствие → ' . $text);
        $caps = $cmd('EHLO ' . $helo, [250]);
        if (!$implicit) {
            if (stripos($caps, 'STARTTLS') === false) throw new RuntimeException('сервер не поддерживает STARTTLS');
            $cmd('STARTTLS', [220]);
            if (!stream_socket_enable_crypto($fp, true, STREAM_CRYPTO_METHOD_TLS_CLIENT)) throw new RuntimeException('не удалось включить TLS');
            $caps = $cmd('EHLO ' . $helo, [250]);
        }
        if (preg_match('/AUTH[ =][^\r\n]*\bPLAIN\b/i', $caps)) {
            $cmd('AUTH PLAIN ' . base64_encode("\0" . $user . "\0" . (string)$c['smtp_pass']), [235], 'AUTH (логин или пароль)');
        } else {
            $cmd('AUTH LOGIN', [334]);
            $cmd(base64_encode($user), [334], 'AUTH (логин)');
            $cmd(base64_encode((string)$c['smtp_pass']), [235], 'AUTH (пароль)');
        }
        $cmd('MAIL FROM:<' . $from . '>', [250]);
        $cmd('RCPT TO:<' . $to . '>', [250, 251]);
        $cmd('DATA', [354]);

        $enc = fn(string $s): string => '=?UTF-8?B?' . base64_encode($s) . '?=';
        $headers = [
            'Date: ' . date('r'),
            'From: ' . $enc('Сайт antonshkel.ru') . ' <' . $from . '>',
            'To: <' . $to . '>',
            'Subject: ' . $enc($subject),
            'Message-ID: <' . bin2hex(random_bytes(8)) . '.' . time() . '@' . $helo . '>',
            'MIME-Version: 1.0',
            'Content-Type: text/plain; charset=UTF-8',
            'Content-Transfer-Encoding: base64',
        ];
        if ($replyTo !== '') $headers[] = 'Reply-To: <' . $replyTo . '>';
        $data = implode("\r\n", $headers) . "\r\n\r\n" . rtrim(chunk_split(base64_encode($body), 76, "\r\n")) . "\r\n.";
        $cmd($data, [250], 'отправка письма');
        @fwrite($fp, "QUIT\r\n");
        fclose($fp);
        return true;
    } catch (Throwable $e) {
        @fclose($fp);
        return $e->getMessage();
    }
}

/** Письмо: SMTP, если настроен, иначе mail(). Возвращает true или текст ошибки. */
function send_mail(array $c, string $subject, string $body, string $replyTo = '')
{
    $to = (string)$c['notify_email'];
    if ($to === '') return 'не указан адрес notify_email';
    if ($c['smtp_host'] !== '' && $c['smtp_user'] !== '' && $c['smtp_pass'] !== '') {
        return smtp_send($c, $to, $subject, $body, $replyTo);
    }
    $from = (string)($c['mail_from'] ?: 'noreply@' . ($c['allowed_hosts'][0] ?? 'localhost'));
    $headers = "From: {$from}\r\nMIME-Version: 1.0\r\nContent-Type: text/plain; charset=UTF-8\r\nContent-Transfer-Encoding: base64";
    if ($replyTo !== '') $headers .= "\r\nReply-To: {$replyTo}";
    $ok = @mail($to, '=?UTF-8?B?' . base64_encode($subject) . '?=', chunk_split(base64_encode($body)), $headers, '-f' . $from);
    return $ok ? true : 'mail() не сработал: на сервере нет почтовой программы — настройте SMTP';
}

/** Telegram. Возвращает true или текст ошибки. */
function send_telegram(array $c, string $text)
{
    if ($c['bot_token'] === '' || $c['chat_id'] === '') return 'не настроен';
    $url  = rtrim((string)($c['telegram_api'] ?? 'https://api.telegram.org'), '/') . '/bot' . $c['bot_token'] . '/sendMessage';
    $post = http_build_query(['chat_id' => (string)$c['chat_id'], 'text' => $text, 'disable_web_page_preview' => 'true']);
    if (function_exists('curl_init')) {
        $ch = curl_init($url);
        curl_setopt_array($ch, [CURLOPT_POST => true, CURLOPT_POSTFIELDS => $post, CURLOPT_RETURNTRANSFER => true,
                                CURLOPT_CONNECTTIMEOUT => 5, CURLOPT_TIMEOUT => 8]);
        $res  = curl_exec($ch);
        $code = (int)curl_getinfo($ch, CURLINFO_HTTP_CODE);
        $err  = curl_error($ch);
        if ($code === 200) return true;
        return $code ? "Telegram ответил {$code}: " . mb_substr((string)$res, 0, 200) : "нет связи с api.telegram.org ({$err})";
    }
    $ctx = stream_context_create(['http' => ['method' => 'POST', 'header' => 'Content-Type: application/x-www-form-urlencoded',
                                             'content' => $post, 'timeout' => 8, 'ignore_errors' => true]]);
    $res = @file_get_contents($url, false, $ctx);
    return ($res !== false && strpos($res, '"ok":true') !== false) ? true : 'нет связи с api.telegram.org';
}

/** Папка для заявок: на уровень выше папки сайта; запасной вариант — _leads рядом с сайтом. */
function leads_dir(bool $create)
{
    $dir = dirname(__DIR__) . '/leads';
    if ($create && !is_dir($dir)) @mkdir($dir, 0700, true);
    if (is_dir($dir) && is_writable($dir)) return $dir;
    $dir = __DIR__ . '/_leads';
    if ($create && !is_dir($dir)) @mkdir($dir, 0700, true);
    return (is_dir($dir) && is_writable($dir)) ? $dir : null;
}

/* ------------------------------------------------------------------ */
/*  Проверка из консоли: php send.php --test                           */
/* ------------------------------------------------------------------ */
if (PHP_SAPI === 'cli') {
    if (!in_array('--test', $argv ?? [], true)) { echo "Запуск: php send.php --test\n"; exit(0); }
    $okAny = false;
    $mark = fn($r) => $r === true ? "OK" : "ОШИБКА — {$r}";
    echo "Проверка приёма заявок\n";
    echo "  config.php:  " . (is_file($cfgFile) ? $cfgFile : 'не найден, используются значения по умолчанию') . "\n";
    $how = ($CFG['smtp_host'] !== '' && $CFG['smtp_pass'] !== '') ? "SMTP {$CFG['smtp_host']}:{$CFG['smtp_port']}" : 'mail()';
    $r = $CFG['notify_email'] !== '' ? send_mail($CFG, 'Проверка формы antonshkel.ru', "Это тестовое письмо. Если вы его видите — заявки с сайта будут приходить сюда.\n\n" . date('d.m.Y H:i')) : 'не указан адрес';
    echo "  Почта ({$CFG['notify_email']}, {$how}): " . $mark($r) . "\n";
    if ($r === true) $okAny = true;
    if ($CFG['bot_token'] !== '') {
        $t = send_telegram($CFG, "Проверка: уведомления о заявках с antonshkel.ru работают.");
        echo "  Telegram: " . $mark($t) . ($CFG['telegram_contacts'] ? '' : ' (приходит только сигнал, без контактов)') . "\n";
        if ($t === true && $CFG['telegram_contacts']) $okAny = true;
    } else {
        echo "  Telegram: не настроен\n";
    }
    if ($CFG['store_csv']) {
        $d = leads_dir(false);
        echo "  Файл заявок: " . ($d ? "{$d}/leads.csv — запись разрешена" : 'папка leads недоступна для записи') . "\n";
        if ($d) $okAny = true;
    } else {
        echo "  Файл заявок: выключен (store_csv = false)\n";
    }
    echo $okAny ? "Итог: заявки будут доходить.\n" : "Итог: заявки НЕ будут доходить — исправьте ошибки выше.\n";
    exit($okAny ? 0 : 1);
}

/* ------------------------------------------------------------------ */
/*  Обработка заявки                                                    */
/* ------------------------------------------------------------------ */
header('Content-Type: application/json; charset=utf-8');
header('X-Robots-Tag: noindex, nofollow');
header('Cache-Control: no-store');

function reply(int $code, array $data): void {
    http_response_code($code);
    echo json_encode($data, JSON_UNESCAPED_UNICODE);
    exit;
}

if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'POST') reply(405, ['ok' => false, 'error' => 'method']);

// Заявка должна прийти с вашего сайта
$src  = $_SERVER['HTTP_ORIGIN'] ?? ($_SERVER['HTTP_REFERER'] ?? '');
$host = strtolower((string)parse_url($src, PHP_URL_HOST));
$self = strtolower((string)preg_replace('/:\d+$/', '', $_SERVER['HTTP_HOST'] ?? ''));
if ($src !== '' && !in_array($host, $CFG['allowed_hosts'], true) && $host !== $self) reply(403, ['ok' => false, 'error' => 'origin']);

// Данные формы (JSON или обычная форма)
$raw = file_get_contents('php://input', false, null, 0, 20000);
$in  = json_decode($raw ?: '', true);
if (!is_array($in)) $in = $_POST;

$line = function ($v, int $max): string {
    $v = is_string($v) ? $v : '';
    $v = strip_tags($v);
    $v = preg_replace('/[\x00-\x1F\x7F]+/u', ' ', $v) ?? '';
    return mb_substr(trim(preg_replace('/\s+/u', ' ', $v) ?? ''), 0, $max);
};
$text = function ($v, int $max): string {
    $v = is_string($v) ? strip_tags($v) : '';
    $v = preg_replace('/[\x00-\x09\x0B-\x1F\x7F]+/u', ' ', $v) ?? '';
    return mb_substr(trim($v), 0, $max);
};

// Ловушка для ботов: это поле человек не видит. Заполнено — делаем вид, что всё хорошо.
if ($line($in['website'] ?? '', 200) !== '') reply(200, ['ok' => true]);

$name    = $line($in['name'] ?? '', 80);
$contact = $line($in['contact'] ?? '', 120);
$type    = $line($in['type'] ?? '', 60);
$budget  = $line($in['budget'] ?? '', 60);
$note    = $text($in['note'] ?? '', 2000);
$lang    = ($in['lang'] ?? 'ru') === 'en' ? 'en' : 'ru';

if ($name === '' || mb_strlen($contact) < 3) reply(422, ['ok' => false, 'error' => 'fields']);
if (($in['consent'] ?? '') !== '1')         reply(422, ['ok' => false, 'error' => 'consent']);

// Не чаще одной заявки в 30 секунд с одного адреса.
// В файле — только необратимый хэш IP с секретом; файлы старше 10 минут удаляются.
$dir = leads_dir(true);
$rlDir = $dir ?? sys_get_temp_dir();
foreach (glob($rlDir . '/rl_*') ?: [] as $f) { if (time() - (int)@filemtime($f) > 600) @unlink($f); }
$ip = $_SERVER['REMOTE_ADDR'] ?? '0.0.0.0';
$rl = $rlDir . '/rl_' . substr(hash_hmac('sha256', $ip, (string)($CFG['rl_secret'] ?? '') . __DIR__), 0, 32);
if (is_file($rl) && time() - (int)filemtime($rl) < 30) reply(429, ['ok' => false, 'error' => 'rate']);
@touch($rl);

$date = date('d.m.Y H:i');

// 1) Файл на сервере (если включён)
$saved = false;
if ($CFG['store_csv'] && $dir !== null) {
    $file  = $dir . '/leads.csv';
    $isNew = !is_file($file);
    if ($fh = @fopen($file, 'ab')) {
        if (flock($fh, LOCK_EX)) {
            if ($isNew) {
                fwrite($fh, "\xEF\xBB\xBF"); // чтобы Excel правильно показал кириллицу
                fputcsv($fh, ['Дата', 'Имя', 'Контакт', 'Что нужно', 'Бюджет', 'О проекте', 'Язык'], ';', '"', '');
            }
            $cell = fn(string $v): string => preg_match('/^[=+\-@\t\r]/', $v) ? "'" . $v : $v; // Excel не должен считать текст формулой
            $row  = array_map($cell, [$date, $name, $contact, $type, $budget, str_replace(["\r", "\n"], ' ', $note), $lang]);
            $saved = fputcsv($fh, $row, ';', '"', '') !== false;
            flock($fh, LOCK_UN);
        }
        fclose($fh);
    }
}

$body = "Новая заявка с сайта antonshkel.ru\n\n"
      . "Имя: {$name}\nКонтакт: {$contact}\nЧто нужно: {$type}\nБюджет: {$budget}\n"
      . ($note !== '' ? "О проекте: {$note}\n" : '')
      . "Язык: {$lang}\nДата: {$date}";

$subject = "Заявка с сайта: " . ($type !== '' ? $type : $name);
$replyTo = filter_var($contact, FILTER_VALIDATE_EMAIL) ? $contact : '';
$hasMail = $CFG['notify_email'] !== '';
$hasTg   = $CFG['bot_token'] !== '' && $CFG['chat_id'] !== '';
$tgFull  = $hasTg && $CFG['telegram_contacts'];
$tgMsg   = $CFG['telegram_contacts'] ? $body
         : "Новая заявка с сайта" . ($type !== '' ? ": {$type}" : '') . ($budget !== '' ? ", бюджет {$budget}" : '') . ". Подробности — на почте.";

// Чтобы человек не ждал: сначала самый быстрый канал, который сохраняет контакты клиента.
// Как только заявка где-то сохранилась — сразу отвечаем сайту «готово», остальное отправляем уже после ответа.
$mailDone = false; $tgDone = false; $delivered = $saved;
if (!$delivered && $tgFull) {                       // Telegram с полной заявкой — обычно доли секунды
    $delivered = send_telegram($CFG, $tgMsg) === true;
    $tgDone = true;
}
if (!$delivered && $hasMail) {                      // почта — если Telegram не настроен или не ответил
    $r = send_mail($CFG, $subject, $body, $replyTo);
    $delivered = $r === true;
    $mailDone = true;
    if ($r !== true) error_log('antonshkel send.php: письмо не ушло — ' . $r);
}
if (!$delivered) reply(500, ['ok' => false, 'error' => 'delivery']);

// Ответ сайту — сразу
ignore_user_abort(true);
@set_time_limit(60);
$out = json_encode(['ok' => true], JSON_UNESCAPED_UNICODE);
http_response_code(200);
header('Content-Length: ' . strlen($out));
header('Connection: close');
echo $out;
if (function_exists('fastcgi_finish_request')) { fastcgi_finish_request(); }
else { while (ob_get_level() > 0) @ob_end_flush(); @flush(); }

// Остальные каналы — в фоне, клиент их уже не ждёт
if ($hasMail && !$mailDone) {
    $r = send_mail($CFG, $subject, $body, $replyTo);
    if ($r !== true) error_log('antonshkel send.php: письмо не ушло — ' . $r);
}
if ($hasTg && !$tgDone) {
    $r = send_telegram($CFG, $tgMsg);
    if ($r !== true) error_log('antonshkel send.php: Telegram — ' . $r);
}
exit;
