
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/globals.dart';
import '../../data/models/app_item.dart';
import '../../data/models/category.dart';
import '../../data/models/market_feed.dart';
import '../../data/repositories/market_repository.dart';
import '../../data/services/market_cache_service.dart';
import '../../theme/app_theme.dart';

enum HomeStatus {
  /// 还没发起过请求
  initial,

  /// 正在加载
  loading,

  /// 有数据（可能为空市场）
  ready,

  /// 加载失败且没有任何旧数据可展示
  error,
}

class HomeController extends ChangeNotifier {
  HomeController(this._repository, {MarketCacheService? cache})
    : _cache = cache ?? MarketCacheService.maybeInstance;

  final MarketRepository _repository;

  /// 本地分页缓存。null = 还没初始化（单测里可以直接不传）
  final MarketCacheService? _cache;

  HomeStatus _status = HomeStatus.initial;

  /// 已加载的全部应用（跨页累积）
  List<AppItem> _apps = const <AppItem>[];

  /// 分类（只在第一页返回，之后一直复用）
  List<AppCategory> _categories = const <AppCategory>[];

  DateTime? _updatedAt;

  String? _errorMessage;
  String? _errorDetail;
  String _query = '';
  String _categoryId = AppCategory.allId;

  /// 下一页游标；null 表示没有更多
  String? _nextCursor;

  /// 是否正在加载下一页（防止滚到底时并发触发多次）
  bool _loadingMore = false;

  /// 是否还有更多
  bool _hasMore = false;

  /// 服务端实际使用的每页条数（第一次响应里的 meta.limit）。
  /// 0 = 还不知道，此时请求不带 limit，让服务端用自己的默认值。
  int _pageLimit = 0;

  /// 当前列表是不是「从本地缓存恢复的」。
  ///
  /// 只用于页脚文案（「显示的是上次缓存」）—— 缓存会在随后的一次
  /// 静默刷新里被服务端数据覆盖，所以它是个瞬时状态。
  bool _fromCache = false;

  bool get fromCache => _fromCache;

  HomeStatus get status => _status;
  String? get errorMessage => _errorMessage;
  String? get errorDetail => _errorDetail;
  String get query => _query;
  String get categoryId => _categoryId;

  /// 已加载的应用（跨页累积，顺序就是服务端给的顺序）
  List<AppItem> get apps => _apps;

  /// 已加载数量。页脚文案与计数都用它。
  int get loadedCount => _apps.length;

  DateTime? get updatedAt => _updatedAt;

  bool get isLoading => _status == HomeStatus.loading;
  bool get hasData => _apps.isNotEmpty;

  /// 是否正在加载下一页
  bool get loadingMore => _loadingMore;

  /// 是否还有更多页
  bool get hasMore => _hasMore;

  /// 分类 chip 的数据（第一项固定是「全部」）
  List<AppCategory> get chipCategories {
    const AppCategory all = AppCategory(id: AppCategory.allId, name: '全部');
    if (_categories.isEmpty) return const <AppCategory>[all];
    return <AppCategory>[all, ..._categories];
  }

  int countFor(String categoryId) {
    if (categoryId == AppCategory.allId) return _apps.length;
    return _apps.where((AppItem app) => app.category == categoryId).length;
  }

  /// 经过「分类 + 关键词」双重过滤后的列表
  ///
  /// 服务端已经按分类筛过了（`fetchFeed(category:)`），所以这里的分类判断
  /// 只用于「服务端没筛的情况」（缓存/切换瞬间）。关键词过滤同理：
  /// 主页不再提供边输入边过滤，搜索在独立页面里走服务端。
  List<AppItem> get visibleApps {
    final String keyword = _query.trim().toLowerCase();
    if (keyword.isEmpty && _categoryId == AppCategory.allId) return _apps;
    return _apps
        .where((AppItem app) {
          if (_categoryId != AppCategory.allId && app.category != _categoryId) {
            return false;
          }
          if (keyword.isEmpty) return true;
          return app.searchBlob.contains(keyword);
        })
        .toList(growable: false);
  }

  /// 有数据，但被筛选条件过滤空了（与「市场本身没数据」是两种提示）
  bool get isFilteredEmpty => hasData && visibleApps.isEmpty;

  Future<void> ensureLoaded() async {
    if (_status != HomeStatus.initial) return;

    final CachedFeed? cached = _cache?.readFeed(_categoryId);
    if (cached != null) {
      _apps = cached.apps;
      _categories = cached.categories;
      _nextCursor = cached.nextCursor;
      _hasMore = cached.hasMore;
      _pageLimit = cached.limit;
      _updatedAt = cached.savedAt;
      _status = HomeStatus.ready;
      _fromCache = true;
      lemonLog('Home', '从缓存恢复 ${cached.apps.length} 个应用');
      notifyListeners();
    }

    await load(silent: _apps.isNotEmpty);
  }

