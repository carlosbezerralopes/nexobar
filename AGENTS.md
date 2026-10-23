# Contribuir com o NexoBar

Leia [README.md](README.md), [compilação](docs/BUILDING.md) e a documentação da plataforma alterada. Interface em português. Preserve os créditos, copyrights e licenças de terceiros.

- Um único coletor alimenta faixa, bandeja e WidBar; apresentações adicionais não multiplicam consultas de IA.
- Consulte somente interfaces dos clientes já autenticados. Nunca extraia credenciais, inicie login, aceite confiança de pasta ou envie prompts ao modelo para obter cotas. O `/usage` do Claude usa terminal temporário, nunca `-p /usage`; falha retorna indisponível, sem fallback de autenticação.
- Dados ausentes não são zero. Mostre somente janelas reais; use o reset informado, sem inventar durações. GPUs Windows têm identidades individuais. Desligar apresentações deve preservar o acesso às configurações.
- Testes usam fixtures, processos sintéticos e diretórios isolados. Consultas reais, instalação de hosts/certificados, publicação e mudanças persistentes na máquina exigem escopo explícito da tarefa.
- Não versionar credenciais, sessões, dados de contas, relatórios locais, caches ou pacotes gerados. Antes de publicar, execute `scripts/audit-publication.py` sobre o índice Git e revise os avisos, conforme [SECURITY.md](SECURITY.md).
- Distinga código implementado, compilação, teste nativo e validação visual. Compilação cruzada não comprova sensores, ConPTY, AppBar ou host WidBar no Windows.
- Preserve alterações existentes. Registre plano, evidências e manifesto de arquivos em um scratchpad fora do checkout, sob o temporário do sistema em `NexoBar/<contexto>`.
