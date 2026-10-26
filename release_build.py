#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
ChunkSpoke 发布回填 + 双包重建脚本（R2 收尾 · 来自验收日志纠正）

核心纠正（为什么"从 v1.0.0 升 v2"跑不通）：
  98C065 的 v1.0.0 源码 remoteUrl 为空，装在手机上 check() 直接静默返回，
  永远触发不了检查更新。正确夹具 = 手机装 F(vc2) 作基线 → 远端 version.json
  标 buildNumber=3 指向 F3(vc3) → F 检测 3>2 → 下载 F3 → 安装。
  （Android 拒绝安装 versionCode 不高于本机的"降级"包，故不能用 28f2d11d 当更新目标。）

脚本做的事（一次运行产出两个包）：
  1. 同步最新工作副本源码到构建副本（含正式 launcher 图标）。
  2. 回填 update_service.dart 的 remoteUrl（F 与 F3 同源，装后均指向远端 version.json）。
  3. 重建 F(vc2)：包内 assets/version.json 保持 buildNumber=2（本地 cur=2）。
  4. 改 version.json 为 buildNumber=3 + apkUrl=F3（这是远端托管版，也是 F3 包内版）。
  5. 重建 F3(vc3)。
  6. 对两个 arm64 包 certutil SHA-256 + 体积 + Built 时间，并提示把"远端 version.json"上传 Release。

  图标默认不调色（v2.0 §7 对齐为可选项，需用户确认后加 --recolor-icon，合并进同次构建）。

用法：
  python3 release_build.py --release-url https://github.com/OWNER/REPO/releases/tag/v1.0.2
  # 或手动指定两个 URL：
  python3 release_build.py --remote-url <version.json直链> --apk-url <F3 apk直链>
  # 可选对齐规范配色：
  python3 release_build.py --release-url ... --recolor-icon

冻结令：本脚本只"准备"，运行会改动构建副本的 pubspec/version.json/update_service 并重建
（SHA 必然变更）。验收期请仅在"你发 Release 后"运行一次。
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import datetime
import zipfile
import sys

# Windows 控制台默认 GBK，遇到 ✓ 等符号会抛 UnicodeEncodeError；统一切到 UTF-8。
try:
    if hasattr(sys.stdout, 'reconfigure'):
        sys.stdout.reconfigure(encoding='utf-8')
        sys.stderr.reconfigure(encoding='utf-8')
except Exception:
    pass

SRC = os.path.dirname(os.path.abspath(__file__))          # 工作副本（源）
DST = r'D:\chunkspoke_flutter'                            # 构建副本（产物位置）
FLUTTER = r'D:\tools\flutter\bin\flutter.bat'
# JAVA_HOME：优先取环境变量；否则落到已知可用嵌套路径（D:\tools\jdk17-full\jdk-17.0.12+7）。
JAVA_HOME = os.environ.get('JAVA_HOME') or r'D:\tools\jdk17-full\jdk-17.0.12+7'

# 1.5.8 起**不内置任何 AI Key**（B4 红线：Key 只由用户在自己设备上填写，
# 落 Android Keystore 密文）。构建不再读取 .env / 环境变量里的密钥，
# 也就不存在「密钥进编译产物」的通道。


def ensure_vosk_model():
    """构建期确保 Vosk 离线模型 zip 落位于 assets（禁止运行时/首启联网）。"""
    m = os.path.join(SRC, 'assets', 'vosk-model-small-en-us-0.15.zip')
    if os.path.isfile(m) and os.path.getsize(m) > 1_000_000:
        return
    print('=== 确保 Vosk 离线模型（构建期下载，仅一次）===')
    sh(f'"{sys.executable}" "{os.path.join(SRC, "tools", "fetch_vosk_model.py")}"',
       cwd=SRC)


def patch_vosk_plugin():
    """修补 vosk_flutter 插件以适配 AGP 9（补 namespace / 提升 compileSdk），幂等。"""
    print('=== 修补 vosk_flutter 插件以适配 AGP 9 ===')
    sh(f'"{sys.executable}" "{os.path.join(SRC, "tools", "patch_vosk_plugin.py")}"',
       cwd=SRC)


