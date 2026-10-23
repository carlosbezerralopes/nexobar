# Avisos de terceiros

O NexoBar credita o **[Codenotch original, de Vinz](https://github.com/vinzdg/codenotch)**, e o **[fork usado como referência](https://github.com/carlosbezerralopes/codenotch)** como inspiração e ponto de partida. O registro abaixo preserva a proveniência das adaptações e a licença MIT original. A implementação própria da interface não elimina a atribuição dos parsers, vetores e demais trechos reutilizados.

Este inventário descreve a origem do código, incluindo componentes históricos ainda presentes no código-fonte e nas fixtures. Não é uma lista de permissões do runtime: cache Claude Desktop/status line, descoberta de credenciais e bridge Antigravity/CSRF mencionados no registro não são fontes autorizadas de cotas no modo atual. As consultas habilitadas seguem a [política de sessão existente](docs/SESSION-ONLY.md), sem extração de credenciais, login ou renovação OAuth pelo NexoBar.

Outros componentes têm avisos próprios:

- [Stats / sensores macOS](docs/HARDWARE-NOTICES.md), MIT, com texto completo.
- [Bibliotecas Windows](windows/docs/THIRD-PARTY-NOTICES.md), incluindo fontes correspondentes MPL-2.0, Apache-2.0 e avisos Microsoft/Mono.
- [WidBar.SDK](windows/widbar/LICENSE-WidBar-SDK.txt), MIT; WindowsAppSDK e seus componentes mantêm os avisos dos pacotes distribuídos.
- [Mapa de atribuição e obrigações de distribuição](docs/ATTRIBUTION.md).

## Registro detalhado Codenotch

`windows/widbar/ProviderIconPaths.cs` ports the same nine provider outlines from the local `Sources/NexoBar/ProviderOutlines.swift`, following the mapping in `ProviderMarks.swift` (Codex uses OpenAI). `windows/scripts/generate-provider-icons.py` reproduces these point arrays without executing Swift. The Windows renderer preserves every loop with even-odd fill and fits the full bounding box. These vectors retain the Codenotch MIT copyright and license below. Provider trademarks belong to their respective owners; their use identifies integrations and does not imply endorsement.

AIProviders.swift adapts usage parsing and Chromium Claude cache layout from [Codenotch](https://github.com/carlosbezerralopes/codenotch), commit `1a33306a1fbd32d0dc185c1ca2507072365bd417`, originally [vinzdg/codenotch](https://github.com/vinzdg/codenotch). ProviderOutlines.swift also adapts the Claude, OpenAI/Codex and Kiro vector outlines from Sources/Providers/GlyphOutline.swift in that same revision (lines 17–147 and 450–565). The provider outline reuse now includes Cursor, Grok, GitHub Copilot, OpenCode, Antigravity and GLM from the same source GlyphOutline.swift. The new application UI and runtime are independent.

AIProviderParsers.swift adapts the following Swift files from that same Codenotch revision: CursorUsage.swift, GrokUsage.swift, OpenCodeUsage.swift, GLMUsage.swift, AntigravityQuotaParser.swift, KiroLimits.swift, GLMCredentials.swift, OpenCodeCredentials.swift, GrokCredentials.swift, and the GitHubCopilotUsage portion of GitHubCopilotProvider.swift. AIProviderCompatibility.swift provides the narrow model/localization/SQLite compatibility boundary. AIProviderIntegrations.swift adapts transport and credential-discovery behavior while omitting OAuth renewal and interactive keychain prompts. AIActivity.swift adapts passive status semantics from ClaudeSessionRecord.swift, CodexActivityMonitor.swift, CursorActivityMonitor.swift, GrokActivityMonitor.swift and AntigravityActivityMonitor.swift. AIQuotaResetWatcher.swift adapts windows/codenotch/src/reset_watch.rs (Windows per-window thresholds and cooldown). The Claude forward-compatible limits[]/legacy merge follows windows/codenotch/src/usage.rs in the same revision. AIAntigravityBridge.swift adapts the local service/CSRF/forceRefresh behavior of Sources/Providers/AntigravityBridge.swift and the loopback-only TLS policy of LocalhostTrust.swift. Its native process/socket ownership discovery is independent and it omits upstream server startup. Local modifications bound reads, validate numbers, separate exact quantities from percentages, preserve read-only WAL access, and retain the new independent UI.

The optional zstd reader loads an existing Homebrew libzstd installation. No zstd binary or source is distributed in this preview.

MIT License

Copyright (c) 2026 Vinz

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
