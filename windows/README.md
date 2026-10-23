# NexoBar para Windows — preview 0.4.0

Extraia **todo o ZIP** em uma pasta local e abra `NexoBar.exe`. O pacote win-x64 inclui o runtime .NET 10; o usuário não precisa instalar .NET. Requer Windows 11 x64 nativo. Não há inicialização automática, instalação no Explorer ou pedido de administrador.

Os três modos têm interruptores independentes em **Personalizar barra → Apresentação**. Podem ser usados juntos; os indicadores compartilham o mesmo coletor. O ícone NexoBar de configurações permanece acessível mesmo com todos os modos desligados.

- **Faixa fixa:** fundo translúcido ajustável, texto opaco e monitor selecionável. Por padrão não reserva espaço: janelas maximizam atrás dela. Marque **Reservar área útil** para recuperar o comportamento AppBar anterior. Desligar ou sair libera a reserva. No modo sem reserva, a API pública de estado de notificações orienta o rebaixamento durante apresentação/fullscreen; o comportamento visual ainda precisa de teste Windows.
- **Bandeja:** um ícone dinâmico por indicador habilitado, número compacto, tema do sistema, tooltip e clique para seu detalhe. GPUs preservam IDs individuais. O Windows controla posição e overflow; mova os ícones desejados para a parte visível da bandeja.
- **WidBar:** plugin WinUI que recebe somente as leituras do NexoBar. Configurações: 1–4 indicadores por página, horizontal/duas linhas, largura, rotação de 2–60 segundos e pausa ao passar o mouse. Há uma prévia demonstrativa nas configurações. **Exige o host WidBar e o pacote companion instalado; ligar o interruptor não instala esses componentes.**

O executável portátil inclui faixa e bandeja. O código do companion e seu construtor MSIX estão em `widbar-source/windows/widbar/` no ZIP: leia o README dessa pasta. **WinUI/XAML e MSIX foram compilados nativamente no Windows; assinatura de teste e instalação local também foram verificadas.** A descoberta do plugin e a execução visual no host WidBar continuam pendentes; esses testes locais não significam pacote publicado. No código-fonte do projeto, a entrada é `windows/widbar/build.ps1`; no kit distribuído, é `widbar-source/windows/widbar/build.ps1`. Não precisa recompilar o app portátil para usar faixa/bandeja.

- Clique esquerdo abre o detalhe somente do indicador clicado; clique direito abre o menu.
- O ícone **NexoBar** na bandeja permite ligar/desligar modos, personalizar, reler e sair. Se o Windows agrupar ícones, procure em “Mostrar ícones ocultos”. Fechar uma janela de detalhe ou configuração mantém o coletor.
- Personalização: monitor, mostrar/ocultar, nome completo, ordem, temperatura filha de CPU/GPU, memória nominal/percentual, cotas horizontais/duas linhas e tempo compacto/detalhado. **Aplicar** grava as preferências.
- Todos os recursos ocultos mantêm um botão NexoBar. Excedentes aparecem em **+N**, com acesso ao detalhe. O tema acompanha `SystemUsesLightTheme`, somente leitura; botões usam cores de texto e interação com contraste definido.
- CPU e RAM atualizam a cada 3 segundos. Gráficos mantêm até 5 minutos somente em RAM e expiram mesmo após falha de sensor. CPU usa delta de `GetSystemTimes`; a primeira amostra é desconhecida. RAM usa total físico menos disponível de `GlobalMemoryStatusEx`, em GiB.
- LibreHardwareMonitor 0.9.6 fornece temperatura e cada GPU separadamente, com o `hardware.Identifier` como identidade salva. A barra não reduz múltiplas GPUs a uma máxima. Carga, temperatura e VRAM são exibidas somente quando informadas. GPUs ausentes preservam ordem/nome/visibilidade e reaparecem ao serem redescobertas; inventário é refeito a cada minuto. Mudanças de ID feitas pelo driver podem criar uma nova entrada.
- Cada GPU mostra uma mini marca **NVIDIA**, **intel** ou **AMD** na barra e no detalhe, como os wordmarks da referência Codenotch. O fabricante vem do tipo de hardware informado pelo backend, nunca do nome editável. Fabricante desconhecido usa um ícone genérico; duas GPUs do mesmo fabricante continuam com nomes, leituras e IDs separados. As marcas usam texto monocromático em Segoe UI, sem incorporar arquivos de logotipo.
- O código não altera controles de ventoinha, tensão, relógio ou potência. Sensores que dependam de drivers/permissões indisponíveis aparecem como indisponíveis. O NexoBar não executa instalador nem solicita elevação; sensores dependem das permissões e do driver do backend. CPU/RAM continuam disponíveis sem temperatura.

