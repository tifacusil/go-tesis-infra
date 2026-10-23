"""Inventaria y copia los reportes JSON de Artillery de load-tests/results/A y B.

Hace en Python, sin dependencias, lo mismo que Recuperar-Artillery.ps1 limitado
a A y B, mas el renombrado con prefijo A_/B_. Los originales solo se leen:
nunca se modifican ni se borran.

Uso, desde la raiz del repo:
    py load-tests/recuperar_artillery.py
    py load-tests/recuperar_artillery.py --salida otra/carpeta

Correrlo otra vez sirve de verificacion: no sobrescribe nada y vuelve a comparar
el SHA256 de cada copia con su original.
"""
import argparse
import csv
import hashlib
import json
import shutil
import sys
from datetime import datetime, timezone
from pathlib import Path

AQUI = Path(__file__).resolve().parent
RAIZ_REPO = AQUI.parent
CARPETAS = [AQUI / "results" / "A", AQUI / "results" / "B"]  # el nombre es el prefijo de la copia
MIN_VENTANAS = 40  # una corrida de 10 min da unas 60 ventanas de 10 s
COLUMNAS = ["Sistema", "Original", "Copia", "Estado", "Ventanas", "InicioUTC",
            "FinUTC", "MB", "SHA256", "Metricas", "P95Agregado"]


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for bloque in iter(lambda: f.read(1 << 20), b""):
            h.update(bloque)
    return h.hexdigest().upper()


def utc(ms):
    if not ms:
        return ""
    return datetime.fromtimestamp(int(ms) / 1000, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def relativa(path):
    try:
        return path.resolve().relative_to(RAIZ_REPO).as_posix()
    except ValueError:
        return str(path.resolve())


def diagnosticar(path):
    fila = {"Ventanas": 0, "InicioUTC": "", "FinUTC": "", "Metricas": "", "P95Agregado": ""}
    try:
        j = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as e:
        return fila | {"Estado": f"ERROR al leer JSON: {e}"}

    agregado = j.get("aggregate") if isinstance(j, dict) else None
    agregado = agregado if isinstance(agregado, dict) else {}
    ventanas = j.get("intermediate") if isinstance(j, dict) else None
    resumenes = agregado.get("summaries")

    fila["Ventanas"] = len(ventanas) if isinstance(ventanas, list) else 0
    fila["InicioUTC"] = utc(agregado.get("firstMetricAt"))
    fila["FinUTC"] = utc(agregado.get("lastMetricAt"))
    if isinstance(resumenes, dict):
        fila["Metricas"] = " | ".join(resumenes)
        fila["P95Agregado"] = " | ".join(
            f"{nombre}={v['p95']}" for nombre, v in resumenes.items()
            if isinstance(v, dict) and v.get("p95") is not None)

    if resumenes and fila["Ventanas"] >= MIN_VENTANAS:
        fila["Estado"] = "SIRVE: ventanas + agregado"
    elif resumenes:
        fila["Estado"] = "PARCIAL: agregado sin ventanas suficientes"
    else:
        fila["Estado"] = "NO SIRVE: sin summaries"
    return fila


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--salida", type=Path, default=AQUI / "results" / "recuperacion",
                   help="carpeta del inventario y las copias (default: load-tests/results/recuperacion)")
    args = p.parse_args()

    copias = args.salida / "reportes"
    copias.mkdir(parents=True, exist_ok=True)

    filas = []
    for carpeta in CARPETAS:
        if not carpeta.is_dir():
            sys.exit(f"No existe la carpeta: {carpeta}")
        for f in sorted(carpeta.glob("*.json")):
            fila = {"Sistema": carpeta.name, "Original": relativa(f), "Copia": "",
                    "MB": round(f.stat().st_size / 2**20, 2), "SHA256": sha256(f)}
            fila |= diagnosticar(f)
            if fila["Estado"].startswith("SIRVE"):
                destino = copias / f"{carpeta.name}_{f.name}"
                if not destino.exists():
                    shutil.copy2(f, destino)
                if sha256(destino) != fila["SHA256"]:
                    sys.exit(f"La copia no coincide con el original: {destino}\n"
                             "No se sobrescribe nada; revisala a mano.")
                fila["Copia"] = relativa(destino)
            filas.append(fila)
            print(f"{fila['Sistema']}  {f.name:<22} {fila['Ventanas']:>5}  {fila['Estado']}")

    filas.sort(key=lambda r: (r["InicioUTC"], r["Sistema"], r["Original"]))
    inventario = args.salida / "inventario-reportes.csv"
    with open(inventario, "w", newline="", encoding="utf-8-sig") as f:
        w = csv.DictWriter(f, fieldnames=COLUMNAS)
        w.writeheader()
        w.writerows(filas)

    sirven = sum(r["Estado"].startswith("SIRVE") for r in filas)
    print(f"\n{len(filas)} JSON revisados, {sirven} SIRVE, {len(filas) - sirven} no sirven o parciales.")
    print(f"Copias verificadas por SHA256 en: {copias.resolve()}")
    print(f"Inventario: {inventario.resolve()}")


if __name__ == "__main__":
    main()
