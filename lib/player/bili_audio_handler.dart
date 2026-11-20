import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';

import 'book_player.dart';

/// 将 BookPlayer 暴露为 Android 系统媒体会话
class BiliAudioHandler extends BaseAudioHandler {
  BiliAudioHandler() {
    playbackState.add(
      PlaybackState(
        controls: [
          MediaControl.skipToPrevious,
          MediaControl.rewind,
          MediaControl.play,
          MediaControl.fastForward,
          MediaControl.skipToNext,
        ],
        systemActions: {
          MediaAction.seek,
          MediaAction.seekForward,
          MediaAction.seekBackward,
          MediaAction.rewind,
          MediaAction.fastForward,
          MediaAction.play,
          MediaAction.pause,
          MediaAction.playPause,
          MediaAction.stop,
        },
        androidCompactActionIndices: const [0, 1, 2],
        processingState: AudioProcessingState.idle,
        playing: false,
        updatePosition: Duration.zero,
      ),
    );
  }

  BookPlayer get _player => BookPlayer.instance;

  @override
  Future<void> play() async {
    debugPrint('[MediaKey] play()');
    await _player.resumeFromMediaCommand();
  }

  @override
  Future<void> pause() async {
    debugPrint('[MediaKey] pause()');
    await _player.pause();
  }

  /// 关键修复：处理方向盘、蓝牙耳机等媒体按键
  @override
  Future<void> click([MediaButton button = MediaButton.media]) async {
    debugPrint('[MediaKey] click: $button');

    switch (button) {
      case MediaButton.media:
        // Android 将 MEDIA_PLAY、MEDIA_PAUSE、
        // MEDIA_PLAY_PAUSE 等按键统一映射到这里。
        if (_player.isPlaying) {
          await _player.pause();
        } else {
          await _player.resumeFromMediaCommand();
        }
        break;

      case MediaButton.next:
        await _player.next();
        break;

      case MediaButton.previous:
        await _player.previous();
        break;
    }
  }

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> skipToNext() => _player.next();

  @override
  Future<void> skipToPrevious() => _player.previous();

  @override
  Future<void> fastForward() => _player.seekRelative(15);

  @override
  Future<void> rewind() => _player.seekRelative(-15);

  @override
  Future<void> stop() => _player.stop();
}