# NexoBar para WidBar — companion 0.6.0

Plugin WinUI 3 real, derivado de `WidgetPluginBase`, com bootstrap `WidgetHostApplication`. Usa **WidBar.SDK 2.1.0** e **Microsoft.WindowsAppSDK 2.3.1** oficiais. O contrato de descoberta permanece SDK **2**. O companion tem executável e MSIX próprios; o aplicativo NexoBar principal continua sendo o único coletor e deve estar aberto. Não ativa o principal nem consulta clientes de IA.

No NexoBar, habilite **WidBar** e selecione indicadores, ordem, 1–8 itens por página, horizontal/duas linhas ou layout personalizado (`customRows`), largura global (120–600 px lógicos), rotação (2–60 s) e pausa ao passar o ponteiro. Em **Personalizar barra → WidBar**, mova cada indicador entre linhas e altere sua ordem. O preset coloca CPU e memória na linha superior e Claude, Codex e Kiro na inferior, com cinco itens por página; 1–8 é o total por página e 2+3 é apenas um preset, permitindo outras distribuições. A seleção dos indicadores permanece nas opções correspondentes. Faixa e bandeja podem continuar habilitadas independentemente.

O plugin recebe a organização pela ponte e usa os mesmos ícones vetoriais das fontes Mac. Nas opções de cada instância no host, escolha **Herdar largura do NexoBar** ou uma largura própria entre 120 e 600 px, além de mostrar nomes. Salvar confirma e Cancelar restaura o estado anterior pelo contrato do host; a prévia usa valores demonstrativos. O espaço entre linhas é configurável de 0–12 px, com padrão 4. A opção de renovação é independente dos nomes. Duas cotas são empilhadas somente quando há duas janelas reais; Codex apenas semanal ocupa uma linha. Temperatura opcional de CPU/GPU só aparece quando fornecida. As prévias usam leituras demonstrativas e as opções atuais. O host pode limitar altura e largura disponíveis na taskbar; o gap máximo não garante acomodar qualquer combinação. No teste 0.5, o preset 2+3 foi aplicado e o JSON confirmou os cinco IDs com largura 402 px. O host reabriu “Em execução” e as opções do companion mostraram ícones CPU/RAM/Claude/Codex/Kiro em 2+3. Largura própria de 305 px foi testada; após Cancelar, reabrir mostrou herança de 402 px, e Salvar com herança foi executado. Layout real na taskbar, rotação, hover e cliques permanecem pendentes.

O preview usa controles WinUI com cores do tema e raiz transparente. Clique captura o ID do indicador e abre somente seu detalhe; a rotação pausa durante o flyout. A opção automática de duas linhas preenche cada coluna de cima para baixo; o layout personalizado preserva a linha e ordem de cada ID. Quotas exibem exclusivamente janelas informadas pelo aplicativo; temperatura e memória nominal dependem dos dados/seleções reais. Sem fonte ou snapshot recente: **indisponível**. Altura, DPI misto, contraste alto e layouts de 1–8 itens precisam de revisão no host físico.

## Bridge sem persistência

`../core/DisplayBridge.cs` define `DisplaySnapshot` schema 1 e `DisplayBridgeServer`. Transporte: named pipe `NexoBar.Display.v1.<hash de usuário/canal>`, acesso `CurrentUserOnly` nos dois lados, um frame JSON com comprimento little-endian de 32 bits. Limites: 256 KiB e 1 s por conexão; freshness máxima 15 s, tolerância futura 2 s. Não há comandos no protocolo. A resposta contém apenas opções visuais e leituras já coletadas, sem caminhos de clientes, tokens, configuração de autenticação ou histórico.

Servidor e cliente não gravam quotas em disco. O servidor recebe uma função que devolve snapshot imutável; ela nunca deve bloquear o dispatcher. Desabilitar limpa indicadores da resposta e para renderização/rotação. O último estado explícito de habilitação permanece somente em RAM; perder a ponte ou expirar o frame limpa as leituras sem reabrir um slot desabilitado. Permanece uma consulta de disponibilidade a cada 3 s, sem conexão persistente, para detectar reativação. O desaparecimento do preview da smart stack pausa o polling e limpa superfícies; fechar o host cancela o polling e libera timers. Não há loop de ativação ou solicitação de atenção.

`DisplayBridgeServer.HasClient` indica apenas conexão local observada há menos de 15 s. Não comprova instalação do WidBar. `--data-directory` do app utiliza outro canal; o companion lê somente o canal padrão, evitando mistura com testes ou instâncias isoladas.

