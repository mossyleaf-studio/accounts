DC = docker compose
-include .env

IMAGE ?= docker.io/injust/mossyleaf-accounts
TAG ?= $(shell git rev-parse --short=7 HEAD)
PLATFORM ?= linux/amd64
DEPLOY_HOST ?=
DEPLOY_DIR ?=
REMOTE_DOCKER ?= docker
NEEDS_DEPLOY_TARGET = @test -n "$(DEPLOY_HOST)" -a -n "$(DEPLOY_DIR)" || { echo "Set DEPLOY_HOST and DEPLOY_DIR (e.g. in .env)"; exit 1; }
BLUEPRINTS = custom/mossyleaf-accounts.yaml custom/mossyleaf-apps.yaml

EMAIL ?=
NAME ?=
CONTEXT ?= mossyleaf
GROUPS_mossyleaf = mossydew mossytrunk
GROUPS_injust = injust
GROUPS_personal = muhmeal
GROUPS ?= $(GROUPS_$(CONTEXT))
TIMEZONE ?= Europe/Paris
LOCALE ?= fr
DURATION ?= days=7
INVITE_ENV = -e INVITE_CONTEXT='$(CONTEXT)' -e INVITE_EMAIL='$(EMAIL)' -e INVITE_NAME='$(NAME)' -e INVITE_GROUPS='$(GROUPS)' -e INVITE_TIMEZONE='$(TIMEZONE)' -e INVITE_LOCALE='$(LOCALE)' -e INVITE_DURATION='$(DURATION)' -e INVITE_WORKSPACE='$(WORKSPACE)'

SHOT = $(DC) run --rm --no-deps playwright npx -y playwright@1.63.0 screenshot --wait-for-timeout=4000
# Chromium resolves *.localhost itself: send it through the server as a proxy to reach the other brands.
BRAND_SHOT = $(SHOT) --proxy-server=http://server:9000 --proxy-bypass='<-loopback>'

.PHONY: up down logs ps apply check invite shots image push deploy-files deploy

up: ## Build the image and start Authentik on http://localhost:9000 and Mailpit on http://localhost:8027
	$(DC) up -d --wait --build

down:
	$(DC) down

logs:
	$(DC) logs -f server worker

ps:
	$(DC) ps

apply: ## Re-apply the custom blueprints now (e.g. after editing branding/branding.css)
	$(DC) exec -T worker ak apply_blueprint $(BLUEPRINTS)

check: ## Smoke test the running stack: blueprints applied, OpenID configurations, sign-in page, brand (CI runs it on a fresh stack)
	./scripts/check.sh

invite: ## make invite EMAIL=a@b.c NAME="Ada" [CONTEXT=mossyleaf|injust|personal] [GROUPS="mossydew mossytrunk"] [WORKSPACE="Atelier Mousse"] [REMOTE=1]
	@test -n "$(EMAIL)" || (echo "EMAIL is required" && exit 1)
ifeq ($(REMOTE),1)
	ssh $(DEPLOY_HOST) "cd $(DEPLOY_DIR) && $(REMOTE_DOCKER) compose exec -T $(INVITE_ENV) -e INVITE_SECURE=1 worker ak shell" < scripts/invite.py
else
	$(DC) exec -T $(INVITE_ENV) worker ak shell < scripts/invite.py
endif

shots: ## Screenshot the sign-in page at phone and desktop widths, and the other brands at phone width, into shots/
	mkdir -p shots
	$(SHOT) --viewport-size=390,844 http://server:9000/if/flow/mossyleaf-authentication/ shots/login-phone.png
	$(SHOT) --viewport-size=1440,900 http://server:9000/if/flow/mossyleaf-authentication/ shots/login-desktop.png
	$(BRAND_SHOT) --viewport-size=390,844 http://injust.localhost:9000/if/flow/mossyleaf-authentication/ shots/login-injust-phone.png
	$(BRAND_SHOT) --viewport-size=390,844 http://personal.localhost:9000/if/flow/mossyleaf-authentication/ shots/login-personal-phone.png

image: ## Build the production image locally (IMAGE, TAG, PLATFORM)
	docker buildx build --platform $(PLATFORM) -t $(IMAGE):$(TAG) -t $(IMAGE):latest --load .

push: ## Build and push the image by hand (CI does it on every push to main once make check passes; run docker login first)
	docker buildx build --platform $(PLATFORM) -t $(IMAGE):$(TAG) -t $(IMAGE):latest --push .

deploy-files: ## Copy the server compose file, env template and README to DEPLOY_HOST:DEPLOY_DIR
	$(NEEDS_DEPLOY_TARGET)
	ssh $(DEPLOY_HOST) 'mkdir -p $(DEPLOY_DIR)'
	scp deploy/compose.yaml deploy/.env.dist deploy/README.md $(DEPLOY_HOST):$(DEPLOY_DIR)/

deploy: ## Run IMAGE:TAG (published by CI) on DEPLOY_HOST: set it in the server .env, pull, restart, reapply the blueprints
	$(NEEDS_DEPLOY_TARGET)
	@curl -sf -o /dev/null https://hub.docker.com/v2/repositories/$(patsubst docker.io/%,%,$(IMAGE))/tags/$(TAG) || { echo "$(IMAGE):$(TAG) is not published: CI only publishes it once make check passes (still running, or failed?)"; exit 1; }
	scp deploy/compose.yaml $(DEPLOY_HOST):$(DEPLOY_DIR)/
	ssh $(DEPLOY_HOST) 'set -e; cd $(DEPLOY_DIR); \
		sed -i "/^IMAGE=/d; /^TAG=/d; /^AUTHENTIK_TAG=/d" .env; \
		printf "IMAGE=%s\nTAG=%s\n" "$(IMAGE)" "$(TAG)" >> .env; \
		$(REMOTE_DOCKER) compose pull server worker; \
		$(REMOTE_DOCKER) compose up -d --wait --remove-orphans; \
		$(REMOTE_DOCKER) compose exec -T worker ak apply_blueprint $(BLUEPRINTS) >/dev/null'
	@echo "$(IMAGE):$(TAG) is running on $(DEPLOY_HOST)"
