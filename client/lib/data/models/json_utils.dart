// lib/data/models/json_utils.dart
//
// index.json 的宽松解析工具。
//
// 阶段一的原则：**单条数据出问题不能影响整体渲染**。
// 所以字段一律走「带默认值的宽松读取」，只有结构性错误（apps 不是数组、顶层不是对象）
// 才向上抛 FormatException，由 MarketRepository 统一转成给用户看的错误文案。

/// 取字符串，缺失/类型不符时返回 [fallback]（会 trim）
String asString(Object? value, {String fallback = ''}) {
  if (value == null) return fallback;
  if (value is String) {
    final String trimmed = value.trim();
    return trimmed.isEmpty ? fallback : trimmed;
  }
  if (value is num || value is bool) return value.toString();
  return fallback;
}

/// 取字符串，空串视为缺失（返回 null）
String? asStringOrNull(Object? value) {
  final String result = asString(value);
  return result.isEmpty ? null : result;
}

/// 取整数（允许写成 "3" / 3.0）
int asInt(Object? value, {int fallback = 0}) {
  if (value is int) return value;
  if (value is double) return value.round();
  if (value is num) return value.round();
  if (value is String) {
    final double? parsed = double.tryParse(value.trim());
    if (parsed != null) return parsed.round();
  }
  return fallback;
}

/// 解析「体积」为字节数。
/// 支持三种写法：`1048576`、`"1048576"`、`"2.3 MB"`（大小写不敏感，KB/KiB 都认）
int asByteSize(Object? value) {
  if (value is int) return value;
  if (value is num) return value.round();
  if (value is String) {
    final RegExpMatch? match =
        RegExp(r'([\d.]+)\s*(b|kb|kib|mb|mib|gb|gib)?', caseSensitive: false)
            .firstMatch(value.trim());
    if (match == null) return 0;
    final double amount = double.tryParse(match.group(1) ?? '') ?? 0;
    final String unit = (match.group(2) ?? 'b').toLowerCase();
    final int factor = switch (unit) {
      'kb' || 'kib' => 1024,
      'mb' || 'mib' => 1024 * 1024,
      'gb' || 'gib' => 1024 * 1024 * 1024,
      _ => 1,
    };
    return (amount * factor).round();
  }
  return 0;
}

/// 取字符串数组。允许直接写成 `"工具,效率"` 这种分隔串。
List<String> asStringList(Object? value) {
  if (value is List) {
    final List<String> result = <String>[];
    for (final Object? item in value) {
      final String text = asString(item);
      if (text.isNotEmpty) result.add(text);
    }
    return result;
  }
  if (value is String && value.trim().isNotEmpty) {
    return value
        .split(RegExp(r'[,，;；|]+'))
        .map((String s) => s.trim())
        .where((String s) => s.isNotEmpty)
        .toList(growable: false);
  }
  return const <String>[];
}

/// 取对象（key 统一转成 String）
Map<String, dynamic>? asMap(Object? value) {
  if (value is Map) {
    return value.map<String, dynamic>(
      (Object? k, Object? v) => MapEntry<String, dynamic>(k.toString(), v),
    );
  }
  return null;
}

/// 取对象数组，自动跳过非对象元素
List<Map<String, dynamic>> asMapList(Object? value) {
  if (value is! List) return const <Map<String, dynamic>>[];
  final List<Map<String, dynamic>> result = <Map<String, dynamic>>[];
  for (final Object? item in value) {
    final Map<String, dynamic>? map = asMap(item);
    if (map != null) result.add(map);
  }
  return result;
}

/// 取时间。支持 ISO8601 字符串、Unix 秒、Unix 毫秒。
DateTime? asDateTime(Object? value) {
  if (value == null) return null;
  if (value is DateTime) return value;
  if (value is int) return _fromEpoch(value);
  if (value is num) return _fromEpoch(value.toInt());
  if (value is String) {
    final String text = value.trim();
    if (text.isEmpty) return null;
    final int? epoch = int.tryParse(text);
    if (epoch != null) return _fromEpoch(epoch);
    return DateTime.tryParse(text);
  }
  return null;
}

DateTime? _fromEpoch(int value) {
  if (value <= 0) return null;
  // 13 位是毫秒，10 位是秒；用 1e11 作为分界（约公元 5138 年）
  final int millis = value > 100000000000 ? value : value * 1000;
  return DateTime.fromMillisecondsSinceEpoch(millis);
}

/// 人性化体积展示：`0 B` / `512 B` / `1.5 KB` / `2.31 MB` / `1.20 GB`
///
/// 存储管理页要同时展示「几字节的键值」和「几 MB 的文件」，用同一套单位避免用户换算。
String formatBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}

/// 人性化时间展示：刚刚 / N 分钟前 / N 小时前 / N 天前 / yyyy-MM-dd
String formatDateTimeLabel(DateTime? time) {
  if (time == null) return '未知';
  final DateTime local = time.toLocal();
  final Duration diff = DateTime.now().difference(local);
  if (diff.inSeconds < 60) return '刚刚';
  if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前';
  if (diff.inHours < 24) return '${diff.inHours} 小时前';
  if (diff.inDays < 30) return '${diff.inDays} 天前';
  final String y = local.year.toString().padLeft(4, '0');
  final String m = local.month.toString().padLeft(2, '0');
  final String d = local.day.toString().padLeft(2, '0');
  return '$y-$m-$d';
}
