# soulseek-stack

slskd, Lidarr y Soularr como quadlets de Podman rootless, ya enlazados entre sí:

- **slskd** es el cliente de Soulseek. Comparte la biblioteca en solo lectura y descarga a `DOWNLOADS_DIR`.
- **Lidarr** lleva la biblioteca. Tiene la lista de artistas y álbumes que quieres, el perfil «Solo FLAC», y se encarga de renombrar los archivos e importarlos a `MUSIC_DIR`.
- **Soularr**, cada `SOULARR_INTERVAL` segundos, busca en slskd lo que falta en Lidarr (o lo que no está en FLAC), lo descarga y le pide a Lidarr que lo importe.

```
Lidarr (pendientes) ──► Soularr ──► slskd ──► Soulseek
     ▲                     │
     └── importa ◄─────────┘ mueve a /downloads/<Artista - Álbum (Año)>
```

## Requisitos

- Podman 4.4 o superior, rootless, con systemd de usuario. Está probado el render con quadlet 5.7.
- python3 (solo la librería estándar).
- Una cuenta de Soulseek **distinta** de la de Nicotine+, o Nicotine+ apagado.
- El puerto TCP `SLSK_LISTEN_PORT` (50300 por defecto) abierto en el router hacia la máquina.
- Linger, para que los servicios sigan corriendo sin sesión abierta: `sudo loginctl enable-linger $USER`.

## Instalación

```bash
cp .env.example .env && chmod 600 .env
$EDITOR .env          # cuenta de Soulseek, contraseña de la web y rutas
./instalar.sh
```

`instalar.sh` hace lo siguiente:

1. Genera las claves de API de slskd y Lidarr si están vacías y las guarda en `.env`.
2. Crea las carpetas.
3. Genera `slskd.yml`, el `config.ini` de Soularr y el `config.xml` de Lidarr dentro de `DATA_DIR`, con permisos 600.
4. Instala los quadlets en `~/.config/containers/systemd/`.
5. Arranca los tres servicios.
6. Configura Lidarr por API (`lib/configurar_lidarr.py`):
   - Crea el perfil **Solo FLAC** a partir de «Lossless», con solo las calidades FLAC, mejoras activadas y el corte en el mejor FLAC.
   - Crea la carpeta raíz `/music` con ese perfil por defecto.
   - Activa el renombrado de pistas.

Se puede relanzar las veces que haga falta. Para solo regenerar la configuración sin arrancar nada: `./instalar.sh --sin-arrancar`.

## Después de instalar

1. Abre Lidarr (`http://<host>:8686`) y crea el usuario y la contraseña que te pide la primera vez.
2. Añade artistas en **Artist › Add New**. Lo que se monitorice pasa a pendiente y Soularr lo busca en la siguiente pasada.
3. Para que mejore lo que ya tienes en MP3: **Library Import** sobre `/music` con el perfil «Solo FLAC». Con `SOULARR_SEARCH_SOURCE=all` también busca lo que no llega al corte.

## Rutas dentro de los contenedores

Todo apunta a las mismas carpetas del host. Es lo que hace que la importación funcione.

| Host | slskd | Lidarr | Soularr |
|---|---|---|---|
| `DOWNLOADS_DIR` | `/downloads` | `/downloads` | `/downloads` |
| `MUSIC_DIR` | `/music` (ro, compartida) | `/music` | (no la ve) |
| `DATA_DIR/<servicio>` | `/app` | `/config` | `/data` |

Los ficheros quedan a nombre de tu usuario:

- slskd y Soularr corren como root del contenedor, que en rootless es tu usuario.
- Lidarr usa `UserNS=keep-id` con `PUID` y `PGID` iguales a tu usuario.

## Operación

```bash
systemctl --user status slskd lidarr soularr
journalctl --user -u soularr -f
podman auto-update                                    # actualiza las imágenes (llevan AutoUpdate=registry)
systemctl --user enable --now podman-auto-update.timer  # o que lo haga a diario
```

Para cambiar algo, edita `.env` o `plantillas/` y relanza `./instalar.sh`. No edites los ficheros generados en `DATA_DIR` ni en `~/.config/containers/systemd/`, porque se sobrescriben. La excepción es `config.xml` de Lidarr, que solo se crea la primera vez; después solo se alinea su clave de API.

## Limitaciones conocidas

- **Servidor de metadatos de Lidarr.** En 2025 tuvo problemas largos al buscar y añadir artistas. En enero de 2026 estaba «casi recuperado» según el issue Lidarr/Lidarr#5498; no he podido comprobar cómo está ahora. Si la búsqueda de artistas falla, prueba con `LIDARR_IMAGE=lscr.io/linuxserver/lidarr:nightly`.
- **Soularr es estricto al elegir.** El número de pistas tiene que coincidir y cada nombre de archivo tiene que parecerse al de la pista (`minimum_filename_match_ratio = 0.8`). Algunos álbumes que sí están en Soulseek no se descargarán. Ajusta `plantillas/soularr-config.ini` si pasa a menudo.
- **Solo descarga lo que está en MusicBrainz.** Lo que no está catalogado (directos, bootlegs) no pasa por aquí.
- **Las webs de Soularr y slskd quedan expuestas** en `WEB_BIND`. Soularr no tiene autenticación: pon `WEB_BIND=127.0.0.1` si la máquina no está solo en tu red local.