Preferências em `%LOCALAPPDATA%\NexoBar\indicators.json`, gravadas por substituição atômica. `--data-directory <pasta-absoluta>` isola preferências, inclusive as pastas das CLIs. A barra não grava quotas, logs de conversa, atividade, histórico físico ou credenciais.

## IA pela sessão existente

| Provedor | Fonte | Limite |
|---|---|---|
| Claude | Claude Code nativo temporário em ConPTY: somente `/usage` | Pasta explícita já confiável e sessão existente. Executável `claude.exe`; shim npm `.cmd` não é executado. Sem fallback status line/Desktop. |
| Codex | `codex app-server`, RPC `account/rateLimits/read` | Só a sessão da CLI existente; janelas por modelo ficam no detalhe. |
| Kiro | `kiro-cli chat --no-interactive /usage` | Parser estrito do texto de cota; CLI ausente/incompatível fica indisponível. |
| Copilot | `gh api --hostname github.com copilot_internal/user` | Usa a sessão de gh; sem exportação de token. |
| Antigravity, Cursor, Grok, OpenCode Go, GLM | Indisponível | Nenhuma interface segura validada no Windows neste ciclo. |

Claude abre um terminal invisível de 160×80, envia somente `/usage` após reconhecer o prompt inicial confiável, aguarda terminar a atualização e um frame estável por 1s, e encerra a árvore própria. Limites: 45s e 512KiB de saída total, sem gravar transcrição. O parser VT incremental considera somente o frame atual; login, trust, setup e falhas de carregamento interrompem a consulta sem responder. O cliente usa sua própria autenticação interna; o NexoBar não lê credenciais, não faz login e não envia prompts ao modelo. RemoteControl e atualização automática são desativados somente no auxiliar; `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` não é usado porque impediu a leitura medida no Mac.

As demais consultas têm stdin fechado, timeout de 20s e saída limitada a 512KiB; o Codex recebe apenas RPC fixo. Todos os processos são criados suspensos e vinculados a um Job kill-on-close antes de executar. Leitura e controle ConPTY usam canais separados, com drenagem concorrente durante o encerramento inclusive nas versões anteriores ao Windows 11 24H2. Timeout, cancelamento, saída precoce e Sair encerram os processos próprios. Falhas substituem a leitura por indisponível; não recuperam cota antiga. Claude é consultado a cada 5min ou por **Atualizar Claude**; os demais provedores, a cada minuto quando habilitados.

Configure **Personalizar barra → Pastas das CLIs → Claude** antes de usar. A pasta deve existir, ser absoluta e já ter confiança concedida pelo próprio Claude Code. Não há escolha automática de pasta pessoal. Escolher aqui não concede confiança. Codex aceita pasta opcional; sem ela, usa o diretório temporário próprio do app. As pastas são persistidas em `indicators.json` do data-directory escolhido. A consulta não altera configurações, status line ou sessões dos clientes manualmente.

Zero só aparece se explicitamente informado. Somente janelas reais aparecem na faixa; uma semanal sozinha ocupa uma linha, mesmo no layout de duas linhas. Contador vencido não confirma renovação. O aviso opcional requer um novo reset informado e queda no uso. Atividade de tarefa de IA não é inferida do consumo físico e permanece **não informada pela fonte**.

Resets são interpretados no fuso explicitamente informado pela CLI; timezone desconhecido, datas inválidas e horários DST ambíguos/inexistentes ficam sem contador. A ausência de um reset não inventa uma janela. Mudanças no layout/texto da CLI podem causar indisponibilidade. **O transporte e o encerramento ConPTY passaram no Windows com clientes sintéticos; a consulta Claude autenticada permanece pendente.** Codex, Kiro e Copilot também não tiveram consultas reais verificadas neste ciclo.

