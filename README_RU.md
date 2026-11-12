# IzviniteVpn v2

Flutter Android-клиент на sing_box и API авторизации на Cloudflare Workers + D1.

## Что находится в репозитории
- Android-клиент: вход по нику и ключу, оранжевая тема, выбор серверов из BLACK LTE.
- Cloudflare Worker: авторизация, сессии, смена первоначального пароля, управление пользователями, лимит устройств и журнал событий.
- D1 schema: таблицы пользователей, устройств и событий.
- GitHub Actions: отдельная сборка APK и отдельное развёртывание API.

## Однократная настройка Cloudflare
1. В Cloudflare Dashboard создай D1 database с именем `izvinitevpn`.
2. В настройках GitHub-репозитория открой Settings → Secrets and variables → Actions.
3. В Variables добавь:
   - `CLOUDFLARE_ACCOUNT_ID` — Account ID из Cloudflare.
   - `CLOUDFLARE_D1_DATABASE_ID` — UUID созданной D1 database.
4. В Secrets добавь:
   - `CLOUDFLARE_API_TOKEN` — API token Cloudflare с разрешениями Workers Scripts:Edit и D1:Edit для нужного аккаунта.
   - `ADMIN_BOOTSTRAP_KEY` — первоначальный секрет администратора (не публиковать и не отправлять в чат).
   - `JWT_SECRET` — случайная секретная строка минимум 32 символа.
5. Запусти Actions → Deploy IzviniteVpn auth API → Run workflow.
6. После успешного deploy открой лог шага Deploy Worker и скопируй URL вида `https://izvinitevpn-auth.<твой-subdomain>.workers.dev`.
7. В Settings → Secrets and variables → Actions → Variables добавь `API_BASE_URL` с этим HTTPS URL без завершающего слеша.
8. Запусти Actions → Build IzviniteVpn APK → Run workflow и скачай новый `IzviniteVpn-arm64-apk`.

Первоначальный вход администратора: ник `Aqsone` и секрет из `ADMIN_BOOTSTRAP_KEY`. При первом входе приложение потребует сменить его на пароль не короче 12 символов. Не вставляй секреты в исходный код, README или сообщения.

## Важно перед использованием
- Текущий APK, собранный до установки `API_BASE_URL`, не подключён к API. Нужен новый APK после настройки переменной.
- Успешный deploy API и успешная сборка APK ещё не доказывают, что импорт конкретной подписки и VPN-туннель работают. Их необходимо отдельно проверить на Android.
- Подписка: https://github.com/FLAT447/v2ray-lists/raw/refs/heads/main/BLACK_LTE.txt
- Уведомления администратора пока представлены журналом событий в панели, без push-уведомлений ОС.
- Ping в клиенте не гарантирует доступность всех UDP-протоколов.
- sing_box и sing-box core распространяются по GPL-3.0-or-later. Соблюдай лицензионные условия при распространении.
