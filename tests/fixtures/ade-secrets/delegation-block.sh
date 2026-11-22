# pinned from better-ade/ade-secrets tag v0.3.0, docs/contract.md (v1), "The delegation block (bin/secret)"
# >>> ade-secrets delegation (docs/contract.md v1 in better-ade/ade-secrets)
if [ "${HUB_SECRETS:-}" != builtin ] && command -v ade-secrets >/dev/null 2>&1; then
  case "${1:-}" in
    --set) [ -n "${2:-}" ] || exit 2; exec ade-secrets set "$2" --helper --kind api-key --used-by hub ;;
    --has) [ -n "${2:-}" ] || exit 2; names="$(ade-secrets list --names)" || exit $?
      printf '%s\n' "$names" | grep -qxF -- "$2"; exit $? ;;
    --forget) [ -n "${2:-}" ] || exit 2; exec ade-secrets forget "$2" ;;
    --list) exec ade-secrets list --names ;;
    ""|-*) ;;
    *) exec ade-secrets get "$1" ;;
  esac
fi
# <<< ade-secrets delegation
