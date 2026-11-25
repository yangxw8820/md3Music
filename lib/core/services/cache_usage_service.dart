import 'dart:io';

import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:path_provider/path_provider.dart';

import '../../data/repositories/settings_repository.dart';
import 'depth_cover_cache.dart';
import 'remote/remote_download_cache.dart';

/// 一次缓存占用快照。
///
/// 口径：**总量 = 图片 + 歌曲**。
/// - 图片 = DefaultCacheManager 网络封面 + 深度图缓存 + 远程缓存里的图片文件；
/// - 歌曲 = 远程缓存里的音频文件及未完成分片（在线串流播放不落盘，不计入）。
class CacheUsageSnapshot {
  const CacheUsageSnapshot({
    required this.imageBytes,
    required this.songBytes,
    this.limitBytes = 0,
  });

  final int imageBytes;
  final int songBytes;

  /// 本次统计时的上限（字节）；0 表示未传入。
  final int limitBytes;

  int get totalBytes => imageBytes + songBytes;

  bool get overLimit => limitBytes > 0 && totalBytes > limitBytes;
}

/// 全应用统一缓存账本：统计占用、按上限裁剪、一键清空。
///
/// 之所以需要这一层：项目里的缓存原本分散在 DefaultCacheManager（图片）、
/// DepthCoverCache（深度图）与 RemoteDownloadCache（FTP 歌曲/封面）三处，
/// 彼此的目录、上限和清理入口都不相通；设置页的 `settings_cache_size`
/// 也是只写不读的死键。这里把它们收敛到一个口径，UI 只依赖本服务。
class CacheUsageService {
  CacheUsageService({
    Future<int> Function()? networkImageBytes,
    Future<int> Function()? depthImageBytes,
    Future<RemoteCacheBytes> Function()? remoteCacheBytes,
    Future<void> Function(int targetBytes)? pruneNetworkImages,
    Future<void> Function(int targetBytes)? pruneRemote,
    Future<void> Function()? clearDepth,
    SettingsRepository? settingsRepository,
  })  : _networkImageBytes =
            networkImageBytes ?? _readNetworkImageBytes,
        _depthImageBytes = depthImageBytes ?? _readDepthImageBytes,
        _remoteCacheBytes = remoteCacheBytes ?? RemoteDownloadCache.cacheBytes,
        _pruneNetworkImages =
            pruneNetworkImages ?? _trimNetworkImages,
        _pruneRemote =
            pruneRemote ?? RemoteDownloadCache.pruneToBytes,
        _clearDepth = clearDepth ?? _clearDepthCache,
        _settingsRepository = settingsRepository ?? SettingsRepository();

  static final CacheUsageService instance = CacheUsageService();

  final Future<int> Function() _networkImageBytes;
  final Future<int> Function() _depthImageBytes;
  final Future<RemoteCacheBytes> Function() _remoteCacheBytes;
  final Future<void> Function(int targetBytes) _pruneNetworkImages;
  final Future<void> Function(int targetBytes) _pruneRemote;
  final Future<void> Function() _clearDepth;
  final SettingsRepository _settingsRepository;

  static int mbToBytes(int mb) => mb * 1024 * 1024;

  /// 统一的人类可读体积格式（设置页与提示文案共用）。
  static String formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  /// 读取当前上限（字节）。
  Future<int> currentLimitBytes() async =>
      mbToBytes(await _settingsRepository.getCacheSize());

  /// 统计所有落盘缓存。各子项单独容错，任何一处失败都返回其余结果。
  Future<CacheUsageSnapshot> measure({int? limitBytes}) async {
    final results = await Future.wait([
      _safeRead(_networkImageBytes, 0),
      _safeRead(_depthImageBytes, 0),
      _safeRead(
        _remoteCacheBytes,
        const (
          audioBytes: 0,
          imageBytes: 0,
          otherBytes: 0,
          totalBytes: 0,
        ),
      ),
    ]);
    final networkImages = results[0] as int;
    final depthImages = results[1] as int;
    final remote = results[2] as RemoteCacheBytes;
    return CacheUsageSnapshot(
      // 远程缓存里的图片也归到「图片」；其他/分片归到「歌曲」，
      // 保证 总量 == 图片 + 歌曲，不会出现三项对不上的情况。
      imageBytes: networkImages + depthImages + remote.imageBytes,
      songBytes: remote.audioBytes + remote.otherBytes,
      limitBytes: limitBytes ?? 0,
    );
  }

