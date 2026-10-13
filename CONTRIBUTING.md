# Contribuindo com o Klipperizer

Obrigado por querer adicionar uma placa! O processo é simples e a CI valida tudo automaticamente.

## Adicionando uma nova placa

1. **Copie o template**:
   ```bash
   cp schema/boards.template.yaml boards/toolhead/minha_placa.yaml
   ```
   (use `mainboard/` ou `adapter/` conforme a categoria)

2. **Preencha os campos** — a referência principal é o guia
   [canbus.esoterical.online](https://canbus.esoterical.online), que tem os
   screenshots de menuconfig de cada placa:
   - `nome` e `categoria`: exatamente como no guia
   - `mcu`: chip real da placa (confira no silkscreen ou no manual)
   - `bootloader.vid_pid`: rode `lsusb` com a placa em modo DFU/BOOT
   - `bootloader.instrucoes`: copie os passos do guia
   - `katapult` e `klipper`: transcreva as opções dos screenshots
     (alternativa: use `python3 tools/extract_board_configs.py --board "Nome"`)

3. **Marque incertezas**: qualquer valor que você não tenha confirmado
   com uma placa real, deixe o comentário `# VALIDAR` na linha. Isso ajuda
   outros usuários a saberem o que conferir.

4. **Abra um Pull Request** — a CI valida o YAML (nome e VID:PID obrigatórios)
   e roda shellcheck nos scripts.

## Regras importantes

- **Símbolos CONFIG_* inválidos não passam em silêncio**: o build valida cada
  símbolo contra o Kconfig real e falha com mensagem clara. Mesmo assim,
  valide offsets e pinos com uma placa real quando possível.
- **Adaptadores USB-CAN** (U2C, UTOC, UTC) não rodam Katapult/Klipper —
  use a seção `adaptador` com `firmware` (URL do binário) e `comando`
  (dfu-util com `{vidpid}` e `{arquivo}`).
- **Placas com variantes de MCU** (Octopus, SKR-3 EZ): crie um perfil por
  variante, com o sufixo no nome.
- **Teste antes de aprovar**: se você testou o perfil com uma placa real,
  remova os `# VALIDAR` e mencione no PR.

## Reportando problemas

Abra uma issue com:
- Placa e variante de MCU
- Modo (CAN/USB) e etapa em que falhou
- Saída completa do log
- Saída de `lsusb` e `ls /dev/serial/by-id/` no momento da falha

## Licença

Toda contribuição é licenciada sob GPL-3.0 junto com o projeto.
