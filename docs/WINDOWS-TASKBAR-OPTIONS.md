# NexoBar dentro da taskbar do Windows

Pesquisa de 23/10/2026, seguida da escolha explícita de implementar os três modos. Windows0.4.0 inclui faixa e bandeja, opções independentes e integração de dados com o plugin WidBar. O companion foi compilado em C# contra o SDK real; seu MSIX, instalação e teste no host Windows continuam pendentes. As alternativas de substituir a pesquisa ou encaixar diretamente no Explorer abaixo permanecem pesquisa, sem implementação. Estado atual em [README Windows](../windows/README.md).

## Resultado

É possível usar ícones reais da área de notificação com conteúdo dinâmico. Para uma área com texto e alternância de indicadores, há hosts como WidBar e técnicas de encaixe usadas pelo TrafficMonitor. Isso não equivale a uma API oficial que permita substituir a caixa de pesquisa ou controlar livremente o botão de clima do Windows.

| Caminho | Texto visível na taskbar | Controle de atualização | Limites |
|---|---|---|---|
| Área de notificação nativa | Desenho dentro do ícone quadrado; valores completos no tooltip/detalhe | O app modifica o ícone por Shell_NotifyIcon/NIM_MODIFY | Espaço pequeno, DPI, ordem/overflow sob controle do Windows/usuário |
| Widget NexoBar para WidBar | Texto e gráficos em espaço livre; largura configurável | Conteúdo WinUI vivo, refresh e smart stacks no SDK | Exige WidBar e pacote de widget; compatibilidade física ainda não testada |
| Encaixe próprio inspirado no TrafficMonitor | Bloco com texto dentro da geometria da taskbar | Controle do app | Depende da estrutura interna do Explorer; risco de sobreposição e quebra em updates |
| Widgets oficiais | Cartão no painel aberto por Win+W | Conteúdo atualizado pelo provedor/host | Não garante um bloco sempre visível na taskbar |
| Anúncios de feed no botão Widgets | Anúncio curto, como os conteúdos rotativos do sistema | Pedido ao host, que pode recusá-lo | Documentação marca preview e EEA; não serve de base para telemetria contínua no Brasil |
| Caixa de pesquisa | Não encontrei API pública para convertê-la em indicadores | Integração documentada retorna resultados de busca | Search provider não substitui a caixa por uma UI arbitrária; integração web restrita ao EEA |

## Recomendação

Para NexoBar independente, a opção mais previsível é um modo **Bandeja nativa**. Um ícone por indicador dá acesso direto ao detalhe; um modo compacto pode alternar CPU, RAM, GPUs e IA no mesmo ícone. Um único ícone comporta dois dígitos ou um pequeno gráfico, não todos os textos atuais. CPU/GPU podem manter amostragem de 3 segundos e redesenhar só quando o valor visual muda. Essa cadência é proposta de implementação, não desempenho já medido no Windows. Não é necessário gerar notificações/toasts para atualizar ícones. A consulta Claude continua a cada 5 minutos, independente da troca visual.

Para priorizar texto sem segunda barra, vale um protótipo **NexoBar para WidBar**. O SDK documenta largura lógica, preview WinUI, temas e alternância de widgets. Exige o host adicional; o repositório público consultado é de templates/site, não prova como o host se integra internamente ao Explorer. Não afirmar que é uma extensão oficial Microsoft nem que sua compatibilidade foi validada por nós.

O encaixe próprio é uma terceira opção, com menos dependências de produto e maior manutenção. TrafficMonitor usa `FindWindow("Shell_TrayWnd")` e `SetParent`, conforme seu código. Isso demonstra viabilidade prática, mas não um contrato estável de layout da taskbar. Não copiar sua implementação sem revisão de licença. Evitar injeção, patch do Explorer ou substituição do Shell como requisito padrão.

## Layout proposto para bloco com texto

Um slot de aproximadamente 160–220 pixels lógicos, altura igual à área disponível, com páginas a cada 5 segundos:

