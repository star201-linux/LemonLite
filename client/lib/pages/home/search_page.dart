// lib/pages/home/search_page.dart
//
// 搜索页：关键词 + 标签筛选 + 分页。
//
// 为什么单独一页而不是继续在主页的搜索框上做本地过滤：
//   搜索是**服务端筛的**（不会把全部应用拉到本地），
//   而「标签 chip」需要服务端返回的命中标签计数 —— 这两件事都超出
//   「在已有列表上 filter 一下」的范围。放在独立页面里，
//   主页保持「推荐流」的单一职责。
//
// 0.5 起没有任何「本地搜索」分支：只有服务端一种后端。

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../data/models/app_item.dart';
import '../../data/models/market_feed.dart';
import '../../data/repositories/market_repository.dart';
import '../../data/services/market_cache_service.dart';
import '../../theme/motion.dart';
import '../detail/app_detail_page.dart';
import 'widgets/app_card.dart';
import 'widgets/state_views.dart';
import '../../theme/loading.dart';

class SearchPage extends StatefulWidget {
  const SearchPage({super.key, this.initialQuery = ''});

  /// 从主页带过来的关键词（主页搜索框里已经输入的）
  final String initialQuery;

  static Route<void> route({String initialQuery = ''}) =>
      MaterialPageRoute<void>(
        builder: (BuildContext context) =>
            SearchPage(initialQuery: initialQuery),
      );

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  late final TextEditingController _input = TextEditingController(
    text: widget.initialQuery,
  );

  /// 输入防抖：每敲一个字都发请求会把服务端打满，
  /// 也会让「正在输入」时的列表疯狂跳动。
  Timer? _debounce;

  /// 当前结果
  MarketSearchPage? _page;

  /// 全量标签（未搜索时的 chip）
  List<MarketTag> _allTags = const <MarketTag>[];

  /// 选中的标签 slug（'' = 不限）
  String _activeTag = '';

  /// 是否加载中 / 是否还有更多
  bool _loading = false;
  bool _loadingMore = false;

  /// 当前结果是不是缓存（页脚会注明「本地缓存」，让用户知道还没联网刷新完）
  bool _fromCache = false;

  String? _error;

