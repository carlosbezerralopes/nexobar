# Compilar e diagnosticar o NexoBar

Execute os comandos na raiz do código-fonte. Os builds usam diretórios temporários contextualizados, não instalam o aplicativo nem publicam arquivos.

## macOS

Requisitos: macOS 14+, toolchain Swift 6 e PowerShell 7. O pacote padrão usa a arquitetura do host; o preview distribuível atual é arm64.

```powershell
pwsh -NoProfile -File scripts/build.ps1
```

O script executa os testes Swift, compila release, monta `NexoBar.app`, aplica assinatura local e verifica o bundle antes de gerar `dist/NexoBar-macOS-preview.zip`. Essa assinatura não equivale a notarização Apple. Build e bundle ficam fora de pastas sincronizadas para evitar metadados do File Provider que invalidam a assinatura. O backend nativo do SwiftPM é uma contingência do toolchain atual.

Opções de `NexoBar.app/Contents/MacOS/NexoBar`:

| Opção | Efeito |
|---|---|
| `--settings` | Abre a personalização. |
| `--data-directory <pasta>` | Isola preferências e estado para testes. |
| `--diagnose` | Diagnostica sensores. |
| `--diagnose-ai` | Mostra disponibilidade, janelas e antiguidade, sem credenciais ou valores de cotas. |
| `--diagnose-claude` | Executa a consulta real temporária; retorna resultado sanitizado, percentuais/resets, duração e contagem de processos próprios após encerramento. Requer sessão existente e pasta configurada. |
| `--capture-window <arquivo.png>` | Produz render do próprio aplicativo para revisão. |
| `--capture-detail cpu` | Seleciona o detalhe para captura. |
| `--capture-delay 45` | Aguarda leituras antes da captura. |

Nenhuma opção de diagnóstico concede trust ou realiza login. Capturas podem conter leituras reais: revise o conteúdo antes de compartilhar.

## Windows

Requisitos de compilação: PowerShell 7, .NET SDK 10 e acesso ao NuGet oficial.

```powershell
pwsh -NoProfile -File windows/scripts/build.ps1
```

O build executa os testes do núcleo e de pipe, compila WPF e publica `win-x64 --self-contained` em `dist/NexoBar-Windows-x64-preview.zip` por padrão; `-OutputZip` permite um nome versionado, como `NexoBar-Windows-x64-0.6.1-preview.zip`. O harness sintético ConPTY só é executado em Windows. Compilação cruzada não valida interface, sensores, CLIs autenticadas ou ciclo de processos no Windows.

