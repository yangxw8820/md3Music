import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/services/remote/remote_download_cache.dart';

void main() {
  Future<Directory> mkTemp() =>
      Directory.systemTemp.createTemp('remote_cache_test');

  test('ensureDownloaded 首次下载后二次命中同一路径', () async {
    var downloads = 0;
    final cache = RemoteDownloadCache(
      tempDir: await mkTemp(),
      downloader: (remotePath, destFile) async {
        downloads++;
        await destFile.writeAsBytes(List.filled(10, 1));
      },
    );
    addTearDown(cache.dispose);

    final p1 = await cache.ensureDownloaded('cfg1', '/music/a.mp3');
    expect(p1, isNotNull);
    expect(File(p1!).existsSync(), isTrue);
    expect(downloads, 1);

    // 二次请求命中缓存：返回同一路径且不重复下载
    final p2 = await cache.ensureDownloaded('cfg1', '/music/a.mp3');
    expect(p2, p1);
    expect(downloads, 1);
  });

  test('cacheBytes 按扩展名拆分音频/图片/其他', () async {
    final dir = await mkTemp();
    addTearDown(() => dir.delete(recursive: true));
    Directory('${dir.path}/cfg').createSync(recursive: true);
    File('${dir.path}/cfg/a.mp3').writeAsBytesSync(List.filled(100, 1));
    File('${dir.path}/cfg/c.jpg').writeAsBytesSync(List.filled(30, 1));
    File('${dir.path}/cfg/d.unknown').writeAsBytesSync(List.filled(10, 1));
    // .part 半成品按原扩展名归类，仍占磁盘
    File('${dir.path}/cfg/e.mp3.part').writeAsBytesSync(List.filled(5, 1));

    final bytes = await RemoteDownloadCache.cacheBytes(directory: dir);
    expect(bytes.audioBytes, 105);
    expect(bytes.imageBytes, 30);
    expect(bytes.otherBytes, 10);
    expect(bytes.totalBytes, 145);
  });

  test('pruneToBytes 按最旧裁剪；clearCache 清空内容但保留根目录', () async {
    final dir = await mkTemp();
    addTearDown(() => dir.delete(recursive: true));
    final old = File('${dir.path}/old.mp3')..writeAsBytesSync(List.filled(60, 1));
    final fresh = File('${dir.path}/fresh.jpg')
      ..writeAsBytesSync(List.filled(30, 1));
    old.setLastModifiedSync(DateTime.now().subtract(const Duration(days: 1)));
    fresh.setLastModifiedSync(DateTime.now());

    await RemoteDownloadCache.pruneToBytes(50, directory: dir);
    expect(old.existsSync(), isFalse);
    expect(fresh.existsSync(), isTrue);

    await RemoteDownloadCache.clearCache(directory: dir);
    expect(dir.existsSync(), isTrue);
    expect(fresh.existsSync(), isFalse);
  });

  test('maxBytes 为 0 表示不限制，pruneToBytes 不删除文件', () async {
    final dir = await mkTemp();
    addTearDown(() => dir.delete(recursive: true));
    final old = File('${dir.path}/old.mp3')..writeAsBytesSync(List.filled(60, 1));
    final fresh = File('${dir.path}/fresh.jpg')
      ..writeAsBytesSync(List.filled(30, 1));
    old.setLastModifiedSync(DateTime.now().subtract(const Duration(days: 2)));
    fresh.setLastModifiedSync(DateTime.now().subtract(const Duration(days: 1)));

    await RemoteDownloadCache.pruneToBytes(0, directory: dir);

    expect(old.existsSync(), isTrue);
    expect(fresh.existsSync(), isTrue);
    expect((await RemoteDownloadCache.cacheBytes(directory: dir)).totalBytes, 90);
  });

  test('缓存超阈值按最旧清理，之后重新下载', () async {
    var downloads = 0;
    final cache = RemoteDownloadCache(
      tempDir: await mkTemp(),
      maxBytes: 100,
      downloader: (_, dest) async {
        downloads++;
        await dest.writeAsBytes(List.filled(60, 1));
      },
    );
    addTearDown(cache.dispose);

    final a = await cache.ensureDownloaded('cfg1', '/a.mp3');
    expect(a, isNotNull);
    // 保证两次下载的修改时间有先后，LRU 判定确定
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final b = await cache.ensureDownloaded('cfg1', '/b.mp3');
    expect(b, isNotNull);
    expect(downloads, 2);

    // 总量 120 > 100：最旧的 a 被清理
    expect(File(a!).existsSync(), isFalse);

    // 再次请求 a：缓存已失效 → 重新下载
    final a2 = await cache.ensureDownloaded('cfg1', '/a.mp3');
    expect(a2, isNotNull);
    expect(downloads, 3);
    expect(File(a2!).existsSync(), isTrue);
  });
}