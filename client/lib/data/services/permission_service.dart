// lib/data/services/permission_service.dart
//
// 权限管理器的数据层。
//
// 三件事都在这里：
//   1. **授权状态**：`perm.decision.<appId>.<permissionId>` → 'granted' | 'denied'。
//      **没写过 = 还没问过用户**（PermissionDecision.ask），
//      于是任何受控权限第一次被调用时都必须弹窗确认 —— 宿主不替用户做主。
//      弹窗里「仅本次生效」默认勾选，那种情况**不落盘**，下次照问。
//   2. **申请记录**：`perm.usage.<appId>.<permissionId>` → JSON。
//      记录这个小程序申请过哪些权限、被拒过几次、最近一次是什么时候。
//   3. **小程序注册表**：`perm.known_apps` → JSON 数组。
//
// 关于注册表与「应用管理」的关系（这一版的改动）：
//   注册表**不再是权限管理器自己的那份应用清单**。应用清单的唯一真相来源是
//   「应用管理」页（ApplicationRegistry），权限管理器只按它给出的 appId 逐项
//   展示与设置权限。这样「应用管理里删掉一个应用」就等于把它从权限管理里
//   一并移除，不会再出现两处清单各说各话。
//   为了兼容旧数据，注册表仍然被读取并作为 appId 的补充来源之一。

import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../core/globals.dart';
import '../models/miniapp_permission.dart';
import 'application_registry.dart';
import 'settings_service.dart';

/// 某个小程序对某个权限的申请记录
@immutable
class MiniappUsage {
  const MiniappUsage({
    this.count = 0,
    this.deniedCount = 0,
    this.firstAt,
    this.lastAt,
  });

  /// 成功调用次数
  final int count;

  /// 因权限被拒而失败的次数（能看出「它想要但被拦了」）
  final int deniedCount;

  final DateTime? firstAt;
  final DateTime? lastAt;

  bool get used => count > 0 || deniedCount > 0;

  int get totalCalls => count + deniedCount;

  static const MiniappUsage empty = MiniappUsage();

  Map<String, dynamic> toJson() => <String, dynamic>{
    'c': count,
    'd': deniedCount,
    if (firstAt != null) 'f': firstAt!.toIso8601String(),
    if (lastAt != null) 'l': lastAt!.toIso8601String(),
  };

  static MiniappUsage fromJson(Map<String, dynamic> json) => MiniappUsage(
    count: (json['c'] as num?)?.toInt() ?? 0,
    deniedCount: (json['d'] as num?)?.toInt() ?? 0,
    firstAt: DateTime.tryParse(json['f']?.toString() ?? ''),
    lastAt: DateTime.tryParse(json['l']?.toString() ?? ''),
  );
}

/// 注册表里的一个小程序（兼容旧数据用；应用清单以应用管理为准）
@immutable
class KnownMiniapp {
  const KnownMiniapp({required this.id, required this.name, this.lastOpenedAt});

  final String id;
  final String name;
  final DateTime? lastOpenedAt;

  /// 展示名：注册表里没记名字时退化成 id（总比空白强）
  String get displayName => name.trim().isEmpty ? id : name;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'name': name,
    if (lastOpenedAt != null) 'last': lastOpenedAt!.toIso8601String(),
  };

  static KnownMiniapp? fromJson(Map<String, dynamic> json) {
    final String id = json['id']?.toString().trim() ?? '';
    if (id.isEmpty) return null;
    return KnownMiniapp(
      id: id,
      name: json['name']?.toString() ?? id,
      lastOpenedAt: DateTime.tryParse(json['last']?.toString() ?? ''),
    );
  }

  KnownMiniapp copyWith({String? name, DateTime? lastOpenedAt}) => KnownMiniapp(
    id: id,
    name: name ?? this.name,
    lastOpenedAt: lastOpenedAt ?? this.lastOpenedAt,
  );
}

/// 一次权限扫描的结果快照。
///
/// 之所以做成不可变快照：管理器页面每次进入/下拉都重新扫一遍，
/// 不持有会变的对象，就不会出现「界面上显示的授权和实际生效的不一致」。
@immutable
class PermissionScanReport {
  const PermissionScanReport({
    required this.miniapps,
    required this.decisions,
    required this.usage,
  });

