import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/settings/app_settings.dart';
import '../../../core/app_version.dart';
import '../../../core/update_service.dart';
import '../../../core/update_banner.dart';
import '../../../core/utils/responsive.dart';
import '../../player/presentation/player_screen.dart';
import '../domain/discovery_event.dart';
import '../domain/lan_subnet.dart';
import '../domain/stream_candidate.dart';
import '../../browser/presentation/browser_screen.dart';
import 'discovery_controller.dart';
import 'widgets/external_link_sheet.dart';
import 'widgets/manual_connect_sheet.dart';
import 'widgets/stream_card.dart';

class DiscoveryScreen extends ConsumerStatefulWidget {
  const DiscoveryScreen({super.key});

  @override
  ConsumerState<DiscoveryScreen> createState() => _DiscoveryScreenState();
}

class _DiscoveryScreenState extends ConsumerState<DiscoveryScreen> {
  /// La reproducción automática se dispara **una sola vez por arranque**.
  /// Si volvieras a la lista y te lanzara otra vez al reproductor, no habría
  /// forma de elegir otro stream ni de salir.
  bool _autoPlayed = false;

  @override
  void initState() {
    super.initState();
    // Buscar nada más abrir: el usuario abre Flux porque ya hay algo emitiendo.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(discoveryControllerProvider.notifier).start();
    });
  }

  void _maybeAutoPlay(DiscoveryState state) {
    if (_autoPlayed || !ref.read(settingsProvider).autoPlay) return;
    final first = state.candidates.firstOrNull;
    if (first == null) return;
    _autoPlayed = true;
    // Medio segundo para que se vea aparecer la tarjeta: saltar a negro sin
    // que dé tiempo a leer nada resulta desconcertante.
    Future<void>.delayed(const Duration(milliseconds: 550), () {
      if (!mounted) return;
      final route = ModalRoute.of(context);
      if (route == null || !route.isCurrent) return;
      _play(first);
    });
  }

  Future<void> _play(StreamCandidate candidate) async {
    final controller = ref.read(discoveryControllerProvider.notifier);
    await controller.remember(candidate);
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PlayerScreen(candidate: candidate),
      ),
    );
  }

  Future<void> _openManual() async {
    final candidate = await ManualConnectSheet.show(context);
    if (candidate != null && mounted) await _play(candidate);
  }

  Future<void> _openExternalLink() async {
    final candidate = await ExternalLinkSheet.show(context);
    if (candidate != null && mounted) await _play(candidate);
  }

  Future<void> _openBrowser() async {
    if (Platform.isWindows || Platform.isLinux) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'El navegador embebido aún no está soportado en esta plataforma (v1).',
          ),
          duration: Duration(seconds: 3),
        ),
      );
      return;
    }

    final candidate = await Navigator.of(context).push(
      MaterialPageRoute<StreamCandidate?>(
        builder: (_) => const BrowserScreen(),
      ),
    );
    if (candidate != null && mounted) await _play(candidate);
  }

  void _showPrivacyPolicy() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Política de Privacidad'),
        content: const SingleChildScrollView(
          child: Text(
            'Flux es una aplicación diseñada para descubrir e interactuar con '
            'servidores de medios locales, y opcionalmente reproducir enlaces de Internet.\n\n'
            '• No recopilamos, almacenamos ni compartimos ningún tipo de '
            'información personal.\n'
            '• El descubrimiento automático ocurre de forma local (LAN).\n'
            '• Si usas el navegador embebido o pegas enlaces externos, Flux se '
            'conectará a esos servidores de Internet para extraer el video.\n'
            '• No utilizamos servidores centralizados para telemetría ni analíticas de uso.\n\n'
            'Al usar Flux, tienes la tranquilidad de que tus datos y hábitos '
            'de visualización permanecen 100% privados y bajo tu control.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Entendido'),
          ),
        ],
      ),
    );
  }

  void _showAbout() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Acerca de Flux'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Versión ${AppVersion.full}'),
            const Text(
              'Flux es un reproductor y escáner de streams para redes locales '
              'que te permite enviar y recibir emisiones fácilmente entre tus dispositivos.',
            ),
            const SizedBox(height: 16),
            Text(
              'Creado por Alessandro',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
            const SizedBox(height: 4),
            const Text('© 2026 Todos los derechos reservados.'),
          ],
        ),
        actions: [
          if (UpdateService.supported)
            TextButton(
              onPressed: () async {
                Navigator.of(context).pop();
                await UpdateService.instance.check();
                if (!mounted) return;
                final message = UpdateService.instance.message;
                if (message != null) {
                  ScaffoldMessenger.of(
                    this.context,
                  ).showSnackBar(SnackBar(content: Text(message)));
                }
              },
              child: const Text('Buscar actualizaciones'),
            ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cerrar'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(discoveryControllerProvider);
    final controller = ref.read(discoveryControllerProvider.notifier);
    final settings = ref.watch(settingsProvider);

    ref.listen<DiscoveryState>(
      discoveryControllerProvider,
      (_, next) => _maybeAutoPlay(next),
    );

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 20,
        title: Row(
          children: [
            Icon(
              Icons.bolt_rounded,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(width: 8),
            const Text('Flux', style: TextStyle(fontWeight: FontWeight.w700)),
          ],
        ),
        actions: [
          IconButton(
            onPressed: _openBrowser,
            tooltip: 'Navegador web',
            icon: const Icon(Icons.public),
          ),
          IconButton(
            onPressed: _openExternalLink,
            tooltip: 'Pegar enlace de Internet',
            icon: const Icon(Icons.link_rounded),
          ),
          IconButton(
            onPressed: _openManual,
            tooltip: 'Conectar a mano (LAN)',
            icon: const Icon(Icons.keyboard_alt_outlined),
          ),
          _SubnetMenu(
            subnets: state.subnets,
            selected: state.selectedSubnet,
            autoPlay: settings.autoPlay,
            followSource: settings.followSource,
            onSelected: controller.selectSubnet,
            onExhaustive: () => controller.start(exhaustive: true),
            onRefreshNetworks: controller.loadSubnets,
            onToggleAutoPlay: () => ref
                .read(settingsProvider.notifier)
                .setAutoPlay(!settings.autoPlay),
            onToggleFollow: () => ref
                .read(settingsProvider.notifier)
                .setFollowSource(!settings.followSource),
            onPrivacyPolicy: _showPrivacyPolicy,
            onAbout: _showAbout,
          ),
          const SizedBox(width: 8),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: state.isScanning ? controller.stop : controller.start,
        icon: Icon(state.isScanning ? Icons.stop_rounded : Icons.radar_rounded),
        label: Text(state.isScanning ? 'Detener' : 'Buscar'),
      ),
      body: Column(
        children: [
          const UpdateBanner(),
          _ScanStatus(state: state),
          Expanded(
            child: _Content(state: state, onPlay: _play, onManual: _openManual),
          ),
        ],
      ),
    );
  }
}

