# Flux

Encuentra el stream que emite Movie Plus en tu red local y lo reproduce, en
Windows y en Android.

El flujo manual que sustituye: abrir la app del teléfono, apuntar la IP, teclearla
en algún reproductor, cruzar los dedos. Flux barre la red, valida qué hay
detrás de cada puerto abierto, mide cuál va más rápido y te lo pone en una
lista con el nombre real del episodio.

## Cómo encuentra los streams

El descubrimiento va de lo más barato a lo más caro, y para en cuanto tiene algo:

| Fase | Qué hace | Coste típico |
|---|---|---|
| 1. Conocidos | Prueba los `host:puerto` que ya funcionaron antes | ~200 ms |
| 2. Rápido | 254 hosts × 22 puertos habituales, en orden puerto-mayor | 2-6 s |
| 3. Vivos | Si lo anterior falló, detecta qué IPs existen de verdad | ~1 s |
| 4. Amplio | ~400 puertos, pero solo sobre los pocos hosts vivos | 5-20 s |

Tres detalles que hacen que esto funcione en la práctica:

- **Orden puerto-mayor en la fase rápida.** Se prueba el 4445 en los 254 hosts
  antes de pasar al segundo puerto, así el caso normal aparece en pantalla en
  el primer segundo en vez de al final del barrido.
- **Detección de hosts vivos sin ICMP.** No hay `ping` en Dart puro ni permisos
  para raw sockets en Android. En su lugar se conecta a un puerto que seguro
  está cerrado: un dispositivo encendido responde `RST` al instante
  ("connection refused") y una IP vacía no responde nada. Eso reduce la fase
  amplia de 254 hosts a los 5-15 reales de una casa.
- **La ruta da igual.** El servidor de Movie Plus devuelve el mismo archivo en
  `/`, en `/v.mkv` y en cualquier otra ruta, así que basta con un `HEAD /`.
  De ahí sale además el nombre real del archivo, vía `Content-Disposition`.

Un stream se considera válido si responde `200`/`206` con un `Content-Type` de
video (o `application/octet-stream` con extensión de video) y un tamaño
razonable. Se guarda si soporta `Accept-Ranges: bytes`, que es lo que permite
adelantar y retroceder.

### Cómo se mide "el más rápido"

TTFB y throughput se guardan **por separado**. El servidor tarda ~1,5 s en
responder al primer `Range` porque tiene que abrir y buscar dentro de un MKV de
1,5 GB, pero luego transfiere rápido: un único número "velocidad" mezclaría
ambas cosas y haría parecer lento un stream que va perfecto. La medición
descuenta el TTFB antes de calcular MB/s, y mide aparte la latencia de salto
pidiendo desde la mitad del archivo — que es exactamente lo que se sufre al
arrastrar la barra de progreso.

## Seguridad

- **Solo redes privadas.** `LanGuard` valida contra 10/8, 172.16/12 y
  192.168/16 antes de abrir un socket, antes de seguir una redirección y antes
  de reproducir. No hay forma de que el escáner salga a Internet, ni siquiera
  escribiendo una dirección pública a mano.
- **Solo peticiones salientes.** La app no escucha en ningún puerto, no tiene
  telemetría y en Android pide únicamente `INTERNET` y `ACCESS_NETWORK_STATE`.
- **Validación antes de reproducir.** Se comprueba tipo y tamaño, hay timeout
  en cada petición y no se siguen redirecciones fuera de la LAN.
- **Motor acotado.** libmpv arranca con `protocolWhitelist` limitada a
  http/https/tcp/tls, así que un servidor manipulado no puede colar un `file://`.

El permiso de tráfico en claro de Android es general porque su configuración de
red no admite rangos CIDR — no se puede escribir "permite 192.168.0.0/16 y nada
más". La restricción real vive en el código. Está explicado en
`android/app/src/main/res/xml/network_security_config.xml`.

## Seguir la emisión y precarga

Cuando cambias de capítulo en Movie Plus, la dirección sigue siendo la misma
pero el archivo detrás es otro. Flux lo detecta y carga el nuevo solo.

