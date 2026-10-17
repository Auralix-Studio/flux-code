import 'package:flutter/material.dart';
import 'dart:io';
import 'app_version.dart';
import 'update_service.dart';

class UpdateBanner extends StatefulWidget {
  const UpdateBanner({super.key});
  @override
  State<UpdateBanner> createState() => _UpdateBannerState();
}

class _UpdateBannerState extends State<UpdateBanner> {
  @override
  void initState() {
    super.initState();
    UpdateService.instance.check();
  }

  @override
  Widget build(BuildContext context) {
    if (!UpdateService.supported) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: UpdateService.instance,
      builder: (context, _) {
        final service = UpdateService.instance;
        final update = service.available;
        if (update == null) return const SizedBox.shrink();
        return MaterialBanner(
          content: Text(
            service.message ??
                'Flux ${update.version} está disponible${AppVersion.build < update.minBuild ? '. Tu versión necesita actualizarse' : ''}.',
          ),
          actions: [
            TextButton(
              onPressed: service.busy ? null : service.install,
              child: Text(
                service.busy
                    ? 'Verificando…'
                    : Platform.isWindows
                    ? 'Descargar ZIP'
                    : 'Actualizar',
              ),
            ),
          ],
        );
      },
    );
  }
}
