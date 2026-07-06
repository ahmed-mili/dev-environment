"""Outils génériques Win32 : localiser une fenêtre par processus, la capturer,
l'activer, et envoyer des raccourcis clavier.

Ces fonctions sont indépendantes du jeu Fortnite ; elles servent aussi pour
Obsidian ou n'importe quelle autre application Windows.
"""
from __future__ import annotations

from ctypes import windll
from typing import Any

import numpy as np
import psutil
import win32api
import win32con
import win32gui
import win32process
import win32ui

# Flags PrintWindow.
_PW_RENDERFULLCONTENT = 0x00000002  # nécessaire pour les fenêtres GPU/DirectX

WindowInfo = dict[str, int]


def _process_name(hwnd: int) -> str:
    try:
        pid = win32process.GetWindowThreadProcessId(hwnd)[1]
        return psutil.Process(pid).name()
    except Exception:
        return ""


def find_window_by_process(process_name: str) -> WindowInfo | None:
    """Cherche la fenêtre principale du processus donné.

    S'il y a plusieurs fenêtres pour ce processus, on garde la plus grande
    visible. Retourne None si le processus n'est pas lancé.
    """
    target = process_name.lower()
    candidates: list[WindowInfo] = []

    def cb(hwnd: int, _: Any) -> None:
        if not win32gui.IsWindowVisible(hwnd):
            return
        if _process_name(hwnd).lower() != target:
            return
        # Client rect (zone interne, sans bordures).
        l, t, r, b = win32gui.GetClientRect(hwnd)
        w, h = r - l, b - t
        if w <= 0 or h <= 0:
            return
        # Position absolue à l'écran du coin haut-gauche du client area.
        sx, sy = win32gui.ClientToScreen(hwnd, (0, 0))
        candidates.append({
            "hwnd": int(hwnd),
            "left": int(sx),
            "top": int(sy),
            "width": int(w),
            "height": int(h),
        })

    win32gui.EnumWindows(cb, None)
    if not candidates:
        return None
    return max(candidates, key=lambda w: w["width"] * w["height"])


def list_processes(query: str) -> list[str]:
    """Liste les noms de processus dont le nom contient *query* (case-insensitive)."""
    out: list[str] = []
    for p in psutil.process_iter(["name"]):
        try:
            n = p.info["name"] or ""
            if query.lower() in n.lower():
                out.append(n)
        except Exception:
            continue
    return out


def capture_window(hwnd: int, width: int, height: int) -> np.ndarray | None:
    """Capture le contenu de la fenêtre via PrintWindow. Retourne BGR ndarray.

    Marche même si une autre app est en avant-plan. Pour DirectX/Unreal il
    FAUT le flag PW_RENDERFULLCONTENT, sinon on récupère un cadre noir.
    Renvoie None si la capture échoue.
    """
    hwnd_dc = win32gui.GetWindowDC(hwnd)
    mfc_dc = win32ui.CreateDCFromHandle(hwnd_dc)
    save_dc = mfc_dc.CreateCompatibleDC()
    bmp = win32ui.CreateBitmap()
    bmp.CreateCompatibleBitmap(mfc_dc, width, height)
    save_dc.SelectObject(bmp)
    try:
        result = windll.user32.PrintWindow(hwnd, save_dc.GetSafeHdc(), _PW_RENDERFULLCONTENT)
        if result != 1:
            return None
        info = bmp.GetInfo()
        raw = bmp.GetBitmapBits(True)
        # raw = BGRX (4 octets/pixel, X = padding). On reshape et drop X → BGR.
        arr = np.frombuffer(raw, dtype=np.uint8).reshape(
            (info["bmHeight"], info["bmWidth"], 4)
        )
        return arr[:, :, :3].copy()  # BGR, ce que veut OpenCV
    finally:
        win32gui.DeleteObject(bmp.GetHandle())
        save_dc.DeleteDC()
        mfc_dc.DeleteDC()
        win32gui.ReleaseDC(hwnd, hwnd_dc)


def crop(img: np.ndarray, region: dict[str, int]) -> np.ndarray:
    """Crop une zone (left/top/width/height) dans l'image capturée."""
    l, t, w, h = region["left"], region["top"], region["width"], region["height"]
    H, W = img.shape[:2]
    l2, t2 = max(0, l), max(0, t)
    r2, b2 = min(W, l + w), min(H, t + h)
    return img[t2:b2, l2:r2]


