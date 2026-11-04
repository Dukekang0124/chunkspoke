#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""ASR-207 §三.1：CEFR 难度轴回填（Chunk.cefr 487/487 + Level.cefr/stage 20/20）。

数据源（可复核，允许商用、须署名）：
  - CEFR-J Vocabulary Profile v1.5  https://github.com/openlanguageprofiles/olp-en-cefrj
      cefrj-vocabulary-profile-1.5.csv        sha256 b0dd3c635f1c9a4f…（A1/A2/B1/B2）
  - Octanove Vocabulary Profile C1/C2 v1.0（同仓库，补 C1/C2 档；本项目把 C2 归一到 C1）
      octanove-vocabulary-profile-c1c2-1.0.csv sha256 18c33a407f2f89f7…
  版权：Tono Laboratory, Tokyo University of Foreign Studies（CEFR-J 项目）。

判定规则（每条都落进 provenance，方便逐块复核）：
  1. 词块切词 → 小写、去标点；先查原形，再做规则化词形还原（-s/-es/-ed/-ing/-ly/-er/-est
     + 少量不规则映射），取该词所有词性里**最低**的一档（最常用义）。
  2. 词块档位 = 命中的实词里**最高**的那档（难词决定门槛）。
  3. 一个词都没命中 → 用 freqRank 分档兜底（阈值由已命中样本的 freqRank 分布标定，
     provenance 记 `freqRank`，不当作词表证据）。
  4. 模块档位 = 本模块词块档位的众数；`stage` 按 §三.2 映射：
     A1/A2 → L1，B1 → L2，B2/C1 → L3（L0 只给新建的「生存 30 句」模块）。

用法：
  python tools/tag_cefr.py --dry-run      # 只看分布，不写文件
  python tools/tag_cefr.py                # 写回两个 JSON + 生成 provenance
