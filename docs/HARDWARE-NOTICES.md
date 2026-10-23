# Sensores físicos — fontes e compatibilidade

`Sources/NexoBar/HardwareSensors.swift` adapta o layout AppleSMC, os códigos de leitura e os nomes de sensores documentados no código do [Stats](https://github.com/exelban/stats), revisão `5de11712ca182d134e28c2db0b543dca0c17a407` (MIT):

- [SMC/smc.swift](https://github.com/exelban/stats/blob/5de11712ca182d134e28c2db0b543dca0c17a407/SMC/smc.swift): layout de 80 bytes, seletor 2, comando 9 para metadados e comando 5 para leitura, tipos `flt ` e `sp78`.
- [Modules/Sensors/values.swift](https://github.com/exelban/stats/blob/5de11712ca182d134e28c2db0b543dca0c17a407/Modules/Sensors/values.swift): associação de chaves a CPU/GPU por geração.
- [Modules/GPU/reader.swift](https://github.com/exelban/stats/blob/5de11712ca182d134e28c2db0b543dca0c17a407/Modules/GPU/reader.swift): propriedade `PerformanceStatistics`, contadores `Device Utilization %` e `GPU Activity(%)` de `IOAccelerator`.

O coletor é independente, sem dependência do aplicativo Stats. Não incorpora controle de ventoinhas nem comandos AppleSMC de escrita. Nenhum serviço privilegiado, driver, dependência adicional, rede ou subprocesso é iniciado pela coleta.

## Semântica

O valor de temperatura mostrado é o **máximo dos sensores válidos** da CPU ou GPU; o detalhe informa quantidade de sensores e média aritmética. Não representa necessariamente a temperatura do package ou de um núcleo específico. Chaves ausentes, sentinelas 0/128, negativos, NaN, infinito e tipos/tamanhos inesperados são descartados. Nenhum valor ausente vira zero.

O uso de GPU vem do percentual publicado pelo driver em `IOAccelerator`. Havendo várias GPUs, mostra o maior percentual e explicita a agregação; não é uma soma. Não deriva atividade de frequência, consumo, renderizador, memória ou FPS. A janela interna e frequência de atualização do contador pertencem ao driver. Leituras imediatamente consecutivas podem retornar valores distintos, inclusive zero; a atualização do aplicativo ocorre no intervalo configurado pelo monitor.

As APIs públicas de IOKit transportam um **protocolo AppleSMC privado e propriedades de driver sem contrato público de estabilidade**. Uso local fora de sandbox pode funcionar sem root; isso não comprova compatibilidade com App Sandbox, Mac App Store ou versões futuras do macOS.

Há mapas explícitos para Apple M1–M5 e Intel. As gerações M1–M4 e Intel possuem associação baseada na fonte Stats, mas ainda não têm teste físico nesta entrega. Hardware desconhecido mostra indisponibilidade de temperatura, preservando o uso GPU quando o driver o expõe. M6/outros chips exigem nova validação e mapa; não há tentativa de adivinhar associação por prefixos.

O monitor deve serializar chamadas em fila de utilidade. A coleta verifica um limite cooperativo de 2,5 s entre chamadas AppleSMC e descarta uma varredura incompleta. As chamadas síncronas de IOKit não oferecem cancelamento; o limite não interrompe uma chamada travada no kernel. No hardware testado, a varredura inteira levou menos de 10 ms.

## Verificação física em 21/10/2026

Mac17,8, Apple M5 Pro, macOS 27.0.1 (26A434), usuário normal sem sudo: 18 leituras CPU entre 66,58 e 69,97 °C; 7 leituras GPU entre 72,19 e 77,52 °C; utilização GPU 99–100% nas primeiras duas amostras. Durações 9,33/5,56/4,83 ms. Valores são observações daquela execução, não uma referência fixa para funcionamento futuro.

O sandbox do executor recusou `IOServiceOpen` com `0xe00002e2`; executar o mesmo binário fora dele, ainda sem root, retornou os sensores reais. Esse teste separa bloqueio do executor de indisponibilidade física. Os logs/probe ficam no scratch de implementação; testes de regressão usam fixtures e não exigem hardware.

## Licença da referência Stats

MIT License

Copyright (c) 2019 Serhiy Mytrovtsiy

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