O ZIP inclui app portátil para faixa/bandeja e kit-fonte WidBar. O construtor do companion restaura e localiza as ferramentas Windows do NuGet para gerar o MSIX; assinatura e implantação são etapas separadas. Visual Studio e Windows SDK completos não foram necessários no build nativo verificado. Veja [compilar WidBar](../windows/widbar/README.md#compilar).

Na validação anterior 0.5, em Windows 11 x64, .NET SDK 10.0.402, passaram 226 checks de núcleo, 60 de ponte/configuração/vetores e 63 de ConPTY com processos sintéticos. O WPF 0.5 foi publicado localmente e empacotado em ZIP; WinUI/XAML e MSIX 0.5 compilaram, a assinatura de teste foi verificada e o companion foi instalado. O preset 2+3 foi aplicado com cinco IDs e largura preservada; o host reabriu em execução e as opções de largura herdada/própria foram exercitadas. Taskbar real, rotação, cliques e auditoria final de distribuição são etapas separadas. O diagnóstico leu CPU/RAM reais; consultas nativas Codex e Kiro retornaram uma janela cada. Claude interrompeu em setup/trust e Copilot estava ausente. Veja a [matriz Windows](../windows/docs/VALIDATION.md).

O [instalador Windows](../windows/setup/README.md#compilar) tem build separado que incorpora o portátil, o companion assinado e, quando necessário, o certificado público. Produz `publish/NexoBar-Setup-x64.exe`, autocontido e de arquivo único; não exige ferramentas de desenvolvimento no destino. Autostart é opt-in. Na versão 0.5 passaram 81 checks, build e verificação de integridade/confiança do payload; o candidato foi assinado e verificado com SignTool. A UI abriu, preservou as opções existentes e bloqueou a revisão com o NexoBar em execução. A instalação física 0.5 foi confirmada no [registro nativo](../windows/docs/INSTALLATION-VALIDATION.md); a 0.6 tem validação separada. A assinatura local de teste não comprova reputação pública do preview. Esses resultados anteriores não comprovam build, UI ou instalação da 0.6; os recursos e limites atuais estão na [matriz 0.6](../windows/docs/PARITY-0.6.md).

Após extrair no Windows, `pwsh -NoProfile -File smoke-windows.ps1 -OpenUI` diagnostica sensores e abre a GUI com preferências isoladas. `-TestConPty` executa clientes sintéticos; a consulta real `-QueryClaude` é opt-in e exige `-ClaudeFolder` já confiável. Leia os [parâmetros e verificações completas](../windows/README.md#compilar-e-verificar) antes da execução. O smoke padrão não consulta Claude.

## Preferências e interação

| Plataforma | Preferências |
|---|---|
| macOS | `~/Library/Application Support/NexoBar/indicators.json` e `appearance.json`. |
| Windows | `%LOCALAPPDATA%\NexoBar\indicators.json`. |

As gravações são atômicas. `--data-directory` permite separar testes do uso normal, incluindo pastas das CLIs. Fechar a janela de configuração mantém a coleta; **Sair** encerra o aplicativo.

No Mac, o clique esquerdo abre o detalhe do indicador e o direito abre as opções. As setas alteram a ordem dentro do grupo NexoBar. Os estilos Sistema, Instrumentos, Contorno, Preenchido e Siglas são selecionáveis; a atualização preserva preferências. Temperaturas são opções filhas de CPU/GPU, sem ícone extra. Todos os indicadores ocultos mantêm acesso às opções; excedentes ficam em **+N**.

**Interação nos monitores**, no macOS, permite cliques no principal ou em todos; a duplicação da barra é controlada pelo sistema. Métricas não ativam o aplicativo; detalhes fecham ao trocar de Space. Essas escolhas não alteram a configuração de ocultação da barra do macOS.

## O que os números significam

| Medição | macOS | Windows |
|---|---|---|
| CPU | Delta de ticks user + system + nice sobre total. | Delta de `GetSystemTimes`. |
| Memória | Páginas ativas + wired + compressor, sobre RAM física; exclui cache inativo e pode diferir do Monitor de Atividade. | Total físico menos disponível de `GlobalMemoryStatusEx`. |
| GPU | Maior percentual publicado pelo driver entre aceleradores; não soma GPUs. | Cada GPU do LibreHardwareMonitor tem leitura e identidade próprias. |
| Temperatura | Máximo entre sensores válidos CPU/GPU; média e quantidade no detalhe. | Somente leituras fornecidas pelo backend e permitidas pelo driver. |

A primeira amostra de CPU é desconhecida. Memória usa GiB (1.073.741.824 bytes), em uso/total por padrão; percentual é uma opção. Sensores atualizam a cada três segundos. Gráficos mantêm até cinco minutos em RAM e expiram mesmo se o sensor parar de responder. Não há controle de ventoinha, tensão, frequência ou potência.

Os mapas AppleSMC contemplam gerações documentadas, mas somente Apple M5 Pro teve teste físico nesta entrega. Outros chips e Intel exigem validação. Leia [fontes e restrições dos sensores](HARDWARE-NOTICES.md).

Cotas mostram somente janelas informadas pela fonte. Layout horizontal é padrão; duas linhas e tempo restante detalhado são opções. No Windows 0.6, mostrar tempo até a renovação é uma opção independente dos nomes; duas linhas exigem duas janelas reais e uma semanal Codex aparece sozinha. O WidBar permite 1–8 indicadores no total por página, distribuições como 2+3 ou 1+4 e espaço de 0–12 px entre linhas (padrão 4). Altura/largura dependem da taskbar e do host. Um reset vencido não confirma renovação. O aviso opcional exige uma nova leitura que confirme mudança, conforme a política do provedor. Não há associação entre consumo físico da máquina e consumo de uma tarefa de IA.