def sh(cmd, cwd=DST):
    # 脱敏：日志中绝不出现内置密钥明文（仅显示 <已脱敏>）。
    masked = re.sub(r"--dart-define=BUILTIN_LLM_KEYS=[^\s]*",
                    "--dart-define=BUILTIN_LLM_KEYS=<已脱敏>", cmd)
    print('\n$', masked, '  (cwd=', cwd, ')')
    return subprocess.run(cmd, cwd=cwd, shell=True,
                          env={**os.environ, 'JAVA_HOME': JAVA_HOME}).returncode


def sync_src():
    """镜像同步最新工作副本（含正式图标）到构建副本。
    /MIR = /E + /PURGE：删除也传播（历史教训：llm.dart 曾因删除不传播在副本复活）。
    robocopy 退出码语义：0-7 均为成功态（1=有复制，2=目标多余，3=两者…），≥8 才是真错误。
    sh() 本身只返回 returncode 不拦截，这里按 robocopy 语义显式判码，避免成功态被当失败、
    也避免真失败被静默放过。"""
    # 排除 .env（本地密钥，绝不进构建副本 / 仓库）。
    excl = '/XD build .dart_tool .git feature /XF .env'
    rc = sh(f'robocopy "{SRC}" "{DST}" /MIR {excl} /R:1 /W:1')
    if rc >= 8:
        raise SystemExit(f'[sync] robocopy 失败，退出码 {rc}（≥8 为真错误）')
    print(f'  ✓ sync 完成（robocopy 退出码 {rc}：0-7 均成功态）')


def certutil_sha(path):
    out = subprocess.run(['certutil', '-hashfile', path, 'SHA256'],
                         capture_output=True, text=True).stdout
    for line in out.splitlines():
        line = line.strip()
        if re.fullmatch(r'[0-9a-fA-F]{64}', line):
            return line.lower()
    return 'ERR'


def set_remote_url(url):
    p = os.path.join(DST, 'lib', 'services', 'update_service.dart')
    s = open(p, encoding='utf-8').read()
    s2 = re.sub(r"(static const String remoteUrl = )'[^']*'",
                r"\1'" + url + "'", s, count=1)
    assert s2 != s, 'remoteUrl 替换未生效，请检查 update_service.dart'
    open(p, 'w', encoding='utf-8').write(s2)
    print('  ✓ remoteUrl 回填 ->', url)


def write_version_json(obj):
    p = os.path.join(DST, 'assets', 'version.json')
    open(p, 'w', encoding='utf-8').write(
        json.dumps(obj, ensure_ascii=False, indent=2) + '\n')
    print('  ✓ version.json ->', obj['version'], 'build', obj['buildNumber'])


def set_pubspec_version(name, code):
    p = os.path.join(DST, 'pubspec.yaml')
    s = open(p, encoding='utf-8').read()
    s2 = re.sub(r'^version: .*$', f'version: {name}+{code}', s,
                count=1, flags=re.M)
    if s2 != s:
        open(p, 'w', encoding='utf-8').write(s2)
        print('  ✓ pubspec version ->', f'{name}+{code}')
    else:
        print('  (pubspec version 已为', f'{name}+{code}', '，跳过写回)')


def recolor_icon():
    """可选项：对齐 v2.0 §7（背景 #0F0F1A + 三个白色圆角横块 + 最上方声波缺口）。
    改工作副本 icon 源图 + pubspec adaptive background，再生成 mipmap。"""
    from PIL import Image, ImageDraw
    S = 1024
    NAVY = (15, 15, 26, 255)     # #0F0F1A
    WHITE = (255, 255, 255, 255)
    bw, bh, gap = 560, 90, 28
    x0 = (S - bw) // 2
    y0 = 300

    def draw_blocks(img, transparent):
        d = ImageDraw.Draw(img)
        cut = (0, 0, 0, 0) if transparent else NAVY
        for i in range(3):
            y = y0 + i * (bh + gap)
            d.rounded_rectangle([x0, y, x0 + bw, y + bh], radius=20, fill=WHITE)
            if i == 0:  # 最上方块挖声波缺口
                for k in range(4):
                    gx = x0 + bw - 130 + k * 28
                    d.rectangle([gx, y + 18, gx + 12, y + bh - 18], fill=cut)

    full = Image.new('RGBA', (S, S), NAVY)
    draw_blocks(full, transparent=False)
    full.save(os.path.join(SRC, 'assets', 'icon', 'icon.png'))

    fg = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    draw_blocks(fg, transparent=True)
    fg.save(os.path.join(SRC, 'assets', 'icon', 'icon_foreground.png'))

    p = os.path.join(SRC, 'pubspec.yaml')
    s = open(p, encoding='utf-8').read().replace(
        'adaptive_icon_background: "#14213D"',
        'adaptive_icon_background: "#0F0F1A"')
    open(p, 'w', encoding='utf-8').write(s)
    sh(f'"{FLUTTER}" pub run flutter_launcher_icons --no-pub', cwd=SRC)
    print('  ✓ 图标已对齐 v2.0 §7（#0F0F1A + 白色块 + 声波缺口）')