  final List<KnownMiniapp> miniapps;

  /// appId → 权限 → 用户的决定（没问过就是 ask）
  final Map<String, Map<MiniappPermission, PermissionDecision>> decisions;

  /// appId → 权限 → 申请记录
  final Map<String, Map<MiniappPermission, MiniappUsage>> usage;

  bool get isEmpty => miniapps.isEmpty;

  int get totalApps => miniapps.length;

  /// 申请过任意权限的小程序数量
  int get appsUsingSensitive => miniapps
      .where(
        (KnownMiniapp app) => MiniappPermission.values.any(
          (MiniappPermission p) => usageOf(app.id, p).used,
        ),
      )
      .length;

  /// 被权限闸门拦下来的调用总数
  int get deniedCalls => usage.values
      .expand((Map<MiniappPermission, MiniappUsage> m) => m.values)
      .fold<int>(0, (int sum, MiniappUsage u) => sum + u.deniedCount);

  /// 总共发生过的受控权限调用次数
  int get totalCalls => usage.values
      .expand((Map<MiniappPermission, MiniappUsage> m) => m.values)
      .fold<int>(0, (int sum, MiniappUsage u) => sum + u.totalCalls);

  /// 被扫描到「有实际使用记录」的权限集合
  Set<MiniappPermission> get usedPermissions {
    final Set<MiniappPermission> result = <MiniappPermission>{};
    for (final Map<MiniappPermission, MiniappUsage> byPerm in usage.values) {
      byPerm.forEach((MiniappPermission p, MiniappUsage u) {
        if (u.used) result.add(p);
      });
    }
    return result;
  }

  MiniappUsage usageOf(String appId, MiniappPermission permission) =>
      usage[appId]?[permission] ?? MiniappUsage.empty;

  PermissionDecision decisionOf(String appId, MiniappPermission permission) =>
      decisions[appId]?[permission] ?? permission.defaultDecision;

  /// 某个小程序被用户拒绝的能力
  List<MiniappPermission> deniedOf(String appId) => MiniappPermission.values
      .where(
        (MiniappPermission p) =>
            decisionOf(appId, p) == PermissionDecision.denied,
      )
      .toList(growable: false);

  /// 还没问过用户的能力（调用时会弹窗）
  List<MiniappPermission> undecidedOf(String appId) => MiniappPermission.values
      .where((MiniappPermission p) => decisionOf(appId, p) == PermissionDecision.ask)
      .toList(growable: false);

  /// 全局视角的三个计数（控制器顶部概览用）
  int get undecidedCount => miniapps.fold<int>(
    0,
    (int sum, KnownMiniapp a) => sum + undecidedOf(a.id).length,
  );

  int get deniedCount => miniapps.fold<int>(
    0,
    (int sum, KnownMiniapp a) => sum + deniedOf(a.id).length,
  );

  KnownMiniapp? appById(String appId) {
    for (final KnownMiniapp app in miniapps) {
      if (app.id == appId) return app;
    }
    return null;
  }
}

class PermissionService extends ChangeNotifier {
  PermissionService._(this._settings);

  final SettingsService _settings;

  static PermissionService? _instance;

  static PermissionService get instance {
    final PermissionService? s = _instance;
    if (s == null) {
      throw StateError('PermissionService 尚未初始化，请先看 main() 里的 init 顺序');
    }
    return s;
  }

  /// 在 main() 里、SettingsService.init() 之后调用
  static PermissionService init() =>
      _instance = PermissionService._(SettingsService.instance);

  // ------------------------------------------------------------------ keys

  static const String _kDecisionPrefix = 'perm.decision.';
  static const String _kUsagePrefix = 'perm.usage.';
  static const String _kKnownApps = 'perm.known_apps';

  static String _decisionKey(String appId, MiniappPermission p) =>
      '$_kDecisionPrefix$appId.${p.id}';
  static String _usageKey(String appId, MiniappPermission p) =>
      '$_kUsagePrefix$appId.${p.id}';

  // -------------------------------------------------------------- 授权状态

