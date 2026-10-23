# Créditos e licenças

## Codenotch: inspiração e ponto de partida

O NexoBar reconhece o [Codenotch original, de Vinz](https://github.com/vinzdg/codenotch), e o [fork de Carlos Bezerra Lopes](https://github.com/carlosbezerralopes/codenotch) como inspiração e ponto de partida. A referência utilizada é o commit [`1a33306a1fbd32d0dc185c1ca2507072365bd417`](https://github.com/carlosbezerralopes/codenotch/tree/1a33306a1fbd32d0dc185c1ca2507072365bd417).

A interface do NexoBar usa AppKit/SwiftUI no macOS e WPF no Windows, com apresentação e coleta próprias. Isso convive com reutilização real: parsers de cotas, contornos vetoriais de provedores, semântica de atividade e outras adaptações são derivados da referência. O [registro detalhado](../THIRD_PARTY_NOTICES.md) identifica os arquivos, preserva a licença integral e distingue a proveniência do código das interfaces habilitadas no runtime atual. O uso não depende de ter Codenotch instalado.

A [licença da revisão usada](https://github.com/carlosbezerralopes/codenotch/blob/1a33306a1fbd32d0dc185c1ca2507072365bd417/LICENSE) e a [licença do upstream](https://github.com/vinzdg/codenotch/blob/main/LICENSE) são MIT, com `Copyright (c) 2026 Vinz`. O aviso original permanece em [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md) e em [LICENSE-Codenotch.txt](../windows/docs/LICENSE-Codenotch.txt). A licença do upstream não foi substituída pela licença das contribuições NexoBar.

## Componentes e referências

| Componente | Uso | Licença e referência preservadas |
|---|---|---|
| Codenotch — Vinz | Parsers, vetores e adaptações identificadas. | MIT; [avisos completos](../THIRD_PARTY_NOTICES.md). |
| Stats — Serhiy Mytrovtsiy | Layout e leitura AppleSMC, mapas de sensores e contadores GPU. | MIT; [arquivos/revisão e licença](HARDWARE-NOTICES.md). |
| LibreHardwareMonitorLib e dependências MPL | Sensores Windows; bibliotecas distribuídas sem modificação. | MPL-2.0; [versões, fontes correspondentes e notices](../windows/docs/THIRD-PARTY-NOTICES.md). |
| WidBar.SDK 2.1.0 | Contrato e bootstrap do companion. | MIT; [licença incluída](../windows/widbar/LICENSE-WidBar-SDK.txt), [pacote oficial](https://www.nuget.org/packages/WidBar.SDK/2.1.0). |
| Microsoft.WindowsAppSDK / WinUI | Interface e empacotamento do companion. | MIT no [repositório oficial](https://github.com/microsoft/WindowsAppSDK/blob/main/LICENSE); preservar também as licenças e avisos dos componentes dos pacotes efetivamente distribuídos. |
| .NET, bibliotecas Microsoft, Mono e HidSharp | Runtime e dependências Windows. | MIT, avisos Mono/Microsoft e Apache-2.0 conforme [inventário Windows](../windows/docs/THIRD-PARTY-NOTICES.md). |

O escopo MPL é o código coberto por essa licença e suas modificações. A combinação com arquivos novos sob MIT não os relicencia automaticamente. Quem redistribui bibliotecas MPL precisa manter os avisos e informar como obter o código-fonte correspondente; os links por revisão estão no inventário Windows. Se houver modificações nesses arquivos, o código coberto modificado também deve ser disponibilizado nos termos da MPL. Referências: [MPL 2.0](https://www.mozilla.org/en-US/MPL/2.0/) e [FAQ da Mozilla, questões 8–11](https://www.mozilla.org/en-US/MPL/2.0/FAQ/).

O leitor zstd opcional do código macOS procura uma biblioteca Homebrew existente. Este preview não distribui fonte nem binário zstd.

## Licença do NexoBar

As contribuições próprias são publicadas sob [MIT](../LICENSE), com `Copyright (c) 2026 Carlos Bezerra Lopes`. Essa licença permite usar, copiar, modificar, publicar, distribuir, sublicenciar e comercializar o código, desde que os avisos exigidos sejam preservados. O texto completo prevalece sobre este resumo. Referência: [MIT na Open Source Initiative](https://opensource.org/license/mit).

Arquivos e bibliotecas de terceiros continuam sob as licenças indicadas acima. Preserve o `LICENSE`, o `THIRD_PARTY_NOTICES.md` e os avisos específicos que correspondem ao conteúdo redistribuído. Pacotes binários devem acompanhar os avisos e os endereços do código-fonte correspondentes, mesmo quando o código do aplicativo tenha sido modificado.

Marcas, nomes e logotipos de provedores identificam integrações e pertencem aos respectivos titulares. Os créditos não afirmam parceria, afiliação, endosso ou transferência de direitos sobre marcas.
