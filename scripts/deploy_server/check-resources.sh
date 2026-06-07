#!/usr/bin/env bash
# -------------------------------------------
# Specialist: check-resources
# Summary: vCPUs, RAM e disco livre — limiares POR PRODUTO em products.json
# -------------------------------------------
# Verifica que a VM atende aos requisitos de capacidade declarados no manifesto
# scripts/data/products.json (.products.<p>.resources, com fallback ao mínimo
# aceitável GLOBAL .defaults.resources): min_vcpus, min_ram_mb (piso),
# recommended_ram_mb (alvo; entre piso e recomendado = aviso) e min_disk_gb.
# NÃO há limiar hardcoded aqui.
#
# Em VMs com menos recursos a stack até sobe, mas:
#   - migrate + app + scheduler + redis disputam CPU em pull/up;
#   - logs + media (RPA) + cache Redis (dashboard) crescem em disco;
#   - heap Python sob carga supera 4 GB sob picos.
# -------------------------------------------

set -uo pipefail

SPECIALIST_NAME="check-resources"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=./_common.sh
source "$SCRIPT_DIR/_common.sh"

PRODUCTS_FILE="${REPO_ROOT}/scripts/data/products.json"
ENV_FILE="${COMPOSE_DIR:-$(pwd)}/.env"

# Limiares de recursos: a fonte da verdade é o manifesto products.json — NÃO há
# valores hardcoded neste script (issue #112). Lidos POR PRODUTO em
# .products.<produto>.resources.* (VMs de produtos diferentes têm specs
# diferentes — ex.: VMs com 7–8 GB de RAM) e, quando o produto não
# declara um limiar, cai no fallback GLOBAL .defaults.resources.*. São lidos
# após o parse de args (dependem de --product). Semântica: min_ram_mb = piso
# bloqueante; recommended_ram_mb = alvo (entre piso e recomendado => aviso).
COMPOSE_DIR_PROBE="${COMPOSE_DIR:-$(pwd)}"

usage() {
    cat <<EOF
Uso: bash $(basename "$0") [--product NAME] [--quiet | --json] [--help]

Verifica vCPUs, RAM e disco livre conforme os limiares do produto em
scripts/data/products.json (.resources, fallback .defaults.resources).
Requer produto: --product <rpa|dashboard|full> (ou SISCAN_PRODUCT / .env).

Exit code: 0 = OK · 1 = abaixo do mínimo · 2 = uso inválido
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        *)
            if common_parse_arg "$@"; then shift "$shift_count"
            else echo "argumento desconhecido: $1" >&2; usage >&2; exit 2; fi
            ;;
    esac
done

# Limiares lidos do manifesto products.json (fonte única — sem hardcode):
# POR PRODUTO em .products.<p>.resources, com fallback GLOBAL em
# .defaults.resources. Exige produto resolvido; falha só se NEM o produto NEM
# o defaults declararem o limiar.
resolve_product
[ -n "${SISCAN_PRODUCT:-}" ] || fail "SISCAN_PRODUCT não definido (sem --product, sem env var, sem entrada em $ENV_FILE) — passe --product ou rode check-env"
product_validate

# _resource KEY → .products.<SISCAN_PRODUCT>.resources.KEY (fallback .defaults.resources.KEY)
_resource() {
    jq -r ".products.\"$SISCAN_PRODUCT\".resources.$1 // .defaults.resources.$1 // empty" "$PRODUCTS_FILE" 2>/dev/null
}
MIN_VCPUS=$(_resource min_vcpus)
MIN_RAM_MB=$(_resource min_ram_mb)
RECOMMENDED_RAM_MB=$(_resource recommended_ram_mb)
MIN_DISK_GB=$(_resource min_disk_gb)
for _pair in "MIN_VCPUS:min_vcpus" "MIN_RAM_MB:min_ram_mb" "RECOMMENDED_RAM_MB:recommended_ram_mb" "MIN_DISK_GB:min_disk_gb"; do
    _name="${_pair%%:*}"; _key="${_pair##*:}"
    [ -n "${!_name}" ] || fail "resources.${_key} ausente em .products.$SISCAN_PRODUCT.resources e em .defaults.resources (products.json) — issue #112"
