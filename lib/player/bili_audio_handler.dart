import 'package:audio_service/audio_service.dart';
import 'package:media_kit/media_kit.dart';
import 'dart:io';
import 'package:flutter/services.dart';

late BiliAudioHandler audioHandler;

class BiliAudioHandler extends BaseAudioHandler {
  final Player player = Player();
  final MethodChannel _deviceChannel = const MethodChannel("abts/device");

  BiliAudioHandler() {
    _setupPlayer();
    _deviceChannel.setMethodCallHandler((call) async {
      switch (call.method) {
        /// 原生Kotlin调用：切换播放暂停【新增】
        case "togglePlayPause":
          await playPause();
          result.success(true);
          break;

        case "isLeanback":
          result.success(false);
          break;

        default:
          result.notImplemented();
          break;
      }
    });
  }

  void _setupPlayer() {
    player.streams.playing.listen((bool playing) {
      playbackState.add(playbackState.value.copyWith(
        playing: playing,
      ));
    });
    player.streams.position.listen((Duration pos) {
      playbackState.add(playbackState.value.copyWith(
        position: pos,
      ));
    });
    player.streams.duration.listen((Duration dur) {
      mediaItem.add(mediaItem.value?.copyWith(duration: dur));
    });
    player.streams.completed.listen((bool completed) async {
      if (completed) {
        await stop();
      }
    });
  }

  Future<void> setSource(String uri, {String? title, String? artist}) async {
    await player.open(Media(uri));
    mediaItem.add(MediaItem(
      id: uri,
      title: title ?? "未知",
      artist: artist,
    ));
  }

  @override
  Future<void> play() async {
    await player.play();
    playbackState.add(playbackState.value.copyWith(playing: true));
  }

  @override
  Future<void> pause() async {
    await player.pause();
    playbackState.add(playbackState.value.copyWith(playing: false));
  }

  @override
  Future<void> playPause() async {
    if (player.state.playing) {
      await pause();
    } else {
      await play();
    }
  }

  @override
  Future<void> stop() async {
    await player.stop();
    playbackState.add(playbackState.value.copyWith(playing: false));
  }

  @override
  Future<void> seek(Duration position) async {
    await player.seek(position);
  }

  Future<void> dispose() async {
    await player.dispose();
  }
}

Future<BiliAudioHandler> initAudioHandler() async {
  audioHandler = await AudioService.init(
    builder: () => BiliAudioHandler(),
    config: const AudioServiceConfig(
      androidNotificationChannelId: "dev.pages.abts.audio",
      androidNotificationChannelName: "音频播放",
      androidNotificationOngoing: true,
    ),
  );
  return audioHandler;
}
