# Конфигурация виртуальной машины devops-vm

Восстановление после отката на снимок `01-clean-install` выполняется по этому документу (лимит 10 минут на практической работе № 6).

## 1. Параметры машины

| Параметр | Значение |
|---|---|
| Гипервизор | VirtualBox 7.2, Apple Silicon (arm64) |
| Имя ВМ | `devops-vm` |
| ОС | Ubuntu Server 24.04.3 LTS (ARM64) |
| Память | 2048 МБ |
| Ядра | 2 |
| Диск | 25 ГБ, динамический |
| Прошивка | EFI |
| Видео | QemuRamFB |

## 2. Сетевые интерфейсы

| Адаптер | Тип | Интерфейс в госте | Адрес | Назначение |
|---|---|---|---|---|
| NIC 1 | NAT | `enp0s8` | `10.0.2.15/24` | исходящий интернет, проброс SSH |
| NIC 2 | Host-only (`HostOnly`) | `enp0s9` | `192.168.56.102/24` | входящие с Mac по имени `devops.local` |

Адрес хоста в Host-only: `192.168.56.101`. Проверка: `ip -br a`.

## 3. Правило проброса портов

NAT, адаптер 1:

- имя правила: `ssh`
- протокол: TCP
- хост: `127.0.0.1:2222`
- гость: `2222` (после hardening; сразу после установки гость слушал `22`)

После смены порта sshd правило обязательно менять, иначе новые сессии не откроются.

На Mac в `~/.ssh/config`:

```
Host devops
  HostName 127.0.0.1
  Port 2222
  User devops
  IdentityFile ~/.ssh/devops_vm
  IdentitiesOnly yes

Host devops.local
  HostName 192.168.56.102
  Port 2222
  User devops
  IdentityFile ~/.ssh/devops_vm
  IdentitiesOnly yes
```

В `/etc/hosts` Mac:

```
192.168.56.102 devops.local
```

## 4. Учётные записи

| Имя | uid | Группы | Аутентификация |
|---|---|---|---|
| `student` | 1000 | `student`, `sudo` | пароль (консоль ВМ, аварийный доступ) |
| `devops` | 1001 | `devops`, `sudo` | только ключ ed25519 |

Создание пользователя:

```bash
sudo adduser devops
sudo usermod -aG sudo devops
```

Ключ на Mac: `~/.ssh/devops_vm` (ed25519). Открытый ключ — в `/home/devops/.ssh/authorized_keys`.

Права:

```bash
sudo -u devops mkdir -p /home/devops/.ssh
sudo chmod 700 /home/devops/.ssh
sudo chmod 600 /home/devops/.ssh/authorized_keys
sudo chown -R devops:devops /home/devops/.ssh
```

## 5. Служба SSH

Рабочий drop-in: `/etc/ssh/sshd_config.d/99-hardening.conf` (лексически позже `50-cloud-init.conf`, но **первое** вхождение директивы побеждает, поэтому cloud-init нужно комментировать).

Содержимое `99-hardening.conf`:

```
Port 2222
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
PermitEmptyPasswords no
MaxAuthTries 3
LoginGraceTime 30
AllowUsers devops
X11Forwarding no
ClientAliveInterval 300
ClientAliveCountMax 2
```

В `/etc/ssh/sshd_config.d/50-cloud-init.conf` закомментировать:

```
#PasswordAuthentication yes
```

Резервная копия: `/etc/ssh/sshd_config.backup`.

Активация (сессию SSH не закрывать):

```bash
sudo sshd -t
sudo systemctl disable --now ssh.socket
sudo systemctl enable --now ssh.service
sudo systemctl restart ssh
sudo ss -tlnp | grep sshd   # ожидается 0.0.0.0:2222
```

Достоверные значения: `sudo sshd -T`. Ожидается `port 2222`, `permitrootlogin no`, `passwordauthentication no`, `maxauthtries 3`, `allowusers devops`.

## 6. Правила межсетевого экрана

Политики: incoming `deny`, outgoing `allow`. Правило SSH создаётся **до** `ufw enable`.

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 2222/tcp comment 'SSH'
sudo ufw allow 80/tcp comment 'HTTP'
sudo ufw allow 443/tcp comment 'HTTPS'
sudo ufw enable
sudo ufw delete allow 2222/tcp
sudo ufw limit 2222/tcp comment 'SSH rate-limited'
sudo ufw logging medium
```

Не использовать `ufw allow ssh`: `/etc/services` сопоставит имя порту 22, а sshd слушает 2222.

Итог `ufw status verbose`: `2222/tcp LIMIT`, `80/tcp ALLOW`, `443/tcp ALLOW`.

## 7. Снимки состояния

| Имя | Когда снимать |
|---|---|
| `01-clean-install` | Ubuntu установлена, `apt upgrade` выполнен, сеть поднята |
| `02-keys-configured` | пользователь `devops`, ключ, `Host devops` |
| `03-ssh-hardened` | порт 2222, пароли выключены, `AllowUsers devops`, sshd перезапущен |
| `04-nginx-https` | Nginx, HTTPS, HTTP 301, самоподписанный сертификат `devops.local` |
| `05-docker-compose` | Docker Engine, Compose (приложение + PostgreSQL), том `app_db_data`, Nginx `location /app/` |

Проверка скриптом: `sudo bash scripts/audit.sh` (код возврата 0). Для негативного теста временно `MaxAuthTries 10` — код возврата 1, затем вернуть `3`.

## 8. Веб-сервер

Пакет: `nginx` 1.24.0 (репозиторий Ubuntu, не `nginx-full`).

Конфигурация ресурса: `/etc/nginx/sites-available/devops-site`, символическая ссылка в `/etc/nginx/sites-enabled/devops-site`. Стандартный ресурс отключён удалением ссылки `/etc/nginx/sites-enabled/default` (файл в `sites-available` сохранён).

Каталог ресурса: `/var/www/devops-site`, владелец `devops:devops`, каталог `755`, файлы `644`. Рабочий процесс читает файлы как `www-data` за счёт прав «остальные»; запись веб-серверу не нужна и не выдаётся.

Сертификат и ключ:

| Путь | Владелец | Права |
|---|---|---|
| `/etc/ssl/certs/devops.crt` | `root:root` | `644` |
| `/etc/ssl/private/devops.key` | `root:root` | `600` |

Ключ за пределы `/etc/ssl/private` не копируется и в репозиторий не попадает. Открытый сертификат скопирован на хост доверенным каналом SSH: `~/devops.crt`.

Формирование (365 суток, SAN обязателен, IP в SAN нет — адрес Host-only с DHCP):

```bash
sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout /etc/ssl/private/devops.key \
  -out /etc/ssl/certs/devops.crt \
  -subj "/CN=devops.local" \
  -addext "subjectAltName=DNS:devops.local"
