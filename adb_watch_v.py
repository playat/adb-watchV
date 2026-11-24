# -*- coding: utf-8 -*-
"""
adb-watchV —— Python + tkinter 版（原 PowerShell 版的 GUI 重构）

启动就是一个连接窗口，先自动扫 mDNS（2.5 秒一轮）：
    · 扫到就自动连，连上就收起窗口、放出悬浮操作条
    · 按 Esc → 窗口下面长出 IP:端口 输入模块，点右侧 ✓ 主动连接
    · 端口通但握不上手（没配对 / 配对码过期）→ 模块换成配对，填配对端口 + 配对码，点 ✓ 主动配对

悬浮操作条（默认屏幕左上角，可拖动；右键可退出）：
    ▲ 上滑      ● 点按      ▼ 下滑      ↺ 重启（重新走一遍连接流程）

连接逻辑与原版一致：
    · 开扫前 adb kill-server，清掉死连接和旧 mDNS 缓存
    · 每个地址先探端口，端口不通就判失败，不让 adb 干等
    · adb connect 有硬超时（20 秒）
    · 端口通、但连续 3 次握不上手 → 直接进配对，不再无限重试
"""

import ctypes
import os
import queue
import re
import socket
import subprocess
import threading
import time
import tkinter as tk

# ---------------------------------------------------------------- 高 DPI

def _setup_dpi():
    """声明 DPI 感知，返回缩放比（96 DPI 为 1.0）。

    不声明的话，Windows 会把窗口当成 96 DPI 的位图整体拉伸到实际缩放 ——
    在 150% 的屏上字全是糊的。声明之后由我们自己按比例放大，才是清晰渲染。
    """
    if os.name != "nt":
        return 1.0
    ok = False
    try:
        ok = ctypes.windll.shcore.SetProcessDpiAwareness(2) == 0   # 每显示器 DPI 感知
    except Exception:
        ok = False
    if not ok:                                  # Win7 没有 shcore，或已被别的方式设过
        try:
            ctypes.windll.user32.SetProcessDPIAware()
        except Exception:
            pass
    dpi = 96
    try:
        dpi = int(ctypes.windll.user32.GetDpiForSystem())
    except Exception:
        try:
            hdc = ctypes.windll.user32.GetDC(0)
            dpi = int(ctypes.windll.gdi32.GetDeviceCaps(hdc, 88))   # LOGPIXELSX
            ctypes.windll.user32.ReleaseDC(0, hdc)
        except Exception:
            dpi = 96
    return max(1.0, dpi / 96.0)


SCALE = _setup_dpi()


def px(value):
    """逻辑像素 -> 实际像素。字体走 tk scaling，这里只管间距和尺寸。"""
    return int(round(value * SCALE))


# ---------------------------------------------------------------- 常量

APP_NAME = "adb-watchV"
FONT = "Microsoft YaHei UI"
SYMBOL_FONT = "Segoe UI Symbol"

BG = "#1f2023"
PANEL = "#26282c"
ENTRY_BG = "#2f3237"
BORDER = "#3a3d43"
FG = "#e6e6e6"
MUTED = "#9aa0a6"
ACCENT = "#4ec9b0"
WARN = "#e2c08d"
ERR = "#f28b82"
BTN_BG = "#34373d"
BTN_HOVER = "#43474e"

BAR_BG = "#232529"
BAR_HOVER = "#34373d"
BAR_GRIP = "#2c2f34"

BAR_ALPHA = 0.10            # 平时 10% 不透明：几乎只剩个影子，压在最上层也不挡
BAR_ALPHA_HOVER = 0.98      # 鼠标移上去变清晰，方便点准
BAR_ALPHA_MSG = 0.92        # 有提示文字时临时提亮，否则 10% 下根本读不出来

# 全局热键：沿用老版定下来的 Alt+F1/F2/F3，左手一只，右手不用离鼠标。
# 想换键改这里就行，支持 F1~F24、单个字母/数字，修饰键写 Ctrl / Alt / Shift / Win。
HOTKEYS = (
    ("Alt+F1", "up",   "上滑"),
    ("Alt+F2", "down", "下滑"),
    ("Alt+F3", "tap",  "点按"),
)
MOD_ALT = 0x0001
MOD_CTRL = 0x0002
MOD_SHIFT = 0x0004
MOD_WIN = 0x0008
MOD_NOREPEAT = 0x4000

VK_EXTRA = {
    "SPACE": 0x20, "ENTER": 0x0D, "TAB": 0x09, "ESC": 0x1B,
    "BACKSPACE": 0x08, "INSERT": 0x2D, "DELETE": 0x2E,
    "HOME": 0x24, "END": 0x23, "PAGEUP": 0x21, "PAGEDOWN": 0x22,
    "UP": 0x26, "DOWN": 0x28, "LEFT": 0x25, "RIGHT": 0x27,
    "PAUSE": 0x13, "SCROLLLOCK": 0x91, "CAPSLOCK": 0x14,
    "OEM_3": 0xC0,      # 反引号 `
    "OEM_5": 0xDC,      # 反斜杠
    # 符号键直接写符号也行（原版支持 Alt+` 这种写法）
    "`": 0xC0, "~": 0xC0,
    "\\": 0xDC, "|": 0xDC,
    "-": 0xBD, "=": 0xBB,
    "[": 0xDB, "]": 0xDD,
    ";": 0xBA, "'": 0xDE,
    ",": 0xBC, ".": 0xBE, "/": 0xBF,
}

WIN_W = px(430)
MSG_MAX_H = px(190)       # 文本区最多这么高，再长就滚动
MSG_MIN_H = px(58)        # 太短会显得窗口在抖
DURATION_MS = 300
NEAR_RATIO = 0.8
FAR_RATIO = 0.2
SCAN_INTERVAL = 2.5
MAX_HANDSHAKE_FAILS = 3

CREATE_NO_WINDOW = 0x08000000 if os.name == "nt" else 0

KNOWN_STATES = {
    "device", "offline", "unauthorized", "bootloader",
    "recovery", "sideload", "rescue", "host", "no",
}


# ---------------------------------------------------------------- 小工具

def decode(raw):
    if not raw:
        return ""
    if isinstance(raw, str):
        return raw
    for enc in ("utf-8", "gbk"):
        try:
            return raw.decode(enc)
        except Exception:
            continue
    return raw.decode("utf-8", "replace")


