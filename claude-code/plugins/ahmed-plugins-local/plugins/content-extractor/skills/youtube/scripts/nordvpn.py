"""
nordvpn.py — Repli NordVPN quand YouTube bloque l'IP (IpBlocked / RequestBlocked / 429).

Pilote l'app NordVPN Windows par sa ligne de commande officielle (support.nordvpn.com,
« Connect to NordVPN (Windows) with Command Prompt ») : `NordVPN.exe -c [-g <pays>]` et `-d`.
L'app doit être installée et connectée au compte (elle tourne en tâche de fond).
Le Windows CLI n'a pas de commande « status » : l'état se lit sur la carte réseau du tunnel
(NordLynx ou OpenVPN Data Channel Offload for NordVPN) via Get-NetAdapter.

Accord d'Ahmed (2026-10-18) : connecter seul en cas de blocage, puis déconnecter à la fin.
"""
import os
import subprocess
import time

EXE = os.path.join(os.environ.get("ProgramFiles", r"C:\Program Files"), "NordVPN", "NordVPN.exe")
COUNTRIES = ["France", "Germany", "Netherlands", "Belgium", "Switzerland"]
_PS_UP = ("@(Get-NetAdapter -IncludeHidden | Where-Object { $_.InterfaceDescription -match "
          "'NordLynx|OpenVPN Data Channel Offload' -and $_.Status -eq 'Up' }).Count")
_next = 0


def available() -> bool:
    return os.name == "nt" and os.path.exists(EXE)


def is_connected() -> bool:
    try:
        out = subprocess.run(["powershell", "-NoProfile", "-Command", _PS_UP],
                             capture_output=True, text=True, timeout=20).stdout.strip()
        return out not in ("", "0")
    except Exception:
        return False


def _cli(*flags):
    try:
        subprocess.run([EXE, *flags], capture_output=True, timeout=60)
    except Exception:
        pass  # l'état réel est vérifié ensuite sur la carte réseau


def _wait(up: bool, timeout: float) -> bool:
    end = time.time() + timeout
    while time.time() < end:
        if is_connected() == up:
            return True
        time.sleep(2)
    return False


def connect(timeout: float = 60):
    """Connecte au pays suivant de COUNTRIES (déconnecte d'abord si déjà connecté, pour changer d'IP).
    Retourne le pays si le tunnel est monté, sinon None."""
    global _next
    if is_connected():
        disconnect()
    country = COUNTRIES[_next % len(COUNTRIES)]
    _next += 1
    _cli("-c", "-g", country)
    if not _wait(True, timeout):
        return None
    time.sleep(5)  # routes et DNS du tunnel
    return country


def disconnect(timeout: float = 30) -> bool:
    _cli("-d")
    return _wait(False, timeout)
