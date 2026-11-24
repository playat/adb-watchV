# -*- coding: utf-8 -*-
"""双击启动（无控制台）。等价于 run.cmd。"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import adb_watch_v  # noqa: E402

adb_watch_v.main()