def work_area():
    """桌面可用区域 (left, top, right, bottom)，扣掉任务栏；拿不到就给整块屏幕。"""
    class RECT(ctypes.Structure):
        _fields_ = [("left", ctypes.c_long), ("top", ctypes.c_long),
                    ("right", ctypes.c_long), ("bottom", ctypes.c_long)]

    if os.name == "nt":
        try:
            r = RECT()
            # SPI_GETWORKAREA = 0x0030
            if ctypes.windll.user32.SystemParametersInfoW(
                    0x0030, 0, ctypes.byref(r), 0):
                if r.right > r.left and r.bottom > r.top:
                    return r.left, r.top, r.right, r.bottom
        except Exception:
            pass
    return None


def parse_hostport(text, default_port=5555):
    """'192.168.88.9:42123' -> ('192.168.88.9', 42123)；裸 IP 补默认端口。"""
    t = (text or "").strip()
    if not t:
        return None
    m = re.fullmatch(r"(.+):(\d{1,5})", t)
    if m:
        return m.group(1).strip(), int(m.group(2))
    if re.fullmatch(r"[0-9A-Za-z_.\-]+", t):
        return t, default_port
    return None


def port_open(host, port, timeout=1.5):
    """端口通不通。比 adb connect 快得多，也不会有 20 秒的等待。"""
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except OSError:
        return False


class Device:
    __slots__ = ("serial", "state", "model")

    def __init__(self, serial, state, model=""):
        self.serial = serial
        self.state = state
        self.model = model

    def __repr__(self):
        return "%s(%s)" % (self.serial, self.state)


def link_kind(serial):
    if re.search(r"\._adb-tls-connect\._tcp$", serial):
        return "无线"
    if ":" in serial:
        return "无线"
    if serial.startswith("emulator-"):
        return "模拟器"
    return "USB"


def state_text(state):
    return {"device": "在线", "offline": "离线",
            "unauthorized": "未授权", "no": "未授权"}.get(state, state)


# ---------------------------------------------------------------- adb 封装

class Adb:
    def __init__(self):
        self.path = self._resolve()

    @staticmethod
    def _resolve():
        here = os.path.dirname(os.path.abspath(__file__))
        for c in (os.path.join(here, "adb", "adb.exe"),
                  os.path.join(here, "adb.exe"),
                  os.path.join(here, "platform-tools", "adb.exe")):
            if os.path.isfile(c):
                return c
        from shutil import which
        return which("adb") or ""

    @property
    def bundled(self):
        return bool(self.path) and self.path.lower().startswith(
            os.path.dirname(os.path.abspath(__file__)).lower())

    def run(self, args, timeout=30):
        """返回 (code, stdout, stderr, timed_out)。超时到点强制结束。"""
        if not self.path:
            return 127, "", "找不到 adb", False
        try:
            p = subprocess.run(
                [self.path] + [str(a) for a in args],
                capture_output=True, timeout=timeout,
                creationflags=CREATE_NO_WINDOW,
            )
            return p.returncode, decode(p.stdout), decode(p.stderr), False
        except subprocess.TimeoutExpired:
            return 124, "", "超时", True
        except Exception as exc:                      # noqa: BLE001
            return 1, "", str(exc), False

    # ---- 设备 ----

    def devices(self):
        code, out, err, _ = self.run(["devices", "-l"], 15)
        found = []
        for line in (out or "").splitlines():
            line = line.strip()
            if not line or line.startswith("List of devices") or line.startswith("*"):
                continue
            parts = line.split()
            if len(parts) < 2:
                continue
            serial, state = parts[0], parts[1]
            if state not in KNOWN_STATES:
                continue
            m = re.search(r"model:(\S+)", line)
            found.append(Device(serial, state, m.group(1) if m else ""))
        return self._drop_alias(found)

    @staticmethod
    def _drop_alias(items):
        """同一台手机既以 IP 又以 mDNS 别名出现时，只留 IP 那条。"""
        plain = [d for d in items if not d.serial.endswith("._adb-tls-connect._tcp")]
        alias = [d for d in items if d.serial.endswith("._adb-tls-connect._tcp")]
        if not alias:
            return items
        kept = list(plain)
        for a in alias:
            dup = any(p.model and a.model and p.model == a.model for p in plain)
            if not dup:
                kept.append(a)
        return kept

    def is_online(self, serial):
        return any(d.serial == serial and d.state == "device" for d in self.devices())

    # ---- mDNS ----

    def mdns_services(self):
        _, out, _, _ = self.run(["mdns", "services"], 8)
        found = []
        pat = re.compile(r"_adb-tls-(connect|pairing)\._tcp\.?\s+([0-9.]+):(\d+)")
        for line in (out or "").splitlines():
            m = pat.search(line)
            if m:
                found.append((m.group(1), m.group(2), int(m.group(3))))
        return found

    def connect_targets(self, host=None):
        seen, out = set(), []
        for svc, h, p in self.mdns_services():
            if svc != "connect":
                continue
            if host and h != host:
                continue
            addr = "%s:%d" % (h, p)
            if addr not in seen:
                seen.add(addr)
                out.append(addr)
        return out

    # ---- 连接 / 配对 ----

    def connect(self, target, timeout=20):
        return self.run(["connect", target], timeout)

    def pair(self, addr, code, timeout=20):
        return self.run(["pair", addr, code], timeout)

    def disconnect_all(self):
        self.run(["disconnect"], 10)

    # ---- 设备能力 ----

    def screen_size(self, serial, timeout=8):
        code, out, _, _ = self.run(["-s", serial, "shell", "wm", "size"], timeout)
        if code != 0 or not out:
            return None
        m = re.search(r"Override size:\s*(\d+)x(\d+)", out) or \
            re.search(r"Physical size:\s*(\d+)x(\d+)", out)
        if not m:
            return None
        return int(m.group(1)), int(m.group(2))

    def input_swipe(self, serial, x, y1, y2, duration=DURATION_MS):
        return self.run(["-s", serial, "shell", "input", "swipe",
                         str(x), str(y1), str(x), str(y2), str(duration)], 15)

    def input_tap(self, serial, x, y):
        return self.run(["-s", serial, "shell", "input", "tap",
                         str(x), str(y)], 15)


# ---------------------------------------------------------------- 全局热键