  /// 用户对该能力的决定。没写过 = 还没问过（[PermissionDecision.ask]）。
  PermissionDecision decisionOf(String appId, MiniappPermission permission) {
    final String? raw = _settings.readRaw(_decisionKey(appId, permission));
    if (raw == null || raw.isEmpty) return permission.defaultDecision;
    return PermissionDecision.byId(raw) ?? permission.defaultDecision;
  }

  /// 用户是否已经做过决定（控制器里用来区分「询问」与「允许/拒绝」）
  bool isDecided(String appId, MiniappPermission permission) =>
      decisionOf(appId, permission) != PermissionDecision.ask;

  bool isGranted(String appId, MiniappPermission permission) =>
      decisionOf(appId, permission) == PermissionDecision.granted;

  Future<void> setDecision(
    String appId,
    MiniappPermission permission,
    PermissionDecision decision,
  ) async {
    if (decision == PermissionDecision.ask) {
      // 「询问」= 没有记录，所以是删除而不是写值 —— 少一个状态就少一处不一致
      await _settings.removeRaw(_decisionKey(appId, permission));
    } else {
      await _settings.writeRaw(_decisionKey(appId, permission), decision.id);
    }
    notifyListeners();
  }

  /// 布尔便捷入口（批量动作与测试用）：true → 允许，false → 拒绝
  Future<void> setGranted(
    String appId,
    MiniappPermission permission,
    bool granted,
  ) => setDecision(
    appId,
    permission,
    granted ? PermissionDecision.granted : PermissionDecision.denied,
  );

  /// 恢复「下次询问」
  Future<void> askAgain(String appId, MiniappPermission permission) =>
      setDecision(appId, permission, PermissionDecision.ask);

  Future<void> setAllDecisions(
    String appId,
    PermissionDecision decision,
  ) async {
    for (final MiniappPermission p in MiniappPermission.values) {
      await setDecision(appId, p, decision);
    }
  }

  /// 一次性打开/关闭某个小程序的全部权限
  Future<void> setAllGranted(String appId, bool granted) => setAllDecisions(
    appId,
    granted ? PermissionDecision.granted : PermissionDecision.denied,
  );

  /// 只动敏感权限。
  ///
  /// 这一版里三项权限（摄像头 / 麦克风 / 管理所有文件）都算敏感，
  /// 所以它等价于 [setAllDecisions]；保留独立入口是为了以后加入
  /// 常规等级的权限时，这个「一键收紧」的语义不会跟着变。
  Future<void> setSensitiveDecision(
    String appId,
    PermissionDecision decision,
  ) async {
    for (final MiniappPermission p in MiniappPermission.sensitiveList) {
      await setDecision(appId, p, decision);
    }
  }

  Future<void> setSensitiveGranted(String appId, bool granted) =>
      setSensitiveDecision(
        appId,
        granted ? PermissionDecision.granted : PermissionDecision.denied,
      );

  /// 对一批小程序批量设置敏感权限
  Future<void> setSensitiveDecisionForAll(
    Iterable<String> appIds,
    PermissionDecision decision,
  ) async {
    for (final String appId in appIds) {
      for (final MiniappPermission p in MiniappPermission.sensitiveList) {
        await setDecision(appId, p, decision);
      }
    }
  }

  Future<void> setSensitiveGrantedForAll(
    Iterable<String> appIds,
    bool granted,
  ) => setSensitiveDecisionForAll(
    appIds,
    granted ? PermissionDecision.granted : PermissionDecision.denied,
  );

  /// 恢复默认 = 全部回到「询问」：删掉该小程序的所有决定，
  /// 下次用到哪个权限就为哪个弹窗。这是「我改错了想重来」的出口。
  Future<void> resetApp(String appId) async {
    final List<String> keys = MiniappPermission.values
        .map((MiniappPermission p) => _decisionKey(appId, p))
        .toList(growable: false);
    await _settings.removeMany(keys);
    notifyListeners();
  }

  // -------------------------------------------------------------- 用量记录

