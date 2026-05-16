# Railway VPN Deploy — VLESS + WebSocket

Готовый шаблон для деплоя личного VPN на **Railway.app** прямо из GitHub-репозитория, заточенный под обход блокировок РФ (ТСПУ/DPI).

## Что внутри

| Компонент | Зачем |
|---|---|
| **XRay-core** (VLESS over WebSocket) | сам VPN. WS-трафик едет внутри TLS-канала, который терминирует Railway на 443 порту — для ТСПУ это выглядит как обычный HTTPS к `*.up.railway.app`. |
| **Caddy** | reverse-proxy на единственном `$PORT`, который дал Railway. Раздаёт три пути: WebSocket → XRay, dashboard → Flask, всё остальное → фейковая страница nginx (decoy). |
| **Flask + qrcode** | мини-веб-морда: QR-код, ссылка `vless://…`, subscription URL для v2rayN/Hiddify. |

```
client ──HTTPS:443──> Railway edge ──HTTP:$PORT──> Caddy ──┬─ /ws/<secret>  → XRay (VLESS)
                                                            ├─ /<sub_path>/* → Flask (QR/подписка)
                                                            └─ /*            → decoy "Welcome to nginx"
```

## Почему именно так

* **Railway не даёт UDP** наружу — поэтому Reality / Hysteria2 / WireGuard не вариант. VLESS+WS работает поверх TCP/443 и проходит везде.
* **Railway сам делает TLS** на edge — внутри XRay TLS не настраиваем, что снимает кучу головной боли с сертификатами.
* **WebSocket** — самый совместимый транспорт: поддерживается всеми клиентами (v2rayNG, Hiddify, Streisand, NekoBox, v2rayN).
* **Decoy на корне** — если кто-то постучится в корень домена, увидит дефолтную страницу nginx, а не пустой 404 (меньше поводов попасть в эвристики РКН).

---

## Деплой за 5 минут

### 1. Залейте репозиторий на GitHub

```bash
cd railway-vpn-deploy
git init && git add . && git commit -m "init"
git branch -M main
git remote add origin https://github.com/<вы>/railway-vpn-deploy.git
git push -u origin main
```

### 2. Создайте проект на Railway

1. <https://railway.app> → **New Project** → **Deploy from GitHub repo** → выбрать `railway-vpn-deploy`.
2. Railway автоматически найдёт `Dockerfile` и `railway.toml`, начнёт сборку.
3. Дождитесь успешного билда (≈ 2–3 минуты).

### 3. Сгенерируйте публичный домен

В сервисе → **Settings → Networking → Generate Domain** — получите что-то вроде
`railway-vpn-deploy-production.up.railway.app`.

### 4. Зафиксируйте секреты (важно!)

При первом старте контейнер сгенерирует случайные `VLESS_UUID`, `WS_PATH`, `SUB_PATH`, `BASIC_AUTH_PASS` и **выведет их в логи**. Откройте **Deployments → Logs**, найдите блок:

```
=============================================================
  Railway VPN deployed
-------------------------------------------------------------
  Dashboard URL      : https://xxx.up.railway.app/yyyyyyyy
  Basic-Auth pass    : ...
  VLESS UUID         : ...
=============================================================
```

Скопируйте все 4 значения в **Settings → Variables**:

| Переменная | Значение из логов |
|---|---|
| `VLESS_UUID` | `…` |
| `WS_PATH` | `/…` |
| `SUB_PATH` | `/…` |
| `BASIC_AUTH_PASS` | `…` |

Затем нажмите **Redeploy**. Теперь UUID и пути не будут меняться при каждом редеплое.

### 5. Заберите конфиг

Откройте `https://<ваш-домен>.up.railway.app<SUB_PATH>/` — введите `admin` / `BASIC_AUTH_PASS` — получите страницу с QR-кодом и subscription-ссылкой.

---

## Клиенты