def parse_hotkey(spec):
    """'Alt+F1' -> (modifiers, vk)；写错了抛 ValueError。"""
    mods = 0
    key = ""
    for part in spec.split("+"):
        p = part.strip().upper()
        if p in ("CTRL", "CONTROL"):
            mods |= MOD_CTRL
        elif p == "ALT":
            mods |= MOD_ALT
        elif p == "SHIFT":
            mods |= MOD_SHIFT
        elif p in ("WIN", "META"):
            mods |= MOD_WIN
        elif p:
            key = p
    if not key:
        raise ValueError("热键没有主键：%s" % spec)

    vk = VK_EXTRA.get(key)
    if vk is None:
        if len(key) == 1 and ("0" <= key <= "9" or "A" <= key <= "Z"):
            vk = ord(key)
        elif key.startswith("F") and key[1:].isdigit() and 1 <= int(key[1:]) <= 24:
            vk = 0x6F + int(key[1:])          # F1 = 0x70
        else:
            raise ValueError("不认识的键：%s" % key)
    return mods, vk


class HotKeys:
    """Windows 全局热键（RegisterHotKey）。

    注册和取消息必须在**同一个线程**：WM_HOTKEY 只投递到调用 RegisterHotKey
    的那个线程的消息队列，而 Tk 的主循环会先把这类线程消息取走再丢掉。
    所以这里自己起一条线程，注册完就守着自己的队列。
    """

    WM_HOTKEY = 0x0312
    PM_REMOVE = 0x0001

    def __init__(self, app):
        self.app = app
        self.live = False
        self.thread = None

    # ---- 开关 ----

    def start(self):
        if os.name != "nt" or self.live:
            return
        self.live = True
        self.thread = threading.Thread(target=self._loop, name="hotkeys",
                                       daemon=True)
        self.thread.start()

    def stop(self):
        self.live = False
        t = self.thread
        if t and t.is_alive():
            t.join(1.0)          # 线程 20ms 一轮，清得很快
        self.thread = None

    # ---- 后台线程 ----

    def _loop(self):
        from ctypes import wintypes
        u32 = ctypes.windll.user32
        u32.RegisterHotKey.argtypes = [wintypes.HWND, ctypes.c_int,
                                       wintypes.UINT, wintypes.UINT]
        u32.RegisterHotKey.restype = wintypes.BOOL
        u32.UnregisterHotKey.argtypes = [wintypes.HWND, ctypes.c_int]
        u32.UnregisterHotKey.restype = wintypes.BOOL
        u32.PeekMessageW.argtypes = [ctypes.POINTER(wintypes.MSG), wintypes.HWND,
                                     wintypes.UINT, wintypes.UINT, wintypes.UINT]
        u32.PeekMessageW.restype = wintypes.BOOL

        ids = []
        failed = []
        for idx, (spec, _action, _label) in enumerate(HOTKEYS, start=1):
            try:
                mods, vk = parse_hotkey(spec)
            except ValueError:
                failed.append(spec)
                continue
            # 老系统不认 MOD_NOREPEAT，退一步再试
            if u32.RegisterHotKey(None, idx, mods | MOD_NOREPEAT, vk) or \
               u32.RegisterHotKey(None, idx, mods, vk):
                ids.append(idx)
            else:
                failed.append(spec)        # 多半是被别的软件占了

        if failed:
            self.app.ui(lambda: self.app.notify_hotkeys(failed))
        if not ids:
            return

        msg = wintypes.MSG()
        try:
            while self.live:
                if u32.PeekMessageW(ctypes.byref(msg), None, self.WM_HOTKEY,
                                    self.WM_HOTKEY, self.PM_REMOVE):
                    idx = int(msg.wParam)
                    if 1 <= idx <= len(HOTKEYS):
                        action = HOTKEYS[idx - 1][1]
                        self.app.ui(lambda a=action: self.app.gesture(a))
                    continue
                time.sleep(0.02)
        finally:
            for idx in ids:
                u32.UnregisterHotKey(None, idx)


# ---------------------------------------------------------------- 悬浮操作条