  /// 按上限裁剪：[limitMb] 省略时读取设置里的上限。
  ///
  /// 顺序：先裁远程歌曲（重新下载成本最低），再裁网络封面，最后才清深度图。
  /// 每一步之后重新测量，避免多删或少删。返回裁剪后的快照。
  Future<CacheUsageSnapshot> enforceLimit({int? limitMb}) async {
    final mb = limitMb ?? await _settingsRepository.getCacheSize();
    final target = mbToBytes(mb < 0 ? 0 : mb);
    var snapshot = await measure(limitBytes: target);
    if (!snapshot.overLimit) return snapshot;

    final songTarget = snapshot.imageBytes >= target
        ? 0
        : target - snapshot.imageBytes;
    await _safe(() => _pruneRemote(songTarget));

    snapshot = await measure(limitBytes: target);
    if (!snapshot.overLimit) return snapshot;

    final imageTarget = snapshot.songBytes >= target
        ? 0
        : target - snapshot.songBytes;
    await _safe(() => _pruneNetworkImages(imageTarget));

    snapshot = await measure(limitBytes: target);
    if (!snapshot.overLimit) return snapshot;

    // 深度图重算代价高，只在网络封面裁完仍超限时整目录清掉。
    await _safe(_clearDepth);
    return measure(limitBytes: target);
  }

  /// 清空全部落盘缓存。不碰临时目录里的其他文件（升级包、录音等）。
  Future<void> clearAll() async {
    await _safe(() => _pruneNetworkImages(0));
    await _safe(_clearDepth);
    await _safe(() => _pruneRemote(0));
  }

  Future<void> _safe(Future<void> Function() action) async {
    try {
      await action();
    } catch (_) {}
  }

  static Future<T> _safeRead<T>(Future<T> Function() read, T fallback) async {
    try {
      return await read();
    } catch (_) {
      return fallback;
    }
  }

  /// DefaultCacheManager 的文件固定落在 `getTemporaryDirectory()/libCachedImageData`。
  static Future<int> _readNetworkImageBytes() async {
    try {
      final temp = await getTemporaryDirectory();
      final dir = Directory(
        '${temp.path}${Platform.pathSeparator}${DefaultCacheManager.key}',
      );
      if (!dir.existsSync()) return 0;
      var total = 0;
      await for (final entity in dir.list(recursive: true, followLinks: false)) {
        if (entity is! File) continue;
        try {
          total += entity.lengthSync();
        } catch (_) {}
      }
      return total;
    } catch (_) {
      return 0;
    }
  }

  static Future<int> _readDepthImageBytes() =>
      DepthCoverCache().cacheSizeBytes();

  static Future<void> _clearDepthCache() async {
    await DepthCoverCache().clearCache();
  }

  /// 网络封面按 `touched` 时间 LRU 增量删除；元数据失真时兜底整池清空。
  static Future<void> _trimNetworkImages(int targetBytes) async {
    final manager = DefaultCacheManager();
    final current = await _readNetworkImageBytes();
    if (current <= targetBytes) return;

    var freed = 0;
    try {
      final objects = await manager.config.repo.getAllObjects();
      objects.sort((a, b) {
        final at = a.touched?.millisecondsSinceEpoch ?? 0;
        final bt = b.touched?.millisecondsSinceEpoch ?? 0;
        return at.compareTo(bt);
      });
      for (final object in objects) {
        if (current - freed <= targetBytes) break;
        final length = object.length ?? 0;
        try {
          await manager.store.removeCachedFile(object);
          freed += length;
        } catch (_) {}
      }
    } catch (_) {}

    // 元数据缺失/长度失真时，整池清空，确保上限真的能生效。
    if (await _readNetworkImageBytes() > targetBytes) {
      await manager.emptyCache();
    }
  }
}
