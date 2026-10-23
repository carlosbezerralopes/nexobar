# Evidências e limites — Windows 0.5.0

Em 23/10/2026, no Windows 11 x64 (build 26300), passaram 226 checks de núcleo, 60 de ponte/configuração/vetores e 63 de ConPTY sintético. Os testes incluem as oito combinações de modos em fixtures, normalização/migração, paginação, posições personalizadas e comunicação real por pipe entre processos do mesmo usuário. As combinações não foram exercitadas visualmente. As fixtures não executam CLIs autenticadas; em diagnóstico nativo separado, Codex e Kiro retornaram uma janela cada. Claude nativo interrompeu em setup/trust, sem login nem concessão de confiança; Copilot estava ausente.

Build nativo: .NET SDK 10.0.402, WPF e WinUI/XAML, WidBar.SDK 2.1.0 e WindowsAppSDK 2.3.1. MakePri/MakeAppx vieram do NuGet `Microsoft.Windows.SDK.BuildTools` 10.0.26100.4654, sem Visual Studio/Windows SDK completos. O WPF 0.5 foi publicado localmente e empacotado em ZIP; o MSIX 0.5 foi compilado, assinado com certificado de teste, verificado e instalado. `Add-AppxPackage` terminou com exit 0 e `Get-AppxPackage` confirmou versão 0.5.0.0, status 0.

A configuração WPF 0.5 mostrou preset/prévia 2+3, cinco itens e botões de linha/ordem. O preset foi aplicado e o JSON confirmou os cinco IDs com largura 402 px preservada. O WidBar foi encerrado pela opção **Sair** antes da atualização e reabriu “Em execução” na 0.5. As opções do companion mostraram ícones CPU/RAM/Claude/Codex/Kiro em 2+3. Largura própria de 305 px foi testada; após Cancelar, reabrir mostrou herança de 402 px, e Salvar com herança foi executado. Isso não comprova layout real na taskbar, rotação, hover ou cliques.

O [instalador](../setup/README.md) foi implementado como EXE autocontido de arquivo único. Passaram 81 checks M07 em duas execuções, build e verificações de integridade/confiança do payload; o candidato assinado passou na verificação SignTool. A UI abriu preservando WidBar ligado, faixa/bandeja/autostart desligados; **Revisar** bloqueou a operação com o NexoBar em execução. A instalação física pelo Setup, incluindo escrita no destino e os fluxos de UAC/Store, permanece pendente. A assinatura local de teste não comprova reputação pública do preview.

Na validação anterior 0.4, NexoBar.Widget 0.4.0.0 foi instalado com confiança autorizada do certificado de teste. No host oficial WidBar 1.2.8.0, o plugin foi descoberto/adicionado e mostrou “Em execução”; o NexoBar indicou cliente da ponte ativo. O WPF iniciou com `--settings`. O harness ConPTY deixou Jobs sem raízes/descendentes e handles passaram de 326 para 327 após aquecimento do runtime. Esse ciclo aprovou 148 checks de núcleo, 20 de ponte e 63 de ConPTY, sem executar CLIs autenticadas.

Logs e recibos locais registram builds, instalações 0.4/0.5 e verificações de assinatura. A auditoria dos pacotes anteriores não encontrou PDBs nem caminhos pessoais; os novos artefatos 0.5 exigem auditoria final própria antes de distribuir. Diagnósticos de hardware e identificadores reais permanecem locais, fora da documentação pública.

