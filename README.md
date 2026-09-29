# xtreamui-installer

Instalador limpio para el panel IPTV Xtream UI, sobre Ubuntu 20.04/22.04/24.04 y Debian 11/12.

Reescritura del instalador que circula habitualmente, corrigiendo los fallos de seguridad y los bugs que dejan la instalación rota.

> ### ⚠️ Pre-release — sin probar de principio a fin
>
> Cada corrección de este repositorio se verificó **sobre una instalación real y en marcha**: se reprodujo el fallo, se aplicó el arreglo y se comprobó el resultado. Los 18 scripts pasan validación de sintaxis en Ubuntu 22.04.
>
> Lo que **no** se ha hecho todavía es ejecutar `install.sh` completo en un servidor limpio, de cero a panel funcionando.
>
> Úsalo en una máquina desechable primero. Si lo pruebas en una instalación nueva, abre un issue con el resultado: es justo lo que falta para quitar este aviso.

---

## Antes de nada: qué es y qué no es esto

Este proyecto controla **cómo** se despliega el panel: permisos, límites de privilegio, exposición de red, gestión de servicios.

**No puede responder por el panel en sí.** El archivo que se descarga contiene binarios precompilados de nginx, PHP y ffmpeg, más código PHP ofuscado. Nadie fuera de sus autores sabe qué hace ese código.

Lo que sí puedes hacer:

- Fijar un SHA256 de un archivo que hayas verificado tú (`--tarball-sha256`)
- Alojar tu propia copia en lugar de depender del release de un tercero
- Tratar el servidor como no confiable: aislado, con firewall, sin nada que te importe perder

Si necesitas garantías sobre el código del panel, este instalador no te las da. Nadie te las puede dar.

---

## Qué corrige respecto al instalador original

### Fallos que rompen la instalación

| Problema | Qué pasaba | Solución |
|---|---|---|
| **Puertos sin validar** | Aceptaba `80910`. El máximo TCP es 65535. nginx rechazaba **toda** la configuración con `[emerg] invalid port` y no arrancaba nada | Validación de rango, duplicados y conflictos antes de escribir nada |
| **Detección de IP rota** | Usaba `api.sentora.org/ip.txt`, un servicio desaparecido. Devolvía cadena vacía y la guardaba en la BD sin comprobar | Cuatro proveedores con fallback, validación del formato, `--ip` para forzarla |
| **Puertos descuadrados** | Los callbacks RTMP apuntaban a `localhost:25461` fijo; la BD anunciaba `rtmp_port 2086` y `https_broadcast_port 2083` mientras nginx escuchaba en otros | Todos los puertos salen de variables y se escriben coherentes en nginx, nginx_rtmp y la base de datos |
| **Sin validación previa** | Descargaba el tarball a ciegas; si el release no existía, `tar` fallaba y el script seguía | Comprueba disponibilidad del payload y dependencias antes de tocar el sistema |
| **`innodb_buffer_pool_size = 10G` fijo** | MariaDB no arranca en máquinas con menos RAM | Se dimensiona según la RAM real del host |
| **ffmpeg hace segfault** | El binario empaquetado es de 2018 (glibc 2.31). En Ubuntu 22.04+ revienta dentro de `libc.so.6`. Ningún stream arranca | Se prueba con una codificación real y se sustituye por el ffmpeg de la distribución |
| **Flag de ffmpeg inexistente** | El panel pasa `-segment_list_flags +live+delete`; ese `delete` era un parche propio del build de Xtream y ffmpeg estándar lo rechaza | Wrapper que traduce el argumento sin tocar el PHP |
| **Segmentos sin borrar** | Sin ese flag los `.ts` se acumulan a ~14 MB/min por stream hasta llenar el tmpfs | El wrapper reescribe la invocación al muxer `hls`, que borra sus propios segmentos y escribe cada uno de forma atómica |
| **Límite de 1024 ficheros abiertos** | Se agota con varios streams simultáneos | 300000 por defecto |
| **Error de sintaxis en el SQL** | `update_reg_users.py` tiene un `ADD KEY` huérfano tras un `;`. `mysql` aborta ahí y nunca aplica el resto: faltan 15 filas de `admin_settings`, la PK de `settings` y todos los defaults del panel. El instalador reporta éxito igualmente | SQL corregido, idempotente, con los errores comprobados de verdad |
| **Admin creado con columnas incompletas** | Falta `default_lang` (`NOT NULL` sin default) y `verified` | Esquema completo de 21 columnas, verificado contra una instalación real |
| **Locale fijado a portugués** | `default_locale = 'pt_PT.utf8'` en toda instalación | Configurable con `--lang` y `--locale` |
| **Cortes de reproducción a los 20-60 s** | El cron `users_checker.php` borra las conexiones MPEGTS de `user_activity_now` cada vez que corre. Sin error en ningún log | Se desactiva ese cron; el control de acceso no depende de él |
| **Tres relojes descuadrados** | Sistema, `php.ini` (que queda vacío) y `settings.default_timezone` (que se queda en `Europe/London`) cada uno por su lado, y el EPG desfasado en silencio | Los tres se fijan igual y `verify_schema()` avisa si divergen |