class Bar:
    """竖着的悬浮条：▲ 上滑 / ● 点按 / ▼ 下滑 / ↺ 重启。可拖动，右键退出。"""

    def __init__(self, app):
        self.app = app
        self.win = tk.Toplevel(app.root)
        self.win.overrideredirect(True)
        self.win.attributes("-topmost", True)
        self.win.attributes("-alpha", BAR_ALPHA)
        self.win.configure(bg=BORDER)
        self._hover_job = None
        self._flash_seq = 0
        self._hovering = False
        self._alert = False

        self.inner = tk.Frame(self.win, bg=BAR_BG)
        self.inner.pack(padx=px(1), pady=px(1))

        # 顶部细条：专门用来拖
        self.grip = tk.Frame(self.inner, bg=BAR_GRIP, height=px(14), cursor="fleur")
        self.grip.pack(fill="x")
        self.grip.bind("<Button-1>", self._drag_start)
        self.grip.bind("<B1-Motion>", self._drag)

        self.btn_up = self._button("▲", lambda: app.gesture("up"))
        self._sep()
        self.btn_tap = self._button("●", lambda: app.gesture("tap"))
        self._sep()
        self.btn_down = self._button("▼", lambda: app.gesture("down"))
        self._sep()
        self.btn_reset = self._button("↺", app.restart, color=WARN)

        # wraplength 而不是 width：文案长了就换行，绝不把条撑宽
        self.msg = tk.Label(self.inner, text="", bg=BAR_BG, fg=ERR,
                            font=(FONT, 8), wraplength=px(48), justify="center")
        self.msg.pack(fill="x", pady=(0, px(3)))

        for w in (self.win, self.inner, self.grip):
            w.bind("<Button-3>", self._menu)

        # 透明度是整窗生效的，所以鼠标进到任何一个子控件都算「进入悬浮条」
        self._bind_hover(self.win)

    # ---- 构建 ----

    def _button(self, glyph, command, color=FG):
        lbl = tk.Label(self.inner, text=glyph, bg=BAR_BG, fg=color,
                       font=(SYMBOL_FONT, 15), width=4, pady=px(6), cursor="hand2")
        lbl.pack(fill="x")

        def press(_e=None):
            command()
            return "break"

        lbl.bind("<Button-1>", press)
        lbl.bind("<Enter>", lambda e: lbl.configure(bg=BAR_HOVER))
        lbl.bind("<Leave>", lambda e: lbl.configure(bg=BAR_BG))
        return lbl

    def _sep(self):
        tk.Frame(self.inner, bg=BORDER, height=px(1)).pack(fill="x", padx=px(6))

    # ---- 位置 / 拖动 ----

    def show_default(self):
        """默认贴主屏左上角。"""
        self.win.update_idletasks()
        self.win.geometry("+%d+%d" % (px(24), px(24)))
        self._refresh_alpha()        # overrideredirect 窗口要在 map 之后设一次才稳
        self.win.lift()

    def _drag_start(self, event):
        self._ox = event.x_root - self.win.winfo_x()
        self._oy = event.y_root - self.win.winfo_y()

    def _drag(self, event):
        self.win.geometry("+%d+%d" % (event.x_root - self._ox,
                                      event.y_root - self._oy))

    # ---- 透明度 ----

    def _bind_hover(self, widget):
        """窗口和所有子控件都挂上 Enter/Leave，否则在按钮之间移动会闪。"""
        widget.bind("<Enter>", self._on_enter, add="+")
        widget.bind("<Leave>", self._on_leave, add="+")
        for child in widget.winfo_children():
            self._bind_hover(child)

    def _on_enter(self, _event=None):
        self._cancel_hover()
        self._hovering = True
        self._refresh_alpha()

    def _on_leave(self, _event=None):
        # 从 ▲ 移到 ● 会先收到 Leave 再收到 Enter，所以晚一点再决定，避免闪烁
        self._cancel_hover()
        self._hovering = False
        try:
            self._hover_job = self.win.after(150, self._fade_out)
        except tk.TclError:
            pass

    def _fade_out(self):
        self._hover_job = None
        self._refresh_alpha()

    def _cancel_hover(self):
        if self._hover_job is not None:
            try:
                self.win.after_cancel(self._hover_job)
            except tk.TclError:
                pass
            self._hover_job = None

    def _set_alpha(self, value):
        try:
            self.win.attributes("-alpha", value)
        except tk.TclError:
            pass

    def _refresh_alpha(self):
        """三条路：鼠标在上面 > 有提示文字 > 平时。10% 下文字读不出来，所以提示时提亮。"""
        if self._hovering:
            value = BAR_ALPHA_HOVER
        elif self._alert:
            value = BAR_ALPHA_MSG
        else:
            value = BAR_ALPHA
        self._set_alpha(value)

    # ---- 状态 ----

    def note(self, text):
        self._flash_seq += 1        # 常驻提示一出现，就别让 flash 的定时器再清它
        self.msg.configure(text=text, fg=ERR)
        self._alert = bool(text)
        self._refresh_alpha()

    def flash(self, text, ms=4000):
        """临时提示，几秒后自己消失。"""
        self._flash_seq += 1
        seq = self._flash_seq
        self.msg.configure(text=text, fg=WARN)
        self._alert = True
        self._refresh_alpha()

        def clear():
            if seq == self._flash_seq and self.msg.cget("text") == text:
                self.msg.configure(text="")
                self._alert = False
                self._refresh_alpha()

        try:
            self.win.after(ms, clear)
        except tk.TclError:
            pass

    def clear_note(self):
        self.msg.configure(text="")
        self._alert = False
        self._refresh_alpha()

    def _menu(self, event):
        m = tk.Menu(self.win, tearoff=0)
        m.add_command(label="重新连接", command=self.app.restart)
        m.add_separator()
        m.add_command(label="退出", command=self.app.quit)
        try:
            m.tk_popup(event.x_root, event.y_root)
        finally:
            m.grab_release()

    def destroy(self):
        self._cancel_hover()
        try:
            self.win.destroy()
        except tk.TclError:
            pass


# ---------------------------------------------------------------- 主程序

