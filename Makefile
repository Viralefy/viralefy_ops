.PHONY: help lint check install update status logs

help:
	@echo "alvos:"
	@echo "  lint    — roda shellcheck em todos os scripts"
	@echo "  check   — bash -n (sintaxe) em todos os scripts"
	@echo "  install — sudo bin/viralefy-install (DESTRUTIVO se não-idempotente)"
	@echo "  update  — sudo viralefy-update (DESTRUTIVO)"
	@echo "  status  — viralefy-status"
	@echo "  logs    — viralefy-logs -f"

SCRIPTS := bin/viralefy-install bin/viralefy-update bin/viralefy-status bin/viralefy-logs bin/bootstrap.sh \
           installer/lib.sh installer/00-prereqs.sh installer/10-users.sh installer/20-postgres.sh \
           installer/30-secrets.sh installer/40-clone.sh installer/50-build.sh installer/60-systemd.sh \
           installer/70-start.sh

lint:
	@command -v shellcheck >/dev/null 2>&1 || { echo "instale shellcheck: apt install shellcheck"; exit 1; }
	shellcheck -x $(SCRIPTS)

check:
	@for f in $(SCRIPTS); do bash -n "$$f" && echo "  ok $$f"; done

install:
	sudo ./bin/viralefy-install

update:
	sudo viralefy-update

status:
	viralefy-status

logs:
	viralefy-logs -f
