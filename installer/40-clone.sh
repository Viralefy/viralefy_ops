#!/usr/bin/env bash
# Clona cada pacote em /viralefy/<pkg> com ownership do usuário do serviço.

install_clone() {
  log "clonando pacotes em $ROOT_DIR/"
  install -d -m 0755 -o root -g root "$ROOT_DIR"

  for pkg in "${PACKAGES[@]}" archive; do
    local dir url user
    dir="$(dir_of "$pkg")"
    url="$(repo_of "$pkg")"

    # archive não roda serviço — fica como root (read-only).
    if [[ "$pkg" == "archive" ]]; then
      user="root"
    else
      user="$(user_of "$pkg")"
    fi

    if [[ -d "$dir/.git" ]]; then
      log "atualizando $pkg ($url)"
      run_as_or_root "$user" git -C "$dir" fetch --depth 1 origin "$BRANCH"
      run_as_or_root "$user" git -C "$dir" reset --hard "origin/$BRANCH"
    else
      log "clonando $pkg ($url)"
      rm -rf "$dir"
      git clone --depth 1 --branch "$BRANCH" "$url" "$dir"
      chown -R "$user:viralefy" "$dir"
    fi
    info "$pkg em $dir"
  done
}

# run_as_or_root: usa sudo -u quando user != root.
run_as_or_root() {
  local user="$1"; shift
  if [[ "$user" == "root" ]]; then
    "$@"
  else
    sudo -u "$user" -H -- "$@"
  fi
}