### Fallos de seguridad

| Problema | Original | Aquí |
|---|---|---|
| **Base de datos expuesta** | `bind-address = *` + `GRANT ALL ON *.* TO 'user_iptvpro'@'%' WITH GRANT OPTION` — cuenta con privilegios de root accesible desde todo internet | `bind-address = 127.0.0.1`, usuario `@'localhost'`, privilegios acotados solo a su base de datos |
| **Escalada a root** | `chmod -R 0777` + cron `@reboot root` ejecutando un script de ese árbol + `NOPASSWD` sobre `python` | Permisos 0750/0640, lanzador root en `/usr/local/sbin`, systemd, y sudo solo para `iptables` y `chattr` |
| **Clave GPG sin validar TLS** | `wget --no-check-certificate ... \| apt-key add -` | TLS verificado y llavero con `signed-by` por repositorio |
| **SSLv3 habilitado** | `ssl_protocols SSLv3 TLSv1.1 TLSv1.2` | `TLSv1.2 TLSv1.3` y cifrados modernos |
| **Contraseñas en la línea de comandos** | `mysql -u root -p$PASS` — visible en `ps` para cualquier usuario | Ficheros temporales con modo 0600 |
| **Contraseñas en el log** | Todo el instalador pasaba por `tee`, dejando las claves en claro | Redacción automática de secretos en el log |
| **Sin firewall** | No configuraba ninguno | `--enable-firewall` con ufw, permitiendo SSH **antes** de activar |

> **Sobre la escalada a root**, que es lo más grave del original: `php-fpm` corre como `xtreamcodes`, y ese usuario tenía sudo sin contraseña sobre `python`. Es decir, `sudo python2 -c 'import os; os.system("/bin/sh")'` da una shell de root. Cualquier RCE en el PHP del panel se convertía en compromiso total de la máquina, sin exploit.

---

## Instalación

### Un solo comando

```bash
curl -fsSL https://raw.githubusercontent.com/am3nd3z/xtreamui-installer/main/bootstrap.sh \
  | sudo bash -s -- \
      --admin-port 8091 \
      --client-port 8080 \
      --admin-user admin \
      --email tu@correo.com \
      --timezone America/Mexico_City \
      --tarball-url https://github.com/am3nd3z/xtreamui-installer/releases/download/v0.9.0-beta/main_xui_Ubuntu_22.04.tar.gz \
      --tarball-sha256 57bdb3916d74a7d7417b6469e968766ddc46d86d195af4b03091cad7b66e2dd8 \
      --enable-firewall \
      --yes
```

### El payload del panel

