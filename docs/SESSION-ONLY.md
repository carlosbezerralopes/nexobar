# Consultas pela sessão existente

Sem leitura direta de Keychain/tokens, login, navegador de autenticação ou inferência para obter cotas. Cada CLI continua responsável por sua sessão. Fonte ausente/falha retorna indisponível, sem outra credencial ou números antigos.

| Provedor | macOS | Windows |
|---|---|---|
| Claude | /usage nativo em PTY temporário, macOS0.3.1 | /usage nativo em ConPTY temporário, Windows0.3.1; teste físico pendente |
| Codex | codex app-server → account/rateLimits/read | Mesmo protocolo pela CLI existente |
| Kiro | kiro-cli chat --no-interactive /usage | Mesmo comando, sujeito à disponibilidade da CLI |
| Copilot | gh api --hostname github.com copilot_internal/user | Mesmo comando pela sessão gh |
| Antigravity | agy --print /usage | Indisponível até validar interface segura nesta plataforma |
| Cursor, Grok, OpenCode Go, GLM | Indisponíveis neste modo | Indisponíveis neste modo |

## Claude Code

O Mac0.3.1 usa [consulta temporária nativa /usage](CLAUDE-USAGE-MAC.md), com pasta escolhida em Personalizar barra. O terminal auxiliar é invisível, tem timeout45s, saída limitada e grupo próprio encerrado. Safe mode desabilita customizações; ferramentas ficam vazias. Nunca aceita trust/setup/login nem usa /usage em modo -p. O próprio cliente usa sua sessão interna; o app não extrai autenticação. Cadência5min ou manual, sem fallback para statusline/cache quando falha.

A verificação com CLI2.1.309 mostrou que a flag composta de tráfego podia impedir o /usage. Sem essa flag, em uma pasta já confiável, o cliente entregou as janelas de cotas e o binárioNexoBar confirmou zero processos próprios após fechar. Não generalizar esse comportamento para todas as versões ou sessões; dados da conta não são publicados.

O Windows0.3.1 usa `claude.exe` nativo em ConPTY, com pasta obrigatória escolhida em Personalizar barra, timeout45s e Job de processos próprio. Não executa shim `.cmd` do Claude, não aceita confiança/login e não usa a ponte como fallback. Cadência5min ou manual. Codex tem pasta opcional. A [ponte da status line](CLAUDE-STATUSLINE.md) é referência para versões anteriores; nenhum settings do Claude é alterado pela atualização. Execução física do transporte Windows ainda precisa ser validada.

## Processos e verificações

Consultas externas têm entrada/protocolo delimitados, saída limitada, timeout e encerramento de processos próprios. O ambiente desabilita prompts/navegador onde o cliente permite. A aplicação não implementa renovação de autenticação. Falhas não restauram cotas anteriores.

Testes Swift de sessão/ponte, testes Python do produtor/instalador e fixtures do núcleo Windows validam partes do contrato sem contas reais. `--diagnose-claude` aciona uma consulta real pela sessão existente e retorna diagnóstico sanitizado; não é uma inspeção passiva de cache. O harness sintético Windows é separado e não chama Claude. Leitores/parser de cache legado permanecem para regressões históricas, sem serem chamados pelo runtime Claude.
