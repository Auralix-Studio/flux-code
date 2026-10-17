# Versiones y distribución de Flux

El código permanece en su repositorio privado. La web y los binarios se distribuyen desde Auralix-Studio/flux, configurado en release.config.json. La web está en ../Webs/flux.

## Preparación
- Crear el repositorio público con el contenido de Webs/flux y habilitar GitHub Pages con GitHub Actions. Debe tener al menos un commit.
- Mantener origin apuntando al código privado. El script rechaza que el destino público coincida con origin.
- PowerShell 7, Flutter compatible con pubspec.lock, Git, SDK Android y Java 17. Windows requiere las herramientas de compilación de Flutter.
- Crear android/key.properties con storeFile, storePassword, keyAlias y keyPassword, y usar el keystore de distribución. Conservar siempre la misma firma para las actualizaciones.
- Antes de compilar localmente, revisar las notas y guardar los cambios en un commit. El script local no crea commits.
- Para publicar localmente, autenticar gh con acceso de escritura al repositorio público.

## Flujo
La fuente de versión es pubspec.yaml (X.Y.Z+N). El número de build crece incluso al cambiar major o minor. Compilar no incrementa la versión.

~~~powershell
pwsh ./scripts/bump_version.ps1 -Type patch
# Editar la entrada generada en assets/changelog.json.
pwsh ./scripts/sync_version.ps1 -Check
pwsh ./scripts/test_release.ps1
pwsh ./scripts/build_release.ps1 -DryRun
# Guardar los cambios en Git antes de compilar.
pwsh ./scripts/build_release.ps1
# Opcional: -Split -Windows para APKs por ABI y ZIP de Windows.
pwsh ./scripts/build_release.ps1 -SkipBuild -Publish -Draft
~~~

Los paquetes se guardan en dist/vX.Y.Z+N con binarios, notas, SHA256SUMS.txt y release-meta.json. La metadata identifica el commit privado usado para construirlos. Reutilizar un paquete verifica su versión, commit, destino, archivos y hashes. Las notas PENDIENTE impiden preparar la publicación.

La publicación comprueba que el destino sea público. No ejecuta git push ni envía commits privados. GitHub crea el tag público sobre la rama predeterminada de la web; ese tag no representa el commit del código. La metadata registra la procedencia real del binario.

Se cargan primero todos los archivos en un borrador. Sin -Draft se publica solo después de una carga satisfactoria. No se sobrescriben releases existentes. Si falla una carga, revisar el borrador antes de repetir. Un borrador aprobado puede publicarse desde GitHub.

## GitHub Actions
`auto-version.yml` valida pruebas en `main`, calcula la versión a partir de Conventional Commits, conserva las notas revisadas y crea un commit/tag privado mediante push atómico. `feat:` incrementa minor, `fix:` patch, `!` o `BREAKING CHANGE:` major. Los cambios de documentación, CI y pruebas por sí solos no publican. La rama `beta` no publica. `ci.yml` valida los PR a main/beta. Todos usan Flutter 3.47.7.

El flujo llama a `Release` con el commit exacto y publica Android y el ZIP Windows tras subirlos como borrador. Android y Windows se construyen secuencialmente; la ejecución manual permite omitir Windows. También se puede ejecutar `Release` manualmente con `draft=true`, y usar su entrada `ref` para recuperar un tag/commit ya preparado sin incrementar otra vez la versión. Configurar en el repositorio privado:
- PUBLIC_RELEASE_TOKEN: token con Contents: write en el repositorio público. GITHUB_TOKEN no alcanza para otro repositorio.
- ANDROID_KEYSTORE_BASE64, ANDROID_KEY_ALIAS, ANDROID_KEY_PASSWORD, ANDROID_STORE_PASSWORD.

GitHub Actions necesita permiso de escritura para el commit/tag privado y las reglas de protección de main deben permitirlo. El token público no cambia origin ni recibe el historial privado. La web despliega automáticamente al publicar la release; recupera y valida su `version.json` en cada despliegue.

## Identidad y actualización

El identificador es `com.auralix.flux`; el namespace Kotlin sigue siendo `com.aur.flux`. Android trata la edición antigua como otra aplicación: no hay migración automática de sus datos. Los archivos públicos conservan nombres `flux-vX.Y.Z-universal.apk` y sufijos de arquitectura. Todas las arquitecturas usan códigos `100000 + build * 10 + ABI`, con build máximo 209989999.

La app comprueba actualizaciones y ofrece búsqueda manual desde la pantalla principal. Android verifica SHA-256, tamaño, paquete, firma y versión antes de solicitar la instalación. Windows abre el ZIP validado por el manifiesto; su instalación y comprobación local del hash son manuales. `min_build` en `scripts/release_policy.json` muestra un aviso, no impone un bloqueo total. `STORE_BUILD=true` excluye la instalación directa y su permiso Android.

El bundle incluye `version.json` con hashes y URLs inmutables, además de `release-meta.json` y `SHA256SUMS.txt`. Una release pública nueva necesita un tag X.Y.Z nuevo; incrementar solo el build no permite sobrescribir un tag ya publicado.

Las pruebas usan simuladores y no descargan ni publican. El workflow y una compilación firmada real deben validarse tras configurar las claves. El ZIP de Windows incluye el bundle completo; no incluye el instalador EXE. Las apps de TV de Flux tienen su propio empaquetado y no están incluidas en este flujo.
