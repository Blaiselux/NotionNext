#!/usr/bin/env bash
set -Eeuo pipefail

readonly deploy_public_key_file="${1:-}"
readonly deploy_user='notionnext-deploy'
readonly deploy_home='/var/lib/notionnext-deploy'
readonly nginx_site='/etc/nginx/sites-enabled/ashway.fun'
readonly nginx_upstream='/etc/nginx/snippets/notionnext-upstream.conf'
readonly nginx_backup_dir='/etc/nginx/backups'

[[ $EUID -eq 0 ]] || {
  printf 'Run this installer as root.\n' >&2
  exit 1
}

[[ -f "$deploy_public_key_file" ]] || {
  printf 'Usage: %s /path/to/deploy-key.pub\n' "$0" >&2
  exit 1
}

install -o root -g root -m 0755 \
  scripts/deploy/vps-deploy.sh /usr/local/sbin/notionnext-deploy
install -o root -g root -m 0755 \
  scripts/deploy/ssh-command.sh /usr/local/sbin/notionnext-deploy-ssh

if ! id "$deploy_user" >/dev/null 2>&1; then
  useradd --create-home --home-dir "$deploy_home" --shell /bin/bash "$deploy_user"
fi

install -d -o "$deploy_user" -g "$deploy_user" -m 0700 "${deploy_home}/.ssh"
{
  printf 'restrict,command="/usr/local/sbin/notionnext-deploy-ssh" '
  cat "$deploy_public_key_file"
} >"${deploy_home}/.ssh/authorized_keys"
chown "$deploy_user:$deploy_user" "${deploy_home}/.ssh/authorized_keys"
chmod 0600 "${deploy_home}/.ssh/authorized_keys"

printf '%s ALL=(root) NOPASSWD: /usr/local/sbin/notionnext-deploy *\n' \
  "$deploy_user" >'/etc/sudoers.d/notionnext-deploy'
chmod 0440 '/etc/sudoers.d/notionnext-deploy'
visudo --check --file='/etc/sudoers.d/notionnext-deploy'

install -d -o root -g "$deploy_user" -m 0750 "$deploy_home"

if docker container inspect notionnext >/dev/null 2>&1; then
  if docker container inspect notionnext-blue >/dev/null 2>&1; then
    printf 'Both notionnext and notionnext-blue exist; refusing to guess the active container.\n' >&2
    exit 1
  fi
  docker rename notionnext notionnext-blue
fi

docker container inspect notionnext-blue >/dev/null 2>&1 || {
  printf 'Expected an existing notionnext-blue container on port 3000.\n' >&2
  exit 1
}

printf 'blue\n' >"${deploy_home}/active-slot"
chown root:"$deploy_user" "${deploy_home}/active-slot"
chmod 0640 "${deploy_home}/active-slot"

install -d -o root -g root -m 0755 /etc/nginx/snippets
install -d -o root -g root -m 0700 "$nginx_backup_dir"
printf 'proxy_pass http://127.0.0.1:3000;\n' >"$nginx_upstream"
chmod 0644 "$nginx_upstream"

if grep -Fq 'proxy_pass http://127.0.0.1:3000;' "$nginx_site"; then
  cp --archive "$nginx_site" "${nginx_backup_dir}/ashway.fun.before-blue-green"
  sed -i \
    's|^[[:space:]]*proxy_pass http://127\.0\.0\.1:3000;|        include /etc/nginx/snippets/notionnext-upstream.conf;|' \
    "$nginx_site"
elif ! grep -Fq 'include /etc/nginx/snippets/notionnext-upstream.conf;' "$nginx_site"; then
  printf 'Could not find the expected NotionNext proxy_pass in %s.\n' "$nginx_site" >&2
  exit 1
fi

nginx -t
systemctl reload nginx
curl --fail --silent --show-error --max-time 15 \
  --resolve 'ashway.fun:443:127.0.0.1' \
  'https://ashway.fun/' >/dev/null

printf 'VPS deploy account and blue/green routing installed successfully.\n'
