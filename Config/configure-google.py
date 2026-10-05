#!/usr/bin/env python3
"""Configure the public Google iOS OAuth client; never accepts a client secret."""
import re
import sys
from pathlib import Path

if len(sys.argv) != 2 or not re.fullmatch(r"[A-Za-z0-9-]+\.apps\.googleusercontent\.com", sys.argv[1]):
    raise SystemExit("Usage: python3 Config/configure-google.py CLIENT_ID.apps.googleusercontent.com")
client_id = sys.argv[1]
reversed_id = ".".join(reversed(client_id.split(".")))
path = Path(__file__).with_name("Google.local.xcconfig")
path.write_text(f"GOOGLE_CLIENT_ID = {client_id}\nGOOGLE_REVERSED_CLIENT_ID = {reversed_id}\n")
print(f"Configured {path}. Rebuild Hestrel to apply it.")
