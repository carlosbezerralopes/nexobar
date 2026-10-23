# Evidências e limites — Windows 0.4.0

Em 23/10/2026, no Windows 11 x64 (build 26300), passaram 148 checks de núcleo, 20 de ponte/política WidBar e 63 de ConPTY sintético. Os testes incluem as oito combinações de modos em fixtures, normalização/migração, paginação e comunicação real por pipe entre processos do mesmo usuário. As combinações não foram exercitadas visualmente. O harness ConPTY encerrou os Jobs sem raízes ou descendentes; após aquecimento do runtime, handles passaram de 326 para 327. Nenhuma CLI autenticada foi executada.

Build nativo: .NET SDK 10.0.402, WPF e WinUI/XAML, WidBar.SDK 2.1.0 e WindowsAppSDK 2.3.1. MakePri/MakeAppx vieram do NuGet `Microsoft.Windows.SDK.BuildTools` 10.0.26100.4654, sem Visual Studio/Windows SDK completos. O MSIX foi gerado; uma cópia com assinatura de teste foi verificada e instalada como NexoBar.Widget 0.4.0.0, com confiança autorizada do certificado local. O host oficial WidBar 1.2.8.0 também foi instalado. A descoberta/ativação visual do plugin permanece pendente. O processo WPF iniciou com `--settings`, sem validação visual. Fontes e binários ainda não foram publicados neste ciclo.

Logs e recibos locais da entrega registram os builds com exit 0, instalação e verificação de assinatura. A auditoria dos pacotes examinados não encontrou PDBs nem caminhos pessoais. Diagnósticos de hardware e identificadores reais permanecem locais, fora da documentação pública.

| Requisito | Implementação / evidência automatizada | Estado físico |
|---|---|---|
| CPU/RAM reais | P/Invoke GetSystemTimes/GlobalMemoryStatusEx, sem zero de primeira amostra; diagnóstico nativo com exit 0 e leituras reais | Leitura confirmada; apresentação/gráficos pendentes |
| Cada GPU e temperaturas | LHM 0.9.6; IDs, duas GPUs e preferências de redescoberta exercitados por fixtures; Intel Iris Xe detectada e conferida no inventário Windows | Carga/temperatura GPU e temperaturas CPU indisponíveis ao usuário; múltiplas GPUs físicas pendentes |
| Marca do fabricante GPU | Wordmarks NVIDIA/intel/AMD por HardwareType, fallback genérico; fixtures para fabricante desconhecido, duas NVIDIA e reordenação | Aparência WPF real pendente; preview HTML é ilustrativo |
| Faixa junto à taskbar | Fundo alpha/texto opaco; overlay sem reserva por padrão; AppBar/reserva opcionais; SHQueryUserNotificationState no overlay | Transparência, maximização, fullscreen e Explorer reiniciado pendentes |
| Tema/interação/monitores | WPF Segoe UI, paleta e hover com contraste, picker persistido, no-activate na faixa e SetWindowPos | Clique, foco, claro/escuro e DPI pendentes |
| Preferências e personalização | Nome, visibilidade, ordem, temperatura filha, RAM nominal; roundtrip atômico e IDs estáveis em fixtures | UI pendente |
| Claude | /usage em ConPTY, pasta explícita, parser VT e protocolo com fixtures; limite512KiB/45s, consulta5min/manual; transporte sintético nativo aprovado | Consulta autenticada pendente; somente shim npm observado, executável nativo não comprovado |
| Codex | Parser RPC, conta versus janelas por modelo, ausência/erro em fixtures | CLI Windows autenticada não executada |
| Kiro / Copilot | Parsers com fixtures; consultas não interativas delimitadas | CLIs Windows não executadas |
| Cotas/contadores | Horizontal/duas linhas, reset compacto/detalhado, zero sem renovação e alertas confirmados em fixtures | UI/avisos pendentes |
| Histórico 5min | Expiração mesmo se sensor parar; ausência não vira zero | Gráfico real pendente |
| Processos próprios | CreateProcess suspenso → Job kill-on-close → ResumeThread; Claude45s, demais20s, limite512KiB; harness sintético nativo passou, incluindo timeout/cancelamento/árvore/Jobs vazios | Encerramento com clientes autenticados e Sair pela GUI pendentes |
| Recuperar acesso | Ícone de bandeja, todos ocultos e +N | Bandeja e overflow pendentes |
| Modos independentes | Faixa/bandeja/WidBar, oito combinações em fixtures, recuperação com todos desligados | Toggles e ciclo visual Windows pendentes |
| Indicadores na bandeja | Ícones por ID, número/glyph por DPI/tema, tooltip, clique individual e descarte HICON | Legibilidade, disposição/overflow e DPI misto pendentes |
| Plugin WidBar | 1–4 itens, layouts, rotação/pausa e política offline em fixtures; pipe same-user, WinUI/XAML, MakeAppx, MSIX, assinatura de teste e instalação local verificados; host instalado | Descoberta do plugin, UI no host, rotação/hover/cliques e ACL entre usuários pendentes |
| Atividade passiva de IA | Estado “não informada pela fonte” | Não implementada como observação de tarefas neste ciclo |
| Antigravity / demais | Indisponível até interface segura validada no Windows | Sem paridade runtime para esses provedores |

Os testes executados no core são um programa de fixtures sem pacotes de teste, chamado pelo build. Resultado e contagem finais ficam no log da entrega; nenhum teste executa autenticação, Keychain, Credential Manager ou processos de provedores. Não se declara paridade de 100% com macOS ou Codenotch.

O ambiente físico disponível tem um monitor e uma GPU física; Microsoft Remote Display Adapter é um adaptador de exibição remoto. Não comprova múltiplas GPUs nem DPI misto. A correção de **Aplicar** para não antecipar consultas de IA está implementada; confirmação pela UI e medição do número de consultas permanecem pendentes.

Smoke reproduzível: `scripts/smoke-windows.ps1` no código-fonte ou `smoke-windows.ps1` no ZIP. Por padrão, grava métricas de hardware, nomes/IDs das GPUs e estado das leituras. `-TestConPty` aciona clientes sintéticos; `-QueryClaude` é uma consulta real opt-in e retorna somente cotas/resets e diagnóstico sanitizado. A revisão visual deve incluir mais de uma aplicação fullscreen antes de atribuir comportamento de barra a um aplicativo específico.


## Base preservada — Claude ConPTY 0.3.1 (23/10/2026)

Registro anterior à execução Windows 0.4.0 acima; os estados pendentes abaixo descrevem somente essa base histórica.

- Core: 131 checks locais no macOS, incluindo parser /usage, weekly-only, zero explícito, modelo separado, frame parcial, percentuais inválidos, UTF8/VT fragmentados, erase/cursor/OSC, refresh concluído e estável, login/trust/setup recusados, IANA America/Fortaleza, DST e viradas de dia/ano, pasta explícita e persistência isolada.
- Harness `native-tests/`: compilação cross-platform e win-x64; execução Windows **pendente**. Usa somente clientes/descendentes sintéticos e watchdog, não toca sessão de usuário.
- WPF/ConPTY: implementação e cross-build não comprovam funcionamento Windows físico. Consultas autenticadas, chooser, sensores, taskbar, DPI/fullscreen e shutdown físico permanecem pendentes do smoke.
- Runtime Claude não lê `claude-statusline.json` e o pacote 0.3.1 não instala ponte. Histórico/parser v1 em fonte e suas fixtures são preservados, sem fallback de execução.
