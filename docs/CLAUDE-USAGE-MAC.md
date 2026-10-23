# Claude /usage temporário — macOS0.3.1

O NexoBar cria um PTY sem abrir Terminal.app, inicia a CLI oficial já instalada, aguarda seu prompt, envia somente /usage, espera o painel terminar de atualizar e encerra o grupo próprio. A sessão interna é administrada pela CLI. Não há leitor de credenciais no app, login, inferência ou nova confiança automática.

## Configuração

Personalizar barra → Pastas das CLIs. Claude exige pasta existente já confiável no cliente. Codex permite escolher uma pasta, mas seu app-server funciona no diretório temporário do NexoBar quando o campo fica vazio. Preferências separadas em Application Support/NexoBar/cli-directories.json. Uma escolha não altera configurações de confiança dos clientes. Pasta ausente/inválida, setup, trust ou login fazem a consulta ficar indisponível.

## Processo e leitura

- Cadência5min ou ação manual; sem instâncias concorrentes do mesmo provedor no app.
- CLI2.1.309 validada com safe-mode, ferramentas vazias, MCP externo desabilitado e saída para leitor de tela.
- RemoteControl desligado somente no processo auxiliar por settings de linha de comando. Nenhuma configuração persistente do cliente é mudada por consulta.
- A flag composta CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC é retirada do ambiente do filho: o teste com ela falhou; sem ela o /usage retornou as cotas. Updater e abertura de navegador são desabilitados por processo.
- Até45s, saída limitada512KiB e mantida somente em memória. O emulador de terminal acompanha apagamentos/redesenhos; não concatena primeiro valor em cache com resultado final.
- Só são interpretados blocos Current session / Current week. Estatísticas de tokens, contribuições, prompts e links de sessão não são persistidos. Janelas por modelo ficam no detalhe.
- Reset usa o horário e fuso apresentados pela CLI, com precisão de minuto. Se não for reconhecido, não se inventa um intervalo5h/7d. Zero precisa ser explícito.
- Ao terminar, o grupo próprio é encerrado e reaproveitamento de snapshots após erro é proibido. Fechar o aplicativo encerra seus subprocessos registrados.

A CLI pode manter seus próprios registros técnicos da sessão; o NexoBar não os extrai, apaga ou transforma em fonte de cotas. A implementação depende do painel textual do cliente e falha se seu formato deixar de ser reconhecido.

## Evidência

Um diagnóstico nativo com CLI2.1.309 retornou janelas de sessão, semanal e modelo em7,35s, com zero processos próprios ao retornar. O teste interativo informou ausência de inferência. Não se presume que isso valide outras versões de CLI, máquinas ou Windows; dados da conta e saídas brutas não fazem parte deste repositório.

Referência oficial do comando: https://code.claude.com/docs/en/commands . RemoteControl: https://code.claude.com/docs/en/remote-control . Testes de parser, PTY e pastas usam fixtures, não contas reais.
