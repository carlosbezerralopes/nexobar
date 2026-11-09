# Widget de mesa dos workers — macOS 0.4.0

Widget WidgetKit (**NexoBar Workers**) que mostra, na mesa do Mac, o próprio Mac e os workers Ubuntu. Dos workers, só lê o que o coletor `telemetria-workers` já grava; o Mac é lido pelo NexoBar e gravado no mesmo formato.

## Fonte

`~/Library/Application Support/workers-telemetria/`, atualizada a cada 5 s pelo agente launchd do coletor:

| Arquivo | Uso no widget |
|---|---|
| `<worker>.json` | Última leitura (formato v1): CPU, RAM, SSD, GPU (`null` sem NVIDIA), ventoinhas, processos. No SSD, o widget usa `ativo` (% do tempo com E/S), `leitura_bs` e `escrita_bs` (bytes/s), como o disco no Windows; `uso` é espaço ocupado e não é exibido. RAM: o total exibido é `ram.instalada_gb` (soma dos pentes), não o `total_gb` utilizável. Também lê `claude_sessoes` (sessões do Claude Code abertas no worker, sem contar o processo `remote-control`). Campos ausentes, como num worker com coletor antigo, aparecem como "—". |
| `<worker>.estado.json` | `conectando`, `conectado` ou `desconectado`, com o detalhe do SSH. |
| `<worker>/AAAA-MM-DD.jsonl` | Histórico de 30 s. Ainda não exibido; o caminho está em `WorkersTelemetry.historyURL`. |

## Comportamento

- Um cartão por worker, na ordem CPU · GPU · SSD · RAM, com temperaturas, watts da GPU, ventoinha e sessões do Claude, os três processos que mais usam CPU, só os que arredondam para 1% ou mais (só o maior no tamanho médio; % do `top`, em que 100% é um núcleo) e o maior processo na GPU, quando houver. A memória da GPU fica numa linha própria (MEM), logo abaixo da GPU, nos tamanhos grande e extragrande; as taxas do SSD só aparecem quando cabem.
- A hora da leitura fica sempre visível, na última linha do cartão, para o apelido ocupar a largura do cabeçalho. Leitura recebida há mais de 60 s, worker desconectado ou conectando aparece esmaecido como desatualizado. A timeline já traz a entrada em que cada cartão expira, sem depender de recarga.
- Ausência não é zero: campo sem leitura aparece como "—"; worker sem NVIDIA mostra "sem GPU".
- Tamanhos: médio (2 cartões, sem load/watts/swap), grande (até 4) e extragrande (até 4 lado a lado).
- **Clique num cartão**: o NexoBar abre a janela daquela posição para escolher o PC (ou Automático) e o apelido. O apelido pertence ao PC e o acompanha se ele mudar de posição; escolher um PC que já está em outra posição troca as duas. No automático, o Mac vem primeiro e os workers depois, em ordem alfabética. As escolhas ficam em `~/Library/Application Support/NexoBar/widget-workers/posicoes.json`.
- O app NexoBar verifica a pasta a cada 5 s e pede ao WidgetKit a recarga quando um arquivo muda.

## Mac

O NexoBar grava `~/Library/Application Support/NexoBar/widget-workers/mac.json` a cada 5 s: CPU, memória, GPU e temperaturas do coletor do app; RAM instalada (`hw.memsize`), swap, SSD interno (tempo ativo e taxas do `IOBlockStorageDriver`, espaço livre do volume), ventoinhas (AppleSMC `F0Ac`…), três processos do `ps` (média recente do macOS, não a amostra instantânea do `top`) e sessões do Claude Code, incluindo as do app Claude. Da GPU, também: watts pelo IOReport (canal "GPU Energy", interface privada da Apple usada sem root, como no macmon; se mudar num macOS novo, os watts ficam ausentes) e memória em uso (IOAccelerator) sobre o limite que o macOS dá à GPU (`recommendedMaxWorkingSetSize`, cerca de 3/4 da RAM unificada, ex.: 37 de 48 GB). A temperatura do SSD não tem fonte sem root e fica fora.

## Sandbox e assinatura

A extensão é sandbox e lê as duas pastas (coletor e NexoBar) pela exceção `com.apple.security.temporary-exception.files.home-relative-path.read-only` ([entitlements](../scripts/macos/WorkersWidget.entitlements)), sem app group nem cópia pelo app. Funciona com a assinatura local (ad-hoc) do preview; uma distribuição pela App Store exigiria outra estratégia.

O executável da extensão precisa entrar por `_NSExtensionMain` (`-e _NSExtensionMain` em `Package.swift`), como o Xcode faz. Com o `main` comum do Swift, o ExtensionFoundation para em `EXC_BREAKPOINT` antes de desenhar e o widget não aparece na galeria.

## Build

O [build.ps1](../scripts/build.ps1) monta a extensão em `Contents/PlugIns` e registra o esquema `nexobar://` no app, usado pelo clique (`nexobar://workers/posicao/<n>`).

Ao mudar o tipo de configuração do widget, suba `CFBundleVersion`: o chronod guarda o descritor por versão. A versão 12 trocou o "Editar widget" (App Intents) pelo clique; widgets adicionados antes precisam ser removidos e adicionados de novo.

## Diagnóstico

```bash
pluginkit -m -v -p com.apple.widgetkit-extension | grep nexobar
/usr/bin/log show --last 5m --style compact --predicate 'process == "NexoBarWorkersWidget"'
```

Após reinstalar o app, a galeria pode manter a lista antiga até ser reaberta.
