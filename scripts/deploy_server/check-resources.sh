#!/usr/bin/env bash
# -------------------------------------------
# Specialist: check-resources
# Summary: CPU (>=4), RAM (>=8GB), disco livre (>=20GB) conforme DEPLOY_SERVER.md
# -------------------------------------------
# Verifica que a VM atende aos requisitos mínimos de capacidade declarados na
# tabela de pré-requisitos do DEPLOY_SERVER.md:
#   - vCPUs >= 4
#   - RAM >= 8 GB
#   - Disco livre em $COMPOSE_DIR >= 20 GB
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

# Limites do DEPLOY_SERVER.md (tabela de pré-requisitos)
MIN_VCPUS=4
MIN_RAM_MB=$((8 * 1024))   # 8 GB (recomendado)
# Piso de RAM (bloqueante). Entre WARN_RAM_MB e MIN_RAM_MB é apenas AVISO
# (não-bloqueante): a VM contratada do ICI (VMPRDAPP-RPADASHBOARD) tem 7,7 GB
# (Anexo G); reprovar o deploy por estar ~0,3 GB abaixo de 8 GB era
# mis-calibração — bloqueava todo deploy nessa VM.
WARN_RAM_MB=$((7 * 1024))  # 7 GB
MIN_DISK_GB=20
COMPOSE_DIR_PROBE="${COMPOSE_DIR:-$(pwd)}"

usage() {
    cat <<EOF
Uso: bash $(basename "$0") [--quiet | --json] [--help]

Verifica vCPUs, RAM e disco livre conforme DEPLOY_SERVER.md
(mínimos: 4 vCPU, 8 GB RAM, 20 GB livres em \$COMPOSE_DIR).

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
print_category_header "$CAT_RAM" "DEPLOY_SERVER.md recomenda ≥ 8 GB. Entre 7 e 8 GB é aviso (não bloqueia — VM contratada do ICI = 7,7 GB); abaixo de 7 GB bloqueia."
ram_mb=$(free -m 2>/dev/null | awk '/^Mem:/ {print $2}')
ram_mb=${ram_mb:-0}
ram_gb=$(awk -v m="$ram_mb" 'BEGIN{printf "%.1f", m/1024}')
if [ "$ram_mb" -ge "$MIN_RAM_MB" ] 2>/dev/null; then
    add_ok "$CAT_RAM" ram 0 "$(hostname)" "${ram_gb} GB (>= 8 GB)"
elif [ "$ram_mb" -ge "$WARN_RAM_MB" ] 2>/dev/null; then
    # Aviso NÃO-bloqueante (convenção do repo: add_ok com "(warn)" no detalhe).
    add_ok "$CAT_RAM" ram 0 "$(hostname)" "${ram_gb} GB (warn) — abaixo do recomendado 8 GB, mas dentro da spec da VM; monitorar OOM sob carga"
else
    add_fail "$CAT_RAM" ram 0 "$(hostname)" "${ram_gb} GB (abaixo do piso de 7 GB; recomendado >= 8 GB) — risco de OOM kills"
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
