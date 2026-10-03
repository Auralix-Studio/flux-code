
(function () {
  'use strict';

  var KEY = {
    ENTER: 13, LEFT: 37, UP: 38, RIGHT: 39, DOWN: 40,
    BACK: 461, ESC: 27,
    PLAY: 415, PAUSE: 19, PLAYPAUSE: 10252, STOP: 413,
    FF: 417, RW: 412
  };

  var el = {};
  var view = 'search';
  var search = null;
  var player = null;
  var candidates = [];
  var autoPlayed = false;
  var controlsTimer = null;
  var bannerTimer = null;

  var zone = 'actions';
  var cardIndex = 0;
  var actionIndex = 0;
  var manualIndex = 0;
  var errorIndex = 0;
  
  var tracksCol = 0;
  var tracksRow = [0, 0];
  var cachedAudio = [];
  var cachedSubs = [];

  function byId(id) { return document.getElementById(id); }

  function init() {
    el.viewSearch = byId('view-search');
    el.viewManual = byId('view-manual');
    el.viewAbout = byId('view-about');
    el.viewPlayer = byId('view-player');
    el.status = byId('search-status');
    el.bar = byId('search-bar');
    el.warning = byId('search-warning');
    el.results = byId('results');
    el.empty = byId('empty');
    el.btnSearch = byId('btn-search');
    el.btnManual = byId('btn-manual');
    el.btnAbout = byId('btn-about');
    el.manualInput = byId('manual-input');
    el.manualError = byId('manual-error');
    el.btnConnect = byId('btn-connect');
    el.btnManualBack = byId('btn-manual-back');
    el.btnAboutBack = byId('btn-about-back');
    el.video = byId('video');
    el.banner = byId('banner');
    el.prepare = byId('prepare');
    el.prepareTitle = byId('prepare-title');
    el.prepareNote = byId('prepare-note');
    el.controls = byId('controls');
    el.playerTitle = byId('player-title');
    el.playerAddress = byId('player-address');
    el.seekBuffer = byId('seek-buffer');
    el.seekPlayed = byId('seek-played');
    el.seekKnob = byId('seek-knob');
    el.timeNow = byId('time-now');
    el.timeTotal = byId('time-total');
    el.followHint = byId('follow-hint');
    el.playerError = byId('player-error');
    el.playerErrorText = byId('player-error-text');
    el.btnRetry = byId('btn-retry');
    el.btnPlayerBack = byId('btn-player-back');
    el.bannerText = byId('banner-text');
    el.skipLeft = byId('skip-left');
    el.skipRight = byId('skip-right');
    el.btnTracks = byId('btn-tracks');
    el.viewTracks = byId('view-tracks');
    el.listSubtitles = byId('list-subtitles');
    el.listAudio = byId('list-audio');

    el.btnSearch.onclick = startSearch;
    el.btnManual.onclick = function () { showView('manual'); };
    el.btnAbout.onclick = function () { showView('about'); };
    el.btnConnect.onclick = connectManual;
    el.btnManualBack.onclick = function () { showView('search'); };
    el.btnAboutBack.onclick = function () { showView('search'); };
    el.btnRetry.onclick = function () { hideError(); if (player) { player.retry(); } };
    el.btnPlayerBack.onclick = leavePlayer;
    if (el.btnTracks) { el.btnTracks.onclick = openTracks; }
    
    el.iconPlay = byId('icon-play');
    el.iconPause = byId('icon-pause');
    el.playPauseFeedback = byId('play-pause-feedback');
    
    el.video.addEventListener('play', function () { showPlayPauseFeedback(true); }, false);
    el.video.addEventListener('pause', function () { showPlayPauseFeedback(false); }, false);

    document.addEventListener('keydown', onKey, false);

    setupLifecycle();

    if (!checkLaunchParams()) {
      startSearch();
    }
  }

  var keepAliveTimer = null;
  var screenSaverDisabled = false;

  function setupLifecycle() {
    
    requestKeepAlive(true);

    keepAliveTimer = setInterval(function () {
      requestKeepAlive(true);
    }, 240000);

    document.addEventListener('visibilitychange', onVisibilityChange, false);
    document.addEventListener('webOSRelaunch', onRelaunch, false);
  }

  function requestKeepAlive(value) {
    if (window.tizen && typeof tizen.power !== 'undefined') {
      try {
        if (value) {
          tizen.power.request('SCREEN', 'SCREEN_NORMAL');
        } else {
          tizen.power.release('SCREEN');
        }
      } catch (e) { }
    }
    
    if (window.webOSSystem && typeof webOSSystem.keepAlive === 'function') {
      try { webOSSystem.keepAlive(value); } catch (e) {  }
    }
    
    if (window.PalmSystem && typeof PalmSystem.keepAlive === 'function') {
      try { PalmSystem.keepAlive(value); } catch (e) {  }
    }
  }

  function setScreenSaver(enabled) {
    screenSaverDisabled = !enabled;
    requestKeepAlive(!enabled);
    
    if (!window.PalmServiceBridge) { return; }

    var bridge;
    try { bridge = new window.PalmServiceBridge(); } catch (e) { return; }

    bridge.onservicecallback = function () {  };

    try {
      if (!enabled) {
        
        bridge.call(
          'luna://com.webos.service.tvpower/power/turnOnScreenSaver',
          JSON.stringify({ block: true })
        );
      } else {
        bridge.call(
          'luna://com.webos.service.tvpower/power/turnOnScreenSaver',
          JSON.stringify({ block: false })
        );
      }
    } catch (e) {  }

    try {
      var bridge2 = new window.PalmServiceBridge();
      bridge2.onservicecallback = function () {};
      bridge2.call(
        'luna://com.webos.service.power2/display/setState',
        JSON.stringify({
          state: enabled ? 'ActiveStandby' : 'Active',
          reason: 'com.aur.flux'
        })
      );
    } catch (e2) {  }
  }

  var activityTimer = null;

  function startActivityHeartbeat() {
    stopActivityHeartbeat();
    activityTimer = setInterval(function () {
      if (!window.PalmServiceBridge) { return; }
      try {
        var bridge = new window.PalmServiceBridge();
        bridge.onservicecallback = function () {};
        
        bridge.call(
          'luna://com.webos.service.tvpower/power/turnOnScreen',
          JSON.stringify({ reason: 'remoteKey' })
        );
      } catch (e) {  }
    }, 180000); 
  }

  function stopActivityHeartbeat() {
    if (activityTimer) { clearInterval(activityTimer); activityTimer = null; }
  }

  var wasPlayingBeforeHide = false;

  function onVisibilityChange() {
    if (document.hidden) {
      
      if (el.video && !el.video.paused) {
        wasPlayingBeforeHide = true;
        try { el.video.pause(); } catch (e) {  }
      } else {
        wasPlayingBeforeHide = false;
      }
      
      setScreenSaver(true);
      stopActivityHeartbeat();
    } else {
      
      requestKeepAlive(true);
      if (wasPlayingBeforeHide && el.video) {
        setScreenSaver(false);
        startActivityHeartbeat();
        try { el.video.play(); } catch (e) {  }
        wasPlayingBeforeHide = false;
      }
    }
  }

  function onRelaunch() {
    
    requestKeepAlive(true);
    checkLaunchParams();
  }

  function checkLaunchParams() {
    // webOS params
    var paramsStr = '';
    if (window.webOSSystem && window.webOSSystem.launchParams) {
      paramsStr = window.webOSSystem.launchParams;
    } else if (window.PalmSystem && window.PalmSystem.launchParams) {
      paramsStr = window.PalmSystem.launchParams;
    }
    
    if (paramsStr) {
      try {
        var params = JSON.parse(paramsStr);
        if (params && (params.host || params.url)) {
          if (window.webOSSystem) { window.webOSSystem.launchParams = ''; }
          if (window.PalmSystem) { window.PalmSystem.launchParams = ''; }
          var candidate = FluxDiscovery.candidateFrom(params, 'cast');
          openPlayer(candidate);
          return true;
        }
      } catch (e) { }
    }

    // Tizen params
    if (window.tizen && typeof tizen.application !== 'undefined') {
      try {
        var appControl = tizen.application.getCurrentApplication().getRequestedAppControl();
        if (appControl && appControl.appControl) {
          var reqData = appControl.appControl.data;
          var params = {};
          
          for (var i = 0; i < reqData.length; i++) {
            if (reqData[i].key === 'PAYLOAD') {
              try {
                params = JSON.parse(reqData[i].value[0]);
              } catch (e) {}
            }
          }
          
          if (params && (params.host || params.url)) {
            var candidate = FluxDiscovery.candidateFrom(params, 'cast');
            openPlayer(candidate);
            return true;
          }
        }
      } catch (e) { }
    }

    return false;
  }

  function showView(name) {
    // Hide all overlays first
    el.viewManual.className = 'modal-overlay';
    el.viewAbout.className = 'modal-overlay';
    el.viewTracks.className = 'modal-overlay';
    
    if (name === 'manual') {
      el.viewManual.className = 'modal-overlay is-active';
      view = name;
      manualIndex = 0;
      el.manualError.innerHTML = '';
      applyFocus();
      return;
    } else if (name === 'about') {
      el.viewAbout.className = 'modal-overlay is-active';
      view = name;
      applyFocus();
      return;
    } else if (name === 'tracks') {
      el.viewTracks.className = 'modal-overlay is-active';
      view = name;
      applyFocus();
      return;
    }

    view = name;
    el.viewSearch.className = 'view' + (name === 'search' ? ' is-active' : '');
    el.viewPlayer.className = 'view view-player' + (name === 'player' ? ' is-active' : '');

    if (name === 'search') {
      zone = candidates.length ? 'results' : 'actions';
      applyFocus();
    }
  }

  function startSearch() {
    if (search) { search.cancel(); }
    candidates = [];
    cardIndex = 0;
    el.results.innerHTML = '';
    el.empty.className = 'empty';
    el.warning.innerHTML = '';
    setProgress(0, 0);
    setStatus('Detectando la red del televisor…');
    showView('search');

    search = FluxDiscovery.search({
      onPhase: function (name, detail) {
        var labels = {
          conocidos: 'Probando servidores conocidos…',
          rapido: 'Buscando en la red…',
          amplio: 'Buscando en otros puertos…',
          validando: 'Comprobando qué es cada uno…'
        };
        setStatus((labels[name] || name) + (detail ? '  ·  ' + detail : ''));
        setProgress(0, 0);
      },
      onProgress: setProgress,
      onFound: function (candidate) {
        candidates.push(candidate);
        renderCards();
        if (!autoPlayed) {
          autoPlayed = true;
          // Igual que en la app de escritorio: se abre solo el primero que
          // aparece, una única vez por arranque. Después, manda el usuario.
          setTimeout(function () {
            if (view === 'search') { openPlayer(candidate); }
          }, 700);
        }
      },
      onWarning: function (message) { el.warning.innerHTML = escape(message); },
      onDone: function (total) {
        setStatus(total > 0
          ? 'Búsqueda completada  ·  ' + total + (total === 1 ? ' emisión' : ' emisiones')
          : 'No se encontró ninguna emisión');
        setProgress(1, 1);
        el.empty.className = 'empty' + (total === 0 ? ' is-visible' : '');
        if (total === 0) { zone = 'actions'; applyFocus(); }
      }
    });
  }

  function setStatus(text) { el.status.innerHTML = escape(text); }

  function setProgress(done, total) {
    var pct = total > 0 ? Math.round((done / total) * 100) : 0;
    el.bar.style.width = pct + '%';
  }

  function renderCards() {
    el.results.innerHTML = '';
    for (var i = 0; i < candidates.length; i++) {
      el.results.appendChild(buildCard(candidates[i], i));
    }
    if (zone !== 'results') { zone = 'results'; }
    applyFocus();
  }

  function buildCard(candidate, index) {
    var card = document.createElement('div');
    card.className = 'card' + (index === 0 && candidates.length > 1 ? ' is-best' : '');
    card.tabIndex = -1;
    card.setAttribute('data-index', index);

    var tags = '';
    if (candidate.size) {
      tags += '<span class="tag"><span class="icon"><svg viewBox="0 0 24 24" width="1em" height="1em" fill="currentColor"><path d="M18 2h-8L4 8v12c0 1.1.9 2 2 2h12c1.1 0 2-.9 2-2V4c0-1.1-.9-2-2-2zm-6 6h-2V4h2v4zm3 0h-2V4h2v4zm3 0h-2V4h2v4z"/></svg></span>' + formatSize(candidate.size) + '</span>';
    }
    tags += candidate.seekable
      ? '<span class="tag"><span class="icon"><svg viewBox="0 0 24 24" width="1em" height="1em" fill="currentColor"><path d="M6.99 11L3 15l3.99 4v-3H14v-2H6.99v-3zM21 9l-3.99-4v3H10v2h7.01v3L21 9z"/></svg></span>Con avance</span>'
      : '<span class="tag tag-warn"><span class="icon"><svg viewBox="0 0 24 24" width="1em" height="1em" fill="currentColor"><path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zM4 12c0-4.42 3.58-8 8-8 1.85 0 3.55.63 4.9 1.69L5.69 16.9C4.63 15.55 4 13.85 4 12zm8 8c-1.85 0-3.55-.63-4.9-1.69L18.31 7.1C19.37 8.45 20 10.15 20 12c0 4.42-3.58 8-8 8z"/></svg></span>Sin avance</span>';
    if (candidate.source === 'conocido') {
      tags += '<span class="tag"><span class="icon"><svg viewBox="0 0 24 24" width="1em" height="1em" fill="currentColor"><path d="M13 3c-4.97 0-9 4.03-9 9H1l3.89 3.89.07.14L9 12H6c0-3.87 3.13-7 7-7s7 3.13 7 7-3.13 7-7 7c-1.93 0-3.68-.79-4.94-2.06l-1.42 1.42C8.27 19.99 10.51 21 13 21c4.97 0 9-4.03 9-9s-4.03-9-9-9zm-1 5v5l4.28 2.54.72-1.21-3.5-2.08V8H12z"/></svg></span>Conocido</span>';
    }

    var badge = index === 0 && candidates.length > 1 
      ? '<div class="badge-best">MEJOR</div>' : '';

    card.innerHTML =
      '<div class="card-top">' +
        '<div class="card-poster"><span class="icon"><svg viewBox="0 0 24 24" width="1em" height="1em" fill="currentColor"><path d="M18 4l2 4h-3l-2-4h-2l2 4h-3l-2-4H8l2 4H7L5 4H4c-1.1 0-1.99.9-1.99 2L2 18c0 1.1.9 2 2 2h16c1.1 0 2-.9 2-2V4h-4z"/></svg></span></div>' +
        '<div class="card-info">' +
          '<div class="card-title">' + escape(candidate.title) + '</div>' +
          '<div class="card-meta">' + escape(candidate.address) + '</div>' +
        '</div>' +
        badge +
      '</div>' +
      '<div class="card-tags">' + tags + '</div>' +
      '<div class="card-metrics">' +
        '<div class="metric"><span class="metric-label">Estado</span><span class="metric-val val-good">Apto</span></div>' +
        '<div class="metric"><span class="metric-label">Duración</span><span class="metric-val">' + (candidate.duration ? formatTime(candidate.duration) : '--:--') + '</span></div>' +
      '</div>';

    card.onclick = function () { openPlayer(candidate); };
    return card;
  }

  function connectManual() {
    var parsed = FluxDiscovery.parseAddress(el.manualInput.value);
    if (!parsed) {
      el.manualError.innerHTML =
        'Dirección no válida. Usa una IP de tu red local, por ejemplo 192.168.1.5:4445';
      return;
    }
    el.manualError.innerHTML = 'Comprobando…';
    FluxNet.inspect(parsed.host, parsed.port, function (raw) {
      if (!raw) {
        el.manualError.innerHTML =
          'No hay ningún video en ' + parsed.host + ':' + parsed.port +
          '. Comprueba que la transmisión esté activa.';
        return;
      }
      el.manualError.innerHTML = '';
      openPlayer(FluxDiscovery.candidateFrom(raw, 'manual'));
    });
  }

  function openPlayer(candidate) {
    
    if (search) { search.cancel(); search = null; }

    FluxDiscovery.remember(candidate.host, candidate.port);
    showView('player');
    hideError();
    el.playerTitle.innerHTML = escape(candidate.title);
    el.playerAddress.innerHTML = escape(candidate.address);
    showControls();

    setScreenSaver(false);
    startActivityHeartbeat();

    if (player) { player.destroy(); }
    player = new FluxPlayer(el.video, {
      onPreparing: function (info) {
        el.prepareTitle.innerHTML = escape(info.candidate.title);
        el.prepareNote.innerHTML = info.resuming
          ? 'Recuperando donde ibas…'
          : 'Precargando…';
        el.prepare.className = 'prepare is-visible';
      },
      onReady: function () { el.prepare.className = 'prepare'; },
      onMeta: function (info) {
        el.timeTotal.innerHTML = formatTime(info.duration);
        // Sin cabeceras, la resolución es lo único que identifica lo que estás
        // viendo, y hasta que no cargan los metadatos no se conoce.
        if (player && player.candidate() && !player.candidate().fileName && info.width) {
          el.playerTitle.innerHTML = escape('Emisión ' + info.width + '×' + info.height);
        }
      },
      onTime: updateSeek,
      onBuffer: updateSeek,
      
      onSeekPreview: function (targetSeconds) {
        var duration = el.video.duration;
        if (!duration || !isFinite(duration)) { return; }
        var pct = (targetSeconds / duration) * 100;
        el.seekPlayed.style.width = pct + '%';
        el.seekKnob.style.left = pct + '%';
        el.timeNow.innerHTML = formatTime(targetSeconds);
      },
      onPlaying: function () { hideError(); },
      onWaiting: function () {  },
      onReconnecting: function (attempt) {
        showBanner('Se cortó la emisión. Reintentando (' + attempt + ')…', true);
      },
      onLost: function () {
        showBanner('La emisión se detuvo. Esperando al capítulo siguiente…', true);
      },
      onRestored: function () { showBanner('Emisión recuperada'); },
      onChanged: function (candidate2) {
        el.playerTitle.innerHTML = escape(candidate2.title);
        el.playerAddress.innerHTML = escape(candidate2.address);
        showBanner('Capítulo nuevo detectado');
        showControls();
      },
      onStalled: function () { showBanner('La imagen se quedó parada. Recuperando…', true); },
      onEnded: function () { showBanner('Terminó. Esperando a lo siguiente…'); },
      onFatal: function (message) { 
        showError(message); 
        setTimeout(function() {
          leavePlayer();
        }, 4000);
      }
    });
    player.start(candidate);
    updateFollowHint();
  }

  function leavePlayer() {
    if (player) { player.destroy(); player = null; }
    hideError();
    el.prepare.className = 'prepare';
    hideBanner();

    setScreenSaver(true);
    stopActivityHeartbeat();

    showView('search');
  }

  function updateSeek() {
    var duration = el.video.duration;
    if (!duration || !isFinite(duration)) { return; }
    var played = el.video.currentTime / duration;
    el.seekPlayed.style.width = (played * 100) + '%';
    el.seekKnob.style.left = (played * 100) + '%';
    el.timeNow.innerHTML = formatTime(el.video.currentTime);
    try {
      if (el.video.buffered && el.video.buffered.length) {
        var end = el.video.buffered.end(el.video.buffered.length - 1);
        el.seekBuffer.style.width = ((end / duration) * 100) + '%';
      }
    } catch (e) {  }
  }

  function showControls() {
    if (el.controls) { el.controls.className = 'controls is-visible'; }
    clearTimeout(controlsTimer);
    controlsTimer = setTimeout(function () {
      if (!el.video.paused && el.controls) { el.controls.className = 'controls'; }
    }, 4000);
  }

  function toggleControls() {
    if (!el.controls) return;
    if (el.controls.className.indexOf('is-visible') >= 0) {
      el.controls.className = 'controls';
    } else {
      showControls();
    }
  }

  function openTracks() {
    if (!player) { return; }
    cachedAudio = player.getAudioTracks();
    cachedSubs = player.getTextTracks();
    renderTracks(el.listAudio, cachedAudio, 1);
    renderTracks(el.listSubtitles, cachedSubs, 0);
    tracksCol = 0;
    tracksRow = [
      Math.max(0, cachedSubs.findIndex(function(t) { return t.enabled; })),
      Math.max(0, cachedAudio.findIndex(function(t) { return t.enabled; }))
    ];
    showView('tracks');
  }

  function renderTracks(container, tracks, colIndex) {
    if (!container) return;
    container.innerHTML = '';
    for (var i = 0; i < tracks.length; i++) {
      var li = document.createElement('li');
      li.className = 'track-item' + (tracks[i].enabled ? ' is-selected' : '');
      li.tabIndex = -1;
      li.innerHTML = escape(tracks[i].label);
      container.appendChild(li);
    }
  }

  function updateFollowHint() {
    el.followHint.innerHTML = (player && player.isFollowing())
      ? 'seguimiento activo'
      : 'seguimiento apagado';
  }

  function showBanner(message, warning) {
    el.bannerText.innerHTML = escape(message);
    el.banner.className = 'banner';
    setTimeout(function () { el.banner.className = 'banner is-visible' + (warning ? ' is-warning' : ''); }, 10);
    bannerTimer = setTimeout(function () { el.banner.className = 'banner'; }, 4000);
  }
  
  var playPauseTimer = null;
  function showPlayPauseFeedback(isPlaying) {
    if (playPauseTimer) { clearTimeout(playPauseTimer); }
    el.iconPlay.style.display = isPlaying ? 'block' : 'none';
    el.iconPause.style.display = isPlaying ? 'none' : 'block';
    
    el.playPauseFeedback.className = 'play-pause-feedback pop';
    playPauseTimer = setTimeout(function () {
      el.playPauseFeedback.className = 'play-pause-feedback';
    }, 500);
  }

  function hideBanner() { el.banner.className = 'banner'; }

  var skipTimer = null;
  function showSkipFeedback(forward) {
    clearTimeout(skipTimer);
    if (forward) {
      el.skipRight.className = 'skip-feedback right is-visible';
      el.skipLeft.className = 'skip-feedback left';
    } else {
      el.skipLeft.className = 'skip-feedback left is-visible';
      el.skipRight.className = 'skip-feedback right';
    }
    skipTimer = setTimeout(function() {
      el.skipRight.className = 'skip-feedback right';
      el.skipLeft.className = 'skip-feedback left';
    }, 700);
  }

  function showError(message) {
    el.prepare.className = 'prepare';
    el.playerErrorText.innerHTML = escape(message);
    el.playerError.className = 'player-error is-visible';
    errorIndex = 0;
    applyFocus();
  }

  function hideError() { el.playerError.className = 'player-error'; }

  function errorVisible() {
    return el.playerError.className.indexOf('is-visible') >= 0;
  }

  function onKey(event) {
    var code = event.keyCode;
    if (view === 'player') { onPlayerKey(code, event); return; }
    if (view === 'manual') { onManualKey(code, event); return; }
    if (view === 'about') { onAboutKey(code, event); return; }
    if (view === 'tracks') { onTracksKey(code, event); return; }
    onSearchKey(code, event);
  }

  function onSearchKey(code, event) {
    if (code === KEY.LEFT || code === KEY.RIGHT) {
      var step = code === KEY.RIGHT ? 1 : -1;
      if (zone === 'results') {
        cardIndex = clamp(cardIndex + step, 0, candidates.length - 1);
      } else {
        actionIndex = clamp(actionIndex + step, 0, 2);
      }
      applyFocus();
      event.preventDefault();
    } else if (code === KEY.UP || code === KEY.DOWN) {
      if (candidates.length) {
        zone = code === KEY.UP ? 'results' : 'actions';
        applyFocus();
      }
      event.preventDefault();
    } else if (code === KEY.ENTER) {
      if (zone === 'results' && candidates[cardIndex]) {
        openPlayer(candidates[cardIndex]);
      } else if (actionIndex === 0) {
        startSearch();
      } else if (actionIndex === 1) {
        showView('manual');
      } else {
        showView('about');
      }
      event.preventDefault();
    } else if (code === KEY.BACK || code === KEY.ESC) {
      // En la pantalla inicial, ATRÁS cierra la app: es lo que espera
      // cualquiera que use un televisor.
      if (window.webOS && window.webOS.platformBack) {
        window.webOS.platformBack();
      } else {
        window.close();
      }
    }
  }

  function onManualKey(code, event) {
    if (code === KEY.BACK || code === KEY.ESC) {
      showView('search');
      event.preventDefault();
      return;
    }
    if (code === KEY.ENTER && manualIndex === 0) {
      // Con el foco en el campo, OK abre el teclado del televisor; solo
      // interceptamos si ya hay algo escrito.
      if (el.manualInput.value) { connectManual(); event.preventDefault(); }
      return;
    }
    if (code === KEY.UP || code === KEY.DOWN) {
      manualIndex = clamp(manualIndex + (code === KEY.DOWN ? 1 : -1), 0, 2);
      applyFocus();
      event.preventDefault();
    } else if (code === KEY.LEFT || code === KEY.RIGHT) {
      if (manualIndex > 0) {
        manualIndex = clamp(manualIndex + (code === KEY.RIGHT ? 1 : -1), 1, 2);
        applyFocus();
        event.preventDefault();
      }
    } else if (code === KEY.ENTER) {
      if (manualIndex === 1) { connectManual(); } else { showView('search'); }
      event.preventDefault();
    }
  }

  function onAboutKey(code, event) {
    if (code === KEY.BACK || code === KEY.ESC || code === KEY.ENTER) {
      showView('search');
      event.preventDefault();
    }
  }

  function onTracksKey(code, event) {
    if (code === KEY.BACK || code === KEY.ESC) {
      showView('player');
      event.preventDefault();
      return;
    }
    var listLen = tracksCol === 0 ? cachedSubs.length : cachedAudio.length;
    if (code === KEY.UP || code === KEY.DOWN) {
      if (listLen > 0) {
        var step = code === KEY.DOWN ? 1 : -1;
        tracksRow[tracksCol] = clamp(tracksRow[tracksCol] + step, 0, listLen - 1);
        applyFocus();
      }
      event.preventDefault();
    } else if (code === KEY.LEFT || code === KEY.RIGHT) {
      tracksCol = code === KEY.RIGHT ? 1 : 0;
      applyFocus();
      event.preventDefault();
    } else if (code === KEY.ENTER) {
      var trackId = tracksCol === 0 ? cachedSubs[tracksRow[0]].id : cachedAudio[tracksRow[1]].id;
      if (tracksCol === 0) {
        player.setTextTrack(trackId);
      } else {
        player.setAudioTrack(trackId);
      }
      openTracks(); 
      event.preventDefault();
    }
  }

  function onPlayerKey(code, event) {
    if (errorVisible()) {
      if (code === KEY.LEFT || code === KEY.RIGHT) {
        errorIndex = clamp(errorIndex + (code === KEY.RIGHT ? 1 : -1), 0, 1);
        applyFocus();
      } else if (code === KEY.ENTER) {
        if (errorIndex === 0) { hideError(); if (player) { player.retry(); } }
        else { leavePlayer(); }
      } else if (code === KEY.BACK || code === KEY.ESC) {
        leavePlayer();
      }
      event.preventDefault();
      return;
    }

    switch (code) {
      case KEY.ENTER:
      case KEY.PLAYPAUSE:
        if (player) { player.playPause(); }
        showControls();
        break;
      case KEY.PLAY:
        el.video.play();
        showControls();
        break;
      case KEY.PAUSE:
        el.video.pause();
        showControls();
        break;
      case KEY.LEFT:
      case KEY.RW:
        if (player) { player.seekBy(-FluxConfig.seekStepSeconds); }
        showSkipFeedback(false);
        showControls();
        break;
      case KEY.RIGHT:
      case KEY.FF:
        if (player) { player.seekBy(FluxConfig.seekStepSeconds); }
        showSkipFeedback(true);
        showControls();
        break;
      case KEY.UP:
        if (el.controls && el.controls.className.indexOf('is-visible') >= 0) {
          openTracks();
        } else {
          if (player) { player.seekBy(FluxConfig.bigSeekStepSeconds); }
          showControls();
        }
        break;
      case KEY.DOWN:
        if (player) { player.seekBy(-FluxConfig.bigSeekStepSeconds); }
        showControls();
        break;
      case KEY.STOP:
      case KEY.BACK:
      case KEY.ESC:
        leavePlayer();
        break;
      default:
        toggleControls();
        return;
    }
    event.preventDefault();
  }

  function applyFocus() {
    var target = null;
    if (view === 'search') {
      if (zone === 'results' && candidates.length) {
        target = el.results.childNodes[clamp(cardIndex, 0, candidates.length - 1)];
      } else {
        target = [el.btnSearch, el.btnManual, el.btnAbout][actionIndex];
      }
    } else if (view === 'manual') {
      target = [el.manualInput, el.btnConnect, el.btnManualBack][manualIndex];
    } else if (view === 'about') {
      target = el.btnAboutBack;
    } else if (view === 'player' && errorVisible()) {
      target = errorIndex === 0 ? el.btnRetry : el.btnPlayerBack;
    } else if (view === 'tracks') {
      var list = tracksCol === 0 ? el.listSubtitles : el.listAudio;
      if (list && list.childNodes.length > tracksRow[tracksCol]) {
        target = list.childNodes[tracksRow[tracksCol]];
      }
    }
    if (target && target.focus) {
      try { target.focus(); } catch (e) {  }
    }
  }

  function clamp(value, min, max) {
    if (value < min) { return min; }
    if (value > max) { return max; }
    return value;
  }

  var formatTime = FluxUtils.formatTime;
  var formatSize = FluxUtils.formatSize;
  var escape = FluxUtils.escape;

  if (document.readyState === 'complete' || document.readyState === 'interactive') {
    setTimeout(init, 0);
  } else {
    document.addEventListener('DOMContentLoaded', init, false);
  }
}());
