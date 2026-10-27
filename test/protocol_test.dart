import 'dart:convert';

import 'package:chunkspoke_web/data/protocol.dart';
import 'package:chunkspoke_web/data/vocab.dart';
import 'package:chunkspoke_web/storage/records.dart';
import 'package:flutter_test/flutter_test.dart';

DataPackage _sample() => DataPackage(
      origin: 'web',
      originVersion: '0.9.0-web',
      exportedAt: '2026-11-03T12:00:00+08:00',
      deviceTag: 'a1b2c3',
      packs: {'content': '1.2.0', 'listening': '2'},
      chunks: const [
        ChunkExchange(
          id: 'get up',
          tier: 'T0',
          assetState: AssetState.relearning,
          assetReturnState: AssetState.consolidated,
          assetReturnStage: 2,
          reviewStage: 1,
          dueDate: 1730000000000,
          lastReviewAt: 1729990000000,
          correctStreak: 2,
          updatedAt: 1729990000000,
        ),
        ChunkExchange(
          id: 'make a decision',
          tier: 'T1',
          assetState: AssetState.mastered,
          reviewStage: 4,
          dueDate: 0,
        ),
      ],
      stats: const {'streak': 0, 'daily_goal': 5, 'reviewed_today': 3},
      events: [
        EventRecord(
          eventId: 'evt-1',
          at: 1729990000000,
          name: 'review_eval',
          props: const {'chunk_id': 'get up', 'grade': 'pass', 'stage_after': 2},
        ),
      ],
      settings: const {'tts_enabled': true, 'voice_id': 'hd-voice-piper-en-us-medium'},
    );

Map<String, Object?> _decode(String raw) => DataPackage.parse(raw).toJson();

void main() {
  group('交换文件往返', () {
    test('encode → parse → toJson 逐字段一致（含需重修返回位）', () {
      final original = _sample().toJson();
      final reparsed = _decode(_sample().encode());
      expect(reparsed, equals(original));
      final chunk = (reparsed['chunks'] as List).first as Map;
      expect(chunk['asset_state'], 'relearning');
      expect(chunk['asset_return_state'], 'consolidated');
      expect(chunk['asset_return_stage'], 2);
    });

    test('需重修返回位经本机行往返后不丢', () {
      final exchange = _sample().chunks.first;
      final record = exchange.toRecord();
      expect(record.assetReturnStateIndex, AssetState.consolidated.index);
      expect(record.assetReturnStage, 2);
      final back = ChunkExchange.fromRecord(record);
      expect(back.toJson(), equals(exchange.toJson()));
    });

    test('无返回位时两列均为 null（本机 -1 ↔ 协议 null）', () {
      final record = const ChunkRecord(
        id: 'get up',
        tier: 'T0',
        assetState: AssetState.consolidating,
      );
      final json = ChunkExchange.fromRecord(record).toJson();
      expect(json['asset_return_state'], isNull);
      expect(json['asset_return_stage'], isNull);
      final parsed = ChunkExchange.fromJson(json, []);
      expect(parsed.toRecord().assetReturnStateIndex, -1);
      expect(parsed.toRecord().assetReturnStage, -1);
    });
  });

  group('硬校验', () {
    test('中文标签进入协议即判非法文件', () {
      final json = _sample().toJson();
      final chunk = (json['chunks'] as List).first as Map;
      chunk['asset_state'] = '巩固中';
      expect(
        () => DataPackage.parse(_encode(json)),
        throwsA(isA<ProtocolException>().having(
          (e) => e.message,
          'message',
          contains('巩固中'),
        )),
      );
    });

    test('asset_return_state 与 stage 必须同时有值', () {
      final json = _sample().toJson();
      final chunk = (json['chunks'] as List).first as Map;
      chunk['asset_return_stage'] = null;
      expect(() => DataPackage.parse(_encode(json)), throwsA(isA<ProtocolException>()));
    });

    test('数字档位不得冒充 grade', () {
      final json = _sample().toJson();
      final event = (json['events'] as List).first as Map;
      (event['props'] as Map)['grade'] = 1;
      expect(
        () => DataPackage.parse(_encode(json)),
        throwsA(isA<ProtocolException>().having(
          (e) => e.message,
          'message',
          contains('grade'),
        )),
      );
    });

    test('schema_version 高于本机 → 整包拒绝', () {
      final json = _sample().toJson();
      json['schema_version'] = 2;
      expect(
        () => DataPackage.parse(_encode(json)),
        throwsA(isA<ProtocolException>().having(
          (e) => e.message,
          'message',
          contains('请升级'),
        )),
      );
    });

    test('外来本机字段被忽略并记入 warnings', () {
      final json = _sample().toJson();
      final chunk = (json['chunks'] as List).first as Map;
      chunk['l4_self_eval'] = 1;
      chunk['last_score'] = 99;
      final parsed = DataPackage.parse(_encode(json));
      expect(parsed.warnings.any((w) => w.contains('l4_self_eval')), isTrue);
      expect(parsed.warnings.any((w) => w.contains('last_score')), isTrue);
      expect((parsed.chunks.first.toJson()).containsKey('last_score'), isFalse);
    });

    test('settings 白名单外的键丢弃并记 warnings', () {
      final json = _sample().toJson();
      (json['settings'] as Map)['glm_key'] = 'should-not-enter';
      final parsed = DataPackage.parse(_encode(json));
      expect(parsed.settings.containsKey('glm_key'), isFalse);
      expect(parsed.warnings.any((w) => w.contains('glm_key')), isTrue);
    });
  });
}

String _encode(Map<String, Object?> json) => jsonEncode(json);
