# Maintainer targets for the caddy-coddy agent. Users of the skill never need this file.
#
#   make check                 # what CI runs: syntax, JSON, version consistency, a fresh render
#   make bump VERSION=1.2.0    # set the version in manifest.yml and SKILL.md, open a changelog section
#   make release               # tag v<version> after `make check`; then push the tag to publish
#
# The version lives in manifest.yml; SKILL.md mirrors it and CHANGELOG.md must have a section for it.
SHELL := bash
.SHELLFLAGS := -euo pipefail -c
VERSION := $(shell sed -n 's/^version:[[:space:]]*//p' manifest.yml)
SCRIPTS := scripts/*.sh references/templates/*.sh references/templates/tests/*.sh references/templates/keycloak/*.sh
JSON := references/templates/keycloak/*.json references/templates/keycloak/import/*.json

.PHONY: check render-example bump release clean

check: ## syntax, JSON, version consistency, no addresses in templates, fresh render of the example, regression tests
	bash -n $(SCRIPTS)
	python3 -m py_compile scripts/*.py tests/*.py && rm -rf scripts/__pycache__ tests/__pycache__
	for f in $(JSON); do python3 -m json.tool "$$f" >/dev/null; done
	test "$$(sed -n 's/^version:[[:space:]]*//p' SKILL.md)" = "$(VERSION)" || { echo "SKILL.md version differs from manifest.yml ($(VERSION))"; exit 1; }
	grep -q '^## \[$(VERSION)\]' CHANGELOG.md || { echo "CHANGELOG.md has no section for $(VERSION)"; exit 1; }
	@# Templates are generic: no addresses other than loopback, every host comes from the manifest.
	! grep -rnE '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' references/templates | grep -vE '127\.0\.0\.1|0\.0\.0\.0' || { echo "address literal in templates"; exit 1; }
	$(MAKE) --no-print-directory render-example
	python3 tests/regression.py 2>&1 | tail -3
	@echo "check: OK ($(VERSION))"

render-example: ## render examples/caddy-coddy.yml into build/example and check the result
	rm -rf build/example && mkdir -p build/example && cp examples/caddy-coddy.yml build/example/
	python3 scripts/render.py build/example >/dev/null
	! grep -rl '@@' build/example || { echo "unresolved placeholders in the rendered example"; exit 1; }
	bash -n build/example/*.sh build/example/tests/*.sh build/example/keycloak/*.sh
	python3 -m json.tool build/example/keycloak/import/realm-coddy.json >/dev/null

bump: ## make bump VERSION=x.y.z
	@test -n "$(VERSION)" && [[ "$(VERSION)" =~ ^[0-9]+\.[0-9]+\.[0-9]+$$ ]] || { echo "usage: make bump VERSION=x.y.z"; exit 2; }
	sed -i 's/^version:.*/version: $(VERSION)/' manifest.yml SKILL.md
	grep -q '^## \[$(VERSION)\]' CHANGELOG.md || sed -i '0,/^## \[/s//## [$(VERSION)] - '"$$(date -u +%F)"'\n\n- \n\n## [/' CHANGELOG.md
	@echo "bumped to $(VERSION); fill in the CHANGELOG.md section, then commit and: make release"

release: check ## tag v<version> on the current commit
	git diff --quiet && git diff --cached --quiet || { echo "commit your changes first"; exit 1; }
	git tag -a "v$(VERSION)" -m "caddy-coddy agent $(VERSION)"
	@echo "tagged v$(VERSION); publish with: git push origin main v$(VERSION)"

clean:
	rm -rf build scripts/__pycache__