退出码 1 = 无法定档的块数超过 --max-unknown（默认 0）。
"""
import argparse
import sys as _sys
for _s in (_sys.stdout, _sys.stderr):
    try:
        _s.reconfigure(encoding='utf-8', errors='replace')
    except Exception:
        pass
import collections
import csv
import hashlib
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PACK = os.path.join(ROOT, 'assets', 'content_pack.json')
DATA = os.path.join(ROOT, 'tools', 'data')
PROV = os.path.join(ROOT, 'tools', 'data', 'cefr_provenance.json')

RANK_ORDER = ['A1', 'A2', 'B1', 'B2', 'C1']
POS = {r: i for i, r in enumerate(RANK_ORDER)}

IRREGULAR = {
    'goes': 'go', 'went': 'go', 'gone': 'go', 'going': 'go',
    'am': 'be', 'is': 'be', 'are': 'be', 'was': 'be', 'were': 'be', 'been': 'be', 'being': 'be',
    'do': 'do', 'does': 'do', 'did': 'do', 'done': 'do', 'doing': 'do',
    'have': 'have', 'has': 'have', 'had': 'have', 'having': 'have',
    'come': 'come', 'comes': 'come', 'came': 'come', 'coming': 'come',
    'take': 'take', 'takes': 'take', 'took': 'take', 'taken': 'take', 'taking': 'take',
    'make': 'make', 'makes': 'make', 'made': 'make', 'making': 'make',
    'get': 'get', 'gets': 'get', 'got': 'get', 'getting': 'get',
    'say': 'say', 'says': 'say', 'said': 'say', 'saying': 'say',
    'see': 'see', 'sees': 'see', 'saw': 'see', 'seen': 'see', 'seeing': 'see',
    'know': 'know', 'knows': 'know', 'knew': 'know', 'known': 'know',
    'think': 'think', 'thinks': 'think', 'thinking': 'think',
    'want': 'want', 'wants': 'want', 'wanted': 'want', 'wanting': 'want',
    'like': 'like', 'likes': 'like', 'liked': 'like', 'liking': 'like',
    'can': 'can', 'could': 'can', 'will': 'will', 'would': 'will',
    'there': 'there', 'they': 'they', 'them': 'they', 'their': 'they',
    'this': 'this', 'that': 'that', 'these': 'this', 'those': 'this',
    'it': 'it', 'its': 'it', 'you': 'you', 'your': 'you', 'yours': 'you',
    'i': 'i', 'me': 'i', 'my': 'i', 'mine': 'i', 'we': 'we', 'our': 'we',
    'he': 'he', 'him': 'he', 'his': 'he', 'she': 'she', 'her': 'she', 'hers': 'she',
    'ok': 'ok', 'okay': 'ok', 'tv': 'tv', 'photo': 'photo', 'photos': 'photo',
}
STOP = {'please', 'thanks', 'thank', 'yes', 'no', 'not', 'and', 'or', 'but', 'so',
        'of', 'to', 'in', 'on', 'at', 'for', 'with', 'the', 'a', 'an', 'some', 'any'}


def norm_word(w):
    w = w.lower().strip()
    return re.sub(r"[^a-z0-9']", '', w)


def tokens(text):
    return [t for t in (norm_word(x) for x in re.split(r"[^A-Za-z0-9']+", text)) if t]


def load_lexicon():
    lex = {}

    def put(word, level):
        if level not in POS:
            return
        cur = lex.get(word)
        if cur is None or POS[level] < POS[cur]:
            lex[word] = level
    for name in ('cefrj-vocabulary-profile-1.5.csv', 'octanove-vocabulary-profile-c1c2-1.0.csv'):
        p = os.path.join(DATA, name)
        if not os.path.isfile(p):
            sys.exit(f'[缺数据] {p}（先按文件头注释里的地址下载并核对 sha256）')
        with open(p, encoding='utf-8-sig', newline='') as f:
            for row in csv.DictReader(f):
                hw = norm_word(row.get('headword', ''))
                lvl = (row.get('CEFR') or '').strip().upper()
                if not hw or not lvl:
                    continue
                if lvl == 'C2':
                    lvl = 'C1'          # 本项目档位上限 = C1（kCefrKeys）
                if re.fullmatch(r'A[12]|B[12]|C[12]', lvl):
                    put(hw, lvl)
    return lex


def lookup(word, lex):
    if word in lex:
        return lex[word], 'direct'
    if word in IRREGULAR and IRREGULAR[word] in lex:
        return lex[IRREGULAR[word]], 'lemma'
    for suf in ('ies', 'es', 's', 'ed', 'ing', 'ly', 'er', 'est'):
        if word.endswith(suf) and len(word) - len(suf) >= 3:
            stem = word[: -len(suf)]
            cand = stem + ('y' if suf == 'ies' else '')
            for c in (cand, cand + 'e', stem):
                if c in lex:
                    return lex[c], 'lemma'
    return None, ''


def chunk_level(text, lex):
    hits, how = [], []
    for t in tokens(text):
        if t in STOP:
            continue
        lv, mode = lookup(t, lex)
        if lv:
            hits.append(lv)
            how.append(mode)
    if not hits:
        return None, []
    best = max(hits, key=lambda x: POS[x])
    return best, sorted(set(hits), key=lambda x: POS[x])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--dry-run', action='store_true')
    ap.add_argument('--max-unknown', type=int, default=0,
                    help='无法定档（词表未命中且拒绝兜底）的块数上限')
    a = ap.parse_args()

    lex = load_lexicon()
    pack = json.load(open(PACK, encoding='utf-8'))

    # 第一轮：只靠词表；未命中块用「词频最接近的已命中块」定档（k-NN，不拍阈值）。
    first = {}
    for lv in pack['levels']:
        for c in lv['chunks']:
            first[c['id']] = chunk_level(c['text'], lex)
    matched = [(c['freqRank'], lvl) for lv in pack['levels'] for c in lv['chunks']
               if (lvl := first[c['id']][0]) and c.get('freqRank', 0) > 0]
    by_lvl = collections.defaultdict(list)
    for fr, lvl in matched:
        by_lvl[lvl].append(fr)
    med = {lvl: sorted(xs)[len(xs) // 2] for lvl, xs in by_lvl.items()}
    anchors = sorted(matched)                      # (freqRank, level)
    print(f'词表命中 {len(matched)}/{len(first)} 块 · 各档中位词频 {med}')

    def fallback(freq):
        """未命中 → 取词频对数距离最近的已命中块档位。"""
        if not freq or not anchors:
            return None
        import math
        target = math.log(freq)
        best, bestd = None, None
        for fr, lvl in anchors:
            d = abs(math.log(fr) - target)
            if bestd is None or d < bestd:
                best, bestd = lvl, d
        return best

    prov, unknown = {}, 0
    dist = collections.Counter()
    assigned = {}
    for lv in pack['levels']:
        for c in lv['chunks']:
            lvl, how = first[c['id']]
            src = 'cefrj'
            if lvl is None:
                lvl = fallback(c.get('freqRank', 0))
                src = 'freqRank-kNN'
            if lvl is not None:
                assigned[c['id']] = (lvl, src, how)
    # 仍无档（freqRank=0，词表未命中）→ 用同模块众数兜底，provenance 明写 module-modal。
    modals = {}
    for lv in pack['levels']:
        cs = collections.Counter(assigned[c['id']][0] for c in lv['chunks'] if c['id'] in assigned)
        if cs:
            modals[lv['id']] = sorted(cs.items(), key=lambda x: (-x[1], POS[x[0]]))[0][0]
    for lv in pack['levels']:
        for c in lv['chunks']:
            if c['id'] in assigned:
                lvl, src, how = assigned[c['id']]
            else:
                lvl = modals.get(lv['id'], 'A1')
                src = 'module-modal'
                how = []
                unknown += 1
            c['cefr'] = lvl
            dist[lvl] += 1
            prov[c['id']] = {'cefr': lvl, 'source': src, 'words': how,
                             'text': c['text'], 'freqRank': c.get('freqRank', 0)}
    print('块级分布：', dict(sorted(dist.items(), key=lambda x: POS[x[0]])),
          f'· 词表/频频兜底外的模块众数补档 {unknown} 块')
    if unknown > a.max_unknown:
        sys.exit(f'[中止] {unknown} 块靠模块众数补档，超过上限 {a.max_unknown}'
                 '（--max-unknown 可调，但请先看 provenance）')

    # 模块档位：取本模块词块档位的 **75 分位**（众数会把全库压成 A1，
    # 因为最常用词都落在 A1；75 分位能让"B1 多的模块"显出难度）。
    for lv in pack['levels']:
        cs = [POS[c['cefr']] for c in lv['chunks'] if c.get('cefr')]
        if not cs:
            continue
        cs.sort()
        top = RANK_ORDER[cs[min(len(cs) - 1, int(len(cs) * 0.75))]]
        lv['cefr'] = top
        # 人工已声明的 stage 优先（ASR-208 §一.4：L0 生存模块由内容侧钉死，不被算法改回 L1）
        if lv.get('stage') not in ('L0', 'L1', 'L2', 'L3'):
            lv['stage'] = {'A1': 'L1', 'A2': 'L1', 'B1': 'L2', 'B2': 'L3', 'C1': 'L3'}[top]
        print(f"  {lv['id']:>2} {lv['theme'][:20]:<22} cefr={top} stage={lv['stage']} "
              f"构成={dict(sorted(collections.Counter(RANK_ORDER[i] for i in cs).items(), key=lambda x: POS[x[0]]))}")

    if a.dry_run:
        print('[dry-run] 未写入')
        return
    with open(PACK, 'w', encoding='utf-8', newline='\n') as f:
        json.dump(pack, f, ensure_ascii=False, indent=2)
        f.write('\n')
    meta = {'sources': {}, 'medianFreqByLevel': med, 'chunks': prov,
            'chunkDist': dict(dist),
            'license': 'CEFR-J / Tono Laboratory, TUFS（研究商用均可，须署名）'}
    for name in ('cefrj-vocabulary-profile-1.5.csv', 'octanove-vocabulary-profile-c1c2-1.0.csv'):
        h = hashlib.sha256(open(os.path.join(DATA, name), 'rb').read()).hexdigest()
        meta['sources'][name] = h
    os.makedirs(os.path.dirname(PROV), exist_ok=True)
    with open(PROV, 'w', encoding='utf-8', newline='\n') as f:
        json.dump(meta, f, ensure_ascii=False, indent=2)
        f.write('\n')
    print(f'✓ 已写回 {os.path.relpath(PACK, ROOT)} 与 {os.path.relpath(PROV, ROOT)}')


if __name__ == '__main__':
    main()
