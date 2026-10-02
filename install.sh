#!/usr/bin/env bash
set -euo pipefail

export PATH=/usr/sbin:/usr/bin:/sbin:/bin

die() {
    printf 'Ошибка: %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'HELP'
Установка tmux и пользовательской службы systemd для Debian и Ubuntu.

  bash install.sh                 Установить для текущего пользователя
  sudo bash install.sh            Установить для пользователя, вызвавшего sudo
  bash install.sh --user USER     Установить для существующего пользователя
  bash install.sh --print-unit    Показать службу без установки
  bash install.sh --print-config  Показать шаблон .tmux.conf без установки
  bash install.sh --help          Показать справку

Нужны Debian 12+ или Ubuntu 22.04+, systemd и права root через sudo
либо прямой запуск от root. При прямом запуске от root выбирается root.
HELP
}

print_config() {
    cat <<'CONFIG'
# Сессии продолжают работать без подключённых клиентов.
set -g destroy-unattached off
set -s exit-unattached off

# Сохранять панель после ошибки программы: видны вывод и код завершения.
# Повторить команду в завершившейся панели: Ctrl+b, затем : respawn-pane
set -g remain-on-exit failed

# При закрытии сессии переключаться на другую, если она существует.
set -g detach-on-destroy off

# Терминал и полноцветный RGB для совместимых внешних терминалов.
set -g default-terminal 'tmux-256color'
set -as terminal-features ",xterm-256color:RGB,gnome*:RGB"

# История, мышь и обработка клавиш/фокуса.
set -g history-limit 100000
set -g mouse on
set -s escape-time 50
set -s focus-events on

# Подключение: tmux -L systemd attach -t main
# Служба: systemctl --user status tmux-systemd.service
# Применить изменения: tmux -N -L systemd source-file ~/.tmux.conf
CONFIG
}

print_unit() {
    cat <<'UNIT'
# Управляется установщиком civisrom/tmux-systemd.
[Unit]
Description=tmux server (systemd socket, main session)
Documentation=man:tmux(1) man:systemd.service(5)
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
Type=exec
WorkingDirectory=%h
Environment=TMUX_TMPDIR=/tmp
UnsetEnvironment=TMUX
# Не присваивать сервер, уже запущенный на этом сокете вне службы.
ExecCondition=/bin/sh -c 'if /usr/bin/tmux -N -L systemd show-options -s >/dev/null 2>&1; then echo "Сокет systemd уже занят другим сервером tmux." >&2; exit 1; fi'
ExecStart=/usr/bin/tmux -D -L systemd
# -N запрещает клиенту создавать второй сервер до готовности основного.
ExecStartPost=/bin/sh -ec '\
    until /usr/bin/tmux -N -L systemd show-options -s >/dev/null 2>&1; do /usr/bin/sleep 0.1; done; \
    /usr/bin/tmux -N -L systemd set-option -s exit-empty off; \
    /usr/bin/tmux -N -L systemd has-session -t =main 2>/dev/null || /usr/bin/tmux -N -L systemd new-session -d -s main'
Restart=on-failure
RestartSec=5
TimeoutStartSec=20
TimeoutStopSec=15
KillMode=control-group
SendSIGHUP=yes

[Install]
WantedBy=default.target
UNIT
}

target_user=${SUDO_USER:-$(id -un)}
while (($#)); do
    case "$1" in
        --user)
            (($# >= 2)) || die 'после --user нужно имя пользователя.'
            target_user=$2
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        --print-unit)
            print_unit
            exit 0
            ;;
        --print-config)
            print_config
            exit 0
            ;;
        *) die "неизвестный аргумент: $1 (см. --help)." ;;
    esac
done

[[ $target_user =~ ^[a-zA-Z_][a-zA-Z0-9_.-]*\$?$ ]] || die 'недопустимое имя пользователя.'
if ((EUID != 0)); then
    command -v sudo >/dev/null || die 'нужны права root; запустите сохранённый скрипт от root с --user USER.'
    [[ -f $0 ]] || die 'сначала скачайте скрипт в файл, затем запустите bash install.sh.'
    exec sudo -- /bin/bash "$0" --user "$target_user"
fi

[[ -r /etc/os-release ]] || die 'не найден /etc/os-release.'
# shellcheck disable=SC1091
. /etc/os-release
case ${ID:-} in
    debian) minimum=12 ;;
    ubuntu) minimum=22.04 ;;
    *) die 'поддерживаются только Debian и Ubuntu.' ;;
esac
dpkg --compare-versions "${VERSION_ID:-0}" ge "$minimum" || die 'нужны Debian 12+ или Ubuntu 22.04+.'
[[ -d /run/systemd/system ]] || die 'systemd должен быть запущен как система инициализации.'
for command in apt-get dpkg-query loginctl systemctl runuser; do
    command -v "$command" >/dev/null || die "не найдена команда $command."
