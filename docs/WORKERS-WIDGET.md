# Widget de mesa dos workers — macOS 0.4.0

Widget WidgetKit (**NexoBar Workers**) que mostra, na mesa do Mac, o próprio Mac e os workers Ubuntu. Dos workers, só lê o que o coletor `telemetria-workers` já grava; o Mac é lido pelo NexoBar e gravado no mesmo formato.

## Fonte

`~/Library/Application Support/workers-telemetria/`, atualizada a cada 5 s pelo agente launchd do coletor:

| Arquivo | Uso no widget |
|---|---|
| `<worker>.json` | Última leitura (formato v1): CPU, RAM, SSD, GPU (`null` sem NVIDIA), ventoinhas, processos. No SSD, o widget usa `ativo` (% do tempo com E/S), `leitura_bs` e `escrita_bs` (bytes/s), como o disco no Windows; `uso` é espaço ocupado e não é exibido. RAM: o total exibido é `ram.instalada_gb` (soma dos pentes), não o `total_gb` utilizável. Também lê `claude_sessoes` (sessões do Claude Code abertas no worker, sem contar o processo `remote-control`), exibido só no cartão do Mac, e `uptime_s` (segundos desde o boot, de `/proc/uptime`). Bloco opcional `fila` (item rodando ou último item, `manter_ate`, `desliga_em`; ausente ou `null` em coletor antigo): o cartão do worker mostra o item ("rodando <id>" ou "<id> · há N min") e o desligamento ("desliga às HH:mm", ou "mantido até HH:mm" enquanto `manter_ate` está no futuro; fora do dia de hoje, "dd/MM HH:mm"). Sem `ocioso_min`, não há linha de desligamento; o Mac não tem o bloco. Tipo trocado num campo da `fila` vira ausente e não derruba o resto da leitura. No grande, a fila ocupa linhas de processo (processos + fila ≤ 3); no médio, o desligamento ocupa a linha do maior processo; o extragrande mantém 3 processos. Campos ausentes, como num worker com coletor antigo, aparecem como "—". |
| `<worker>.estado.json` | `conectando`, `conectado` ou `desconectado`, com o detalhe do SSH. |
| `<worker>/AAAA-MM-DD.jsonl` | Histórico de 30 s. Ainda não exibido; o caminho está em `WorkersTelemetry.historyURL`. |

## Comportamento

- Um cartão por worker, na ordem CPU · GPU · SSD · RAM, com temperaturas, watts da GPU, ventoinha, tempo ligado ("ligado 3d 4h"; no cartão do Mac, as sessões do Claude, porque as sessões do Claude Desktop nos workers ficam presas ao Mac), os três processos que mais usam CPU, só os que arredondam para 1% ou mais (só o maior no tamanho médio; % do `top`, em que 100% é um núcleo) e o maior processo na GPU, quando houver. A memória da GPU fica numa linha própria (VRAM), logo abaixo da GPU, nos tamanhos grande e extragrande; as taxas do SSD só aparecem quando cabem.
- **Fila no rodapé:** nos workers com bloco `fila`, o rodapé ganha a linha do item ("rodando <id>", "<id> · há N min" ou "<id> · <estado>") e a do desligamento ("desliga às HH:MM" ou "mantido até HH:MM"; "dd/MM HH:MM" fora do dia de hoje; nada sem `desliga_em`). No grande, processos e linhas da fila somam no máximo 3. No médio, o desligamento ocupa o lugar do maior processo. O extragrande mantém 3 processos. O Mac não tem esse bloco.
- A hora da leitura fica sempre visível, na última linha do cartão, para o apelido ocupar a largura do cabeçalho. Leitura recebida há mais de 60 s, worker desconectado ou conectando aparece esmaecido como desatualizado. A timeline já traz a entrada em que cada cartão expira, sem depender de recarga.
- Ausência não é zero: campo sem leitura aparece como "—"; worker sem NVIDIA mostra "sem GPU".
- Tamanhos: médio (2 cartões, sem load/watts/swap), grande (até 4), extragrande (até 4 lado a lado) e, a partir do macOS 27, extragrande vertical (4 cartões numa coluna, um sobre o outro, cada um largo e com cerca de 1/4 da altura; segue as regras do grande).
- **Atividade:** no cabeçalho, à direita do nome, um ícone roxo (`cube.fill`) com a GPU acima de 10% e um azul (`cpu.fill`) com a CPU a partir de 50%. Valem juntos e também no Mac. O cartão ganha uma borda fina na cor ativa (gradiente roxo e azul com os dois). Dado ausente não é atividade, e o cartão desatualizado não mostra nada. Os limiares ficam em `WorkerActivity`.
- **Grande com trabalho:** com item da fila ou GPU/CPU ativa, o grande mostra só o maior processo de CPU, além do processo da GPU. Sem trabalho, mostra até 3, dentro do teto de 3 linhas com a fila. O extragrande mantém 3. No extragrande, a linha do desligamento sobe para o cabeçalho, à direita do apelido e à esquerda dos ícones de atividade. O texto não trunca: se não couber, vira "até 03:00" ou "às 16:51", depois só o horário, e por fim o apelido trunca no meio. Nas próximas 24 h o horário não leva dd/MM; além disso, leva. Nos outros tamanhos, a linha continua no rodapé. O vertical segue o grande, porque cada cartão tem a altura dele.
- **Clique num cartão**: o NexoBar abre a janela daquela posição para escolher o PC (ou Automático) e o apelido. O apelido pertence ao PC e o acompanha se ele mudar de posição; escolher um PC que já está em outra posição troca as duas. No automático, o Mac vem primeiro e os workers depois, em ordem alfabética. As escolhas ficam em `~/Library/Application Support/NexoBar/widget-workers/posicoes.json`.
- **Acordar**: se o worker do cartão clicado estiver desconectado, a janela oferece acordá-lo; o botão fecha a janela e o NexoBar roda `~/.agents/scripts/worker/acordar.sh <worker>` (Wake-on-LAN pela LAN de casa e espera do SSH, até 4 min); enquanto o script roda, o cartão fica "acordando" em laranja (marca em `NexoBar/widget-workers/acordando.json`, que vence em 5 min); sem o script, a opção não aparece. Worker sem WoL recebe do script a explicação de como liga.
- O app NexoBar verifica a pasta a cada 5 s e pede ao WidgetKit a recarga quando um arquivo muda.