## Compilar e verificar

Pré-requisitos de desenvolvimento: PowerShell 7, .NET SDK 10 e acesso ao NuGet oficial. Na raiz `NexoBar`:

```powershell
pwsh -NoProfile -File windows/scripts/build.ps1
```

O script roda fixtures do core e testes reais de pipe, compila o harness ConPTY sintético (e o executa somente em Windows), compila WPF code-only em `net10.0-windows` com `EnableWindowsTargeting=true`, publica `win-x64 --self-contained` e gera `dist/NexoBar-Windows-x64-preview.zip`. O kit-fonte WidBar é incluído separadamente; esse build não gera seu MSIX. Temporários ficam sob `TEMP/NexoBar/windows-build`; `-ArtifactsDirectory` e `-PackagesDirectory` isolam outro contexto. Não faz instalação, commit ou upload.

O build nativo passou em Windows 11 x64 (build 26300), com .NET SDK 10.0.402: 148 checks do núcleo, 20 de ponte e 63 de ConPTY sintético. Os Jobs próprios terminaram sem raízes ou descendentes; handles passaram de 326 para 327 após aquecimento do runtime. As fixtures não chamam CLIs autenticadas. O diagnóstico nativo leu CPU/RAM e identificou Intel Iris Xe, compatível com o inventário Windows; carga/temperatura GPU e temperaturas CPU ficaram indisponíveis. Apenas uma GPU física e um monitor estavam disponíveis; Microsoft Remote Display Adapter não conta como GPU física adicional.

O processo WPF iniciou com `--settings`; isso não comprova sua aparência ou interação. As oito combinações físicas, cliques, transparência, reserva de área, fullscreen, rotação WidBar e DPI ainda exigem revisão manual. Múltiplas GPUs e monitores/DPI misto também permanecem pendentes. Veja a [matriz de evidências](docs/VALIDATION.md).

Depois de extrair o ZIP em Windows nativo, rode `pwsh -NoProfile -File smoke-windows.ps1 -OpenUI`. O script grava um diagnóstico de CPU/RAM/GPUs em `TEMP/NexoBar/windows-native-smoke/sensors.json` e abre a GUI com dados isolados. Ausência de temperatura não é falha automática. Confira os nomes/quantidade de GPUs contra o Gerenciador de Dispositivos.

O pacote inclui `native-tests/NexoBar.ConPty.Tests.exe`. `pwsh -NoProfile -File smoke-windows.ps1 -TestConPty` testa somente processos sintéticos: sucesso após refresh, trust/login/setup sem input, timeout, cancelamento, shutdown, excesso de saída, saída da raiz com descendente, falha de startup, Jobs vazios e handles limitados. Nenhuma CLI autenticada é executada por esse harness. O harness é opt-in no smoke; seu watchdog externo é de 20s por caso.

Somente para diagnóstico real explicitamente solicitado, execute `pwsh -NoProfile -File smoke-windows.ps1 -QueryClaude -ClaudeFolder 'C:\pasta-ja-confiavel'`. O script cria dados isolados em TEMP e chama `--diagnose-claude --output <json>`; registra somente resultado sanitizado, percentuais/resets, duração e Jobs próprios após conclusão. Não inclui texto do terminal, tokens ou login. `--data-directory` também vale nesse modo. O smoke padrão não consulta Claude.

Para validar os modos no Windows: exercite as oito combinações de liga/desliga; confirme recuperação com todos desligados; maximize uma janela com reserva desligada e ligada; compare fundos claros/escuros e DPI; clique em indicadores diferentes da bandeja. O smoke usa preferências e pipe isolados: o companion WidBar conecta somente à instância normal do NexoBar, evitando mistura de testes. Avalie WidBar após instalar seu companion: duas/quatro métricas, rotação, hover, cliques por ID, desligar/religar, perda da conexão e reinício do host.

Contrato e APIs públicas: [CLAUDE-CONPTY.md](docs/CLAUDE-CONPTY.md). A consulta Claude e a política de sessão existente permanecem iguais em todos os modos.

Licenças e fontes: [THIRD-PARTY-NOTICES.md](docs/THIRD-PARTY-NOTICES.md). Matriz de evidências: [VALIDATION.md](docs/VALIDATION.md).
