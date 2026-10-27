import 'dart:convert';

import '../storage/records.dart';
import 'vocab.dart';

/// 交换文件的结构性错误：预览页必须拒收整包，而不是部分导入。
class ProtocolException implements Exception {
  final String message;
  const ProtocolException(this.message);
  @override
  String toString() => 'ProtocolException: $message';
}

const int kSupportedSchemaVersion = 1;
const String kAppTag = 'chunkspoke';

/// 协议白名单：只允许已知键进出。
const Set<String> kStatsKeys = {
  'streak',
  'daily_goal',
  'reviewed_today',
  'milestones',
  'funnel',
  'immersion',
  'sandbox',
};

const Set<String> kSettingsKeys = {
  'tts_enabled',
  'voice_id',
  'level_filter',
  'translation_on',
};

/// 本机字段：协议不携带；外来文件出现即忽略并记入报告。
const Set<String> kLocalOnlyChunkKeys = {'l4_self_eval', 'l2_one_try', 'last_score'};

class ChunkExchange {
  final String id;
  final String tier;
  final AssetState assetState;
  final AssetState? assetReturnState;
  final int? assetReturnStage;
  final int reviewStage;
  final int dueDate;
  final int lastReviewAt;
  final int correctStreak;
  final int updatedAt;

  const ChunkExchange({
    required this.id,
    required this.tier,
    required this.assetState,
    this.assetReturnState,
    this.assetReturnStage,
    this.reviewStage = 0,
    this.dueDate = 0,
    this.lastReviewAt = 0,
    this.correctStreak = 0,
    this.updatedAt = 0,
  });

  Map<String, Object?> toJson() => {
        'id': id,
        'tier': tier,
        'asset_state': assetState.wire,
        'asset_return_state': assetReturnState?.wire,
        'asset_return_stage': assetReturnStage,
        'review_stage': reviewStage,
        'due_date': dueDate,
        'last_review_at': lastReviewAt,
        'correct_streak': correctStreak,
        'updated_at': updatedAt,
      };

  static ChunkExchange fromJson(Map<String, Object?> m, List<String> warnings) {
    for (final k in kLocalOnlyChunkKeys) {
      if (m.containsKey(k)) warnings.add('已忽略本机字段 $k（协议不携带自评/打分）');
    }
    final id = m['id'];
    if (id is! String || id.isEmpty) {
      throw const ProtocolException('chunk 缺少 id');
    }
    final tier = m['tier'];
    if (tier is! String) {
      throw ProtocolException('chunk "$id" 的 tier 非法：$tier');
    }
    final stateRaw = m['asset_state'];
    if (stateRaw is! String) {
      throw ProtocolException('chunk "$id" 缺少 asset_state 枚举名');
    }
    final assetState = _parseAssetState(stateRaw, id);

    final returnStateRaw = m['asset_return_state'];
    final returnStageRaw = m['asset_return_stage'];
    if ((returnStateRaw == null) != (returnStageRaw == null)) {
      throw ProtocolException(
        'chunk "$id" 的 asset_return_state / asset_return_stage 必须同时有值或同时为 null',
      );
    }
    if (returnStateRaw != null && returnStateRaw is! String) {
      throw ProtocolException('chunk "$id" 的 asset_return_state 必须是枚举名');
    }
    final returnState = returnStateRaw == null
        ? null
        : _parseAssetState(returnStateRaw as String, id, field: 'asset_return_state');
    int? returnStage;
    if (returnStageRaw != null) {
      if (returnStageRaw is! int || returnStageRaw < 0) {
        throw ProtocolException('chunk "$id" 的 asset_return_stage 非法：$returnStageRaw');
      }
      returnStage = returnStageRaw;
    }

    return ChunkExchange(
      id: id,
      tier: tier,
      assetState: assetState,
      assetReturnState: returnState,
      assetReturnStage: returnStage,
      reviewStage: _int(m, 'review_stage', id),
      dueDate: _int(m, 'due_date', id),
      lastReviewAt: _int(m, 'last_review_at', id),
      correctStreak: _int(m, 'correct_streak', id),
      updatedAt: _int(m, 'updated_at', id),
    );
  }

  static AssetState _parseAssetState(String raw, String id, {String field = 'asset_state'}) {
    try {
      return AssetState.parse(raw);
    } on FormatException catch (e) {
      throw ProtocolException('chunk "$id" 的 $field 非法：${e.message}');
    }
  }

  static int _int(Map<String, Object?> m, String key, String id) {
    final v = m[key];
    if (v == null) return 0;
    if (v is! int) throw ProtocolException('chunk "$id" 的 $key 必须是整数（epoch ms）：$v');
    return v;
  }

  ChunkRecord toRecord({bool orphan = false}) => ChunkRecord(
        id: id,
        tier: tier,
        assetState: assetState,
        assetReturnStateIndex: assetReturnState?.index ?? -1,
        assetReturnStage: assetReturnStage ?? -1,
        reviewStage: reviewStage,
        dueDate: dueDate,
        lastReviewAt: lastReviewAt,
        correctStreak: correctStreak,
        updatedAt: updatedAt,
        orphan: orphan,
      );

  static ChunkExchange fromRecord(ChunkRecord r) => ChunkExchange(
        id: r.id,
        tier: r.tier,
        assetState: r.assetState,
        assetReturnState: r.assetReturnState,
        assetReturnStage: r.assetReturnStage >= 0 ? r.assetReturnStage : null,
        reviewStage: r.reviewStage,
        dueDate: r.dueDate,
        lastReviewAt: r.lastReviewAt,
        correctStreak: r.correctStreak,
        updatedAt: r.updatedAt,
      );
}

