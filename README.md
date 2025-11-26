# Assistente SISCan RPA
**Assistente SISCan RPA — Instalador remoto**

Este repositório contém um instalador remoto modular (PowerShell + Bash) para instalar, atualizar e gerenciar o serviço "Assistente SISCan RPA".

**Resumo**
- **Objetivo:** fornecer um instalador extremamente simples para usuários finais (não técnicos) que:
	- solicita token para acesso à imagem privada;
	- solicita credenciais SISCan;
	- valida dependências (Docker, Docker Compose);
	- baixa/atualiza imagem privada e configura volumes;
	- cria/reinicia serviços automaticamente;
	- é modular e seguro (tokens não expostos em logs).

**Comandos finais (para o usuário)**
- **Windows (PowerShell):**

		irm "https://raw.githubusercontent.com/Prisma-Consultoria/assistente-siscan-rpa/main/install.ps1" | iex

	Se estiver testando localmente a partir do repositório baixado, use os comandos abaixo (recomendado para inspecionar o script antes de executar):

	- Desbloquear o arquivo baixado (Windows pode bloquear scripts baixados):

		```powershell
		Unblock-File .\install.ps1
		```

	- Executar o instalador localmente com policy temporariamente bypassada:

		```powershell
		powershell -ExecutionPolicy Bypass -File .\install.ps1
		```

- **Linux / macOS (Bash):**

	curl -sSL https://raw.githubusercontent.com/Prisma-Consultoria/assistente-siscan-rpa/main/install.sh | bash

**Estrutura mínima do repositório**
- `install.ps1` — bootstrap PowerShell que baixa módulos e executa o fluxo.
- `install.sh` — bootstrap Bash equivalente.
- `scripts/version.txt` — versão/fallback (atualmente: `main`).
- `scripts/modules/docker.ps1` / `docker.sh` — valida Docker/Compose e faz login no registry.
- `scripts/modules/siscan.ps1` / `siscan.sh` — puxa imagem, cria `docker-compose.yml`, configura volumes e sobe serviços.

**Como funciona (arquitetura)**
- Bootstrap leve: o `install.*` solicita entradas seguras ao usuário e faz o download dinâmico dos módulos em `scripts/modules/`.
- Cache local: módulos baixados são salvos em um diretório de cache (Windows: `%ProgramData%/AssistenteSISCan/installer-cache`; Linux/macOS: `$XDG_DATA_HOME` ou `~/.local/share/assistente-scan/installer-cache`). Se o download falhar, o instalador usa o módulo em cache quando disponível.
- Modularidade: cada módulo implementa uma função/entrypoint simples (`Module-Main` no PowerShell e `module_main` no Bash). Atualizar um módulo no repositório atualiza o comportamento sem alterar o comando principal.

**Segurança**
- Tokens e senhas são lidos via entrada oculta (`Read-Host -AsSecureString` no PowerShell, `read -s` no Bash) e nunca são gravados em logs explícitos.
- O instalador tenta usar `docker login --password-stdin` para evitar expor credenciais em argumentos de processo.
- Recomendação: use accounts com escopo mínimo (read-only) para pull de imagens privadas.
- (Melhoria sugerida) Assinar/sha256 dos módulos para garantir integridade — posso adicionar isso se desejar.

**Configuração padrão gerada**
- `docker-compose.yml` será criado em `%ProgramData%/AssistenteSISCan/` (Windows) ou `$XDG_DATA_HOME/assistente-siscan/` (Linux/macOS) com:
	- serviço `assistente-siscan-rpa` usando a imagem privada `REGISTRY/prisma-consultoria/assistente-siscan-rpa:latest`;
	- variáveis de ambiente `SISCAN_USER` e `SISCAN_PASS` preenchidas com as credenciais digitadas (passadas em environment do container);
	- volume de persistência para `/app/data`.

**Troubleshooting básico**
- Se `docker` não for encontrado, instale Docker (https://docs.docker.com/get-docker/).
- Se `docker compose` não for encontrado, instale a versão compatível do Compose (v2 integrado ou `docker-compose`).
- Erro no `docker login`: verifique se o `Registry URL` está correto e se o token tem permissão de pull. Tente fornecer `Registry usuário` quando necessário.
- Se o download do módulo falhar e não houver cache, execute manualmente:

	- Baixe o módulo em outro host com conectividade e transfira para a máquina destino, colocando-o no diretório de cache do instalador.

**Desenvolvimento e manutenção**
- Para atualizar a lógica de instalação, edite os módulos em `scripts/modules/` e mantenha o `install.*` como bootstrap mínimo.
- Para adicionar verificações adicionais (e.g., saúde do serviço), crie um novo módulo e invoque-o a partir do bootstrap.

**Testes rápidos (local)**
- PowerShell (Windows):

	- Execute em modo interativo: `.	ests\run-local.ps1` (se fornecer um script de teste) — caso não exista, use um ambiente Docker local com uma imagem pública similar para validar o fluxo.

- Bash (Linux/macOS):

	- Simule variáveis e invoque o módulo: `REGISTRY=ghcr.io TOKEN=xxx SISCAN_USER=foo SISCAN_PASS=bar bash -c '. scripts/modules/docker.sh && module_main'`

**Próximos passos recomendados**
- Adicionar verificação de integridade (SHA256) e/ou assinatura GPG dos módulos baixados.
- Implementar suporte explícito a registries (GitHub Container Registry, ACR, ECR) com fluxos de login dedicados.
- Adicionar testes automatizados (CI) para validar que o instalador e módulos continuam funcionando.

Se quiser, eu posso:
- adicionar verificação de assinatura/SHA para os módulos;
- melhorar o suporte a registries específicos (ex.: GHCR, ACR);
- criar um pequeno script de testes locais/CI.

---
Arquivo principal de bootstrap:
- PowerShell: `install.ps1`
- Bash: `install.sh`

Obrigado — informe qual melhoria prefere que eu implemente em seguida.

O **Assistente SISCan RPA** é um utilitário simples e intuitivo criado para ajudar usuários – mesmo os que não entendem nada de Docker ou configurações técnicas – a instalar, atualizar e gerenciar o serviço **SISCan-RPA**.

Ele funciona como um *facilitador*: você informa alguns dados básicos e o assistente cuida do resto.

---

## ✨ Recursos Principais

- 🔄 **Criar ou atualizar a imagem do serviço**
- ♻️ **Resetar o serviço por completo**
- 🔐 **Informar ou recriar credenciais do SISCan**
- 🔑 **Adicionar o token/chave para baixar imagens privadas**
- 📂 **Configurar caminhos dos volumes utilizados pelo sistema**

Tudo isso de forma simples, guiada e com foco em pessoas leigas.

---

## 📦 Repositório da imagem utilizada

O serviço principal está em:

👉 **https://github.com/Prisma-Consultoria/siscan-rpa**

Este repositório atua apenas como **instalador, configurador e gerenciador** do SISCan-RPA.

