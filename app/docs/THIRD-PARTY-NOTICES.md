# Componentes de terceiros — Windows

NexoBar distribui componentes sem modificações nas bibliotecas. Textos de licença acompanham `licenses/` e `docs/` no ZIP. A lista de arquivos/versões efetivos está em `NexoBar.deps.json`, no lockfile do código-fonte e em `package-manifest.json`.

| Componente | Versão | Licença e fonte |
|---|---|---|
| LibreHardwareMonitorLib | 0.9.6 | MPL-2.0; LibreHardwareMonitor e contribuidores; [código correspondente](https://github.com/LibreHardwareMonitor/LibreHardwareMonitor/tree/3d331e3370efb858411f19511373eff65a218701). |
| DiskInfoToolkit | 1.1.2 | MPL-2.0; Florian K.; [fonte](https://github.com/Blacktempel/DiskInfoToolkit/tree/25319eae5781e75bcf141e844ceab2afe94d40ea). Dependência indireta; leitura de disco não é ativada pelo NexoBar. |
| RAMSPDToolkit-NDD | 1.4.2 | MPL-2.0; Florian K.; [fonte](https://github.com/Blacktempel/RAMSPDToolkit/tree/3b47b960e0830fef344624ad5e389675d5f0a1ce). Dependência indireta; SPD não é ativado pelo NexoBar. |
| BlackSharp.Core | 1.0.7 | MPL-2.0; Florian K.; [fonte](https://github.com/Blacktempel/BlackSharp/tree/c70b735c6cec123ee8a046ac4a0bc6c606f52cf0). |
| HidSharp | 2.6.4 | Apache-2.0; James F. Bellinger; texto e copyright copiados do pacote oficial NuGet. |
| Mono.Posix.NETStandard | 1.0.0 | Licença Mono (MIT e avisos de terceiros), Microsoft/Mono; [link de licença declarado pelo pacote](https://go.microsoft.com/fwlink/?linkid=869050), que redireciona ao [arquivo oficial](https://github.com/mono/mono/blob/main/LICENSE). `LICENSE-Mono.txt` e `Mono-PATENTS.txt` incluídos. |
| .NET / WindowsDesktop | runtime 10.0.13 | MIT e avisos de terceiros; Microsoft e contribuidores; textos extraídos dos pacotes Microsoft oficiais. |
| System.Management, System.CodeDom, System.IO.Ports | 10.0.2 / 10.0.2 / 10.0.3 | MIT e avisos de terceiros, Microsoft; metadados e notices oficiais dos pacotes incluídos. |
| System.IO.FileSystem.AccessControl | 5.0.0 | MIT e avisos de terceiros, Microsoft. |

MPL-2.0 permite combinar a biblioteca com outros arquivos; o código-fonte dos componentes cobertos permanece disponível nos links acima, incluindo a revisão correspondente informada nos metadados NuGet. O texto completo está em `LICENSE-LibreHardwareMonitor-MPL-2.0.txt`. Nenhuma alteração foi feita no código coberto. O uso das APIs não transfere titularidade sobre marcas.

Os parsers de cotas foram reimplementados a partir do contrato e do comportamento de referência do projeto Codenotch, revisão `1a33306a1fbd32d0dc185c1ca2507072365bd417`, licenciado sob MIT. A atribuição e licença originais do projeto principal acompanham o ZIP. A UI Windows é implementação nova em WPF.
