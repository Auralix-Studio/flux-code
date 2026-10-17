import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flux/core/app_version.dart';
import 'package:flux/core/update_service.dart';
import 'package:flux/features/discovery/presentation/discovery_controller.dart';
import 'package:flux/features/discovery/presentation/discovery_screen.dart';

class IdleDiscoveryController extends DiscoveryController {
  @override
  DiscoveryState build() => const DiscoveryState();
  @override
  Future<void> start({bool exhaustive = false}) async {}
}

void main() {
  testWidgets('About shows the generated release version and update action', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    // Keep this UI test offline; manifest validation has its own regression tests.
    UpdateService.instance.busy = true;
    addTearDown(() {
      UpdateService.instance.busy = false;
    });
    tester.view.physicalSize = const Size(1200, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          discoveryControllerProvider.overrideWith(IdleDiscoveryController.new),
        ],
        child: const MaterialApp(home: DiscoveryScreen()),
      ),
    );
    await tester.pump();
    expect(find.text('Flux'), findsOneWidget);
    await tester.tap(find.byTooltip('Red y opciones'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Acerca de Flux'));
    await tester.tap(find.text('Acerca de Flux'));
    await tester.pumpAndSettle();
    expect(find.text('Versión ${AppVersion.full}'), findsOneWidget);
    expect(
      find.text('Buscar actualizaciones'),
      UpdateService.supported ? findsOneWidget : findsNothing,
    );
    await tester.tap(find.text('Cerrar'));
    await tester.pumpAndSettle();
    expect(find.text('Versión ${AppVersion.full}'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
