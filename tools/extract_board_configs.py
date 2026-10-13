#!/usr/bin/env python3
"""
Klipperizer — Extrator de configs do guia canbus.esoterical.online

Varre o repositório Esoterical/voron_canbus, baixa os screenshots de
menuconfig (Katapult e Klipper) de cada placa e os envia para um modelo
de visão para transcrever as opções CONFIG_* em YAML.

Uso:
  python3 tools/extract_board_configs.py --list          # lista as placas
  python3 tools/extract_board_configs.py --board "EBB36" # extrai uma placa
  python3 tools/extract_board_configs.py --all           # extrai todas

Requer: pip install requests  +  uma chave de API de visão configurada
via variável de ambiente (VISION_API_KEY).
"""
import argparse
import base64
import os
import re
import sys
import urllib.request

API_BASE = "https://api.github.com/repos/Esoterical/voron_cannus/contents"
# Nota: ajuste o nome do repositório se necessário (Esoterical/voron_canbus)
API_BASE = "https://api.github.com/repos/Esoterical/voron_canbus/contents"
RAW_BASE = "https://raw.githubusercontent.com/Esoterical/voron_canbus/main"

SECOES = {
    "Katapult Config": "katapult",
    "Klipper Config": "klipper",
    "Klipper USB-CAN-Bridge Config": "klipper",
}


def listar_pastas(caminho):
    url = f"{API_BASE}/{caminho}"
    req = urllib.request.Request(url, headers={"Accept": "application/vnd.github+json"})
    with urllib.request.urlopen(req) as resp:
        return [i for i in __import__("json").load(resp) if i["type"] == "dir"]


def ler_readme(caminho):
    url = f"{RAW_BASE}/{caminho}/README.md"
    try:
        with urllib.request.urlopen(url) as resp:
            return resp.read().decode("utf-8", errors="replace")
    except Exception:
        return ""


def extrair_imagens(readme_md):
    """Retorna [(secao, url_da_imagem)] a partir do markdown da placa."""
    resultado = []
    secao_atual = None
    for linha in readme_md.splitlines():
        m = re.match(r"^#+\s*(.+)$", linha.strip())
        if m:
            titulo = m.group(1).strip()
            secao_atual = next((v for k, v in SECOES.items() if k in titulo), None)
        m_img = re.search(r"!\[[^\]]*\]\((https://[^)]+)\)", linha)
        if m_img and secao_atual:
            resultado.append((secao_atual, m_img.group(1)))
    return resultado


def transcrever_imagem(url_imagem, chave_api):
    """Envia a imagem para um modelo de visão e extrai as opções CONFIG_*."""
    with urllib.request.urlopen(url_imagem) as resp:
        dados = base64.b64encode(resp.read()).decode()

    prompt = (
        "Esta é uma captura de tela do menuconfig do Klipper ou Katapult. "
        "Transcreva EXATAMENTE cada opção selecionada como linhas no formato "
        "CONFIG_NOME=valor (ex.: CONFIG_MCU_STM32G0B1=y, "
        "CONFIG_CLOCK_FREQ_64M=y, CONFIG_CAN_BUS_PA11_PA12=y). "
        "Responda APENAS com as linhas CONFIG_*, sem comentários."
    )
    corpo = __import__("json").dumps({
        "model": "gpt-4o-mini",
        "messages": [{
            "role": "user",
            "content": [
                {"type": "text", "text": prompt},
                {"type": "image_url", "image_url": {"url": f"data:image/png;base64,{dados}"}},
            ],
        }],
        "max_tokens": 1000,
    }).encode()

    req = urllib.request.Request(
        "https://api.openai.com/v1/chat/completions",
        data=corpo,
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {chave_api}",
        },
    )
    with urllib.request.urlopen(req) as resp:
        texto = __import__("json").load(resp)["choices"][0]["message"]["content"]
    return [l.strip() for l in texto.splitlines() if l.strip().startswith("CONFIG_")]


def processar_placa(caminho, chave_api):
    nome = caminho.rsplit("/", 1)[-1]
    print(f"\n=== {nome} ===")
    readme = ler_readme(caminho)
    if not readme:
        print("  (sem README)")
        return
    imagens = extrair_imagens(readme)
    if not imagens:
        print("  (sem screenshots de config)")
        return
    configs = {"katapult": [], "klipper": []}
    for secao, url in imagens:
        print(f"  [{secao}] {url.rsplit('/', 1)[-1]}")
        try:
            configs[secao].extend(transcrever_imagem(url, chave_api))
        except Exception as exc:  # noqa: BLE001
            print(f"    ERRO: {exc}")
    for secao, linhas in configs.items():
        if linhas:
            print(f"  --- {secao} ---")
            for l in linhas:
                print(f"    {l}")


def main():
    ap = argparse.ArgumentParser(description="Extrai configs de menuconfig do guia Esoterical")
    ap.add_argument("--list", action="store_true", help="lista as placas disponíveis")
    ap.add_argument("--board", help="extrai uma placa pelo nome da pasta")
    ap.add_argument("--all", action="store_true", help="extrai todas as placas")
    args = ap.parse_args()

    chave = os.environ.get("VISION_API_KEY")
    if not chave and (args.board or args.all):
        sys.exit("Defina VISION_API_KEY no ambiente.")

    pastas = []
    for raiz in ("toolhead_flashing/common_hardware", "mainboard_flashing/common_hardware"):
        pastas.extend(listar_pastas(raiz))

    if args.list:
        for p in pastas:
            print(p["name"])
        return

    alvo = [p["path"] for p in pastas if args.board and args.board.lower() in p["name"].lower()]
    if args.all:
        alvo = [p["path"] for p in pastas]
    if not alvo:
        sys.exit("Placa não encontrada. Use --list para ver as opções.")

    for caminho in alvo:
        processar_placa(caminho, chave)


if __name__ == "__main__":
    main()
