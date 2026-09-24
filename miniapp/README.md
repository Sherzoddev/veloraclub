# Velora Club Telegram Mini App

`client-webapp.html` — мобильный интерфейс клиентского приложения клуба. Его
отдаёт HTTPS-сервис Railway с корректным `Content-Type: text/html`, а защищённые
действия выполняет Supabase Edge Function `client-webapp`, которая проверяет
Telegram `initData`.

Открывать страницу нужно с параметром клуба:

```text
https://velora-club-miniapp-production.up.railway.app/?c=<club_id>
```

Клиент, касса и Telegram-бот используют одни записи `customers`, `resources`,
`reservations`, `orders`, `loyalty_tiers` и `waitlist_entries`.

Защищённый API находится в `supabase/functions/client-webapp/index.ts`. Он
проверяет подпись Telegram `initData`, не отдаёт service-role ключ браузеру и
разрешает клиенту читать или менять только данные его Telegram-профиля в
выбранном клубе.

Поддержанные действия API: загрузка профиля, столов и свободных слотов,
создание/отмена брони, очередь, история посещений, уведомления и подтверждение
нового уровня лояльности. QR карты содержит `CARD:<card_token>`; этот же формат
понимает Windows-касса.

Railway запускает `server.js` и раздаёт `client-webapp.html`. Публичная страница
не содержит ключей Supabase, а все операции выполняет через проверенную Edge
Function. Не размещайте Mini App в Supabase Storage: его защитные заголовки
отдают HTML как `text/plain`, из-за чего Telegram показывает исходный код.