Comportamiento del servidor, medido con un monitor durante 40 minutos:

```
22:29:53  CAMBIO -> "Rick and Morty S03E01.mkv"   (antes S03E10, mismo puerto)
22:32:38  SERVIDOR NO RESPONDE
22:32:46  vuelve                                  (8 s de hueco)
22:35:55  SERVIDOR NO RESPONDE
22:36:23  vuelve                                  (28 s de hueco)
```

Tres cosas que eso obligó a resolver:

- **Comparar la URL no sirve de nada.** Se compara una huella del contenido:
  nombre del archivo + tamaño + `Last-Modified`. Dos capítulos que pesan casi
  lo mismo se distinguen por la fecha.
- **No basta con dejar que FFmpeg reconecte.** Su reconexión continúa por el
  mismo offset de bytes; sobre un archivo distinto eso no da el capítulo nuevo,
  da basura. Por eso se detecta el cambio y se reabre desde cero.
- **Los huecos son largos.** El sondeo normal va cada 5 s, pero en cuanto falla
  uno pasa a 1,2 s para enganchar el capítulo nuevo en cuanto asome. Y si el
  reproductor ya se había rendido, la vuelta de la emisión lo despierta.

La **precarga** aprovecha ese momento: el capítulo nuevo se abre en pausa, se
deja llenar el búfer unos segundos y solo entonces se reproduce, así arranca ya
fluido en vez de dar el tirón de los primeros segundos. Mientras tanto se ve un
aviso con el título de lo que está entrando.

Si el servidor reapareciera en otro puerto, un barrido de los puertos
habituales sobre ese único dispositivo (22 conexiones) lo reengancha.

El sondeo es un `HEAD` cada pocos segundos. Comprobado: el servidor acepta
conexiones concurrentes y responde 200 mientras sirve el video a 8 MB/s, así
que vigilar no le quita ancho de banda a lo que estás viendo.

Ambas cosas se apagan desde el menú: **Reproducción automática** (abre el
primer stream al iniciar, una sola vez por arranque) y **Seguir la emisión**.

## Reproductor

Sobre **media_kit** (libmpv), no `video_player`: es lo único que reproduce MKV
en Windows, y trae subtítulos incrustados, varias pistas de audio, aceleración
por hardware y seek preciso.

- Subtítulos y pistas de audio del MKV, con nombres legibles ("Español" en vez
  de `spa`).
- Velocidad de 0,5x a 2x.
- Búfer de 64 MB y reconexión de FFmpeg (`reconnect=1`) para absorber los
  cortes de Wi-Fi sin que se note.
- **Supervisor de reconexión** propio: reintentos con espera creciente
  (1-2-4-8 s) reanudando en el segundo exacto donde se cortó. Detecta también
  los atascos silenciosos — mpv no siempre lanza un error cuando el teléfono
  deja de enviar datos, a veces se queda en "buffering" para siempre.
- Controles adaptados al ancho real de la ventana, no a la plataforma: una
  ventana estrecha en Windows recibe los mismos controles grandes que un móvil.

**Teclado (Windows):** `espacio`/`K` play-pausa · `←`/`→` ±10 s (con `shift`,
±60 s) · `↑`/`↓` volumen · `M` silencio · `F`/`F11` pantalla completa · `Esc`
salir.

**Gestos (Android):** un toque muestra controles · doble toque a los lados
±10 s, en el centro play-pausa · deslizar en vertical ajusta el volumen.

## Televisores LG

Hay una segunda app, independiente, en [`webos/`](webos/README.md). Flutter no
compila para webOS, así que es JavaScript y comparte el protocolo aprendido, no
el código. Allí no hay sockets crudos ni cabeceras legibles (CORS), y el
televisor solo tiene un pipeline de medios, así que el descubrimiento y la
detección de cambio de capítulo funcionan de otra manera. Está explicado en su
propio README.

## Estructura