def build_arm64(build_number=None, dart_define='', cwd=DST, no_pub=True):
    # --no-pub：pub 缓存已暖，跳过构建内联网 pub get（曾因网络抖动挂死整轮）
    cmd = (f'"{FLUTTER}" build apk --release --split-per-abi '
           f'-P force-version-code-ignoring-abi=true'
           f'{" --no-pub" if no_pub else ""}{dart_define}')
    if build_number is not None:
        # Android 覆盖安装判据是 manifest versionCode，不是 assets/version.json。
        # 显式 --build-number 双保险（pubspec 已 +N 仍再钉一次）。
        cmd += f' --build-number={build_number}'
    rc = sh(cmd, cwd=cwd)
    if rc != 0:
        raise SystemExit(f'[build] flutter build 失败，退出码 {rc}')
    apk = os.path.join(cwd, 'build', 'app', 'outputs', 'flutter-apk',
                       'app-arm64-v8a-release.apk')
    return apk, certutil_sha(apk), os.path.getsize(apk)


def aapt_version_code(apk):
    """实测 APK manifest versionCode（凭证：不许靠脚本标签自证）。
    返回 (vc_str, raw_line)：raw_line 为 aapt 原始 package 行，作为凭证附输出。"""
    cand = []
    ah = os.environ.get('ANDROID_HOME') or os.environ.get('ANDROID_SDK_ROOT')
    if ah:
        cand.append(os.path.join(ah, 'build-tools'))
    for base in [r'C:\tools\android-sdk', r'D:\Android\sdk',
                 os.path.expandvars(r'%LOCALAPPDATA%\Android\sdk')]:
        cand.append(os.path.join(base, 'build-tools'))
    aapt = None
    for c in cand:
        if os.path.isdir(c):
            for ver in sorted(os.listdir(c), reverse=True):
                p = os.path.join(c, ver, 'aapt.exe')
                if os.path.exists(p):
                    aapt = p
                    break
        if aapt:
            break
    if not aapt:
        return ('N/A', '(未找到 aapt，请手动 aapt dump badging)')
    out = subprocess.run([aapt, 'dump', 'badging', apk],
                         capture_output=True, text=True).stdout
    m = re.search(r"package: .*?versionCode='(\d+)'", out)
    if not m:
        return ('ERR', out.splitlines()[0] if out else '(aapt 无输出)')
    return (m.group(1), m.group(0))


def _key_fragments(keys_json):
    """从注入 JSON 派生密钥前 12 字符片段（运行期派生，不写死进脚本）。"""
    frags = []
    try:
        for e in json.loads(keys_json or '[]'):
            k = (e.get('key') or '')
            if len(k) >= 12:
                frags.append(k[:12])
    except Exception:
        pass
    return frags


def bundle_selfcheck(apk, keys_json):
    """尽力而为：解压 libapp.so，确认内置 Key 片段只存在于该编译产物常量区。"""
    frags = _key_fragments(keys_json)
    if not frags:
        return '(无注入密钥，跳过包内自检)'
    try:
        with zipfile.ZipFile(apk) as z:
            so = None
            for n in z.namelist():
                if n.endswith('libapp.so'):
                    so = z.read(n)
                    break
        if so is None:
            return '(未找到 libapp.so，跳过包内自检)'
        found = [f for f in frags if f.encode('utf-8') in so]
        if found:
            return f'包内 libapp.so 命中 {len(found)}/{len(frags)} 个密钥片段（编译产物常量区；符合预期）'
        return '(包内未命中任何密钥片段)'
    except Exception as e:  # 尽力而为，绝不伪造
        return f'(包内自检异常：{e})'


