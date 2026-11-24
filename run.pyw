# -*- coding: utf-8 -*-
"""双击启动（无控制台）。

.pyw 由 pythonw 执行，不会创建控制台窗口；本文件只负责把自身目录加进
sys.path，然后调用 adb_watch_v.main()。
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import adb_watch_v  # noqa: E402

adb_watch_v.main()
