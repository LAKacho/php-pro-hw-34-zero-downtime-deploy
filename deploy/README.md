# Деплой мини-приложения

В этом каталоге хранится автоматический деплой приложения из [target](../) на виртуальный сервер с нулевым временем простоя.

## Что реализовано

- Git-пулл и сборка нового релиза в отдельной директории.
- Атомарный переключатель через symlink `current`.
- Разделение постоянных данных в `shared/` для `var` и выгруженных файлов.
- Проверка healthcheck до смены активного состояния.
- Простая интеграция с GitHub Actions для автозапуска после push в `main`.

## Конфигурация сервера

1. Создайте каталог для приложения:

```bash
sudo mkdir -p /srv/pspa-target/{config,releases,shared,repo}
```

2. Скопируйте пример файла конфигурации:

```bash
sudo cp deploy/config/production.env.example /srv/pspa-target/config/.env.production
```

3. Заполните real values для prod-среды и пометьте файл как секретный. В учебной постановке рекомендуем хранить его в отдельном закрытом репозитории настроек, а не в основном приложении.

4. Подключите Nginx/Apache так, чтобы корень документа был на `/srv/pspa-target/current/public`.

Пример:

```nginx
server {
    listen 80;
    server_name app.example.com;
    root /srv/pspa-target/current/public;
    index index.php;

    location / {
        try_files $uri /index.php$is_args$args;
    }

    location ~ \.php$ {
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_pass unix:/run/php/php-fpm.sock;
    }
}
```

## Запуск деплоя

```bash
chmod +x deploy/deploy.sh
APP_REPO=https://github.com/<your-user>/pspa-target.git \
DEPLOY_ROOT=/srv/pspa-target \
CONFIG_FILE=/srv/pspa-target/config/.env.production \
./deploy/deploy.sh
```

## Zero-downtime

Схема деплоя сделана по модели `releases + current`:

1. новый релиз собирается в отдельную папку;
2. общие данные лежат в `shared/`;
3. активный релиз меняется через `ln -sfn` на готовую сборку;
4. приложение проходит HTTP healthcheck до завершения релиза.

Это позволяет выкатить версию без остановки сервиса и быстро откатить билд при ошибке.

## Принцип закрытого репозитория настроек

Для прод-среды лучше держать secrets отдельно, например как приватный repo `infra/pspa-target-config` с файлом `.env.production` и шаблонами Nginx. На сервере монтируется только нужный config, а основной app-repo остаётся открытым для сборки кода.