done

account=$(getent passwd "$target_user") || die 'указанный пользователь не существует.'
IFS=: read -r account_name _ target_uid _ _ target_home target_shell <<< "$account"
[[ $account_name == "$target_user" ]] || die 'нужно указать имя пользователя, а не UID.'
[[ $target_home == /* && $target_home != / && -d $target_home ]] || die 'у пользователя должен быть существующий домашний каталог.'
case $target_shell in
    */nologin|*/false|'') die 'у пользователя должна быть интерактивная оболочка.' ;;
esac
[[ -x $target_shell ]] || die 'оболочка пользователя недоступна.'

missing=()
for package in tmux dbus-user-session; do
    if [[ $(dpkg-query -W -f='${Status}' "$package" 2>/dev/null || true) != 'install ok installed' ]]; then
        missing+=("$package")
    fi
done
if ((${#missing[@]})); then
    apt-get update
    DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l apt-get install -y --no-install-recommends "${missing[@]}"
fi
tmux_version=$(/usr/bin/tmux -V)
dpkg --compare-versions "${tmux_version#tmux }" ge 3.2 || die 'нужен tmux 3.2 или новее из репозитория дистрибутива.'

as_user() {
    runuser -u "$target_user" -- env -u TMUX \
        HOME="$target_home" XDG_RUNTIME_DIR="/run/user/$target_uid" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$target_uid/bus" \
        TMUX_TMPDIR=/tmp "$@"
}

unit=tmux-systemd.service
unit_dir=$target_home/.config/systemd/user

# Существующие настройки, в том числе по альтернативному стандартному пути,
# имеют приоритет. Создание выполняется владельцем с запретом перезаписи.
# shellcheck disable=SC2016
print_config | as_user /bin/bash -euo pipefail -c '
    destination=$HOME/.tmux.conf
    alternative=$HOME/.config/tmux/tmux.conf
    if [[ -e $destination || -L $destination || -e $alternative || -L $alternative ]]; then
        cat >/dev/null
        printf "Существующая конфигурация tmux сохранена.\n"
        exit 0
    fi
    umask 077
    temporary=$(mktemp "$HOME/.tmux.conf.XXXXXXXX")
    trap '\''rm -f -- "$temporary"'\'' EXIT
    cat > "$temporary"
    ln -- "$temporary" "$destination"
    printf "Создана конфигурация: %s\n" "$destination"
'

# Запись от имени владельца защищает root от ссылок внутри чужого HOME.
# Переменные раскрываются внутри Bash, запущенного от выбранного пользователя.
# shellcheck disable=SC2016
print_unit | as_user /bin/bash -euo pipefail -c '
    unit_dir=$1
    destination=$unit_dir/tmux-systemd.service
    mkdir -p -- "$unit_dir"
    if [[ -L $destination || ( -e $destination && ! -f $destination ) ]]; then
        printf "Ошибка: файл службы является ссылкой или не является обычным файлом.\n" >&2
        exit 1
    fi
    temporary=$(mktemp "$unit_dir/.tmux-systemd.XXXXXXXX")
    trap '\''rm -f -- "$temporary"'\'' EXIT
    cat > "$temporary"
    chmod 0644 "$temporary"
    if [[ -f $destination ]] && cmp -s -- "$temporary" "$destination"; then
        printf "Файл службы уже актуален.\n"
        exit 0
    fi
    if [[ -f $destination ]]; then
        backup=$(mktemp "$destination.bak.XXXXXXXX")
        cp -p -- "$destination" "$backup"
        printf "Предыдущая служба сохранена: %s\n" "$backup"
    fi
    mv -f -- "$temporary" "$destination"
' -- "$unit_dir"

loginctl enable-linger "$target_user"
systemctl start "user@$target_uid.service"
as_user systemctl --user daemon-reload
as_user systemctl --user enable "$unit"
if as_user systemctl --user is-active --quiet "$unit"; then
    printf 'Работающая служба сохранена без перезапуска. Изменения службы применятся при следующем запуске.\n'
else
    as_user systemctl --user start "$unit" || die "служба не запустилась; проверьте journalctl --user -u $unit."
fi
as_user systemctl --user is-active --quiet "$unit" || die 'служба не активна; возможно, сокет systemd занят сервером, запущенным вручную.'
as_user /usr/bin/tmux -N -L systemd show-options -s >/dev/null || die 'служба активна, но сокет tmux недоступен.'

printf '\nГотово. Пользователь: %s; служба: %s\n' "$target_user" "$unit"
printf 'После входа под этим пользователем:\n  tmux -L systemd attach -t main\n'
printf 'Если сессия main была закрыта:\n  tmux -N -L systemd new-session -A -s main\n'
