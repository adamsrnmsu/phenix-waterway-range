# Run inside the Lima VM (limactl shell phenix -- sudo make -C <this dir> <target>). ~/git is mounted at the same path.
# HOME_GIT: this repo lives in ~/git, so derive it from the Makefile's path (works under sudo)
HOME_GIT ?= $(abspath $(dir $(lastword $(MAKEFILE_LIST)))../..)
MM_SRC     ?= $(HOME_GIT)/minimega
PHENIX_SRC ?= $(HOME_GIT)/sceptre-phenix
# Build from private copies: the host's git fsmonitor socket (.git/fsmonitor--daemon.ipc) truncates the docker
# build context at .git on virtiofs, so builds fail with 'not a git repository'.
MM_CTX     ?= /var/tmp/minimega-src
PHENIX_CTX ?= /var/tmp/sceptre-phenix-src

all: up

# generated, never hand-edited; .DELETE_ON_ERROR drops it if the check fails
.DELETE_ON_ERROR:
phenix-arm64.Dockerfile: $(PHENIX_SRC)/docker/Dockerfile phenix-arm64.sed
	sed -f phenix-arm64.sed $< > $@
	grep -q 'minimega:arm64' $@ && grep -q Linux_arm64 $@ && grep -q filebeat-7.17.5-arm64 $@

minimega-ctx:
	mkdir -p $(MM_CTX) && rsync -a --exclude 'fsmonitor--daemon*' $(MM_SRC)/ $(MM_CTX)/

phenix-ctx:
	mkdir -p $(PHENIX_CTX) && rsync -a --exclude 'fsmonitor--daemon*' $(PHENIX_SRC)/ $(PHENIX_CTX)/

minimega-base: minimega-ctx
	docker build -t minimega:arm64 -f $(MM_CTX)/docker/Dockerfile $(MM_CTX)

minimega: minimega-base
	docker build -t minimega:arm64-kvm -f minimega-arm64.Dockerfile .

phenix: phenix-arm64.Dockerfile minimega-base phenix-ctx
	docker build -t phenix:arm64 -f phenix-arm64.Dockerfile \
	  --build-arg PHENIX_COMMIT=$$(git -C $(PHENIX_SRC) rev-parse HEAD) $(PHENIX_CTX)

images: minimega phenix

up:
	docker compose -f docker-compose.yml up -d minimega phenix

down:
	docker compose -f docker-compose.yml down

.PHONY: all minimega-ctx phenix-ctx minimega-base minimega phenix images up down
