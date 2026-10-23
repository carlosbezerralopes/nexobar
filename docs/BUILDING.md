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

O build executa os testes do núcleo e de pipe, compila WPF e publica `win-x64 --self-contained` em `dist/NexoBar-Windows-x64-preview.zip`. O harness sintético ConPTY só é executado em Windows. Compilação cruzada não valida interface, sensores, CLIs autenticadas ou ciclo de processos no Windows.

O ZIP inclui app portátil para faixa/bandeja e kit-fonte WidBar. O MSIX do companion exige ferramentas Windows, assinatura e implantação próprias. Veja [compilar WidBar](../windows/widbar/README.md#compilar).

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

Cotas mostram somente janelas informadas pela fonte. Layout horizontal é padrão; duas linhas e tempo restante detalhado são opções. Um reset vencido não confirma renovação. O aviso opcional exige uma nova leitura que confirme mudança, conforme a política do provedor. Não há associação entre consumo físico da máquina e consumo de uma tarefa de IA.
