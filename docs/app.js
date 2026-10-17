// ChunkSpoke 官网脚本：拉取 version.json 渲染版本/大小；按 UA 分流下载（移动直下 / 桌面二维码）。
(function () {
  'use strict';
  var DOWNLOAD_URL = 'https://github.com/Dukekang0124/chunkspoke/releases/latest/download/chunkspoke-latest.apk';
  var VERSION_URL = 'https://raw.githubusercontent.com/Dukekang0124/chunkspoke/main/version.json';

  function fmtMB(bytes) {
    if (!bytes) return '';
    return (bytes / 1048576).toFixed(1) + ' MB';
  }

  function applyVersion(j) {
    var v = 'v' + (j.versionName || '1.2.4');
    var mb = fmtMB(j.size);
    document.querySelectorAll('.version-badge').forEach(function (e) { e.textContent = v; });
    var fv = document.getElementById('footerVersion'); if (fv) fv.textContent = v;
    var fs = document.getElementById('footerSize'); if (fs) fs.textContent = mb ? ('约 ' + mb) : '';
  }

  function loadVersion() {
    // 容错：拉取失败则用页面内已烘焙的默认值（v1.2.4）。
    fetch(VERSION_URL, { cache: 'no-store' })
      .then(function (r) { if (!r.ok) throw new Error('http ' + r.status); return r.json(); })
      .then(applyVersion)
      .catch(function () {/* keep fallback */});
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
      window.location.href = DOWNLOAD_URL;
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