done
min_ram_gb=$(awk -v m="$MIN_RAM_MB" 'BEGIN{printf "%.0f", m/1024}')
rec_ram_gb=$(awk -v m="$RECOMMENDED_RAM_MB" 'BEGIN{printf "%.0f", m/1024}')

CAT_CPU="vCPUs"
CAT_RAM="Memória RAM"
CAT_DISK="Disco livre em \$COMPOSE_DIR"

# ────────────────────────────────────────────────────────────────────────────
# vCPUs
# ────────────────────────────────────────────────────────────────────────────
print_category_header "$CAT_CPU" "DEPLOY_SERVER.md exige ≥ $MIN_VCPUS vCPUs — Gunicorn workers + scheduler + migrate disputam CPU em picos."
vcpus=$(nproc 2>/dev/null || echo 0)
if [ "$vcpus" -ge "$MIN_VCPUS" ] 2>/dev/null; then
    add_ok "$CAT_CPU" cpu 0 "$(hostname)" "$vcpus vCPUs (>= $MIN_VCPUS)"
else
    add_fail "$CAT_CPU" cpu 0 "$(hostname)" "$vcpus vCPUs (esperado >= $MIN_VCPUS) — sob carga pode haver gargalo em workers Gunicorn"
fi

# ────────────────────────────────────────────────────────────────────────────
# RAM
# ────────────────────────────────────────────────────────────────────────────
print_category_header "$CAT_RAM" "products.json: recomendado ≥ ${rec_ram_gb} GB; piso bloqueante ${min_ram_gb} GB. Entre o piso e o recomendado é aviso (não bloqueia — ex.: VMs com 7–8 GB de RAM)."
ram_mb=$(free -m 2>/dev/null | awk '/^Mem:/ {print $2}')
ram_mb=${ram_mb:-0}
ram_gb=$(awk -v m="$ram_mb" 'BEGIN{printf "%.1f", m/1024}')
if [ "$ram_mb" -ge "$RECOMMENDED_RAM_MB" ] 2>/dev/null; then
    add_ok "$CAT_RAM" ram 0 "$(hostname)" "${ram_gb} GB (>= ${rec_ram_gb} GB recomendado)"
elif [ "$ram_mb" -ge "$MIN_RAM_MB" ] 2>/dev/null; then
    # Aviso NÃO-bloqueante (convenção do repo: add_ok com "(warn)" no detalhe).
    add_ok "$CAT_RAM" ram 0 "$(hostname)" "${ram_gb} GB (warn) — abaixo do recomendado ${rec_ram_gb} GB, acima do piso ${min_ram_gb} GB; monitorar OOM sob carga"
else
    add_fail "$CAT_RAM" ram 0 "$(hostname)" "${ram_gb} GB (abaixo do piso de ${min_ram_gb} GB; recomendado >= ${rec_ram_gb} GB) — risco de OOM kills"
fi

# ────────────────────────────────────────────────────────────────────────────
# Disco livre no COMPOSE_DIR
# ────────────────────────────────────────────────────────────────────────────
print_category_header "$CAT_DISK" "DEPLOY_SERVER.md exige ≥ 20 GB livres em \$COMPOSE_DIR — imagens Docker, logs, media (RPA) e backups crescem rápido."

if [ -d "$COMPOSE_DIR_PROBE" ]; then
    # df -BG output: 1G blocks; pega coluna 'Avail'
    disk_gb=$(df -BG --output=avail "$COMPOSE_DIR_PROBE" 2>/dev/null | tail -1 | tr -dc '0-9')
    disk_gb=${disk_gb:-0}
    if [ "$disk_gb" -ge "$MIN_DISK_GB" ] 2>/dev/null; then
        add_ok "$CAT_DISK" disk 0 "$COMPOSE_DIR_PROBE" "${disk_gb} GB livres (>= $MIN_DISK_GB)"
    else
        add_fail "$CAT_DISK" disk 0 "$COMPOSE_DIR_PROBE" "${disk_gb} GB livres (esperado >= $MIN_DISK_GB) — risco de disco cheio com pull de imagens novas"
    fi
else
    add_fail "$CAT_DISK" disk 0 "$COMPOSE_DIR_PROBE" "diretório não existe — não é possível medir disco"
fi

render_results
finalize_exit