| Платформа | Рекомендую |
|---|---|
| Android | [v2rayNG](https://play.google.com/store/apps/details?id=com.v2ray.ang) или [Hiddify](https://github.com/hiddify/hiddify-next/releases) |
| iOS | [Streisand](https://apps.apple.com/app/streisand/id6450534064) или [V2Box](https://apps.apple.com/app/v2box/id6446814690) |
| Windows / macOS | [v2rayN](https://github.com/2dust/v2rayN/releases), [Hiddify-Next](https://github.com/hiddify/hiddify-next/releases) |
| Linux | [NekoRay](https://github.com/MatsuriDayo/nekoray/releases) |

**Способа два:**

1. Отсканировать QR со страницы dashboard.
2. Скопировать **Subscription URL** и вставить в раздел «Подписки» клиента — он сам подтянет конфиг и будет авто-обновлять.

---

## Split-routing: что не уходит через VPN

С апреля 2026 российские сервисы (Сбер, Яндекс, Ozon, Wildberries, банки, Госуслуги, операторы связи) **сами блокируют пользователей с VPN** по чёрному списку IP от РКН — это требование Минцифры от 15.04.2026. Если просто включить VPN и пойти на `sberbank.ru`, увидите «доступ ограничен».

Решается это **split-routing**: трафик к российским сервисам идёт напрямую (минуя VPN), всё остальное — через VPN. Реализовано в двух местах:

### 1. На стороне сервера (XRay)

XRay-сервер в Railway автоматически **режет outbound к РФ** (`geoip:ru` + актуальный список [UnRKN/ru-blocklist](https://github.com/UnRKN/ru-blocklist) с банками/маркетплейсами/госсайтами). Это защита нашего Railway-IP — он не светится в логах российских сервисов и не попадает в чёрный список РКН быстрее.

Если клиент случайно отправит запрос к Сберу через VPN, сервер вернёт reject → клиент быстро поймёт и переотправит напрямую (если split-routing настроен).

### 2. На стороне клиента (Clash subscription) — **рекомендуется**

Самый простой способ — использовать **Clash subscription** вместо обычной v2ray. На dashboard есть отдельная кнопка «Subscription — Clash ⚡ для РФ». Эта подписка отдаёт готовый Mihomo/Clash-конфиг, в котором уже прописаны правила:

- `*.ru`, `*.su`, `*.рф`, `geoip:ru` → DIRECT (мимо VPN)
- Sberbank, Yandex, Ozon, Wildberries, VK, Mail.ru, Госуслуги, банки → DIRECT
- Всё остальное → PROXY (через VPN)

**Поддержка Clash-формата:**

| Клиент | Платформа | Поддержка Clash |
|---|---|---|
| **Hiddify** | Android / iOS / Win / Mac / Linux | ✅ нативно |
| **Mihomo Party** | Win / Mac / Linux | ✅ нативно |
| **Stash** | iOS | ✅ нативно |
| **ClashX Meta** | macOS | ✅ нативно |
| **v2rayN** (Pro/Core: Mihomo) | Windows | ✅ через core swap |
| v2rayNG | Android | ❌ нет; используйте Hiddify |
| Streisand | iOS | ❌ нет; используйте Hiddify |

### Ручная настройка split-routing в v2rayNG (если без Clash)

Если хочется остаться на v2rayNG/Streisand, split-tunnel можно настроить вручную:

1. **v2rayNG** → ☰ → **Routing settings** → **Predefined rules**: выбрать `bypass mainland China` (это закроет китайские домены; для РФ нужно дополнить вручную).
2. Добавить правило: **Domain** = `geosite:category-ru-cn,ru,рф,sberbank,yandex,ozon,wildberries,mail.ru,vk.com,ok.ru,kinopoisk.ru,gosuslugi.ru,nalog.ru` → **Outbound tag**: `direct`.
3. **Hiddify** → Settings → **Routing** → включить `Bypass LAN and Russia` (есть в свежих версиях).

Либо использовать готовые правила от [runetfreedom/russia-v2ray-rules-dat](https://github.com/runetfreedom/russia-v2ray-rules-dat) — там есть geosite-файлы для прямой подгрузки.

---

## Переменные окружения

Все опциональны (при отсутствии — генерируются случайно).

| Имя | Назначение |
|---|---|
| `VLESS_UUID` | UUID клиента VLESS |
| `WS_PATH` | секретный путь WebSocket, начинается с `/` |
| `SUB_PATH` | секретный путь к dashboard / подписке |
| `BASIC_AUTH_USER` | логин dashboard (default: `admin`) |
| `BASIC_AUTH_PASS` | пароль dashboard |
| `PROFILE_NAME` | имя профиля в клиенте (default: `Railway-VPN`) |
| `PUBLIC_HOST` | переопределить домен (обычно не нужно — берётся `RAILWAY_PUBLIC_DOMAIN`) |
| `PORT` | задаёт Railway, не трогать |

---

## Локальный тест

```bash
docker build -t railway-vpn .
docker run --rm -p 8080:8080 \
  -e PUBLIC_HOST=localhost \
  -e VLESS_UUID=$(python -c 'import uuid;print(uuid.uuid4())') \
  -e WS_PATH=/ws-test \
  -e SUB_PATH=/dash-test \
  -e BASIC_AUTH_PASS=test1234 \
  railway-vpn
```

Открыть <http://localhost:8080/dash-test/> (admin / test1234). На localhost TLS нет — ссылка `vless://` будет нерабочей (`security=tls` ожидает HTTPS); это нормально, на Railway будет работать.

---

## Безопасность

* Все секретные эндпоинты висят на длинных случайных путях (`/dashboard-<16-char-token>`).
* Dashboard защищён Basic-Auth, subscription-эндпоинт — только обфускацией пути (так как мобильные клиенты не умеют Basic-Auth в подписке).
* XRay блокирует доступ во внутренние сети (`geoip:private`) и BitTorrent.
* Для смены любого секрета — поменяйте переменную в Railway и сделайте Redeploy.

## Известные ограничения Railway

* **Нет UDP** наружу → нельзя использовать Reality/Hysteria/WireGuard. Только TCP-based (что мы и делаем).
* **Free $5/мес** обычно хватает на личное использование (≈ 50–80 ГБ трафика).
* **IP Railway известны** — крупные сервисы (Netflix и т.п.) могут резать. Для YouTube/Twitter/Instagram работает стабильно.

## Лицензия

MIT. Используйте на свой риск, только для законных целей в вашей юрисдикции.