/// Cabecera con el estado de la búsqueda. La barra de progreso es por fase, no
/// global: engañaría menos decir "buscando en los puertos habituales, 40 %"
/// que fingir un único porcentaje para cuatro fases de coste muy distinto.
class _ScanStatus extends StatelessWidget {
  const _ScanStatus({required this.state});

  final DiscoveryState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final subtitle = [
      if (state.detail != null) state.detail!,
      if (state.candidates.isNotEmpty)
        '${state.candidates.length} encontrado'
            '${state.candidates.length == 1 ? '' : 's'}',
    ].join(' · ');

    return Container(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  state.phase.label,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (subtitle.isNotEmpty)
                Text(
                  subtitle,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: state.isScanning
                  ? (state.progress == 0 ? null : state.progress)
                  : (state.phase == ScanPhase.idle ? 0 : 1),
              minHeight: 4,
            ),
          ),
          if (state.message != null) ...[
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.info_outline_rounded,
                  size: 15,
                  color: Color(0xFFE0B33C),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    state.message!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _Content extends ConsumerWidget {
  const _Content({
    required this.state,
    required this.onPlay,
    required this.onManual,
  });

  final DiscoveryState state;
  final Future<void> Function(StreamCandidate) onPlay;
  final VoidCallback onManual;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (state.candidates.isEmpty) {
      return state.isScanning
          ? const _Searching()
          : _EmptyState(state: state, onManual: onManual);
    }

    final controller = ref.read(discoveryControllerProvider.notifier);
    final columns = context.streamGridColumns;

    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 96),
      itemCount: state.candidates.length,
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: columns,
        crossAxisSpacing: 14,
        mainAxisSpacing: 14,
        mainAxisExtent: 300,
      ),
      itemBuilder: (context, index) {
        final candidate = state.candidates[index];
        return StreamCard(
          candidate: candidate,
          isBest:
              index == 0 &&
              candidate.metrics != null &&
              state.candidates.length > 1,
          onPlay: () => onPlay(candidate),
          onRemeasure: () => controller.remeasure(candidate),
        );
      },
    );
  }
}