| Requisito | Implementação / evidência automatizada | Estado físico |
|---|---|---|
| CPU/RAM reais | P/Invoke GetSystemTimes/GlobalMemoryStatusEx, sem zero de primeira amostra; diagnóstico nativo com exit 0 e leituras reais | Leitura confirmada; apresentação/gráficos pendentes |
| Cada GPU e temperaturas | LHM 0.9.6; IDs, duas GPUs e preferências de redescoberta exercitados por fixtures; Intel Iris Xe detectada e conferida no inventário Windows | Carga/temperatura GPU e temperaturas CPU indisponíveis ao usuário; múltiplas GPUs físicas pendentes |
| Marca do fabricante GPU | Wordmarks NVIDIA/intel/AMD por HardwareType, fallback genérico; fixtures para fabricante desconhecido, duas NVIDIA e reordenação | Aparência WPF real pendente; preview HTML é ilustrativo |
| Faixa junto à taskbar | Fundo alpha/texto opaco; overlay sem reserva por padrão; AppBar/reserva opcionais; correção implementada para distinguir BUSY de fullscreen com geometria | Transparência, maximização, fullscreen real em mais de um aplicativo e Explorer reiniciado pendentes |
| Tema/interação/monitores | WPF Segoe UI, paleta e hover com contraste, picker persistido, no-activate na faixa e SetWindowPos | Clique, foco, claro/escuro e DPI pendentes |
| Preferências e personalização | Nome, visibilidade, ordem, temperatura filha, RAM nominal; roundtrip atômico e IDs estáveis; customRows, preset 2+3 e largura global/por instância em fixtures | Preset aplicado, cinco IDs/largura 402 px confirmados no JSON; override 305 px, Cancelar e Salvar herdado exercitados nas opções do host |
| Claude | /usage em ConPTY, pasta explícita, parser VT e protocolo com fixtures; limite512KiB/45s, consulta5min/manual; transporte sintético nativo aprovado | Executável nativo localizado; recusou setup/trust com segurança e Jobs vazios; leitura de cotas pendente |
| Codex | Parser RPC, conta versus janelas por modelo, ausência/erro em fixtures | Consulta nativa retornou uma janela; apresentação visual pendente |
| Kiro / Copilot | Parsers com fixtures; consultas não interativas delimitadas | Kiro retornou uma janela em consulta nativa; Copilot ausente |
| Cotas/contadores | Horizontal/duas linhas, reset compacto/detalhado, zero sem renovação e alertas confirmados em fixtures | UI/avisos pendentes |
| Histórico 5min | Expiração mesmo se sensor parar; ausência não vira zero | Gráfico real pendente |
| Processos próprios | CreateProcess suspenso → Job kill-on-close → ResumeThread; Claude45s, demais20s, limite512KiB; harness sintético nativo passou, incluindo timeout/cancelamento/árvore/Jobs vazios | Encerramento com clientes autenticados e Sair pela GUI pendentes |
| Recuperar acesso | Ícone de bandeja, todos ocultos e +N | Bandeja e overflow pendentes |
| Modos independentes | Faixa/bandeja/WidBar, oito combinações em fixtures, recuperação com todos desligados | Toggles e ciclo visual Windows pendentes |
| Indicadores na bandeja | Ícones por ID, números ampliados, tooltip, clique individual e descarte HICON; imagens nativas 16/20/24 px revisadas | Clique, disposição/overflow e DPI misto pendentes |
| Plugin WidBar | 1–8 itens, customRows/preset 2+3, vetores Mac, largura global 120–600 e override por instância; WinUI/XAML/MSIX 0.5 assinado/verificado/instalado | Host 0.5 em execução e opções 2+3 revisadas; taskbar real, rotação/hover/cliques, DPI e ACL entre usuários pendentes |
| Instalador | EXE de arquivo único/autocontido, 81 checks; payload íntegro/confiável e candidato assinado/verificado; autostart opt-in | UI/preservação de opções e bloqueio com app aberto verificados; instalação física, UAC/Store e autostart aplicado pendentes |
| Atividade passiva de IA | Estado “não informada pela fonte” | Não implementada como observação de tarefas neste ciclo |
| Antigravity / demais | Indisponível até interface segura validada no Windows | Sem paridade runtime para esses provedores |

Os testes executados no core são um programa de fixtures sem pacotes de teste, chamado pelo build. Resultado e contagem finais ficam no log da entrega; nenhum teste executa autenticação, Keychain, Credential Manager ou processos de provedores. Não se declara paridade de 100% com macOS ou Codenotch.

O ambiente físico disponível tem um monitor e uma GPU física; Microsoft Remote Display Adapter é um adaptador de exibição remoto. Não comprova múltiplas GPUs nem DPI misto. **Aplicar** foi acionado e persistiu o preset. A correção para não antecipar consultas de IA está implementada; a medição do número de consultas permanece pendente.

Smoke reproduzível: `scripts/smoke-windows.ps1` no código-fonte ou `smoke-windows.ps1` no ZIP. Por padrão, grava métricas de hardware, nomes/IDs das GPUs e estado das leituras. `-TestConPty` aciona clientes sintéticos; `-QueryClaude` é uma consulta real opt-in e retorna somente cotas/resets e diagnóstico sanitizado. A revisão visual deve incluir mais de uma aplicação fullscreen antes de atribuir comportamento de barra a um aplicativo específico.


## Base preservada — Claude ConPTY 0.3.1 (23/10/2026)

Registro anterior às execuções Windows acima; os estados pendentes abaixo descrevem somente essa base histórica.

- Core: 131 checks locais no macOS, incluindo parser /usage, weekly-only, zero explícito, modelo separado, frame parcial, percentuais inválidos, UTF8/VT fragmentados, erase/cursor/OSC, refresh concluído e estável, login/trust/setup recusados, IANA America/Fortaleza, DST e viradas de dia/ano, pasta explícita e persistência isolada.
- Harness `native-tests/`: compilação cross-platform e win-x64; execução Windows **pendente**. Usa somente clientes/descendentes sintéticos e watchdog, não toca sessão de usuário.
- WPF/ConPTY: implementação e cross-build não comprovam funcionamento Windows físico. Consultas autenticadas, chooser, sensores, taskbar, DPI/fullscreen e shutdown físico permanecem pendentes do smoke.
- Runtime Claude não lê `claude-statusline.json` e o pacote 0.3.1 não instala ponte. Histórico/parser v1 em fonte e suas fixtures são preservados, sem fallback de execução.
