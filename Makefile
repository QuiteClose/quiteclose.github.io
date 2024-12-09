PROJECT_NAME   := quiteclose.github.io
JEKYLL_VERSION := 4.2.0
MAKEFILE_PATH  := $(abspath $(lastword $(MAKEFILE_LIST)))
REPO_DIR       := $(shell dirname $(MAKEFILE_PATH))

define with_container
	docker run --rm -it \
	--name "$(PROJECT_NAME)" \
	--volume "$(REPO_DIR):/srv/jekyll:Z" \
	--publish 4000:4000 \
	--publish 35729:35729 \
	jekyll/jekyll:$(JEKYLL_VERSION) \
	$(1);
endef

help:
	@echo "Usage:"
	@echo "  make asset        - Get a unique asset path"
	@echo "  make build        - Build the site"
	@echo "  make clean        - Remove build artifacts"
	@echo "  make serve        - Serve the site"
	@echo "  make shell        - Start a shell in the container"

asset:
	@getPath() { \
		echo "/assets/$$(date +'%Y')/$$(date|md5sum|cut -c1-5)"; \
	}; \
	UNIQUE_PATH=$$(getPath); \
	while [ -d "$(REPO_DIR)$$UNIQUE_PATH" ]; do \
		UNIQUE_PATH=$$(getPath); \
	done; \
	mkdir -p "$(REPO_DIR)$$UNIQUE_PATH"; \
	echo "Created $$UNIQUE_PATH";

build:
	$(call with_container,jekyll build --incremental --trace)

clean:
	@if [ -d "$(REPO_DIR)/_site" ]; then \
		echo "Removing $(REPO_DIR)/_site"; \
		rm -rf "$(REPO_DIR)/_site"; \
	fi

serve:
	$(call with_container,jekyll serve --draft --livereload)

shell:
	$(call with_container,/bin/sh)