class _Searching extends StatelessWidget {
  const _Searching();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const _PulsingRadar(),
          const SizedBox(height: 24),
          Text('Rastreando tu red…', style: theme.textTheme.titleMedium),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40),
            child: Text(
              'Asegúrate de que la transmisión está activa en el teléfono y de '
              'que ambos estáis en el mismo Wi-Fi.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PulsingRadar extends StatefulWidget {
  const _PulsingRadar();

  @override
  State<_PulsingRadar> createState() => _PulsingRadarState();
}

class _PulsingRadarState extends State<_PulsingRadar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animation = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  )..repeat();

  @override
  void dispose() {
    _animation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    return SizedBox(
      width: 120,
      height: 120,
      child: AnimatedBuilder(
        animation: _animation,
        builder: (context, child) {
          return Stack(
            alignment: Alignment.center,
            children: [
              for (var i = 0; i < 3; i++)
                _ring(color, (_animation.value + i / 3) % 1),
              Icon(Icons.wifi_tethering_rounded, size: 34, color: color),
            ],
          );
        },
      ),
    );
  }

  Widget _ring(Color color, double t) {
    return Container(
      width: 40 + 80 * t,
      height: 40 + 80 * t,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: color.withValues(alpha: (1 - t) * 0.5)),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.state, required this.onManual});

  final DiscoveryState state;
  final VoidCallback onManual;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final noNetwork = state.phase == ScanPhase.noNetwork;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 32, 24, 96),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Icon(
                noNetwork
                    ? Icons.wifi_off_rounded
                    : Icons.travel_explore_rounded,
                size: 48,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(height: 18),
              Text(
                noNetwork
                    ? 'No estás conectado a una red local'
                    : 'No se encontró ninguna transmisión',
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 20),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainer,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: theme.colorScheme.outlineVariant),
                ),
                child: const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _Hint(
                      'Empieza a transmitir en el teléfono antes de buscar.',
                    ),
                    _Hint(
                      'Los dos dispositivos deben estar en el mismo Wi-Fi, '
                      'no en la red de invitados.',
                    ),
                    _Hint(
                      'Si tu router tiene aislamiento de clientes activado, '
                      'ningún escaneo funcionará: desactívalo.',
                    ),
                    _Hint(
                      '¿Ya sabes la dirección? Escríbela directamente.',
                      last: true,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: onManual,
                icon: const Icon(Icons.keyboard_alt_outlined),
                label: const Text('Escribir IP y puerto'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint(this.text, {this.last = false});

  final String text;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: last ? 0 : 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 5),
            child: Container(
              width: 5,
              height: 5,
              decoration: BoxDecoration(
                color: theme.colorScheme.primary,
                shape: BoxShape.circle,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Fila de menú con estado de encendido/apagado.
class _Toggle extends StatelessWidget {
  const _Toggle({
    required this.enabled,
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final bool enabled;
  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Icon(
          icon,
          size: 20,
          color: enabled
              ? theme.colorScheme.primary
              : theme.colorScheme.outline,
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title),
              Text(
                subtitle,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        Icon(
          enabled ? Icons.toggle_on_rounded : Icons.toggle_off_rounded,
          color: enabled
              ? theme.colorScheme.primary
              : theme.colorScheme.outline,
        ),
      ],
    );
  }
}

class _SubnetMenu extends StatelessWidget {
  const _SubnetMenu({
    required this.subnets,
    required this.selected,
    required this.autoPlay,
    required this.followSource,
    required this.onSelected,
    required this.onExhaustive,
    required this.onRefreshNetworks,
    required this.onToggleAutoPlay,
    required this.onToggleFollow,
    required this.onPrivacyPolicy,
    required this.onAbout,
  });

  final List<LanSubnet> subnets;
  final LanSubnet? selected;
  final bool autoPlay;
  final bool followSource;
  final ValueChanged<LanSubnet> onSelected;
  final VoidCallback onExhaustive;
  final VoidCallback onRefreshNetworks;
  final VoidCallback onToggleAutoPlay;
  final VoidCallback onToggleFollow;
  final VoidCallback onPrivacyPolicy;
  final VoidCallback onAbout;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PopupMenuButton<Object>(
      tooltip: 'Red y opciones',
      icon: const Icon(Icons.more_vert_rounded),
      onSelected: (value) {
        if (value is LanSubnet) {
          onSelected(value);
        } else if (value == 'exhaustive') {
          onExhaustive();
        } else if (value == 'refresh') {
          onRefreshNetworks();
        } else if (value == 'autoplay') {
          onToggleAutoPlay();
        } else if (value == 'follow') {
          onToggleFollow();
        } else if (value == 'privacy') {
          onPrivacyPolicy();
        } else if (value == 'about') {
          onAbout();
        }
      },
      itemBuilder: (context) => [
        const PopupMenuItem<Object>(
          enabled: false,
          height: 32,
          child: Text('REPRODUCCIÓN', style: TextStyle(fontSize: 10)),
        ),
        PopupMenuItem<Object>(
          value: 'autoplay',
          child: _Toggle(
            enabled: autoPlay,
            icon: Icons.play_circle_outline_rounded,
            title: 'Reproducción automática',
            subtitle: 'Abre el primer stream al iniciar',
          ),
        ),
        PopupMenuItem<Object>(
          value: 'follow',
          child: _Toggle(
            enabled: followSource,
            icon: Icons.sensors_rounded,
            title: 'Seguir la emisión',
            subtitle: 'Carga sola el capítulo que pongas',
          ),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem<Object>(
          enabled: false,
          height: 32,
          child: Text('RED A ESCANEAR', style: TextStyle(fontSize: 10)),
        ),
        for (final subnet in subnets)
          PopupMenuItem<Object>(
            value: subnet,
            child: Row(
              children: [
                Icon(
                  subnet == selected
                      ? Icons.radio_button_checked_rounded
                      : Icons.radio_button_unchecked_rounded,
                  size: 18,
                  color: subnet == selected ? theme.colorScheme.primary : null,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(subnet.cidr),
                      Text(
                        subnet.isVirtual
                            ? '${subnet.interfaceName} · virtual'
                            : subnet.interfaceName,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        const PopupMenuDivider(),
        const PopupMenuItem<Object>(
          value: 'refresh',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.refresh_rounded, size: 20),
            title: Text('Volver a detectar redes'),
          ),
        ),
        const PopupMenuItem<Object>(
          value: 'exhaustive',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.travel_explore_rounded, size: 20),
            title: Text('Búsqueda exhaustiva'),
            subtitle: Text('Más lenta, revisa ~400 puertos'),
          ),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem<Object>(
          value: 'about',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.info_outline_rounded, size: 20),
            title: Text('Acerca de Flux'),
          ),
        ),
        const PopupMenuItem<Object>(
          value: 'privacy',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.privacy_tip_outlined, size: 20),
            title: Text('Política de Privacidad'),
          ),
        ),
      ],
    );
  }
}
