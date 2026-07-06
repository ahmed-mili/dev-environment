"""Outils pour capturer/actualiser la fenêtre Obsidian depuis Claude Code.

Usage :
    python obsidian_tools.py --capture --output capture.png
    python obsidian_tools.py --refresh          # Ctrl+R sur Obsidian
    python obsidian_tools.py --find             # infos de la fenêtre
"""
from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

import cv2
import numpy as np

import window_tools

OBSIDIAN_PROCESS = "Obsidian.exe"

# CLI officiel d'Obsidian (bundlé avec l'app desktop, cf. help.obsidian.md/cli).
# Sur Windows c'est `Obsidian.com` (variante console de Obsidian.exe). Il pilote
# l'instance Obsidian EN COURS via son API JS — donc SANS toucher au premier plan.
_OBSIDIAN_CLI_FALLBACK = r"C:\Program Files\Obsidian\Obsidian.com"


def _obsidian_cli() -> str | None:
    """Localise le CLI Obsidian (`obsidian` sur le PATH, sinon chemin d'install)."""
    exe = shutil.which("obsidian") or shutil.which("Obsidian.com")
    if exe:
        return exe
    return _OBSIDIAN_CLI_FALLBACK if os.path.exists(_OBSIDIAN_CLI_FALLBACK) else None


def _obsidian_eval(code: str) -> tuple[bool, str]:
    """Exécute du JS dans l'Obsidian en cours via le CLI (sans premier plan).

    Retourne (ok, sortie). Le CLI imprime `=> <résultat>` en cas de succès ; si le
    JS lève une exception, la sortie est vide (le CLI n'imprime rien) → ok=False.
    Emballe toujours ton code pour renvoyer une chaîne sentinelle non vide.
    """
    exe = _obsidian_cli()
    if exe is None:
        return False, "CLI Obsidian (Obsidian.com) introuvable"
    try:
        proc = subprocess.run(
            [exe, "eval", f"code={code}"],
            capture_output=True,
            text=True,
            timeout=20,
        )
    except Exception as exc:  # noqa: BLE001 — on veut le repli clavier quoi qu'il arrive
        return False, f"échec d'exécution du CLI : {exc}"
    out = (proc.stdout or "").strip()
    err = (proc.stderr or "").strip()
    ok = proc.returncode == 0 and out.startswith("=>") and out != "=> undefined"
    return ok, out or err or "(sortie vide — le JS a peut-être levé une exception)"


def _find_obsidian() -> dict[str, int] | None:
    """Trouve la fenêtre Obsidian ; essaye des variantes de nom si besoin."""
    info = window_tools.find_window_by_process(OBSIDIAN_PROCESS)
    if info is None:
        # Variante portable (Obsidian appelé autrement) ?
        for alt in ["Obsidian.exe"]:
            info = window_tools.find_window_by_process(alt)
            if info is not None:
                break
    return info


def do_capture(output_path: Path | None = None) -> Path:
    """Capture la fenêtre Obsidian entière (PrintWindow) et sauvegarde un PNG.

    Retourne le chemin du fichier écrit.
    """
    info = _find_obsidian()
    if info is None:
        procs = window_tools.list_processes("obsidian")
        print(f"⚠️  Processus '{OBSIDIAN_PROCESS}' introuvable.")
        if procs:
            print(f"   Processus 'obsidian*' actifs : {procs}")
        else:
            print("   Lance Obsidian puis réessaie.")
        sys.exit(1)

    img = window_tools.capture_window(info["hwnd"], info["width"], info["height"])
    if img is None:
        print("⚠️  PrintWindow a échoué (image noire / mode rendu GPU non compatible ?).")
        sys.exit(1)

    if output_path is None:
        fd, output_path_str = tempfile.mkstemp(suffix="_obsidian.png", prefix="capture_")
        output_path = Path(output_path_str)

    output_path.parent.mkdir(parents=True, exist_ok=True)
    cv2.imwrite(str(output_path), img)
    print(f"✅ Capture Obsidian → {output_path}")
    print(f"   Taille : {info['width']}×{info['height']} (hwnd={info['hwnd']})")
    return output_path


