# IA — sessão existente e paridade

O projeto prioriza **não acessar credenciais, não iniciar login e não procurar outra autenticação se a consulta falhar**, mesmo quando isso limita a paridade com a referência. O contrato atual está em [SESSION-ONLY.md](SESSION-ONLY.md).

| Provedor | Fonte atual | Diferença intencional do fork |
|---|---|---|
| Claude Mac/Windows0.3.1 | /usage nativo em PTY/ConPTY temporário, pasta configurada já confiável | Sem cache Desktop, Keychain, endpoint próprio ou inferência. Nunca /usage via -p. Pedido de confiança/login aborta. Windows requer claude.exe nativo; consulta física pendente. |
| Codex | CLI `account/rateLimits/read` | Sem leitura direta de auth.json ou fallback de snapshot em falhas. |
| Kiro | CLI `/usage` não interativa | Sem token SQLite, GetUsageLimits ou recuperação por outra credencial. Timeout fica indisponível. |
| Copilot | `gh api` pela sessão da CLI | Sem exportar token nem ler hosts.yml. |
| Antigravity | CLI `/usage` não interativa | Sem bridge do IDE/captura de CSRF ou outra identidade. |
| Cursor, Grok, OpenCode Go, GLM | Indisponíveis neste modo | Leitores de tokens/configurações removidos. Não se presume que estejam deslogados. |

Os parsers puros preservam percentuais utilizados, janelas, renovação e quantidades explicitamente informadas. Não se transforma percentual arredondado em créditos/tokens. Falha não restaura a cota anterior; o arquivo de estado guarda apenas contagem de falhas e pausa de consultas.

## Janelas realmente disponíveis

A barra apresenta somente as janelas de conta informadas pelo cliente. Janelas por modelo não assumem o lugar de sessão/semanal. Uma janela semanal única ocupa uma única linha, mesmo com preferência de duas linhas. Se o plano passar a informar uma sessão e uma semanal, ambas reaparecem no layout escolhido. Não é uma regra fixa sobre assinatura ou duração: a decisão acompanha cada resposta.

Se nenhum dado for obtido, aparece apenas indisponibilidade, sem duas linhas artificiais. Tempo restante usa o reset informado e não confirma renovação sozinho. Cliques continuam abrindo apenas os detalhes do provedor escolhido.

## Recursos mantidos e limites

Atividade passiva, privacidade dos detalhes e observação de renovação continuam usando dados locais/leituras válidas, sem login. Copilot/OpenCode/GLM não ganham estado de trabalho presumido quando a fonte não publica esse dado. O comportamento não afirma observar todas as contas e sessões.

Histórico de consumo e orçamento por dias úteis continuam sem coleta ativada. A cadência de consulta e perfis múltiplos não reproduzem integralmente o fork. Essas diferenças estão subordinadas à política de não acessar credenciais solicitada pelo usuário, e não serão contornadas para manter números na barra.

Referência de parsers/comportamento: carlosbezerralopes/codenotch, revisão `1a33306a1fbd32d0dc185c1ca2507072365bd417`. Atribuições permanecem em THIRD_PARTY_NOTICES.md. A validação atual distingue testes de fixtures de consultas live a contas.
