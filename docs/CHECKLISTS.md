# Checklists Operacionais — Assistente SISCAN
<a name="checklists"></a>

Versão: 4.0
Data: 2026-03-23

Checklists para os três modos de deploy: HOST (PC local, produto `full`), Servidor RPA (produto `rpa`) e Servidor Dashboard (produto `dashboard`).

---

## Verificações comuns — todos os modos

Este checklist se aplica a qualquer modo de deploy, independentemente do produto selecionado.

- [ ] Docker Engine instalado e rodando: `docker info` sem erros.
- [ ] Docker Compose v2: `docker compose version` retorna `v2.x.x`.
- [ ] `git` disponível: `git --version`.
- [ ] Repositório clonado: `git clone https://github.com/Prisma-Consultoria/assistente-siscan-rpa.git`.
- [ ] `.env` criado a partir do sample correspondente ao produto:
  - HOST: `.env.host.sample`
  - Servidor RPA: `.env.server-rpa.sample`
  - Servidor Dashboard: `.env.server-dashboard.sample`
- [ ] `DATABASE_PASSWORD` alterado (não usar o padrão).
- [ ] Conectividade com GHCR confirmada (`ghcr.io` porta 443 acessível).

---

## Modo HOST — produto `full` (PC local)

### Antes do primeiro deploy

- [ ] Docker Desktop instalado e iniciado.
- [ ] **Windows:** `Set-ExecutionPolicy RemoteSigned -Scope LocalMachine` executado.
- [ ] Token GitHub (PAT) com `read:packages` gerado.
- [ ] `DATABASE_HOST=db` no `.env` (não alterar).
- [ ] `SECRET_KEY` definida (ou vazia — o assistente gera).
- [ ] `DASHBOARD_ADMIN_PASSWORD` definida.
- [ ] Pastas `HOST_*` preenchidas com caminhos do sistema operacional.
- [ ] `SISCAN_PRODUCT=full` no `.env`.

### Após instalação (Opção 2 do menu)

- [ ] 7 containers em execução: `docker compose -f docker-compose.prd.host.yml ps`.
- [ ] Serviços healthy: `app`, `dashboard-app`.
- [ ] RPA acessível: `http://localhost:5001/health` → `"schema_status":"current"`.
- [ ] Dashboard acessível: `http://localhost:5000/health` → `"schema_status":"current"`.
- [ ] Credenciais SISCAN cadastradas: `http://localhost:5001/admin/siscan-credentials`.
- [ ] Primeira coleta manual (Opção 4 do menu).
- [ ] Sync do dashboard (Opção 5 ou automático após 30 min).

---

## Modo Servidor — produto `rpa` (VM do RPA)

### Antes do primeiro deploy

- [ ] Ubuntu Server 24.04+: `lsb_release -a`.
- [ ] Docker Engine ≥ 28 (não Docker Desktop): `docker version`.
- [ ] PostgreSQL 16+ externo acessível: `psql -h <DATABASE_HOST> -U siscan_rpa -c "SELECT 1"`.
- [ ] Token de registro do runner gerado em: `siscan-rpa` → Settings → Actions → Runners.
- [ ] `DATABASE_HOST` preenchido com IP/hostname do PostgreSQL (**não** usar `db`).
- [ ] `SECRET_KEY` definida.
- [ ] Caminhos `HOST_*` em formato Linux absoluto.
- [ ] `siscan-server-setup.sh --product rpa` executado.

### Após configuração

- [ ] Containers em execução: `docker compose -f docker-compose.prd.rpa.yml ps` → `app` e `rpa-scheduler` com status `Up` / `healthy`.
- [ ] Health: `http://<IP>:5001/health` → `"schema_status":"current"`.
- [ ] Runner online: GitHub → `siscan-rpa` → Settings → Actions → Runners → status `Idle`.
- [ ] Credenciais SISCAN cadastradas em `/admin/siscan-credentials`.
- [ ] Primeira coleta manual executada com sucesso.

---

## Modo Servidor — produto `dashboard` (VM do Dashboard)

### Antes do primeiro deploy

- [ ] Ubuntu Server 24.04+.
- [ ] Docker Engine ≥ 28.
- [ ] PostgreSQL externo acessível com bancos `siscan_rpa` e `siscan_dashboard` criados.
- [ ] Token de registro do runner gerado em: `siscan-dashboard` → Settings → Actions → Runners.
- [ ] `DATABASE_HOST` preenchido.
- [ ] `SESSION_SECRET` definida.
- [ ] `RPA_DATABASE_URL` preenchido com conexão ao banco do RPA.
- [ ] `ADMIN_PASSWORD` definida.
- [ ] `HOST_LOG_DIR` preenchido.
- [ ] `siscan-server-setup.sh --product dashboard` executado.

### Após configuração

- [ ] Containers em execução: `docker compose -f docker-compose.prd.dashboard.yml ps` → `app` e `sync` com status `Up` / `healthy`.
- [ ] Health: `http://<IP>:5000/health` → `"schema_status":"current"`.
- [ ] Runner online: GitHub → `siscan-dashboard` → Settings → Actions → Runners → status `Idle`.
- [ ] Login funcional: admin / senha definida em `ADMIN_PASSWORD`.
- [ ] Sync executado: dados do RPA visíveis no dashboard.

---

## Emergência / Rollback

Os passos a seguir se aplicam a qualquer produto. Substitua o compose file e a imagem conforme o caso.

- [ ] Identificar imagem/tag anterior: `docker images | grep siscan`.
- [ ] Parar stack: `docker compose -f <compose-file> down`.
- [ ] Pull da tag anterior: `docker pull <imagem>:<tag-anterior>`.
- [ ] Recriar: `docker compose -f <compose-file> up -d`.
- [ ] Coletar artefatos: [TROUBLESHOOTING.md — Coleta de artefatos](TROUBLESHOOTING.md).
- [ ] Comunicar time DevOps Prisma.

---

> Mantenha estes checklists como referência rápida durante procedimentos de operação e emergência.
