# Versiones y distribución de Flux

El código permanece en su repositorio privado. La web y los binarios se distribuyen desde Auralix-Studio/flux, configurado en release.config.json. La web está en ../Webs/flux.

## Preparación
- Crear el repositorio público con el contenido de Webs/flux y habilitar GitHub Pages con GitHub Actions. Debe tener al menos un commit.
- Mantener origin apuntando al código privado. El script rechaza que el destino público coincida con origin.
- PowerShell 7, Flutter compatible con pubspec.lock, Git, SDK Android y Java 17. Windows requiere las herramientas de compilación de Flutter.
- Crear android/key.properties con storeFile, storePassword, keyAlias y keyPassword, y usar el keystore de distribución. Conservar siempre la misma firma para las actualizaciones.
- Antes de compilar, revisar las notas y guardar los cambios en un commit. No se crean commits automáticamente.
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
El workflow Release es manual. Configurar en el repositorio privado:
- PUBLIC_RELEASE_TOKEN: token con Contents: write en el repositorio público. GITHUB_TOKEN no alcanza para otro repositorio.
- ANDROID_KEYSTORE_BASE64, ANDROID_KEY_ALIAS, ANDROID_KEY_PASSWORD, ANDROID_STORE_PASSWORD.

Las pruebas usan simuladores y no descargan ni publican. El workflow y una compilación firmada real deben validarse tras configurar las claves. El ZIP de Windows incluye el bundle completo; no incluye el instalador EXE. Las apps de TV de Flux tienen su propio empaquetado y no están incluidas en este flujo.
