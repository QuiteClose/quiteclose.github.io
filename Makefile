PROJECT_NAME   := quiteclose.github.io
JEKYLL_VERSION := 4.2.0
MAKEFILE_PATH  := $(abspath $(lastword $(MAKEFILE_LIST)))
REPO_DIR       := $(shell dirname $(MAKEFILE_PATH))

define with_container
	docker run --rm -it \
	--name "$(PROJECT_NAME)" \
	--volume "$(REPO_DIR):/srv/jekyll:Z" \
	--publish 4000:4000 \
	jekyll/jekyll:$(JEKYLL_VERSION) \
	$(1);
endef

clean:
	@if [ -d "$(REPO_DIR)/_site" ]; then \
		echo "Removing $(REPO_DIR)/_site"; \
		rm -rf "$(REPO_DIR)/_site"; \
	fi

serve:
	$(call with_container,jekyll serve --livereload)

shell:
	$(call with_container,/bin/sh)

