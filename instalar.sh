#!/usr/bin/env bash
# Instala slskd + Lidarr + Soularr como quadlets de Podman rootless, ya enlazados entre sí.
#
#   ./instalar.sh               genera la configuración, instala los quadlets, arranca y configura Lidarr
#   ./instalar.sh --sin-arrancar  solo genera la configuración y los quadlets
#
# Se puede relanzar las veces que haga falta: regenera configuración y reinicia los servicios.
set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")"
BASE=$PWD
ARRANCAR=1
[[ "${1:-}" == "--sin-arrancar" ]] && ARRANCAR=0

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
aviso() { printf '\033[1;33m[aviso]\033[0m %s\n' "$*" >&2; }
fallo() { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

# --- Requisitos -----------------------------------------------------------------
[[ $EUID -eq 0 ]] && fallo "Lánzalo con tu usuario, no con root: es un despliegue rootless."
command -v podman >/dev/null || fallo "Falta podman."
command -v python3 >/dev/null || fallo "Falta python3."
command -v systemctl >/dev/null || fallo "Falta systemd."
PODMAN_VER=$(podman version --format '{{.Client.Version}}')
python3 - "$PODMAN_VER" <<'EOF' || fallo "Hace falta Podman 4.4 o superior para quadlets con .network (tienes $PODMAN_VER)."
import sys
v = tuple(int(x) for x in sys.argv[1].split("-")[0].split(".")[:2])
sys.exit(0 if v >= (4, 4) else 1)
EOF

# --- .env -----------------------------------------------------------------------
[[ -f .env ]] || fallo "No hay .env. Haz: cp .env.example .env && chmod 600 .env, y rellénalo."
chmod 600 .env

# Genera las claves de API que falten y las guarda en .env
python3 - .env <<'EOF'
import re, secrets, sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
for name, nbytes in (("SLSKD_API_KEY", 32), ("LIDARR_API_KEY", 16)):
    m = re.search(rf"^{name}=(.*)$", text, re.M)
    if m and m.group(1).strip():
        continue
    line = f"{name}={secrets.token_hex(nbytes)}"
    text = re.sub(rf"^{name}=.*$", line, text, flags=re.M) if m else text.rstrip("\n") + f"\n{line}\n"
    print(f"Generada {name} en .env")
open(path, "w", encoding="utf-8").write(text)
EOF

set -a
# shellcheck disable=SC1091
source ./.env
set +a

for v in SLSK_USERNAME SLSK_PASSWORD SLSKD_WEB_USERNAME SLSKD_WEB_PASSWORD MUSIC_DIR DOWNLOADS_DIR DATA_DIR; do
  [[ -n "${!v:-}" ]] || fallo "Falta $v en .env"
done
for v in MUSIC_DIR DOWNLOADS_DIR DATA_DIR; do
  [[ "${!v}" == /* ]] || fallo "$v tiene que ser una ruta absoluta (${!v})"
done
[[ "$SLSK_PASSWORD" == "$SLSKD_WEB_PASSWORD" ]] && aviso "La contraseña de la web de slskd es la misma que la de Soulseek; mejor que sean distintas."

# Valores por defecto si se ha borrado alguna línea del .env
: "${WEB_BIND:=0.0.0.0}" "${SLSKD_HTTP_PORT:=5030}" "${LIDARR_PORT:=8686}" "${SOULARR_WEBUI_PORT:=8265}"
: "${SLSK_LISTEN_PORT:=50300}" "${TZ:=Europe/Madrid}" "${SOULARR_INTERVAL:=300}"
: "${SLSKD_IMAGE:=docker.io/slskd/slskd:latest}" "${LIDARR_IMAGE:=lscr.io/linuxserver/lidarr:latest}"
: "${SOULARR_IMAGE:=docker.io/mrusse08/soularr:latest}" "${SOULARR_SEARCH_SOURCE:=all}"
: "${SOULARR_ALBUMS_PER_RUN:=10}" "${SOULARR_ALLOWED_FILETYPES:=flac}" "${SOULARR_IGNORED_USERS:=}"
export WEB_BIND SLSKD_HTTP_PORT LIDARR_PORT SOULARR_WEBUI_PORT SLSK_LISTEN_PORT TZ SOULARR_INTERVAL \
  SLSKD_IMAGE LIDARR_IMAGE SOULARR_IMAGE SOULARR_SEARCH_SOURCE SOULARR_ALBUMS_PER_RUN \
  SOULARR_ALLOWED_FILETYPES SOULARR_IGNORED_USERS
case "$SOULARR_SEARCH_SOURCE" in missing|cutoff_unmet|all) ;; *) fallo "SOULARR_SEARCH_SOURCE debe ser missing, cutoff_unmet o all";; esac

export HOST_UID HOST_GID VOL_RW VOL_RO
HOST_UID=$(id -u)
HOST_GID=$(id -g)
if [[ -n "${SELINUX_LABEL:-}" ]]; then
  VOL_RW=":${SELINUX_LABEL}"; VOL_RO="ro,${SELINUX_LABEL}"
else
  VOL_RW=""; VOL_RO="ro"
fi

# --- Carpetas -------------------------------------------------------------------
info "Carpetas"
if [[ ! -d "$MUSIC_DIR" ]]; then
  aviso "$MUSIC_DIR no existe; la creo vacía."
  mkdir -p "$MUSIC_DIR"
fi
mkdir -p "$DOWNLOADS_DIR" "$DATA_DIR"/{slskd,lidarr,soularr}
chmod 700 "$DATA_DIR"
[[ -w "$MUSIC_DIR" ]] || fallo "No puedes escribir en $MUSIC_DIR y Lidarr tiene que mover ahí los álbumes."
if [[ "$(stat -c %d "$MUSIC_DIR")" != "$(stat -c %d "$DOWNLOADS_DIR")" ]]; then
  aviso "Descargas y biblioteca están en sistemas de ficheros distintos: cada importación será una copia completa."
fi

# --- Configuración de los servicios ---------------------------------------------
info "Configuración de slskd y Soularr"
python3 lib/render.py plantillas/slskd.yml "$DATA_DIR/slskd/slskd.yml"
python3 lib/render.py plantillas/soularr-config.ini "$DATA_DIR/soularr/config.ini"

info "Configuración de Lidarr"
LIDARR_XML="$DATA_DIR/lidarr/config.xml"
if [[ -f "$LIDARR_XML" ]]; then
  # Lidarr ya creó su config.xml: solo se alinea la clave de API con la de .env
  python3 - "$LIDARR_XML" <<'EOF'
import os, re, sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
new = re.sub(r"<ApiKey>.*?</ApiKey>", f"<ApiKey>{os.environ['LIDARR_API_KEY']}</ApiKey>", text)
if new != text:
    open(path, "w", encoding="utf-8").write(new)
    print("Clave de API de Lidarr alineada con .env")
EOF
else
  python3 lib/render.py plantillas/lidarr-config.xml "$LIDARR_XML"
fi

# --- Quadlets -------------------------------------------------------------------
QUADLET_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/containers/systemd"
info "Quadlets en $QUADLET_DIR"
mkdir -p "$QUADLET_DIR"
for f in plantillas/quadlet/*; do
  python3 lib/render.py "$f" "$QUADLET_DIR/$(basename "$f")"
done

# Comprueba que quadlet entiende los ficheros
GEN=$(command -v /usr/libexec/podman/quadlet || command -v /usr/lib/podman/quadlet || true)
if [[ -n "$GEN" ]]; then
  "$GEN" -dryrun -user >/dev/null 2>&1 || aviso "quadlet se queja de algún fichero; revisa: $GEN -dryrun -user"
fi

if [[ $ARRANCAR -eq 0 ]]; then
  info "Hecho (sin arrancar). Para arrancar: ./instalar.sh"
  exit 0
fi

# --- Arranque -------------------------------------------------------------------
info "Descargando imágenes"
podman pull -q "$SLSKD_IMAGE" "$LIDARR_IMAGE" "$SOULARR_IMAGE" >/dev/null

info "Arrancando servicios"
systemctl --user daemon-reload
systemctl --user restart slskd.service lidarr.service
systemctl --user restart soularr.service

case "$WEB_BIND" in
  0.0.0.0|"") HOST=127.0.0.1 ;;
  *) HOST=$WEB_BIND ;;
esac

info "Configurando Lidarr (perfil Solo FLAC, carpeta /music, renombrado)"
LIDARR_URL="http://$HOST:$LIDARR_PORT" python3 lib/configurar_lidarr.py

# --- Avisos finales -------------------------------------------------------------
if [[ "$(loginctl show-user "$USER" -p Linger --value 2>/dev/null)" != "yes" ]]; then
  aviso "Sin linger los servicios se paran al cerrar sesión. Actívalo con: sudo loginctl enable-linger $USER"
fi

cat <<EOF

Listo. Webs:
  slskd    http://$HOST:$SLSKD_HTTP_PORT   (usuario $SLSKD_WEB_USERNAME)
  Lidarr   http://$HOST:$LIDARR_PORT       (la primera vez te pide crear usuario y contraseña)
  Soularr  http://$HOST:$SOULARR_WEBUI_PORT

Falta a mano:
  - Abrir en el router el puerto TCP $SLSK_LISTEN_PORT hacia esta máquina.
  - En Lidarr, añadir artistas (Artist > Add New) con el perfil «Solo FLAC». Soularr los busca cada ${SOULARR_INTERVAL}s.

Logs: journalctl --user -u soularr -f   (o slskd, lidarr)
EOF
