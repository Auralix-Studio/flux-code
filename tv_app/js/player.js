
/**
 * Equivalente webOS de:
 *   lib/features/player/data/player_controller.dart    (reproducción, reconexión)
 *   lib/features/player/data/progress_store.dart       (persistencia de progreso)
 *
 * Estas implementaciones deben mantenerse en sincronía en cuanto al protocolo
 * (lógica de reconexión, guardado de progreso, fingerprint). Si cambias uno,
 * revisa el otro.
 */
function FluxPlayer(video, handlers) {
  'use strict';

  var self = this;
  var candidate = null;
  var lastFingerprint = null;
  var resumeAt = 0;
  var attempt = 0;
  var generation = 0;

  var watchTimer = null;
  var stallTimer = null;
  var reconnectTimer = null;
  var misses = 0;
  var lost = false;
  var checking = false;
  var following = true;
  var preparing = false;
  var destroyed = false;
  var lastProgressAt = Date.now();

  var seekDebounceTimer = null;
  var seekPending = null;
  var seeking = false;
  var _lastSaveAt = 0;

  function emit(name, payload) {
    if (destroyed) { return; }
    if (handlers[name]) { handlers[name](payload); }
  }

  function applyPipelineHints() {
    try {
      var opts = {
        option: {
          
          bufferControl: {
            minBufferTime: 8,       
            maxBufferTime: 30,      
            bufferMaxByte: 48 * 1024 * 1024  
          }
        },
        
        mediaTransportType: 'URI'
      };
      
      if (candidate && candidate.headers) {
        opts.option.httpHeader = candidate.headers;
      }
      
      video.setAttribute('mediaOption', JSON.stringify(opts));
    } catch (e) {
      
    }
  }

  this.load = function (next, options) {
    if (destroyed) { return; }
    var opts = options || {};
    generation++;
    var mine = generation;

    candidate = next;
    attempt = 0;
    misses = 0;
    lost = false;
    preparing = true;
    seeking = false;
    seekPending = null;
    clearTimeout(seekDebounceTimer);
    resumeAt = opts.resumeAt || 0;
    if (resumeAt === 0 && next.fingerprint) {
      resumeAt = _loadProgress(next.fingerprint);
    }
    lastProgressAt = Date.now();
    emit('onPreparing', { candidate: candidate, resuming: resumeAt > 0 });

    applyPipelineHints();
    video.autoplay = false;
    video.preload = 'auto';
    
    var finalUrl = candidate.url;
    if (opts.bustCache && !candidate.isExternal) {
      finalUrl += '?flux=' + Date.now();
    }
    video.src = finalUrl;

    try {
      video.load();
    } catch (e) {  }

    var deadline = Date.now() + 8000;

    (function waitForBuffer() {
      if (destroyed || mine !== generation) { return; }
      if (ready() || Date.now() > deadline) {
        preparing = false;
        if (resumeAt > 0 && video.duration && resumeAt < video.duration) {
          safeSeek(resumeAt);
        }
        emit('onReady', candidate);
        play();
        return;
      }
      setTimeout(waitForBuffer, 200);
    }());
  };

  function ready() {
    if (video.readyState >= 4) { return true; }
    if (video.readyState >= 3) {
      
      var ahead = bufferedAhead();
      return ahead >= 4 || ahead === 0; 
    }
    return false;
  }

  function bufferedAhead() {
    try {
      if (!video.buffered || !video.buffered.length) { return 0; }
      var end = video.buffered.end(video.buffered.length - 1);
      return Math.max(0, end - video.currentTime);
    } catch (e) {
      return 0;
    }
  }
  this.bufferedAhead = bufferedAhead;

  function play() {
    try {
      var promise = video.play();
      if (promise && promise['catch']) {
        promise['catch'](function () {  });
      }
    } catch (e) {  }
  }

  this.playPause = function () {
    if (video.paused) { play(); } else { video.pause(); }
  };

  this.seekBy = function (seconds) {
    if (!video.duration || !isFinite(video.duration)) { return; }
    
    var base = seekPending !== null ? seekPending : video.currentTime;
    var target = base + seconds;
    if (target < 0) { target = 0; }
    if (target > video.duration - 1) { target = video.duration - 1; }

    seekPending = target;
    lastProgressAt = Date.now();
    
    emit('onSeekPreview', target);

    clearTimeout(seekDebounceTimer);
    seekDebounceTimer = setTimeout(function () {
      var finalTarget = seekPending;
      seekPending = null;
      if (finalTarget !== null) {
        safeSeek(finalTarget);
      }
    }, 150);
  };

  this.seekTo = function (seconds) {
    seekPending = null;
    clearTimeout(seekDebounceTimer);
    safeSeek(seconds);
  };

  function safeSeek(seconds) {
    lastProgressAt = Date.now();

    try {
      if (video.seekable && video.seekable.length > 0) {
        
        var start = video.seekable.start(0);
        var end = video.seekable.end(video.seekable.length - 1);
        if (seconds < start) { seconds = start; }
        if (seconds > end) { seconds = end; }
      }
      seeking = true;
      video.currentTime = seconds;
    } catch (e) {
      seeking = false;
      
    }
  }

  this.candidate = function () { return candidate; };
  this.isPreparing = function () { return preparing; };
  this.isFollowing = function () { return following; };

  this.setFollowing = function (value) {
    following = !!value;
    if (following) { startWatching(); } else { stopWatching(); }
  };

  function scheduleReconnect() {
    if (destroyed || preparing) { return; }
    if (attempt >= FluxConfig.maxReconnectAttempts) {
      emit('onFatal', 'Se perdió la conexión con el servidor y no se pudo ' +
        'recuperar tras ' + attempt + ' intentos.');
      return;
    }
    attempt++;
    emit('onReconnecting', attempt);
    var delay = Math.min(FluxConfig.maxBackoffMs, 1000 * Math.pow(2, attempt - 1));
    clearTimeout(reconnectTimer);
    reconnectTimer = setTimeout(reconnectNow, delay);
  }

  function reconnectNow() {
    if (destroyed || !candidate) { return; }
    var mine = generation;
    var saved = video.currentTime || resumeAt;

    try {
      var promise = video.play();
      if (promise && promise.then) {
        promise.then(function () {
          if (destroyed || mine !== generation) { return; }
          lastProgressAt = Date.now();
        })['catch'](function () {
          if (destroyed || mine !== generation) { return; }
          fullReload(saved);
        });
        return;
      }
    } catch (e) {
      
    }
    if (mine !== generation) { return; }
    fullReload(saved);
  }

  function fullReload(savedPosition) {
    self.load(candidate, { resumeAt: savedPosition, bustCache: true });
  }

  this.retry = function () {
    attempt = 0;
    reconnectNow();
  };

  function startWatching() {
    stopWatching();
    if (!following) { return; }
    watchTimer = setInterval(check, FluxConfig.watchInterval);
    stallTimer = setInterval(function () {
      if (destroyed || preparing || video.paused || video.ended) { return; }
      
      if (Date.now() - lastProgressAt > FluxConfig.stallTimeout) {
        emit('onStalled');
        check();
        scheduleReconnect();
      }
    }, 5000);
  }

  function stopWatching() {
    clearInterval(watchTimer);
    clearInterval(stallTimer);
    watchTimer = null;
    stallTimer = null;
  }

  function retune() {
    if (!following || destroyed) { return; }
    clearInterval(watchTimer);
    var interval = (misses > 0 || lost)
      ? FluxConfig.watchRecoveryInterval
      : FluxConfig.watchInterval;
    watchTimer = setInterval(check, interval);
  }

  function check() {
    if (destroyed || checking || !candidate || !following) { return; }
    if (candidate.isExternal) { return; } // No inspeccionamos la red para enlaces externos
    checking = true;

    FluxNet.inspect(
      candidate.host,
      candidate.port,
      function (meta) {
        checking = false;
        if (destroyed) { return; }

        if (!meta) {
          misses++;
          if (misses >= FluxConfig.missesBeforeLost && !lost) {
            lost = true;
            emit('onLost');
          }
          retune();
          return;
        }

        var probe = FluxDiscovery.candidateFrom(meta, candidate.source);
        misses = 0;

        if (lost) {
          lost = false;
          if (probe.fingerprint === candidate.fingerprint) {
            emit('onRestored', candidate);
            reconnectNow();
          } else {
            resumeAt = 0;
            candidate = probe;
            emit('onChanged', candidate);
            fullReload(0);
          }
        } else {
          if (probe.fingerprint !== candidate.fingerprint) {
            resumeAt = 0;
            candidate = probe;
            emit('onChanged', candidate);
            fullReload(0);
          }
        }
        retune();
      }
    );
  }
  this.check = check;

  function _saveProgress() {
    if (!candidate || !video.duration || !isFinite(video.duration)) { return; }
    var key = 'flux.progress.' + candidate.fingerprint;
    var pct = video.currentTime / video.duration;
    try {
      if (pct >= 0.95) {
        localStorage.removeItem(key);
      } else if (video.currentTime > 10) {
        localStorage.setItem(key, String(Math.floor(video.currentTime)));
      }
    } catch (e) {}
  }

  function _loadProgress(fingerprint) {
    try {
      var val = parseInt(localStorage.getItem('flux.progress.' + fingerprint), 10);
      return (val && val > 0) ? val : 0;
    } catch (e) { return 0; }
  }

  function onMeta() {
    if (video.duration && isFinite(video.duration)) {
      var print = 'dur:' + video.duration.toFixed(3);
      if (lastFingerprint === null) { lastFingerprint = print; }
    }
    emit('onMeta', {
      duration: video.duration,
      width: video.videoWidth,
      height: video.videoHeight
    });
  }

  function onTimeUpdate() {
    lastProgressAt = Date.now();
    if (video.currentTime > 0) {
      resumeAt = video.currentTime;
      if (attempt > 0) { attempt = 0; }
      if (Date.now() - _lastSaveAt > 5000 && candidate) {
        _saveProgress();
        _lastSaveAt = Date.now();
      }
    }
    emit('onTime', video.currentTime);
  }

  function onSeeked() {
    seeking = false;
    lastProgressAt = Date.now();
    emit('onTime', video.currentTime);
  }

  function onError() {
    if (destroyed) { return; }
    // Un error es la señal más rápida de que el emisor cambió de archivo:
    // se comprueba en el acto, sin esperar al siguiente ciclo.
    check();
    scheduleReconnect();
  }

  function onBuffer() { emit('onBuffer'); }
  function onWaiting() { emit('onWaiting'); }
  function onPlaying() {
    lastProgressAt = Date.now();
    emit('onPlaying');
    if (FluxConfig.debugEvents) { console.log('video.playing'); }
  }
  function onPausedEvent() { emit('onPaused'); }
  function onEndedEvent() {
    if (destroyed) { return; }
    emit('onEnded');
    check();
  }

  video.addEventListener('loadedmetadata', onMeta, false);
  video.addEventListener('timeupdate', onTimeUpdate, false);
  video.addEventListener('seeked', onSeeked, false);
  video.addEventListener('progress', onBuffer, false);
  video.addEventListener('waiting', onWaiting, false);
  video.addEventListener('playing', onPlaying, false);
  video.addEventListener('pause', onPausedEvent, false);
  video.addEventListener('ended', onEndedEvent, false);
  video.addEventListener('error', onError, false);

  this.getAudioTracks = function () {
    var tracks = [];
    if (video.audioTracks) {
      for (var i = 0; i < video.audioTracks.length; i++) {
        var t = video.audioTracks[i];
        tracks.push({ id: i, label: t.label || t.language || 'Audio ' + (i + 1), enabled: t.enabled });
      }
    }
    return tracks;
  };

  this.setAudioTrack = function (id) {
    if (video.audioTracks) {
      for (var i = 0; i < video.audioTracks.length; i++) {
        video.audioTracks[i].enabled = (i === id);
      }
    }
  };

  this.getTextTracks = function () {
    var tracks = [{ id: -1, label: 'Apagado', enabled: true }];
    var anyEnabled = false;
    if (video.textTracks) {
      for (var i = 0; i < video.textTracks.length; i++) {
        var t = video.textTracks[i];
        var isShowing = (t.mode === 'showing');
        if (isShowing) { anyEnabled = true; }
        tracks.push({ id: i, label: t.label || t.language || 'Subtítulo ' + (i + 1), enabled: isShowing });
      }
    }
    tracks[0].enabled = !anyEnabled;
    return tracks;
  };

  this.setTextTrack = function (id) {
    if (video.textTracks) {
      for (var i = 0; i < video.textTracks.length; i++) {
        video.textTracks[i].mode = (i === id) ? 'showing' : 'disabled';
      }
    }
  };

  this.start = function (initial) {
    self.load(initial, {});
    startWatching();
  };

  this.destroy = function () {
    _saveProgress();
    destroyed = true;
    stopWatching();
    clearTimeout(reconnectTimer);
    clearTimeout(seekDebounceTimer);
    seekPending = null;
    video.removeEventListener('loadedmetadata', onMeta, false);
    video.removeEventListener('timeupdate', onTimeUpdate, false);
    video.removeEventListener('seeked', onSeeked, false);
    video.removeEventListener('progress', onBuffer, false);
    video.removeEventListener('waiting', onWaiting, false);
    video.removeEventListener('playing', onPlaying, false);
    video.removeEventListener('pause', onPausedEvent, false);
    video.removeEventListener('ended', onEndedEvent, false);
    video.removeEventListener('error', onError, false);
    try {
      video.pause();
      video.removeAttribute('src');
      video.load();
    } catch (e) {  }
  };
}
