import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/services/cache_usage_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const oneMb = 1024 * 1024;

  group('CacheUsageService', () {
    test('measure 合并三处缓存，总量恒等于图片加歌曲', () async {
      final service = CacheUsageService(
        networkImageBytes: () async => 100,
        depthImageBytes: () async => 20,
        remoteCacheBytes: () async => (
          audioBytes: 200,
          imageBytes: 30,
          otherBytes: 10,
          totalBytes: 240,
        ),
      );

      final snapshot = await service.measure();
      expect(snapshot.imageBytes, 150);
      expect(snapshot.songBytes, 210);
      expect(snapshot.totalBytes, 360);
      expect(snapshot.totalBytes, snapshot.imageBytes + snapshot.songBytes);
    });

    test('单个统计源失败时其余结果仍可用', () async {
      final service = CacheUsageService(
        networkImageBytes: () async => 100,
        depthImageBytes: () async => 20,
        remoteCacheBytes: () async => throw StateError('目录不可读'),
      );

      final snapshot = await service.measure();
      expect(snapshot.imageBytes, 120);
      expect(snapshot.songBytes, 0);
    });

    test('enforceLimit 优先裁剪远程歌曲，未超限时不碰图片', () async {
      var remoteAudio = 600000;
      final remoteTargets = <int>[];
      var imageCalls = 0;
      final service = CacheUsageService(
        networkImageBytes: () async => 600000,
        depthImageBytes: () async => 0,
        remoteCacheBytes: () async => (
          audioBytes: remoteAudio,
          imageBytes: 0,
          otherBytes: 0,
          totalBytes: remoteAudio,
        ),
        pruneRemote: (target) async {
          remoteTargets.add(target);
          remoteAudio = target;
        },
        pruneNetworkImages: (target) async => imageCalls++,
      );

      final snapshot = await service.enforceLimit(limitMb: 1);
      expect(remoteTargets, [oneMb - 600000]);
      expect(imageCalls, 0);
      expect(snapshot.totalBytes, oneMb);
      expect(snapshot.overLimit, isFalse);
    });

    test('enforceLimit 歌曲裁完仍超限才裁图片，再不行清深度图', () async {
      var network = 1200000;
      var depth = 600000;
      final imageTargets = <int>[];
      var depthCalls = 0;
      final service = CacheUsageService(
        networkImageBytes: () async => network,
        depthImageBytes: () async => depth,
        remoteCacheBytes: () async => (
          audioBytes: 0,
          imageBytes: 0,
          otherBytes: 0,
          totalBytes: 0,
        ),
        pruneRemote: (target) async {},
        pruneNetworkImages: (target) async {
          imageTargets.add(target);
          // 模拟元数据失真：图片池只降到 600KB，没达到目标。
          network = 600000;
        },
        clearDepth: () async {
          depthCalls++;
          depth = 0;
        },
      );

      final snapshot = await service.enforceLimit(limitMb: 1);
      expect(imageTargets, [oneMb]);
      expect(depthCalls, 1);
      expect(snapshot.totalBytes, 600000);
      expect(snapshot.overLimit, isFalse);
    });

    test('limitMb 为 0 表示不限制，不触发任何裁剪', () async {
      var remoteAudio = 100;
      var images = 100;
      var remoteCalls = 0;
      var imageCalls = 0;
      var depthCalls = 0;
      final service = CacheUsageService(
        networkImageBytes: () async => images,
        depthImageBytes: () async => 0,
        remoteCacheBytes: () async => (
          audioBytes: remoteAudio,
          imageBytes: 0,
          otherBytes: 0,
          totalBytes: remoteAudio,
        ),
        pruneRemote: (target) async {
          remoteCalls++;
          remoteAudio = target;
        },
        pruneNetworkImages: (target) async {
          imageCalls++;
          images = target;
        },
        clearDepth: () async => depthCalls++,
      );

      final snapshot = await service.enforceLimit(limitMb: 0);
      expect(remoteCalls, 0);
      expect(imageCalls, 0);
      expect(depthCalls, 0);
      expect(snapshot.limitBytes, 0);
      expect(snapshot.overLimit, isFalse);
      expect(snapshot.totalBytes, 200);
    });

    test('formatBytes 输出稳定可读', () {
      expect(CacheUsageService.formatBytes(512), '512 B');
      expect(CacheUsageService.formatBytes(2048), '2.0 KB');
      expect(CacheUsageService.formatBytes(5 * oneMb), '5.0 MB');
      expect(CacheUsageService.formatBytes(1536 * oneMb), '1.50 GB');
    });
  });
}
