import 'dart:io';

import 'package:flutter/widgets.dart';

/// Tamaño de ventana según los breakpoints de Material 3.
enum ScreenSize { compact, medium, expanded }

extension ResponsiveContext on BuildContext {
  Size get _size => MediaQuery.sizeOf(this);

  ScreenSize get screenSize {
    final width = _size.width;
    if (width < 600) return ScreenSize.compact;
    if (width < 1000) return ScreenSize.medium;
    return ScreenSize.expanded;
  }

  bool get isCompact => screenSize == ScreenSize.compact;
  bool get isExpanded => screenSize == ScreenSize.expanded;

  /// Móvil real: gestos táctiles, controles grandes, orientación gestionada.
  bool get isMobilePlatform => Platform.isAndroid || Platform.isIOS || Platform.isWindows;

  /// Escritorio: teclado, hover, ventana redimensionable.
  bool get isDesktopPlatform =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  bool get isLandscape => _size.width > _size.height;

  /// Número de columnas para la rejilla de streams encontrados.
  int get streamGridColumns {
    final width = _size.width;
    if (width < 620) return 1;
    if (width < 1100) return 2;
    if (width < 1500) return 3;
    return 4;
  }

  /// Escala de los controles del reproductor: en un móvil en mano los botones
  /// deben ser mayores que en un monitor a 60 cm.
  double get controlScale => isCompact ? 1.0 : 1.15;
}