def _keystroke_refresh() -> None:
    """Repli : focus + Ctrl+R clavier (exige le premier plan)."""
    info = _find_obsidian()
    if info is None:
        print("⚠️  Obsidian introuvable.")
        sys.exit(1)
    if not window_tools.focus_window(info["hwnd"]):
        print("⚠️  Impossible de mettre Obsidian au premier plan (repli clavier échoué).")
        sys.exit(1)
    time.sleep(0.15)
    window_tools.send_keys_ctrl_r()
    print("✅ Ctrl+R envoyé à Obsidian (repli clavier, premier plan).")


def _keystroke_hard_reload() -> None:
    """Repli : focus + Ctrl+Shift+R clavier (exige le premier plan)."""
    info = _find_obsidian()
    if info is None:
        print("⚠️  Obsidian introuvable.")
        sys.exit(1)
    if not window_tools.focus_window(info["hwnd"]):
        print("⚠️  Impossible de mettre Obsidian au premier plan (repli clavier échoué).")
        sys.exit(1)
    time.sleep(0.15)
    window_tools.send_keys_ctrl_shift_r()
    print("✅ Ctrl+Shift+R envoyé à Obsidian (repli clavier, premier plan).")


def do_refresh() -> None:
    """Recharge les snippets CSS d'Obsidian SANS le mettre au premier plan.

    Passe par le CLI Obsidian (`app.customCss.requestLoadSnippets()`) : le CSS est
    ré-appliqué au DOM en direct, idéal pour vérifier une modif de snippet. Repli
    sur Ctrl+R clavier (focus requis) si le CLI est indisponible.
    """
    ok, out = _obsidian_eval(
        "(async()=>{await app.customCss.requestLoadSnippets();return 'css-reloaded'})()"
    )
    if ok:
        print("✅ Snippets CSS rechargés via le CLI Obsidian (sans premier plan).")
        return
    print(f"ℹ️  CLI Obsidian indisponible ({out}) — repli clavier Ctrl+R.")
    _keystroke_refresh()


def do_hard_reload() -> None:
    """Reload complet du renderer Obsidian SANS le mettre au premier plan.

    Passe par le CLI Obsidian (`location.reload()`, équivalent exact de Ctrl+R
    côté Chromium) déclenché en `setTimeout` pour que le CLI réponde avant que la
    page ne se recharge. Repli sur Ctrl+Shift+R clavier si le CLI est indisponible.
    """
    ok, out = _obsidian_eval("setTimeout(()=>location.reload(),60);'reloading'")
    if ok:
        print("✅ Reload complet du renderer déclenché via le CLI Obsidian (sans premier plan).")
        return
    print(f"ℹ️  CLI Obsidian indisponible ({out}) — repli clavier Ctrl+Shift+R.")
    _keystroke_hard_reload()


def do_find() -> None:
    """Affiche les infos de la fenêtre Obsidian détectée."""
    info = _find_obsidian()
    if info is None:
        print("⚠️  Obsidian introuvable.")
        sys.exit(1)
    print(
        f"hwnd={info['hwnd']} | {info['width']}×{info['height']} | "
        f"screen=({info['left']},{info['top']})"
    )


# JS : localise le VRAI conteneur scrollable de la note (mode lecture OU édition).
# `querySelector` sur une liste renvoie le 1er élément dans l'ordre du DOM, pas par
# priorité de sélecteur — d'où des .cm-scroller cachés (0×0) attrapés à tort. On
# filtre donc sur "visible ET scrollable", en préférant la feuille active, sinon le
# plus grand contenu.
_FIND_SCROLLER_JS = (
    "const c=[...document.querySelectorAll('.markdown-preview-view,.cm-scroller')]"
    ".filter(e=>e.clientHeight>50&&e.scrollHeight>e.clientHeight+4);"
    "const s=c.find(e=>e.closest('.workspace-leaf.mod-active'))"
    "||c.sort((a,b)=>b.scrollHeight-a.scrollHeight)[0];"
)


def _obsidian_scroll(fraction: float) -> tuple[bool, str]:
    """Fait défiler la note active de `fraction` de sa hauteur visible (sans focus)."""
    code = (
        "(()=>{" + _FIND_SCROLLER_JS
        + "if(!s)return 'no-scroller';const b=s.scrollTop;"
        "s.scrollTop=Math.min(s.scrollHeight,b+Math.round(s.clientHeight*%s));"
        "return b+'->'+s.scrollTop+'/'+s.scrollHeight;})()"
    ) % fraction
    return _obsidian_eval(code)


