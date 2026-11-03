#!/usr/bin/env python3
"""Rellena una plantilla con las variables del entorno.

Uso: render.py <plantilla> <destino>

Sustituye ${VAR}; si falta alguna variable, falla en vez de dejar el hueco.
Para cada variable existe también ${Q_VAR}: el valor entre comillas dobles y escapado
(JSON, que es YAML válido), para contraseñas con caracteres raros.
"""
import json
import os
import string
import sys


def main() -> int:
    src, dst = sys.argv[1], sys.argv[2]
    values = dict(os.environ)
    values.update({f"Q_{k}": json.dumps(v) for k, v in os.environ.items()})
    with open(src, encoding="utf-8") as f:
        template = string.Template(f.read())
    try:
        text = template.substitute(values)
    except KeyError as e:
        print(f"Falta la variable {e} para {src}", file=sys.stderr)
        return 1
    old_umask = os.umask(0o077)
    try:
        with open(dst, "w", encoding="utf-8") as f:
            f.write(text)
        os.chmod(dst, 0o600)
    finally:
        os.umask(old_umask)
    return 0


if __name__ == "__main__":
    sys.exit(main())
