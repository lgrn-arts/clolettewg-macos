# CloletteWG

<img src="Assets/AppIcon.png" alt="CloletteWG icon" width="96">

[English](#english) · [Русский](#а-теперь-на-русском)

## English

A tiny AmneziaWG client for older macOS versions (because there wasn't one), written in Objective-C and Go. It lives in the tray and does exactly what you need: connects the tunnel, shows its status, and doesn't ask for your password every single time. That's it.

Tested on OS X Mavericks and Catalina. Other versions are untested, so feedback is welcome — hence the beta. Anything older than Mavericks is a no-go.

### What can this thing do?

- Import regular `.conf` files and `vpn://` links.
- Work with legacy AWG, AWG 3.x, and plain WireGuard configs.
- Switch, edit, and delete configs.
- Show the endpoint, handshake, RX/TX, port, and daemon log.

Configs live here:

```text
~/Library/Application Support/CloletteWG/Tunnels.plist
```

Only the owner can read the file (`0600`).

### What you need to build it

- macOS with Xcode Command Line Tools.
- Python 3, but only for the DMG installer.
- An Intel Mac or Apple Silicon with Rosetta 2.

### Build

```sh
./build.sh
```

On the first run, the script downloads the official Go toolchains, verifies them, and builds two daemons:

- Go 1.10.8 for Mavericks and versions before Catalina;
- Go 1.22.12 for Catalina and newer.

How else would it work?

If you have just built the daemons with `make core`, you can skip rebuilding them:

```sh
SKIP_CORE_BUILD=1 ./build.sh
```

### Install

1. Drag `CloletteWG.app` into `/Applications`.
2. Launch it from there. This is required for daemon setup; otherwise the app will show a warning and refuse to run.
3. Enter your administrator password once to install the daemon.
4. Import a config or paste a link.
5. Profit.

The service itself goes into `/Library/PrivilegedHelperTools`. No more passwords after that: the app talks to the daemon through a local socket available to the `admin` group and protected by a token.

When updating, the app compares the installed daemon with the one bundled in `.app`. If they differ, it offers an update.

### Quirks

- **Uninstall Service…** removes the daemon and launchd service but keeps your configs.

### Limitations

- Only the first `[Peer]` from the config is used.
- IPv6 does not work and is not supported. This is an AmneziaWG kernel limitation, and it's intentional.

### Make commands

```sh
make app        # only the .app
make dmg        # .app and DMG
make core       # rebuild both daemons
make test-app   # parser and tunnel-name tests on macOS
make test-core  # engine tests on macOS or Linux
make test       # both suites
```

You can override `SDKROOT` and `CLANG` if needed. The GUI is built with deployment target `10.9`, and every component is `x86_64`.

### Sources this app is glued together from

- CloletteWG UI, MIT, based on a barebones Swift app: `maloyan/amnezia-cloak`.
- Binaries for and from Mavericks: `TheFrutigerDaniel/amneziawg-mavericks`.
- The engine is based on `wireguard-go` and distributed under GPLv2. See `Engine/LICENSE` and `Engine/COPYING`.
- The official AmneziaWG project for Apple platforms: `amnezia-vpn/amneziawg-apple`.

## А теперь на русском

Это минималистичный клиент AmneziaWG для старых макосей (потому что других не было), написанный на Objective-C и Go. Программа живёт в трее и делает ровно то, что нужно: подключает туннель, показывает статус и не требует пароль при каждом запуске. Всё.

Работоспособность проверена на OS X Mavericks и Catalina. На других системах не проверена, нужны тесты и фидбэк, оттого и бэта. Ниже Mavericks не поддерживается.

### Что это чудо умеет?

- Импортировать обычные `.conf` и ссылки `vpn://`.
- Работать с legacy-AWG и AWG 3.x, аналогично и с обычными Wireguard конфигами.
- Переключаться, редактировать и удалять конфиги.
- Показывать endpoint, handshake, RX/TX, порт и журнал демона.

Конфиги лежат здесь:

```text
~/Library/Application Support/CloletteWG/Tunnels.plist
```

Файл доступен только владельцу (`0600`).

### Что нужно для сборки

- macOSь с Xcode Command Line Tools.
- Python 3 — только для DMG-установщика.
- Intel Mac или Apple Silicon с Rosetta 2.

### Билд:

```sh
./build.sh
```

При первой сборке скрипт сам скачает официальные тулчейны Go, проверит их и соберет два демона:

- Go 1.10.8 — для Mavericks и систем до Catalina;
- Go 1.22.12 — для Catalina и новее.

А как иначе?

Если демоны только что собраны через `make core`, можно пропустить их повторную сборку:

```sh
SKIP_CORE_BUILD=1 ./build.sh
```

### Установка

1. Перетащи `CloletteWG.app` в `/Applications`.
2. Запусти именно с папки с приложениями (это нужно для установки демонов, в противном случае не запустится и выскочит предупреждение).
3. Один раз введи пароль администратора для установки демона.
4. Импортируй конфиг или вставь ссылку.
5. Profit.

Сам сервис ставится в `/Library/PrivilegedHelperTools`. Дальше пароль не нужен: приложение общается с демоном через локальный сокет, доступный группе `admin` и защищённый токеном.

При обновлении приложение сравнивает установленный демон с тем, что лежит внутри `.app`. Если они отличаются, предложит обновиться.

### Нюансы

- **Uninstall Service…** сносит демон и launchd-сервис, но оставляет конфиги.

### Ограничения

- Используется первый `[Peer]` из конфига.
- Не работает и не поддерживается IPv6. Это ограничение со стороны ядра AmneziaWG и так задумано.

### Команды для make'а

```sh
make app        # только .app
make dmg        # .app и DMG
make core       # пересобрать оба демона
make test-app   # тесты parser и имен туннелей на macOS
make test-core  # тесты движка на macOS или Linux
make test       # оба набора
```

При необходимости можно переопределить `SDKROOT` и `CLANG`. GUI собирается с deployment target `10.9`, все компоненты — `x86_64`.

### Сурсы, на базе их и собрано приложение воедино

- Гуй CloletteWG, MIT, за основу взята пустышка, написанная на Swift: `maloyan/amnezia-cloak`.
- Бинарники для и от Mavericks: `TheFrutigerDaniel/amneziawg-mavericks`
- Движок основан на `wireguard-go` и распространяется по GPLv2. Тексты лицензий лежат в `Engine/LICENSE` и `Engine/COPYING`.
- Официальный проект AmneziaWG для яблок: `amnezia-vpn/amneziawg-apple`.