def _obsidian_scroll_top() -> tuple[bool, str]:
    """Remet la note active tout en haut (sans focus)."""
    code = (
        "(()=>{" + _FIND_SCROLLER_JS
        + "if(!s)return 'no-scroller';s.scrollTop=0;return 'top';})()"
    )
    return _obsidian_eval(code)


def do_scroll_capture(output_dir: Path | None = None, max_pages: int = 12) -> list[Path]:
    """Capture l'ensemble du document en le faisant défiler, SANS premier plan.

    Le défilement passe par le CLI Obsidian (scroll JS de la feuille active) : ni
    focus ni frappe clavier. Repli sur Page Down clavier (Obsidian au premier plan
    requis) si le CLI est indisponible. S'arrête quand le contenu n'avance plus.
    """
    info = _find_obsidian()
    if info is None:
        print("⚠️  Obsidian introuvable.")
        sys.exit(1)

    use_cli = _obsidian_cli() is not None
    if use_cli:
        _obsidian_scroll_top()
        time.sleep(0.4)
    else:
        print(
            "ℹ️  CLI Obsidian indisponible — défilement clavier "
            "(Obsidian doit être au premier plan)."
        )

    if output_dir is None:
        output_dir = Path(tempfile.gettempdir()) / "obsidian_scroll"
    output_dir.mkdir(parents=True, exist_ok=True)

    paths: list[Path] = []
    prev_img: np.ndarray | None = None
    threshold = 1.5  # seuil de diff moyenne (pixels BGR)

    for i in range(1, max_pages + 1):
        img = window_tools.capture_window(info["hwnd"], info["width"], info["height"])
        if img is None:
            print(f"⚠️  Capture {i} échouée, arrêt.")
            break

        # Vérifier si on est arrivé en bas (comparaison avec la capture précédente)
        if prev_img is not None and img.shape == prev_img.shape:
            diff = cv2.absdiff(prev_img, img)
            mean_diff = float(np.mean(diff))
            if mean_diff < threshold:
                print(f"🛑 Fin du document détectée (diff={mean_diff:.2f} < {threshold}).")
                break

        path = output_dir / f"scroll_{i:03d}.png"
        cv2.imwrite(str(path), img)
        paths.append(path)
        print(f"✅ Capture {i} → {path}")

        if use_cli:
            ok, pos = _obsidian_scroll(0.9)
            if not ok:
                print(f"⚠️  Défilement CLI échoué ({pos}) — arrêt.")
                break
        else:
            window_tools.send_keys_page_down()  # exige le premier plan
        time.sleep(0.8)  # laisser le temps au rendu

        prev_img = img

    print(f"🎉 {len(paths)} captures sauvegardées dans {output_dir}")
    return paths


def main() -> None:
    parser = argparse.ArgumentParser(description="Outils capture/refresh Obsidian")
    parser.add_argument(
        "--capture",
        action="store_true",
        help="prend un screenshot de la fenêtre Obsidian entière",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=None,
        help="chemin de sortie PNG (défaut : fichier temporaire)",
    )
    parser.add_argument(
        "--refresh",
        action="store_true",
        help="recharge les snippets CSS via le CLI Obsidian (sans premier plan ; repli Ctrl+R clavier)",
    )
    parser.add_argument(
        "--hard-reload",
        dest="hard_reload",
        action="store_true",
        help="reload complet du renderer via le CLI Obsidian (sans premier plan ; repli Ctrl+Shift+R clavier)",
    )
    parser.add_argument(
        "--find",
        action="store_true",
        help="affiche les infos de la fenêtre Obsidian",
    )
    parser.add_argument(
        "--scroll-capture",
        dest="scroll_capture",
        action="store_true",
        help="capture tout le document en le faisant défiler via le CLI Obsidian (sans premier plan)",
    )
    parser.add_argument(
        "--scroll-dir",
        dest="scroll_dir",
        type=Path,
        default=None,
        help="dossier de sortie pour --scroll-capture (défaut : dossier temp)",
    )
    args = parser.parse_args()

    if args.capture:
        do_capture(args.output)
    elif args.refresh:
        do_refresh()
    elif args.hard_reload:
        do_hard_reload()
    elif args.scroll_capture:
        do_scroll_capture(args.scroll_dir)
    elif args.find:
        do_find()
    else:
        parser.print_help()
        sys.exit(1)


if __name__ == "__main__":
    main()