  MiniappUsage usageOf(String appId, MiniappPermission permission) {
    final String? raw = _settings.readRaw(_usageKey(appId, permission));
    if (raw == null || raw.isEmpty) return MiniappUsage.empty;
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is Map) {
        return MiniappUsage.fromJson(
          decoded.map<String, dynamic>(
            (Object? k, Object? v) => MapEntry<String, dynamic>(k.toString(), v),
          ),
        );
      }
    } catch (e) {
      lemonLog('Permission', '用量记录损坏，按空处理：$e');
    }
    return MiniappUsage.empty;
  }

  /// 记一笔调用。[denied] 为 true 表示「调用被权限拦截」，同样要留痕 ——
  /// 「谁想要什么」比「谁成功做了什么」更值得在控制器里暴露。
  ///
  /// 刻意**不** notifyListeners()：它每次桥接调用都会跑，
  /// 通知会让整棵权限页面在每个 API 调用时重建。
  Future<void> recordUse(
    String appId,
    MiniappPermission permission, {
    bool denied = false,
  }) async {
    final MiniappUsage current = usageOf(appId, permission);
    final DateTime now = DateTime.now();
    final MiniappUsage next = MiniappUsage(
      count: current.count + (denied ? 0 : 1),
      deniedCount: current.deniedCount + (denied ? 1 : 0),
      firstAt: current.firstAt ?? now,
      lastAt: now,
    );
    await _settings.writeRaw(
      _usageKey(appId, permission),
      jsonEncode(next.toJson()),
    );
  }

  /// 清掉某个小程序的用量记录（「清除数据」时一起做）
  Future<void> clearUsage(String appId) async {
    await _settings.removeMany(
      MiniappPermission.values
          .map((MiniappPermission p) => _usageKey(appId, p))
          .toList(growable: false),
    );
  }

  // ---------------------------------------------------------------- 注册表

  /// 打开过的小程序（按最近打开时间倒序）
  List<KnownMiniapp> get knownMiniapps {
    final List<KnownMiniapp> list = _readKnownApps();
    list.sort((KnownMiniapp a, KnownMiniapp b) {
      final DateTime da = a.lastOpenedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      final DateTime db = b.lastOpenedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      return db.compareTo(da);
    });
    return list;
  }

  List<String> get knownAppIds =>
      knownMiniapps.map((KnownMiniapp a) => a.id).toList(growable: false);

  String nameOf(String appId) {
    for (final KnownMiniapp app in knownMiniapps) {
      if (app.id == appId) return app.displayName;
    }
    return appId;
  }

  /// 记录「这个小程序被打开过」。
  ///
  /// 注意：**应用清单以「应用管理」（ApplicationRegistry）为准**，
  /// 这个注册表现在只是旧数据的兼容层。新代码登记应用请用
  /// `ApplicationRegistry.instance.record(...)`；这里保留写入是为了
  /// 让升级期间两条路径都不会丢记录。
  @Deprecated('应用清单已改由 ApplicationRegistry 维护，请用它的 record()')
  Future<void> recordOpen(String appId, String name) async {
    if (appId.trim().isEmpty) return;
    final List<KnownMiniapp> list = _readKnownApps();
    final int index = list.indexWhere((KnownMiniapp a) => a.id == appId);
    final String cleanName = name.trim().isEmpty ? appId : name.trim();
    if (index >= 0) {
      list[index] = list[index].copyWith(
        name: cleanName,
        lastOpenedAt: DateTime.now(),
      );
    } else {
      list.add(
        KnownMiniapp(id: appId, name: cleanName, lastOpenedAt: DateTime.now()),
      );
    }
    await _writeKnownApps(list);
    notifyListeners();
  }

  /// 清掉某个 appId 的权限记录（决定 + 申请记录）。
  ///
  /// **它不负责「移除应用」** —— 那件事属于应用管理（ApplicationRegistry.remove）。
  /// 保留这个方法是为了让「只想清权限记录、保留应用」这种场景有出口。
  Future<void> clearAppRecords(String appId) async {
    final List<String> keys = <String>[];
    for (final MiniappPermission p in MiniappPermission.values) {
      keys.add(_decisionKey(appId, p));
      keys.add(_usageKey(appId, p));
    }
    await _settings.removeMany(keys);
    notifyListeners();
  }

  List<KnownMiniapp> _readKnownApps() {
    final String? raw = _settings.readRaw(_kKnownApps);
    if (raw == null || raw.isEmpty) return <KnownMiniapp>[];
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is! List) return <KnownMiniapp>[];
      final List<KnownMiniapp> result = <KnownMiniapp>[];
      for (final Object? item in decoded) {
        if (item is! Map) continue;
        final KnownMiniapp? app = KnownMiniapp.fromJson(
          item.map<String, dynamic>(
            (Object? k, Object? v) => MapEntry<String, dynamic>(k.toString(), v),
          ),
        );
        if (app != null) result.add(app);
      }
      return result;
    } catch (e) {
      lemonLog('Permission', '注册表损坏，重建：$e');
      return <KnownMiniapp>[];
    }
  }

  Future<void> _writeKnownApps(List<KnownMiniapp> apps) async {
    await _settings.writeRaw(
      _kKnownApps,
      jsonEncode(apps.map((KnownMiniapp a) => a.toJson()).toList()),
    );
  }

  // ------------------------------------------------------------------ 扫描

  /// 扫一遍：应用清单以**应用管理**（ApplicationRegistry）为准，
  /// 再补上 storage 里出现过的 appId 与调用方补充的 appId，然后带上全部授权与申请记录。
  /// UI 只消费这个快照。
  ///
  /// 为什么应用清单要从应用管理取：权限管理器里列出的应用必须与
  /// 「应用管理」里的一致 —— 那边删掉一个应用，这边就不该再看到它。
  /// 两处各自维护一份清单是上一版最容易产生不一致的地方。
  PermissionScanReport scan({
    Map<String, String> nameHints = const <String, String>{},
    Iterable<String> extraIds = const <String>[],
  }) {
    final Map<String, KnownMiniapp> merged = <String, KnownMiniapp>{};

    // 1) 应用管理里的清单 —— 主来源
    for (final RegisteredApp app in ApplicationRegistry.instance.all) {
      merged[app.id] = KnownMiniapp(
        id: app.id,
        name: app.displayName,
        lastOpenedAt: app.lastOpenedAt,
      );
    }

    // 2) 旧注册表：兼容尚未迁移完的数据，避免升级瞬间少几个应用
    for (final KnownMiniapp app in knownMiniapps) {
      merged.putIfAbsent(app.id, () => app);
    }

    // 3) storage 里出现过的小程序一定有数据，必须出现在存储管理里
    for (final String id in _settings.miniappStorageAppIds()) {
      merged.putIfAbsent(id, () => KnownMiniapp(id: id, name: id));
    }

    // 4) 调用方补充（例如两个 appfiles 目录名）
    for (final String id in extraIds) {
      if (id.trim().isEmpty) continue;
      merged.putIfAbsent(id, () => KnownMiniapp(id: id, name: id));
    }

    // 市场里能查到名字的，用市场名覆盖「只有 id」的占位名
    nameHints.forEach((String id, String name) {
      final KnownMiniapp? existing = merged[id];
      if (existing == null) return;
      if (name.trim().isEmpty) return;
      merged[id] = existing.copyWith(name: name.trim());
    });

    final Map<String, Map<MiniappPermission, PermissionDecision>> decisions =
        <String, Map<MiniappPermission, PermissionDecision>>{};
    final Map<String, Map<MiniappPermission, MiniappUsage>> usage =
        <String, Map<MiniappPermission, MiniappUsage>>{};
    for (final String id in merged.keys) {
      decisions[id] = <MiniappPermission, PermissionDecision>{
        for (final MiniappPermission p in MiniappPermission.values)
          p: decisionOf(id, p),
      };
      usage[id] = <MiniappPermission, MiniappUsage>{
        for (final MiniappPermission p in MiniappPermission.values)
          p: usageOf(id, p),
      };
    }

    final List<KnownMiniapp> apps = merged.values.toList()
      ..sort((KnownMiniapp a, KnownMiniapp b) {
        final DateTime da =
            a.lastOpenedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        final DateTime db =
            b.lastOpenedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        final int byTime = db.compareTo(da);
        return byTime != 0 ? byTime : a.displayName.compareTo(b.displayName);
      });

    return PermissionScanReport(
      miniapps: apps,
      decisions: decisions,
      usage: usage,
    );
  }
}
