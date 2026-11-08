# Widget de mesa dos workers — macOS 0.4.0

Widget WidgetKit (**NexoBar Workers**) que mostra, na mesa do Mac, a telemetria dos workers Ubuntu publicada pelo coletor `telemetria-workers`. O NexoBar não coleta nada dos workers: só lê os arquivos que o coletor já grava.

## Fonte

`~/Library/Application Support/workers-telemetria/`, atualizada a cada 5 s pelo agente launchd do coletor:

| Arquivo | Uso no widget |
|---|---|
| `<worker>.json` | Última leitura (formato v1): CPU, RAM, SSD, GPU (`null` sem NVIDIA), ventoinhas, processos. |
| `<worker>.estado.json` | `conectando`, `conectado` ou `desconectado`, com o detalhe do SSH. |
| `<worker>/AAAA-MM-DD.jsonl` | Histórico de 30 s. Ainda não exibido; o caminho está em `WorkersTelemetry.historyURL`. |

## Comportamento

- Um cartão por worker, na ordem CPU · GPU · SSD · RAM, com temperaturas, ventoinha, o processo que mais usa CPU e o maior processo na GPU, quando houver.
- A hora da leitura fica sempre no cabeçalho. Leitura recebida há mais de 60 s, worker desconectado ou conectando aparece esmaecido como desatualizado. A timeline já traz a entrada em que cada cartão expira, sem depender de recarga.
- Ausência não é zero: campo sem leitura aparece como "—"; worker sem NVIDIA mostra "sem GPU".
- Tamanhos: médio (2 cartões, sem load/watts/swap), grande (até 4) e extragrande (até 4 lado a lado).
- **Editar widget** (clique direito no widget): 1º a 4º worker definem a ordem, e cada posição tem um apelido que substitui o nome no cartão. Posição vazia é ignorada e worker repetido aparece só na primeira. Worker escolhido que sumiu da pasta continua visível como sem leitura. Sem nenhuma escolha, aparecem todos, conectados primeiro.
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