  /// 请求序号：只接受最后一次请求的响应。
  /// 没有它的话，快速输入时「旧的关键词的结果」会覆盖「新的关键词的结果」。
  int _requestSeq = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _input.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    final MarketRepository repo = context.read<MarketRepository>();
    _allTags = await repo.fetchTags();
    if (!mounted) return;
    await _load();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      _load();
    });
  }

  Future<void> _load() async {
    final int seq = ++_requestSeq;
    final String query = _input.text;
    final String tag = _activeTag;

    // ---- 1. 先看缓存：同一组「关键词 + 标签」的结果直接铺上，
    //         用户不会为了一次网络往返看一屏转圈。
    final CachedSearch? cached = MarketCacheService.maybeInstance?.readSearch(
      query: query,
      tag: tag,
    );
    if (cached != null && cached.apps.isNotEmpty) {
      setState(() {
        _page = MarketSearchPage(
          apps: cached.apps,
          tags: cached.tags,
          total: cached.total,
          hasMore: cached.hasMore,
          query: cached.query,
          activeTag: cached.tag,
          limit: cached.limit,
        );
        _loading = false;
        _error = null;
        _fromCache = true;
      });
    } else {
      setState(() {
        _loading = true;
        _error = null;
      });
    }

    // ---- 2. 再走网络（静默刷新：缓存已经在屏幕上时不再闪 loading）
    try {
      // 首屏不带 limit：让服务端按面板配置决定每页条数。
      // 后续页才用响应里返回的 limit（见 _loadMore）。
      final MarketSearchPage page = await context
          .read<MarketRepository>()
          .search(query: query, tag: tag);
      if (!mounted || seq != _requestSeq) return; // 丢弃过期响应
      setState(() {
        _page = page;
        _loading = false;
        _fromCache = false;
      });
      unawaited(_saveCache(page));
    } on MarketException catch (e) {
      if (!mounted || seq != _requestSeq) return;
      // 有缓存时网络失败不该把结果清掉：提示一句，列表继续用缓存
      if (cached != null && cached.apps.isNotEmpty) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('刷新失败，显示的是本地缓存：${e.message}')));
        return;
      }
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || seq != _requestSeq) return;
      setState(() {
        _error = '搜索失败：$e';
        _loading = false;
      });
    }
  }

  Future<void> _saveCache(MarketSearchPage page) async {
    final MarketCacheService? cache = MarketCacheService.maybeInstance;
    if (cache == null || page.apps.isEmpty) return;
    try {
      await cache.saveSearch(
        query: page.query.isEmpty ? _input.text : page.query,
        tag: _activeTag,
        apps: page.apps,
        tags: page.tags,
        total: page.total,
        hasMore: page.hasMore,
        limit: page.limit,
      );
    } catch (_) {
      // 缓存只是加速，失败不影响搜索
    }
  }

  /// 加载下一页
  Future<void> _loadMore() async {
    final MarketSearchPage? page = _page;
    if (page == null || !page.hasMore) return;
    if (_loadingMore) return;

    setState(() => _loadingMore = true);
    try {
      final MarketSearchPage next = await context
          .read<MarketRepository>()
          .search(
            query: _input.text,
            tag: _activeTag,
            limit: page.limit > 0 ? page.limit : null,
            offset: (page.apps.length),
          );
      if (!mounted) return;
      final MarketSearchPage merged = MarketSearchPage(
        apps: <AppItem>[...page.apps, ...next.apps],
        tags: next.tags,
        total: next.total,
        hasMore: next.hasMore,
        query: next.query,
        activeTag: next.activeTag,
        limit: next.limit > 0 ? next.limit : page.limit,
      );
      setState(() {
        _page = merged;
        _fromCache = false;
      });
      unawaited(_saveCache(merged));
    } on MarketException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  void _selectTag(String slug) {
    setState(() => _activeTag = slug);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: SearchBar(
          controller: _input,
          autoFocus: widget.initialQuery.isEmpty,
          hintText: '搜索应用名称、作者或标签',
          leading: const Icon(Icons.search),
          trailing: <Widget>[
            if (_input.text.isNotEmpty)
              IconButton(
                tooltip: '清除',
                icon: const Icon(Icons.close),
                onPressed: () {
                  _input.clear();
                  _load();
                },
              ),
          ],
          onChanged: _onChanged,
          onSubmitted: (String _) => _load(),
          elevation: const WidgetStatePropertyAll<double>(0),
          backgroundColor: WidgetStatePropertyAll<Color>(
            scheme.surfaceContainerHigh,
          ),
        ),
        actions: <Widget>[
          IconButton(
            tooltip: '清空搜索',
            icon: const Icon(Icons.refresh),
            onPressed: () {
              _input.clear();
              setState(() => _activeTag = '');
              _load();
            },
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          // 标签 chips：服务端模式用「命中结果的标签」，
          // 静态模式用本地统计出来的标签
          if (_tagsToShow.isNotEmpty) _tagBar(scheme),
          Expanded(child: _body(context)),
        ],
      ),
    );
  }

  List<MarketTag> get _tagsToShow {
    final MarketSearchPage? page = _page;
    // 已经选了标签：显示全量（否则用户被自己选中的标签锁死，
    // 只能先点「全部」才能换 —— 很别扭）
    if (_activeTag.isNotEmpty) {
      return _allTags.isNotEmpty
          ? _allTags
          : (page?.tags ?? const <MarketTag>[]);
    }
    // 没选标签：优先显示「命中结果里的标签」，没有就用全量
    if (page != null && page.tags.isNotEmpty) return page.tags;
    return _allTags;
  }

  Widget _tagBar(ColorScheme scheme) {
    return SizedBox(
      height: 48,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: FilterChip(
              label: const Text('全部'),
              selected: _activeTag.isEmpty,
              onSelected: (_) => _selectTag(''),
            ),
          ),
          for (final MarketTag tag in _tagsToShow)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: FilterChip(
                label: Text(
                  tag.count > 0 ? '${tag.name} ${tag.count}' : tag.name,
                ),
                selected: _activeTag == tag.slug,
                onSelected: (bool on) => _selectTag(on ? tag.slug : ''),
              ),
            ),
        ],
      ),
    );
  }

  Widget _body(BuildContext context) {
    if (_loading) {
      return const LoadingView(message: '正在搜索…');
    }
    if (_error != null) {
      return ErrorView(title: '搜索失败', message: _error!, onRetry: _load);
    }

    final MarketSearchPage? page = _page;
    if (page == null || page.apps.isEmpty) {
      return EmptyView(
        icon: Icons.search_off,
        title: _input.text.trim().isEmpty && _activeTag.isEmpty
            ? '输入关键词开始搜索'
            : '没有匹配的应用',
        message: _input.text.trim().isEmpty && _activeTag.isEmpty
            ? '可以搜应用名、作者，或者点上面的标签'
            : '换个关键词，或者取消标签筛选试试',
        actionLabel: '清空条件',
        onAction: () {
          _input.clear();
          setState(() => _activeTag = '');
          _load();
        },
      );
    }

    return NotificationListener<ScrollNotification>(
      onNotification: (ScrollNotification n) {
        // 快到底部时预加载下一页
        if (n.metrics.pixels >= n.metrics.maxScrollExtent - 400) {
          _loadMore();
        }
        return false;
      },
      child: ListView.builder(
        padding: const EdgeInsets.only(bottom: 24),
        itemCount: page.apps.length + 1,
        itemBuilder: (BuildContext ctx, int i) {
          if (i == page.apps.length) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Center(
                child: _loadingMore
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: M3ELoadingIndicator(),
                      )
                    : Text(
                        page.hasMore
                            ? '继续下滑加载更多'
                            : '共 ${page.total} 个结果${_fromCache ? '（本地缓存）' : ''}',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
              ),
            );
          }
          final AppItem app = page.apps[i];
          return Padding(
            padding: EdgeInsets.fromLTRB(16, i == 0 ? 8 : 0, 16, 8),
            // 搜索结果同样是错峰淡入：一屏结果一次全刷出来会显得很「跳」
            child: StaggeredEntrance(
              index: i % 8,
              child: AppCard(
                app: app,
                onTap: () {
                  HapticFeedback.selectionClick();
                  Navigator.of(ctx).push(AppDetailPage.route(app));
                },
              ),
            ),
          );
        },
      ),
    );
  }
}