class DataPackage {
  final int schemaVersion;
  final String app;
  final String origin;
  final String originVersion;
  final String exportedAt;
  final String deviceTag;
  final Map<String, String> packs;
  final List<ChunkExchange> chunks;
  final Map<String, Object?> stats;
  final List<EventRecord> events;
  final Map<String, Object?> settings;

  /// 解析期发现的可恢复问题（未知键、本机字段等），随预览页展示。
  final List<String> warnings;

  DataPackage({
    this.schemaVersion = kSupportedSchemaVersion,
    this.app = kAppTag,
    required this.origin,
    required this.originVersion,
    required this.exportedAt,
    required this.deviceTag,
    this.packs = const {},
    this.chunks = const [],
    this.stats = const {},
    this.events = const [],
    this.settings = const {},
    this.warnings = const [],
  });

  Map<String, Object?> toJson() => {
        'schema_version': schemaVersion,
        'app': app,
        'origin': origin,
        'origin_version': originVersion,
        'exported_at': exportedAt,
        'device_tag': deviceTag,
        'packs': Map<String, String>.from(packs),
        'chunks': chunks.map((c) => c.toJson()).toList(),
        'stats': Map<String, Object?>.from(stats),
        'events': events.map((e) => e.toMap()).toList(),
        'settings': Map<String, Object?>.from(settings),
      };

  String encode() => const JsonEncoder.withIndent('  ').convert(toJson());

  static DataPackage parse(String raw) {
    Object? root;
    try {
      root = jsonDecode(raw);
    } on FormatException catch (e) {
      throw ProtocolException('不是合法 JSON：${e.message}');
    }
    if (root is! Map) throw const ProtocolException('交换文件顶层必须是对象');
    final m = root.map((k, v) => MapEntry(k.toString(), v));
    final warnings = <String>[];

    final version = m['schema_version'];
    if (version is! int) throw const ProtocolException('缺少 schema_version（整数）');
    if (version > kSupportedSchemaVersion) {
      throw ProtocolException('文件版本 $version 高于本机支持版本 $kSupportedSchemaVersion，请升级网页版');
    }
    final app = m['app'];
    if (app != kAppTag) throw ProtocolException('app 字段必须是 "$kAppTag"：$app');

    final origin = m['origin'];
    if (origin is! String) throw const ProtocolException('缺少 origin（web | android）');
    final originVersion = m['origin_version'];
    final exportedAt = m['exported_at'];
    final deviceTag = m['device_tag'];

    final packs = <String, String>{};
    final packsRaw = m['packs'];
    if (packsRaw is Map) {
      for (final e in packsRaw.entries) {
        final v = e.value;
        if (v is String) packs[e.key.toString()] = v;
      }
    }

    final chunks = <ChunkExchange>[];
    final chunksRaw = m['chunks'];
    if (chunksRaw != null) {
      if (chunksRaw is! List) throw const ProtocolException('chunks 必须是数组');
      for (final item in chunksRaw) {
        if (item is! Map) throw const ProtocolException('chunks[] 必须是对象');
        chunks.add(ChunkExchange.fromJson(item.map((k, v) => MapEntry(k.toString(), v)), warnings));
      }
    }

    final stats = _whitelist(m['stats'], kStatsKeys, 'stats', warnings);
    final settings = _whitelist(m['settings'], kSettingsKeys, 'settings', warnings);

    final events = <EventRecord>[];
    final eventsRaw = m['events'];
    if (eventsRaw != null) {
      if (eventsRaw is! List) throw const ProtocolException('events 必须是数组');
      for (final item in eventsRaw) {
        if (item is! Map) throw const ProtocolException('events[] 必须是对象');
        final em = item.map((k, v) => MapEntry(k.toString(), v));
        final propsRaw = em['props'];
        final props = propsRaw is Map
            ? propsRaw.map((k, v) => MapEntry(k.toString(), v as Object?))
            : <String, Object?>{};
        final grade = props['grade'];
        if (grade != null) {
          try {
            ReviewGrade.parse(grade.toString());
          } on FormatException catch (e) {
            throw ProtocolException('事件 grade 非法：${e.message}');
          }
        }
        final eventId = em['event_id'];
        if (eventId is! String || eventId.isEmpty) {
          throw const ProtocolException('事件缺少 event_id');
        }
        final at = em['at'];
        if (at is! int) throw ProtocolException('事件 "$eventId" 的 at 必须是 epoch ms');
        final name = em['name'];
        if (name is! String || name.isEmpty) {
          throw ProtocolException('事件 "$eventId" 缺少 name');
        }
        events.add(EventRecord(eventId: eventId, at: at, name: name, props: props));
      }
    }

    return DataPackage(
      schemaVersion: version,
      app: app as String,
      origin: origin,
      originVersion: originVersion is String ? originVersion : '',
      exportedAt: exportedAt is String ? exportedAt : '',
      deviceTag: deviceTag is String ? deviceTag : '',
      packs: packs,
      chunks: chunks,
      stats: stats,
      events: events,
      settings: settings,
      warnings: warnings,
    );
  }

  static Map<String, Object?> _whitelist(
    Object? raw,
    Set<String> allow,
    String label,
    List<String> warnings,
  ) {
    final out = <String, Object?>{};
    if (raw == null) return out;
    if (raw is! Map) throw ProtocolException('$label 必须是对象');
    for (final e in raw.entries) {
      final k = e.key.toString();
      if (!allow.contains(k)) {
        warnings.add('$label 未知键已丢弃：$k');
        continue;
      }
      out[k] = e.value;
    }
    return out;
  }
}
