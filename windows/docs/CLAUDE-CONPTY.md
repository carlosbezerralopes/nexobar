# Claude /usage no Windows 0.6.0

Contrato: `app/ClaudeConPty.cs` → `core/ClaudeNativeUsage.cs`; pastas em `core/CLIWorkingDirectories.cs`. Sem credenciais, login, trust automático, inferência, fallback status line/Desktop ou transcrição persistida.

A descoberta aceita o executável nativo `claude.exe` já instalado, inclusive o fornecido pelo pacote npm oficial `@anthropic-ai/claude-code`. O shim `.cmd` não é executado e não há instalação ou autenticação automática. Ausência de um executável nativo válido resulta em indisponível.

O executável nativo `claude.exe` recebe os argumentos fixos `--safe-mode --strict-mcp-config --tools "" --ax-screen-reader --settings '{"disableRemoteControl":true,"remoteControlAtStartup":false}'`. As aspas seguem a convenção de argumentos Windows; nenhuma shell é usada. `.cmd` é recusado porque exige parsing adicional. `BROWSER` é definido como comando fixo sem navegador, mas a barreira principal é não enviar input a telas de login/setup/trust e abortá-las.

O processo é criado com `CREATE_SUSPENDED | EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT`, sem herdar handles. O atributo `PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE` conecta ConPTY 160×80. A raiz só é retomada depois de entrar em Job com `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`. O Job também encerra descendentes após a raiz sair.

Com pseudoconsole, `STARTF_USESTDHANDLES` fica ativado com handles padrão explicitamente nulos, evitando herdar os streams redirecionados do pai; os endpoints dos pipes permanecem vivos até `CreateProcess`. Essas condições foram corrigidas e exercitadas pelo harness nativo.

Um reader dedicado drena o pipe de saída concorrentemente. Após 512KiB, descarta bytes adicionais e sinaliza erro, mantendo drenagem até fechar o pseudoconsole. O controle só envia `/usage\r` uma vez, após identidade Claude + plano + prompt vazio, nunca texto do modelo. O frame inicial é apagado do parser quando a requisição é enviada, evitando recuperar cotas anteriores. O retorno requer mudança posterior, 1s após envio, 1s de estabilidade, ausência de refreshing/loading e percentual em toda seção reconhecida. A renovação é interpretada no timezone declarado; datas inválidas, timezone desconhecido ou DST ambíguo ficam sem contador.

Cleanup encerra o Job e aguarda a raiz por até 2s, fecha input, chama `ClosePseudoConsole` enquanto o reader continua drenando, aguarda EOF e fecha handles/memória/registro em finally. Se falhar antes do reader, fecha o pipe de saída antes do pseudoconsole. Isso evita a condição documentada de bloqueio síncrono do flush nas versões anteriores ao Windows 11 24H2. O harness impõe watchdog adicional por caso.

Referências oficiais Microsoft:

- [Criar sessão pseudoconsole](https://learn.microsoft.com/en-us/windows/console/creating-a-pseudoconsole-session): pipes em canais separados e ordem de criação.
- [ClosePseudoConsole](https://learn.microsoft.com/en-us/windows/console/closepseudoconsole): comportamento antes/depois de Windows 11 24H2, drenagem durante encerramento.
- [Job Objects](https://learn.microsoft.com/en-us/windows/win32/procthread/job-objects): ownership de processos/descendentes e kill-on-close.

Verificação anterior 0.5 (23/10/2026): Windows 11 x64, build 26300, .NET SDK 10.0.402; 63 checks ConPTY passaram com clientes e descendentes sintéticos, incluindo timeout, cancelamento, shutdown, falhas de startup e Jobs próprios vazios ao final. O harness usa UTF-8 e aquece o runtime antes da baseline; na execução anterior 0.4, handles passaram de 326 para 327. Isso verifica o transporte e o lifecycle sintéticos, sem executar clientes autenticados no harness. Reprodução: `smoke-windows.ps1 -TestConPty` em Windows 11 nativo.

A consulta real só ocorre mediante `-QueryClaude -ClaudeFolder <pasta-ja-confiavel>` ou ao habilitar Claude no app com pasta configurada. Login, setup ou trust interrompem a consulta sem resposta automática.

No diagnóstico comparativo de 23/10/2026, o instalado 0.5 ficou indisponível com PATH normal; com PATH temporário no processo apontando para o executável nativo npm já existente, `/usage` retornou em 5,128 s, com três janelas (duas de conta e uma por modelo) e nenhum processo no Job ao final. Não houve login, trust ou prompt ao modelo. Isso isolou a descoberta do executável como causa nesse ambiente; não equivale a validar o app 0.6 com PATH normal.

A correção 0.6 de descoberta e transporte passou em 83 checks com processos e diretórios sintéticos. A execução real da release 0.6, UI e instalação têm aceite separado. O registro anterior 0.3.1, limitado a fixtures/cross-build, está preservado na [matriz de evidências](VALIDATION.md#base-preservada--claude-conpty-031-23102026).