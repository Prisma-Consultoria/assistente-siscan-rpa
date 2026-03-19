# Checklists Operacionais — Assistente SISCAN RPA
<a name="checklists"></a>

Versão: 3.0
Data: 2026-03-18

---

## Verificações comuns — ambos os modos

Use este checklist independentemente do modo de deploy (HOST ou Servidor).

- [ ] Docker Engine instalado e rodando: `docker info` sem erros.
- [ ] Docker Compose v2: `docker compose version` retorna `v2.x.x`.
- [ ] `git` disponível: `git --version`.
- [ ] Repositório clonado: `git clone https://github.com/Prisma-Consultoria/assistente-siscan-rpa.git`.
- [ ] `.env` criado a partir do sample correspondente ao modo: `.env.host.sample` (HOST) ou `.env.server.sample` (Servidor).
- [ ] Variáveis obrigatórias preenchidas:
  - [ ] `DATABASE_PASSWORD` (não usar o padrão `siscan_rpa`)
  - [ ] `SECRET_KEY` (pode estar vazio — o assistente gera; mas em servidor definir manualmente)
  - [ ] `HOST_LOG_DIR`
  - [ ] `HOST_SISCAN_REPORTS_INPUT_DIR`
  - [ ] `HOST_REPORTS_OUTPUT_CONSOLIDATED_DIR`
  - [ ] `HOST_REPORTS_OUTPUT_CONSOLIDATED_PDFS_DIR`
  - [ ] `HOST_CONFIG_DIR`
- [ ] Pastas `HOST_*` criadas no sistema de arquivos.
- [ ] Conectividade com GHCR confirmada (`ghcr.io` porta 443 acessível).

---

## Modo HOST — Windows / Linux (PC local)

### Antes do primeiro deploy

- [ ] Docker Desktop instalado e iniciado (ícone estável na bandeja).
- [ ] **Windows:** `Set-ExecutionPolicy RemoteSigned -Scope LocalMachine` executado (ou `execute.ps1` disponível como alternativa).
- [ ] Token GitHub (PAT) com `read:packages` gerado e disponível para a primeira execução.
- [ ] `DATABASE_HOST=db` no `.env` (banco local em container — não alterar).
- [ ] Pastas `HOST_*` com caminhos Windows (barras invertidas) ou Linux (barras normais).

### Após instalação (Opção 2 do menu)

- [ ] Containers em execução: `docker compose -f docker-compose.prd.host.yml ps` → `app`, `db` e `rpa-scheduler` com status `Up` / `healthy`.
- [ ] Logs sem erros críticos: `docker compose -f docker-compose.prd.host.yml logs --tail=50`.
- [ ] Sistema acessível: `http://localhost:<HOST_APP_EXTERNAL_PORT>`.
- [ ] Health endpoint: `http://localhost:<HOST_APP_EXTERNAL_PORT>/health` retorna `"schema_status":"current"`.
- [ ] Credenciais SISCAN cadastradas em: `http://localhost:<HOST_APP_EXTERNAL_PORT>/admin/siscan-credentials`.
- [ ] Primeira coleta manual executada com sucesso (Opção 4 do menu).

### Antes de atualizar (Opção 2 — nova versão)

- [ ] Comunicar usuários sobre possível indisponibilidade breve.
- [ ] Anotar versão atual: `docker images ghcr.io/prisma-consultoria/siscan-rpa-rpa`.
- [ ] Token GitHub válido (ou `credenciais.txt` será refeito se expirado).
- [ ] Espaço em disco disponível. **Windows:** `Get-PSDrive C`. **Linux:** `df -h`.

### Emergência / Rollback (modo HOST)

- [ ] Identificar imagem anterior: `docker images ghcr.io/prisma-consultoria/siscan-rpa-rpa`.
- [ ] Parar stack: `docker compose -f docker-compose.prd.host.yml down`.
- [ ] Se imagem anterior estiver localmente, recriar stack: `docker compose -f docker-compose.prd.host.yml up -d`.
- [ ] Se imagem não estiver localmente, solicitar ao time técnico a tag de rollback.
- [ ] Coletar artefatos antes de abrir chamado (ver [TROUBLESHOOTING.md — Coleta de artefatos](TROUBLESHOOTING.md)).
- [ ] Comunicar time DevOps Prisma com logs e descrição do problema.

---

## Modo Servidor — Ubuntu Server (Opção 1.A)

### Antes do primeiro deploy

- [ ] Ubuntu Server 22.04+: `lsb_release -a`.
- [ ] Docker Engine ≥ 24 (não Docker Desktop): `docker version`.
- [ ] `curl` e `sudo` disponíveis.
- [ ] PostgreSQL 16+ externo acessível: `psql -h <DATABASE_HOST> -U siscan_rpa -c "SELECT 1"`.
- [ ] Token de registro do runner obtido: GitHub → repositório `siscan-rpa` → Settings → Actions → Runners.
- [ ] `DATABASE_HOST` preenchido com IP/hostname do PostgreSQL externo (**não** usar `db`).
- [ ] Caminhos `HOST_*` em formato Linux absoluto (ex.: `/opt/siscan-rpa/logs`).
- [ ] `siscan-server-setup.sh` executado: `bash ./siscan-server-setup.sh`.

### Após configuração do servidor

- [ ] Containers em execução: `docker compose -f docker-compose.prd.external-db.yml ps` → `app` e `rpa-scheduler` com status `Up` / `healthy`.
- [ ] Logs sem erros de conexão com banco: `docker compose -f docker-compose.prd.external-db.yml logs migrate`.
- [ ] Sistema acessível: `http://<IP-DO-SERVIDOR>:<HOST_APP_EXTERNAL_PORT>`.
- [ ] Health endpoint retorna `"schema_status":"current"`.
- [ ] Runner registrado e online: GitHub → repositório `siscan-rpa` → Settings → Actions → Runners.
- [ ] Logout e login no servidor realizados para que permissões Docker tenham efeito (fase 7 do script).
- [ ] Credenciais SISCAN cadastradas em `/admin/siscan-credentials`.

### Emergência / Rollback (modo servidor)

- [ ] Identificar a tag do deploy anterior nos logs do GitHub Actions.
- [ ] Parar stack: `docker compose -f docker-compose.prd.external-db.yml down`.
- [ ] Fazer pull da tag anterior: `docker pull ghcr.io/prisma-consultoria/siscan-rpa-rpa:<tag-anterior>`.
- [ ] Ajustar tag no compose ou variável e recriar: `docker compose -f docker-compose.prd.external-db.yml up -d`.
- [ ] Coletar artefatos antes de abrir chamado (ver [TROUBLESHOOTING.md — Coleta de artefatos](TROUBLESHOOTING.md)).
- [ ] Comunicar time DevOps Prisma.

---

> Mantenha estes checklists como referência rápida durante procedimentos de operação e emergência.