class App:
    def __init__(self):
        self.adb = Adb()
        self.root = tk.Tk()
        try:
            # 一个 point 占多少像素；设对了字体才会按真实 DPI 渲染
            self.root.tk.call("tk", "scaling", (SCALE * 96.0) / 72.0)
        except tk.TclError:
            pass
        self.root.title(APP_NAME)
        self.root.configure(bg=BG)
        self.root.resizable(False, False)
        self.root.protocol("WM_DELETE_WINDOW", self.quit)

        self.state = "idle"          # idle / scan / manual / pair / bar
        self.run_id = 0              # 每重启一次 +1，旧线程看到不一致就自己退
        self.device = ""
        self.size = (0, 0)
        self.bar = None
        self.ok_btn = None
        self.ip_entry = None
        self.code_entry = None
        self.manual_cp = None        # 手动连接时输入的地址，配对后还要用它兜底
        self.notes = set()           # 扫到过的连接地址，配对时反查
        self.ui_queue = queue.Queue()
        self.gesture_lock = threading.Lock()
        self.busy = False
        self._bar_shown = False    # 文本区滚动条当前是不是露着
        self._sync_guard = False
        self._pos = None           # 窗口左上角；None 表示还没摆过（首次居中）
        self.hotkeys = HotKeys(self)

        self._build()
        self._pump()
        self.root.after(150, self.start)

    # ============================================================ 界面骨架

    def _build(self):
        wrap = tk.Frame(self.root, bg=BG, padx=px(18), pady=px(14))
        wrap.pack(fill="both", expand=True)

        head = tk.Frame(wrap, bg=BG)
        head.pack(fill="x")
        tk.Label(head, text=APP_NAME, bg=BG, fg=FG,
                 font=(FONT, 11, "bold")).pack(side="left")
        self.dot = tk.Label(head, text="●", bg=BG, fg=MUTED, font=(FONT, 9))
        self.dot.pack(side="right")

        # 输入模块先占住底部，文本再长也压不到它
        self.body = tk.Frame(wrap, bg=BG)
        self.body.pack(side="bottom", fill="x", pady=(px(12), 0))

        # 中间的文本区：超过 MSG_MAX_H 就在自己内部滚动，不撑窗口
        self.msg_box = tk.Frame(wrap, bg=BG)
        self.msg_box.pack(fill="both", expand=True, pady=(px(8), 0))

        self.msg_canvas = tk.Canvas(self.msg_box, bg=BG, bd=0,
                                    highlightthickness=0, height=px(MSG_MIN_H))
        self.msg_bar = tk.Scrollbar(self.msg_box, orient="vertical",
                                    command=self.msg_canvas.yview,
                                    width=px(8), bg=BG, troughcolor=BG,
                                    activebackground=BORDER, relief="flat", bd=0)
        self.msg_canvas.configure(yscrollcommand=self._scroll_set)
        self.msg_canvas.pack(side="left", fill="both", expand=True)

        self.msg_inner = tk.Frame(self.msg_canvas, bg=BG)
        self._msg_win = self.msg_canvas.create_window(
            (0, 0), window=self.msg_inner, anchor="nw")
        self.msg_canvas.bind("<Configure>", self._msg_wide)

        self.lbl_status = tk.Label(self.msg_inner, text="准备中…", bg=BG, fg=FG,
                                   font=(FONT, 10), anchor="w", justify="left",
                                   wraplength=WIN_W - px(40))
        self.lbl_status.pack(fill="x", pady=(0, px(2)))

        self.lbl_detail = tk.Label(self.msg_inner, text="", bg=BG, fg=MUTED,
                                   font=(FONT, 9), anchor="w", justify="left",
                                   wraplength=WIN_W - px(40))
        self.lbl_detail.pack(fill="x")

        self.lbl_error = tk.Label(self.msg_inner, text="", bg=BG, fg=ERR,
                                  font=(FONT, 9), anchor="w", justify="left",
                                  wraplength=WIN_W - px(40))
        self.lbl_error.pack(fill="x")

        self._wheel_bind(self.msg_inner)

        self.root.bind("<Configure>", self._on_move, add="+")
        self.place(px(150))
        self.root.bind("<Escape>", self.on_escape)

    def fit(self):
        self.root.update_idletasks()
        h = self.root.winfo_reqheight()
        self.place(max(h, px(130)))

    # ---- 文本区：超高了就滚动 ----

    def _scroll_set(self, first, last):
        self.msg_bar.set(first, last)

    def _msg_wide(self, event):
        """内层 Frame 跟着 canvas 的宽度走，否则文字会按最宽那行排版。"""
        self.msg_canvas.itemconfigure(self._msg_win, width=max(event.width, 1))

    def _wheel(self, event):
        if not self._bar_shown:
            return
        self.msg_canvas.yview_scroll(-1 if event.delta > 0 else 1, "units")

    def _wheel_bind(self, widget):
        widget.bind("<MouseWheel>", self._wheel, add="+")
        for child in widget.winfo_children():
            self._wheel_bind(child)

    def _sync_msg(self):
        """按文本实际高度调整滚动区：不超过上限就原样显示，超了就出滚动条。"""
        if self._sync_guard:
            return
        self._sync_guard = True
        try:
            self.msg_inner.update_idletasks()
            h = self.msg_inner.winfo_reqheight()
            maxh = MSG_MAX_H
            show = h > maxh
            if show != self._bar_shown:
                self._bar_shown = show
                if show:
                    self.msg_bar.pack(side="right", fill="y")
                    # 有滚动条了，文字宽度要缩一点，重新量一次
                    wrap_w = WIN_W - px(40) - px(10)
                    for lbl in (self.lbl_status, self.lbl_detail, self.lbl_error):
                        lbl.configure(wraplength=wrap_w)
                else:
                    self.msg_bar.pack_forget()
                    wrap_w = WIN_W - px(40)
                    for lbl in (self.lbl_status, self.lbl_detail, self.lbl_error):
                        lbl.configure(wraplength=wrap_w)
                self.msg_inner.update_idletasks()
                h = self.msg_inner.winfo_reqheight()
            height = max(MSG_MIN_H, min(h, maxh))
            self.msg_canvas.configure(height=height)
            self.msg_canvas.configure(
                scrollregion=(0, 0, max(self.msg_inner.winfo_reqwidth(), 1), h))
            if show:
                self.msg_canvas.yview_moveto(1.0)   # 最新那行在下面，滚到底
        finally:
            self._sync_guard = False
        self.fit()

    def place(self, height):
        """摆窗口：第一次放屏幕正中，之后只改高度，位置跟着窗口走。

        以前每次刷新都重算居中，用户把窗口拖到别处、一刷新又弹回中间，很难受。
        现在位置记住在 _pos 里（用户拖动时由 _on_move 更新），只做防出屏的夹取。
        """
        w = WIN_W
        area = work_area() or (0, 0, self.root.winfo_screenwidth(),
                               self.root.winfo_screenheight())
        left, top, right, bottom = area
        if self._pos is None:
            x = left + (right - left - w) // 2
            y = top + (bottom - top - height) // 2
        else:
            x, y = self._pos
            x = max(left, min(x, right - w))
            y = max(top, min(y, bottom - height))   # 变高之后别被任务栏吃掉
        self._pos = (x, y)
        self.root.geometry("%dx%d+%d+%d" % (w, height, x, y))

    def _on_move(self, event):
        """窗口被拖到别处时记住位置，下次变高就按这个位置长。"""
        if event.widget is not self.root:
            return
        try:
            if self.root.state() != "normal":
                return
            pos = (self.root.winfo_x(), self.root.winfo_y())
        except tk.TclError:
            return
        if pos != self._pos:
            self._pos = pos

    # ---- 文案 ----

    def say(self, status, detail="", color=FG):
        self.lbl_status.configure(text=status, fg=color)
        self.lbl_detail.configure(text=detail)
        self._sync_msg()

    def error(self, text=""):
        self.lbl_error.configure(text=text)
        self._sync_msg()

    def dot_color(self, color):
        self.dot.configure(fg=color)

    # ---- 线程 → UI ----

    def ui(self, fn):
        self.ui_queue.put(fn)

    def ui_if(self, rid, fn):
        if rid == self.run_id:
            self.ui(fn)

    def _pump(self):
        if getattr(self, "_closed", False):
            return
        try:
            while True:
                fn = self.ui_queue.get_nowait()
                try:
                    fn()
                except Exception:                    # noqa: BLE001
                    pass
        except queue.Empty:
            pass
        try:
            self._pump_id = self.root.after(50, self._pump)
        except tk.TclError:
            pass

    # ============================================================ 启动 / 扫描

    def start(self):
        if not self.adb.path:
            self.say("找不到 adb", "把 platform-tools 里的 adb.exe 和两个 DLL 放进 adb\\ 子目录。", ERR)
            self.dot_color(ERR)
            return
        self.start_scan()

    def start_scan(self):
        self.run_id += 1
        rid = self.run_id
        self.state = "scan"
        self.clear_body()
        self.error("")
        self.say("正在扫描 mDNS …", "每 2.5 秒一轮，扫到就自动连。按 Esc 手动输入。")
        self.dot_color(ACCENT)
        threading.Thread(target=self._scan_loop, args=(rid,), daemon=True).start()

    def _alive(self, rid):
        return rid == self.run_id

    def _scan_loop(self, rid):
        # 开扫前清一遍 adb 服务：死连接和旧 mDNS 缓存不清，会一直扫到已经没用的端口
        self.adb.run(["kill-server"], 10)
        t0 = time.time()
        n = 0
        fails = 0
        hinted = False

        while self._alive(rid):
            n += 1
            elapsed = int(time.time() - t0)
            self.ui_if(rid, lambda n=n, e=elapsed: self.say(
                "正在扫描 mDNS …",
                "第 %d 次 · 已等 %d 秒 · 按 Esc 手动输入" % (n, e)))

            targets = self.adb.connect_targets()
            self.notes.update(targets)

            for t in targets:
                if not self._alive(rid):
                    return
                self.ui_if(rid, lambda t=t: self.say("连接 %s …" % t, "mDNS 已报出端口，正在连"))
                ok, reason = self._try_connect(t)
                if ok:
                    self.ui_if(rid, lambda t=t: self._connected(t))
                    return
                if reason in ("handshake", "timeout"):
                    fails += 1
                    self.ui_if(rid, lambda f=fails: self.error(
                        "端口通，但没握上手（第 %d/%d 次）。" % (f, MAX_HANDSHAKE_FAILS)))
                    if fails >= MAX_HANDSHAKE_FAILS:
                        self.ui_if(rid, lambda: self.enter_pair(direct=True))
                        return
                else:
                    self.ui_if(rid, lambda: self.error(""))

            # 顺手看 adb：插着 USB、或上次的连接还活着，不用等 mDNS
            devs = self.adb.devices()
            online = [d for d in devs if d.state == "device"]
            pending = [d for d in devs if d.state != "device"]

            if len(online) == 1:
                self.ui_if(rid, lambda s=online[0].serial: self._connected(s))
                return
            if len(online) > 1:
                self.ui_if(rid, lambda lst=list(online): self.show_picker(lst))
                return

            if pending and not hinted:
                hinted = True
                d = pending[0]
                self.ui_if(rid, lambda d=d: self.error(
                    "adb 里有「%s」：%s（%s）— 多半是端口变了，继续等；不想等按 Esc。"
                    % (state_text(d.state), d.serial, link_kind(d.serial))))

            # 补足 2.5 秒间隔，期间随时能被 Esc 打断
            deadline = time.time() + SCAN_INTERVAL
            while time.time() < deadline and self._alive(rid):
                time.sleep(0.1)

    # ---- 单次连接 ----

    def _try_connect(self, target, attempts=1, timeout=20):
        """返回 (是否连上, 失败原因)。原因：port / handshake / timeout。"""
        hp = parse_hostport(target)
        if not hp:
            return False, "port"
        host, port = hp
        if not port_open(host, port):
            return False, "port"

        self.adb.disconnect_all()
        reason = "handshake"
        for i in range(attempts):
            if i:
                time.sleep(1.2)
            code, out, err, timed_out = self.adb.connect(target, timeout)
            if timed_out:
                reason = "timeout"
            time.sleep(0.7)
            if self.adb.is_online(target):
                return True, ""
            if timed_out:
                break
            text = (out or "") + (err or "")
            if "connected to" in text or "already connected" in text:
                on = [d for d in self.adb.devices() if d.state == "device"]
                if len(on) == 1:
                    return True, ""          # adb 登记的可能是别名，认这一台
        return False, reason

    # ============================================================ 连接成功 → 悬浮条

    def _connected(self, serial):
        self.device = serial
        self.state = "bar"
        self.error("")
        self.say("已连接", serial)
        self.dot_color(ACCENT)
        # 分辨率要跑 adb，别在 UI 线程里等
        threading.Thread(target=self._finish_connect, args=(serial,),
                         daemon=True).start()

    def _finish_connect(self, serial):
        size = None
        for _ in range(3):
            size = self.adb.screen_size(serial)
            if size:
                break
            time.sleep(0.6)
        if not size:
            self.ui(lambda: (self.error(
                "拿不到分辨率（adb shell wm size 失败），再试一次？"), self.show_retry()))
            return
        self.ui(lambda: self._open_bar(size))

    def _open_bar(self, size):
        self.size = size
        try:
            self.root.withdraw()
        except tk.TclError:
            return
        self.show_bar()

    def show_bar(self):
        if self.bar:
            self.bar.destroy()
        self.bar = Bar(self)
        self.bar.show_default()
        self.hotkeys.start()        # 悬浮条出现才占热键，没连上时不抢键

    # ============================================================ 手动连接模块

    def clear_body(self):
        for w in self.body.winfo_children():
            w.destroy()
        self.ok_btn = None
        self.ip_entry = None
        self.code_entry = None
        self.busy = False

    def _entry(self, parent, value="", width=17):
        e = tk.Entry(parent, bg=ENTRY_BG, fg=FG, insertbackground=FG,
                     relief="flat", font=(FONT, 10), width=width,
                     highlightthickness=px(1), highlightbackground=BORDER,
                     highlightcolor=ACCENT)
        e.insert(0, value)
        e.icursor("end")
        return e

    def _ok(self, parent, command, text="✓", color=ACCENT):
        b = tk.Button(parent, text=text, command=command, font=(SYMBOL_FONT, 12),
                      bg=BTN_BG, fg=color, activebackground=BTN_HOVER,
                      activeforeground=color, relief="flat", bd=0,
                      highlightthickness=0, width=3, cursor="hand2")
        b.bind("<Enter>", lambda e: b.configure(bg=BTN_HOVER))
        b.bind("<Leave>", lambda e: b.configure(bg=BTN_BG))
        return b

    def _scan_btn(self, parent):
        """⟳ —— 回到扫描模式。收起的图标按钮，跟 ✓ 排一起。"""
        return self._ok(parent, self.start_scan, "⟳", color=MUTED)

    def on_escape(self, _event=None):
        """Esc 只在扫描阶段有意义：停下扫描，长出输入模块。"""
        if self.state == "scan":
            self.run_id += 1              # 让扫描线程看到 run_id 变了，自己退出
            self.show_manual()
        elif self.state == "pair":
            self.show_manual()
        elif self.state == "pick":
            self.start_scan()

    def show_manual(self):
        self.state = "manual"
        self.clear_body()
        self.error("")
        self.say("手动连接", "手机『无线调试』主页上的 IP:端口。填完点 ✓ 或回车；点 ⟳ 回去继续扫描。")
        self.dot_color(WARN)

        f = tk.Frame(self.body, bg=BG)
        f.pack(fill="x")
        f.columnconfigure(1, weight=1)

        tk.Label(f, text="连接 IP:端口", bg=BG, fg=MUTED,
                 font=(FONT, 9)).grid(row=0, column=0, sticky="w")
        self.ip_entry = self._entry(f, "192.168.88.", 15)
        self.ip_entry.grid(row=0, column=1, sticky="we", padx=(px(10), px(8)))
        self.ok_btn = self._ok(f, self.do_manual)
        self.ok_btn.grid(row=0, column=2, sticky="ns")
        self._scan_btn(f).grid(row=0, column=3, sticky="ns", padx=(px(6), 0))

        self.ip_entry.bind("<Return>", lambda e: self.do_manual())
        self.ip_entry.focus_set()
        self.fit()

    def do_manual(self):
        if self.busy or self.state != "manual":
            return
        text = self.ip_entry.get().strip()
        hp = parse_hostport(text, 5555)
        if not hp or not text.isascii() or " " in text:
            self.error("地址不对，应该像 192.168.88.9:42123 这样（只认半角字符）。")
            return
        target = "%s:%d" % hp
        self.manual_cp = target
        self.notes.add(target)

        self.set_busy(True)
        self.error("")
        self.say("正在连接 %s …" % target, "先探端口，再 adb connect（最多 20 秒）")
        rid = self.run_id
        threading.Thread(target=self._manual_worker, args=(rid, target),
                         daemon=True).start()

    def _manual_worker(self, rid, target):
        host, port = parse_hostport(target)

        if not port_open(host, port):
            self.ui_if(rid, lambda: self.fail_manual(
                "%s 端口没开 —— 端口变了 / 无线调试关了 / IP 换了。回手机看一眼再填。" % target))
            return

        ok, reason = self._try_connect(target, attempts=3)
        if ok:
            self.ui_if(rid, lambda: self._connected(target))
            return
        if reason == "port":
            self.ui_if(rid, lambda: self.fail_manual("%s 端口没开，再确认一下端口。" % target))
        else:
            self.ui_if(rid, lambda: self.enter_pair(direct=False))

    def fail_manual(self, msg):
        self.set_busy(False)
        self.error(msg)
        self.say("手动连接", "改一下地址再点 ✓。", WARN)

    # ============================================================ 配对模块

    def enter_pair(self, direct=False):
        """连不上就换成配对模块，主动配对。direct=True 表示是扫描阶段转过来的。"""
        self.state = "pair"
        self.clear_body()
        self.dot_color(WARN)

        if direct:
            self.say("配对", "扫到的端口是通的，但三次都没握上手 —— 多半是没配对过，配一次就好。")
        else:
            self.say("配对", "没连上。手机上点『使用配对码配对设备』，抄弹窗里的地址和 6 位码。")

        hint_host = ""
        if self.manual_cp:
            hint_host = parse_hostport(self.manual_cp)[0]

        f = tk.Frame(self.body, bg=BG)
        f.pack(fill="x")
        f.columnconfigure(1, weight=1)

        tk.Label(f, text="配对 IP:端口", bg=BG, fg=MUTED,
                 font=(FONT, 9)).grid(row=0, column=0, sticky="w", pady=px(2))
        self.ip_entry = self._entry(f, (hint_host + ":") if hint_host else "192.168.88.", 15)
        self.ip_entry.grid(row=0, column=1, sticky="we", padx=(px(10), px(8)), pady=px(2))

        tk.Label(f, text="配对码", bg=BG, fg=MUTED,
                 font=(FONT, 9)).grid(row=1, column=0, sticky="w", pady=px(2))
        self.code_entry = self._entry(f, "", 15)
        self.code_entry.grid(row=1, column=1, sticky="we", padx=(px(10), px(8)), pady=px(2))

        self.ok_btn = self._ok(f, self.do_pair, "✓")
        self.ok_btn.grid(row=0, column=2, rowspan=2, sticky="ns")
        self._scan_btn(f).grid(row=0, column=3, rowspan=2, sticky="ns",
                               padx=(px(6), 0))

        back = tk.Label(f, text="← 返回手动连接", bg=BG, fg=MUTED,
                        font=(FONT, 8), cursor="hand2")
        back.grid(row=2, column=0, columnspan=3, sticky="w", pady=(px(6), 0))
        back.bind("<Button-1>", lambda e: self.show_manual())
        back.bind("<Enter>", lambda e: back.configure(fg=FG))
        back.bind("<Leave>", lambda e: back.configure(fg=MUTED))

        self.ip_entry.bind("<Return>", lambda e: self.code_entry.focus_set())
        self.code_entry.bind("<Return>", lambda e: self.do_pair())
        (self.code_entry if hint_host else self.ip_entry).focus_set()
        self.fit()

    def do_pair(self):
        if self.busy or self.state != "pair":
            return
        addr_text = self.ip_entry.get().strip()
        code = self.code_entry.get().strip()

        hp = parse_hostport(addr_text, 5555)
        if not hp or not addr_text.isascii() or " " in addr_text:
            self.error("配对地址不对，应该像 192.168.88.9:37123 这样。")
            return
        if not re.fullmatch(r"\d{6}", code):
            self.error("配对码是 6 位数字，在手机的配对弹窗里。")
            return

        addr = "%s:%d" % hp
        # 拿连接端口去配对必卡死：端口开着，但对面不是配对服务
        if addr in self.notes:
            self.error("%s 是【连接端口】，配对要填弹窗里那个（每次都不一样）。" % addr)
            return

        self.set_busy(True)
        self.error("")
        self.say("正在配对 %s …" % addr, "adb pair，最多等 20 秒")
        rid = self.run_id
        threading.Thread(target=self._pair_worker, args=(rid, addr, hp[0], code),
                         daemon=True).start()

    def _pair_worker(self, rid, addr, host, code):
        if not port_open(host, hp_port(addr), timeout=2.0):
            self.ui_if(rid, lambda: self.fail_pair(
                "%s 连不上 —— 手机上的配对弹窗还开着吗？弹窗一关端口就没了。" % addr))
            return

        code_, out, err, timed_out = self.adb.pair(addr, code)
        text = (out or "") + (err or "")
        if "Successfully paired" not in text:
            extra = "（adb pair 等了 20 秒没回应，那个端口上没有配对服务）" if timed_out else ""
            self.ui_if(rid, lambda: self.fail_pair(
                "配对没成功：配对码或端口过期了%s。弹窗重开会同时换掉这两个。" % extra))
            return

        # 配对成功后端口又变了：按 mDNS 现端口 → 刚才输的 → 5555 依次试
        time.sleep(1.2)
        candidates = []
        for c in self.adb.connect_targets(host=host):
            if c not in candidates:
                candidates.append(c)
        for c in (self.manual_cp, "%s:5555" % host):
            if c and c not in candidates:
                candidates.append(c)

        for c in candidates:
            if not self._alive(rid):
                return
            self.ui_if(rid, lambda c=c: self.say("配对成功，正在连接 %s …" % c, ""))
            ok, _ = self._try_connect(c, attempts=2)
            if ok:
                self.ui_if(rid, lambda c=c: self._connected(c))
                return

        self.ui_if(rid, lambda: self.fail_pair(
            "配对成功了，但重连没成功。手机上确认无线调试还开着，然后回手动连接填新端口。"))

    def fail_pair(self, msg):
        self.set_busy(False)
        self.error(msg)
        self.dot_color(WARN)

    def set_busy(self, busy, text=None):
        self.busy = busy
        if self.ok_btn is not None:
            try:
                self.ok_btn.configure(state="disabled" if busy else "normal",
                                      text=text or "✓")
            except tk.TclError:
                pass

    # ============================================================ 手势

    def gesture(self, kind):
        if self.state != "bar" or not self.device:
            return
        threading.Thread(target=self._gesture_worker, args=(kind,),
                         daemon=True).start()

    def _gesture_worker(self, kind):
        with self.gesture_lock:
            w, h = self.size
            if not w or not h:
                return
            x = w // 2
            if kind == "tap":
                code, out, err, _ = self.adb.input_tap(self.device, x, h // 2)
                what = "点按"
            else:
                near, far = int(h * NEAR_RATIO), int(h * FAR_RATIO)
                y1, y2 = (near, far) if kind == "up" else (far, near)
                code, out, err, _ = self.adb.input_swipe(self.device, x, y1, y2)
                what = "上滑" if kind == "up" else "下滑"

            if code == 0:
                self.ui(self.bar.clear_note if self.bar else (lambda: None))
                return

            online = self.adb.is_online(self.device)
            msg = "设备已离线" if not online else "%s失败" % what
            self.ui(lambda: self._bar_note(msg))

    def _bar_note(self, text):
        if self.bar:
            self.bar.note(text)

    def notify_hotkeys(self, failed):
        """热键被别的软件占了就说一声，不然按了没反应会以为坏了。

        条只有 4 个汉字宽，所以只报末位键名（F1 / F2 / F3），不再带前缀。
        """
        if self.bar and failed:
            keys = "、".join(f.split("+")[-1] for f in failed)
            self.bar.flash("%s 被占" % keys)

    # ============================================================ 多设备选择

    def show_picker(self, devices):
        self.state = "pick"
        self.clear_body()
        self.say("检测到 %d 台在线设备" % len(devices), "点一台用，或者按 Esc 重新扫描。")
        self.dot_color(ACCENT)

        box = tk.Frame(self.body, bg=BG)
        box.pack(fill="x")
        for d in devices:
            row = tk.Frame(box, bg=PANEL, cursor="hand2")
            row.pack(fill="x", pady=px(2))
            label = "%s   %s  (%s)" % (d.serial, d.model or "", link_kind(d.serial))
            lbl = tk.Label(row, text=label, bg=PANEL, fg=FG, font=(FONT, 9),
                           anchor="w", padx=px(8), pady=px(5), cursor="hand2")
            lbl.pack(fill="x")
            for w in (row, lbl):
                w.bind("<Button-1>", lambda e, s=d.serial: self._pick(s))
                w.bind("<Enter>", lambda e, l=lbl: l.configure(bg=BTN_HOVER))
                w.bind("<Leave>", lambda e, l=lbl: l.configure(bg=PANEL))
        self.fit()

    def _pick(self, serial):
        if self.state != "pick":
            return
        self.error("")
        self._connected(serial)

    def show_retry(self):
        self.state = "retry"
        self.clear_body()
        b = tk.Button(self.body, text="重试连接", command=lambda: self.start_scan(),
                      bg=BTN_BG, fg=FG, activebackground=BTN_HOVER,
                      relief="flat", bd=0, font=(FONT, 9), padx=px(12), pady=px(4),
                      cursor="hand2")
        b.pack(anchor="w")
        self.fit()

    # ============================================================ 重启 / 退出

    def restart(self):
        self.hotkeys.stop()
        if self.bar:
            self.bar.destroy()
            self.bar = None
        self.device = ""
        self.size = (0, 0)
        self.manual_cp = None
        self.notes.clear()
        try:
            self.root.deiconify()
            self.root.lift()
        except tk.TclError:
            return
        self.start_scan()

    def quit(self):
        self.hotkeys.stop()
        self._closed = True
        self.run_id += 1
        try:
            if getattr(self, "_pump_id", None):
                self.root.after_cancel(self._pump_id)
        except tk.TclError:
            pass
        try:
            self.root.destroy()
        except tk.TclError:
            pass

    def run(self):
        self.root.mainloop()


def hp_port(addr):
    hp = parse_hostport(addr)
    return hp[1] if hp else 0


def main():
    try:
        App().run()
    except Exception:                                  # noqa: BLE001
        import traceback
        import tempfile
        path = os.path.join(tempfile.gettempdir(), "adb-watchV-error.log")
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(traceback.format_exc())
        try:
            from tkinter import messagebox
            messagebox.showerror(APP_NAME, "启动失败，日志：\n" + path)
        except Exception:                              # noqa: BLE001
            pass
        raise


if __name__ == "__main__":
    main()
