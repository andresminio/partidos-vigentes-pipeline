import os
import urllib.request

from secrets_loader import load_secrets

load_secrets()
URL = os.environ.get("SHEET_WEBAPP_URL", "")
TOKEN = os.environ.get("SHEET_WEBAPP_TOKEN", "")


def main():
    if not URL or not TOKEN:
        print("Falta configurar SHEET_WEBAPP_URL/SHEET_WEBAPP_TOKEN en Bitwarden.")
        return

    with urllib.request.urlopen(f"{URL}?token={TOKEN}", timeout=180) as resp:
        print(resp.read().decode())


if __name__ == "__main__":
    main()
