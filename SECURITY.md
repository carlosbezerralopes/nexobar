# Segurança e privacidade

O NexoBar consulta somente as interfaces permitidas dos clientes já autenticados.
Não envie tokens, cookies, arquivos de autenticação, bancos dos clientes, transcrições,
saídas brutas de terminais ou diretórios de preferências ao relatar um problema.
Remova também nomes de usuário, caminhos pessoais e identificadores de contas das capturas.

Antes de publicar código, execute com Python 3.10 ou superior:

```text
python3 scripts/audit-publication.py --root . --mode tree --output /caminho/fora-do-repositorio/publication-audit.json
```

No Windows, use `python` se esse for o nome do Python instalado. `--mode staged`
verifica os bytes do índice Git antes do commit; `--mode tracked` verifica os arquivos
versionados no disco. `--mode manifest --manifest <arquivo.json>` recebe uma lista JSON
de caminhos relativos exatos. O relatório nunca inclui trechos do conteúdo detectado.
Código de saída: 0 sem bloqueios, 1 com achados que exigem revisão, 2 por erro de entrada
ou leitura. Avisos devem ser revisados, mesmo quando o código de saída for 0.

O scanner não acessa diretórios externos, credenciais reais, rede ou clientes de IA.
Em modo árvore, exclui apenas diretórios de build/cache declarados no próprio script;
arquivos sensíveis ignorados pelo Git continuam sendo detectados nesse modo.
Imagens e outros binários constam do inventário e precisam de revisão visual/manual.
A análise estática por padrões não garante ausência absoluta de dados sensíveis e
não substitui a revisão do conteúdo que será publicado. Ela não verifica o histórico Git.
Pacotes de distribuição precisam de auditoria separada de seu conteúdo.

Relate vulnerabilidades de forma privada pelo recurso de comunicação privada de
segurança do repositório, quando estiver habilitado. Não publique detalhes exploráveis
ou dados de contas em uma issue pública.
