#!/usr/bin/env python
# Generate a secret key for settings_local.py

from random import choice
from string import printable

secret = ''
while len(secret) < 64:
    n = choice(printable)
    if n not in "'  \t\n\r\x0b\x0c":
        secret += n
print secret
