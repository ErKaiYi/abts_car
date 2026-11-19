import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart' hide AudioTrack;
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/network/api_config.dart';
import '../core/storage/bookmark_store.dart';
import '../core/storage/cache_store.dart';
import '../core/storage/shelf_store.dart';
import '../models/audio_stream.dart';
import '../models/book.dart';
import '../models/chapter.dart';
import '../services/audio_focus.dart';
import '../services/bili_api.dart';
import '../services/device_service.dart';
import '../services/umeng_analytics.dart';

enum CachePlayOutcome { okOffline, okOnline, fileMissing, failed }
enum ShelfPlayOutcome { ok, bookGone, loadFailed }

/// 听书播放器：按"章节"连播 + 断点续播 + 睡眠定时 + 系统媒体会话
class BookPlayer extends ChangeNotifier {
  BookPlayer._();
  static final BookPlayer instance = BookPlayer._();

  final Player _player = Player();
  final BiliApi _api = BiliApi.instance;
  final ShelfStore _shelf = ShelfStore.instance;
  final CacheStore _cache = CacheStore.instance;

  BaseAudioHandler? _audioHandler;
  int _lastStatePush = 0;

  Book? _book;
  List<Chapter> _chapters = [];
  bool _chaptersComplete = true;
  int _index = 0;

  bool _ready = false;
  bool _loading = false;
  bool _loaded = false;
  String? _error;
  String? _playbackUrl;
  BookAudio? _lastAudio;

  final Map<int, ({String url, int ts})> _urlCache = {};
  Timer? _positionTimer;
  Timer? _sleepTimer;
  Duration _sleepRemaining = Duration.zero;

  // ---------- 倍速播放 ----------
  static const speedSteps = <double>[
    0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.25, 2.5, 2.75, 3.0,
  ];
  static const double minRate = 0.5;
  static const double maxRate = 3.0;
  static const _prefRate = 'abts_rate';
  double _rate = 1.0;

  // ---------- 断流重连 ----------
  bool _mediaReady = false;
  int _session = 0;
  Duration _lastPos = Duration.zero;
  DateTime _lastPosAt = DateTime.now();
  bool _reconnecting = false;
  bool _stopping = false;

  bool _stopAtChapterEnd = false;
  bool _markingDone = false;

  final ValueNotifier<Duration> positionTick = ValueNotifier(Duration.zero);

  bool _pausedByInterruption = false;

  /// 允许后台/媒体键自动续播（改为默认 true，解决车机按键无效问题）
  bool _playAllowed = true;

  static const double _duckedVolume = 0.05;
  bool _ducking = false;
  double _volumeBeforeDuck = 1.0;

  // ---------- 自定义快进快退与按键模式 ----------
  static const _prefSeekSeconds = 'abts_seek_seconds';
  static const _prefPauseRewindSeconds = 'abts_pause_rewind_seconds'; 
  static const _prefPrevNextMode = 'abts_prev_next_mode'; 
  static const _prefPauseRewind = 'abts_pause_rewind';

  int _customSeekSeconds = 15; 
  int _pauseRewindSeconds = 3; 
  int _prevNextMode = 0; 
  bool _pauseRewindEnabled = true; 

  // 记录在暂停时，下次播放需要跳转到哪里
  Duration? _pendingResumeSeek;

  int get customSeekSeconds => _customSeekSeconds;
  int get pauseRewindSeconds => _pauseRewindSeconds;
  int get prevNextMode => _prevNextMode;
  bool get pauseRewindEnabled => _pauseRewindEnabled;

  Player get player => _player;
  Book? get book => _book;
  List<Chapter> get chapters => _chapters;
  int get index => _index;
  bool get loading => _loading;
  bool get loaded => _loaded;
  String? get error => _error;
  String? get playbackUrl => _playbackUrl;
  BookAudio? get lastAudio => _lastAudio;
  Duration get sleepRemaining => _sleepRemaining;
  double get rate => _rate;
  bool get stopAtChapterEnd => _stopAtChapterEnd;
  bool _isOffline = false;
  bool get isOffline => _isOffline;

  bool get currentCached {
    final b = _book?.bvid;
    final c = currentChapter?.cid;
    if (b == null || c == null || c == 0) return false;
    return _cache.isCached(b, c);
  }

  Future<String?> _cachedPathOf(String? bvid, int cid) async {
    if (bvid == null || bvid.isEmpty || cid == 0) return null;
    if (!_cache.isCached(bvid, cid)) return null;
    return _cache.cacheFilePath(bvid, cid);
  }

  String get rateLabel {
    final r = _rate;
    return '${r % 1 == 0 ? r.toStringAsFixed(1) : r.toStringAsFixed(2).replaceAll(RegExp(r'0$'), '')}x';
  }

