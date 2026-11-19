
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Android 音频焦点管理
///
/// 功能：
/// 1. 播放时申请系统音频焦点
/// 2. 暂停时释放系统音频焦点
/// 3. 监听音频焦点变化
/// 4. 处理来电、其他播放器抢占、导航提示音
/// 5. 监听耳机拔出、蓝牙断开等音频设备变化
class AudioFocus {
  AudioFocus._();

  static final AudioFocus instance = AudioFocus._();

  static const MethodChannel _method =
      MethodChannel('abts/audio_focus');

  static const EventChannel _events =
      EventChannel('abts/audio_focus_events');

  StreamSubscription<dynamic>? _sub;

  bool _listening = false;
  bool _requesting = false;
  bool _hasFocus = false;

  /// 是否已经获得音频焦点
  bool get hasFocus => _hasFocus;

  /// 是否正在监听焦点事件
  bool get isListening => _listening;

  /// 永久失去焦点
  /// 例如其他播放器抢占
  void Function()? onFocusLost;

  /// 暂时失去焦点
  /// 例如来电或短暂音频打断
  void Function()? onFocusInterrupted;

  /// 音频焦点被闪避
  /// 例如导航提示音
  void Function()? onFocusDucked;

  /// 重新获得焦点
  void Function()? onFocusGained;

  /// 音频输出设备发生变化
  /// 例如拔耳机、蓝牙断开
  void Function()? onNoisy;

  bool get _isAndroid => Platform.isAndroid;

  /// 开始监听系统音频焦点事件
  void start() {
    if (!_isAndroid) {
      debugPrint('[AudioFocus] non-Android, listener skipped');
      return;
    }

    if (_listening || _sub != null) {
      debugPrint('[AudioFocus] listener already started');
      return;
    }

    debugPrint('[AudioFocus] starting listener');

    try {
      _sub = _events.receiveBroadcastStream().listen(
        _handleEvent,
        onError: (Object error, StackTrace stackTrace) {
          debugPrint('[AudioFocus] event stream error: $error');
          debugPrint('$stackTrace');
        },
        onDone: () {
          debugPrint('[AudioFocus] event stream closed');
          _listening = false;
          _sub = null;
        },
        cancelOnError: false,
      );

      _listening = true;
    } catch (e, st) {
      _listening = false;
      _sub = null;

      debugPrint('[AudioFocus] start listener failed: $e');
      debugPrint('$st');
    }
  }

  /// 处理原生焦点事件
  void _handleEvent(dynamic event) {
    debugPrint('[AudioFocus] event: $event');

    switch (event) {
      case 'lost':
        _hasFocus = false;
        onFocusLost?.call();
        break;

      case 'interrupted':
        _hasFocus = false;
        onFocusInterrupted?.call();
        break;

      case 'ducked':
        onFocusDucked?.call();
        break;

      case 'gained':
        _hasFocus = true;
        onFocusGained?.call();
        break;

      case 'noisy':
        onNoisy?.call();
        break;

      default:
        debugPrint('[AudioFocus] unknown event: $event');
        break;
    }
  }

  /// 请求系统音频焦点
  ///
  /// Android 原生申请成功返回 true。
  /// 申请失败或通道异常返回 false。
  /// 非 Android 平台直接返回 true。
  Future<bool> request() async {
    if (!_isAndroid) {
      return true;
    }

    // 避免同时重复发送焦点请求
    if (_requesting) {
      debugPrint('[AudioFocus] request already in progress');
      return false;
    }

    _requesting = true;

    try {
      debugPrint('[AudioFocus] requesting focus');

      final result = await _method.invokeMethod<bool>('request');

      _hasFocus = result ?? false;

      debugPrint('[AudioFocus] request result=$_hasFocus');

      return _hasFocus;
    } catch (e, st) {
      _hasFocus = false;

      debugPrint('[AudioFocus] request failed: $e');
      debugPrint('$st');

      return false;
    } finally {
      _requesting = false;
    }
  }

  /// 释放系统音频焦点
  Future<void> abandon() async {
    if (!_isAndroid) {
      return;
    }

    try {
      debugPrint('[AudioFocus] abandoning focus');

      await _method.invokeMethod<void>('abandon');

      _hasFocus = false;

      debugPrint('[AudioFocus] focus abandoned');
    } catch (e, st) {
      debugPrint('[AudioFocus] abandon failed: $e');
      debugPrint('$st');
    }
  }

  /// 停止监听系统焦点事件
  Future<void> stop() async {
    debugPrint('[AudioFocus] stopping listener');

    try {
      await _sub?.cancel();
    } catch (e) {
      debugPrint('[AudioFocus] cancel listener failed: $e');
    }

    _sub = null;
    _listening = false;

    debugPrint('[AudioFocus] listener stopped');
  }
}