def focus_window(hwnd: int) -> bool:
    """Met la fenêtre au premier plan (même si minimisée ou en arrière-plan).

    Utilise AttachThreadInput pour contourner la restriction Windows sur
    SetForegroundWindow. Retourne True si le focus a été accordé.
    """
    if win32gui.IsIconic(hwnd):
        win32gui.ShowWindow(hwnd, win32con.SW_RESTORE)

    # Tentative directe (peut échouer si le processus n'a pas le focus).
    try:
        win32gui.SetForegroundWindow(hwnd)
    except Exception:
        pass
    if win32gui.GetForegroundWindow() == hwnd:
        return True

    # Contournement par AttachThreadInput.
    foreground_hwnd = win32gui.GetForegroundWindow()
    if foreground_hwnd == 0:
        # Pas de fenêtre au premier plan — tentative directe uniquement
        try:
            win32gui.SetForegroundWindow(hwnd)
        except Exception:
            pass
        return win32gui.GetForegroundWindow() == hwnd

    foreground_thread = win32process.GetWindowThreadProcessId(foreground_hwnd)[0]
    target_thread = win32process.GetWindowThreadProcessId(hwnd)[0]

    if foreground_thread != target_thread and foreground_thread != 0 and target_thread != 0:
        win32process.AttachThreadInput(foreground_thread, target_thread, True)
        try:
            win32gui.SetForegroundWindow(hwnd)
        except Exception:
            pass
        finally:
            win32process.AttachThreadInput(foreground_thread, target_thread, False)

    return win32gui.GetForegroundWindow() == hwnd


def send_keys_ctrl_r() -> None:
    """Simule un appui sur Ctrl+R via keybd_event natif.

    Nécessite que la fenêtre cible soit au premier plan (appeler focus_window
    juste avant).
    """
    import time

    # Ctrl down
    win32api.keybd_event(win32con.VK_CONTROL, 0, 0, 0)
    # R down
    win32api.keybd_event(0x52, 0, 0, 0)  # VK_R
    time.sleep(0.05)
    # R up
    win32api.keybd_event(0x52, 0, win32con.KEYEVENTF_KEYUP, 0)
    # Ctrl up
    win32api.keybd_event(win32con.VK_CONTROL, 0, win32con.KEYEVENTF_KEYUP, 0)
    time.sleep(0.05)


def send_keys_ctrl_shift_r() -> None:
    """Simule un appui sur Ctrl+Shift+R (hard reload app) via keybd_event."""
    import time

    # Ctrl down
    win32api.keybd_event(win32con.VK_CONTROL, 0, 0, 0)
    # Shift down
    win32api.keybd_event(win32con.VK_SHIFT, 0, 0, 0)
    # R down
    win32api.keybd_event(0x52, 0, 0, 0)  # VK_R
    time.sleep(0.05)
    # R up
    win32api.keybd_event(0x52, 0, win32con.KEYEVENTF_KEYUP, 0)
    # Shift up
    win32api.keybd_event(win32con.VK_SHIFT, 0, win32con.KEYEVENTF_KEYUP, 0)
    # Ctrl up
    win32api.keybd_event(win32con.VK_CONTROL, 0, win32con.KEYEVENTF_KEYUP, 0)
    time.sleep(0.05)


def send_keys_page_down() -> None:
    '''Simule un appui sur Page Down via keybd_event natif.'''
    import time
    win32api.keybd_event(win32con.VK_NEXT, 0, 0, 0)  # VK_NEXT = Page Down
    time.sleep(0.05)
    win32api.keybd_event(win32con.VK_NEXT, 0, win32con.KEYEVENTF_KEYUP, 0)
    time.sleep(0.05)



def scroll_mouse_down(hwnd: int, clicks: int = 1) -> None:
    '''Scroll la molette de la souris vers le bas dans la zone de contenu.'''
    import time
    rect = win32gui.GetWindowRect(hwnd)
    sidebar = 48
    cx = max(rect[0] + sidebar + 80, (rect[0] + rect[2]) // 2)
    cy = (rect[1] + rect[3]) // 2 + 60
    win32api.SetCursorPos((cx, cy))
    time.sleep(0.15)
    for _ in range(clicks):
        win32api.mouse_event(win32con.MOUSEEVENTF_WHEEL, 0, 0, -120 * 5, 0)
        time.sleep(0.20)

