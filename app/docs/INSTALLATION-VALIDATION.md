# Instalação nativa — Windows 0.5.0

Em 23/10/2026, o instalador final foi executado no Windows 11 x64 com preferências existentes e WidBar 1.2.8.0. A interface concluiu a instalação por usuário e reutilizou o companion 0.5.0.0 compatível, sem reinstalação ou downgrade.

- Os 526 arquivos instalados corresponderam aos hashes do manifesto incorporado.
- As preferências antes/depois permaneceram semanticamente idênticas: cinco indicadores, layout personalizado 2+3, largura 402 px, somente WidBar habilitado.
- O atalho do menu Iniciar foi criado. Nenhum atalho Startup foi criado; inicialização automática permaneceu desligada.
- O executável da pasta definitiva iniciou e mostrou cliente do widget ativo no canal de dados.
- A revisão da instalação com o aplicativo aberto havia sido bloqueada, sem encerramento automático do processo.

O EXE final tem assinatura local de teste verificada por SignTool. SHA256: `cd8f6498d8173b0b5e520ce22e099e8a5670ac663541489fa655e956b75ae0b9`. O certificado já era confiável nesta máquina; este teste não exerceu importação/UAC nem instalação do host pela Store em uma máquina limpa.

Os testes automatizados passaram em 226 checks de núcleo, 60 de ponte/configuração/vetores, 63 de ConPTY sintético e 81 de instalação. Pacotes MSIX adulterado e sem assinatura foram recusados. Cenários de Store, confiança recusada, nova instalação, atualização e rollback usam serviços simulados no harness e não equivalem a teste físico desses fluxos.

No host, a configuração da instância mostrou os cinco ícones em duas linhas e prévia demonstrativa. Alterar largura para 305 px e cancelar restaurou a herança de 402 px; a opção herdada foi salva. A captura da barra de tarefas real, rotação, cliques em detalhes, múltiplos monitores e fullscreen em aplicativos reais continuam fora desta comprovação.

Os documentos incorporados ao instalador refletem o build anterior à instalação física; este registro posterior complementa aquela evidência sem modificar o pacote assinado.
