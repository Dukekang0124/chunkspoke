// ChunkSpoke 官网脚本：拉取 version.json 渲染版本/大小；按 UA 分流下载（移动直下 / 桌面二维码）。
(function () {
  'use strict';

  // 版本清单按顺序尝试：同源副本最快且不受国内网络干扰，jsDelivr / raw 作兜底。
  // 同源副本由 tools/publish_release.py 在每次发版时自动刷新，不会陈旧。
  var VERSION_URLS = [
    './version.json',
    'https://cdn.jsdelivr.net/gh/Dukekang0124/chunkspoke@latest/version.json',
    'https://raw.githubusercontent.com/Dukekang0124/chunkspoke/main/version.json'
  ];

  // 全部清单源都失败时的兜底直链（GitHub Pages 镜像，无 20MB 限制、支持断点续传）。
  var FALLBACK_DOWNLOAD_URL =
    'https://dukekang0124.github.io/chunkspoke-releases/apk/1.4.8/chunkspoke-latest.apk';
  var FALLBACK_VERSION = 'v1.4.8';

  var downloadUrl = FALLBACK_DOWNLOAD_URL;

  function fmtMB(bytes) {
    if (!bytes) return '';
    return (bytes / 1048576).toFixed(1) + ' MB';
  }

  function applyVersion(j) {
    var v = 'v' + (j.versionName || FALLBACK_VERSION.replace(/^v/, ''));
    var mb = fmtMB(j.size);
    document.querySelectorAll('.version-badge').forEach(function (e) { e.textContent = v; });
    var fv = document.getElementById('footerVersion'); if (fv) fv.textContent = v;
    var fs = document.getElementById('footerSize'); if (fs) fs.textContent = mb ? ('约 ' + mb) : '';
    var hs = document.getElementById('heroSize'); if (hs && mb) hs.textContent = '约 ' + mb;
    // 下载地址取自清单，发版后无需改本文件；urls 为备用源列表。
    var u = j.url || ((j.urls && j.urls[0]) || '');
    if (u) downloadUrl = u;
  }

  function loadFrom(urls, i) {
    if (i >= urls.length) return Promise.reject(new Error('all sources failed'));
    return fetch(urls[i], { cache: 'no-store' })
      .then(function (r) { if (!r.ok) throw new Error('http ' + r.status); return r.json(); })
      .then(applyVersion)
      .catch(function () { return loadFrom(urls, i + 1); });
  }

  function loadVersion() {
    // 全部失败则保留页面内已烘焙的默认值，不影响下载按钮可用。
    loadFrom(VERSION_URLS, 0).catch(function () {/* keep fallback */});
  }

  function isMobile() {
    return /Mobi|Android|iPhone|iPad|iPod/i.test(navigator.userAgent) || window.innerWidth < 768;
  }

  function onDownload(e) {
    e.preventDefault();
    if (isMobile()) {
      var hint = document.getElementById('mobileHint');
      if (hint) hint.hidden = false;
      // 直接触发 APK 下载（移动端浏览器会下载 .apk）。
      window.location.href = downloadUrl;
    } else {
      var m = document.getElementById('qrModal');
      if (m) m.hidden = false;
    }
  }

  document.addEventListener('DOMContentLoaded', function () {
    loadVersion();
    ['downloadBtn', 'downloadBtn2'].forEach(function (id) {
      var b = document.getElementById(id);
      if (b) b.addEventListener('click', onDownload);
    });
    var close = document.getElementById('qrClose');
    if (close) close.addEventListener('click', function () {
      var m = document.getElementById('qrModal'); if (m) m.hidden = true;
    });
    var modal = document.getElementById('qrModal');
    if (modal) modal.addEventListener('click', function (ev) {
      if (ev.target === modal) modal.hidden = true;
    });
  });
})();
