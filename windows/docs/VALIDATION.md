# Evidências e limites — Windows 0.4.0

Em 23/10/2026, o núcleo passou em 148 checks e a ponte/política WidBar em 20 checks. Os testes incluem as oito combinações de modos, normalização/migração, paginação e comunicação real por pipe entre processos do mesmo usuário. A biblioteca do plugin compilou contra WidBar.SDK2.1.0/WindowsAppSDK2.3.1 reais. Isso não valida XAML, MSIX, instalação nem execução do host Windows.

Build local: macOS arm64, .NET SDK 10.0.402 e runtime 10.0.13. Publicação cruzada em win-x64 self-contained, WPF sem XAML, Windows-targeting habilitado. Compilar não comprova a execução da GUI no Windows.

| Requisito | Implementação / evidência automatizada | Estado físico |
|---|---|---|
| CPU/RAM reais | P/Invoke GetSystemTimes/GlobalMemoryStatusEx, sem zero de primeira amostra | Pendente no Windows |
| Cada GPU e temperaturas | LHM 0.9.6; IDs, duas GPUs e preferências de redescoberta exercitados por fixtures | Sensores/permissões/driver pendentes |
| Marca do fabricante GPU | Wordmarks NVIDIA/intel/AMD por HardwareType, fallback genérico; fixtures para fabricante desconhecido, duas NVIDIA e reordenação | Aparência WPF real pendente; preview HTML é ilustrativo |
| Faixa junto à taskbar | Fundo alpha/texto opaco; overlay sem reserva por padrão; AppBar/reserva opcionais; SHQueryUserNotificationState no overlay | Transparência, maximização, fullscreen e Explorer reiniciado pendentes |
| Tema/interação/monitores | WPF Segoe UI, paleta e hover com contraste, picker persistido, no-activate na faixa e SetWindowPos | Clique, foco, claro/escuro e DPI pendentes |
| Preferências e personalização | Nome, visibilidade, ordem, temperatura filha, RAM nominal; roundtrip atômico e IDs estáveis em fixtures | UI pendente |
| Claude | /usage em ConPTY, pasta explícita, parser VT e protocolo com fixtures; limite512KiB/45s, consulta5min/manual | Consulta real pelo Claude Windows pendente |
| Codex | Parser RPC, conta versus janelas por modelo, ausência/erro em fixtures | CLI Windows autenticada não executada |
| Kiro / Copilot | Parsers com fixtures; consultas não interativas delimitadas | CLIs Windows não executadas |
| Cotas/contadores | Horizontal/duas linhas, reset compacto/detalhado, zero sem renovação e alertas confirmados em fixtures | UI/avisos pendentes |
| Histórico 5min | Expiração mesmo se sensor parar; ausência não vira zero | Gráfico real pendente |
| Processos próprios | CreateProcess suspenso → Job kill-on-close → ResumeThread; Claude45s, demais20s, limite512KiB; harness sintético compilado | Timeout/árvore e harness no Windows pendentes |
| Recuperar acesso | Ícone de bandeja, todos ocultos e +N | Bandeja e overflow pendentes |
| Modos independentes | Faixa/bandeja/WidBar, oito combinações em fixtures, recuperação com todos desligados | Toggles e ciclo visual Windows pendentes |
| Indicadores na bandeja | Ícones por ID, número/glyph por DPI/tema, tooltip, clique individual e descarte HICON | Legibilidade, disposição/overflow e DPI misto pendentes |
| Plugin WidBar | Preview WinUI, 1–4 itens, layouts, rotação/pausa, pipe same-user e política offline testados; C# compila contra SDK real | XAML/MakeAppx/MSIX/assinatura/host Windows pendentes |
| Atividade passiva de IA | Estado “não informada pela fonte” | Não implementada como observação de tarefas neste ciclo |
| Antigravity / demais | Indisponível até interface segura validada no Windows | Sem paridade runtime para esses provedores |

Os testes executados no core são um programa de fixtures sem pacotes de teste, chamado pelo build. Resultado e contagem finais ficam no log da entrega; nenhum teste executa autenticação, Keychain, Credential Manager ou processos de provedores. Não se declara paridade de 100% com macOS ou Codenotch.

Smoke reproduzível: `scripts/smoke-windows.ps1` no código-fonte ou `smoke-windows.ps1` no ZIP. Por padrão, grava métricas de hardware, nomes/IDs das GPUs e estado das leituras. `-TestConPty` aciona clientes sintéticos; `-QueryClaude` é uma consulta real opt-in e retorna somente cotas/resets e diagnóstico sanitizado. A revisão visual deve incluir mais de uma aplicação fullscreen antes de atribuir comportamento de barra a um aplicativo específico.


## Base preservada — Claude ConPTY 0.3.1 (23/10/2026)

- Core: 131 checks locais no macOS, incluindo parser /usage, weekly-only, zero explícito, modelo separado, frame parcial, percentuais inválidos, UTF8/VT fragmentados, erase/cursor/OSC, refresh concluído e estável, login/trust/setup recusados, IANA America/Fortaleza, DST e viradas de dia/ano, pasta explícita e persistência isolada.
- Harness `native-tests/`: compilação cross-platform e win-x64; execução Windows **pendente**. Usa somente clientes/descendentes sintéticos e watchdog, não toca sessão de usuário.
- WPF/ConPTY: implementação e cross-build não comprovam funcionamento Windows físico. Consultas autenticadas, chooser, sensores, taskbar, DPI/fullscreen e shutdown físico permanecem pendentes do smoke.
- Runtime Claude não lê `claude-statusline.json` e o pacote 0.3.1 não instala ponte. Histórico/parser v1 em fonte e suas fixtures são preservados, sem fallback de execução.
