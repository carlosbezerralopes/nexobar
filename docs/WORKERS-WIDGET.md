# Widget de mesa dos workers — macOS 0.4.0

Widget WidgetKit (**NexoBar Workers**) que mostra, na mesa do Mac, a telemetria dos workers Ubuntu publicada pelo coletor `telemetria-workers`. O NexoBar não coleta nada dos workers: só lê os arquivos que o coletor já grava.

## Fonte

`~/Library/Application Support/workers-telemetria/`, atualizada a cada 5 s pelo agente launchd do coletor:

| Arquivo | Uso no widget |
|---|---|
| `<worker>.json` | Última leitura (formato v1): CPU, RAM, SSD, GPU (`null` sem NVIDIA), ventoinhas, processos. No SSD, o widget usa `ativo` (% do tempo com E/S), `leitura_bs` e `escrita_bs` (bytes/s), como o disco no Windows; `uso` é espaço ocupado e não é exibido. RAM: o total exibido é `ram.instalada_gb` (soma dos pentes), não o `total_gb` utilizável. Também lê `claude_sessoes` (sessões do Claude Code abertas no worker, sem contar o processo `remote-control`). Campos ausentes, como num worker com coletor antigo, aparecem como "—". |
| `<worker>.estado.json` | `conectando`, `conectado` ou `desconectado`, com o detalhe do SSH. |
| `<worker>/AAAA-MM-DD.jsonl` | Histórico de 30 s. Ainda não exibido; o caminho está em `WorkersTelemetry.historyURL`. |

## Comportamento

- Um cartão por worker, na ordem CPU · GPU · SSD · RAM, com temperaturas, watts da GPU, ventoinha e sessões do Claude, os três processos que mais usam CPU, só os que arredondam para 1% ou mais (só o maior no tamanho médio; % do `top`, em que 100% é um núcleo) e o maior processo na GPU, quando houver. VRAM e taxas do SSD só aparecem quando cabem na linha.
- A hora da leitura fica sempre visível, na última linha do cartão, para o apelido ocupar a largura do cabeçalho. Leitura recebida há mais de 60 s, worker desconectado ou conectando aparece esmaecido como desatualizado. A timeline já traz a entrada em que cada cartão expira, sem depender de recarga.
- Ausência não é zero: campo sem leitura aparece como "—"; worker sem NVIDIA mostra "sem GPU".
- Tamanhos: médio (2 cartões, sem load/watts/swap), grande (até 4) e extragrande (até 4 lado a lado).
- **Editar widget** (clique direito no widget): quatro posições, cada uma com worker e apelido. O apelido pertence ao worker escolhido na mesma posição e substitui o nome no cartão; apelido em posição sem worker é ignorado. Os escolhidos vêm primeiro, na ordem das posições, e os demais depois, em ordem alfabética com o nome original. Worker repetido aparece só na primeira posição; worker escolhido que sumiu da pasta continua visível como sem leitura.
- O app NexoBar verifica a pasta a cada 5 s e pede ao WidgetKit a recarga quando um arquivo muda.

## Sandbox e assinatura

A extensão é sandbox e lê a pasta pela exceção `com.apple.security.temporary-exception.files.home-relative-path.read-only` ([entitlements](../scripts/macos/WorkersWidget.entitlements)), sem app group nem cópia pelo app. Funciona com a assinatura local (ad-hoc) do preview; uma distribuição pela App Store exigiria outra estratégia.

O executável da extensão precisa entrar por `_NSExtensionMain` (`-e _NSExtensionMain` em `Package.swift`), como o Xcode faz. Com o `main` comum do Swift, o ExtensionFoundation para em `EXC_BREAKPOINT` antes de desenhar e o widget não aparece na galeria.

## Build

A configuração usa App Intents. O editor só mostra as opções se a extensão tiver `Contents/Resources/Metadata.appintents`, que o Xcode normalmente gera. O [build.ps1](../scripts/build.ps1) compila a extensão com `swiftc` emitindo os const values e roda `xcrun appintentsmetadataprocessor`; o build falha se os metadados não forem gerados. O alvo SwiftPM `NexoBarWorkersWidget` continua para compilação e testes.

Ao mudar o tipo de configuração do widget, suba `CFBundleVersion`: o chronod guarda o descritor por versão e, com a versão antiga, "Editar widget" abre a galeria. Widgets já na mesa criados sem configuração precisam ser removidos e adicionados de novo.

## Diagnóstico

```bash
pluginkit -m -v -p com.apple.widgetkit-extension | grep nexobar
/usr/bin/log show --last 5m --style compact --predicate 'process == "NexoBarWorkersWidget"'
```

Após reinstalar o app, a galeria pode manter a lista antiga até ser reaberta.
