#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""本地 E2E harness：以 HTTP/1.1（Content-Length 定界 + keep-alive）托管模型分块。

为什么不用 `python -m http.server`：
  其默认 HTTP/1.0 靠「连接关闭」表示响应结束，模拟器 NAT(10.0.2.2) 下最后一次
  小尾部数据段会与 FIN 竞争，导致 15.7MB 流稳定在最后几个字节被截断
  （ClientException: Connection closed while receiving data）。
  改用 HTTP/1.1 后由 Content-Length 定界，不再依赖 EOF，问题消失。

用法：python tools/harness_server.py [端口] [根目录]
"""
import os
import sys
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer


class Handler(SimpleHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'  # Content-Length 定界，规避 NAT 截断

    def end_headers(self):
        self.send_header('Accept-Ranges', 'none')
        super().end_headers()


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8899
    root = sys.argv[2] if len(sys.argv) > 2 else os.getcwd()
    os.chdir(root)
    srv = ThreadingHTTPServer(('0.0.0.0', port), Handler)
    print(f'[harness] HTTP/1.1 serving {root} at 0.0.0.0:{port}')
    srv.serve_forever()


if __name__ == '__main__':
    main()