  Future<void> loadPlaybackSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _customSeekSeconds = prefs.getInt(_prefSeekSeconds) ?? 15;
      _pauseRewindSeconds = prefs.getInt(_prefPauseRewindSeconds) ?? 3;
      _prevNextMode = prefs.getInt(_prefPrevNextMode) ?? 0;
      _pauseRewindEnabled = prefs.getBool(_prefPauseRewind) ?? true;
      notifyListeners();
    } catch (e) {
      debugPrint('[BookPlayer] load playback settings failed: $e');
    }
  }

  Future<void> setPrevNextMode(int mode) async {
    _prevNextMode = mode;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_prefPrevNextMode, mode);
    } catch (_) {}
    notifyListeners();
  }

  Future<void> setCustomSeekSeconds(int seconds) async {
    _customSeekSeconds = seconds.clamp(5, 120);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_prefSeekSeconds, _customSeekSeconds);
    } catch (_) {}
    notifyListeners();
  }

  Future<void> setPauseRewindSeconds(int seconds) async {
    _pauseRewindSeconds = seconds.clamp(1, 60);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_prefPauseRewindSeconds, _pauseRewindSeconds);
    } catch (_) {}
    notifyListeners();
  }

  Future<void> setPauseRewindEnabled(bool enabled) async {
    _pauseRewindEnabled = enabled;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefPauseRewind, enabled);
    } catch (_) {}
    notifyListeners();
  }

  Future<void> loadRate() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final v = prefs.getDouble(_prefRate);
      if (v != null && v >= 0.5 && v <= 3.0) {
        _rate = v;
        await _player.setRate(v);
      }
    } catch (e) {
      debugPrint('[BookPlayer] load rate failed: $e');
    }
  }

  Future<void> setRate(double v) async {
    _rate = v.clamp(0.5, 3.0);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_prefRate, _rate);
    } catch (_) {}
    await _player.setRate(_rate);
    _pushState(force: true);
    notifyListeners();
  }

  Future<void> cycleSpeed() async {
    final idx = speedSteps.indexWhere((e) => (e - _rate).abs() < 0.001);
    final next = speedSteps[(idx + 1) % speedSteps.length];
    await setRate(next);
  }

  // ---------- 音量 ----------
  static const double maxVolumePct = 2.0;
  static const _prefVolume = 'abts_volume';
  double _volumePct = 1.0;
  bool _volumeMaxRaised = false;

  double get volumePct => _volumePct;

  Future<void> loadVolume() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final v = prefs.getDouble(_prefVolume);
      if (v != null && v >= 0 && v <= maxVolumePct) _volumePct = v;
    } catch (e) {
      debugPrint('[BookPlayer] load volume failed: $e');
    }
    await _applyVolume();
  }

  Future<void> setVolumePct(double v) async {
    _volumePct = v.clamp(0.0, maxVolumePct);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_prefVolume, _volumePct);
    } catch (_) {}
    await _applyVolume();
    notifyListeners();
  }

  Future<void> _applyVolume() async {
    try {
      if (_volumePct > 1.0) await _ensureVolumeMax();
      if (_ducking) return;
      await _player.setVolume(_volumePct * 100);
    } catch (e) {
      debugPrint('[BookPlayer] apply volume failed: $e');
    }
  }

  Future<void> _ensureVolumeMax() async {
    if (_volumeMaxRaised) return;
    try {
      final p = _player.platform;
      if (p is NativePlayer) {
        await p.setProperty('volume-max', '${(maxVolumePct * 100).round()}');
        _volumeMaxRaised = true;
      }
    } catch (e) {
      debugPrint('[BookPlayer] set volume-max failed: $e');
    }
  }

  void setStopAtChapterEnd(bool v) {
    _stopAtChapterEnd = v;
    notifyListeners();
  }

  Chapter? get currentChapter =>
      _chapters.isNotEmpty && _index < _chapters.length
          ? _chapters[_index]
          : null;

  bool get hasNext => _index < _chapters.length - 1;
  bool get hasPrev => _index > 0;

  void attachHandler(BaseAudioHandler h) {
    _audioHandler = h;
  }

  // ================= 日志监控绝杀区 =================
  Process? _logcatProcess;
  bool _bydLogListening = false;

  void _startBydLogListener() {
    if (_bydLogListening || !Platform.isAndroid) return;
    _bydLogListening = true;

    unawaited(() async {
      try {
        // 执行底层的 logcat 命令，监听比亚迪系统(MediaCenterReceiver)的按键日志
        _logcatProcess = await Process.start('logcat', [
          '-v', 'time',
          '-s', 'MediaCenterReceiver:D', '*:S'
        ]);

        _logcatProcess!.stdout
            .transform(const SystemEncoding().decoder)
            .listen((data) {
          if (data.contains('action=ACTION_UP')) {
            // 排除掉上一曲/下一曲，只抓播放/暂停
            if (data.contains('KEYCODE_MEDIA_PLAY_PAUSE') ||
                data.contains('KEYCODE_MEDIA_PLAY') ||
                data.contains('KEYCODE_MEDIA_PAUSE') ||
                data.contains('KEYCODE_HEADSETHOOK')) {
              
              debugPrint('[BYD_LOG] 捕获到物理按键日志，触发播放/暂停！');
              togglePlay();
            }
          }
        });

        debugPrint('[BYD_LOG] 监听器已启动');
      } catch (e) {
        debugPrint('[BYD_LOG] 监听启动失败: $e');
        _bydLogListening = false;
      }
    }());
  }
  // ==================================================

  void setup() {
    if (_ready) return;
    _ready = true;
    
    unawaited(loadRate());
    unawaited(loadVolume());
    unawaited(loadPlaybackSettings()); 
    
    // 【开启绝杀监听】
    _startBydLogListener();
    
    _player.stream.completed.listen((_) async {
      if (_loading || !_loaded) return;
      final dur = currentDuration;
      if (dur > Duration.zero &&
          currentPosition < dur - const Duration(seconds: 3)) {
        return;
      }
      flushProgress();
      _markCurrentDone();
      if (_stopAtChapterEnd) {
        _error = null;
        await _rewindTail();
        await pause();
        _advanceSavedProgress();
        notifyListeners();
        return;
      }
      if (hasNext) {
        await next();
      } else {
        _error = null;
        await _rewindTail();
        await pause();
        notifyListeners();
      }
    });
    _player.stream.error.listen((e) async {
      if (_reconnecting) return;
      _loading = false;
      if (_loaded) {
        final ok = await _reconnect();
        if (ok) return;
      }
      _error = '播放失败，请稍后重试';
      notifyListeners();
    });
    _player.stream.position.listen((p) {
      positionTick.value = p;
      _tickSave();
      _pushState();
      _tallyPlayTime();
      _markDoneIfReached(p);
    });
    _player.stream.playing.listen((_) {
      _lastPos = currentPosition;
      _lastPosAt = DateTime.now();
      _pushState(force: true);
      notifyListeners();
    });
    _player.stream.buffering.listen((_) {
      _pushState();
      notifyListeners();
    });
    _player.stream.duration.listen((_) {
      _pushState(force: true);
      notifyListeners();
    });

    Timer.periodic(const Duration(seconds: 5), (_) {
      if (_reconnecting || !_loaded) return;
      if (!_player.state.playing) {
        _lastPosAt = DateTime.now();
        return;
      }
      final pos = currentPosition;
      if (pos != _lastPos) {
        _lastPos = pos;
        _lastPosAt = DateTime.now();
        return;
      }
      if (DateTime.now().difference(_lastPosAt) > const Duration(seconds: 40)) {
        unawaited(_reconnect());
      }
    });

    Timer.periodic(const Duration(seconds: 2), (_) {
      final h = _audioHandler;
      if (h == null) return;
      final actual = _player.state.playing;
      final remote = h.playbackState.value;
      if (remote.playing == actual) return;
      _pushState(force: true);
    });

    AudioFocus.instance
      ..onFocusInterrupted = () {
        unawaited(_pauseForInterruption());
      }
      ..onFocusDucked = () {
        unawaited(_duckVolume());
      }
      ..onFocusLost = () {
        _pausedByInterruption = false;
        unawaited(pause());
      }
      ..onFocusGained = () {
        unawaited(_restoreAfterFocusGain());
      }
      ..onNoisy = () {
        unawaited(pause());
      }
      ..start();

    DeviceService.instance.bindScreenEvents(
      onScreenOff: () => unawaited(handleScreenOff()),
      onScreenOn: () {},
    );
  }

  void markUiVisible() {
    _playAllowed = true;
  }

  Future<void> handleScreenOff() async {
    _playAllowed = false;
    _pausedByInterruption = false;
    if (_player.state.playing) {
      await pause();
    } else {
      flushProgress();
    }
  }

  Future<bool> _reconnect({int? keepMs}) async {
    if (_reconnecting) return false;
    _reconnecting = true;
    final mySession = _session;
    final resumeMs = keepMs ?? currentPosition.inMilliseconds;
    try {
      final chapter = currentChapter;
      if (chapter == null) return false;
      _playbackUrl = null;
      _loading = true;
      notifyListeners();

      final local = await _cachedPathOf(_book?.bvid, chapter.cid);
      if (local != null) {
        try {
          await _player.open(Media(local));
          if (mySession != _session) {
            await _player.stop();
            return false;
          }
          if (_rate != 1.0) await _player.setRate(_rate);
          await _seekToResume(resumeMs);
          _isOffline = true;
          _mediaReady = true;
          _error = null;
          _loading = false;
          _lastPos = currentPosition;
          _lastPosAt = DateTime.now();
          unawaited(AudioFocus.instance.request());
          _pushState(force: true);
          notifyListeners();
          return true;
        } catch (e) {
          await _cache.dropIfBroken(_book?.bvid ?? '', chapter.cid);
        }
      }

      _urlCache.remove(chapter.cid);
      final candidates = await _fetchStreamCandidates(chapter.cid);
      if (candidates.isEmpty) return false;

      var opened = false;
      for (final url in candidates) {
        try {
          await _player.open(Media(url, httpHeaders: _streamHeaders()),
              play: false);
          if (mySession != _session) {
            await _player.stop();
            return false;
          }
          if (_rate != 1.0) await _player.setRate(_rate);
          await _seekToResume(resumeMs);
          opened = true;
          _playbackUrl = url;
          break;
        } catch (e) {
          await _player.stop();
        }
      }
      if (!opened) return false;

      _error = null;
      _loading = false;
      _mediaReady = true;
      _lastPos = currentPosition;
      _lastPosAt = DateTime.now();
      unawaited(AudioFocus.instance.request());
      _pushState(force: true);
      notifyListeners();
      return true;
    } catch (e) {
      return false;
    } finally {
      _reconnecting = false;
      _loading = false;
    }
  }

  void _advanceSavedProgress() {
    final book = _book;
    if (book == null || !hasNext) return;
    if (!_shelf.isOnShelf(book.bvid)) return;
    final nextIndex = _index + 1;
    if (nextIndex < 0 || nextIndex >= _chapters.length) return;
    final nextChapter = _chapters[nextIndex];
    unawaited(_shelf.updateProgress(
      book.bvid,
      cid: nextChapter.cid,
      chapterIndex: nextIndex,
      positionMs: 0,
      chapterDurationMs: nextChapter.duration * 1000,
    ));
  }

  Future<void> _rewindTail({int seconds = 15}) async {
    try {
      final pos = currentPosition;
      if (pos <= Duration.zero) return;
      final back = pos - Duration(seconds: seconds);
      await _player.seek(back < Duration.zero ? Duration.zero : back);
      positionTick.value = currentPosition;
    } catch (e) {
      debugPrint('[BookPlayer] 回退片尾失败: $e');
    }
  }

  Future<void> _pauseForInterruption() async {
    if (!_player.state.playing) return;
    _pausedByInterruption = true;
    await _player.pause();
    _pushState(force: true);
    flushProgress();
  }

  Future<void> _duckVolume() async {
    if (_ducking || !_player.state.playing) return;
    final v = _player.state.volume;
    if (v <= _duckedVolume) return;
    _ducking = true;
    _volumeBeforeDuck = v;
    await _player.setVolume(v * 0.3);
  }

  Future<void> _restoreVolumeIfDucked() async {
    if (!_ducking) return;
    _ducking = false;
    if (_volumeBeforeDuck > 0) {
      await _player.setVolume(_volumeBeforeDuck);
    }
  }

  Future<void> _restoreAfterFocusGain() async {
    await _restoreVolumeIfDucked();
    if (!_playAllowed) {
      _pausedByInterruption = false;
      return;
    }
    if (!_pausedByInterruption) return;
    _pausedByInterruption = false;
    await resume();
  }

  Duration _playTally = Duration.zero;
  Book? _playTallyBook;
  bool _autoShelved = false;
  bool _notificationAsked = false;

  void _ensureNotificationPermission() {
    if (_notificationAsked || !Platform.isAndroid) return;
    _notificationAsked = true;
    unawaited(() async {
      try {
        await Permission.notification.request();
      } catch (_) {}
    }());
  }

  Future<bool> playBook(Book book, {int resumeIndex = 0, int resumeMs = 0}) async {
    _ensureNotificationPermission();
    List<Chapter> chapters;
    if (_book?.bvid == book.bvid && _chapters.isNotEmpty) {
      chapters = _chapters;
    } else {
      chapters = book.chapters ?? await _api.pageList(book.bvid);
    }

    if (chapters.isEmpty) {
      _error = '这本书没有可播放的分P';
      _book = book;
      _loaded = false;
      notifyListeners();
      return false;
    }

    if (_playTallyBook?.bvid != book.bvid) {
      _playTally = Duration.zero;
      _playTallyBook = book;
      _autoShelved = false;
    }

    final idx = resumeIndex >= 0 && resumeIndex < chapters.length
        ? resumeIndex
        : 0;
    return _loadTarget(idx,
        resumeMs: resumeMs, newBook: book, newChapters: chapters);
  }

  Future<ShelfPlayOutcome> playBookWithFallback(ShelfBook sb) async {
    _ensureNotificationPermission();
    final book = sb.book;
    var chapters = const <Chapter>[];
    var networkOk = false;
    try {
      if (_book?.bvid == book.bvid && _chapters.isNotEmpty) {
        chapters = _chapters;
        networkOk = true;
      } else if (book.chapters != null && book.chapters!.isNotEmpty) {
        chapters = book.chapters!;
        networkOk = true;
      } else {
        chapters = await _api.pageList(book.bvid);
        networkOk = true;
      }
    } catch (_) {
      networkOk = false;
    }

    if (chapters.isNotEmpty) {
      final idx = sb.lastChapterIndex >= 0 && sb.lastChapterIndex < chapters.length
          ? sb.lastChapterIndex
          : 0;
      final ok = await _loadTarget(idx,
          resumeMs: sb.positionMs, newBook: book, newChapters: chapters);
      if (ok) return ShelfPlayOutcome.ok;
    }

    final cached = _cache.chaptersOf(book.bvid);
    if (cached.isNotEmpty) {
      final ordered = <Chapter>[
        ...cached.where((c) => c.cid == sb.lastCid),
        ...cached.where((c) => c.cid != sb.lastCid),
      ];
      for (final c in ordered) {
        final r = await playCachedEntry(book.bvid, c.cid, book);
        if (r == CachePlayOutcome.okOffline || r == CachePlayOutcome.okOnline) {
          return ShelfPlayOutcome.ok;
        }
        if (r == CachePlayOutcome.failed) return ShelfPlayOutcome.loadFailed;
      }
      return ShelfPlayOutcome.loadFailed;
    }

    _book = book;
    _chapters = const [];
    _loaded = false;
    _error = networkOk ? '作品已下架或无法播放' : '网络不可用，且没有离线缓存';
    notifyListeners();
    return networkOk ? ShelfPlayOutcome.bookGone : ShelfPlayOutcome.loadFailed;
  }

  Future<bool> resumeShelf(ShelfBook sb) async {
    return playBook(
      sb.book,
      resumeIndex: sb.lastChapterIndex,
      resumeMs: sb.positionMs,
    );
  }

  Future<void> playChapterIndex(int index, {int offsetMs = 0}) async {
    if (_chapters.isEmpty || index < 0 || index >= _chapters.length) return;
    await _loadTarget(index, resumeMs: offsetMs);
  }

  Future<bool> _loadTarget(
    int index, {
    int resumeMs = 0,
    Book? newBook,
    List<Chapter>? newChapters,
    bool chaptersComplete = true,
  }) async {
    final prevBook = _book;
    final prevChapters = _chapters;
    final prevIndex = _index;
    final prevLoaded = _loaded;
    final prevUrl = _playbackUrl;
    final prevAudio = _lastAudio;
    final prevOffline = _isOffline;

    if (newBook != null) _book = newBook;
    if (newChapters != null) {
      _chapters = newChapters;
      _chaptersComplete = chaptersComplete;
    }
    _loading = true;
    _error = null;
    notifyListeners();

    var ok = false;
    try {
      if (_chapters.isEmpty || index < 0 || index >= _chapters.length) {
        throw StateError('章节索引越界：$index');
      }
      final chapter = _chapters[index];
      final curBvid = _book?.bvid;
      final localPath = await _cachedPathOf(curBvid, chapter.cid);

      if (localPath != null) {
        var opened = false;
        try {
          await _player.open(Media(localPath));
          opened = true;
        } catch (e) {
          await Future<void>.delayed(const Duration(milliseconds: 350));
          try {
            await _player.open(Media(localPath));
            opened = true;
          } catch (e2) {}
        }
        if (opened) {
          try {
            if (_rate != 1.0) await _player.setRate(_rate);
            if (resumeMs > 0) await _seekToResume(resumeMs);
          } catch (e) {}
          ok = true;
          _playbackUrl = null;
          _mediaReady = true;
          _isOffline = true;
          _pausedByInterruption = false;
        } else {
          await _cache.dropIfBroken(curBvid ?? '', chapter.cid);
        }
      }

      if (!ok) {
        final candidates = await _fetchStreamCandidates(chapter.cid);
        if (candidates.isEmpty) {
          throw StateError('获取音频链接失败（章节可能无法播放）');
        }

        for (var i = 0; i < candidates.length; i++) {
          final url = candidates[i];
          try {
            await _player.open(Media(url, httpHeaders: _streamHeaders()),
                play: resumeMs <= 0);
            if (_rate != 1.0) await _player.setRate(_rate);
            if (resumeMs > 0) {
              await _seekToResume(resumeMs);
            }
            if (_error != null) _error = null;
            ok = true;
            _playbackUrl = url;
            _mediaReady = true;
            _isOffline = false;
            _pausedByInterruption = false;
            break;
          } catch (e) {
            if (i < candidates.length - 1) {
              await _player.stop();
            }
          }
        }
      }

      if (!ok) {
        throw StateError('无法播放该章节');
      }
      unawaited(AudioFocus.instance.request());
      _index = index;
      _loaded = true;
      AppAnalytics.onEvent('play_start');
    } catch (e) {
      _error = '播放失败，请稍后重试';
    } finally {
      if (!ok) {
        _book = prevBook;
        _chapters = prevChapters;
        _index = prevIndex;
        _loaded = prevLoaded;
        _playbackUrl = prevUrl;
        _lastAudio = prevAudio;
        _isOffline = prevOffline;
        _mediaReady = false;
      }
      _loading = false;
      _pushNowPlaying();
      notifyListeners();
    }
    return ok;
  }

  Future<void> _seekToResume(int resumeMs) async {
    final target = Duration(milliseconds: resumeMs);
    await _waitForDuration();
    await _player.seek(target);
    await _player.play();
    await Future<void>.delayed(const Duration(milliseconds: 600));
    final off = (_player.state.position - target).inMilliseconds.abs();
    if (off > 5000) {
      await _player.seek(target);
    }
  }

  Future<void> _waitForDuration() async {
    if (_player.state.duration > Duration.zero) return;
    try {
      await _player.stream.duration
          .firstWhere((d) => d > Duration.zero)
          .timeout(const Duration(seconds: 4));
    } catch (_) {}
  }

  Map<String, String> _streamHeaders() => const {
        'User-Agent': BiliEndpoints.userAgent,
        'Referer': BiliEndpoints.home,
      };

  Future<List<String>> _fetchStreamCandidates(int cid) async {
    final cached = _urlCache[cid];
    if (cached != null) {
      final ageMs = DateTime.now().millisecondsSinceEpoch - cached.ts;
      if (ageMs < 90 * 60 * 1000) return [cached.url];
    }
    final audio = await _api.playUrl(_book!.bvid, cid);
    _lastAudio = audio;

    final list = <String>[];
    void add(AudioTrack? t) {
      if (t == null) return;
      String toHttps(String u) =>
          u.startsWith('http://') ? 'https://${u.substring(7)}' : u;
      if (t.baseUrl.isNotEmpty) list.add(toHttps(t.baseUrl));
      for (final b in t.backupUrls) {
        if (b.isNotEmpty) list.add(toHttps(b));
      }
    }

    final aac = [...audio.tracks]..sort((a, b) => b.bandwidth.compareTo(a.bandwidth));
    for (final t in aac) {
      add(t);
    }
    add(audio.flac);
    add(audio.dolby);

    final uniq = list.toSet().toList();
    if (uniq.isNotEmpty) {
      _urlCache[cid] =
          (url: uniq.first, ts: DateTime.now().millisecondsSinceEpoch);
      if (_urlCache.length > 6) {
        final eldest = _urlCache.keys.first;
        _urlCache.remove(eldest);
      }
    }
    return uniq;
  }

  void _pushNowPlaying() {
    final h = _audioHandler;
    if (h == null) return;
    final chapter = currentChapter;
    if (chapter == null || _book == null) return;
    final dur = currentDuration;
    final pic = Book.normalizePic(_book!.pic);
    h.mediaItem.add(
      MediaItem(
        id: '${_book!.bvid}/${chapter.cid}',
        title: '第 ${chapter.page} 章 · ${chapter.part}',
        artist: _book!.cleanTitle,
        album: _book!.cleanTitle,
        artUri: pic.isEmpty ? null : Uri.tryParse(pic),
        duration:
            dur > Duration.zero ? dur : Duration(seconds: chapter.duration),
      ),
    );
    _pushState(force: true);
  }

  void _pushState({bool force = false}) {
    final h = _audioHandler;
    if (h == null) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (!force && now - _lastStatePush < 500) return;
    _lastStatePush = now;

    final playing = _player.state.playing;
    final pos = currentPosition;
    final buffered = _player.state.buffer;
    final buf = buffered > pos ? buffered : pos;

    final processing = _loading
        ? AudioProcessingState.buffering
        : _error != null
            ? AudioProcessingState.error
            : _loaded
                ? AudioProcessingState.ready
                : AudioProcessingState.idle;

    h.playbackState.add(
      PlaybackState(
        controls: [
          MediaControl.skipToPrevious,
          MediaControl.rewind,
          playing ? MediaControl.pause : MediaControl.play,
          MediaControl.fastForward,
          MediaControl.skipToNext,
        ],
        systemActions: {
          MediaAction.seek,
          MediaAction.seekForward,
          MediaAction.seekBackward,
          MediaAction.play,
          MediaAction.pause,
          MediaAction.stop,
        },
        androidCompactActionIndices: const [0, 1, 2],
        processingState: processing,
        playing: playing,
        updatePosition: pos,
        bufferedPosition: buf,
      ),
    );
  }

  void togglePlay() {
    final willPlay = !_player.state.playing;
    _pausedByInterruption = false;
    if (willPlay) {
      unawaited(resume());
    } else {
      unawaited(pause());
    }
    _pushState(force: true);
  }

  Future<void> resume() async {
    _pausedByInterruption = false;
    await _restoreVolumeIfDucked();
    
    if (_loaded && !_mediaReady && !_reconnecting) {
      final ok = await _reconnect();
      if (ok) return;
    }

    // 先让播放器继续播放（瞬间出声，解决卡顿问题）
    await _player.play();
    unawaited(AudioFocus.instance.request());
    
    // 然后再在后台悄悄执行跳转，实现丝滑回退
    if (_pendingResumeSeek != null) {
      final target = _pendingResumeSeek!;
      _pendingResumeSeek = null;
      unawaited(_player.seek(target));
    }

    _pushState(force: true);
  }

  /// 媒体会话（车机语音 / 方向盘 / 蓝牙按键）发起的「播放」
  Future<bool> resumeFromMediaCommand() async {
    if (_loaded) {
      await resume();
      return true;
    }
    
    final current = _book;
    if (current != null && _chapters.isNotEmpty) {
      final saved = _shelf.byBvid(current.bvid);
      final rawIdx = saved?.lastChapterIndex ?? _index;
      final idx = rawIdx.clamp(0, _chapters.length - 1).toInt();
      final ok = await playBook(
        current,
        resumeIndex: idx,
        resumeMs: saved?.positionMs ?? 0,
      );
      if (ok) return true;
    }

    for (final b in _shelf.books) {
      if (!b.hasProgress) continue;
      final outcome = await playBookWithFallback(b);
      if (outcome == ShelfPlayOutcome.ok) return true;
    }
    return false;
  }

  Future<void> pause() async {
    _pausedByInterruption = false;
    // 暂停时记录下来该回退到哪里，不要立刻 seek，否则会卡死引擎
    if (_pauseRewindEnabled && _pauseRewindSeconds > 0) {
      final currentPos = currentPosition;
      final targetPos = currentPos - Duration(seconds: _pauseRewindSeconds);
      _pendingResumeSeek = targetPos < Duration.zero ? Duration.zero : targetPos;
    } else {
      _pendingResumeSeek = null;
    }

    await _player.pause();
    unawaited(AudioFocus.instance.abandon());
    _pushState(force: true);
    flushProgress();
  }

  Future<void> smartSeek(int seconds, {bool isForward = true}) async {
    if (!_loaded) return;

    final currentPos = currentPosition;
    final duration = currentDuration;
    final totalDuration = duration > Duration.zero
        ? duration
        : Duration(seconds: currentChapter?.duration ?? 0);

    final targetPos = currentPos + Duration(seconds: seconds);

    if (isForward) {
      if (totalDuration > Duration.zero && targetPos >= totalDuration) {
        if (hasNext) {
          final overflow = targetPos - totalDuration;
          await playChapterIndex(_index + 1, offsetMs: overflow.inMilliseconds);
        } else {
          await seek(totalDuration);
          await pause();
        }
      } else {
        await seek(targetPos);
      }
    } else {
      if (targetPos < Duration.zero) {
        if (hasPrev) {
          final prevIdx = _index - 1;
          final prevChapter = _chapters[prevIdx];
          final prevTotal = Duration(seconds: prevChapter.duration);
          final targetMs = (prevTotal.inMilliseconds + targetPos.inMilliseconds)
              .clamp(0, prevTotal.inMilliseconds);
          await playChapterIndex(prevIdx, offsetMs: targetMs);
        } else {
          await seek(Duration.zero);
        }
      } else {
        await seek(targetPos);
      }
    }
  }

  Future<void> next() async {
    if (_prevNextMode == 1) {
      await smartSeek(_customSeekSeconds, isForward: true);
    } else {
      if (!hasNext) return;
      await playChapterIndex(_index + 1);
    }
  }

  Future<void> previous() async {
    if (_prevNextMode == 1) {
      await smartSeek(-_customSeekSeconds, isForward: false);
    } else {
      if (!hasPrev) return;
      await playChapterIndex(_index - 1);
    }
  }

  Future<void> seek(Duration to) async {
    await _player.seek(to);
    _pushState(force: true);
  }

  Future<void> seekRelative(int seconds) async {
    final target = currentPosition + Duration(seconds: seconds);
    await seek(target < Duration.zero ? Duration.zero : target);
  }

  Future<void> jumpToBookmark(Bookmark bm) async {
    final idx = _chapters.indexWhere((c) => c.cid == bm.cid);
    if (idx < 0) return;
    if (idx == _index && _loaded && !_loading) {
      await seek(Duration(milliseconds: bm.positionMs));
      if (!_player.state.playing) await resume();
      return;
    }
    await playChapterIndex(idx, offsetMs: bm.positionMs);
  }

  Future<bool> playBookmark(Bookmark bm) async {
    _ensureNotificationPermission();
    if (_book?.bvid == bm.bvid && _chapters.isNotEmpty) {
      final idx = _chapters.indexWhere((c) => c.cid == bm.cid);
      if (idx >= 0) {
        return await _loadTarget(idx, resumeMs: bm.positionMs);
      }
      if (_chaptersComplete) return false;
    }
    try {
      final book = await _api.detail(bm.bvid);
      var chapters = book.chapters ?? const <Chapter>[];
      if (chapters.isEmpty) chapters = await _api.pageList(bm.bvid);
      final idx = chapters.indexWhere((c) => c.cid == bm.cid);
      if (idx < 0) return false;
      if (_playTallyBook?.bvid != book.bvid) {
        _playTally = Duration.zero;
        _playTallyBook = book;
        _autoShelved = false;
      }
      return await _loadTarget(
        idx,
        resumeMs: bm.positionMs,
        newBook: book,
        newChapters: chapters,
      );
    } catch (e) {
      return false;
    }
  }

  Future<void> stop() async {
    if (_stopping) return;
    _stopping = true;
    _pausedByInterruption = false;
    if (_loaded) flushProgress();
    _session++;
    try {
      await _player.stop();
    } catch (e) {}
    unawaited(AudioFocus.instance.abandon());
    _loaded = false;
    _playbackUrl = null;
    _mediaReady = false;
    _reconnecting = false;
    positionTick.value = Duration.zero;
    _positionTimer?.cancel();
    
    // 【新增】停掉日志监听
    _logcatProcess?.kill();
    _bydLogListening = false;

    final h = _audioHandler;
    if (h != null) {
      h.mediaItem.add(null);
      h.playbackState.add(
        h.playbackState.value.copyWith(
          processingState: AudioProcessingState.idle,
          playing: false,
          updatePosition: Duration.zero,
        ),
      );
    }
    _stopping = false;
    notifyListeners();
  }

  static const Duration _autoShelfAfter = Duration(minutes: 1);
  String? _tallyBvid;
  Duration _lastTallyPos = Duration.zero;

  void _tallyPlayTime() {
    final book = _book;
    if (book == null || !_loaded) return;
    if (currentDuration <= Duration.zero) return;

    final pos = currentPosition;
    if (_tallyBvid != book.bvid) {
      _tallyBvid = book.bvid;
      _lastTallyPos = pos;
      return;
    }
    final delta = pos - _lastTallyPos;
    _lastTallyPos = pos;
    if (delta <= Duration.zero || delta > const Duration(seconds: 60)) {
      return;
    }
    _playTally += delta;
    if (_playTally >= _autoShelfAfter && !_autoShelved) {
      _autoShelved = true;
      if (!_shelf.isOnShelf(book.bvid)) {
        unawaited(_shelf.add(book));
        AppAnalytics.onEvent('shelf_add_auto');
      }
    }
  }

  void _markCurrentDone() {
    if (_markingDone) return;
    _markingDone = true;
    final chapter = currentChapter;
    final book = _book;
    _markingDone = false;
    if (chapter == null || book == null) return;
    if (!_shelf.isOnShelf(book.bvid)) return;
    _shelf.markChapterDone(book.bvid, chapter.cid);
  }

  void _markDoneIfReached(Duration pos) {
    final chapter = currentChapter;
    final book = _book;
    final dur = currentDuration;
    if (chapter == null || book == null || dur <= Duration.zero) return;
    if (pos < dur * 0.95) return;
    if (!_shelf.isOnShelf(book.bvid)) return;
    _shelf.markChapterDone(book.bvid, chapter.cid);
  }

  Map<String, String> get downloadHeaders => _streamHeaders();

  Future<({List<Chapter> chapters, bool complete})> resolveChapters(
      String bvid) async {
    if (_book?.bvid == bvid && _chapters.isNotEmpty) {
      return (chapters: [..._chapters], complete: _chaptersComplete);
    }

    try {
      final list = await _api.pageList(bvid);
      if (list.isNotEmpty) return (chapters: list, complete: true);
    } catch (_) {}

    final saved = _shelf.byBvid(bvid)?.book.chapters;
    if (saved != null && saved.isNotEmpty) {
      return (chapters: [...saved], complete: true);
    }

    return (chapters: _cache.chaptersOf(bvid), complete: false);
  }

  Future<CachePlayOutcome> playCachedEntry(
      String bvid, int cid, Book book) async {
    _ensureNotificationPermission();

    final local = await _cachedPathOf(bvid, cid);
    if (local == null) {
      _cache.logEvent('播放缓存失败：文件不存在 $bvid/$cid');
      return CachePlayOutcome.fileMissing;
    }

    final resolved = await resolveChapters(bvid);
    final chapters = resolved.chapters;
    var index = chapters.indexWhere((c) => c.cid == cid);
    if (index < 0) {
      final fromCache = _cache.entriesOf(bvid)
          .firstWhere((e) => e.cid == cid, orElse: () => CacheEntry(
              bvid: bvid, cid: cid, bookTitle: book.cleanTitle, chapterTitle: ''));
      chapters.add(fromCache.toChapter());
      index = chapters.length - 1;
    }

    var shelf = _shelf.byBvid(bvid);
    final target = shelf?.book ?? book;
    if (shelf == null) {
      await _shelf.add(target);
      shelf = _shelf.byBvid(bvid);
    }
    final resumeMs = (shelf != null && shelf.lastCid == cid) ? shelf.positionMs : 0;

    final ok = await _loadTarget(index,
        resumeMs: resumeMs,
        newBook: target,
        newChapters: chapters,
        chaptersComplete: resolved.complete);

    if (!ok) {
      _cache.logEvent('缓存入口播放失败 $bvid/$cid');
      return CachePlayOutcome.failed;
    }
    return _isOffline ? CachePlayOutcome.okOffline : CachePlayOutcome.okOnline;
  }

  Future<String?> resolveUrlFor(String bvid, int cid) async {
    try {
      final cached = _urlCache[cid];
      if (cached != null &&
          DateTime.now().millisecondsSinceEpoch - cached.ts <
              90 * 60 * 1000) {
        return cached.url;
      }
      final audio = await _api.playUrl(bvid, cid);
      final urls = <String>[];
      String toHttps(String u) =>
          u.startsWith('http://') ? 'https://${u.substring(7)}' : u;
      void add(AudioTrack? t) {
        if (t == null) return;
        if (t.baseUrl.isNotEmpty) urls.add(toHttps(t.baseUrl));
        for (final b in t.backupUrls) {
          if (b.isNotEmpty) urls.add(toHttps(b));
        }
      }

      final aac = [...audio.tracks]..sort((a, b) => b.bandwidth.compareTo(a.bandwidth));
      for (final t in aac) {
        add(t);
      }
      add(audio.flac);
      add(audio.dolby);
      final uniq = urls.toSet().toList();
      if (uniq.isEmpty) return null;
      _urlCache[cid] = (url: uniq.first, ts: DateTime.now().millisecondsSinceEpoch);
      if (_urlCache.length > 12) {
        _urlCache.remove(_urlCache.keys.first);
      }
      return uniq.first;
    } catch (e) {
      return null;
    }
  }

  Duration? get position => _player.state.duration > Duration.zero
      ? _player.state.position
      : null;
  Duration get currentPosition => _player.state.position;
  Duration get currentDuration => _player.state.duration;
  bool get isPlaying => _player.state.playing;
  bool get buffering => _player.state.buffering;

  Timer? _lastSaveTimer;
  void _tickSave() {
    if (currentChapter == null || _book == null) return;
    _lastSaveTimer?.cancel();
    _lastSaveTimer = Timer(const Duration(seconds: 2), _saveNow);
  }

  void _saveNow() {
    if (!_loaded) return;
    if (_loading) return;
    final chapter = currentChapter;
    final book = _book;
    if (chapter == null || book == null) return;
    final pos = currentPosition;
    var durMs = currentDuration.inMilliseconds;
    if (durMs <= 0) durMs = chapter.duration * 1000;
    if (durMs <= 0) return;
    _shelf.updateProgress(
      book.bvid,
      cid: chapter.cid,
      chapterIndex: _index,
      positionMs: pos.inMilliseconds,
      chapterDurationMs: durMs,
      totalChapters: _chaptersComplete ? _chapters.length : 0,
    );
  }

  void flushProgress() {
    _lastSaveTimer?.cancel();
    _saveNow();
  }

  void setSleepTimer(Duration d) {
    _sleepTimer?.cancel();
    _sleepRemaining = d;
    AppAnalytics.onEvent('sleep_timer_use', {'minutes': d.inMinutes});
    _sleepTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      _sleepRemaining -= const Duration(seconds: 1);
      if (_sleepRemaining <= Duration.zero) {
        t.cancel();
        _sleepRemaining = Duration.zero;
        pause();
      }
      notifyListeners();
    });
    notifyListeners();
  }

  void cancelSleepTimer() {
    _sleepTimer?.cancel();
    _sleepRemaining = Duration.zero;
    notifyListeners();
  }
}