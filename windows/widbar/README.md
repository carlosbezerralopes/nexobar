# NexoBar para WidBar — companion 0.4.0

Plugin WinUI 3 real, derivado de `WidgetPluginBase`, com bootstrap `WidgetHostApplication`. Usa **WidBar.SDK 2.1.0** e **Microsoft.WindowsAppSDK 2.3.1** oficiais. O contrato de descoberta permanece SDK **2**. O companion tem executável e MSIX próprios; o aplicativo NexoBar principal continua sendo o único coletor e deve estar aberto. Não ativa o principal nem consulta clientes de IA.

No NexoBar, habilite **WidBar** e selecione indicadores, ordem, 1–4 itens por página, horizontal/duas linhas, largura (120–600 px lógicos), rotação (2–60 s) e pausa ao passar o ponteiro. O plugin lê essas opções da ponte; a janela de configuração do host explica onde editá-las, sem outra cópia de preferências. Faixa e bandeja podem continuar habilitadas independentemente.

O preview usa controles WinUI com cores do tema e raiz transparente. Clique captura o ID do indicador e abre somente seu detalhe; a rotação pausa durante o flyout. A opção de duas linhas preenche cada coluna de cima para baixo. Quotas exibem exclusivamente janelas informadas pelo aplicativo; temperatura e memória nominal dependem dos dados/seleções reais. Sem fonte ou snapshot recente: **indisponível**. Altura, DPI misto, contraste alto e layouts de quatro itens precisam de revisão no host físico.

## Bridge sem persistência

`../core/DisplayBridge.cs` define `DisplaySnapshot` schema 1 e `DisplayBridgeServer`. Transporte: named pipe `NexoBar.Display.v1.<hash de usuário/canal>`, acesso `CurrentUserOnly` nos dois lados, um frame JSON com comprimento little-endian de 32 bits. Limites: 256 KiB e 1 s por conexão; freshness máxima 15 s, tolerância futura 2 s. Não há comandos no protocolo. A resposta contém apenas opções visuais e leituras já coletadas, sem caminhos de clientes, tokens, configuração de autenticação ou histórico.

Servidor e cliente não gravam quotas em disco. O servidor recebe uma função que devolve snapshot imutável; ela nunca deve bloquear o dispatcher. Desabilitar limpa indicadores da resposta e para renderização/rotação. O último estado explícito de habilitação permanece somente em RAM; perder a ponte ou expirar o frame limpa as leituras sem reabrir um slot desabilitado. Permanece uma consulta de disponibilidade a cada 3 s, sem conexão persistente, para detectar reativação. O desaparecimento do preview da smart stack pausa o polling e limpa superfícies; fechar o host cancela o polling e libera timers. Não há loop de ativação ou solicitação de atenção.

`DisplayBridgeServer.HasClient` indica apenas conexão local observada há menos de 15 s. Não comprova instalação do WidBar. `--data-directory` do app utiliza outro canal; o companion lê somente o canal padrão, evitando mistura com testes ou instâncias isoladas.

## Compilar

Pré-requisitos Windows: Windows 11, PowerShell 7, .NET SDK 10, Windows SDK (MakeAppx) e ferramentas WinUI/Windows App SDK do workload de desenvolvimento Windows do Visual Studio. Acesso ao NuGet oficial durante restore. Na raiz do NexoBar:

```powershell
pwsh -NoProfile -File windows/widbar/build.ps1
```

O script executa as fixtures de pipe, compila/publica WinUI e .NET/WindowsAppSDK autocontidos e gera `TEMP/NexoBar/widbar-build/NexoBar-WidBar-x64-unsigned.msix`. `-Architecture arm64`, `-ArtifactsDirectory`, `-Publisher` e `-MakeAppxPath` são configuráveis. A busca padrão encontra MakeAppx x64; em host ARM64, informe uma ferramenta compatível por `-MakeAppxPath` (execução/emulação não validada). O manifesto tem identidade local `NexoBar.Widget`, Publisher `CN=NexoBar`, Application oculta e AppExtension `com.widbar.widget`, plugin `com.nexobar.indicators`/SDK 2; `Public/plugin.json` vem dos targets do SDK, sem catálogo escrito à mão.

O script não instala WidBar, não habilita Developer Mode, não cria/trusta certificado, não assina nem instala o MSIX. Assinatura/deploy exigem identidade e certificado próprios, aprovados fora deste build. WidBar precisa ser instalado separadamente pelo usuário para execução física.

Para conferir C# contra os assemblies reais do SDK no macOS/Linux:

```powershell
pwsh -NoProfile -File windows/widbar/build.ps1 -ContractOnly
```

Esse modo produz uma biblioteca de verificação; exclui apenas bootstrap e compilação XAML/PRI. Não é um plugin executável empacotado. O build WinUI/MSIX exige as ferramentas Windows nativas, incluindo MakePri/MakeAppx. A compilação C# foi validada no macOS com .NET 10.0.402; a GUI, carregamento no WidBar, ACL entre usuários, assinatura e empacotamento nativo continuam pendentes de Windows. As fixtures de pipe não chamam CLIs autenticadas nem sensores.

## Fontes e licença

SDK oficial [NuGet WidBar.SDK 2.1.0](https://www.nuget.org/packages/WidBar.SDK/2.1.0), MIT; pacote declara revisão `ebd56b71820b584616945773e674a109dd8407b9`. [Template companion](https://github.com/andelby/widbar-widget-template/tree/main/templates/companion), [contrato](https://github.com/andelby/widbar-widget-template/blob/main/wiki/Plugin-Contract.md) e [empacotamento](https://github.com/andelby/widbar-widget-template/blob/main/wiki/Packaging-and-Publishing.md). O README do NuGet 2.1 prevalece sobre exemplos antigos que sobrescrevem `FlyoutBackdrop`: essa propriedade tornou-se obsoleta; o material do flyout é escolhido pelo host. WinUI/WindowsAppSDK e SDK WidBar preservam suas licenças nos pacotes restaurados.