## Compilar

Pré-requisitos Windows: Windows 11, PowerShell 7, .NET SDK 10 e acesso ao NuGet oficial durante restore. O build nativo foi verificado com as ferramentas MakeAppx/MakePri/SignTool do pacote `Microsoft.Windows.SDK.BuildTools` 10.0.26100.4654, sem Visual Studio ou Windows SDK completos instalados. Na raiz do NexoBar:

```powershell
pwsh -NoProfile -File windows/widbar/build.ps1
```

O script executa as fixtures de pipe, restaura as dependências, compila/publica WinUI e .NET/WindowsAppSDK autocontidos e gera `TEMP/NexoBar/widbar-build/NexoBar-WidBar-x64-unsigned.msix`. Localiza MakeAppx x64 primeiro no pacote SDK restaurado, depois no Windows SDK instalado. `-Architecture arm64`, `-ArtifactsDirectory`, `-Publisher` e `-MakeAppxPath` são configuráveis; em host ARM64, informe uma ferramenta compatível por `-MakeAppxPath` (execução/emulação não validada). O manifesto tem identidade local `NexoBar.Widget`, Publisher `CN=NexoBar`, Application oculta e AppExtension `com.widbar.widget`, plugin `com.nexobar.indicators`/SDK 2; `Public/plugin.json` vem de `obj/widbar/plugin.json`, gerado pelos targets do SDK, sem catálogo escrito à mão. Release não emite símbolos próprios e o estágio do pacote remove PDBs.

O script não instala WidBar, não habilita Developer Mode, não cria/trusta certificado, não assina nem instala o MSIX. Assinatura/deploy exigem identidade e certificado próprios, aprovados fora deste build. WidBar precisa ser instalado separadamente pelo usuário para execução física.

O [instalador NexoBar](../setup/README.md) incorpora o companion assinado e orienta host/confiança com consentimento; a instalação 0.5 foi registrada em [INSTALLATION-VALIDATION.md](../docs/INSTALLATION-VALIDATION.md), enquanto a 0.6 tem validação separada. O candidato anterior 0.5 tem assinatura local de teste, sem reputação pública comprovada. Os registros 0.5 abaixo não comprovam build, UI ou instalação 0.6; veja a [matriz 0.6](../docs/PARITY-0.6.md).

Para conferir C# contra os assemblies reais do SDK no macOS/Linux:

```powershell
pwsh -NoProfile -File windows/widbar/build.ps1 -ContractOnly
```

Esse modo produz uma biblioteca de verificação; exclui apenas bootstrap e compilação XAML/PRI. Não é um plugin executável empacotado. A compilação C# foi validada no macOS; WinUI/XAML e MakeAppx passaram nativamente em Windows 11 x64 com .NET 10.0.402. O MSIX 0.5 foi compilado, assinado com certificado local de teste, verificado e instalado; a consulta do pacote confirmou versão 0.5.0.0 e status normal. Passaram 60 checks de ponte/configuração/vetores, sem CLIs autenticadas ou sensores.

Na validação anterior, o MSIX 0.4.0.0 foi assinado com certificado de teste `CN=NexoBar`, validade de 30 dias e chave privada não exportável, verificado após confiança autorizada e instalado. No host oficial WidBar 1.2.8.0, o plugin foi descoberto/adicionado, mostrou “Em execução” e o NexoBar indicou cliente da ponte ativo. A atualização 0.5 reabriu em execução e teve a configuração visual revisada conforme descrito acima; taskbar, rotação, hover, cliques, DPI e ACL entre usuários continuam pendentes. Veja a [matriz de evidências](../docs/VALIDATION.md).

## Fontes e licença

SDK oficial [NuGet WidBar.SDK 2.1.0](https://www.nuget.org/packages/WidBar.SDK/2.1.0), MIT; pacote declara revisão `ebd56b71820b584616945773e674a109dd8407b9`. [Template companion](https://github.com/andelby/widbar-widget-template/tree/main/templates/companion), [contrato](https://github.com/andelby/widbar-widget-template/blob/main/wiki/Plugin-Contract.md) e [empacotamento](https://github.com/andelby/widbar-widget-template/blob/main/wiki/Packaging-and-Publishing.md). O README do NuGet 2.1 prevalece sobre exemplos antigos que sobrescrevem `FlyoutBackdrop`: essa propriedade tornou-se obsoleta; o material do flyout é escolhido pelo host. WinUI/WindowsAppSDK e SDK WidBar preservam suas licenças nos pacotes restaurados.