## Fila de trabalho

Segundo widget da mesma extensão (**Fila de trabalho**), só nos tamanhos grande e extragrande. Mostra a fila distribuída de GPU do `~/.agents` numa visualização:

- **Contadores:** rodando, na fila (livre e chegando), falhas e feitos. Dos feitos, só a contagem e quantos faltam buscar.
- **Máquinas, na ordem da fila:** vaga livre de GPU e CPU (barra cheia = livre; não é o uso do hardware) e RAM livre, com o que roda em cada uma e a idade da batida. Batida há 3 min ou mais fica laranja; na idade de órfão (`orfao_min`), vermelha. Sem batimento recente (`vivo_s`), a máquina aparece desligada.
- **Na fila**, na ordem de entrada, e **falhas**, da mais recente. O grande mostra até 7 linhas de itens e o extragrande até 8 por coluna; o resto vira "+N".
- **Extragrande vertical** (macOS 27 em diante): cabeçalho, os quatro contadores em 2×2 e uma coluna com as máquinas (até 4 itens rodando por máquina), a fila e as falhas (até 3). A fila ocupa as linhas que sobram, descontada a altura de cada máquina.
- **Clique:** lê a fila na hora (`nexobar://fila`).

O NexoBar roda `pwsh ~/.agents/scripts/worker/fila.ps1 painel` a cada minuto, só com o widget na mesa, e grava `~/Library/Application Support/NexoBar/widget-fila/fila.json`. A consulta vai com `WORKER_NAO_ACORDAR=1`: não acorda o mestre desligado. Falha mantém o último painel, esmaecido, com o motivo no cabeçalho; painel com mais de 3 min também esmaece. Sem o script, nada roda.

## Mac

O NexoBar grava `~/Library/Application Support/NexoBar/widget-workers/mac.json` a cada 5 s: CPU, memória, GPU e temperaturas do coletor do app; RAM instalada (`hw.memsize`), swap, SSD interno (tempo ativo e taxas do `IOBlockStorageDriver`, espaço livre do volume), ventoinhas (AppleSMC `F0Ac`…), três processos do `ps` (média recente do macOS, não a amostra instantânea do `top`) e sessões do Claude Code, incluindo as do app Claude. Da GPU, também: watts pelo IOReport (canal "GPU Energy", interface privada da Apple usada sem root, como no macmon; se mudar num macOS novo, os watts ficam ausentes) e memória em uso (IOAccelerator) sobre o limite que o macOS dá à GPU (`recommendedMaxWorkingSetSize`, cerca de 3/4 da RAM unificada, ex.: 37 de 48 GB). A temperatura do SSD não tem fonte sem root e fica fora.

## Sandbox e assinatura

A extensão é sandbox e lê as três pastas (coletor, `widget-workers` e `widget-fila`) pela exceção `com.apple.security.temporary-exception.files.home-relative-path.read-only` ([entitlements](../scripts/macos/WorkersWidget.entitlements)), sem app group nem cópia pelo app. Funciona com a assinatura local (ad-hoc) do preview; uma distribuição pela App Store exigiria outra estratégia.

O executável da extensão precisa entrar por `_NSExtensionMain` (`-e _NSExtensionMain` em `Package.swift`), como o Xcode faz. Com o `main` comum do Swift, o ExtensionFoundation para em `EXC_BREAKPOINT` antes de desenhar e o widget não aparece na galeria.

## Build

O [build.ps1](../scripts/build.ps1) monta a extensão em `Contents/PlugIns` e registra o esquema `nexobar://` no app, usado pelo clique (`nexobar://workers/posicao/<n>`).

Ao mudar o tipo de configuração ou a lista de widgets, suba `CFBundleVersion`: o chronod guarda o descritor por versão. A versão 12 trocou o "Editar widget" (App Intents) pelo clique; widgets adicionados antes precisam ser removidos e adicionados de novo. A 13 juntou o widget da fila. A 14 acrescentou o extragrande vertical ao widget dos workers. A 15 fez o mesmo no widget da fila.

## Diagnóstico

```bash
pluginkit -m -v -p com.apple.widgetkit-extension | grep nexobar
/usr/bin/log show --last 5m --style compact --predicate 'process == "NexoBarWorkersWidget"'
```

Ao reinstalar o app, registre-o de novo e encerre o processo do widget, que o macOS reabre com a versão nova:

```bash
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/NexoBar.app
pkill -x NexoBarWorkersWidget
```

Sem isso, o widget pode ficar parado com o erro "Bundle version did not match; LaunchServices DB may need to be rebuilt" no log do `chronod` (ocorreu em 08/11/2026 após duas reinstalações seguidas). Não reinicie o `chronod` nem a Central de Notificações para isso. Após reinstalar, a galeria pode manter a lista antiga até ser reaberta.
