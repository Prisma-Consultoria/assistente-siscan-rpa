# `scripts/data/products.json` — Manifesto de produtos

Fonte de verdade declarativa que descreve cada produto que o assistente deploya. Consumido pelos specialists em `scripts/deploy_server/check-*.sh` em vez de `case "$SISCAN_PRODUCT"` hardcoded — viabiliza adicionar um produto novo editando só o JSON (1ª task da feature [#42](https://github.com/Prisma-Consultoria/assistente-siscan-rpa/issues/42)).

## Schema

```json
{
  "version": "2.0",
  "products": {
    "<id>": {
      "label": "Nome amigável",
      "repo": "owner/repo",
      "image": "ghcr.io/owner/repo:main",
      "compose_file": "docker-compose.prd.<id>.yml",
      "env_sample": ".env.server-<id>.sample",
      "runner_label": "producao-<id>",
      "runner_name_suffix": "siscan-<id>",
      "session_secret_var": "SECRET_KEY ou SESSION_SECRET",
      "expected_services": ["app", "..."],
      "expected_external_ports": [5001],
      "required_env_vars": ["DATABASE_HOST", "..."],
      "host_dir_vars": [
        "HOST_LOG_DIR",
        "...",
        {
          "name": "HOST_SECRETS_DIR",
          "derived_from": "HOST_LOG_DIR",
          "derivation": "dirname + /secrets",
          "default_mode": "700",
          "auto_create": true,
          "description": "..."
        }
      ],
      "default_passwords_to_detect": ["siscan_rpa"],
      "extras": {
        "rsa_keys_required": true,
        "host_secrets_dir_optional": true,
        "host_backups_dir_optional": true,
        "siscan_portal_url_default": "https://siscan.saude.gov.br/",
        "excel_columns_mapping_required": true,
        "redis_required": true,
        "rpa_database_url_required": true,
        "sync_interval_default_seconds": 1800
      }
    }
  }
}
```

### `host_dir_vars` — schema v2.0 (TSK00.05.01 [#95](https://github.com/Prisma-Consultoria/assistente-siscan-rpa/issues/95))

A partir da v2.0, `host_dir_vars[]` aceita DUAS formas que coexistem no mesmo array:

| Forma | Quem preenche | Quem valida |
|---|---|---|
| **String** (legado) | Operador no setup Fase 5 (prompt interativo) | `check-env` (não-vazia + path Linux) + `check-permissions` (existe + escrevível) |
| **Objeto** (v2.0) | `siscan-server-setup.sh` Fase 5 deriva automaticamente | `check-permissions` via blocos dedicados (extras-driven) |

**Schema do objeto**:

| Campo | Tipo | Obrigatório | Descrição |
|---|---|---|---|
| `name` | string | sim | Nome da variável (ex: `HOST_SECRETS_DIR`) |
| `derived_from` | string | sim | Variável-fonte para derivação (ex: `HOST_LOG_DIR`) |
| `derivation` | string | sim | Operação de derivação. Suportada: `"dirname + /<subdir>"` — extrai parent de `derived_from` e anexa subdir. |
| `default_mode` | string | não | Permissões POSIX (ex: `"700"` para secrets). Aplicado via `chmod` após `mkdir -p`. |
| `auto_create` | boolean | não (default `false`) | Se `true`, setup cria o diretório via `mkdir -p`. |
| `description` | string | não | Descrição amigável (para help). |

**Semântica de preservação**: se o operador declarar manualmente o valor no `.env` (ex: `HOST_SECRETS_DIR=/mnt/seguro/keys`), o setup **preserva** esse valor — apenas garante que o diretório exista e tenha o `default_mode` correto. Já com `HOST_SECRETS_DIR` ausente, é derivado de `dirname(HOST_LOG_DIR) + /secrets`.

**Backward compat para `product_get_array host_dir_vars`**: a função emite **somente strings** — objetos são filtrados pra preservar a semântica histórica ("vars que o operador precisa declarar"). Para acessar metadata de derivação, use `product_get_host_dir_vars_derived`.

## Campos

| Campo | Tipo | Quem consome | Para quê |
|---|---|---|---|
| `label` | string | (informativo) | Nome amigável exibido em outputs |
| `repo` | string | `check-runner` | Owner/repo do GitHub pro registro do runner self-hosted |
| `image` | string | `check-stack` | Imagem GHCR esperada localmente |
| `compose_file` | string | `check-stack` | Compose file esperado em `COMPOSE_DIR` |
| `env_sample` | string | (informativo, futuro setup) | Sample do `.env` que o setup copia |
| `runner_label` | string | (informativo, futuro setup) | Label do runner no GitHub Actions |
| `runner_name_suffix` | string | `check-runner` | Sufixo no nome do runner: `<hostname>-<suffix>` |
| `session_secret_var` | string | `check-env` | Nome da variável de sessão (`SECRET_KEY` rpa, `SESSION_SECRET` dashboard) — validada com `≥ 32 chars` |
| `expected_services` | array | `check-stack` | Serviços que devem estar `running` no `docker compose ps` |
| `expected_external_ports` | array | `check-stack` | Portas externas verificadas contra collision (`ss -tlnp`) |
| `required_env_vars` | array | `check-env` | Variáveis obrigatórias no `.env` (validadas não-vazias + regras especiais) |
| `host_dir_vars` | array misto (string \| objeto, schema v2.0) | `check-env`, `check-permissions`, `siscan-server-setup` Fase 5 | `HOST_*_DIR`. Strings: operador declara, specialists validam. Objetos: setup deriva automaticamente (TSK00.05.01) — ver subseção dedicada acima |
| `default_passwords_to_detect` | array | `check-env` | Valores de `DATABASE_PASSWORD` que indicam senha default não alterada |
| `extras` | object | múltiplos | Flags booleanas + defaults consumidos por specialists específicos |

## Flags do `extras`

| Flag | Tipo | Consumido por | Comportamento |
|---|---|---|---|
| `rsa_keys_required` | bool | `check-permissions` | Valida `rsa_private_key.pem` + `rsa_public_key.pem` em `$HOST_SECRETS_DIR` (registro interno 01/04 — chaves expirando) |
| `host_secrets_dir_optional` | bool | `check-permissions` | Se ausente no `.env`, deriva de `$(dirname $HOST_LOG_DIR)/secrets` + valida perms 700 |
| `host_backups_dir_optional` | bool | `check-permissions` | Se ausente, deriva de `$(dirname $HOST_LOG_DIR)/backups` + valida existência |
| `siscan_portal_url_default` | string | `check-env`, `check-network` | URL default do portal SISCAN (ativa categoria condicional em check-network) |
| `excel_columns_mapping_required` | bool | `check-permissions` | Valida presença de `config/excel_columns_mapping.json` (RPA) |
| `redis_required` | bool | (informativo) | Indica que o produto depende de Redis local — futuro: check-redis |
| `rpa_database_url_required` | bool | `check-env`, `check-db` | Exige `RPA_DATABASE_URL` com regex `postgresql://...` + faz TCP/5432 pra esse host (dashboard) |
| `sync_interval_default_seconds` | number | `check-env` | Default do `SYNC_INTERVAL_SECONDS` quando ausente (apenas warning) |

## Adicionar um produto novo

Quando entrar uma demanda de um terceiro produto (ex.: `siscan-relatorios`):

1. Adicionar entrada `relatorios` em `products.json` preenchendo todos os campos
2. Criar `.env.server-relatorios.sample` e `docker-compose.prd.relatorios.yml`
3. Criar workflow `.github/workflows/cd_imagem_certificada_selfhosted.yml` no repo do produto novo (cópia adaptada do siscan-rpa)
4. Registrar runner na VM com label `producao-relatorios`

**Não é necessário** mexer no código dos specialists nem do doctor — eles iteram o manifesto e descobrem o produto novo automaticamente.

> **Refatoração ainda pendente da feature #42:** `siscan-server-setup.sh` ainda tem `case` hardcoded para escolher compose/sample/runner label. Quando aquela tarefa for entregue, adicionar um produto novo vira realmente só "editar o JSON + criar samples".

## API dos helpers em `_common.sh`

Specialists usam essas funções (definidas em `scripts/deploy_server/_common.sh`):

```bash
# Pré-requisitos
PRODUCTS_FILE="${REPO_ROOT}/scripts/data/products.json"
SISCAN_PRODUCT=$(_read_env SISCAN_PRODUCT)
product_validate                          # falha (exit 2) se produto desconhecido

# Leitura de campos
compose=$(product_get compose_file)
label=$(product_get label "siscan-default")  # com default

# Leitura de arrays
mapfile -t services < <(product_get_array expected_services)
# (host_dir_vars filtra para SÓ strings — semântica histórica preservada)
mapfile -t host_vars < <(product_get_array host_dir_vars)

# Leitura de host_dir_vars derivados (objetos v2.0 — TSK00.05.01)
# Saída TSV: name<TAB>derived_from<TAB>derivation<TAB>default_mode<TAB>auto_create
# Sentinela "-" para campos vazios (evita colapso de tabs adjacentes pelo `read`).
while IFS=$'\t' read -r name derived_from derivation default_mode auto_create; do
    [ "$default_mode" = "-" ] && default_mode=""
    [ "$auto_create" = "-" ] && auto_create=""
    echo "Derivada: $name from $derived_from via '$derivation' (mode=$default_mode)"
done < <(product_get_host_dir_vars_derived)

# Flags booleanas
if product_has_extra rsa_keys_required; then
    # ...
fi

# Strings de extras
default_url=$(product_extra siscan_portal_url_default)
```

### Integração com `siscan-server-setup.sh` Fase 5

O setup chama `ensure_host_paths_derived "${ENV_FILE}"` após a coleta interativa das vars legacy. Internamente:

1. Itera `product_get_host_dir_vars_derived` (TSV)
2. Para cada objeto: chama `env_set_or_derive ENV_FILE VAR PARENT_VAR DERIVATION [MODE] [AUTO_CREATE]`
3. `env_set_or_derive` é **idempotente**:
   - Se `VAR` já tem valor no `.env`: preserva, só aplica `chmod`/`mkdir` se faltarem
   - Se ausente: deriva via `env_apply_derivation`, grava com `_set_env_value`, depois `mkdir`/`chmod`

Helpers extensíveis: novas operações de derivação (além de `dirname + /<sub>`) podem ser adicionadas em `env_apply_derivation` sem alterar o manifesto.

## Ver também

- [`index.md`](index.md) — entry point da documentação do doctor
- [`../siscan-server-setup.md`](../siscan-server-setup.md) — Fase 5 consome o schema v2.0 via `ensure_host_paths_derived`
- [`../../DEPLOY_SERVER.md`](../../DEPLOY_SERVER.md#fluxo-do-compose-file-de-produção) — guia narrativo do deploy (fluxo do compose)
- [`scripts/check-network.md`](scripts/check-network.md) — primeiro specialist a usar manifesto (campo `siscan_portal_url_default`)
- [Feature #42](https://github.com/Prisma-Consultoria/assistente-siscan-rpa/issues/42) — abstração multi-produto completa (esta task é o subset 1)
- [Task #45](https://github.com/Prisma-Consultoria/assistente-siscan-rpa/issues/45) — TSK00.02.01 que entregou esta estrutura
- [Task #95](https://github.com/Prisma-Consultoria/assistente-siscan-rpa/issues/95) — TSK00.05.01 que entregou schema v2.0 do `host_dir_vars[]`
