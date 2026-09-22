import os
import urllib.request

# Las URLs y el token viven en refresh_config.py (gitignoreado) o en variables de
# entorno; nunca en este archivo, para no filtrarlos al repo público.
try:
    from refresh_config import URLS, TOKEN
except ImportError:
    TOKEN = os.environ.get("SHEET_WEBAPP_TOKEN", "")
    # Fallback: una o varias URLs separadas por coma en SHEET_WEBAPP_URL.
    _urls = os.environ.get("SHEET_WEBAPP_URL", "")
    URLS = {u.strip(): u.strip() for u in _urls.split(",") if u.strip()}


def refrescar(nombre, url):
    with urllib.request.urlopen(f"{url}?token={TOKEN}", timeout=180) as resp:
        print(f"OK: {nombre} -> {resp.read().decode()}")


def main():
    if not URLS or not TOKEN:
        print("Falta configurar URLS/TOKEN (refresh_config.py o variables de entorno).")
        return

    for nombre, url in URLS.items():
        refrescar(nombre, url)


if __name__ == "__main__":
    main()
