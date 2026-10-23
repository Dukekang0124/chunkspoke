import '../models/listening_article.dart';
import 'listening_store.dart';

/// 磨耳朵首页的纯数据模型（无 I/O，便于按日锁定推荐口径）。
///
/// 口径：
/// - 推荐只认最近 7 天的收听行为，固定三张卡：今日篇目 / 昨天听过 / 隔天重逢；
/// - 今日篇目按「当天 + 未听优先」确定性轮换，同一天多次进入结果不变；
/// - 不展示进度百分比，也不出现 Day N 编号；
/// - 全部篇目都听过视为「无新内容日」，由首页引导去词块库复习。
enum ListeningPickKind { today, yesterday, reunion }

class ListeningPick {
  final ListeningPickKind kind;
  final ListeningArticle article;
  final String label;
  final String hint;

  const ListeningPick({
    required this.kind,
    required this.article,
    required this.label,
    required this.hint,
  });
}

class ListeningResume {
  final ListeningArticle article;
  final int positionMs;
  final int sentenceIndex;
  final bool completed;

  const ListeningResume({
    required this.article,
    required this.positionMs,
    required this.sentenceIndex,
    required this.completed,
  });
}

class ListeningSceneGroup {
  final String scene;
  final String label;
  final List<ListeningArticle> articles;

  const ListeningSceneGroup({
    required this.scene,
    required this.label,
    required this.articles,
  });
}

class ListeningHomeData {
  final List<ListeningPick> picks;
  final ListeningResume? resume;
  final List<ListeningArticle> recent;
  final List<ListeningSceneGroup> scenes;
  final bool noNewContent;
  final int dueReviews;
  final Map<String, int> lastListenedAt;
  final Set<String> completedIds;

  const ListeningHomeData({
    required this.picks,
    required this.resume,
    required this.recent,
    required this.scenes,
    required this.noNewContent,
    required this.dueReviews,
    required this.lastListenedAt,
    required this.completedIds,
  });
}

ListeningHomeData buildListeningHome({
  required List<ListeningArticle> articles,
  required Map<String, int> lastListenedAt,
  required Map<String, ListeningPosition> positions,
  required Set<String> completedIds,
  required Set<String> learnedChunkIds,
  required DateTime now,
  int dueReviews = 0,
}) {
  final byId = {for (final a in articles) a.id: a};
  final todayStart = _dayStart(now);
  final tomorrowStart = _dayStart(now.add(const Duration(days: 1)));
  final yesterdayStart = _dayStart(now.subtract(const Duration(days: 1)));

  bool heardToday(ListeningArticle a) {
    final ts = lastListenedAt[a.id];
    if (ts == null) return false;
    return ts >= todayStart.millisecondsSinceEpoch &&
        ts < tomorrowStart.millisecondsSinceEpoch;
  }

  ListeningArticle? yesterdayPick() {
    String? bestId;
    var bestTs = -1;
    for (final e in lastListenedAt.entries) {
      if (!byId.containsKey(e.key)) continue;
      if (e.value < yesterdayStart.millisecondsSinceEpoch ||
          e.value >= todayStart.millisecondsSinceEpoch) {
        continue;
      }
      if (e.value > bestTs) {
        bestTs = e.value;
        bestId = e.key;
      }
    }
    return bestId == null ? null : byId[bestId];
  }

  final yesterday = yesterdayPick();
  final today = _todayPick(
    articles,
    heardToday,
    yesterday?.id,
    lastListenedAt,
    now,
  );

  final picks = <ListeningPick>[];
  if (today != null) {
    picks.add(ListeningPick(
      kind: ListeningPickKind.today,
      article: today,
      label: '今日篇目',
      hint: lastListenedAt.containsKey(today.id) ? '换个场景再听一遍' : '今天从这篇开始',
    ));
  }
  if (yesterday != null) {
    picks.add(ListeningPick(
      kind: ListeningPickKind.yesterday,
      article: yesterday,
      label: '昨天听过',
      hint: '接着昨天的场景再听',
    ));
  }

  final reunion = _reunionPick(
    articles,
    learnedChunkIds,
    lastListenedAt,
    yesterdayStart.millisecondsSinceEpoch,
    {today?.id, yesterday?.id},
  );
  if (reunion != null) {
    final learned = _learnedCount(reunion, learnedChunkIds);
    picks.add(ListeningPick(
      kind: ListeningPickKind.reunion,
      article: reunion,
      label: '隔天重逢',
      hint: '含 $learned 个已学词块',
    ));
  }

  ListeningResume? resume;
  var bestResumeTs = -1;
  for (final e in positions.entries) {
    final article = byId[e.key];
    if (article == null) continue;
    final p = e.value;
    if (p.positionMs <= 0 && p.sentenceIndex <= 0) continue;
    if (p.updatedAt > bestResumeTs) {
      bestResumeTs = p.updatedAt;
      resume = ListeningResume(
        article: article,
        positionMs: p.positionMs,
        sentenceIndex: p.sentenceIndex,
        completed: completedIds.contains(article.id),
      );
    }
  }

  final recent = [...articles]..sort(_recentOrder);
  final scenes = _sceneGroups(recent);
  final allHeard = articles.isNotEmpty &&
      articles.every((a) =>
          lastListenedAt.containsKey(a.id) || completedIds.contains(a.id));

  return ListeningHomeData(
    picks: picks,
    resume: resume,
    recent: recent,
    scenes: scenes,
    noNewContent: allHeard,
    dueReviews: dueReviews,
    lastListenedAt: Map.unmodifiable(lastListenedAt),
    completedIds: Set.unmodifiable(completedIds),
  );
}

