
/**
 * Equivalente webOS de:
 *   lib/features/discovery/data/discovery_repository.dart  (lógica de búsqueda)
 *   lib/features/discovery/data/known_hosts_store.dart     (persistencia)
 *   lib/features/discovery/domain/stream_candidate.dart    (modelo + fingerprint)
 *   lib/core/utils/formatters.dart                         (prettyTitle)
 *
 * Estas implementaciones deben mantenerse en sincronía en cuanto al protocolo
 * (puertos, orden de fases, lógica de fingerprint). Si cambias uno, revisa el otro.
 */
var FluxDiscovery = (function () {
  'use strict';

  function candidateFrom(raw, source) {
    var fileName = raw.fileName || null;
    return {
      host: raw.host,
      port: raw.port,
      url: raw.url,
      isExternal: !!raw.isExternal,
      fileName: fileName,
      contentType: raw.contentType || null,
      size: raw.size || null,
      lastModified: raw.lastModified || null,
      duration: typeof raw.duration === 'number' ? raw.duration : null,
      width: raw.width || null,
      height: raw.height || null,
      seekable: !!raw.seekable,
      probe: raw.source,
      source: source,
      address: raw.host + ':' + raw.port,
      title: displayTitle(raw, fileName),
      fingerprint: fingerprintOf(raw),
      headers: raw.headers || null
    };
  }

  function displayTitle(raw, fileName) {
    if (fileName) { return FluxUtils.prettyTitle(fileName); }
    if (raw.width && raw.height) { return 'Emisión ' + raw.width + '×' + raw.height; }
    return 'Emisión en directo';
  }

  function fingerprintOf(raw) {
    if (raw.fileName || raw.size || raw.lastModified) {
      return [raw.fileName || '', raw.size || 0, raw.lastModified || ''].join('|');
    }
    if (typeof raw.duration === 'number' && isFinite(raw.duration)) {
      return 'dur:' + raw.duration.toFixed(3);
    }
    return 'desconocido';
  }



  function loadKnown() {
    try {
      var raw = window.localStorage.getItem(FluxConfig.storageKey);
      return raw ? JSON.parse(raw) : [];
    } catch (e) {
      return [];
    }
  }

  function remember(host, port) {
    if (!FluxNet.isPrivateIp(host)) { return; }
    try {
      var list = loadKnown();
      var entry = host + ':' + port;
      var filtered = [entry];
      for (var i = 0; i < list.length && filtered.length < 12; i++) {
        if (list[i] !== entry) { filtered.push(list[i]); }
      }
      window.localStorage.setItem(FluxConfig.storageKey, JSON.stringify(filtered));
    } catch (e) {  }
  }

  function parseAddress(text) {
    var input = String(text || '').replace(/^\s+|\s+$/g, '');
    if (!input) { return null; }
    input = input.replace(/^https?:\/\//i, '');
    input = input.split('/')[0];
    var parts = input.split(':');
    var host = parts[0];
    var port = parts.length > 1 ? parseInt(parts[1], 10) : FluxConfig.primaryPort;
    if (!FluxNet.isPrivateIp(host)) { return null; }
    if (!port || port < 1 || port > 65535) { return null; }
    return { host: host, port: port };
  }

  function search(handlers) {
    var seen = {};
    var found = 0;
    var cancelled = false;
    var running = null;

    function emitFound(raw, source) {
      if (cancelled || !raw) { return; }
      var key = raw.host + ':' + raw.port;
      if (seen[key]) { return; }
      seen[key] = true;
      found++;
      handlers.onFound(candidateFrom(raw, source));
    }

    function phase(name, detail) {
      if (!cancelled) { handlers.onPhase(name, detail); }
    }

    function finish() {
      if (!cancelled) { handlers.onDone(found); }
    }

    function checkKnown(next) {
      var known = loadKnown();
      if (!known.length) { next(); return; }
      phase('conocidos', known.length + ' recordadas');

      var pending = known.length;
      for (var i = 0; i < known.length; i++) {
        var parsed = parseAddress(known[i]);
        if (!parsed) {
          if (--pending === 0) { next(); }
          continue;
        }
        
        FluxNet.inspect(parsed.host, parsed.port, function (result) {
          emitFound(result, 'conocido');
          if (--pending === 0) { next(); }
        });
      }
    }

    function sweepPrimary(prefix, next) {
      if (!FluxNet.canSweep()) {
        handlers.onWarning(
          'Este televisor es demasiado antiguo para barrer la red. ' +
          'Escribe la dirección a mano.'
        );
        next();
        return;
      }
      phase('rapido', prefix + '.0/24 · puerto ' + FluxConfig.primaryPort);
      sweepPorts(prefix, [FluxConfig.primaryPort], next);
    }

    function sweepSecondary(prefix, next) {
      if (found > 0 || !FluxNet.canSweep()) { next(); return; }
      phase('amplio', 'otros ' + FluxConfig.secondaryPorts.length + ' puertos');
      sweepPorts(prefix, FluxConfig.secondaryPorts, next);
    }

    function sweepPorts(prefix, ports, next) {
      var targets = [];
      var order = FluxConfig.hostOrder();
      // Orden puerto-mayor, igual que en escritorio: así el puerto más
      // probable se prueba en toda la red antes de pasar al siguiente.
      for (var p = 0; p < ports.length; p++) {
        for (var h = 0; h < order.length; h++) {
          targets.push({ host: prefix + '.' + order[h], port: ports[p] });
        }
      }

      var queue = [];
      var validating = false;
      var sweepDone = false;

      function pump() {
        if (validating || cancelled) { return; }
        if (!queue.length) {
          if (sweepDone) { next(); }
          return;
        }
        validating = true;
        var target = queue.shift();
        FluxNet.inspect(target.host, target.port, function (result) {
          emitFound(result, 'busqueda');
          validating = false;
          pump();
        });
      }

      running = FluxNet.pool(
        targets,
        FluxNet.concurrency(),
        function (target, done) {
          if (cancelled) { done(); return; }
          FluxNet.probeReachable(
            target.host,
            target.port,
            FluxConfig.probeTimeout,
            function (reachable) {
              if (reachable) {
                queue.push(target);
                pump();
              }
              done();
            }
          );
        },
        function (completed, total) { handlers.onProgress(completed, total); },
        function () {
          if (cancelled) { return; }
          sweepDone = true;
          pump();
        }
      );
    }

    FluxNet.detectLocalIp(function (ip) {
      if (cancelled) { return; }
      checkKnown(function () {
        if (cancelled) { return; }
        if (!ip || !FluxNet.isPrivateIp(ip)) {
          handlers.onWarning(
            'No se pudo averiguar la dirección del televisor. ' +
            'Puedes escribir la del teléfono a mano.'
          );
          finish();
          return;
        }
        var prefix = FluxNet.prefixOf(ip);
        sweepPrimary(prefix, function () {
          sweepSecondary(prefix, finish);
        });
      });
    });

    return {
      cancel: function () {
        cancelled = true;
        if (running) { running.cancel(); }
        // Además de dejar de lanzar peticiones, se cortan las que ya iban en
        // vuelo: el reproductor necesita las conexiones libres.
        FluxNet.abortAll();
      }
    };
  }

  return {
    search: search,
    remember: remember,
    parseAddress: parseAddress,
    candidateFrom: candidateFrom
  };
}());