```text
CPU     28%  61°
RAM     40/48 GiB
NVIDIA  52%  65°
AMD     12%  48°
Claude  40% · 2h | 42% · 3d
Codex   68% · 3d
```

Valores ilustrativos. Nomes/ordem/participação e tempo de rotação configuráveis. Em espaço menor, IA pode usar duas linhas e abreviar o nome; janelas ausentes não ganham espaço artificial. Preferir troca de páginas a texto correndo continuamente: preserva a leitura. Pausar alternância enquanto o ponteiro estiver sobre o slot ou houver detalhe aberto; clique congela a identidade da página e abre somente seu detalhe. Botão direito abre opções. Permitir fixar um indicador. Não disparar nova consulta de IA a cada rotação.

Na bandeja, a proposta é ainda mais compacta: valor percentual desenhado no ícone, identificação no tooltip e detalhe por clique. Sessão/semanal completas ficam no detalhe; tentar colocar ambos e seus tempos em 16–32 px prejudica legibilidade. Ícones separados podem representar cada janela, mas o Shell pode ocultá-los ou reorganizá-los; não prometer um grupo indivisível. Tema deve ser redesenhado em resposta à mudança do sistema e testado em contraste alto/DPI.

## Fontes primárias e evidências

- [Microsoft: Shell_NotifyIcon](https://learn.microsoft.com/en-us/windows/win32/api/shellapi/nf-shellapi-shell_notifyicona): adicionar, modificar e remover ícone. A API não documenta uma espera de minutos para NIM_MODIFY; isso não constitui garantia de taxa de quadros.
- [Microsoft: NOTIFYICONDATAW](https://learn.microsoft.com/en-us/windows/win32/api/shellapi/ns-shellapi-notifyicondataw): múltiplos IDs, ícone, tooltip e eventos; recomenda recursos em 16×16 e 32×32 para DPI.
- [Microsoft: área de notificação](https://learn.microsoft.com/en-us/windows/win32/shell/notification-area): presença/overflow e atualização sem balão.
- [Microsoft: Widgets](https://learn.microsoft.com/en-us/windows/apps/design/widgets/): cartões no Widgets Board, com provedor Win32 empacotado/PWA.
- [Microsoft: TryShowAnnouncement](https://learn.microsoft.com/en-us/windows/windows-app-sdk/api/winrt/microsoft.windows.widgets.feeds.providers.feedmanager.tryshowannouncement?view=windows-app-sdk-2.0): o host pode não mostrar o anúncio, conforme suas políticas.
- [Microsoft: feed providers](https://learn.microsoft.com/en-gb/windows/apps/develop/feeds/feed-providers): preview/EEA na documentação consultada.
- [Microsoft: integração Search](https://learn.microsoft.com/en-us/windows/apps/develop/search/): integração com resultados, não superfície arbitrária na taskbar.
- [WidBar: template e requisitos](https://github.com/andelby/widbar-widget-template/blob/main/README.md), SHA do blob consultado `719872b55afd12028491f32d6b5d1f757e47842b`.
- [WidBar: contrato](https://github.com/andelby/widbar-widget-template/blob/main/wiki/Plugin-Contract.md), blob `bdd694924eab307f1154358f71e458adca8160fb`: largura, refresh, visibilidade e smart stacks.
- [WidBar: preview, temas e interação](https://github.com/andelby/widbar-widget-template/blob/main/wiki/Preview-Flyout-Settings.md), blob `cf5144273cc33d9fba721bd2081d4981ea7feb9f`.
- [TrafficMonitor: TaskBarDlg.cpp](https://github.com/zhongyang219/TrafficMonitor/blob/master/TrafficMonitor/TaskBarDlg.cpp): linhas 628 e 1017 do arquivo consultado localizam o Shell e tornam a janela filha da taskbar.

Antes de adotar qualquer novo modo: validar Windows 11/build instalado, dois monitores/DPI misto, tema claro/escuro/alto contraste, ocultação automática, tela cheia, Explorer reiniciado e indicadores indisponíveis. WSL não executa nem comprova esses comportamentos do Shell nativo.