```
lib/
  core/
    net/lan_guard.dart          frontera de seguridad: qué IPs son alcanzables
    theme/, utils/              tema, formateo, breakpoints
  features/
    discovery/
      domain/                   modelos: subred, candidato, métricas, eventos
      data/                     escáner de puertos, validador HTTP, orquestador
      presentation/             pantalla de búsqueda y tarjetas
    player/
      domain/track_labels.dart  nombres legibles de pistas
      presentation/             controlador, pantalla y controles
```

La regla: `domain` no importa nada de Flutter, `data` no importa nada de
`presentation`.

## Comandos

```bash
flutter run -d windows
```

```bash
flutter run -d android
```

```bash
flutter test
```

```bash
flutter build apk --release
```

### Instalador para Windows

Para compilar la aplicación y generar el instalador ejecutable (`.exe`) con asistente de configuración y opción de acceso directo en el escritorio:

- **Con doble clic**: Ejecuta `build_installer.bat` en la raíz del proyecto.
- **Desde PowerShell**:
  ```powershell
  .\scripts\build_installer.ps1
  ```
- Si ya compilaste Flutter previamente y solo deseas reempaquetar el instalador:
  ```powershell
  .\scripts\build_installer.ps1 -SkipFlutterBuild
  ```

El instalador generado se guardará en `build\installer\Flux_Setup_vX.Y.Z.exe`.

## Ajustes

Casi todo lo tocable está en
`lib/features/discovery/data/scan_config.dart`: listas de puertos, timeouts,
concurrencia y tamaño de la medición. Si tu app emite en un puerto fijo distinto
del 4445, ponlo el primero en `quickPorts` y el barrido lo encontrará al
instante.

## Estado

Verificado de extremo a extremo en Windows contra un stream real de Movie Plus:
descubrimiento, medición, reproducción automática, subtítulos y seek. El APK de
Android compila; falta probarlo sobre el dispositivo.

El cambio de capítulo está construido sobre el comportamiento observado del
servidor real y cubierto por tests de la máquina de estados, pero el cambio en
sí no se ha ejecutado todavía de extremo a extremo con la app delante.

Limitaciones conocidas:

- Solo IPv4 y subredes /24. Una red con máscara distinta (`/16`) solo se
  escanea en su tramo /24.
- Si el router tiene aislamiento de clientes (AP isolation), ningún escaneo
  puede funcionar; hay que desactivarlo en el router.
- Sin soporte para HTTPS con certificado autofirmado.

## Navegador y apertura remota de TV

- El navegador detecta URLs de video y manifiestos HLS/DASH, incluyendo respuestas fetch/XHR identificadas por Content-Type. Descarta segmentos individuales antes de enviarlos al detector.
- La detección no descarga cada candidato para verificarlo: se comprueba al seleccionarlo, con Referer, User-Agent y cookies del navegador. Las comprobaciones cancelan el cuerpo de la respuesta para evitar descargar un archivo completo cuando el servidor ignora Range.
- Los videos cortos no se consideran anuncios solo por su duración.
- El botón **Abrir Flux en TV** permite solicitar la apertura de la aplicación instalada en LG webOS y Samsung Tizen sin elegir un video. Hay que aceptar el emparejamiento en el televisor. LG espera la confirmación del lanzamiento; Samsung espera la autorización y envía la solicitud, sin confirmar que la aplicación haya terminado de abrir.
- El descubrimiento hace un barrido por solicitud, se detiene al cerrar el diálogo y puede repetirse con **Buscar de nuevo**.
- En Android TV el receptor HTTP necesita Flux abierto. Esta función no instala aplicaciones, no enciende la TV ni implementa un mando universal. La reproducción de contenido protegido o que requiera cabeceras depende del reproductor de cada TV.

Validación de estos ajustes: pruebas de detección/clasificación y respuestas de lanzamiento webOS con servidor local simulado. Emparejamiento y reproducción en hardware real pendientes.

## Versiones y publicación
Consulta [RELEASES.md](RELEASES.md). La fuente de versión es pubspec.yaml; el instalador recibe esa versión automáticamente. La web pública está en ../Webs/flux y el destino de releases se configura en release.config.json.