El archivo que despliega el instalador está publicado en las [releases](https://github.com/am3nd3z/xtreamui-installer/releases) de este mismo repositorio, para no depender de terceros:

```
main_xui_Ubuntu_22.04.tar.gz     387 MB
SHA256  57bdb3916d74a7d7417b6469e968766ddc46d86d195af4b03091cad7b66e2dd8
```

Pasar `--tarball-sha256` es lo que hace que el instalador **se niegue a continuar si los bytes cambian**. Garantiza reproducibilidad entre instalaciones; no garantiza que el contenido sea seguro — son binarios precompilados y PHP ofuscado que nadie ha auditado.

> Pese al nombre, el fichero **no está comprimido**: es un tar plano. Sus primeros bytes son `69 70 74` —el comienzo de `iptv_xtream_codes/` en la cabecera tar— en lugar de la firma gzip `1F 8B`. Se conservan el nombre y los bytes originales para que la huella coincida con el payload en uso. `lib/panel.sh` extrae con `tar -xf` sin forzar `-z`, así que GNU tar autodetecta el formato.

`bootstrap.sh` descarga el repositorio completo y lanza `install.sh`. Hace falta porque `install.sh` carga `lib/*.sh` respecto a su propia ubicación, y por una tubería `${BASH_SOURCE[0]}` vale `stdin`.

Para fijar una versión concreta en lugar de seguir `main`:

```bash
curl -fsSL .../bootstrap.sh | sudo XUI_REF=v0.9.0 bash -s -- ...
```

> Con el one-liner, `--yes` es obligatorio salvo que haya terminal disponible: al venir por tubería, las confirmaciones leerían EOF. El bootstrap lo detecta y avisa antes de empezar, en vez de fallar a mitad.

### Clonando el repositorio

```bash
git clone https://github.com/am3nd3z/xtreamui-installer.git
cd xtreamui-installer
chmod +x install.sh tools/*.sh
```

### Con fichero de configuración (recomendado)

```bash
cp xtreamui.conf.example xtreamui.conf
chmod 600 xtreamui.conf
nano xtreamui.conf

sudo ./install.sh --config xtreamui.conf
```

### Con argumentos

```bash
sudo ./install.sh \
  --admin-port 8091 \
  --client-port 8080 \
  --admin-user admin \
  --email tu@correo.com \
  --timezone Europe/Madrid \
  --tarball-url https://tu-host/xui-ubuntu-22.04.tar.gz \
  --tarball-sha256 abc123... \
  --admin-allow-ip TU.IP.PUBLICA \
  --enable-firewall
```

### Ensayo sin cambios

```bash
sudo ./install.sh --config xtreamui.conf --dry-run
```

Valida todo — puertos, dependencias, disponibilidad del payload, recursos — y no toca nada.

---

## Puertos

| Servicio | Por defecto | Expuesto |
|---|---|---|
| Panel admin | `--admin-port` | Sí (restringible con `--admin-allow-ip`) |
| Clientes HTTP | `--client-port` | Sí |
| Clientes HTTPS | client + 2 | Sí |
| RTMP | client + 1 | Sí |
| MariaDB | 7999 | **No** — solo loopback |
| Módulo ISP | 8805 | **No** — solo loopback |
| RTMP stat | 31210 | **No** — solo loopback |

Rango válido: **1–65535**. Fuera de ahí el instalador se niega a continuar.

---

## Herramientas

### Reparar una instalación existente

Detecta y corrige los descuadres de puertos sin reinstalar:

```bash
sudo MYSQL_PWD='tu-password-root' ./tools/fix-ports.sh --detect
sudo MYSQL_PWD='tu-password-root' ./tools/fix-ports.sh --admin-port 8091 --client-port 8080
```

`MYSQL_PWD` hace falta para leer y escribir la base de datos. Sin ella solo se comprueba la parte de nginx. La conexión va por socket unix, no TCP: el `my.cnf` del panel trae `skip-name-resolve=1`, y eso impide que `root@localhost` haga match con conexiones a `127.0.0.1`.

Arregla los callbacks RTMP, sincroniza la base de datos con lo que nginx escucha de verdad, rellena `server_ip` si está vacío y quita SSLv3 si lo encuentra. Hace copia de seguridad de cada fichero y valida la configuración **antes** de reiniciar.

## Marca del panel

La página de login se tematiza en la instalación. El tema se instala como `admin/assets/css/xtreamui-brand.css` — **no incrustado en el PHP**, así que se reedita sin tocar código:

```bash
BRAND_NAME=Pato Player
BRAND_ACCENT=#F5A03C
BRAND_FONT_DISPLAY=Oswald
BRAND_FONT_BODY=Barlow
```

Con un nombre de dos palabras, la segunda toma el color de acento: *Pato* en blanco, *Player* en naranja.

El instalador hace **cuatro inserciones concretas** en `login.php` y deja intacta toda la lógica de autenticación, control de flood, 2FA y cambio de contraseña forzado. Después valida con `php -l` y comprueba que los campos del formulario sigan ahí; **si cualquiera de las dos falla, restaura la copia de seguridad automáticamente**. Una página de login rota deja al operador fuera de su propio panel, así que ese camino no se deja al azar.

Si `login.php` no tiene la estructura esperada —otro build del panel— cada inserción se salta con un aviso en lugar de corromper el fichero.

### En una instalación existente

```bash
sudo MYSQL_PWD='tu-password' ./tools/apply-branding.sh --brand-name "Pato Player"
sudo ./tools/apply-branding.sh --accent '#3B82F6'    # re-tematizar
sudo ./tools/apply-branding.sh --restore             # volver al original
```

Es idempotente: al reejecutarlo detecta los bloques ya presentes y solo refresca el CSS.

### El icono de la pestaña

`BRAND_HIDE_FAVICON=yes` lo quita del login **y del dashboard** (`header.php` y `header_sidebar.php`). Se hace con un data URI vacío:

```html
<link rel="icon" href="data:,">
```

Borrar la etiqueta sin más no sirve: el navegador pediría `/favicon.ico` por defecto, que existe en el panel y volvería igual.

> Tras cualquier cambio, recarga con **Ctrl+Shift+R**. Los navegadores cachean favicons y hojas de estilo con ganas, y uno viejo te hace perseguir un cambio que ya está aplicado.

## Rotación de segmentos

El panel invoca a ffmpeg con el muxer `segment` y el flag `+live+delete`. Ese `delete` era un parche propio de su compilación: **no existe en ningún ffmpeg estándar** — verificado contra el paquete de la distribución y contra el build estático que el propio proyecto original redistribuye. Sin él los `.ts` nunca se borran.

El wrapper ofrece dos modos, configurables en `/etc/xtreamui-ffmpeg.conf`:

```bash
SEGMENT_MODE=hls          # por defecto
HLS_DELETE_THRESHOLD=6
```

**`hls`** reescribe la invocación al muxer HLS:

```
-f segment -segment_time 10 -segment_list_size 6      ->  -f hls -hls_time 10 -hls_list_size 6
-segment_list_flags +live+delete                          -hls_flags delete_segments+temp_file
-segment_list  X.m3u8   Y_%d.ts                           -hls_segment_filename Y_%d.ts   X.m3u8
```

Dos ventajas sobre limpiar con cron:

- `delete_segments` borra los segmentos al salir de la ventana, sin proceso externo
- `temp_file` escribe cada segmento a `.tmp` y lo renombra al completarlo, así que **ningún cliente recibe un segmento a medio escribir** — esto elimina microcortes, no es solo higiene de disco

`HLS_DELETE_THRESHOLD` importa porque el panel sirve MPEGTS leyendo esos mismos ficheros: con el valor por defecto de ffmpeg (1), un cliente TS que se retrase lee un fichero ya borrado. A 6 hay ~2 minutos de margen.

Se deja fuera `independent_segments` a propósito: elevaría la playlist a `EXT-X-VERSION:6`, y el PHP del panel parsea versión 3.

**`legacy`** mantiene el muxer `segment` (sin el flag inexistente) y barre el directorio con un cron cada minuto. Es el comportamiento anterior, por si alguna instalación tiene problemas con el muxer HLS.

Medido en producción, modo `hls`:

```
t= 45s  segmentos=12  mas_antiguo=1_1.ts   29MB
t= 90s  segmentos=12  mas_antiguo=1_5.ts   29MB
t=135s  segmentos=12  mas_antiguo=1_10.ts  29MB
t=180s  segmentos=12  mas_antiguo=1_14.ts  29MB
```

Doce segmentos constantes, tamaño estable, sin `.tmp` residuales y con los 6 de la playlist siempre presentes.

### La reproducción se corta a los 20-60 segundos

Si una línea reproduce en VLC un rato y luego para, **desaparece de Live Connections** y no hay ningún error en los logs:

```bash
sudo ./tools/fix-ts-dropouts.sh --detect
sudo ./tools/fix-ts-dropouts.sh
```

Lo causa el cron `users_checker.php` del panel, que cada minuto borra la fila del cliente:

```sql
DELETE FROM user_activity_now WHERE activity_id = '<id>'
```

Afecta solo a conexiones MPEGTS; las HLS sobreviven, lo que hace parecer un problema del formato o de la fuente. Y como el servidor cierra el stream **limpiamente**, el reproductor lo interpreta como fin de emisión normal y `curl` devuelve éxito — no hay rastro de error en ninguna parte.

Determinado ejecutando los doce crons de minuto uno a uno contra una conexión TS viva: solo ese la mata. Con él desactivado y los otros diecinueve corriendo, la reproducción aguantó cinco minutos y 78 MB.

**Qué se pierde:** la revalidación periódica de líneas. **Qué no:** el límite de conexiones se comprueba al conectar, la caducidad al autenticar, y `kill_leaks.php` sigue actualizando el watchdog del servidor.

> **Al probar esto, usa una prueba larga.** El fallo solo aparece pasados 20-60 segundos; cualquier `curl --max-time 20` parece exitoso. Es el error que cometí yo al validar esta parte.

### Reparar ffmpeg

Si los streams no arrancan y el panel no da un error claro:

```bash
sudo ./tools/fix-ffmpeg.sh --detect   # diagnostica
sudo ./tools/fix-ffmpeg.sh            # repara
```

Síntomas que cubre:

- Los streams aparecen offline pero la fuente reproduce bien en cualquier otro sitio
- `dmesg` muestra `ffmpeg[NNNN]: segfault at 1ac ... in libc.so.6`
- En `stream_logs`: `Error setting option segment_list_flags to value +live+delete`
- El tmpfs de `streams/` crece sin parar

Ojo con el diagnóstico: `ffmpeg -version` **funciona** aunque el binario esté roto, porque imprimir la versión no llega al código que revienta. Por eso la comprobación hace una codificación real con `testsrc`, no un chequeo de versión.

### Reparar formatos de salida de los clientes

Si una línea autentica bien pero **ningún reproductor la reproduce** y el servidor devuelve un **HTTP 405 vacío**:

```bash
sudo MYSQL_PWD='tu-password-root' ./tools/fix-user-outputs.sh --detect
sudo MYSQL_PWD='tu-password-root' ./tools/fix-user-outputs.sh
```

El panel **no asigna ningún formato por defecto** al crear una línea. Sin formatos en `user_output`, el usuario autentica y luego se le rechaza todo. El motivo real solo aparece en la tabla `client_logs`:

```
client_status: USER_DISALLOW_EXT
query_string:  username=...&password=...&stream=1&extension=ts
```

Ojo con la URL sin extensión: nginx la reescribe a `extension=ts`, así que una línea con solo HLS marcado falla justo en la URL que el propio `get.php` del panel entrega para `output=ts`.

> **Al probar:** el panel cachea estos permisos. Tras un cambio, espera dos o tres minutos antes de concluir que no funcionó. Para ver qué cree el panel:
> ```bash
> curl -s "http://127.0.0.1:PUERTO/player_api.php?username=U&password=P" | python3 -m json.tool
> ```

### Desinstalar

```bash
sudo ./tools/uninstall.sh           # conserva la base de datos
sudo ./tools/uninstall.sh --purge   # la elimina también
```

---

## Operación

```bash
systemctl status xtreamui
systemctl restart xtreamui
journalctl -u xtreamui -f

tail -f /home/xtreamcodes/iptv_xtream_codes/logs/error.log
```

Las credenciales quedan en `/root/xtreamui-credentials.txt` con modo 0600. **Pásalas a un gestor de contraseñas y borra el fichero.**

---

## Recomendaciones

1. **Servidor dedicado.** Nada más tuyo en esa máquina.
2. **Restringe el panel de admin** con `--admin-allow-ip`. Es el objetivo de mayor valor.
3. **Fija el SHA256** del archivo. Sin eso ejecutas lo que ese servidor sirva ese día.
4. **Aloja tu propia copia** del payload en lugar de apuntar al release de un tercero.
5. **Cambia la contraseña** del panel en el primer acceso.
6. **Certificado real.** El instalador genera uno autofirmado; sustitúyelo por uno de Let's Encrypt.

### Sobre el firewall

Si lo activas tú a mano, **permite SSH antes de habilitarlo**:

```bash
ufw allow 22/tcp          # PRIMERO
ufw allow 8080/tcp
ufw allow 8091/tcp
ufw default deny incoming
ufw --force enable
```

Y antes de cerrar la terminal, abre una **segunda** sesión SSH para comprobar que sigues teniendo acceso. Si falla, usas la primera para `ufw disable`.

---

## Requisitos

- Ubuntu 20.04 / 22.04 / 24.04, o Debian 11 / 12
- x86_64
- 2 GB de RAM mínimo (4+ GB si vas a transcodificar)
- 10 GB libres en `/`
- Instalación limpia, sin otro panel de control
- Acceso root

---

## Estructura

```
install.sh                 Orquestador
lib/
  common.sh                Logging, validación, utilidades
  preflight.sh             Comprobaciones previas
  system.sh                Paquetes y repositorios
  database.sh              MariaDB, esquema y credenciales
  schema.sh                Claves primarias, ajustes y verificación de la BD
  panel.sh                 Descarga, verificación y despliegue
  webserver.sh             nginx y nginx-rtmp
  ffmpeg.sh                Validación, wrapper y limpieza de segmentos
  hardening.sh             Permisos, privilegios, systemd
  branding.sh              Tema del login y del icono de pestaña
  firewall.sh              Reglas ufw
tools/
  fix-ports.sh             Reparar puertos de una instalación existente
  fix-ffmpeg.sh            Reparar ffmpeg de una instalación existente
  fix-user-outputs.sh      Asignar formatos de salida a líneas que no los tienen
  fix-ts-dropouts.sh       Corregir cortes de reproducción a los 20-60 s
  apply-branding.sh        Tematizar el login de una instalación existente
  uninstall.sh             Desinstalar
assets/
  login-theme.css          Hoja de estilo del tema, con tokens sustituibles
xtreamui.conf.example      Plantilla de configuración
```

---

## Licencia

GPL-3.0, heredada del instalador original al que sustituye.

## Aviso

Se distribuye tal cual. Asegúrate de tener los derechos sobre el contenido que sirvas y de cumplir la legislación aplicable en tu jurisdicción. Eso queda de tu lado.
