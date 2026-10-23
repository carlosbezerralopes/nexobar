<div align="center">

# NexoBar

**Sua máquina e suas cotas de IA, à vista.**

Indicadores de hardware e limites de uso em uma barra compacta, com interface em português e consultas pelas sessões dos clientes que você já utiliza.

[macOS 0.3.1 · preview](#plataformas) · [Windows 0.6.0 · preview](#plataformas) · [Compilar](docs/BUILDING.md) · [Licença MIT](LICENSE)

</div>

> **Crédito ao projeto original:** o NexoBar nasceu da inspiração e do ponto de partida oferecidos pelo [Codenotch, de Vinz](https://github.com/vinzdg/codenotch), usando como referência o [fork de Carlos Bezerra Lopes](https://github.com/carlosbezerralopes/codenotch). A interface e os coletores do NexoBar têm implementação própria; parsers, vetores de provedores e outras adaptações reutilizadas estão identificados nos [créditos e licenças](docs/ATTRIBUTION.md).

## O que você acompanha

- **CPU, memória, GPU e temperaturas**, quando a plataforma e os sensores fornecem a leitura.
- **Cotas de IA e horários de renovação** informados pelos clientes compatíveis. Uma janela semanal aparece sozinha quando não existe uma janela de sessão.
- **Detalhes por indicador**, com gráficos de hardware dos últimos cinco minutos mantidos somente em memória.
- **Uma barra do seu jeito:** ordem, nomes, visibilidade, estilos, memória em GiB ou percentual e cotas em uma ou duas linhas.

Uma leitura ausente aparece como indisponível. O NexoBar não transforma ausência em zero nem usa consumo de CPU/GPU para inferir a atividade de uma tarefa de IA. Um contador que chegou a zero também não confirma que a cota foi renovada.

## Plataformas

| Plataforma | Apresentação | Estado deste preview |
|---|---|---|
| macOS 14+ · Apple Silicon | Barra de menus nativa em AppKit/SwiftUI | 0.3.1; bundle arm64, testes automatizados e verificações físicas em Apple M5 Pro. Outros chips precisam de validação. |
| macOS · Intel | Mesma base Swift | Exige compilação própria; execução física ainda não verificada. |
| Windows 11 · x64 | Faixa translúcida, ícones de bandeja e companion WidBar | 0.6.0; cotas, renovação, temperatura opcional e organização descritas na [matriz 0.6](windows/docs/PARITY-0.6.md). Build, teste nativo e validação visual têm evidências separadas. |
| Linux | — | Não implementado. |

Na validação anterior, o companion 0.5 foi compilado, assinado com certificado de teste, verificado e instalado. O host WidBar 1.2.8 reabriu “Em execução”; sua configuração mostrou cinco ícones em 2+3 e permitiu exercitar largura própria, Cancelar e Salvar com largura herdada. Essa evidência não valida a UI ou a instalação 0.6. Veja a [matriz de evidências Windows](windows/docs/VALIDATION.md) e os [recursos e limites da 0.6](windows/docs/PARITY-0.6.md).

### Três modos independentes no Windows

| Modo | Como funciona | O que exige |
|---|---|---|
| **Faixa** | Barra translúcida junto à taskbar; reserva de área opcional, desligada por padrão. | Aplicativo portátil. |
| **Bandeja** | Um ícone dinâmico por indicador, com tooltip e clique para o detalhe correspondente. | Aplicativo portátil; o Windows controla ordem e overflow. |
| **WidBar** | Widget com 1–8 indicadores por página, posições em duas linhas, largura e rotação configuráveis. | Host WidBar e companion compatível instalados separadamente. |

Os interruptores podem ser combinados. **Um único coletor alimenta todos os modos**: habilitar outra apresentação não multiplica as consultas de IA. GPUs são enumeradas individualmente no Windows, preservando os identificadores fornecidos pelo backend. Ligar WidBar nas opções não instala o host nem o companion.

Na 0.6 Windows, mostrar o tempo até a renovação é opcional e independente dos nomes. Duas cotas ocupam duas linhas quando há duas janelas reais; Codex somente semanal ocupa uma. Temperatura de CPU/GPU aparece quando habilitada e fornecida pelo hardware. O WidBar permite espaço de 0–12 px entre linhas, com padrão 4, e 1–8 indicadores no total por página: 2+3 é um preset, não um limite por linha.

## Começar

Use um pacote preview somente quando ele estiver disponível junto à versão correspondente, ou [compile a partir do código-fonte](docs/BUILDING.md). A existência do código-fonte não significa que um binário já tenha sido publicado.

| Pacote | Uso |
|---|---|
| `NexoBar-macOS-preview.zip` | Extraia e abra `NexoBar.app`. O pacote atual é arm64. A assinatura é local, sem notarização Apple. |
| `NexoBar-Windows-x64-0.6.0-preview.zip` | Extraia para uma pasta local e abra `NexoBar.exe`. O runtime .NET é incluído. O kit-fonte do WidBar é separado do executável portátil. |
| `NexoBar-Setup-x64.exe` | Instalador de arquivo único com runtime incluído. Abra, escolha faixa/bandeja/WidBar, revise o destino e confirme. Autostart é opcional. A validação da instalação 0.6 é separada do teste anterior 0.5. |

Clique no indicador para abrir seu detalhe e use o menu de contexto para personalizar. No macOS, clique com o botão direito na barra. No Windows, o ícone NexoBar na bandeja permite recuperar as opções mesmo com os modos desligados; ele pode estar em “Mostrar ícones ocultos”. Fechar a configuração mantém o coletor; **Sair** encerra o aplicativo.

O portátil não configura inicialização automática nem instala hosts ou certificados. O [instalador Windows](windows/setup/README.md) permite autostart por escolha explícita e orienta a instalação do WidBar/companion, incluindo consentimento e UAC quando necessário para confiar no certificado público. O candidato preview usa assinatura local de teste, sem reputação pública comprovada. A instalação 0.5 e suas verificações estão no [registro nativo](windows/docs/INSTALLATION-VALIDATION.md); isso não comprova UI ou instalação 0.6. Veja também [compilação e diagnóstico](docs/BUILDING.md), [Windows](windows/README.md) e [companion WidBar](windows/widbar/README.md).

## Integrações de IA

Os indicadores de IA são opcionais. Configure os clientes necessários fora do NexoBar e habilite somente os provedores que deseja acompanhar.

| Provedor | Fonte disponível no código | Disponibilidade |
|---|---|---|
| Claude | Consulta temporária `/usage` do Claude Code, em PTY no Mac e ConPTY no Windows. | A descoberta Windows inclui o executável nativo do pacote npm oficial; consulta exige cliente e sessão existentes. Veja o [diagnóstico e seus limites](windows/docs/CLAUDE-CONPTY.md). |
| Codex | RPC de limites pelo `codex app-server`. | Consulta nativa Windows retornou uma janela; depende da CLI e sessão existentes. |
| Kiro | Comando `/usage` pela CLI não interativa. | Consulta nativa Windows retornou uma janela; depende de versão/formato compatíveis. |
| GitHub Copilot | Consulta pela sessão existente de `gh api`. | Cliente ausente no ambiente Windows validado; consulta pendente. |
| Antigravity | `/usage` pela CLI no macOS. | Sem interface validada no Windows neste ciclo. |
| Cursor, Grok, OpenCode Go e GLM | Sem interface de sessão permitida validada neste modo. | Cotas indisponíveis. |

Implementação não garante que uma conta ou versão específica do cliente exponha cotas. Os limites conhecidos estão na [política de sessão existente](docs/SESSION-ONLY.md) e na [matriz de paridade](docs/AI-PARITY.md).

### Configurar Claude e Codex

Em **Personalizar barra → Pastas das CLIs**, selecione para Claude uma pasta **já confiável no Claude Code**. A pasta do Codex é opcional. Escolher uma pasta no NexoBar não concede confiança ao cliente.

No Windows, Claude exige o executável nativo **`claude.exe`** já autenticado, inclusive o instalado pelo pacote npm oficial; o shim npm `.cmd` não é executado. A consulta envia somente `/usage`, espera a leitura e encerra o terminal auxiliar. Ela acontece a cada cinco minutos ou por **Atualizar Claude**. Pedidos de login, trust ou setup interrompem a consulta sem resposta automática. A correção de descoberta da 0.6 tem fixtures sintéticas; seu diagnóstico real com PATH normal e a validação da release são etapas separadas.

## Privacidade e controle

**O NexoBar não pede senhas, não extrai tokens e não inicia login.** A autenticação e as requisições aos provedores pertencem ao próprio cliente já autenticado. O aplicativo não lê Keychain/Credential Manager para obter credenciais nem envia prompts para gerar respostas de modelos.

As consultas podem fazer o cliente acessar o serviço do provedor; portanto, cotas de IA não são uma função totalmente offline. Falha, timeout ou sessão expirada substituem a leitura por indisponível, sem recuperar cotas antigas de um fallback de autenticação.

Preferências são gravadas localmente. Gráficos de hardware ficam em RAM; cotas e transcrições de terminal não são persistidas. O estado de controle pode guardar backoff de consultas. Metadados passivos de atividade, onde implementados, seguem a [política documentada](docs/SESSION-ONLY.md). A ponte WidBar transmite somente opções visuais e leituras ao companion do mesmo usuário, sem caminhos dos clientes, credenciais ou histórico.

## Desenvolvimento e limites

- [Compilar e diagnosticar](docs/BUILDING.md): requisitos, comandos, preferências e semântica das métricas.
- [Implementação Windows](windows/README.md) e [WidBar](windows/widbar/README.md): pacotes, modos e testes nativos pendentes.
- [Sensores macOS](docs/HARDWARE-NOTICES.md): fontes, APIs e compatibilidade por geração.
- [Claude no macOS](docs/CLAUDE-USAGE-MAC.md) e [ConPTY no Windows](windows/docs/CLAUDE-CONPTY.md): contrato de consulta temporária.

Este é um **preview em desenvolvimento**. As leituras dependem das APIs do sistema, dos drivers e dos formatos dos clientes. AppleSMC e contadores de GPU no Mac não têm garantia pública de estabilidade; o funcionamento local não comprova compatibilidade com sandbox ou lojas. O NexoBar não altera o comportamento de ocultação da barra do macOS.

## Créditos e licença

O código próprio do NexoBar é distribuído sob a [licença MIT](LICENSE). O [Codenotch original](https://github.com/vinzdg/codenotch), de **Vinz**, e o [fork usado como referência](https://github.com/carlosbezerralopes/codenotch) merecem crédito pelo ponto de partida. A revisão de referência é `1a33306a1fbd32d0dc185c1ca2507072365bd417`.

A MIT permite uso, modificação, publicação, redistribuição e uso comercial, preservados o copyright e o aviso de licença. Os direitos de cada componente continuam regidos por sua licença: adaptações do Codenotch e do Stats preservam MIT; bibliotecas do Windows incluem MPL-2.0, Apache-2.0 e avisos Microsoft/Mono. Consulte os [créditos detalhados](docs/ATTRIBUTION.md), os [avisos Codenotch](THIRD_PARTY_NOTICES.md) e os [avisos Windows](windows/docs/THIRD-PARTY-NOTICES.md).

Nomes e marcas de provedores pertencem aos respectivos titulares. A identificação de integrações não implica afiliação ou endosso.
