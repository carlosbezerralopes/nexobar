# Claude Code: ponte de cotas da status line

**Escopo atual:** Windows0.3.0 e versões anteriores do Mac. O Mac0.3.1 usa consulta temporária nativa /usage com pasta configurável, sem depender desta ponte. A configuração instalada pelo NexoBar nesta máquina foi restaurada por seu recibo ao migrar; o instalador não deve ser executado para habilitar a nova consultaMac.

O NexoBar lê somente o recibo local produzido pela interface oficial [`statusLine`](https://code.claude.com/docs/en/statusline). Não executa Claude, `/usage`, `/statusline`, login ou uma chamada autenticada. A fonte anterior do Claude Desktop não é fallback do runtime.

Segundo a documentação oficial consultada em 23/10/2026, `rate_limits` aparece após a primeira resposta da API em uma sessão compatível. `five_hour` e `seven_day` podem faltar independentemente; janelas cujo reset passou desaparecem. Instalar a ponte não cria uma observação de cota nem comprova que a conta emitiu esses campos.

Workspace trust, `disableAllHooks` e `allowManagedHooksOnly` podem impedir a execução da status line. O instalador não altera esses controles. Configuração gravada e cotas recebidas são verificações distintas.

## Contrato v1

Arquivo UTF-8, no máximo 16 KiB:

- macOS: `~/Library/Application Support/NexoBar/claude-statusline.json`.
- Windows: `%LOCALAPPDATA%/NexoBar/claude-statusline.json`.

```json
{"schemaVersion":1,"provider":"claude","capturedAt":"2026-10-23T12:00:00.000Z","windows":[{"id":"session","usedPercent":23.5,"resetsAt":1792757100},{"id":"weekly_all","usedPercent":0,"resetsAt":null}]}
```

`capturedAt` é a **data de entrega local pelo Claude Code**, e não a data de uma consulta remota. O cliente pode entregar de novo uma cota que já conhecia. Não se configura `refreshInterval` para simular novas observações. Entregas futuras ou com idade de 30 minutos ou mais são recusadas.

`windows` contém de zero a duas janelas, com IDs únicos `session` e `weekly_all`. `usedPercent` precisa ser número finito entre 0 e 100; booleano, texto, `null` e ausência não são zero. `resetsAt` é número de segundos Unix no intervalo 1.000.000.000–4.102.444.800 ou `null`; milissegundos são recusados. Janela com reset vencido é removida, sem inferir uma renovação. Só a janela semanal ocupa um único slot quando a sessão falta. Nenhuma janela válida significa indisponível.

O produtor substitui integralmente as janelas a cada evento; nunca reaproveita uma janela anterior. Extrai exclusivamente `rate_limits.five_hour.used_percentage/resets_at` e `rate_limits.seven_day.used_percentage/resets_at`. Não persiste stdin bruto, prompt, transcript, sessão, conta, modelo, contagem de tokens ou credenciais. Escreve temporário na mesma pasta, faz flush e troca atômica; em POSIX o arquivo tem permissão `0600`. Windows usa a ACL herdada da pasta privada do usuário; `0600` não equivale a uma ACL Windows. Entrada tem limite de 1 MiB. Evento malformado invalida as janelas quando o arquivo pode ser escrito.

## Preparar e revisar

Pré-requisito: Python 3.11+ instalado. Execute no diretório `scripts/claude-statusline` do código-fonte ou `Contents/Resources/claude-statusline` do aplicativo Mac. A integração instalada usa uma cópia estável do produtor em `NexoBar/integrations/claude-statusline` na pasta de dados do aplicativo; não depende do checkout ou do caminho do bundle.

```text
python3 install.py prepare --directory <pasta-vazia-de-revisao>
```

`prepare` é o dry run: grava apenas `plan.json`, `statusLine.diff.json` e a cópia de `producer.py` na pasta de revisão. Lê os settings para extrair só `statusLine`; não faz cópia do restante. Não lê arquivos de sessão ou autenticação. Confira o diff e o produtor. O comando mostra o digest do plano revisado.

Windows requer `--shell posix` quando o Claude usa Git Bash ou `--shell powershell` quando usa PowerShell 7+. Os paths são emitidos com barras `/` e escapados para o shell escolhido; o shell deve corresponder ao usado pelo cliente. A compatibilidade Windows é de código/fixtures até validação no sistema real. Se o processo está dentro do Claude Desktop MSIX, `%LOCALAPPDATA%` pode estar virtualizado; prepare/aplique pelo terminal normal do usuário e confira o arquivo no ambiente real.

Um campo `statusLine` existente é recusado por padrão. Para encadear explicitamente:

```text
python3 install.py prepare --directory <pasta-vazia-de-revisao> --chain-existing --shell posix --shell-executable /bin/sh
```

`type=command`, `command` e os demais campos antigos são preservados; só o comando passa pelo produtor. O comando anterior recebe os mesmos bytes de stdin, em memória, e sua saída é devolvida sem reformatação (até 64 KiB). Timeout de dois segundos impede travar a entrega. A saída de erro anterior não é gravada. O comando anterior continua responsável por seus próprios efeitos e políticas de dados. Revise-o antes de autorizar o encadeamento. Em Windows, indique o executável real do Git Bash ou do PowerShell **7**, sem fallback para 5.1.

## Aplicar e desfazer

Aplicação explícita, depois da revisão:

```text
python3 install.py apply --plan <pasta-de-revisao>/plan.json --expected-digest <digest-exibido>
```

O instalador verifica o digest, o hash do produtor e a igualdade do campo `statusLine` atual com o observado na preparação. Relê os settings antes de mesclar a alteração e confere a gravação. Preserva os outros campos, inclusive os adicionados depois do dry run. Settings inválidos, symlink, campo alterado e diretório de instalação já existente são recusados. Não há instalação no startup.

`receipt.json` na pasta instalada é o backup delimitado: contém somente o campo anterior, o instalado e metadados da integração. Não guarda outros settings. Para desfazer:

```text
python3 install.py uninstall --receipt <pasta-instalada>/receipt.json
```

Restaura só `statusLine` se ainda for exatamente o instalado; se o usuário o mudou, recusa para não apagar a alteração. Outros settings são preservados. Os arquivos instalados e o recibo permanecem para inspeção; nenhuma árvore é apagada automaticamente. Uma nova preparação exige um diretório de destino novo ou remoção manual dos arquivos conhecidos após a desinstalação.

## Verificar sem sessão autenticada

```text
python3 -m unittest discover -s scripts/claude-statusline -p test_bridge.py -v
```

As fixtures cobrem zero/ausência, reset, filtros de privacidade, atomicidade/limite/permissão POSIX, eventos malformados, paths das duas plataformas, encadeamento/stdin/timeout/saída, dry run, digest e hash, preservação dos settings e restauração condicional. Os testes Swift `ClaudeStatusLineTests` cobrem leitura/freshness/schema e o runtime mantém injeção em `AISessionPolicyTests`. Os testes não executam Claude ou validam autenticação.