```

Проверка срока: `sudo openssl x509 -in /etc/ssl/certs/devops.crt -noout -dates`. Ожидается `notAfter` через год от даты выпуска.

HTTP-блок: `return 301 https://$host$request_uri`. HTTPS: `listen 443 ssl`, протоколы `TLSv1.2 TLSv1.3`. Заголовок HSTS не добавляется.

Применение конфигурации только так: `sudo nginx -t && sudo systemctl reload nginx`.

Доставка с хоста: `scripts/deploy.sh` (`rsync -avz --delete --chmod=D755,F644`, одно SSH-соединение, `BatchMode=yes`, проверка `curl --cacert`).

## 9. Контейнеризация

Пакет `docker.io` из репозитория Ubuntu не используется. Docker Engine ставится из официального репозитория `download.docker.com` (архитектура ARM64, код Ubuntu `noble`).

Ключ и список пакетов:

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=arm64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu noble stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
```

Фактические версии:

| Компонент | Значение |
|---|---|
| Docker Engine | 29.9.2 (`5:29.9.2-1~ubuntu.24.04~noble`) |
| Compose plugin | v5.6.1 |
| Репозиторий | `https://download.docker.com/linux/ubuntu noble/stable arm64` |
| Файл списка | `/etc/apt/sources.list.d/docker.list` |
| Ключ | `/etc/apt/keyrings/docker.asc` |

Служба: `sudo systemctl enable --now docker`. Ожидается `systemctl is-active docker` → `active`.

Группа `docker` (gid 988): только `devops`. Добавление:

```bash
sudo usermod -aG docker devops
```

После `usermod` нужна **новая** SSH-сессия, иначе сокет `/var/run/docker.sock` недоступен (permission denied). Учётные записи без `sudo` в группу `docker` не включать: участник группы может смонтировать `/` на запись и фактически получить права root.

Проект на сервере: `/home/devops/app` (копия каталога `app/` репозитория). Доставка с хоста:

```bash
rsync -avz --delete --exclude=.env \
  -e "ssh -o BatchMode=yes" \
  app/ devops:~/app/
```

Секреты не в git и не в контексте сборки. На сервере файл `/home/devops/app/.env` создаётся из `app/.env.example`, права `600`, владелец `devops:devops`:

```bash
cp ~/app/.env.example ~/app/.env
chmod 600 ~/app/.env
```

Содержимое (пароль задаётся на сервере, в репозиторий не попадает):

```
POSTGRES_DB=app
POSTGRES_USER=app
POSTGRES_PASSWORD=<секрет>
DB_HOST=db
```

Файл `app/.dockerignore` исключает `.env` из контекста сборки. Образ: `devops-app:1.0`, процесс gunicorn от пользователя `app` (uid 999), порт контейнера 5000.

Конфигурация Compose (`/home/devops/app/docker-compose.yml`):

- сеть проекта `backend` (bridge); приложение резолвит СУБД по имени `db`;
- том `db_data` → на хосте `app_db_data` (`docker volume ls`);
- СУБД `postgres:16-alpine`, порт 5432 **не публикуется**, healthcheck `pg_isready`;
- приложение публикует только `127.0.0.1:5000:5000`;
- `depends_on: db: condition: service_healthy`;
- `restart: unless-stopped`.

Запуск:

```bash
cd ~/app
docker compose up -d --build
docker compose ps    # app-db-1 (healthy), app-app-1 127.0.0.1:5000->5000
```

Имена контейнеров: `app-app-1`, `app-db-1`. Проверка портов: `sudo ss -tlnp | grep -E ':(5000|5432)\b'` — ожидается только `127.0.0.1:5000`; `5432` на сервере не слушает.

`docker compose down` сохраняет том; `docker compose down -v` удаляет данные (на рабочем сервере не выполнять без необходимости).

Обратный прокси в HTTPS-блоке `/etc/nginx/sites-available/devops-site`:

```
location /app/ {
    proxy_pass http://127.0.0.1:5000/;
    proxy_set_header Host              $host;
    proxy_set_header X-Real-IP         $remote_addr;
    proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
}
```

Завершающий `/` в `proxy_pass` снимает префикс `/app/`: `/app/health` → `/health`. Применение: `sudo nginx -t && sudo systemctl reload nginx`.

Проверка с хоста: `curl --cacert ~/devops.crt https://devops.local/app/` и `/app/health`; статический ресурс `curl --cacert ~/devops.crt -I https://devops.local/` остаётся 200. Если контейнер приложения остановлен, Nginx возвращает 502 и пишет в `/var/log/nginx/devops-site.error.log` строку `connect() failed (111: Connection refused) while connecting to upstream`.
