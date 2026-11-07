# Windows 0.6 — apresentação e limites

Resultados posteriores ao empacotamento: [evidências 0.6](VALIDATION-0.6.md).

A 0.6 aproxima a apresentação Windows dos recursos solicitados do macOS 0.3.1. Um único coletor continua alimentando faixa, bandeja e WidBar. A tabela descreve o contrato implementado; não comprova instalação ou validação visual da release.

| Recurso | Comportamento Windows 0.6 |
|---|---|
| Renovação | Mostrar tempo até a renovação é opcional e independente dos nomes; formato compacto/detalhado continua separado. Sem reset informado, não inventa contador. |
| Cotas | Duas linhas quando existem duas janelas reais e o modo está selecionado. Codex somente semanal ocupa uma linha, sem sessão fictícia ou linha vazia. Janelas por modelo permanecem no detalhe. |
| Temperatura | Opção filha de CPU/GPU, exibida somente quando o backend fornece leitura. Ausente não vira zero. Cada GPU mantém sua identidade. |
| Organização WidBar | De 1 a 8 indicadores no total por página, com linha e ordem por ID. O preset 2+3 não limita as distribuições; 1+4, 3+2 e 0+5 são possíveis. Excedentes usam páginas. |
| Espaço entre linhas | De 0 a 12 px lógicos, padrão 4; aplicado à apresentação e às prévias. É separado do espaço interno das cotas. |
| Prévias | Valores demonstrativos respeitam memória, temperatura, cotas, reset e organização. Não consultam clientes de IA. |
| Claude | Descobre o executável nativo, inclusive do pacote npm oficial; nunca executa shim `.cmd`, autentica ou concede confiança. Consulta temporária `/usage`. |
| Compatibilidade | Preferências 0.5 são preservadas e novos campos têm defaults. Setup 0.6 preserva a pasta anterior, recusa downgrade de versão superior e não substitui destino desconhecido. |

O host controla o espaço disponível na taskbar. Gap 12, cotas empilhadas e reset visível não garantem acomodação em toda altura, largura ou DPI. Geometria dos controles próprios, visual da taskbar, rotação e cliques exigem verificações nativas separadas.

Em 23/10/2026, as fixtures da atualização de contrato passaram em 261 checks do núcleo e 79 de ponte/configuração; a correção Claude passou em 83 checks sintéticos e o Setup em 85 checks de transação/versão com serviços Windows simulados. As evidências históricas de build, assinatura e host 0.5 estão em [VALIDATION.md](VALIDATION.md). Elas não validam UI, pacote ou instalação 0.6; os resultados da validação final da release são registrados separadamente.

O diagnóstico físico contemporâneo, com o aplicativo 0.5 e o mesmo coletor, confirmou CPU disponível, mas não temperatura CPU, carga GPU ou temperatura GPU. A opção térmica e suas fixtures não criam um sensor ausente.

Continuam diferenças em relação ao macOS: estilos e nomes por indicador, cores por percentual, gráficos térmicos/detalhes no WidBar e fontes de alguns provedores. Média/contagem de sensores e gestão de monitores também diferem. Não há declaração de paridade total nem ampliação de fontes de autenticação. Veja [AI-PARITY.md](../../docs/AI-PARITY.md), [sessão existente](../../docs/SESSION-ONLY.md) e [Claude ConPTY](CLAUDE-CONPTY.md).