ListeningArticle? _todayPick(
  List<ListeningArticle> articles,
  bool Function(ListeningArticle) heardToday,
  String? yesterdayId,
  Map<String, int> lastListenedAt,
  DateTime now,
) {
  var pool = articles
      .where((a) => !heardToday(a) && a.id != yesterdayId)
      .toList();
  if (pool.isEmpty) {
    pool = articles.where((a) => a.id != yesterdayId).toList();
  }
  if (pool.isEmpty) pool = [...articles];
  if (pool.isEmpty) return null;

  final unheard =
      pool.where((a) => !lastListenedAt.containsKey(a.id)).toList();
  final base = unheard.isNotEmpty ? unheard : pool;
  base.sort(_recentOrder);
  final day = _dayStart(now).difference(DateTime(2020)).inDays;
  return base[day % base.length];
}

ListeningArticle? _reunionPick(
  List<ListeningArticle> articles,
  Set<String> learnedChunkIds,
  Map<String, int> lastListenedAt,
  int yesterdayStartMs,
  Set<String?> exclude,
) {
  final candidates = articles
      .where((a) =>
          !exclude.contains(a.id) &&
          _learnedCount(a, learnedChunkIds) > 0 &&
          (lastListenedAt[a.id] == null ||
              lastListenedAt[a.id]! < yesterdayStartMs))
      .toList();
  if (candidates.isEmpty) return null;
  candidates.sort((a, b) {
    final byCount = _learnedCount(b, learnedChunkIds)
        .compareTo(_learnedCount(a, learnedChunkIds));
    if (byCount != 0) return byCount;
    final at = lastListenedAt[a.id] ?? 0;
    final bt = lastListenedAt[b.id] ?? 0;
    if (at != bt) return at.compareTo(bt);
    return _recentOrder(a, b);
  });
  return candidates.first;
}

int _learnedCount(ListeningArticle a, Set<String> learnedChunkIds) =>
    a.chunks.where((c) => learnedChunkIds.contains(c.id)).length;

int _recentOrder(ListeningArticle a, ListeningArticle b) {
  final ad = a.updatedDate;
  final bd = b.updatedDate;
  if (ad == null && bd == null) return a.id.compareTo(b.id);
  if (ad == null) return 1;
  if (bd == null) return -1;
  final byDate = bd.compareTo(ad);
  return byDate != 0 ? byDate : a.id.compareTo(b.id);
}

List<ListeningSceneGroup> _sceneGroups(List<ListeningArticle> recent) {
  final order = <String>[];
  final grouped = <String, List<ListeningArticle>>{};
  final labels = <String, String>{};
  for (final a in recent) {
    if (!grouped.containsKey(a.scene)) {
      order.add(a.scene);
      grouped[a.scene] = [];
      labels[a.scene] = a.sceneLabel.isNotEmpty ? a.sceneLabel : a.scene;
    }
    grouped[a.scene]!.add(a);
  }
  return [
    for (final scene in order)
      ListeningSceneGroup(
        scene: scene,
        label: labels[scene]!,
        articles: grouped[scene]!,
      ),
  ];
}

DateTime _dayStart(DateTime d) => DateTime(d.year, d.month, d.day);