  Future<void> load({bool silent = false}) async {
    if (!silent || _apps.isEmpty) {
      _status = HomeStatus.loading;
    }
    _errorMessage = null;
    _errorDetail = null;
    notifyListeners();

    try {
      await _loadFirstPage();
    } on MarketException catch (e) {
      _handleError(e.message, e.detail);
    } catch (e) {
      _handleError('加载失败：$e', null);
    }

    notifyListeners();
  }

  Future<void> _reloadFirstPage() async {
    try {
      await _loadFirstPage();
    } on MarketException catch (e) {
      AppTheme.showToast(e.message, isError: true);
    } catch (e) {
      AppTheme.showToast('切换分类失败：$e', isError: true);
    }
    notifyListeners();
  }

  Future<void> _loadFirstPage() async {
    final MarketFeedPage page = await _repository.fetchFeed(
      limit: _pageLimit > 0 ? _pageLimit : null,
      category: _categoryId,
    );

    // 分类只在第一页返回；后续页不带，所以这里要保留旧值。
    if (page.categories.isNotEmpty) _categories = page.categories;
    if (page.limit > 0) _pageLimit = page.limit;
    _apps = page.apps;
    _nextCursor = page.nextCursor;
    _hasMore = page.hasMore && page.nextCursor != null;
    _updatedAt = DateTime.now();
    _status = HomeStatus.ready;
    _fromCache = false;
    unawaited(_saveCache());

    // 选中的分类在新数据里可能已经没了（市场改版 / 换了服务器）
    if (_categoryId != AppCategory.allId &&
        !_categories.any((AppCategory c) => c.id == _categoryId)) {
      _categoryId = AppCategory.allId;
    }
    lemonLog('Home', '第一页：${page.apps.length} 个，hasMore=$_hasMore');
  }

  /// 加载下一页（滚到底部时由 _LoadMoreTrigger 调用）
  Future<void> loadMore() async {
    if (_loadingMore || !_hasMore) return;
    if (_nextCursor == null) return;

    _loadingMore = true;
    notifyListeners();
    try {
      final MarketFeedPage page = await _repository.fetchFeed(
        limit: _pageLimit > 0 ? _pageLimit : null,
        cursor: _nextCursor,
        category: _categoryId,
      );

      // 追加并去重：游标分页理论上不会重复，但服务端数据变动时
      // 仍可能出现「下一页包含了上一页最后一条」，重复卡片很难看。
      final Set<String> existing = _apps.map((AppItem a) => a.id).toSet();
      _apps = <AppItem>[
        ..._apps,
        ...page.apps.where((AppItem a) => !existing.contains(a.id)),
      ];
      _nextCursor = page.nextCursor;
      _hasMore = page.hasMore && page.nextCursor != null;
      if (page.limit > 0) _pageLimit = page.limit;
      unawaited(_saveCache());
    } on MarketException catch (e) {
      // 加载下一页失败不该把已有列表清空，只提示一句
      AppTheme.showToast(e.message, isError: true);
    } catch (e) {
      AppTheme.showToast('加载更多失败：$e', isError: true);
    } finally {
      _loadingMore = false;
      notifyListeners();
    }
  }

  /// 已有旧数据时，刷新失败不清空列表，只用浮层提示，避免「刷一下全没了」的体验。
  void _handleError(String message, String? detail) {
    _errorMessage = message;
    _errorDetail = detail;
    if (_apps.isNotEmpty) {
      _status = HomeStatus.ready;
      AppTheme.showToast(message, isError: true);
    } else {
      _status = HomeStatus.error;
    }
  }

  // ------------------------------------------------------------- 筛选

  void search(String keyword) {
    if (_query == keyword) return;
    _query = keyword;
    notifyListeners();
  }

  void selectCategory(String categoryId) {
    if (_categoryId == categoryId) return;
    _categoryId = categoryId;
    notifyListeners();
    // 分类是**服务端筛的**（不会把全部应用拉下来再本地过滤），
    // 所以换分类必须重新请求第一页。
    _reloadFirstPage();
  }

  /// 把当前已加载的列表写进本地缓存（失败不影响任何功能）
  Future<void> _saveCache() async {
    final MarketCacheService? cache = _cache;
    if (cache == null || _apps.isEmpty) return;
    try {
      await cache.saveFeed(
        category: _categoryId,
        apps: _apps,
        categories: _categories,
        nextCursor: _nextCursor,
        hasMore: _hasMore,
        limit: _pageLimit,
      );
    } catch (e) {
      lemonLog('Home', '写缓存失败（忽略）：$e');
    }
  }

  /// 清掉当前分类的缓存（手动刷新 / 换服务器时由外部调用）
  Future<void> clearCache() async {
    await _cache?.clear();
  }

  void clearFilters() {
    if (_query.isEmpty && _categoryId == AppCategory.allId) return;
    _query = '';
    _categoryId = AppCategory.allId;
    notifyListeners();
  }
}
