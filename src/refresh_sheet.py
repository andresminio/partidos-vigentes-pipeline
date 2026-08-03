import os
import urllib.request

# La URL y el token viven en refresh_config.py (gitignoreado) o en variables de
# entorno; nunca en este archivo, para no filtrarlos al repo público.
try:
    from refresh_config import URL, TOKEN
except ImportError:
    URL = os.environ.get("SHEET_WEBAPP_URL", "")
    TOKEN = os.environ.get("SHEET_WEBAPP_TOKEN", "")


def main():
    if not URL or not TOKEN:
        print("Falta configurar URL/TOKEN (refresh_config.py o variables de entorno).")
        return

    with urllib.request.urlopen(f"{URL}?token={TOKEN}", timeout=180) as resp:
        print(resp.read().decode())


if __name__ == "__main__":
    main()