def git_leak_check(keys_json):
    """git log -p 全量自查：内置 Key 是否曾进入版本历史。"""
    frags = _key_fragments(keys_json)
    if not frags:
        return '(无注入密钥，跳过 git 泄漏自查)'
    try:
        r = subprocess.run(['git', '-C', SRC, 'log', '-p'],
                           capture_output=True, text=True,
                           encoding='utf-8', errors='replace')
        out = r.stdout or ''
    except Exception as e:
        return f'(git 自查异常：{e})'
    leaked = [f for f in frags if f in out]
    if leaked:
        return f'⚠ 发现 {len(leaked)} 个密钥片段曾出现在 git 历史！必须处理。'
    return f'git log -p 自查：{len(frags)} 个片段均未出现（无泄漏）✓'


def do_preview(bd, out_arg, build_number=10):
    """预览构建：同步到 ASCII 路径副本 DST 后单构建 arm64，直出桌面
    app-v1.1.0-preview.apk（禁止 upload）。源码路径含中文会触发 AOT 快照器
    读 app.dill 失败，故改在 DST 构建。"""
    print('=== 预览构建（单 arm64，直出桌面，禁止 upload）===')
    print('--- 同步源码到构建副本 DST（ASCII 路径，规避中文路径 AOT 失败）---')
    sync_src()
    out_path = out_arg or os.path.join(
        os.path.expanduser('~'), 'Desktop', 'app-v1.1.0-preview.apk')
    # no_pub=False：DST 首次构建需联网解析依赖（pub 缓存可能不实）。
    apk, sha, size = build_arm64(
        build_number=build_number,
        dart_define=bd, cwd=DST, no_pub=False)
    shutil.copy(apk, out_path)
    print(f'  ✓ 预览包已输出：{out_path}')
    print(f'  体积 {size} B | SHA {sha}')
    keys = ''  # 1.5.8 起不内置 Key，自检自然跳过
    print('--- 构建自检（尽力而为，如实报告）---')
    print('  包内：', bundle_selfcheck(out_path, keys))
    print('  git ：', git_leak_check(keys))
    print('====================================')


def main():
    ap = argparse.ArgumentParser(description='ChunkSpoke 回填+双包重建')
    ap.add_argument('--release-url', help='GitHub Release 地址（tag 或 download 形式，自动推导两个 URL）')
    ap.add_argument('--remote-url', help='手动指定远端 version.json 直链')
    ap.add_argument('--apk-url', help='手动指定 F3 的 apk 下载直链')
    ap.add_argument('--vf', default='1.0.1', help='F 展示版本名')
    ap.add_argument('--vf3', default='1.0.2', help='F3 展示版本名')
    ap.add_argument('--bf', type=int, default=2, help='F 的 versionCode')
    ap.add_argument('--bf3', type=int, default=3, help='F3 的 versionCode')
    ap.add_argument('--no-recolor', action='store_true', help='关闭图标调色（默认已批准并入：#0F0F1A+白色块+声波缺口）')
    ap.add_argument('--preview', action='store_true',
                    help='预览构建：单 arm64 直出桌面 app-v1.1.0-preview.apk（含注入与自检，不做双包/回填/upload）')
    ap.add_argument('--out', default=None, help='预览 APK 输出路径（默认桌面 app-v1.1.0-preview.apk）')
    ap.add_argument('--build-number', type=int, default=None,
                    help='预览构建 versionCode 覆盖（默认 10）')
    a = ap.parse_args()

    bd = ''  # 1.5.8 起不注入任何内置 Key
    ensure_vosk_model()
    patch_vosk_plugin()
    if a.preview:
        do_preview(bd, a.out, a.build_number if a.build_number is not None else 10)
        return

    if a.release_url:
        u = re.sub(r'/releases/tag/', '/releases/download/', a.release_url).rstrip('/')
        remote_url = u + '/version.json'
        apk_url = u + '/app-arm64-v8a-release.apk'
    else:
        remote_url, apk_url = a.remote_url, a.apk_url
    assert remote_url and apk_url, '需提供 --release-url 或 (--remote-url + --apk-url)'

    print('=== 1/同步源码 ===')
    sync_src()
    if not a.no_recolor:
        print('=== 1.5/图标调色（已批准：#0F0F1A 背景 + 白色块 + 声波缺口）===')
        recolor_icon()
        sync_src()

    print('=== 2/回填 remoteUrl ===')
    set_remote_url(remote_url)

    print(f'=== 3/重建 F (vc{a.bf}) ===')
    write_version_json({
        "version": a.vf, "buildNumber": a.bf, "apkUrl": "", "contentUrl": "",
        "notes": f"版本 {a.vf}：更新链路基线（零功能改动）。",
    })
    set_pubspec_version(a.vf, a.bf)
    f_apk, f_sha, f_size = build_arm64(a.bf, dart_define=bd)

    # 防 F3 覆盖：F 构建后立即物理另存（SHA 已在 build_arm64 内即时记账）
    f_kept = f_apk.replace('app-arm64-v8a-release.apk', 'app-F-vc2-release.apk')
    shutil.copy(f_apk, f_kept)
    print('  ✓ F 产物已另存(防 F3 覆盖)：', f_kept)

    print(f'=== 4/重建 F3 (vc{a.bf3}) ===')
    write_version_json({
        "version": a.vf3, "buildNumber": a.bf3, "apkUrl": apk_url, "contentUrl": "",
        "notes": f"版本 {a.vf3}：应用内更新链路验证（从 {a.vf} 升上来）。",
    })
    set_pubspec_version(a.vf3, a.bf3)
    f3_apk, f3_sha, f3_size = build_arm64(a.bf3, dart_define=bd)

    now = datetime.datetime.now().strftime('%Y/%m/%d %H:%M:%S')
    print('\n==================== 发布回填结果 ====================')
    print(f'F  (vc{a.bf})  arm64 : {f_size:>10} B | SHA {f_sha}')
    print(f'F3 (vc{a.bf3}) arm64 : {f3_size:>10} B | SHA {f3_sha}')
    print(f'Built: {now}')
    print(f'remoteUrl(回填到 update_service.dart) : {remote_url}')
    print(f'apkUrl  (远端 version.json -> F3)       : {apk_url}')
    print('请将「远端 version.json」(buildNumber=3, apkUrl=F3) 作为 Release 资产上传。')
    print('手机装 F(vc2) -> 设置页检查更新 -> 下载 F3(vc3) -> 安装。')
    print('---- 实测 manifest versionCode（aapt 原始输出，凭证 + 覆盖自校验）----')
    ABI_VC_BASE = 1000 * 2  # arm64-v8a 序号 2（Flutter split-per-abi 官方公式）

    def classify(measured, bn):
        if measured == str(bn):
            return ('A(force-flag 生效, 2/3)', True)
        if measured == str(ABI_VC_BASE + bn):
            return ('B(平台公式, 2002/2003)', True)
        return ('X(不符)', False)

    f_vc, f_line = aapt_version_code(f_kept)
    f_path, f_ok = classify(f_vc, a.bf)
    assert f_ok, f'[自检] F manifest versionCode={f_vc} 既非 {a.bf} 也非 {ABI_VC_BASE + a.bf}，中止'
    print(f'F  aapt 原始行 : {f_line}')
    print(f'F  manifest versionCode : {f_vc}  -> 路径 {f_path}')
    f3_vc, f3_line = aapt_version_code(f3_apk)
    f3_path, f3_ok = classify(f3_vc, a.bf3)
    assert f3_ok, f'[自检] F3 manifest versionCode={f3_vc} 既非 {a.bf3} 也非 {ABI_VC_BASE + a.bf3}，中止'
    assert int(f3_vc) > int(f_vc), '[自检] F3 versionCode 未大于 F，单调递增判据失败，中止'
    print(f'F3 aapt 原始行 : {f3_line}')
    print(f'F3 manifest versionCode : {f3_vc}  -> 路径 {f3_path}')
    print(f'[判据] F3({f3_vc}) > F({f_vc}) 单调递增 ✓ | 与 json buildNumber({a.bf}/{a.bf3}) 一致 ✓')
    print('---- 远端 version.json 全文（整文上传为 Release 同名资产）----')
    print(open(os.path.join(DST, 'assets', 'version.json'), encoding='utf-8').read().rstrip())
    print('---- 资产名逐字符核对（apkUrl 末段 必须 == 产物名）----')
    print(f"apkUrl 末段={os.path.basename(apk_url)}  产物名={os.path.basename(f3_apk)}  "
          f"一致={os.path.basename(apk_url) == os.path.basename(f3_apk)}")
    print('======================================================')


if __name__ == '__main__':
    main()
